// Regression tests for inbound dual-sig verification (bug 2026-08-20).
//
// The bug: WsTransport._verifyInboundEnvelope hashed the PI's pubkey as the
// v2 `dest`. The Pi signs Pi→app frames with dest = the RECIPIENT's (phone's)
// pubkey, so every inbound v2 frame failed verification and `pair_ok` was
// silently dropped — "Pairing timed out" on the phone while the Pi logged
// "Paired with Android device".
//
// These tests sign frames exactly the way pi-extension
// `src/transport/inner_sig.ts` does (same domains, same byte layout) and
// verify them through the extracted pure function, so any future drift in
// either the crypto layout or the dest handling fails here instead of on a
// physical phone.

import 'dart:convert';

import 'package:app/data/transport/inner_sig.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

/// Signs like pi-extension `signInnerCt` (v1, sender-bound).
Future<String> signV1(SimpleKeyPair sk, String ct) async {
  final sig = await Ed25519()
      .sign(utf8.encode('$kInnerSigDomain$ct'), keyPair: sk);
  return base64.encode(sig.bytes);
}

/// Signs like pi-extension `signInnerCtV2` (v2, dest-bound + ts).
Future<String> signV2(SimpleKeyPair sk, String destB64, int ts, String ct) async {
  final sig = await Ed25519()
      .sign(utf8.encode('$kInnerSigDomainV2$destB64\n$ts\n$ct'), keyPair: sk);
  return base64.encode(sig.bytes);
}

Future<String> pubB64(SimpleKeyPair kp) async =>
    base64.encode((await kp.extractPublicKey()).bytes);

void main() {
  late SimpleKeyPair piKey; // sender (the PC)
  late SimpleKeyPair phoneKey; // recipient (this device)
  late String piPub;
  late String phonePub;
  const ct = 'eyJ0eXBlIjoicGFpcl9vayIsImlkIjoiYWJjIn0='; // base64 JSON
  final now = DateTime.now().millisecondsSinceEpoch;

  setUp(() async {
    piKey = await Ed25519().newKeyPair();
    phoneKey = await Ed25519().newKeyPair();
    piPub = await pubB64(piKey);
    phonePub = await pubB64(phoneKey);
  });

  test('v2 frame from Pi with dest=phone verifies against the PHONE key', () async {
    // THE regression: the Pi signed with dest = the recipient's pubkey, so
    // verification must hash the recipient's own key — not the sender's.
    final sig2 = await signV2(piKey, phonePub, now, ct);
    final sig1 = await signV1(piKey, ct);
    final v = await verifyInboundInnerSig(
      senderPubkeyB64: piPub,
      ownPubkeyB64: phonePub,
      ct: ct,
      sigB64: sig1,
      sig2B64: sig2,
      tsRaw: now,
      nowMs: now,
    );
    expect(v.ok, isTrue, reason: 'legit Pi→phone frame must verify');
    expect(v.v2Verified, isTrue, reason: 'valid sig2 marks the sender v2');
  });

  test('REGRESSION: hashing the SENDER key as dest fails (the 2026-08-20 bug)', () async {
    final sig2 = await signV2(piKey, phonePub, now, ct);
    final v = await verifyInboundInnerSig(
      senderPubkeyB64: piPub,
      // Bug behavior: ownPubkeyB64 = the PI's key. Must NOT verify, because
      // the signature covers the phone's key as dest.
      ownPubkeyB64: piPub,
      ct: ct,
      sigB64: '',
      sig2B64: sig2,
      tsRaw: now,
      nowMs: now,
    );
    expect(v.ok, isFalse,
        reason: 'a call site passing the sender key as dest must fail loudly');
  });

  test('v2 frame signed for a DIFFERENT recipient fails (cross-peer redirect)', () async {
    final otherKey = await Ed25519().newKeyPair();
    final otherPub = await pubB64(otherKey);
    final sig2 = await signV2(piKey, otherPub, now, ct);
    final v = await verifyInboundInnerSig(
      senderPubkeyB64: piPub,
      ownPubkeyB64: phonePub,
      ct: ct,
      sigB64: '',
      sig2B64: sig2,
      tsRaw: now,
      nowMs: now,
    );
    expect(v.ok, isFalse, reason: 'dest binding must reject redirected frames');
  });

  test('stale v2 frame (outside the 10-min window) fails', () async {
    final staleTs = now - kInnerSigMaxAgeMs - 1000;
    final sig2 = await signV2(piKey, phonePub, staleTs, ct);
    final v = await verifyInboundInnerSig(
      senderPubkeyB64: piPub,
      ownPubkeyB64: phonePub,
      ct: ct,
      sigB64: '',
      sig2B64: sig2,
      tsRaw: staleTs,
      nowMs: now,
    );
    expect(v.ok, isFalse, reason: 'captured frame replayed later must fail');
  });

  test('tampered ct fails v2 verification', () async {
    final sig2 = await signV2(piKey, phonePub, now, ct);
    final v = await verifyInboundInnerSig(
      senderPubkeyB64: piPub,
      ownPubkeyB64: phonePub,
      ct: ct.replaceRange(0, 1, 'Z'),
      sigB64: '',
      sig2B64: sig2,
      tsRaw: now,
      nowMs: now,
    );
    expect(v.ok, isFalse);
  });

  test('v1-only frame from a pre-v2 sender verifies (transition)', () async {
    final sig1 = await signV1(piKey, ct);
    final v = await verifyInboundInnerSig(
      senderPubkeyB64: piPub,
      ownPubkeyB64: phonePub,
      ct: ct,
      sigB64: sig1,
      nowMs: now,
    );
    expect(v.ok, isTrue);
    expect(v.v2Verified, isFalse, reason: 'v1 must not mark the sender v2');
  });

  test('v1-only frame from a v2-capable sender fails (downgrade strip)', () async {
    final sig1 = await signV1(piKey, ct);
    final v = await verifyInboundInnerSig(
      senderPubkeyB64: piPub,
      ownPubkeyB64: phonePub,
      ct: ct,
      sigB64: sig1,
      senderV2Capable: true,
      nowMs: now,
    );
    expect(v.ok, isFalse);
  });

  test('non-numeric ts with sig2 fails', () async {
    final sig2 = await signV2(piKey, phonePub, now, ct);
    final v = await verifyInboundInnerSig(
      senderPubkeyB64: piPub,
      ownPubkeyB64: phonePub,
      ct: ct,
      sigB64: '',
      sig2B64: sig2,
      tsRaw: '$now',
      nowMs: now,
    );
    expect(v.ok, isFalse);
  });

  test('dest spelling must match between signer and verifier', () async {
    // The v2 dest goes into the hashed bytes VERBATIM — a sender that signs
    // with the standard spelling and a recipient hashing its url-safe
    // spelling (or vice versa) must NOT verify. Production code avoids this
    // by normalizing to standard base64 at connect (`_ownPubkeyB64 =
    // base64.encode(pub.bytes)` on the app; the Pi signs with the relay-
    // asserted standard peer id).
    //
    // Pick a key whose standard spelling actually differs when re-spelled
    // url-safe — a random key has ~26% chance of containing no '+'/'/'
    // (the two spellings then coincide and the test vacuously passes).
    late String phonePubPunct;
    late String phoneUrl;
    for (var i = 0;; i++) {
      final kp = await Ed25519().newKeyPair();
      final pub = base64.encode((await kp.extractPublicKey()).bytes);
      if (pub.contains('+') || pub.contains('/')) {
        phonePubPunct = pub;
        phoneUrl = pub.replaceAll('+', '-').replaceAll('/', '_');
        break;
      }
    }
    expect(phoneUrl, isNot(phonePubPunct)); // sanity: spellings differ

    final sig2 = await signV2(piKey, phonePubPunct, now, ct);
    final v = await verifyInboundInnerSig(
      senderPubkeyB64: piPub,
      ownPubkeyB64: phoneUrl,
      ct: ct,
      sigB64: '',
      sig2B64: sig2,
      tsRaw: now,
      nowMs: now,
    );
    expect(v.ok, isFalse,
        reason: 'different dest spelling = different signed bytes');

    // Signing and verifying with the SAME url-safe spelling works.
    final sig2Url = await signV2(piKey, phoneUrl, now, ct);
    final v2 = await verifyInboundInnerSig(
      senderPubkeyB64: piPub,
      ownPubkeyB64: phoneUrl,
      ct: ct,
      sigB64: '',
      sig2B64: sig2Url,
      tsRaw: now,
      nowMs: now,
    );
    expect(v2.ok, isTrue);
  });
}
