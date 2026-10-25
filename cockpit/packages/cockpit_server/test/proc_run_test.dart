import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit_core/cockpit_core.dart';
import 'package:cockpit_protocol/cockpit_protocol.dart';
import 'package:cockpit_server/cockpit_server.dart';
import 'package:test/test.dart';

// `proc.run`: exec de aba remota / `.panel` remoto roda NO HOST.
void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cockpit-proc');
    path = '${dir.path}/s.sock';
    LocalEndpoint.debugForceTcp = true;
  });
  tearDown(() {
    LocalEndpoint.debugForceTcp = null;
    dir.deleteSync(recursive: true);
  });

  Future<_TestClient> boot() async {
    final server = RemoteServer(_FakeTerminals(), _Fake(), _Fake(), _SpyDb());
    await server.bind(path);
    addTearDown(server.close);
    return _connectClient(path);
  }

  test('roda a linha no host e devolve stdout/code', () async {
    final client = await boot();
    final reply = await _call(client, 'proc.run', {
      'command': 'printf hello; printf err 1>&2; exit 3',
      'cwd': dir.path,
    });
    expect(reply.ok, isTrue);
    final data = reply.data as Map;
    expect(data['code'], 3);
    expect(data['stdout'], 'hello');
    expect(data['stderr'], 'err');
    expect(data['timedOut'], isFalse);
  }, testOn: '!windows');

  test('Windows usa o command processor nativo', () async {
    final client = await boot();
    final reply = await _call(client, 'proc.run', {
      'command': 'echo hello& echo err 1>&2& exit 3',
      'cwd': dir.path,
    });
    expect(reply.ok, isTrue);
    final data = reply.data as Map;
    expect(data['code'], 3);
    expect(data['stdout'].toString().trim(), 'hello');
    expect(data['stderr'].toString().trim(), 'err');
  }, testOn: 'windows');

  test('cwd inexistente é erro tipado', () async {
    final client = await boot();
    final reply = await _call(client, 'proc.run', {
      'command': 'true',
      'cwd': '${dir.path}/nope',
    });
    expect(reply.ok, isFalse);
    expect(reply.code, 'cwd_not_found');
  });

  test('timeout mata o processo e marca timedOut', () async {
    final client = await boot();
    final reply = await _call(client, 'proc.run', {
      'command': 'sleep 5',
      'timeout': 1,
    });
    final data = reply.data as Map;
    expect(data['timedOut'], isTrue);
    expect(data['code'], 124);
  }, testOn: '!windows');

  test('proc.run não segura as demais mensagens do socket', () async {
    final client = await boot();
    final replies = <int>[];
    final sub = client.messages.listen((message) {
      if (message is RpcResponse && (message.rid == 1 || message.rid == 2)) {
        replies.add(message.rid);
      }
    });
    addTearDown(sub.cancel);

    client.send(
      RpcRequest(
        rid: 1,
        method: 'proc.run',
        params: {
          'command': Platform.isWindows
              ? 'ping -n 3 127.0.0.1 >NUL'
              : 'sleep 1',
        },
      ),
    );
    // A reverse cli.cmd response travels through this same dispatcher. An
    // immediate second message proves the process lifetime is not serialized
    // ahead of it; the old order was [1, 2].
    client.send(
      RpcRequest(rid: 2, method: 'test.unsupported', params: const {}),
    );

    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (replies.length < 2) {
      if (DateTime.now().isAfter(deadline)) {
        fail('responses did not complete: $replies');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(replies, [2, 1]);
  });
}

Future<RpcResponse> _call(
  _TestClient client,
  String method,
  Map<String, Object?> params,
) async {
  const rid = 1;
  final reply = client.messages.firstWhere(
    (m) => m is RpcResponse && m.rid == rid,
  );
  client.send(RpcRequest(rid: rid, method: method, params: params));
  return await reply.timeout(const Duration(seconds: 5)) as RpcResponse;
}

/// [DbService] que só registra o descritor recebido — o que interessa aqui é
/// COM QUE senha o servidor chamaria o driver, não o resultado da query.
class _SpyDb implements DbService {
  final seen = <RemoteDbConnDescriptor>[];

  @override
  Future<Map<String, Object?>> query(
    RemoteDbConnDescriptor conn,
    String sql, {
    int limit = 200,
    bool dml = false,
  }) async {
    seen.add(conn);
    return {'columns': <Object?>[], 'rows': <Object?>[]};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Future<_TestClient> _connectClient(String path) async {
  final endpoint = await LocalEndpoint.connect(path);
  final socket = endpoint.socket;
  addTearDown(socket.destroy);
  final messages = StreamController<RemoteMessage>.broadcast();
  const RemoteMessageCodec().decodeStream(socket).listen(messages.add);
  final ack = messages.stream.first;
  socket.add(
    utf8.encode(
      const RemoteMessageCodec().encode(
        Hello(
          version: protocolVersion,
          client: 'test',
          token: endpoint.token,
          local: false,
        ),
      ),
    ),
  );
  await ack.timeout(const Duration(seconds: 5));
  return _TestClient(socket, messages.stream);
}

class _TestClient {
  _TestClient(this._socket, this.messages);
  final Socket _socket;
  final Stream<RemoteMessage> messages;

  void send(RemoteMessage m) =>
      _socket.add(utf8.encode(const RemoteMessageCodec().encode(m)));
}

/// Túnel que só registra o que lhe pediram — o que interessa é PARA ONDE o
/// driver aponta depois, não abrir SSH de verdade.
class _SpyTunnel implements SshTunnel {
  _SpyTunnel({this.failure});
  final SshTunnelException? failure;
  final requests = <String>[];

  @override
  Future<TunnelEndpoint> ensure(
    SshTunnelConfig config, {
    required String targetHost,
    required int targetPort,
    String? passphrase,
    HostKeyPrompt? onUnknownHostKey,
  }) async {
    if (failure != null) throw failure!;
    requests.add('${config.endpoint} -> $targetHost:$targetPort');
    return const TunnelEndpoint('127.0.0.1', 55432);
  }

  @override
  Future<TunnelEndpoint> ensureSocks(
    SshTunnelConfig config, {
    String? passphrase,
    HostKeyPrompt? onUnknownHostKey,
  }) async {
    if (failure != null) throw failure!;
    requests.add('${config.endpoint} -> socks');
    return const TunnelEndpoint('127.0.0.1', 51080);
  }

  @override
  Future<void> closeAll() async {}
}

class _FakeTerminals implements TerminalService {
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Fake implements FileService, GitService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
