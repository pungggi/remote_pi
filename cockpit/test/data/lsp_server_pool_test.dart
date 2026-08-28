import 'dart:async';
import 'dart:io';

import 'package:cockpit/app/core/data/lsp/lsp_server_pool.dart';
import 'package:cockpit/app/core/domain/contracts/lsp_client.dart';
import 'package:cockpit/app/core/domain/entities/lsp_diagnostic.dart';
import 'package:cockpit/app/core/domain/entities/lsp_semantic_tokens.dart';
import 'package:cockpit/app/core/domain/exceptions/lsp_error.dart';
import 'package:cockpit/app/core/domain/result.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cliente fake controlável: `startSucceeds` é compartilhado pela factory pra
/// simular "falhou ao subir → corrigi o comando → restart sobe".
class _FakeClient implements LspClient {
  _FakeClient(this.rootPath, this._shared);
  final _Shared _shared;
  @override
  final String rootPath;

  final _diag = StreamController<LspDiagnosticsBatch>.broadcast();
  bool _running = false;
  final List<String> opened = [];

  /// Quantas vezes `semanticTokens/full` foi pedido — o teto de tamanho tem que
  /// evitar o round-trip, não só descartar a resposta.
  int semanticTokensCalls = 0;

  @override
  Stream<LspDiagnosticsBatch> get diagnostics => _diag.stream;
  @override
  bool get isRunning => _running;
  @override
  dynamic get semanticTokensLegend => const SemanticTokensLegend(
    tokenTypes: <String>['class', 'variable'],
    tokenModifiers: <String>[],
  );

  @override
  Future<Result<void, LspError>> start() async {
    _shared.startCalls++;
    if (!_shared.startSucceeds) return const Failure(LspError('boom'));
    _running = true;
    return const Success(null);
  }

  @override
  Future<void> didOpen({required String path, required String text}) async =>
      opened.add(path);
  @override
  Future<void> didChange({
    required String path,
    required String text,
    required int version,
  }) async {}
  @override
  Future<void> didClose({required String path}) async {}
  @override
  Future<Result<Object?, LspError>> request(
    String method,
    Map<String, dynamic> params,
  ) async => const Success(null);
  @override
  Future<Result<Object?, LspError>> semanticTokensFull(String path) async {
    semanticTokensCalls++;
    // `semanticGate` deixa o teste segurar a resposta e editar o documento no
    // meio do caminho, reproduzindo a corrida request→didChange→response.
    final gate = _shared.semanticGate;
    if (gate != null) return gate.future;
    return const Success(null);
  }

  @override
  Future<Result<Object?, LspError>> definition(
    String path, {
    required int line,
    required int character,
  }) async => const Success(null);
  @override
  Future<void> kill() async => _running = false;
  @override
  void dispose() {
    _diag.close();
  }
}

class _Shared {
  bool startSucceeds = true;
  int startCalls = 0;
  final List<_FakeClient> created = [];

  /// Quando setado, `semanticTokensFull` do fake espera por ele.
  Completer<Result<Object?, LspError>>? semanticGate;
}

class _FakeFactory implements LspClientFactory {
  _FakeFactory(this.shared);
  final _Shared shared;
  @override
  LspClient create({required LspServerSpec spec, required String rootPath}) {
    final c = _FakeClient(rootPath, shared);
    shared.created.add(c);
    return c;
  }
}

void main() {
  late Directory tmp;
  late String dartFile;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pool_test');
    File('${tmp.path}/pubspec.yaml').writeAsStringSync('name: x');
    dartFile = '${tmp.path}/main.dart';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('open com start falho → stopped; restart sobe e reabre o doc', () async {
    final shared = _Shared()..startSucceeds = false;
    final pool = LspServerPool(_FakeFactory(shared));

    await pool.openDocument(path: dartFile, text: 'a');
    // Servidor falhou, mas o doc fica registrado → status stopped (não null).
    final s1 = pool.statusForPath(dartFile);
    expect(s1, isNotNull);
    expect(s1!.running, isFalse);
    expect(s1.languageId, 'dart');

    // "Corrige o comando" e reinicia.
    shared.startSucceeds = true;
    await pool.restartForPath(dartFile);

    final s2 = pool.statusForPath(dartFile);
    expect(s2!.running, isTrue);
    // O doc foi reaberto no servidor novo.
    expect(shared.created.last.opened, contains(dartFile));

    pool.dispose();
  });

  test('restartLanguage reinicia mesmo sem servidor vivo', () async {
    final shared = _Shared()..startSucceeds = false;
    final pool = LspServerPool(_FakeFactory(shared));
    await pool.openDocument(path: dartFile, text: 'a');
    expect(pool.statusForPath(dartFile)!.running, isFalse);

    shared.startSucceeds = true;
    await pool.restartLanguage('dart');
    expect(pool.statusForPath(dartFile)!.running, isTrue);

    pool.dispose();
  });

  test('open com sucesso abre o doc e fica running', () async {
    final shared = _Shared();
    final pool = LspServerPool(_FakeFactory(shared));
    await pool.openDocument(path: dartFile, text: 'a');
    final s = pool.statusForPath(dartFile);
    expect(s!.running, isTrue);
    expect(shared.created.single.opened, [dartFile]);
    pool.dispose();
  });

  group('teto de semantic tokens', () {
    test('arquivo pequeno pede tokens ao servidor', () async {
      final shared = _Shared();
      final pool = LspServerPool(_FakeFactory(shared));
      await pool.openDocument(path: dartFile, text: 'class A {}');

      await pool.semanticTokensFull(dartFile);

      expect(shared.created.single.semanticTokensCalls, 1);
      pool.dispose();
    });

    test('arquivo acima do teto NÃO faz round-trip e volta vazio', () async {
      final shared = _Shared();
      final pool = LspServerPool(_FakeFactory(shared));
      // > 100KB: o custo real não era o request, era o relayout do texto todo
      // disparado quando os tokens chegam async.
      final big = 'class A {}\n' * 12000; // ~132KB
      await pool.openDocument(path: dartFile, text: big);

      final tokens = await pool.semanticTokensFull(dartFile);

      expect(tokens.tokens, isEmpty);
      expect(shared.created.single.semanticTokensCalls, 0);
      pool.dispose();
    });

    test('edição durante o request não desloca os tokens', () async {
      final shared = _Shared();
      final pool = LspServerPool(_FakeFactory(shared));

      // Texto do PEDIDO: linhas de 4 chars → início da linha 1 no offset 5.
      await pool.openDocument(path: dartFile, text: 'aaaa\nbbbb\n');

      final gate = Completer<Result<Object?, LspError>>();
      shared.semanticGate = gate;
      final pending = pool.semanticTokensFull(dartFile);

      // Usuário digita enquanto o servidor responde: linhas encurtam, então o
      // início da linha 1 passa pro offset 3. Se o decode usasse o texto NOVO
      // com os deltas da versão antiga, o token cairia na letra errada — era
      // isso que fazia o texto já digitado piscar.
      await pool.changeDocument(path: dartFile, text: 'aa\nbbbb\n');

      // Resposta: 1 token em (deltaLine 1, deltaStart 0, len 2, type 0).
      gate.complete(
        const Success(<String, dynamic>{
          'data': <int>[1, 0, 2, 0, 0],
        }),
      );
      final tokens = await pending;

      expect(tokens.tokens, hasLength(1));
      // 5 = início da linha 1 no texto do PEDIDO (3 seria o do texto novo).
      expect(tokens.tokens.single.start, 5);
      expect(tokens.tokens.single.end, 7);

      shared.semanticGate = null;
      pool.dispose();
    });

    test('encolher abaixo do teto reativa os tokens', () async {
      final shared = _Shared();
      final pool = LspServerPool(_FakeFactory(shared));
      await pool.openDocument(path: dartFile, text: 'class A {}\n' * 12000);
      await pool.semanticTokensFull(dartFile);
      expect(shared.created.single.semanticTokensCalls, 0);

      // Usuário apaga a maior parte do arquivo → volta a valer.
      await pool.changeDocument(path: dartFile, text: 'class A {}');
      await pool.semanticTokensFull(dartFile);

      expect(shared.created.single.semanticTokensCalls, 1);
      pool.dispose();
    });
  });

  group('roteamento de raiz', () {
    late Directory external;

    setUp(() {
      // Simula o SDK Flutter / pub-cache: FORA do workspace, com pubspec próprio
      // (é isso que fazia o walk-up querer um servidor com raiz lá).
      external = Directory.systemTemp.createTempSync('pool_sdk');
      File('${external.path}/pubspec.yaml').writeAsStringSync('name: flutter');
    });
    tearDown(() => external.deleteSync(recursive: true));

    test('arquivo FORA do workspace reusa o servidor do projeto', () async {
      final shared = _Shared();
      final pool = LspServerPool(_FakeFactory(shared));

      await pool.openDocument(
        path: dartFile,
        text: 'a',
        fallbackRoot: tmp.path,
      );
      // Classe do SDK aberta por go-to-definition.
      final sdkFile = '${external.path}/framework.dart';
      await pool.openDocument(path: sdkFile, text: 'b', fallbackRoot: tmp.path);

      // UM servidor só (o do projeto) — não subiu outro com raiz no SDK.
      expect(shared.created, hasLength(1));
      expect(shared.startCalls, 1);
      // E o arquivo do SDK foi aberto NELE (é dependência, já está no contexto).
      expect(shared.created.single.opened, [dartFile, sdkFile]);
      expect(pool.statusForPath(sdkFile)!.running, isTrue);

      pool.dispose();
    });

    test(
      'monorepo: subpacote DENTRO do workspace ganha servidor próprio',
      () async {
        final shared = _Shared();
        final pool = LspServerPool(_FakeFactory(shared));

        // `tmp/sub/pubspec.yaml` → pacote distinto dentro do mesmo workspace.
        final sub = Directory('${tmp.path}/sub')..createSync();
        File('${sub.path}/pubspec.yaml').writeAsStringSync('name: sub');
        final subFile = '${sub.path}/main.dart';

        await pool.openDocument(
          path: dartFile,
          text: 'a',
          fallbackRoot: tmp.path,
        );
        await pool.openDocument(
          path: subFile,
          text: 'b',
          fallbackRoot: tmp.path,
        );

        // DOIS servidores: o walk-up ainda manda dentro do workspace.
        expect(shared.created, hasLength(2));
        expect(shared.created[0].opened, [dartFile]);
        expect(shared.created[1].opened, [subFile]);

        pool.dispose();
      },
    );

    test('sem workspace, arquivo solto usa a própria raiz achada', () async {
      final shared = _Shared();
      final pool = LspServerPool(_FakeFactory(shared));

      final sdkFile = '${external.path}/framework.dart';
      await pool.openDocument(path: sdkFile, text: 'b'); // sem fallbackRoot

      expect(shared.created, hasLength(1));
      expect(shared.created.single.rootPath, external.path);

      pool.dispose();
    });
  });
}
