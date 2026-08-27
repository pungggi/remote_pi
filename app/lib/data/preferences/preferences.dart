import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Plan 125 (Layer 4) — when the Android foreground service keeps the relay
/// WebSocket alive in the background. Replaces the plan-103 on/off bool.
enum KeepAliveMode {
  /// Always run the service while backgrounded + a peer is connected. Most
  /// reliable, most battery.
  always,

  /// Run the service only while charging (default). Reliable on power, saves
  /// battery on the go.
  whenCharging,

  /// Never run the service; the OS freezes the process on background and the
  /// WS drops on focus change (the pre-plan-103 behaviour).
  off,
}

/// Plan 131 (upstream #114) — user font-size preference. Applied on top of
/// the OS text scale by composing the ambient `TextScaler` (see
/// `font_scale.dart`), so it multiplies — never replaces — the system
/// accessibility setting.
enum UiFontScale {
  small(0.9),
  normal(1.0),
  large(1.15),
  extraLarge(1.3);

  const UiFontScale(this.factor);

  /// Multiplier applied to the effective text scale. 1.0 = system default.
  final double factor;
}

/// App-wide UI preferences (persisted across launches).
///
/// Extends [ChangeNotifier] so widgets can `context.watch<Preferences>()`
/// and rebuild on toggle. Backed by [FlutterSecureStorage] (same store
/// already used by pairing). Call [load] once during bootstrap before
/// the first frame to hydrate the in-memory cache.
class Preferences extends ChangeNotifier {
  final FlutterSecureStorage _store;
  bool _hideToolCalls = false;
  String? _selectedPeerEpk;
  String? _relayUrl;
  // Plan 115 — LAN candidate URLs for the global relay, learned from the
  // relay's handshake advertisement (and editable in Settings). LAN is
  // dialled first so home use bypasses Tailscale entirely.
  List<String> _lanEndpoints = const [];
  // Plan 115 — the endpoint that last connected successfully. The next
  // connect starts from it (preference bias) before falling through the
  // full candidate list. Also drives the mesh HTTP client so it follows
  // the live path instead of always the (possibly flaky) primary.
  String? _lastGoodRelayUrl;
  bool _onboardingCompleted = false;
  ThemeMode _themeMode = ThemeMode.system;
  // Plan 125 (Layer 4) — when to keep the relay WebSocket alive in the
  // background via an Android foreground service. Three-way (was a bool in
  // plan 103). Default `whenCharging` ("stay connected on power, save battery
  // on the go"); the user can switch in Settings.
  KeepAliveMode _keepAliveMode = KeepAliveMode.whenCharging;
  // Plan 110 — tool calls are collapsed by default; tapping expands them to show
  // full details. Reduces chat noise when the AI makes many tool calls.
  bool _collapseToolCalls = true;
  // Plan/122 — project paths pinned to the top of the Projects list for
  // quick access. Matched by absolute repo path.
  List<String> _pinnedProjects = const [];
  // Plan 131 (upstream #114) — text-size preset. Composed onto the OS text
  // scale in main.dart's MaterialApp.builder.
  UiFontScale _uiFontScale = UiFontScale.normal;

  Preferences([FlutterSecureStorage? store])
    : _store = store ?? const FlutterSecureStorage();

  static const _kHideToolCallsKey = 'prefs.hide_tool_calls';
  static const _kSelectedPeerEpkKey = 'prefs.selected_peer_epk';
  static const _kRelayUrlKey = 'prefs.relay_url';
  static const _kLanEndpointsKey = 'prefs.lan_endpoints';
  static const _kLastGoodRelayUrlKey = 'prefs.last_good_relay_url';
  static const _kOnboardingCompletedKey = 'prefs.onboarding_completed';
  static const _kThemeModeKey = 'prefs.theme_mode';
  static const _kKeepAliveInBackgroundKey = 'prefs.keep_alive_in_background';
  static const _kCollapseToolCallsKey = 'prefs.collapse_tool_calls';
  static const _kPinnedProjectsKey = 'prefs.pinned_projects';
  static const _kUiFontScaleKey = 'prefs.ui_font_scale';

  /// True → chat hides `ToolEvent` rows (only user/assistant text remain).
  bool get hideToolCalls => _hideToolCalls;

  /// Epoch of the peer the user last picked from Home — the one
  /// `/chat` will connect to when it mounts. Null = no peer selected yet
  /// (user is still browsing or hasn't paired). Persisted so reopening
  /// the app right into `/chat` (e.g. via deep-link) knows which peer.
  ///
  /// Plan 17: under the new rooms model the persisted value carries an
  /// optional `:roomId` suffix (e.g. `Bz02uLi…:main` or
  /// `Bz02uLi…:room-uuid-xyz`). The getter returns only the EPK; use
  /// [selectedRoomId] for the room half. Legacy values without the
  /// `:room` suffix transparently fall through (the value is the epk
  /// and `selectedRoomId` returns null → falls back to 'main' at the
  /// caller).
  String? get selectedPeerEpk {
    final raw = _selectedPeerEpk;
    if (raw == null) return null;
    final ix = raw.indexOf(':');
    return ix < 0 ? raw : raw.substring(0, ix);
  }

  /// Plan 17 — the room half of the persisted selected target. Returns
  /// null for legacy values (caller defaults to 'main').
  String? get selectedRoomId {
    final raw = _selectedPeerEpk;
    if (raw == null) return null;
    final ix = raw.indexOf(':');
    if (ix < 0) return null;
    final r = raw.substring(ix + 1);
    return r.isEmpty ? null : r;
  }

  /// Composite raw value (epk[:room]). Tests can inspect.
  String? get selectedRoomRaw => _selectedPeerEpk;

  /// User-configured relay URL override. `null` = use the public default
  /// (`kDefaultRelayUrl` in `relay_config.dart`). Set via Settings or
  /// during onboarding step 2 (custom relay).
  String? get relayUrl => _relayUrl;

  /// `true` after the user completed the 3-step onboarding flow at least
  /// once. Drives `/boot` redirect: false → `/onboarding`, true → `/home`.
  bool get onboardingCompleted => _onboardingCompleted;

  /// Preferred app theme. `ThemeMode.system` (default) follows the OS
  /// light/dark setting; `light` / `dark` pin it. Consumed by `MaterialApp`
  /// in `main.dart` and set from the Settings "Display" section.
  ThemeMode get themeMode => _themeMode;

  /// Hydrate from secure storage. Safe to call multiple times.
  Future<void> load() async {
    var changed = false;

    final raw = await _store.read(key: _kHideToolCallsKey);
    final next = raw == 'true';
    if (next != _hideToolCalls) {
      _hideToolCalls = next;
      changed = true;
    }

    final selected = await _store.read(key: _kSelectedPeerEpkKey);
    final cleaned = (selected != null && selected.isNotEmpty) ? selected : null;
    if (cleaned != _selectedPeerEpk) {
      _selectedPeerEpk = cleaned;
      changed = true;
    }

    final relay = await _store.read(key: _kRelayUrlKey);
    final relayCleaned = (relay != null && relay.isNotEmpty) ? relay : null;
    if (relayCleaned != _relayUrl) {
      _relayUrl = relayCleaned;
      changed = true;
    }

    // Plan 115 — hydrate LAN candidates (JSON array) + last-good winner.
    final lanRaw = await _store.read(key: _kLanEndpointsKey);
    final lanList = _decodeLanEndpoints(lanRaw);
    if (!_listEquals(lanList, _lanEndpoints)) {
      _lanEndpoints = lanList;
      changed = true;
    }

    final lastGood = await _store.read(key: _kLastGoodRelayUrlKey);
    final lastGoodCleaned = (lastGood != null && lastGood.isNotEmpty)
        ? lastGood
        : null;
    if (lastGoodCleaned != _lastGoodRelayUrl) {
      _lastGoodRelayUrl = lastGoodCleaned;
      changed = true;
    }

    final onboarded = await _store.read(key: _kOnboardingCompletedKey);
    final onboardedBool = onboarded == 'true';
    if (onboardedBool != _onboardingCompleted) {
      _onboardingCompleted = onboardedBool;
      changed = true;
    }

    final theme = await _store.read(key: _kThemeModeKey);
    final themeMode = _themeModeFromString(theme);
    if (themeMode != _themeMode) {
      _themeMode = themeMode;
      changed = true;
    }

    // Plan 125 (Layer 4) — migrate the plan-103 on/off bool to the three-way
    // mode: 'true' → always, 'false' → off, absent (first launch) →
    // whenCharging (new default). Already-migrated names pass through; garbage
    // falls back to whenCharging.
    final keepAlive = await _store.read(key: _kKeepAliveInBackgroundKey);
    final keepAliveMode = _parseKeepAliveMode(keepAlive);
    if (keepAliveMode != _keepAliveMode) {
      _keepAliveMode = keepAliveMode;
      changed = true;
    }

    // Plan 110 — default true when the key is absent (first launch: collapsed).
    final collapse = await _store.read(key: _kCollapseToolCallsKey);
    final collapseBool = collapse == null ? true : collapse == 'true';
    if (collapseBool != _collapseToolCalls) {
      _collapseToolCalls = collapseBool;
      changed = true;
    }

    // Plan/122 — pinned project paths (JSON array). Empty/missing → none.
    final pinnedRaw = await _store.read(key: _kPinnedProjectsKey);
    final pinned = _decodeJsonStringList(pinnedRaw);
    if (!_listEquals(pinned, _pinnedProjects)) {
      _pinnedProjects = pinned;
      changed = true;
    }

    // Plan 131 (upstream #114) — font-size preset. Absent/garbage → normal.
    final fontScale = await _store.read(key: _kUiFontScaleKey);
    final uiFontScale = _uiFontScaleFromString(fontScale);
    if (uiFontScale != _uiFontScale) {
      _uiFontScale = uiFontScale;
      changed = true;
    }

    if (changed) notifyListeners();
  }

  Future<void> setHideToolCalls(bool value) async {
    if (_hideToolCalls == value) return;
    _hideToolCalls = value;
    await _store.write(key: _kHideToolCallsKey, value: value.toString());
    notifyListeners();
  }

  Future<void> setSelectedPeerEpk(String? value) async {
    final cleaned = (value != null && value.isNotEmpty) ? value : null;
    if (cleaned == _selectedPeerEpk) return;
    _selectedPeerEpk = cleaned;
    if (cleaned == null) {
      await _store.delete(key: _kSelectedPeerEpkKey);
    } else {
      await _store.write(key: _kSelectedPeerEpkKey, value: cleaned);
    }
    notifyListeners();
  }

  /// Plan 17 — persist the composite `epk:roomId` selection. Passing
  /// [roomId] = null falls back to 'main' implicitly via the getter
  /// contract. Null [epk] clears the entire selection.
  Future<void> setSelectedRoom({String? epk, String? roomId}) async {
    if (epk == null || epk.isEmpty) {
      return setSelectedPeerEpk(null);
    }
    final composite = (roomId == null || roomId.isEmpty) ? epk : '$epk:$roomId';
    return setSelectedPeerEpk(composite);
  }

  /// Set the user-configured relay URL. `null` or empty clears the
  /// override so the app falls back to `kDefaultRelayUrl`. Caller should
  /// validate via `isValidRelayUrl` first when [value] is non-null.
  Future<void> setRelayUrl(String? value) async {
    final cleaned = (value != null && value.isNotEmpty) ? value : null;
    if (cleaned == _relayUrl) return;
    _relayUrl = cleaned;
    if (cleaned == null) {
      await _store.delete(key: _kRelayUrlKey);
    } else {
      await _store.write(key: _kRelayUrlKey, value: cleaned);
    }
    notifyListeners();
  }

  // ── Plan 115 — LAN endpoints + last-good winner ───────────────────────

  /// LAN candidate URLs for the global relay (home VLAN addresses the
  /// relay advertised at handshake, plus anything the user typed in
  /// Settings). Dialled first so home use skips the overlay.
  List<String> get lanEndpoints => List.unmodifiable(_lanEndpoints);

  /// Replace the whole LAN candidate list. Pass an empty list to opt out
  /// of LAN entirely ("Tailscale only"). Dedupes + drops empties.
  Future<void> setLanEndpoints(List<String> urls) async {
    final cleaned = _normalizeLanEndpoints(urls);
    if (_listEquals(cleaned, _lanEndpoints)) return;
    _lanEndpoints = cleaned;
    if (cleaned.isEmpty) {
      await _store.delete(key: _kLanEndpointsKey);
    } else {
      await _store.write(key: _kLanEndpointsKey, value: jsonEncode(cleaned));
    }
    notifyListeners();
  }

  /// Merge [urls] into the LAN candidate list (union, preserving existing
  /// order, deduped). Used when the relay advertises its LAN addresses at
  /// handshake — we keep what the user already had and add any new ones
  /// the relay knows about. Inputs are normalised the same way as
  /// [setLanEndpoints] (trimmed, empties dropped) so a dirty advertised
  /// URL can't sneak in untrimmed and later fail to dedupe/connect.
  Future<void> mergeLanEndpoints(Iterable<String> urls) async {
    final merged = <String>[..._lanEndpoints];
    final seen = merged.toSet();
    for (final raw in urls) {
      final u = raw.trim();
      if (u.isNotEmpty && seen.add(u)) merged.add(u);
    }
    if (_listEquals(merged, _lanEndpoints)) return;
    _lanEndpoints = List.unmodifiable(merged);
    await _store.write(key: _kLanEndpointsKey, value: jsonEncode(merged));
    notifyListeners();
  }

  /// The endpoint that last connected successfully, or `null` before the
  /// first successful connect. The next connect starts from it.
  String? get lastGoodRelayUrl => _lastGoodRelayUrl;

  /// Record the winning endpoint after a successful connect. `null` /
  /// empty clears it.
  Future<void> setLastGoodRelayUrl(String? value) async {
    final cleaned = (value != null && value.isNotEmpty) ? value : null;
    if (cleaned == _lastGoodRelayUrl) return;
    _lastGoodRelayUrl = cleaned;
    if (cleaned == null) {
      await _store.delete(key: _kLastGoodRelayUrlKey);
    } else {
      await _store.write(key: _kLastGoodRelayUrlKey, value: cleaned);
    }
    // No notifyListeners() — last-good is internal transport bookkeeping,
    // not UI state. Avoids a rebuild storm on every reconnect.
  }

  Future<void> setOnboardingCompleted(bool value) async {
    if (_onboardingCompleted == value) return;
    _onboardingCompleted = value;
    await _store.write(key: _kOnboardingCompletedKey, value: value.toString());
    notifyListeners();
  }

  /// Persist the preferred [ThemeMode]. Stored as a stable string key so the
  /// value survives enum reordering.
  Future<void> setThemeMode(ThemeMode value) async {
    if (_themeMode == value) return;
    _themeMode = value;
    await _store.write(key: _kThemeModeKey, value: value.name);
    notifyListeners();
  }

  /// Plan 125 (Layer 4) — when to keep the relay WebSocket alive in the
  /// background via the Android foreground service. Default
  /// [KeepAliveMode.whenCharging].
  KeepAliveMode get keepAliveMode => _keepAliveMode;

  Future<void> setKeepAliveMode(KeepAliveMode value) async {
    if (_keepAliveMode == value) return;
    _keepAliveMode = value;
    await _store.write(key: _kKeepAliveInBackgroundKey, value: value.name);
    notifyListeners();
  }

  /// Plan 125 (Layer 4) — resolve the keep-alive mode from its stored string,
  /// migrating the plan-103 bool. Unknown/garbage → [KeepAliveMode.whenCharging].
  static KeepAliveMode _parseKeepAliveMode(String? raw) {
    switch (raw) {
      case null:
        return KeepAliveMode.whenCharging;
      case 'true':
        return KeepAliveMode.always;
      case 'false':
        return KeepAliveMode.off;
      default:
        return KeepAliveMode.values.firstWhere(
          (m) => m.name == raw,
          orElse: () => KeepAliveMode.whenCharging,
        );
    }
  }

  /// Plan 110 — when true, tool calls are collapsed by default in chat.
  /// Tapping a collapsed card expands it. Default true.
  bool get collapseToolCalls => _collapseToolCalls;

  Future<void> setCollapseToolCalls(bool value) async {
    if (_collapseToolCalls == value) return;
    _collapseToolCalls = value;
    await _store.write(key: _kCollapseToolCallsKey, value: value.toString());
    notifyListeners();
  }

  // ── Plan/122 — pinned projects (Projects list quick access) ───────────

  /// Project paths the user pinned to the top of the Projects list.
  /// Matched by absolute repo path; a path that no longer exists on the
  /// paired PC is inert (matches nothing and renders no tile).
  List<String> get pinnedProjects => List.unmodifiable(_pinnedProjects);

  bool isProjectPinned(String path) => _pinnedProjects.contains(path);

  /// Toggle membership of [path] in the pinned set and persist. Returns the
  /// new pinned state (`true` = now pinned). New pins append; removal is by
  /// value. Safe to call from the UI toggle.
  Future<bool> togglePinnedProject(String path) async {
    final next = List<String>.from(_pinnedProjects);
    final nowPinned = !next.remove(path);
    if (nowPinned) next.add(path);
    _pinnedProjects = List.unmodifiable(next);
    if (next.isEmpty) {
      await _store.delete(key: _kPinnedProjectsKey);
    } else {
      await _store.write(key: _kPinnedProjectsKey, value: jsonEncode(next));
    }
    notifyListeners();
    return nowPinned;
  }

  // ── Plan 131 — font-size preset (upstream #114) ────────────────────────

  /// Text-size preset for the whole app UI. Multiplied onto the OS text
  /// scale (see [UiFontScale]); `normal` (default) leaves the system value
  /// untouched.
  UiFontScale get uiFontScale => _uiFontScale;

  /// Persist the preferred font-size preset. Stored as a stable enum name
  /// (same convention as [setThemeMode]) so the value survives reordering.
  Future<void> setUiFontScale(UiFontScale value) async {
    if (_uiFontScale == value) return;
    _uiFontScale = value;
    await _store.write(key: _kUiFontScaleKey, value: value.name);
    notifyListeners();
  }

  /// Resolve the persisted preset. Unknown/garbage → [UiFontScale.normal].
  static UiFontScale _uiFontScaleFromString(String? raw) {
    return UiFontScale.values.firstWhere(
      (s) => s.name == raw,
      orElse: () => UiFontScale.normal,
    );
  }

  static ThemeMode _themeModeFromString(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  // ── Plan 115 — LAN endpoint JSON helpers ─────────────────────────────

  /// Decode a persisted LAN endpoints blob (JSON array of strings) into a
  /// normalised, deduped list. Tolerates a missing/blank/corrupt value by
  /// returning an empty list — a corrupt blob must never block boot.
  static List<String> _decodeLanEndpoints(String? raw) =>
      _decodeJsonStringList(raw);

  /// Decode a persisted JSON string array into a normalised (trimmed,
  /// deduped, order-preserving) list. Tolerates a missing/blank/corrupt
  /// value by returning an empty list — a corrupt blob must never block
  /// boot. Shared by LAN endpoints (Plan 115) and pinned projects (122).
  static List<String> _decodeJsonStringList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return _normalizeLanEndpoints(decoded.whereType<String>());
    } catch (_) {
      return const [];
    }
  }

  /// Drop empties + dedupe while preserving first-seen order. Returns an
  /// unmodifiable list so the field can be compared by identity safely.
  static List<String> _normalizeLanEndpoints(Iterable<String> urls) {
    final out = <String>[];
    final seen = <String>{};
    for (final u in urls) {
      final t = u.trim();
      if (t.isNotEmpty && seen.add(t)) out.add(t);
    }
    return List.unmodifiable(out);
  }

  /// Reference equality is wrong for [List]; deep compare so the loaders
  /// and setters can short-circuit no-op writes (and skip a redundant
  /// [notifyListeners]).
  static bool _listEquals(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
