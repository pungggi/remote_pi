import 'dart:async';

import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:flutter/foundation.dart';

import 'mesh_blob.dart';
import 'mesh_client.dart';
import 'mesh_envelope.dart';

/// Orchestrates publish + pull-and-apply of the Owner's mesh blob
/// against the relay's `/mesh` endpoint. Sits between the
/// [PairingStorage] (local cache) and the [MeshClient] (network).
///
/// Single source of truth for the Owner's membership is the relay
/// (plan/24); the local storage is a hydrated cache. Mutations:
///   1. write through to local storage immediately (UI responsiveness)
///   2. publish in background; on conflict/failure, the next
///      [pullAndApply] reconciles.
///
/// Reads: [pullOnDemand] runs at boot, WS reconnect, deep links;
/// [startPolling] keeps the cache fresh while the app is in foreground.
class MeshSyncService extends ChangeNotifier {
  final MeshClient _client;
  final OwnerIdentityBridge _ownerBridge;
  final PairingStorage _storage;

  /// Last version we observed locally — used as the `since` query
  /// parameter on subsequent fetches so the relay can short-circuit
  /// to 304. Reset to 0 when the Owner key changes (sync drift).
  int _lastVersion = 0;

  /// True while a publish is in flight. Used by mutation paths to
  /// avoid stampeding the relay; the queued change is picked up by
  /// the next fetch loop instead.
  bool _publishing = false;

  Timer? _pollTimer;
  bool _disposed = false;

  /// Last observed [updatedAt] from the relay. Surfaced so the UI can
  /// render "last synced ... ago" if it wants to.
  int? lastUpdatedAt;

  MeshSyncService(this._client, this._ownerBridge, this._storage);

  int get lastVersion => _lastVersion;

  // -------------------------------------------------------------------------
  // Pull
  // -------------------------------------------------------------------------

  /// One-shot fetch + apply. Called from boot, WS reconnection, deep
  /// links. Returns `true` if the local cache now reflects a
  /// successfully-verified relay version (including 304 "we're up to
  /// date" and 404 "relay never had data"); `false` on failure.
  Future<bool> pullOnDemand() async {
    final pk = _ownerBridge.currentOwnerPk;
    if (pk == null) {
      return false;
    }
    final hash = await MeshClient.ownerPkHash(pk);
    final result = await _client.fetch(
      hash,
      since: _lastVersion > 0 ? _lastVersion : null,
    );
    switch (result) {
      case MeshFetchOk(envelope: final env, version: final v, updatedAt: final u):
        final applied = await _applyVerified(env, expectedOwnerPk: pk);
        if (applied) {
          _lastVersion = v;
          lastUpdatedAt = u;
          notifyListeners();
          return true;
        }
        return false;
      case MeshFetchNotModified():
        return true;
      case MeshFetchNotFound():
        return true;
      case MeshFetchFailure():
        return false;
    }
  }

  /// Verify the envelope, parse, and overwrite the local storage with
  /// the relay's view. Returns `false` when verification fails or the
  /// embedded owner_pk doesn't match the one we expected — those are
  /// silent drops (we do not touch the cache).
  Future<bool> _applyVerified(
    MeshEnvelope env, {
    required Uint8List expectedOwnerPk,
  }) async {
    final ok = await MeshBlob.verifyEnvelope(env);
    if (!ok) {
      return false;
    }
    final blob = MeshBlob.fromCanonicalBytes(env.blob);
    if (!_bytesEqual(blob.ownerPk, expectedOwnerPk)) {
      return false;
    }
    await _replaceLocalCacheWith(blob);
    return true;
  }

  /// Overwrite local peers + nicknames with what the relay says.
  /// Implements the "relay is source of truth" contract from plan/24:
  /// any peer in the local cache but absent from `blob.members` is
  /// removed; renamed nicknames propagate; relay_url updates.
  ///
  /// Uses the **silent** variants of save/delete so the mutation hook
  /// (which republishes) does not fire. Otherwise every pull would
  /// loop into a publish, and any tiny diff (timestamp precision,
  /// reordering) would round-trip back to the relay. Worse: a race
  /// between the apply-phase intermediate states and a concurrent
  /// `publish()` could observe an empty PairingStorage and ship
  /// members=[] — the bug reproduced by the user, where pi-extension
  /// self-revoked after the app silently published v2 empty.
  Future<void> _replaceLocalCacheWith(MeshBlob blob) async {
    final existing = {
      for (final p in await _storage.listPeers()) p.remoteEpk: p,
    };
    final keep = <String>{};
    for (final m in blob.members) {
      keep.add(m.remoteEpk);
      final prev = existing[m.remoteEpk];
      final next = PeerRecord(
        remoteEpk: m.remoteEpk,
        sessionName: prev?.sessionName ?? m.nickname ?? 'Piper',
        relayUrl: m.relayUrl,
        pairedAt: m.pairedAt,
        nickname: m.nickname,
        roomId: prev?.roomId,
      );
      if (prev == null || !_peerEqualsForMesh(prev, next)) {
        await _storage.savePeerSilent(next);
      }
    }
    for (final p in existing.values) {
      if (!keep.contains(p.remoteEpk)) {
        await _storage.deletePeerSilent(p.remoteEpk);
        await _storage.deleteRooms(p.remoteEpk);
      }
    }
  }

  /// Compare the mesh-controlled fields only — `sessionName` and
  /// `roomId` stay client-local and don't trigger a re-save when the
  /// relay version arrives unchanged.
  bool _peerEqualsForMesh(PeerRecord a, PeerRecord b) =>
      a.remoteEpk == b.remoteEpk &&
      a.relayUrl == b.relayUrl &&
      a.pairedAt == b.pairedAt &&
      a.nickname == b.nickname;

  // -------------------------------------------------------------------------
  // Publish
  // -------------------------------------------------------------------------

  /// Snapshot the current local peer list, bump version, sign, POST.
  /// Conflict (409) → re-fetch then publish again with the higher
  /// version. Network failure leaves the cache as-is — the next
  /// [pullAndApply] tick will reconcile (LWW from plan/24 § Q5).
  ///
  /// [allowEmpty] opts out of the empty-on-existing safety net (see
  /// [_publishOnce]). Used by the revoke-last-peer flow, which is the
  /// only legitimate caller of "publish members=[] on top of a
  /// non-zero version watermark" — every other caller leaves the
  /// default `false` so the safety net still protects against races.
  Future<MeshPublishResult> publish({bool allowEmpty = false}) async {
    if (_publishing) {
      return const MeshPublishFailure('already in flight');
    }
    final pk = _ownerBridge.currentOwnerPk;
    if (pk == null) {
      return const MeshPublishFailure('owner pk not loaded');
    }
    _publishing = true;
    try {
      return await _publishOnce(
        pk,
        refetchOnConflict: true,
        allowEmpty: allowEmpty,
      );
    } finally {
      _publishing = false;
    }
  }

  Future<MeshPublishResult> _publishOnce(
    Uint8List pk, {
    required bool refetchOnConflict,
    required bool allowEmpty,
  }) async {
    final peers = await _storage.listPeers();
    // Safety net (plan/24-fix-app-publish-race): never overwrite a
    // non-empty membership with members=[] UNLESS the caller opted in
    // via [allowEmpty]. The only legitimate "empty on top of non-zero
    // version" path is the user revoking their last paired peer
    // (SettingsViewModel.revoke); every other caller passes
    // `allowEmpty:false` so we still refuse races (transient
    // PairingStorage state, apply mid-flight, mistaken Owner-key
    // reset) that would self-revoke pi-extension on every Pi the user
    // owns.
    if (peers.isEmpty && _lastVersion > 0 && !allowEmpty) {
      return const MeshPublishFailure('refused empty-on-existing');
    }
    // Encoding gotcha: `PairingStorage.PeerRecord.remoteEpk` is whatever
    // the QR / pair_ok handed us — historically base64url (no padding).
    // The Pi-extension's self-revoke check compares `my_pubkey` (which
    // it formats as base64 STANDARD, matching `owner_pk` in the blob)
    // against the strings in `members[].remote_epk`. Mixing encodings
    // looks like "I'm not listed" → self-revoke. Normalise on the way
    // out so the blob is uniformly base64 standard, end-to-end.
    final members = peers
        .map((p) => MeshMember(
              remoteEpk: toStandardB64(p.remoteEpk),
              relayUrl: p.relayUrl,
              pairedAt: p.pairedAt,
              nickname: p.nickname,
            ))
        .toList(growable: false);
    final nextVersion = _lastVersion + 1;
    final blob = MeshBlob(
      version: nextVersion,
      issuedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
      ownerPk: pk,
      members: members,
    );
    final keyPair = await _ownerBridge.requireKeyPair();
    final envelope = await blob.signWith(keyPair);
    final hash = await MeshClient.ownerPkHash(pk);
    final result = await _client.publish(hash, envelope);
    switch (result) {
      case MeshPublishOk(version: final v, updatedAt: final u):
        _lastVersion = v;
        lastUpdatedAt = u;
        notifyListeners();
        return result;
      case MeshPublishConflict():
        if (!refetchOnConflict) return result;
        await pullOnDemand();
        return _publishOnce(
          pk,
          refetchOnConflict: false,
          allowEmpty: allowEmpty,
        );
      case MeshPublishBadRequest():
        return result;
      case MeshPublishForbidden():
      case MeshPublishTooLarge():
      case MeshPublishFailure():
        return result;
    }
  }

  // -------------------------------------------------------------------------
  // Polling
  // -------------------------------------------------------------------------

  /// Begin periodic [pullOnDemand] every [interval] (default 60s, the
  /// Q1 value from plan/24). Idempotent — calling twice cancels the
  /// previous timer first.
  ///
  /// The host (typically the router or a top-level lifecycle observer)
  /// is responsible for stopping the polling when the app goes
  /// background and restarting it on resume.
  void startPolling({Duration interval = const Duration(seconds: 60)}) {
    stopPolling();
    _pollTimer = Timer.periodic(interval, (_) {
      // ignore: unawaited_futures
      pullOnDemand();
    });
  }

  void stopPolling() {
    if (_pollTimer != null) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  /// Reset the version watermark — used by the Owner-key-replaced
  /// path (sync drift in plan/23) so the next fetch is unconditional.
  void resetVersionWatermark() {
    _lastVersion = 0;
    lastUpdatedAt = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stopPolling();
    super.dispose();
  }
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
