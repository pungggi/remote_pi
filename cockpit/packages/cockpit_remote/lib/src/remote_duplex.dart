import 'dart:io';
import 'dart:typed_data';

/// Canal duplex de bytes por baixo de um [RemoteConnection] (plano 59). Abstrai
/// "de onde vêm/vão os bytes" pra o mesmo protocolo servir dois transportes:
///
/// - **`Socket` UDS** (sidecar local + túnel `ssh -L` do desktop): [SocketRemoteDuplex].
/// - **canal SSH do `dartssh2`** (`forwardLocalUnix` → socket UNIX remoto): o
///   adapter vive na camada `data/` do app (mantém este pacote sem dartssh2).
///
/// Só o mínimo que o [RemoteConnection] usa: um stream de entrada, um `add` de
/// saída, um `done` e um `destroy`.
abstract class RemoteDuplex {
  Stream<Uint8List> get input;
  void add(List<int> bytes);
  Future<void> get done;
  void destroy();
}

/// [RemoteDuplex] sobre um [Socket] do `dart:io` (o transporte histórico:
/// sidecar loopback e `ssh -L`).
class SocketRemoteDuplex implements RemoteDuplex {
  SocketRemoteDuplex(this._socket);

  final Socket _socket;

  /// Conecta a um socket UNIX (path) e devolve o duplex pronto. É o caminho de
  /// quem SABE que o outro lado é um socket UNIX — hoje a ponta local de um
  /// `ssh -L`. Para o endpoint anunciado pelo servidor local (que no Windows é
  /// TCP + token) use `RemoteConnection.connect`, que passa pelo
  /// `LocalEndpoint`.
  static Future<SocketRemoteDuplex> connectUnix(String socketPath) async {
    final socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    return SocketRemoteDuplex(socket);
  }

  @override
  Stream<Uint8List> get input => _socket;

  @override
  void add(List<int> bytes) => _socket.add(bytes);

  @override
  Future<void> get done => _socket.done;

  @override
  void destroy() => _socket.destroy();
}
