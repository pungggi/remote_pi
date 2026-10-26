import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cockpit/app/cockpit/data/remote/dartssh_host_connection.dart';
import 'package:cockpit_remote/cockpit_remote.dart';
import 'package:dartssh2/dartssh2.dart';

/// [DartSshHostConnection] rodando numa **isolate própria** (a fachada que o
/// connector usa no mobile).
///
/// Por que existe: o `dartssh2` cifra/decifra cada pacote em Dart puro
/// (pointycastle), síncrono, na isolate que o criou. Na isolate principal, uma
/// rajada de saída de PTY (redraw de TUI, `cat` grande) gastava dezenas de ms
/// por frame só em AES+HMAC, e a view travava — o mesmo tráfego no desktop,
/// pelo binário `ssh`, não custa nada à UI. Aqui o `SSHClient` inteiro vive na
/// isolate worker; pra isolate principal só atravessam **bytes em claro** dos
/// canais encaminhados (via [RemoteDuplex]) e os resultados dos comandos.
///
/// O que NÃO atravessa e fica na principal: Keychain (chave privada lida
/// antes do spawn e enviada em PEM; host key verificada por ida-e-volta de
/// mensagem, porque plugin Flutter não roda em isolate secundária).
///
/// Mesma API do [DartSshHostConnection] — `connect`/`runDetailed`/
/// `forwardUnix`/`forwardTcp`/`done`/`close` — com a diferença de que os
/// forwards devolvem um [RemoteDuplex] pronto em vez de `SSHForwardChannel`.
class SshWorkerConnection {
  SshWorkerConnection(
    this._endpoint, {
    required HostKeyVerifier verifyHostKey,
    List<String> identityPems = const [],
    String? password,
  }) : _verifyHostKey = verifyHostKey, // ignore: prefer_initializing_formals
       _identityPems = identityPems, // ignore: prefer_initializing_formals
       _password = password; // ignore: prefer_initializing_formals

  final SshEndpoint _endpoint;
  final HostKeyVerifier _verifyHostKey;
  final List<String> _identityPems;
  final String? _password;

  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  final _done = Completer<void>();
  bool _closed = false;

  int _nextId = 0;
  final Map<int, Completer<Object?>> _replies = {};
  final Map<int, _IsolateDuplex> _channels = {};

  /// Completa quando a sessão SSH cai (do lado remoto ou por [close]).
  Future<void> get done => _done.future;

  /// Sobe a isolate e autentica. Erros vêm como [DartSshException], iguais aos
  /// da conexão direta — o connector não distingue os dois caminhos.
  Future<void> connect() async {
    if (_toWorker != null) return;
    final fromWorker = ReceivePort();
    _fromWorker = fromWorker;
    final ready = Completer<SendPort>();
    fromWorker.listen((message) => _onWorkerMessage(message, ready));
    try {
      _isolate = await Isolate.spawn(
        _sshWorkerMain,
        _WorkerBootstrap(
          reply: fromWorker.sendPort,
          user: _endpoint.user,
          host: _endpoint.host,
          port: _endpoint.port,
          identityPems: _identityPems,
          password: _password,
        ),
        debugName: 'ssh-worker ${_endpoint.endpoint}',
        errorsAreFatal: true,
      );
    } on Object catch (e) {
      fromWorker.close();
      _fromWorker = null;
      throw DartSshException('ssh_connect_failed', '$e');
    }
    _toWorker = await ready.future;
    await _request(const _Connect());
  }

  Future<(int, String, String)> runDetailed(String command) async {
    final result = await _request(_RunDetailed(command));
    final list = result! as List<Object?>;
    return (list[0]! as int, list[1]! as String, list[2]! as String);
  }

  Future<String> run(String command) async =>
      (await _request(_Run(command)))! as String;

  Future<RemoteDuplex> forwardUnix(String remoteSocketPath) =>
      _forward(_ForwardUnix(remoteSocketPath));

  Future<RemoteDuplex> forwardTcp(int port) => _forward(_ForwardTcp(port));

  Future<RemoteDuplex> _forward(_Request request) async {
    final channelId = (await _request(request))! as int;
    final duplex = _IsolateDuplex(this, channelId);
    _channels[channelId] = duplex;
    return duplex;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _toWorker?.send(const _Close());
    _finish();
  }

  Future<Object?> _request(_Request request) {
    final worker = _toWorker;
    if (worker == null || _closed) {
      throw const DartSshException('ssh_not_connected');
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _replies[id] = completer;
    worker.send(_Envelope(id, request));
    return completer.future;
  }

  void _onWorkerMessage(Object? message, Completer<SendPort> ready) {
    switch (message) {
      case SendPort():
        ready.complete(message);
      case _Reply(:final id, :final value):
        _replies.remove(id)?.complete(value);
      case _Failure(:final id, :final code, :final detail):
        _replies.remove(id)?.completeError(DartSshException(code, detail));
      case _VerifyHostKey(:final id, :final fingerprint):
        _verifyHostKey(fingerprint)
            .then((ok) => _toWorker?.send(_Envelope(id, _HostKeyAnswer(ok))))
            .catchError(
              (Object _) =>
                  _toWorker?.send(_Envelope(id, const _HostKeyAnswer(false))),
            );
      case _ChannelData(:final channel, :final data):
        _channels[channel]?._input.add(data.materialize().asUint8List());
      case _ChannelDone(:final channel):
        _channels.remove(channel)?._complete();
      case _SessionDone():
        _finish();
    }
  }

  void _finish() {
    for (final c in _replies.values) {
      if (!c.isCompleted) {
        c.completeError(const DartSshException('ssh_not_connected'));
      }
    }
    _replies.clear();
    for (final ch in _channels.values) {
      ch._complete();
    }
    _channels.clear();
    _fromWorker?.close();
    _fromWorker = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _toWorker = null;
    if (!_done.isCompleted) _done.complete();
  }
}

/// [RemoteDuplex] de um canal encaminhado que vive na isolate worker: entrada
/// alimentada pelas mensagens `_ChannelData`; saída enviada como
/// [TransferableTypedData] (sem cópia).
class _IsolateDuplex implements RemoteDuplex {
  _IsolateDuplex(this._owner, this._channel);

  final SshWorkerConnection _owner;
  final int _channel;
  final _input = StreamController<Uint8List>();
  final _done = Completer<void>();

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  void add(List<int> bytes) {
    final worker = _owner._toWorker;
    if (worker == null) return;
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    worker.send(_ChannelData(_channel, TransferableTypedData.fromList([data])));
  }

  @override
  Future<void> get done => _done.future;

  @override
  void destroy() {
    _owner._toWorker?.send(_ChannelDestroy(_channel));
    _owner._channels.remove(_channel);
    _complete();
  }

  void _complete() {
    if (!_input.isClosed) _input.close();
    if (!_done.isCompleted) _done.complete();
  }
}

// ---------------------------------------------------------------------------
// Protocolo main <-> worker. Tudo aqui é enviável por SendPort (campos
// primitivos/imutáveis).
// ---------------------------------------------------------------------------

class _WorkerBootstrap {
  const _WorkerBootstrap({
    required this.reply,
    required this.user,
    required this.host,
    required this.port,
    required this.identityPems,
    required this.password,
  });
  final SendPort reply;
  final String user;
  final String host;
  final int port;
  final List<String> identityPems;
  final String? password;
}

sealed class _Request {
  const _Request();
}

class _Connect extends _Request {
  const _Connect();
}

class _RunDetailed extends _Request {
  const _RunDetailed(this.command);
  final String command;
}

class _Run extends _Request {
  const _Run(this.command);
  final String command;
}

class _ForwardUnix extends _Request {
  const _ForwardUnix(this.path);
  final String path;
}

class _ForwardTcp extends _Request {
  const _ForwardTcp(this.port);
  final int port;
}

class _HostKeyAnswer extends _Request {
  const _HostKeyAnswer(this.accepted);
  final bool accepted;
}

class _Close {
  const _Close();
}

class _Envelope {
  const _Envelope(this.id, this.request);
  final int id;
  final _Request request;
}

class _Reply {
  const _Reply(this.id, this.value);
  final int id;
  final Object? value;
}

class _Failure {
  const _Failure(this.id, this.code, this.detail);
  final int id;
  final String code;
  final String? detail;
}

class _VerifyHostKey {
  const _VerifyHostKey(this.id, this.fingerprint);
  final int id;
  final String fingerprint;
}

class _ChannelData {
  const _ChannelData(this.channel, this.data);
  final int channel;
  final TransferableTypedData data;
}

class _ChannelDone {
  const _ChannelDone(this.channel);
  final int channel;
}

class _ChannelDestroy {
  const _ChannelDestroy(this.channel);
  final int channel;
}

class _SessionDone {
  const _SessionDone();
}

// ---------------------------------------------------------------------------
// Lado worker.
// ---------------------------------------------------------------------------

Future<void> _sshWorkerMain(_WorkerBootstrap boot) async {
  final reply = boot.reply;
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);

  final hostKeyAnswers = <int, Completer<bool>>{};
  var nextHostKeyId = 0;
  // Canais encaminhados vivem aqui; a principal só conhece o id numérico.
  final channels = <int, SSHForwardChannel>{};
  var nextChannel = 0;

  final conn = DartSshHostConnection(
    SshEndpoint(boot.user, boot.host, boot.port),
    identityPems: boot.identityPems,
    password: boot.password,
    verifyHostKey: (fingerprint) {
      final id = nextHostKeyId++;
      final completer = Completer<bool>();
      hostKeyAnswers[id] = completer;
      reply.send(_VerifyHostKey(id, fingerprint));
      return completer.future;
    },
  );

  Future<Object?> handle(_Request request) async {
    switch (request) {
      case _Connect():
        await conn.connect();
        unawaited(conn.done.then((_) => reply.send(const _SessionDone())));
        return null;
      case _RunDetailed(:final command):
        final (code, out, err) = await conn.runDetailed(command);
        return [code, out, err];
      case _Run(:final command):
        return conn.run(command);
      case _ForwardUnix(:final path):
        return conn.forwardUnix(path);
      case _ForwardTcp(:final port):
        return conn.forwardTcp(port);
      case _HostKeyAnswer():
        return null; // tratado no dispatcher abaixo
    }
  }

  await for (final message in inbox) {
    switch (message) {
      case _Envelope(:final id, request: _HostKeyAnswer(:final accepted)):
        hostKeyAnswers.remove(id)?.complete(accepted);
      case _Envelope(:final id, :final request):
        unawaited(
          handle(request).then(
            (value) {
              if (value is SSHForwardChannel) {
                final channelId = nextChannel++;
                channels[channelId] = value;
                value.stream.listen(
                  (data) => reply.send(
                    _ChannelData(
                      channelId,
                      TransferableTypedData.fromList([data]),
                    ),
                  ),
                  onDone: () {
                    channels.remove(channelId);
                    reply.send(_ChannelDone(channelId));
                  },
                  onError: (Object _) {
                    channels.remove(channelId);
                    reply.send(_ChannelDone(channelId));
                  },
                );
                reply.send(_Reply(id, channelId));
              } else {
                reply.send(_Reply(id, value));
              }
            },
            onError: (Object e) {
              if (e is DartSshException) {
                reply.send(_Failure(id, e.code, e.detail));
              } else {
                reply.send(_Failure(id, 'ssh_connect_failed', '$e'));
              }
            },
          ),
        );
      case _ChannelData(:final channel, :final data):
        channels[channel]?.sink.add(data.materialize().asUint8List());
      case _ChannelDestroy(:final channel):
        channels.remove(channel)?.destroy();
      case _Close():
        for (final ch in channels.values) {
          ch.destroy();
        }
        channels.clear();
        await conn.close();
        inbox.close();
        reply.send(const _SessionDone());
    }
  }
}
