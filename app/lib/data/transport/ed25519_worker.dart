// Long-lived background isolate for Ed25519 sign/verify (perf fix 2026-08-20).
//
// package:cryptography's Ed25519 is a PURE-DART implementation — every
// sign/verify runs on the calling isolate. The transport signs EVERY
// outbound frame twice (dual-sig v1+v2, plan/130) and verifies EVERY
// inbound frame; during agent-chunk bursts / session syncs that stole
// the UI isolate for hundreds of milliseconds per second (123% CPU,
// p95 frame 550 ms, p99 1250 ms — measured on a Z Fold4) and made the
// app feel frozen while switching cards.
//
// This worker owns ALL per-frame crypto: the UI isolate sends byte
// payloads over a SendPort and awaits the result. Copies are cheap
// relative to the scalar mults; the UI thread never runs curve math.

import 'dart:async';
import 'dart:isolate';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// A single long-lived Ed25519 worker isolate.
///
/// Lazily spawned on first use; survives for the process lifetime.
/// All methods are safe to call concurrently — requests are correlated
/// by id. If the isolate dies (OOM kill, platform teardown) pending
/// calls fail and the next call respawns it.
class Ed25519Worker {
  Ed25519Worker._();

  /// Process-wide instance.
  static final Ed25519Worker instance = Ed25519Worker._();

  Isolate? _isolate;
  SendPort? _sendPort;
  Completer<void>? _ready;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  int _nextId = 0;

  /// Signs [data] with the Ed25519 key whose seed is [seed] (32 bytes).
  Future<Uint8List> sign(List<int> seed, List<int> data) async {
    final m = await _request({
      'op': 'sign',
      'seed': seed is Uint8List ? seed : Uint8List.fromList(seed),
      'data': data is Uint8List ? data : Uint8List.fromList(data),
    });
    return m['sig'] as Uint8List;
  }

  /// Verifies [signature] over [data] with the raw Ed25519 public key [publicKey].
  Future<bool> verify(List<int> publicKey, List<int> data, List<int> signature) async {
    final m = await _request({
      'op': 'verify',
      'pub': publicKey is Uint8List ? publicKey : Uint8List.fromList(publicKey),
      'data': data is Uint8List ? data : Uint8List.fromList(data),
      'sig': signature is Uint8List ? signature : Uint8List.fromList(signature),
    });
    return m['verified'] as bool;
  }

  Future<Map<String, dynamic>> _request(Map<String, dynamic> req) async {
    await _ensureSpawned();
    final id = _nextId++;
    req['id'] = id;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _sendPort!.send(req);
    return completer.future;
  }

  Future<void> _ensureSpawned() async {
    if (_isolate != null && _ready != null) {
      await _ready!.future;
      return;
    }
    final ready = Completer<void>();
    _ready = ready;

    final rcv = ReceivePort();
    rcv.listen(
      (msg) {
        if (msg is SendPort) {
          _sendPort = msg;
          if (!ready.isCompleted) ready.complete();
          return;
        }
        if (msg is Map) {
          final completer = _pending.remove(msg['id']);
          if (completer == null) return;
          if (msg['ok'] == true) {
            completer.complete(Map<String, dynamic>.from(msg));
          } else {
            completer.completeError(
              StateError('ed25519 worker: ${msg['error']}'),
            );
          }
        }
      },
      onDone: _onWorkerDied, // worker isolate died → port closes
    );

    try {
      _isolate = await Isolate.spawn(
        _workerMain,
        rcv.sendPort,
        debugName: 'ed25519-worker',
        errorsAreFatal: true,
      );
      // Review fix (PR #30, augment finding 1): a PARENT-owned ReceivePort
      // never closes when the spawned isolate exits — `rcv.onDone` would
      // never fire and worker death would leave pending futures hanging
      // forever, with later requests sent to a stale port. addOnExitListener
      // is the reliable signal: it fires when the isolate terminates for ANY
      // reason, letting _onWorkerDied fail pending calls + clear state so the
      // next request respawns the worker.
      final exitPort = ReceivePort();
      _isolate!.addOnExitListener(exitPort.sendPort);
      exitPort.listen((_) {
        exitPort.close();
        if (_isolate != null) _onWorkerDied();
      });
    } catch (e) {
      _isolate = null;
      _ready = null;
      rcv.close();
      if (!ready.isCompleted) ready.completeError(e);
      rethrow;
    }
    await ready.future;
  }

  /// Test-only: kills the worker isolate so death handling can be verified
  /// (PR #30 review: respawn-after-death regression).
  @visibleForTesting
  void debugKillForTest() {
    _isolate?.kill(priority: Isolate.immediate);
  }

  void _onWorkerDied() {
    _isolate = null;
    _sendPort = null;
    _ready = null;
    final pending = List.of(_pending.values);
    _pending.clear();
    for (final c in pending) {
      c.completeError(StateError('ed25519 worker isolate died'));
    }
  }
}

/// Isolate entrypoint — must be top-level for Isolate.spawn.
void _workerMain(SendPort sendPort) {
  final rcv = ReceivePort();
  sendPort.send(rcv.sendPort);
  final algo = Ed25519();
  rcv.listen((msg) async {
    final m = msg as Map;
    final id = m['id'];
    try {
      if (m['op'] == 'sign') {
        final kp = await algo.newKeyPairFromSeed(m['seed'] as List<int>);
        final sig = await algo.sign(m['data'] as List<int>, keyPair: kp);
        sendPort.send({'id': id, 'ok': true, 'sig': sig.bytes});
      } else if (m['op'] == 'verify') {
        final ok = await algo.verify(
          m['data'] as List<int>,
          signature: Signature(
            m['sig'] as List<int>,
            publicKey: SimplePublicKey(
              m['pub'] as List<int>,
              type: KeyPairType.ed25519,
            ),
          ),
        );
        sendPort.send({'id': id, 'ok': true, 'verified': ok});
      } else {
        sendPort.send({'id': id, 'ok': false, 'error': 'unknown op ${m['op']}'});
      }
    } catch (e) {
      sendPort.send({'id': id, 'ok': false, 'error': '$e'});
    }
  });
}
