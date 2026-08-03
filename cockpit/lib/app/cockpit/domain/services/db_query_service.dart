import 'dart:async';

import 'package:cockpit/app/cockpit/domain/contracts/db_connection_store.dart';
import 'package:cockpit/app/cockpit/domain/contracts/db_driver.dart';
import 'package:cockpit/app/cockpit/domain/contracts/mongo_database_store.dart';
import 'package:cockpit/app/cockpit/domain/contracts/nosql_runner.dart';
import 'package:cockpit/app/cockpit/domain/contracts/ssh_tunnel.dart';
import 'package:cockpit/app/cockpit/domain/entities/db_connection.dart';
import 'package:cockpit/app/cockpit/domain/entities/db_result.dart';
import 'package:cockpit/app/cockpit/domain/entities/ssh_tunnel_config.dart';

/// Orquestra a execução de queries — o **mesmo** motor pra tab `.dbq` e pra
/// CLI `cockpit db` (decisão J do plano 51): resolve a conexão por nome no
/// store, resolve senha no cofre (nunca expõe pro chamador), escolhe o driver
/// e serializa execuções (pré-requisito do slot global do anaki na Wave 3).
class DbQueryService {
  DbQueryService(
    this._store,
    this._secrets,
    this._registry,
    this._nosql,
    this._tunnel,
    this._sshKeys,
    this._mongoDatabases,
  );

  final DbConnectionStore _store;
  final DbSecrets _secrets;
  final DbDriverRegistry _registry;
  final NoSqlRunner _nosql;
  final SshTunnel _tunnel;
  final SshKeyInspector _sshKeys;
  final MongoDatabaseStore _mongoDatabases;

  /// Prompt de passphrase SSH. Setado pela UI no boot; **nulo no caminho CLI**
  /// (agente não tem como responder) — nesse caso a conexão sem passphrase no
  /// cofre falha com `ssh_credential_required` em vez de pendurar.
  SshPassphrasePrompt? passphrasePrompt;

  /// Confirmação de host key nova (TOFU). Mesma regra do [passphrasePrompt]:
  /// ausente = recusa honesta, nunca confiança cega.
  HostKeyPrompt? hostKeyPrompt;

  /// Passphrases digitadas mas **não** salvas no cofre: valem enquanto o app
  /// viver. É o que permite "não quero segredo em cofre nenhum" sem punir com
  /// um prompt por query.
  final Map<String, String> _passphraseCache = {};

  /// Limite default de linhas quando nem chamada nem `.dbq` especificam.
  static const defaultLimit = 200;

  /// Uma fila **por engine**, não global.
  ///
  /// O anaki guarda a conexão num `static CONNECTOR` — mas esse estático é por
  /// **dylib**, e cada engine compila a sua. Logo o que precisa ser serializado
  /// é o acesso a um mesmo dylib: um Postgres lento não tem por que segurar uma
  /// query de SQLite, Redis ou Mongo.
  ///
  /// Duas conexões do MESMO engine continuam serializadas — elas realmente
  /// disputam o mesmo slot. Sair disso depende do anaki devolver um handle por
  /// conexão em vez de manter uma global.
  final Map<DbEngine, Future<void>> _queues = {};

  Future<List<DbConnection>> connections(String workspaceRoot) =>
      _store.load(workspaceRoot);

  /// Executa [sql] contra a conexão [connName] do workspace. [workspaceId]
  /// entra na chave do cofre (`cockpit.db.<workspaceId>.<nome>`).
  Future<DbResult> query({
    required String workspaceRoot,
    required String workspaceId,
    required String connName,
    required String sql,
    int? limit,
    bool dml = false,
  }) async {
    // Resolver conexão e abrir túnel ficam FORA da fila: não tocam o dylib, e
    // prender o slot durante um handshake SSH atrasaria as outras queries do
    // mesmo engine à toa.
    final conn = await _resolve(workspaceRoot, workspaceId, connName);
    final driver = _driverFor(conn);
    final password = await _passwordFor(conn, workspaceId);
    final resolved = _resolvePaths(workspaceRoot, conn);
    return _serialized(conn.engine, () async {
      if (dml) {
        return driver.execute(resolved, sql, password: password);
      }
      return driver.query(
        resolved,
        sql,
        limit: limit ?? defaultLimit,
        password: password,
      );
    });
  }

  /// Introspecção normalizada (tabelas ou colunas de [table]).
  Future<DbResult> schema({
    required String workspaceRoot,
    required String workspaceId,
    required String connName,
    String? table,
    String? schema,
  }) async {
    final conn = await _resolve(workspaceRoot, workspaceId, connName);
    final driver = _driverFor(conn);
    final password = await _passwordFor(conn, workspaceId);
    final resolved = _resolvePaths(workspaceRoot, conn);
    return _serialized(
      conn.engine,
      () => driver.schema(
        resolved,
        table: table,
        schema: schema,
        password: password,
      ),
    );
  }

  /// Executa [statements] **em sequência** (mesma conexão lógica, execuções
  /// serializadas) e devolve o resultado do **último** — semântica de "run
  /// script" dos clients (os intermediários preparam o terreno; o final é o
  /// resultado). Limitação v1 (modelo efêmero): cada statement abre/fecha a
  /// própria conexão — temp tables/transactions entre statements não
  /// sobrevivem.
  Future<DbResult> runStatements({
    required String workspaceRoot,
    required String workspaceId,
    required String connName,
    required List<String> statements,
    int? limit,
  }) async {
    if (statements.isEmpty) {
      throw const DbQueryException('query_failed', 'Nothing to run.');
    }
    final conn = await _resolve(workspaceRoot, workspaceId, connName);
    final driver = _driverFor(conn);
    final password = await _passwordFor(conn, workspaceId);
    final resolved = _resolvePaths(workspaceRoot, conn);
    return _serialized(
      conn.engine,
      cap: _scriptCap(statements.length),
      () async {
        DbResult? last;
        for (final sql in statements) {
          last = await driver.query(
            resolved,
            sql,
            limit: limit ?? defaultLimit,
            password: password,
          );
        }
        return last!;
      },
    );
  }

  /// Redis (CLI-only): envia `parts` e devolve o reply JSON-serializável.
  Future<Object?> redisCommand({
    required String workspaceRoot,
    required String workspaceId,
    required String connName,
    required List<String> parts,
  }) async {
    final conn = await _resolve(workspaceRoot, workspaceId, connName);
    _requireEngine(conn, DbEngine.redis, connName);
    final password = await _passwordFor(conn, workspaceId);
    return _serialized(
      conn.engine,
      () => _nosql.redis(conn, parts, password: password),
    );
  }

  /// Redis em lote (tabela do plano 52): [commands] em sequência numa única
  /// conexão, replies na mesma ordem. Mesma resolução de conexão/senha do
  /// [redisCommand] — a UI executa exatamente o que o agente executaria.
  Future<List<Object?>> redisBatch({
    required String workspaceRoot,
    required String workspaceId,
    required String connName,
    required List<List<String>> commands,
  }) async {
    final conn = await _resolve(workspaceRoot, workspaceId, connName);
    _requireEngine(conn, DbEngine.redis, connName);
    final password = await _passwordFor(conn, workspaceId);
    return _serialized(
      conn.engine,
      () => _nosql.redisMany(conn, commands, password: password),
    );
  }

  /// Mongo: roda `command` (runCommand) e devolve o doc JSON. Serve o browser
  /// (plano 53) e o `cockpit mongo` do agente — mesmo caminho, mesmo database.
  ///
  /// [database] força o alvo (só o `listDatabases` do seletor precisa disso);
  /// omitido, vale a escolha salva do usuário e, na falta dela, a URL.
  Future<Object?> mongoCommand({
    required String workspaceRoot,
    required String workspaceId,
    required String connName,
    required Map<String, dynamic> command,
    String? database,
  }) async {
    final conn = await _resolve(workspaceRoot, workspaceId, connName);
    _requireEngine(conn, DbEngine.mongo, connName);
    final password = await _passwordFor(conn, workspaceId);
    final target = database ?? mongoDatabase(workspaceId, conn);
    return _serialized(
      conn.engine,
      () => _nosql.mongo(conn, command, password: password, database: target),
    );
  }

  /// Database efetivo de uma conexão Mongo: o da URL (quando ela traz path)
  /// vence — é explícito — e, faltando esse, a escolha salva do seletor.
  /// `null` deixa o runner cair no fallback dele.
  String? mongoDatabase(String workspaceId, DbConnection conn) =>
      conn.database.isNotEmpty
      ? conn.database
      : _mongoDatabases.selected(workspaceId, conn.name);

  /// `true` quando a conexão depende do seletor (URL sem database).
  bool mongoNeedsDatabase(DbConnection conn) => conn.database.isEmpty;

  /// Fixa o database da conexão (seletor do painel).
  Future<void> selectMongoDatabase(
    String workspaceId,
    String connName,
    String database,
  ) => _mongoDatabases.select(workspaceId, connName, database);

  /// Recusa cedo quando a conexão nomeada é de outro engine.
  void _requireEngine(DbConnection conn, DbEngine expected, String connName) {
    if (conn.engine == expected) return;
    throw DbQueryException(
      'unsupported_engine',
      '"$connName" is a ${conn.engine.label} connection, '
          'not ${expected.label}.',
    );
  }

  /// Teto de um script: cada statement pode legitimamente levar o timeout
  /// inteiro do driver, então o limite acompanha o tamanho do script em vez de
  /// cortar trabalho válido.
  Duration _scriptCap(int statements) {
    final proportional = Duration(seconds: statements * 60);
    return proportional > operationCap ? proportional : operationCap;
  }

  /// Chave do cofre pra senha da conexão — única por workspace+nome.
  static String secretKey(String workspaceId, String connName) =>
      'cockpit.db.$workspaceId.$connName';

  /// Chave do cofre pra passphrase da chave SSH — separada da senha do banco
  /// (são segredos distintos, e a conexão pode ter um sem o outro).
  static String sshSecretKey(String workspaceId, String connName) =>
      'cockpit.ssh.$workspaceId.$connName';

  /// Resolve a conexão por nome e, se ela tiver túnel SSH, **redireciona o
  /// destino pra ponta local do túnel** (plano 54, decisão A). Este é o único
  /// ponto do fluxo que sabe da existência de SSH: drivers, views, sessões e
  /// CLI recebem uma `DbConnection` TCP comum.
  Future<DbConnection> _resolve(
    String root,
    String workspaceId,
    String name,
  ) async {
    final all = await _store.load(root);
    for (final c in all) {
      if (c.name == name) return _tunneled(c, workspaceId);
    }
    final available = all.map((c) => c.name).join(', ');
    throw DbQueryException(
      'unknown_connection',
      'No connection named "$name" in this workspace. '
          'Available: ${available.isEmpty ? '(none)' : available}',
    );
  }

  /// Testa uma conexão **ainda não salva** (botão Test do dialog): abre o
  /// túnel se houver e roda o ping mínimo do engine. Vive aqui, e não na VM,
  /// porque testar tem que exercitar exatamente o caminho da execução real —
  /// incluindo o SSH. Lança [DbQueryException] em falha.
  ///
  /// [sshPassphrase] é a digitada no dialog e tem precedência sobre o cofre:
  /// sem isso, testar uma passphrase nova sempre validaria a antiga.
  Future<void> ping(
    DbConnection conn, {
    required String workspaceId,
    String? password,
    String? sshPassphrase,
  }) async {
    final target = await _tunneled(conn, workspaceId, override: sshPassphrase);
    return _serialized(conn.engine, () async {
      switch (conn.engine) {
        case DbEngine.redis:
          await _nosql.redis(target, const ['PING'], password: password);
        case DbEngine.mongo:
          await _nosql.mongo(target, const {'ping': 1}, password: password);
        case DbEngine.sqlite:
        case DbEngine.postgres:
        case DbEngine.mysql:
        case DbEngine.mssql:
          await _driverFor(
            conn,
          ).query(target, 'SELECT 1', limit: 1, password: password);
      }
    });
  }

  Future<DbConnection> _tunneled(
    DbConnection conn,
    String workspaceId, {
    String? override,
  }) async {
    final ssh = conn.ssh;
    if (ssh == null) return conn;
    if (!conn.engine.supportsSshTunnel) return conn;
    final passphrase = await _passphraseFor(
      conn,
      ssh,
      workspaceId,
      override: override,
    );
    try {
      // Mongo vai por **SOCKS**, os demais por port-forward. Não é preferência
      // de estilo: o driver do Mongo descobre os membros do replica set pelo
      // `hello` e passa a discar os hostnames que o servidor anunciar — uma
      // porta local fixa só alcançaria o primeiro nó, e `mongodb+srv://` nem
      // isso. Postgres/MySQL/MSSQL/Redis falam com um endereço só, então
      // port-forward é o mecanismo certo (e não exigem suporte a proxy).
      if (conn.engine == DbEngine.mongo) {
        final proxy = await _tunnel.ensureSocks(
          ssh,
          passphrase: passphrase,
          onUnknownHostKey: hostKeyPrompt,
        );
        return conn.withSocksProxy(proxy.host, proxy.port);
      }
      final endpoint = await _tunnel.ensure(
        ssh,
        targetHost: conn.host,
        targetPort: conn.port,
        passphrase: passphrase,
        onUnknownHostKey: hostKeyPrompt,
      );
      return conn.withEndpoint(endpoint.host, endpoint.port);
    } on SshTunnelException catch (e) {
      // Passphrase cacheada rejeitada (usuário trocou a chave, cofre velho):
      // esquece pra que a próxima tentativa volte a perguntar.
      if (e.kind == 'ssh_credential_required') {
        _passphraseCache.remove(sshSecretKey(workspaceId, conn.name));
      }
      throw DbQueryException(e.kind, e.message);
    }
  }

  /// Passphrase da chave SSH, na ordem: **cofre → cache de sessão → prompt**.
  /// Chave sem passphrase devolve `null` sem tocar em nada — o caminho feliz,
  /// que funciona igual na GUI e na CLI.
  Future<String?> _passphraseFor(
    DbConnection conn,
    SshTunnelConfig ssh,
    String workspaceId, {
    String? override,
  }) async {
    if (!await _sshKeys.needsPassphrase(ssh.keyPath)) return null;
    // Digitada agora (dialog) ganha do cofre — testar passphrase nova tem que
    // testar a nova.
    if (override != null && override.isNotEmpty) return override;

    final key = sshSecretKey(workspaceId, conn.name);
    if (ssh.savePassphrase) {
      final saved = await _secrets.read(key);
      if (saved != null && saved.isNotEmpty) return saved;
    }
    final cached = _passphraseCache[key];
    if (cached != null) return cached;

    final prompt = passphrasePrompt;
    if (prompt == null) {
      // Caminho CLI: erro honesto e imediato em vez de pendurar esperando uma
      // resposta que nunca vem.
      throw DbQueryException(
        'ssh_credential_required',
        'Connection "${conn.name}" uses a passphrase-protected SSH key and no '
            'passphrase is saved. Open it in the Cockpit UI and enable '
            '"Save passphrase" to let agents use this connection.',
      );
    }
    final typed = await prompt(conn.name, ssh.keyPath);
    if (typed == null || typed.isEmpty) {
      throw DbQueryException(
        'ssh_credential_required',
        'SSH passphrase required for "${conn.name}".',
      );
    }
    _passphraseCache[key] = typed;
    return typed;
  }

  /// Derruba todos os túneis e esquece as passphrases de sessão. Chamado ao
  /// desmontar o shell — o TTL ocioso cobre o resto.
  Future<void> closeSshTunnels() async {
    _passphraseCache.clear();
    await _tunnel.closeAll();
  }

  /// Esquece a passphrase de sessão (renome/remoção de conexão).
  void forgetSshPassphrase(String workspaceId, String connName) =>
      _passphraseCache.remove(sshSecretKey(workspaceId, connName));

  DbDriver _driverFor(DbConnection conn) {
    final driver = _registry.forEngine(conn.engine);
    if (driver == null) {
      throw DbQueryException(
        'unsupported_engine',
        '${conn.engine.label} support is not available yet '
            '(arrives with the anakiORM integration).',
      );
    }
    return driver;
  }

  Future<String?> _passwordFor(DbConnection conn, String workspaceId) async {
    if (conn.engine == DbEngine.sqlite) return null;
    if (conn.savePassword) {
      final saved = await _secrets.read(secretKey(workspaceId, conn.name));
      if (saved != null) return saved;
    }
    // Fallback: senha embutida na URL — o caminho de quem NÃO usa o cofre
    // (dialog com "Save Password" off grava `user:senha@` no databases.json)
    // ou json editado na mão.
    return conn.urlPassword;
  }

  /// Sqlite com path relativo é relativo à raiz do workspace.
  DbConnection _resolvePaths(String root, DbConnection conn) {
    if (conn.engine != DbEngine.sqlite) return conn;
    final path = conn.sqlitePath;
    final absolute =
        path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
    return absolute ? conn : conn.copyWith(url: 'sqlite:$root/$path');
  }

  /// Quanto uma execução espera **na fila** antes de desistir. Menor que o
  /// timeout da CLI (60s) de propósito: o agente recebe um erro nomeado em vez
  /// de "no response from app".
  static const defaultQueueWait = Duration(seconds: 45);

  /// Espera efetiva da fila. Campo (e não const) só para os testes poderem
  /// encurtá-la — em produção nunca é reatribuído.
  Duration queueWait = defaultQueueWait;

  /// Teto de **execução** de uma operação. Um degrau acima do timeout dos
  /// drivers (30s), então só dispara quando algo escapou do controle deles.
  ///
  /// Existe para o serviço se curar sozinho: sem ele, uma única operação
  /// travada deixa a fila em `busy` permanente e mata a feature de DB até
  /// alguém reiniciar o app — foi o que aconteceu no E2E do plano 54.
  static const defaultOperationCap = Duration(seconds: 120);

  /// Igual ao [queueWait]: campo só para encurtar nos testes.
  Duration operationCap = defaultOperationCap;

  /// Serializa execuções: uma por vez, na ordem de chegada. Erros não quebram
  /// a fila.
  ///
  /// A serialização é obrigatória (o slot de conexão do anaki é global por
  /// dylib), mas a **espera** é limitada: sem teto, uma conexão lenta ou
  /// abandonada fazia todo o resto — inclusive outros workspaces e engines —
  /// esperar sem explicação. Ao estourar, esta chamada **não executa** (preserva
  /// a serialização) e a fila segue encadeada na anterior.
  Future<T> _serialized<T>(
    DbEngine engine,
    Future<T> Function() action, {
    Duration? cap,
  }) async {
    final previous = _queues[engine] ?? Future<void>.value();
    final gate = Completer<void>();
    _queues[engine] = gate.future;
    try {
      await previous.timeout(queueWait);
    } on TimeoutException {
      // Encadeia o portão na anterior em vez de abri-lo: quem chegar depois
      // continua atrás de quem ainda está rodando.
      gate.complete(previous.then((_) {}, onError: (_) {}));
      throw DbQueryException(
        'busy',
        'Another ${engine.label} operation is still running. It may be a '
            'connection that is slow or unreachable — try again in a moment.',
      );
    }
    try {
      return await action().timeout(cap ?? operationCap);
    } on TimeoutException {
      // Libera a fila mesmo assim (o `finally` abaixo). O trabalho abandonado
      // pode seguir vivo — mesma natureza do timeout que os drivers já aplicam
      // sobre o `Isolate.run` —, mas travar todo o resto é pior.
      throw DbQueryException(
        'timeout',
        'Operation exceeded ${(cap ?? operationCap).inSeconds}s and was '
            'abandoned.',
      );
    } finally {
      gate.complete();
    }
  }
}
