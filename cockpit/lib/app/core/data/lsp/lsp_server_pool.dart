import 'dart:async';
import 'dart:io';

import 'package:cockpit/app/core/data/lsp/lsp_command.dart';
import 'package:cockpit/app/core/data/lsp/lsp_launchers.dart';
import 'package:cockpit/app/core/data/lsp/lsp_text_edit.dart';
import 'package:cockpit/app/core/data/lsp/project_root_finder.dart';
import 'package:cockpit/app/core/domain/contracts/lsp_client.dart';
import 'package:cockpit/app/core/domain/entities/lsp_diagnostic.dart';
import 'package:cockpit/app/core/domain/entities/lsp_location.dart';
import 'package:cockpit/app/core/domain/entities/lsp_semantic_tokens.dart';
import 'package:cockpit/app/core/domain/exceptions/lsp_error.dart';
import 'package:cockpit/app/core/domain/result.dart';
import 'package:cockpit/app/core/utils/executable_resolver.dart';
import 'package:flutter/foundation.dart';

/// Pool **global do app** de language servers, chaveado por `(linguagem, raiz)`.
/// Vários workspaces vivos compartilham este pool: dois arquivos da mesma raiz
/// reusam o servidor; raízes/linguagens distintas têm servidores distintos.
///
/// Gerencia o ciclo de vida por **contagem de referência** dos documentos
/// abertos: o último `closeDocument` agenda o desligamento (com carência, caso
/// o usuário reabra logo). Degrada graciosamente — linguagem sem servidor
/// instalado é um no-op silencioso, o editor nunca quebra.
class LspServerPool {
  LspServerPool(this._factory);

  final LspClientFactory _factory;
  // Não injetado: o parser do auto_injector não pula parâmetro opcional com
  // default, então fica como campo inline (fora do grafo de DI).
  final ProjectRootFinder _rootFinder = const ProjectRootFinder();

  final Map<String, _ServerEntry> _servers = <String, _ServerEntry>{};
  final Map<String, _DocEntry> _docs = <String, _DocEntry>{};

  /// Starts em andamento por chave — evita a corrida de dois `openDocument`
  /// concorrentes (ex: restauração de sessão abrindo várias abas da mesma
  /// linguagem/raiz de uma vez) subirem **dois** processos de servidor pro
  /// mesmo (linguagem, raiz): o segundo sobrescreveria `_servers[key]` e o
  /// primeiro doc ficaria conversando com um processo órfão, invisível pro
  /// resto do pool (semanticTokensFull/definition sempre leem `_servers[key]`
  /// atual). Chamadas concorrentes esperam o MESMO Future.
  final Map<String, Future<_ServerEntry?>> _pendingStarts =
      <String, Future<_ServerEntry?>>{};

  final StreamController<LspDiagnosticsBatch> _diagnostics =
      StreamController<LspDiagnosticsBatch>.broadcast();

  /// Emite a cada mudança de estado de servidor (subiu / caiu / reiniciou). A
  /// barra de status do LSP escuta isto pra atualizar o indicador ao vivo.
  final StreamController<void> _statusChanges =
      StreamController<void>.broadcast();

  /// Diagnostics de **todos** os servidores, mesclados. A UI roteia por `uri`.
  Stream<LspDiagnosticsBatch> get diagnostics => _diagnostics.stream;

  /// Pulsos de mudança de estado de servidores (sem payload — a UI re-consulta
  /// [statusForPath]).
  Stream<void> get statusChanges => _statusChanges.stream;

  /// Override de comando por linguagem (Wave 2: vem da tela "Language").
  /// `languageId` → linha de comando (`exec arg1 arg2`). Vazio = usa o default.
  Map<String, String> commandOverrides = const <String, String>{};

  /// Carência antes de desligar um servidor sem documentos abertos.
  static const Duration _shutdownGrace = Duration(seconds: 30);

  /// Abre um documento: resolve linguagem/raiz, **registra o doc** (mesmo se o
  /// servidor não subir — pra que o restart saiba o que reabrir), sobe/reusa o
  /// servidor e manda `didOpen`. [fallbackRoot] (a raiz do workspace) é usado
  /// quando o walk-up não acha marcador **ou** quando acha um marcador fora do
  /// workspace (ver [_rootFor]). No-op se a linguagem não é suportada.
  Future<void> openDocument({
    required String path,
    required String text,
    String? fallbackRoot,
  }) async {
    final def = languageForPath(path);
    if (def == null) return;
    final root = _rootFor(path, def, fallbackRoot);
    if (root == null) return;

    final key = _key(def.id, root);
    // Registra o doc antes de tentar subir — garante que statusForPath/restart
    // conheçam o documento (texto + raiz) mesmo se o start falhar.
    _docs[path] = _DocEntry(key, root, text);
    final entry = await _ensureServer(key, def, root);
    if (entry != null && entry.client.isRunning) {
      await entry.client.didOpen(path: path, text: text);
    }
  }

  /// Raiz do servidor que deve atender [path].
  ///
  /// O walk-up (`ProjectRootFinder`) resolve o caso do monorepo: um arquivo em
  /// `mono/cockpit/lib/x.dart` é atendido pelo servidor de `mono/cockpit/`
  /// (onde está o `pubspec.yaml`), não pelo de `mono/`. Mas o mesmo walk-up,
  /// aplicado a um arquivo **fora do workspace** — uma classe do SDK Flutter
  /// aberta via go-to-definition, ou um pacote do pub-cache — acha o
  /// `pubspec.yaml` DAQUELE pacote e pediria um servidor com raiz no SDK, que
  /// tentaria indexar o pacote inteiro (milhares de arquivos) e travava a UI.
  ///
  /// Como o VSCode faz (e é o que fazemos aqui): **um servidor por workspace**;
  /// abrir um arquivo do SDK só manda `didOpen` pro servidor que já existe. Ele
  /// responde highlight/definition normalmente porque esses arquivos já estão
  /// no contexto de análise dele — são dependências do projeto, já resolvidas.
  ///
  /// Regra: usa a raiz do walk-up só quando ela está **dentro** do workspace
  /// ([fallbackRoot]); do contrário, cai no próprio workspace. Sem workspace
  /// (drop de arquivo solto do SO), aceita a raiz achada — é o único candidato.
  String? _rootFor(String path, LanguageDef def, String? fallbackRoot) {
    final found = _rootFinder.findRoot(path, def.markers);
    if (fallbackRoot == null) return found;
    if (found != null && _isUnder(found, fallbackRoot)) return found;
    return fallbackRoot;
  }

  bool _isUnder(String path, String root) =>
      path == root || path.startsWith('$root${Platform.pathSeparator}');

  /// Garante um servidor vivo para [key]. Reusa se já existe; senão resolve a
  /// spec e sobe. Retorna o entry vivo, ou `null` se não deu pra subir
  /// (degradação graciosa — os docs ficam registrados, status = stopped).
  Future<_ServerEntry?> _ensureServer(
    String key,
    LanguageDef def,
    String root,
  ) {
    final existing = _servers[key];
    if (existing != null) {
      existing.cancelPendingShutdown();
      return Future.value(existing.client.isRunning ? existing : null);
    }
    // Já há um start em andamento pra essa chave (corrida de docs concorrentes)
    // → todo mundo espera o MESMO resultado, ninguém sobe um segundo processo.
    final pending = _pendingStarts[key];
    if (pending != null) return pending;

    final future = _startServer(key, def, root);
    _pendingStarts[key] = future;
    unawaited(future.whenComplete(() => _pendingStarts.remove(key)));
    return future;
  }

  Future<_ServerEntry?> _startServer(
    String key,
    LanguageDef def,
    String root,
  ) async {
    final spec = await _resolveSpec(def);
    if (spec == null) {
      _statusChanges.add(null);
      return null;
    }
    final client = _factory.create(spec: spec, rootPath: root);
    final entry = _ServerEntry(client);
    _servers[key] = entry;
    entry.sub = client.diagnostics.listen(_onDiagnostics);
    final result = await client.start();
    if (result.isFailure) {
      final error = (result as Failure<void, LspError>).error;
      debugPrint('[lsp-pool] start falhou ($key): ${error.message}');
      await entry.sub?.cancel();
      _servers.remove(key);
      client.dispose();
      _statusChanges.add(null);
      return null;
    }
    _statusChanges.add(null);
    return entry;
  }

  /// `textDocument/didChange` (full sync). Guarda o texto mesmo sem servidor
  /// vivo (pro restart reabrir com o conteúdo atual).
  Future<void> changeDocument({
    required String path,
    required String text,
  }) async {
    final doc = _docs[path];
    if (doc == null) return;
    doc.version++;
    doc.lastText = text;
    final entry = _servers[doc.serverKey];
    if (entry == null || !entry.client.isRunning) return;
    await entry.client.didChange(path: path, text: text, version: doc.version);
  }

  /// Estado do LSP para o documento [path]: a linguagem e se o servidor está
  /// rodando. `null` se a linguagem não é suportada (a UI mostra vazio).
  LspDocStatus? statusForPath(String path) {
    final def = languageForPath(path);
    if (def == null) return null;
    final doc = _docs[path];
    final entry = doc == null ? null : _servers[doc.serverKey];
    return LspDocStatus(
      languageId: def.id,
      label: def.label,
      running: entry?.client.isRunning ?? false,
    );
  }

  /// Reinicia o servidor que atende [path]. Funciona mesmo se o servidor estava
  /// parado/falho (re-tenta subir e reabre os docs com o texto atual).
  Future<void> restartForPath(String path) async {
    final doc = _docs[path];
    if (doc == null) return;
    await _restartKey(doc.serverKey);
  }

  /// Reinicia todos os servidores de uma linguagem (ex.: após o usuário salvar
  /// um novo comando na tela "Language"). Cobre tanto servidores vivos quanto
  /// chaves com docs registrados mas sem servidor (start falhou antes).
  Future<void> restartLanguage(String languageId) async {
    final prefix = '$languageId$_sep';
    final keys = <String>{
      ..._servers.keys.where((k) => k.startsWith(prefix)),
      ..._docs.values
          .map((d) => d.serverKey)
          .where((k) => k.startsWith(prefix)),
    };
    for (final key in keys) {
      await _restartKey(key);
    }
  }

  /// Mata (se vivo) e re-sobe o servidor de [key], reabrindo todos os docs
  /// registrados nele com o último texto conhecido.
  Future<void> _restartKey(String key) async {
    final entry = _servers.remove(key);
    if (entry != null) {
      entry.cancelPendingShutdown();
      await entry.sub?.cancel();
      await entry.client.kill();
      entry.client.dispose();
    }
    _statusChanges.add(null);

    final docs = <String, _DocEntry>{
      for (final e in _docs.entries)
        if (e.value.serverKey == key) e.key: e.value,
    };
    if (docs.isEmpty) return;
    final def = languageForPath(docs.keys.first);
    if (def == null) return;
    final fresh = await _ensureServer(key, def, docs.values.first.root);
    if (fresh == null || !fresh.client.isRunning) return;
    for (final e in docs.entries) {
      await fresh.client.didOpen(path: e.key, text: e.value.lastText);
    }
  }

  /// Fecha o documento; agenda o desligamento do servidor quando não sobra
  /// nenhum doc registrado naquela chave.
  Future<void> closeDocument(String path) async {
    final doc = _docs.remove(path);
    _semanticSkipLogged.remove(path);
    if (doc == null) return;
    final entry = _servers[doc.serverKey];
    if (entry == null) return;
    if (entry.client.isRunning) await entry.client.didClose(path: path);
    final remaining = _docs.values.any((d) => d.serverKey == doc.serverKey);
    if (!remaining) _scheduleShutdown(doc.serverKey, entry);
  }

  /// Request genérico ao servidor que atende [path] (ex.: formatting na Wave 3).
  /// Falha se não há servidor para o documento.
  Future<Result<Object?, LspError>> requestForPath(
    String path,
    String method,
    Map<String, dynamic> params,
  ) async {
    final doc = _docs[path];
    final entry = doc == null ? null : _servers[doc.serverKey];
    if (entry == null) {
      return const Failure(LspError('No language server for this document.'));
    }
    return entry.client.request(method, params);
  }

  /// `textDocument/formatting` — pede a formatação do documento ao servidor e
  /// devolve os edits a aplicar no buffer. Lista vazia se não há servidor vivo,
  /// se o servidor não suporta formatting, ou em erro.
  Future<List<LspTextEdit>> formatDocument(
    String path, {
    int tabSize = 2,
    bool insertSpaces = true,
  }) async {
    final result = await requestForPath(path, 'textDocument/formatting', {
      'textDocument': {'uri': Uri.file(path).toString()},
      'options': {'tabSize': tabSize, 'insertSpaces': insertSpaces},
    });
    return result.fold(parseTextEdits, (_) => const <LspTextEdit>[]);
  }

  /// `textDocument/definition` — definição de símbolo na posição.
  /// `null` se não há servidor, sem suporte, fora do range, ou em erro.
  Future<LspLocation?> definition(String path, int line, int character) async {
    final doc = _docs[path];
    if (doc == null) return null;
    final entry = _servers[doc.serverKey];
    if (entry == null || !entry.client.isRunning) return null;

    final result = await entry.client.definition(
      path,
      line: line,
      character: character,
    );
    return result.fold(parseDefinitionResponse, (_) => null);
  }

  /// Teto pra pedir semantic tokens. Acima disso o arquivo fica só com o
  /// highlight léxico (que tem teto próprio, maior — 200KB em
  /// `code_highlight.dart`).
  ///
  /// Medido num arquivo Dart de 5.371 linhas / 144KB (debug/JIT): aplicar os
  /// tokens custa ~40ms de merge de overlay **e força um segundo layout de
  /// texto completo de ~310ms**, porque eles chegam async, depois do primeiro
  /// paint. Era ~metade do custo de abrir o arquivo. A 59KB o mesmo layout fica
  /// em ~19ms — aceitável. O corte fica nessa faixa, com folga pro caso comum:
  /// 100KB de Dart são ~3.500 linhas, então a esmagadora maioria dos arquivos
  /// reais mantém o highlight semântico e só os genuinamente grandes degradam.
  ///
  /// Degradar por tamanho é o que editores fazem; o certo mesmo seria aplicar
  /// tokens só ao viewport, mas isso exige tokenização por linha com estado do
  /// lexer (o pacote `highlight` suporta via `continuation`, porém não expõe —
  /// precisaria vendorizar). Fora do escopo deste corte.
  static const int _kMaxSemanticTokensChars = 100 * 1024;

  /// Paths já avisados no log — evita repetir a cada `didChange` (o viewer
  /// re-pede tokens no debounce de 400ms enquanto se digita).
  final Set<String> _semanticSkipLogged = <String>{};

  /// `textDocument/semanticTokens/full` — decodifica tokens semânticos do doc.
  /// `SemanticTokens` vazio se não há servidor, sem suporte, em erro, ou se o
  /// documento passa de [_kMaxSemanticTokensChars].
  Future<SemanticTokens> semanticTokensFull(String path) async {
    final doc = _docs[path];
    if (doc == null) return SemanticTokens(tokens: const <SemanticToken>[]);
    // Antes de qualquer round-trip: arquivo grande fica no léxico. Evita o
    // request, o decode e — o que de fato pesava — o relayout do texto inteiro.
    if (doc.lastText.length > _kMaxSemanticTokensChars) {
      if (_semanticSkipLogged.add(path)) {
        final kb = (doc.lastText.length / 1024).round();
        debugPrint(
          '[lsp-pool] semantic tokens off (${kb}KB > '
          '${_kMaxSemanticTokensChars ~/ 1024}KB): $path',
        );
      }
      return SemanticTokens(tokens: const <SemanticToken>[]);
    }
    final entry = _servers[doc.serverKey];
    if (entry == null || !entry.client.isRunning) {
      return SemanticTokens(tokens: const <SemanticToken>[]);
    }
    final legendObj = entry.client.semanticTokensLegend;
    if (legendObj is! SemanticTokensLegend) {
      return SemanticTokens(tokens: const <SemanticToken>[]);
    }

    // Texto no momento do PEDIDO. Ler `doc.lastText` depois do await pegaria uma
    // versão possivelmente já avançada por um `didChange` concorrente, e os
    // deltas do servidor (que são relativos ao documento que ELE tinha) seriam
    // convertidos em offsets sobre outro texto → tokens deslocados.
    final requestedText = doc.lastText;
    final result = await entry.client.semanticTokensFull(path);
    return result.fold((response) {
      if (response is! Map<String, dynamic>) {
        return SemanticTokens(tokens: const <SemanticToken>[]);
      }
      final data = response['data'];
      if (data is! List) return SemanticTokens(tokens: const <SemanticToken>[]);
      final ints = data.cast<int>();
      return decodeSemanticTokens(requestedText, ints, legendObj);
    }, (_) => SemanticTokens(tokens: const <SemanticToken>[]));
  }

  /// Desliga tudo (shutdown do app).
  void dispose() {
    for (final entry in _servers.values) {
      entry.cancelPendingShutdown();
      entry.sub?.cancel();
      entry.client.dispose();
    }
    _servers.clear();
    _docs.clear();
    _semanticSkipLogged.clear();
    if (!_diagnostics.isClosed) _diagnostics.close();
    if (!_statusChanges.isClosed) _statusChanges.close();
  }

  void _onDiagnostics(LspDiagnosticsBatch batch) {
    if (!_diagnostics.isClosed) _diagnostics.add(batch);
  }

  void _scheduleShutdown(String key, _ServerEntry entry) {
    // Cancela qualquer timer pendente ANTES de agendar um novo — senão, se
    // `closeDocument` for chamado várias vezes seguidas pra chaves que já
    // bateram "0 docs restantes" (ex: fechar várias abas do mesmo projeto de
    // uma vez, cada dispose() concorrente vendo `_docs` vazio antes de
    // qualquer um reabrir), cada chamada criava um Timer NOVO sem cancelar o
    // anterior — só o último ficava rastreado em `entry.shutdownTimer`
    // (cancelável por `cancelPendingShutdown`), e os demais viravam órfãos
    // que disparavam de qualquer jeito, matando/descartando o client várias
    // vezes (double-dispose) e distorcendo o log.
    entry.cancelPendingShutdown();
    entry.shutdownTimer = Timer(_shutdownGrace, () async {
      // Pode ter sido reusado durante a carência (algum doc voltou pra chave).
      if (_docs.values.any((d) => d.serverKey == key)) return;
      _servers.remove(key);
      await entry.sub?.cancel();
      await entry.client.kill();
      entry.client.dispose();
      _statusChanges.add(null);
      debugPrint('[lsp-pool] desligou $key');
    });
  }

  /// Resolve a spec: aplica override do usuário (Wave 2) ou o default, e
  /// localiza o binário no PATH (apps GUI não herdam PATH do shell).
  Future<LspServerSpec?> _resolveSpec(LanguageDef def) async {
    String executable = def.defaultExecutable;
    List<String> args = def.defaultArgs;

    final override = commandOverrides[def.id]?.trim();
    if (override != null && override.isNotEmpty) {
      final parts = splitLspCommand(override);
      if (parts.isNotEmpty) {
        executable = parts.first;
        args = parts.sublist(1);
      }
    }

    final resolved = await resolveExecutable(executable);
    // Não sobe o servidor se o binário não existe de fato. `resolveExecutable`
    // devolve o nome cru quando não acha (ex.: `gopls` sem o `~/go/bin` na PATH
    // de um launch GUI). Spawnar um executável inexistente dispara
    // ProcessException — e, no modo merged-thread, um SIGPIPE que derrubava o app
    // inteiro. Degradação graciosa: retorna null → status "stopped", e um
    // restart (após instalar o server / ajustar o comando) re-tenta.
    if (!_resolvesToRealFile(resolved)) return null;
    return def.toSpec(executable: resolved, args: args);
  }

  /// `true` se [exec] aponta pra um arquivo real (caminho absoluto existente).
  /// Nome cru (sem separador) = `resolveExecutable` não achou → não dá pra subir.
  bool _resolvesToRealFile(String exec) =>
      (exec.contains('/') || exec.contains(r'\')) && File(exec).existsSync();

  /// Separador da chave `(linguagem, raiz)`. NUL nunca aparece num caminho nem
  /// num languageId, então é um delimitador seguro (raízes podem ter espaços).
  static const String _sep = '\u0000';

  String _key(String languageId, String root) => '$languageId$_sep$root';
}

class _ServerEntry {
  _ServerEntry(this.client);

  final LspClient client;
  StreamSubscription<LspDiagnosticsBatch>? sub;
  Timer? shutdownTimer;

  void cancelPendingShutdown() {
    shutdownTimer?.cancel();
    shutdownTimer = null;
  }
}

class _DocEntry {
  _DocEntry(this.serverKey, this.root, this.lastText);

  final String serverKey;

  /// Raiz usada ao abrir — reusada no restart pra recriar o mesmo servidor.
  final String root;

  /// Último texto conhecido (open/change) — reaberto no restart.
  String lastText;

  int version = 1;
}

/// Estado do LSP de um documento, pra barra de status do pane de Files.
class LspDocStatus {
  const LspDocStatus({
    required this.languageId,
    required this.label,
    required this.running,
  });

  final String languageId;
  final String label;
  final bool running;
}
