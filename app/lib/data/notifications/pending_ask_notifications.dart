import 'dart:async';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/notifications/local_notifications.dart';
import 'package:app/data/notifications/session_completion_notifications.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/domain/contracts/service.dart';
import 'package:app/protocol/protocol.dart';

/// Plan/170 — "session X is waiting for your answer" hints.
///
/// The phone keeps ONE connection and switches rooms; the `device` room is
/// the always-on home base (Home/Projects). A `pending_ask` frame arriving
/// there means an ask flow opened in a session whose room the app is NOT
/// attached to — historically a dead end (no live frame, no resume replay,
/// no notification: the 6-hour wedge of 2026-11-22). This service turns
/// those hints into:
///
/// - a **notification** per asking session (stable id by canonical key —
///   replaces, never stacks; cancelled when the last flow clears);
/// - a persisted **badge set** (`isAsking`) Home tiles can read, surviving
///   app restarts until a clear arrives or the chat's own sync self-heals.
///
/// The hint is NEVER the source of truth: opening the chat replays the real
/// sheet via `session_sync` → `pendingRequests` (plan/100/129).
///
/// Dedupe: keyed by `(epk, roomId, flowId)`; a replayed open for a known
/// flow (device-room journal catch-up after re-attach) does not re-notify.
/// The notification payload is the SAME canonical `<standardB64(epk)>:<roomId>`
/// key the completion banners use, so main()'s existing tap routing opens
/// the right chat with zero new plumbing.
class PendingAskNotifications extends Service {
  final LocalBoxes _boxes;
  final LocalNotifications _local;

  StreamSubscription<PendingAskEvent>? _sub;

  /// Events observed before [_attach]'s load finished, replayed in order
  /// once the persisted set is live. Review #117: an ask landing exactly in
  /// the app-start window (device-room journal replay) must not be lost —
  /// dropping it would silence the badge until the next edge.
  final List<PendingAskEvent> _preAttachBuffer = [];

  /// canonical key → open flow ids. Null until [_attach] loads the box.
  Map<String, Set<String>>? _openFlows;

  final _changesController = StreamController<void>.broadcast();

  static const _boxKey = 'pending_ask_flows';

  PendingAskNotifications({required LocalBoxes boxes, required LocalNotifications local})
      : _boxes = boxes,
        _local = local;

  /// Wire to [ConnectionManager.pendingAskStream]. Async: loads the persisted
  /// badge set while SUBSCRIBED — events arriving mid-load are buffered by
  /// [_onEvent] and replayed after, so [isAsking] never flickers AND no
  /// start-window event is lost (review #117 race fix).
  Future<void> attach(Stream<PendingAskEvent> stream) async {
    _sub?.cancel();
    _sub = stream.listen(_onEvent, onError: (Object _, StackTrace _) {});
    await _loadPersisted();
    if (_preAttachBuffer.isEmpty) return;
    final buffered = List<PendingAskEvent>.of(_preAttachBuffer);
    _preAttachBuffer.clear();
    for (final e in buffered) {
      _onEvent(e);
    }
  }

  /// Whether session `(epk, roomId)` has at least one open ask flow.
  /// `epk` accepts either base64 flavor (normalized internally).
  bool isAsking(String epk, String roomId) {
    final flows = _openFlows?[canonicalKey(epk, roomId)];
    return flows != null && flows.isNotEmpty;
  }

  /// Fires on every badge-set change (open/clear) — Home rebuilds on this.
  Stream<void> get changes => _changesController.stream;

  /// Plan/170 — self-heal: the room's own sync settled with no pending
  /// interactive request, so every badge hint for it is stale. Clears all
  /// flows for the room, cancels its notification, persists, and notifies
  /// listeners. Also the manual reset path (debug / future UI).
  Future<void> clearRoom(String epk, String roomId) async {
    final flows = _openFlows;
    if (flows == null) return;
    final key = canonicalKey(epk, roomId);
    if (flows.remove(key) == null) return;
    _persist();
    _changesController.add(null);
    await _local.cancel(
      SessionCompletionNotifications.stableNotificationId(key),
    );
  }

  static String canonicalKey(String epk, String roomId) =>
      '${toStandardB64(epk)}:$roomId';

  void _onEvent(PendingAskEvent e) {
    final flows = _openFlows;
    if (flows == null) {
      // attach()'s load is still in flight — buffer, don't drop.
      _preAttachBuffer.add(e);
      return;
    }
    final key = canonicalKey(e.epk, e.roomId);
    final had = flows[key]?.isNotEmpty ?? false;
    if (e.open) {
      final set = flows[key] ?? <String>{};
      if (set.contains(e.flowId)) return; // replayed open — already badged
      set.add(e.flowId);
      flows[key] = set;
    } else {
      final set = flows[key];
      if (set == null || !set.remove(e.flowId)) return; // unknown clear
      if (set.isEmpty) flows.remove(key);
    }
    final has = flows[key]?.isNotEmpty ?? false;
    _persist();
    if (had != has) {
      _changesController.add(null);
      // Rising edge notifies; falling edge cancels — a mid-edge set change
      // (second flow opens) only refreshes the body.
      // ignore: unawaited_futures
      _notify(key, has, e);
    }
  }

  Future<void> _notify(String key, bool has, PendingAskEvent e) async {
    final id = SessionCompletionNotifications.stableNotificationId(key);
    if (!has) {
      await _local.cancel(id);
      return;
    }
    final questions = e.questionCount;
    final body = StringBuffer();
    if (e.title case final title?) body.write(title);
    if (questions != null && questions > 0) {
      if (body.isNotEmpty) body.write(' · ');
      body.write('$questions question${questions == 1 ? '' : 's'}');
    }
    if (body.isEmpty) body.write('The agent needs your answer to continue.');
    await _local.show(
      id: id,
      title: 'Session is asking you',
      body: body.toString(),
      // Same canonical-key payload as plan/132 banners: main()'s existing
      // tap routing (_openFromCompletionTap) opens this chat unchanged.
      payload: key,
    );
  }

  Future<void> _loadPersisted() async {
    if (_openFlows != null) return;
    final map = <String, Set<String>>{};
    try {
      final raw = _boxes.runtimeBox().get(_boxKey);
      if (raw is Map) {
        for (final entry in raw.entries) {
          if (entry.key is String && entry.value is List) {
            map[entry.key as String] =
                (entry.value as List).whereType<String>().toSet();
          }
        }
      }
    } catch (_) {
      // Corrupt box → start clean (badges self-heal on the next sync).
    }
    _openFlows = map;
  }

  void _persist() {
    final flows = _openFlows;
    if (flows == null) return;
    // Hive has no Set adapter — persist Lists (the load path converts
    // back). Snapshot first so a later in-memory mutation can't race the
    // async write, and swallow async errors: persistence is best-effort,
    // the in-memory set stays authoritative.
    final snapshot = <String, List<String>>{
      for (final e in flows.entries) e.key: e.value.toList(),
    };
    // ignore: unawaited_futures, body_might_complete_normally
    _boxes.runtimeBox().put(_boxKey, snapshot).catchError((Object _) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    _preAttachBuffer.clear();
    _changesController.close();
  }
}
