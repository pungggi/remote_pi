import 'package:app/data/mesh/mesh_sync_service.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/relay_config.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/settings/states/settings_state.dart';

/// Settings is config-only (nickname + revoke). The peer switcher moved
/// to Home; the connection itself is shared and owned by
/// [ConnectionManager] from app boot (plano 12). Revoke side-effect:
/// re-subscribe the relay's presence push so the removed epk is dropped.
class SettingsViewModel extends ViewModel<SettingsState> {
  final PairingStorage _storage;
  final Preferences _prefs;
  final ConnectionManager _conn;

  /// Optional in tests; required in production. The revoke flow drives
  /// it explicitly with `allowEmpty:true` so a revoke of the last
  /// remaining peer still propagates to the relay — without it, the
  /// safety net in [MeshSyncService] refuses to publish members=[] and
  /// the next `pullOnDemand` resurrects the peer from the stale blob.
  final MeshSyncService? _meshSync;
  bool _disposed = false;

  SettingsViewModel(this._storage, this._prefs, this._conn, [this._meshSync])
    : super(const SettingsLoading()) {
    _load();
  }

  Future<void> _load() async {
    final peers = await _storage.listPeers();
    if (_disposed) return;
    if (peers.isEmpty) {
      emit(const SettingsNoPeer());
      return;
    }
    emit(SettingsList(peers: peers));
  }

  /// Set or clear the local nickname for the peer at [epk].
  Future<void> setNickname(String epk, String? nickname) async {
    final s = state;
    if (s is! SettingsList) return;
    PeerRecord? target;
    for (final p in s.peers) {
      if (p.remoteEpk == epk) {
        target = p;
        break;
      }
    }
    if (target == null) return;
    final trimmed = nickname?.trim();
    final normalized = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    final updated = target.copyWith(nickname: normalized);
    await _storage.savePeer(updated);
    await _load();
  }

  /// Effective relay URL the app is connecting to right now.
  String get effectiveRelayUrl => resolveRelayUrl(_prefs);

  /// User-set relay URL. Empty when none is set — since plan/102 there is no
  /// default to fall back to ([kDefaultRelayUrl] is `''`); the relay arrives
  /// with the pairing QR.
  String get relayUrlOverride => _prefs.relayUrl ?? kDefaultRelayUrl;

  /// Drops the stored relay so the next pairing QR decides again. Needed
  /// because the relay is per-network: after moving to a different WLAN the
  /// old address is not merely stale, it is wrong.
  Future<void> clearRelayUrl() async {
    await _prefs.setRelayUrl(null);
    notifyListeners();
  }

  // ── Plan 115 — LAN endpoint (optional, auto-filled by the relay) ──────

  /// The current LAN candidate the app will try first at home, or `''`
  /// when none is set ("Tailscale/primary only" — plan 115 opt-out).
  /// Shows the first learned LAN endpoint; the full candidate list may
  /// contain several (relay advertises all its RFC1918 addresses).
  String get lanUrlOverride =>
      _prefs.lanEndpoints.isEmpty ? '' : _prefs.lanEndpoints.first;

  /// Set or clear the LAN endpoint override. Empty/blank clears the whole
  /// LAN list (opt out of LAN — primary/overlay only). On success the
  /// connection is rebuilt so the new candidate set takes effect now.
  Future<String?> saveLanUrl(String? value) async {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      await _prefs.setLanEndpoints(const []);
      await _conn.disconnect();
      _conn.boot(preferredEpk: _prefs.selectedPeerEpk);
      return null;
    }
    final reason = relayUrlValidationMessage(trimmed);
    if (reason != null) return reason;
    await _prefs.setLanEndpoints([trimmed]);
    await _conn.disconnect();
    _conn.boot(preferredEpk: _prefs.selectedPeerEpk);
    return null;
  }

  /// Clear every LAN candidate (plan 115 opt-out: dial the primary only).
  ///
  /// Rebuilds the connection so the change takes effect immediately — the
  /// active link may currently be on a LAN endpoint that is no longer a
  /// candidate, so we drop it and reconnect over the primary/overlay.
  /// (Mirrors [saveLanUrl]; the VM-level [notifyListeners] refreshes the
  /// Settings helper text, which reads [lanUrlOverride].)
  Future<void> clearLanUrl() async {
    await _prefs.setLanEndpoints(const []);
    await _conn.disconnect();
    _conn.boot(preferredEpk: _prefs.selectedPeerEpk);
    notifyListeners();
  }

  Future<String?> saveRelayUrl(String? value) async {
    if (value == null || value.trim().isEmpty) {
      return 'Enter a relay URL, or use Clear — pairing sets it from the QR.';
    }
    final trimmed = value.trim();

    final reason = relayUrlValidationMessage(trimmed);
    if (reason != null) return reason;
    await _prefs.setRelayUrl(trimmed);

    await _conn.disconnect();
    _conn.boot(preferredEpk: _prefs.selectedPeerEpk);
    return null;
  }

  /// Revoke pairing locally. Drops the peer from the relay's presence
  /// subscription too so we stop receiving updates about a peer that no
  /// longer exists on this device. Clears the selected pointer when it
  /// matches. If this was the LAST peer, also resets
  /// `onboardingCompleted=false` so the next boot lands on /onboarding
  /// (matches user expectation of "revoke = start fresh").
  Future<void> revoke(String epk) async {
    final wasActive = _conn.activePeer?.remoteEpk == epk;
    if (_prefs.selectedPeerEpk == epk) {
      await _prefs.setSelectedPeerEpk(null);
    }
    // Use the SILENT delete so the storage mutation hook does not
    // auto-publish a members=[] blob through the safety-net guard
    // (which would refuse it for the last-peer case and leave the
    // relay holding stale state). We publish ourselves below with
    // `allowEmpty:true` — the only place in the app that opts out of
    // the empty-on-existing safety net.
    await _storage.deletePeerSilent(epk);
    final remaining = await _storage.listPeers();
    if (_meshSync != null) {
      // ignore: unawaited_futures
      _meshSync.publish(allowEmpty: remaining.isEmpty);
    }
    _conn.subscribeToPeers(remaining.map((p) => p.remoteEpk).toList());
    // If the revoked peer was the one currently driving the connection,
    // tear it down so we don't keep talking to a peer the user just
    // removed. If others remain, fall back to one of them; otherwise
    // disconnect cleanly.
    if (wasActive) {
      await _conn.disconnect();
      if (remaining.isNotEmpty) {
        final fallback = remaining.first;
        await _prefs.setSelectedPeerEpk(fallback.remoteEpk);
        // ignore: unawaited_futures
        _conn.boot(preferredEpk: fallback.remoteEpk);
      }
    }
    if (remaining.isEmpty) {
      await _prefs.setOnboardingCompleted(false);
    }
    await _load();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
