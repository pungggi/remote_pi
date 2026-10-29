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
//   DURABLE  read_markers           key = <epk>:<roomId>   → int (Plan/149:
//                                 last-read seq; unread = msgs box rows
//                                 past it — NEVER a counter, plan/111=30 ev)
//   VOLATILE runtime  (wiped@boot)  key = <epk>:<roomId>   → RuntimeRecord

import 'package:app/data/transport/epk_encoding.dart';
import 'package:hive_flutter/hive_flutter.dart';

const String _kNamespace = 'rp_v2';
const String _kSessionsIndex = 'sessions_index';
const String _kRuntime = 'runtime';
const String _kNotifyPrefs = 'notify_prefs';
const String _kReadMarkers = 'read_markers';

/// Facade over the v2 Hive boxes. A single instance is shared by the
/// [SyncService] (writer) and the read repositories (readers) so they observe
/// the same open box objects (`Hive.openBox` is idempotent).
class LocalBoxes {
  static bool _initialized = false;

  /// `true` once [init]/[initForTest] has opened the common boxes. Lets
  /// UI-layer callers skip OPTIONAL box work in environments without
  /// storage (plain ViewModel tests never init Hive).
  static bool get isInitialized => _initialized;

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
    // Plan/149 — per-session last-read seq markers (durable; unread
    // survives restarts).
    await Hive.openBox<dynamic>(_kReadMarkers);
    final runtime = await Hive.openBox<dynamic>(_kRuntime);
    await runtime.clear(); // VOLATILE — zero on boot (#3)
  }

  Box<dynamic> sessionsIndexBox() => Hive.box<dynamic>(_kSessionsIndex);

  Box<dynamic> runtimeBox() => Hive.box<dynamic>(_kRuntime);

  /// Plan/132 — per-session completion-notification toggles. Key is
  /// `<epk>:<roomId>` (same shape as [sessionKey]); value is a `bool`.
  Box<dynamic> notifyPrefsBox() => Hive.box<dynamic>(_kNotifyPrefs);

  /// Plan/149 — per-session last-read seq markers. Key is
  /// `<epk>:<roomId>`; value is the highest seq the user actually saw
  /// (written on chat open). Unread = msgs box rows with seq > marker,
  /// counted on demand — never stored (plan/111 verdict: derived state
  /// drifts; the box rows are the SSOT).
  Box<dynamic> readMarkersBox() => Hive.box<dynamic>(_kReadMarkers);

  /// Plan/149 — number of unread messages for a session: msgs box rows
  /// with `seq > lastReadSeq`. Returns 0 for unknown sessions / empty
  /// boxes. Sync-ish: only touches the already-open boxes; callers that
  /// might hit a cold session should await [msgsBox] first.
  ///
  /// A MISSING marker means "nothing has been read" — modeled as -1, not
  /// 0: seqs are allocated from zero (SyncService), so a default of 0
  /// would permanently hide the first unread row and report 0 unread for
  /// a one-message session (PR #71 review).
  int unreadCount(String epk, String roomId) {
    if (!isMsgsBoxOpen(epk, roomId)) return 0;
    final box = openMsgsBox(epk, roomId);
    final lastRead =
        (readMarkersBox().get(sessionKey(epk, roomId)) as int?) ?? -1;
    var n = 0;
    for (final k in box.keys) {
      if (k is int && k > lastRead) n++;
    }
    return n;
  }

  /// Plan/149 — mark a session read up to [upToSeq] (chat open). Never
  /// moves the marker backwards (a racing delivery for an older replayed
  /// seq must not clear newer unread).
  void markRead(String epk, String roomId, int upToSeq) {
    final markers = readMarkersBox();
    final current = (markers.get(sessionKey(epk, roomId)) as int?) ?? -1;
    if (upToSeq > current) markers.put(sessionKey(epk, roomId), upToSeq);
  }

  /// Plan/149 (PR #71 review) — wipe the read marker when a room's local
  /// message history resets (session_new / new-conversation detection):
  /// seqs restart at 0, so a stale marker (e.g. 100) would suppress every
  /// unread row until the new conversation's seq passes it.
  void clearReadMarker(String epk, String roomId) {
    readMarkersBox().delete(sessionKey(epk, roomId));
  }

  /// Per-session message box. Lazily opened; idempotent (returns the already
  /// open box on subsequent calls).
  Future<Box<dynamic>> msgsBox(String epk, String roomId) =>
      Hive.openBox<dynamic>(msgsBoxName(epk, roomId));

  /// Synchronous accessor for a msgs box known to be open already.
  Box<dynamic> openMsgsBox(String epk, String roomId) =>
      Hive.box<dynamic>(msgsBoxName(epk, roomId));

  bool isMsgsBoxOpen(String epk, String roomId) =>
      Hive.isBoxOpen(msgsBoxName(epk, roomId));

  /// Grouped-Home (by-model) preview — the text of the session's most
  /// recent user prompt, or `null` when unknown (box not open yet, no
  /// user row, or only image-only sends). Picks the user row with the
  /// highest `ts` (seq is storage order, not chronology, once backward
  /// history paging appends older pages with fresh seqs). Whitespace is
  /// collapsed by the caller for a single-line subtitle.
  String? lastUserPrompt(String epk, String roomId) {
    if (!isMsgsBoxOpen(epk, roomId)) return null;
    final box = openMsgsBox(epk, roomId);
    String? bestText;
    var bestTs = -1;
    var bestSeq = -1;
    for (final entry in box.toMap().entries) {
      final value = entry.value;
      if (value is! Map) continue;
      if (value['role'] != 'user') continue;
      final text = (value['text'] as String?)?.trim();
      if (text == null || text.isEmpty) continue; // image-only send
      final ts = (value['ts'] as num?)?.toInt() ?? 0;
      final seq = entry.key is int ? entry.key as int : -1;
      if (ts > bestTs || (ts == bestTs && seq > bestSeq)) {
        bestTs = ts;
        bestSeq = seq;
        bestText = text;
      }
    }
    return bestText;
  }

  /// `:` and the epk's `/`+`=` would break the on-disk filename — sanitise to
  /// the url-safe, unpadded epk form (same approach as the v1 store).
  static String msgsBoxName(String epk, String roomId) =>
      'msgs_${toAppEpk(epk)}__$roomId';

  static String sessionKey(String epk, String roomId) => '$epk:$roomId';
}
