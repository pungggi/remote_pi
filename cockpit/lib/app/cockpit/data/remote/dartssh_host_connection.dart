import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// Decide se a host key apresentada por um destino é aceita. Recebe o
/// fingerprint textual do `dartssh2`; `false` = recusa (a conexão falha com
/// `ssh_host_key_changed`). A política (TOFU + Keychain) vive fora desta
/// classe — ela precisa de plugin Flutter, e esta classe roda também numa
/// isolate secundária, onde plugin não existe. Ver [SshWorkerConnection].
typedef HostKeyVerifier = Future<bool> Function(String fingerprint);

/// Endpoint SSH parseado de um `sshTarget` (`user@host[:port]`).
class SshEndpoint {
  const SshEndpoint(this.user, this.host, this.port);
  final String user;
  final String host;
  final int port;

  /// Parseia `user@host`, `user@host:port` ou `host` (sem user → erro tipado:
  /// no mobile não há usuário do SO pra assumir).
  static SshEndpoint parse(String target) {
    final trimmed = target.trim();
    final at = trimmed.indexOf('@');
    if (at <= 0) {
      throw const DartSshException('ssh_target_no_user');
    }
    final user = trimmed.substring(0, at);
    var rest = trimmed.substring(at + 1);
    var port = 22;
    final colon = rest.lastIndexOf(':');
    if (colon > 0) {
      final maybePort = int.tryParse(rest.substring(colon + 1));
      if (maybePort != null) {
        port = maybePort;
        rest = rest.substring(0, colon);
      }
    }
    if (rest.isEmpty) throw const DartSshException('ssh_target_no_host');
    return SshEndpoint(user, rest, port);
  }

  String get endpoint => '$host:$port';
}

/// Falha tipada do transporte dartssh2 (a frase nasce na UI; `detail` é texto
/// cru: stderr do host, fingerprint).
class DartSshException implements Exception {
  const DartSshException(this.code, [this.detail]);
  final String code;
  final String? detail;

  @override
  String toString() => 'DartSshException($code: $detail)';
}

/// Conexão SSH em Dart puro (`dartssh2`) para o **mobile** (plano 59): autentica
/// com a chave do dispositivo (PEM em [identityPems]) ou senha, e encaminha pro
/// socket do `cockpit-server` remoto via `forwardLocalUnix`/`forwardLocal`.
///
/// **Sem dependência de plugin Flutter** — de propósito: toda a criptografia
/// do `dartssh2` (AES-CTR + HMAC, Dart puro via pointycastle) roda na isolate
/// que instancia esta classe, pacote por pacote. Na isolate principal isso
/// congelava a view do iPad/Android a cada rajada de saída de PTY. Por isso o
/// connector a instancia dentro de um [SshWorkerConnection] (isolate própria)
/// e só bytes em claro atravessam pra UI. Chave privada e política de host key
/// chegam por parâmetro/callback, resolvidos por quem tem acesso ao Keychain.
class DartSshHostConnection {
  DartSshHostConnection(
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

  /// Senha (auth por senha, plano 60 Wave C). `null` = auth por chave do
  /// dispositivo. Nunca logada; vem do Keychain via o connector.
  final String? _password;

  SSHClient? _client;

  static const _connectTimeout = Duration(seconds: 15);

  Future<void> get done => _client?.done ?? Future<void>.value();

  /// Abre (autentica) a conexão SSH. Idempotente enquanto viva.
  Future<void> connect() async {
    if (_client != null && !_client!.isClosed) return;
    final identities = [
      for (final pem in _identityPems) ...SSHKeyPair.fromPem(pem),
    ];

    String? rejection;
    final SSHClient client;
    try {
      final socket = await _NoDelaySshSocket.connect(
        _endpoint.host,
        _endpoint.port,
        timeout: _connectTimeout,
      );
      client = SSHClient(
        socket,
        username: _endpoint.user,
        // Auth por senha: sem identidades (evita tentar a chave do device e
        // falhar antes de chegar na senha). Auth por chave: identidades do
        // Keychain, sem callback de senha.
        identities: _password != null ? const [] : identities,
        onPasswordRequest: _password != null ? () => _password : null,
        onVerifyHostKey: (type, fingerprint) async {
          final accepted = await _verifyHostKey(utf8.decode(fingerprint));
          if (!accepted) rejection = 'ssh_host_key_changed';
          return accepted;
        },
      );
      // Teto no handshake/auth: o timeout do [SSHSocket.connect] cobre só o
      // connect TCP. Um host que aceita a conexão e não completa a autenticação
      // (rede meia-boca, servidor sobrecarregado) deixaria isto pendurado sem
      // limite, e a UI eternamente em "conectando" — sem falhar nem reagendar.
      await client.authenticated.timeout(
        _connectTimeout,
        onTimeout: () => throw const DartSshException('ssh_auth_timeout'),
      );
    } on DartSshException {
      rethrow;
    } catch (e) {
      throw DartSshException(rejection ?? 'ssh_connect_failed', '$e');
    }
    _client = client;
  }

  /// Encaminha pro socket UNIX remoto (`direct-streamlocal@openssh.com`) e
  /// devolve o canal duplex.
  Future<SSHForwardChannel> forwardUnix(String remoteSocketPath) async {
    final client = _client;
    if (client == null) throw const DartSshException('ssh_not_connected');
    return client
        .forwardLocalUnix(remoteSocketPath)
        .timeout(
          _connectTimeout,
          onTimeout: () => throw const DartSshException('ssh_forward_timeout'),
        );
  }

  /// Encaminha pra uma porta de LOOPBACK remota (`direct-tcpip`) e devolve o
  /// canal duplex.
  ///
  /// É o caminho de host Windows (plano 61): lá o `cockpit-server` não cria
  /// socket UNIX — `dart:io` não tem AF_UNIX no Windows —, escuta em TCP de
  /// loopback e anuncia porta+token num arquivo de rendezvous. O
  /// `forwardLocalUnix` não serve para esse caso.
  Future<SSHForwardChannel> forwardTcp(int port) async {
    final client = _client;
    if (client == null) throw const DartSshException('ssh_not_connected');
    return client
        .forwardLocal('127.0.0.1', port)
        .timeout(
          _connectTimeout,
          onTimeout: () => throw const DartSshException('ssh_forward_timeout'),
        );
  }

  /// Executa um comando no host devolvendo **exit code, stdout e stderr
  /// separados** — o que o dialeto de host (`HostShell`) precisa para decidir
  /// se o comando funcionou.
  ///
  /// Existe porque o `run` do `dartssh2` **mescla stderr no stdout** (o default
  /// é `stderr: true`) e não expõe exit code. Num host Windows isso era veneno:
  /// `uname -sm && printf %s "\$HOME"` falha, o `cmd.exe` responde em DUAS
  /// linhas na stderr ("'uname' não é reconhecido…"), e o probe via `run` lia
  /// aquilo como stdout de duas linhas — exatamente o formato de um POSIX que
  /// respondeu. O host Windows era classificado como POSIX, o forward ia pro
  /// `direct-streamlocal` de um socket que não existe, e o erro chegava como
  /// `SSHChannelOpenError(2: open failed)`.
  Future<(int, String, String)> runDetailed(String command) async {
    final client = _client;
    if (client == null) throw const DartSshException('ssh_not_connected');
    final result = await client
        .runWithResult(command)
        .timeout(
          _connectTimeout,
          onTimeout: () => throw const DartSshException('ssh_exec_timeout'),
        );
    // Tolerante pelo mesmo motivo do SshTunnel.capture: host Windows responde
    // na codepage local, e um byte inválido aqui virava FormatException no
    // lugar do erro real.
    return (
      result.exitCode ?? 0,
      utf8.decode(result.stdout, allowMalformed: true),
      utf8.decode(result.stderr, allowMalformed: true),
    );
  }

  /// Executa um comando no host e devolve o stdout (trim). Usado só pra
  /// resolver caminhos (ex.: `$HOME`) — o mobile não faz bootstrap (decisão D).
  Future<String> run(String command) async {
    final client = _client;
    if (client == null) throw const DartSshException('ssh_not_connected');
    // Mesmo motivo do handshake: um exec que não volta pendurava a abertura
    // inteira (este `run` resolve a `$HOME` remota antes do forward).
    final out = await client
        .run(command)
        .timeout(
          _connectTimeout,
          onTimeout: () => throw const DartSshException('ssh_exec_timeout'),
        );
    // Tolerante pelo mesmo motivo do SshTunnel.capture: host Windows responde
    // na codepage local, e um byte inválido aqui virava FormatException no
    // lugar do erro real.
    return utf8.decode(out, allowMalformed: true).trim();
  }

  Future<void> close() async {
    _client?.close();
    _client = null;
  }
}

/// [SSHSocket] sobre o `Socket` do `dart:io` com **`TCP_NODELAY`** ligado.
///
/// O `SSHSocket.connect` do `dartssh2` deixa o Nagle ativo. Com ele, um pacote
/// pequeno (uma tecla, um `pty.ack`) pode ficar retido até o ACK TCP do pacote
/// anterior — dezenas de ms numa rede móvel, sentidos direto no eco da
/// digitação. Terminal interativo é o caso clássico em que Nagle atrapalha.
class _NoDelaySshSocket implements SSHSocket {
  _NoDelaySshSocket._(this._socket);

  final Socket _socket;

  static Future<SSHSocket> connect(
    String host,
    int port, {
    Duration? timeout,
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    return _NoDelaySshSocket._(socket);
  }

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> close() => _socket.close();

  @override
  Future<void> get done => _socket.done;

  @override
  void destroy() => _socket.destroy();

  @override
  Future<void> flush() => _socket.flush();
}
