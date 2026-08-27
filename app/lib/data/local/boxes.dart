// Plan/31 — local SSOT box layer (Hive v2).
//
// Three families of box in a NEW namespace (`rp_v2`); v1 (`session_history`,
// the blob snapshot) is abandoned without migration (#6 — re-sync from the Pi
// on first boot). The `runtime` box is VOLATILE: wiped on every boot (#3) so
// connection/presence never report stale online across restarts.
//
//   DURABLE  msgs_<epk>__<roomId>   key = seq (int)        → MessageRecord
//   DURABLE  sessions_index         key = <epk>:<roomId>   → SessionIndexRecord
//   DURABLE  notify_prefs           key = <epk>:<roomId>   → bool (Plan 132)
//   VOLATILE runtime  (wiped@boot)  key = <epk>:<roomId>   → RuntimeRecord

import 'package:app/data/transport/epk_encoding.dart';
import 'package:hive_flutter/hive_flutter.dart';

const String _kNamespace = 'rp_v2';
const String _kSessionsIndex = 'sessions_index';
const String _kRuntime = 'runtime';
const String _kNotifyPrefs = 'notify_prefs';

/// Facade over the v2 Hive boxes. A single instance is shared by the
/// [SyncService] (writer) and the read repositories (readers) so they observe
/// the same open box objects (`Hive.openBox` is idempotent).
class LocalBoxes {
  static bool _initialized = false;

  /// Open the v2 namespace and the always-on boxes; **wipe `runtime`** before
  /// anything subscribes (#3 / Risk 2). Call once during bootstrap, before
  /// `runApp` and before any read-repo is constructed.
  static Future<void> init() async {
    if (_initialized) return;
    await Hive.initFlutter(_kNamespace);
    await _openCommon();
    _initialized = true;
  }

  /// For tests: open against a custom directory. Unlike [init] this always
  /// re-opens + wipes the volatile box, so a second call simulates a restart
  /// (and lets tests assert the wipe).
  static Future<void> initForTest(String path) async {
    if (!_initialized) Hive.init(path);
    await _openCommon();
    _initialized = true;
  }

  static Future<void> _openCommon() async {
    await Hive.openBox<dynamic>(_kSessionsIndex);
    // Plan/132 — per-session completion-notification toggles (durable).
    await Hive.openBox<dynamic>(_kNotifyPrefs);
    final runtime = await Hive.openBox<dynamic>(_kRuntime);
    await runtime.clear(); // VOLATILE — zero on boot (#3)
  }

  Box<dynamic> sessionsIndexBox() => Hive.box<dynamic>(_kSessionsIndex);

  Box<dynamic> runtimeBox() => Hive.box<dynamic>(_kRuntime);

  /// Plan/132 — per-session completion-notification toggles. Key is
  /// `<epk>:<roomId>` (same shape as [sessionKey]); value is a `bool`.
  Box<dynamic> notifyPrefsBox() => Hive.box<dynamic>(_kNotifyPrefs);

  /// Per-session message box. Lazily opened; idempotent (returns the already
  /// open box on subsequent calls).
  Future<Box<dynamic>> msgsBox(String epk, String roomId) =>
      Hive.openBox<dynamic>(msgsBoxName(epk, roomId));

  /// Synchronous accessor for a msgs box known to be open already.
  Box<dynamic> openMsgsBox(String epk, String roomId) =>
      Hive.box<dynamic>(msgsBoxName(epk, roomId));

  bool isMsgsBoxOpen(String epk, String roomId) =>
      Hive.isBoxOpen(msgsBoxName(epk, roomId));

  /// `:` and the epk's `/`+`=` would break the on-disk filename — sanitise to
  /// the url-safe, unpadded epk form (same approach as the v1 store).
  static String msgsBoxName(String epk, String roomId) =>
      'msgs_${toAppEpk(epk)}__$roomId';

  static String sessionKey(String epk, String roomId) => '$epk:$roomId';
}
