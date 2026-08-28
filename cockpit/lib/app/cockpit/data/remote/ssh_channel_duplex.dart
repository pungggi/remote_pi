import 'dart:typed_data';

import 'package:cockpit_remote/cockpit_remote.dart';
import 'package:dartssh2/dartssh2.dart';

/// [RemoteDuplex] sobre um canal `forwardLocalUnix` do `dartssh2` (plano 59):
/// o transporte do **mobile**. O `SSHForwardChannel` encaminha bytes pro socket
/// UNIX remoto (`~/.cockpit/cockpit-server.sock`) via
/// `direct-streamlocal@openssh.com` — sem socket local, sem binário `ssh`.
///
/// Mantém o `cockpit_remote` livre de `dartssh2`: o adapter vive aqui na
/// camada `data/` do app.
class SshChannelDuplex implements RemoteDuplex {
  SshChannelDuplex(this._channel);

  final SSHForwardChannel _channel;

  @override
  Stream<Uint8List> get input => _channel.stream;

  @override
  void add(List<int> bytes) => _channel.sink.add(bytes);

  @override
  Future<void> get done => _channel.done;

  @override
  void destroy() => _channel.destroy();
}
