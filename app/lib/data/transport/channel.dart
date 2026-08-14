import 'package:app/protocol/protocol.dart';

/// Abstract channel — testable interface over [PlainPeerChannel].
abstract class IChannel {
  Stream<ServerMessage> get serverMessages;
  Future<void> send(ClientMessage msg);
  Future<void> close();
}

/// Optional capability mixed into a channel that also speaks raw relay
/// control frames (subscribe_presence, peer_online, etc — see plano 12).
/// ConnectionManager does an `is IControlLink` cast to drive presence;
/// channels that don't implement it simply skip the subsystem.
abstract class IControlLink {
  Stream<ControlInbound> get controlFrames;
  void sendControl(Map<String, dynamic> json);
}

/// Optional capability — the channel's transport knows whether the
/// connection is confidentiality-protected (`wss://`/`https://` or a
/// loopback host). Security fix 2026-08 (H2): drives the persistent
/// insecure-transport banner on Home. Non-WS transports (tests, in-memory
/// pipes) don't implement it and default to secure via the forwarding in
/// `PlainPeerChannel`.
abstract class ITransportSecurityInfo {
  bool get isTransportSecure;
}
