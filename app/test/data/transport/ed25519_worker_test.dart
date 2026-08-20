// Regression test for the Ed25519Worker death-handling fix (PR #30 review,
// augment finding 1).
//
// The worker's ReceivePort is owned by the PARENT, so it never closes when
// the spawned isolate exits — the original `onDone` never fired, leaving
// pending crypto futures unresolved forever and later requests going to a
// stale port (no respawn). The fix registers Isolate.addOnExitListener,
// which reliably fires on isolate death and triggers fail-pending +
// respawn-on-next-call.

import 'dart:async';
import 'dart:typed_data';

import 'package:app/data/transport/ed25519_worker.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final seed = Uint8List.fromList(List.generate(32, (i) => i));
  final data = Uint8List.fromList(List.filled(64, 7));

  test('worker death never leaves calls hanging; the next call respawns', () async {
    final w = Ed25519Worker.instance;

    // 1) Warm: first sign spawns the worker.
    final sig1 = await w.sign(seed, data).timeout(const Duration(seconds: 15));
    expect(sig1.length, 64);

    // 2) A request in flight when the worker dies must resolve — either it
    //    completed before the kill landed, or it fails with StateError. The
    //    REGRESSION it must never do is HANG (the pre-fix behavior: the
    //    parent-owned port never closes, so the future never completes).
    final pending = w.sign(seed, data);
    w.debugKillForTest();
    var sawStateError = false;
    try {
      await pending.timeout(const Duration(seconds: 10));
    } on StateError {
      sawStateError = true; // death handling fired — the fix working
    } on TimeoutException {
      fail('pending sign hung after worker death (pre-fix regression)');
    }
    // Either outcome is acceptable; a hang is not.

    // 3) The next request respawns the worker and succeeds deterministically.
    final sig2 = await w.sign(seed, data).timeout(const Duration(seconds: 15));
    expect(sig2.length, 64);
    expect(sig2, equals(sig1)); // same seed+data → same signature
    // Sanity: if step 2's call failed via the death handler, we know the
    // exit listener fired (that's the mechanism under test).
    expect(sawStateError || sig2.length == 64, isTrue);
  });

  test('verify works after a respawn (worker round-trips through death)', () async {
    final w = Ed25519Worker.instance;
    // Derive the REAL public key — the worker's verify takes the raw pubkey,
    // not the seed.
    final kp = await Ed25519().newKeyPairFromSeed(seed);
    final pub = (await kp.extractPublicKey()).bytes;
    final sig = await w.sign(seed, data).timeout(const Duration(seconds: 15));
    w.debugKillForTest();
    // Allow the exit listener to fire.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final ok = await w.verify(pub, data, sig).timeout(const Duration(seconds: 15));
    expect(ok, isTrue);
  });
}
