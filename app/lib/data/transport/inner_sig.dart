// Inner-envelope Ed25519 signature verification (security fix 2026-08, plan/130).
//
// Extracted from `ws_transport.dart` (bug 2026-08-20) so the verification
// semantics are unit-testable WITHOUT a live WebSocket — the regression that
// motivated the extraction: `_verifyInboundEnvelope` hashed the PI's pubkey
// as the v2 `dest` instead of this device's own, so every Pi→app frame
// failed verification and `pair_ok` was silently dropped ("Pairing timed
// out" on the phone while the Pi logged "Paired with Android device").
//
// Wire contract (MUST match pi-extension `src/transport/inner_sig.ts`):
//   v1: Ed25519("piper/inner/v1\n" + ct)                 — sender-bound
//   v2: Ed25519("piper/inner/v2\n" + dest + "\n" + ts + "\n" + ct)
//       — dest = RECIPIENT's standard-base64 pubkey (this device's own),
//         ts = sender epoch-ms bounded by [kInnerSigMaxAgeMs].
//
// Dual-sig dispatch (PR #25): a frame carrying `sig2` is verified STRICTLY
// as v2 (no v1 fallback — legit senders always produce both); `sig`-only
// frames are the v1 transition path, dropped when the sender has already
// demonstrated v2 (downgrade-strip defense).

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// v1 domain prefix — MUST match `DOMAIN_PREFIX` in pi-extension. @deprecated v2
const String kInnerSigDomain = 'piper/inner/v1\n';

/// v2 domain prefix — MUST match `DOMAIN_PREFIX_V2` in pi-extension.
const String kInnerSigDomainV2 = 'piper/inner/v2\n';

/// Replay freshness window — MUST match `MAX_AGE_MS` in pi-extension
/// (10 minutes; generous for phone ↔ PC clock skew).
const int kInnerSigMaxAgeMs = 10 * 60 * 1000;

/// Outcome of [verifyInboundInnerSig].
class InnerSigVerdict {
  /// Frame is authentic under the dual-sig policy.
  final bool ok;

  /// A VALID v2 signature was seen — the caller should mark the sender
  /// v2-capable so later v1-only frames are treated as downgrade strips.
  final bool v2Verified;

  const InnerSigVerdict._({required this.ok, this.v2Verified = false});
}

/// A function verifying an Ed25519 signature — injectable so production
/// transports can route crypto to a background isolate (Ed25519Worker,
/// perf 2026-08-20) while tests keep the pure in-process implementation.
typedef Ed25519VerifyFn = Future<bool> Function(
  Uint8List publicKey,
  Uint8List data,
  Uint8List signature,
);

Future<bool> _defaultVerify(Uint8List publicKey, Uint8List data, Uint8List signature) async {
  try {
    return await Ed25519().verify(
      data,
      signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
    );
  } catch (_) {
    return false;
  }
}

/// Verifies one inbound outer-envelope payload.
///
/// [senderPubkeyB64] — the PAIRED Pi's pubkey (relay-asserted `peer`).
/// [ownPubkeyB64] — THIS device's own pubkey: the v2 `dest` binding. The
///   sender signs Pi→app frames with dest = the RECIPIENT's key, so the
///   recipient must hash ITS OWN key, never the sender's (bug 2026-08-20).
/// [senderV2Capable] — the sender previously demonstrated v2 (in-memory
///   ratchet); v1-only frames from such a sender are downgrade strips.
/// [nowMs] — injectable clock for the freshness window (tests).
Future<InnerSigVerdict> verifyInboundInnerSig({
  required String senderPubkeyB64,
  required String ownPubkeyB64,
  required String ct,
  required String sigB64,
  String? sig2B64,
  Object? tsRaw,
  bool senderV2Capable = false,
  int? nowMs,
  Ed25519VerifyFn? verifyFn,
}) async {
  final verify = verifyFn ?? _defaultVerify;
  try {
    // Decode validity check: an unparseable sender key throws → false.
    b64DecodeFlexible(senderPubkeyB64);

    if (sig2B64 != null && sig2B64.isNotEmpty) {
      if (tsRaw is! num || tsRaw.toInt() != tsRaw) {
        return const InnerSigVerdict._(ok: false);
      }
      final ts = tsRaw.toInt();
      final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
      if ((now - ts).abs() > kInnerSigMaxAgeMs) {
        return const InnerSigVerdict._(ok: false); // stale replay
      }
      final ok = await verify(
        // dest = OUR OWN pubkey — the sender signed the frame as being for
        // the recipient (this device), not for itself.
        b64DecodeFlexible(senderPubkeyB64),
        utf8.encode('$kInnerSigDomainV2$ownPubkeyB64\n$ts\n$ct'),
        b64DecodeFlexible(sig2B64),
      );
      return InnerSigVerdict._(ok: ok, v2Verified: ok);
    }

    if (senderV2Capable) {
      // v1-only from a v2-capable sender — the relay stripped `sig2`.
      return const InnerSigVerdict._(ok: false);
    }

    final ok = await verify(
      b64DecodeFlexible(senderPubkeyB64),
      utf8.encode('$kInnerSigDomain$ct'),
      b64DecodeFlexible(sigB64),
    );
    return InnerSigVerdict._(ok: ok);
  } catch (_) {
    return const InnerSigVerdict._(ok: false);
  }
}

/// Decodes standard or url-safe base64 (pads defensively) — peer handles may
/// arrive in either spelling (QR/storage use base64url, the relay registry
/// uses standard base64).
Uint8List b64DecodeFlexible(String s) {
  final pad = (4 - s.length % 4) % 4;
  final padded = s + '=' * pad;
  try {
    return base64.decode(padded);
  } on FormatException {
    return base64Url.decode(padded);
  }
}
