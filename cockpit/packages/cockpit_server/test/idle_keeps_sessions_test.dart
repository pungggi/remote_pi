// Regra que decide se o usuário perde trabalho ao ficar desconectado: o
// servidor remoto NÃO pode encerrar por ociosidade enquanto houver sessão
// viva. Sem ela, dois minutos de rede caída matavam o agente/build que
// estivesse rodando no host.
import 'dart:async';

import 'package:cockpit_core/cockpit_core.dart';
import 'package:cockpit_server/cockpit_server.dart';
import 'package:test/test.dart';

void main() {
  group('exit-on-idle', () {
    test('encerra quando não há sessão alguma', () async {
      final server = _serverWith(const []);
      final exited = _watchIdleExit(server);
      await _bindAndDropClient(server);
      expect(await exited, isTrue);
    });

    test('NÃO encerra enquanto uma sessão está viva', () async {
      final server = _serverWith([_session('a', alive: true)]);
      final exited = _watchIdleExit(server);
      await _bindAndDropClient(server);
      expect(await exited, isFalse);
    });

    test('encerra se as sessões existentes já terminaram', () async {
      // Sessão finalizada retém só scrollback: não é trabalho em andamento.
      final server = _serverWith([_session('a', alive: false)]);
      final exited = _watchIdleExit(server);
      await _bindAndDropClient(server);
      expect(await exited, isTrue);
    });

    test(
      'sem a flag, sessão viva não segura o servidor (sidecar local)',
      () async {
        final server = _serverWith([_session('a', alive: true)])
          ..idleKeepsSessions = false;
        final exited = _watchIdleExit(server);
        await _bindAndDropClient(server);
        expect(await exited, isTrue);
      },
    );
  });
}

RemoteServer _serverWith(List<PtySessionInfo> sessions) =>
    RemoteServer(_FakeTerminals(sessions), _FakeFiles(), _FakeGit(), _FakeDb())
      ..exitOnIdle = const Duration(milliseconds: 30)
      ..idleKeepsSessions = true;

/// Resolve `true` se o servidor pedir para sair dentro da janela de espera.
Future<bool> _watchIdleExit(RemoteServer server) {
  final completer = Completer<bool>();
  server.onIdleExit = () {
    if (!completer.isCompleted) completer.complete(true);
  };
  Timer(const Duration(milliseconds: 200), () {
    if (!completer.isCompleted) completer.complete(false);
  });
  return completer.future;
}

/// Arma o timer de ociosidade como um cliente que conecta e some faria.
Future<void> _bindAndDropClient(RemoteServer server) async {
  await server.armIdleTimerForTest();
}

PtySessionInfo _session(String id, {required bool alive}) => PtySessionInfo(
  id: id,
  pid: 1,
  executable: '/bin/zsh',
  rows: 25,
  columns: 80,
  scrollbackLength: 0,
  exitCode: alive ? null : 0,
);

class _FakeTerminals implements TerminalService {
  _FakeTerminals(this._sessions);
  final List<PtySessionInfo> _sessions;

  @override
  Future<List<PtySessionInfo>> sessions() async => _sessions;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeFiles implements FileService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeGit implements GitService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeDb implements DbService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
