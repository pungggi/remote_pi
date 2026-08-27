// Plan/132 — SessionCompletionNotifications: the toggle (durable) + the
// notification gate (backgrounded → enabled → dedup → permission).

import 'dart:async';
import 'dart:io';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/notifications/local_notifications.dart';
import 'package:app/data/notifications/session_completion_notifications.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class _FakeLocalNotifications implements LocalNotifications {
  bool permission = true;
  final List<({int id, String title, String body, String? payload})> shown = [];

  /// Plan 132 review fix — simulates the cold-start launch payload.
  String? launchPayload;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> requestPermission() async => permission;

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    shown.add((id: id, title: title, body: body, payload: payload));
  }

  @override
  Stream<String> get taps => const Stream.empty();

  @override
  Future<String?> consumeLaunchTap() async {
    final p = launchPayload;
    launchPayload = null;
    return p;
  }
}

void main() {
  late Directory tmp;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('piper_131_');
    await LocalBoxes.initForTest(tmp.path);
  });

  tearDownAll(() async {
    // Close Hive's grip on the temp dir before deleting — on Windows the
    // box files are still open and delete() fails with errno 32.
    await Hive.close();
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup only.
    }
  });

  setUp(() async {
    // Isolation: the notify box is durable — clear it between tests.
    await LocalBoxes().notifyPrefsBox().clear();
  });

  SessionCompletionNotifications build(_FakeLocalNotifications local) =>
      SessionCompletionNotifications(
        boxes: LocalBoxes(),
        local: local,
        roomTitle: (epk, roomId) => epk == 'epkX' ? 'backend' : null,
      );

  RunDoneEvent marker(String roomId, int endedAt, {String? turnId}) =>
      RunDoneEvent(
        epk: 'epkX',
        roomId: roomId,
        marker: RunDoneMarker(turnId: turnId, endedAtMs: endedAt),
      );

  test('toggle defaults off and persists through the box', () async {
    final local = _FakeLocalNotifications();
    final svc = build(local);

    expect(svc.isEnabled('epkX', 'r1'), isFalse);
    await svc.setEnabled('epkX', 'r1', true);
    expect(svc.isEnabled('epkX', 'r1'), isTrue);
    await svc.setEnabled('epkX', 'r1', false);
    expect(svc.isEnabled('epkX', 'r1'), isFalse);
  });

  test('gate order — foreground, disabled, dedup, permission', () async {
    final local = _FakeLocalNotifications();
    final svc = build(local);
    final events = StreamController<RunDoneEvent>.broadcast();
    svc.attach(events.stream);
    await svc.setEnabled('epkX', 'r1', true);

    // Foreground → suppressed.
    svc.setBackgrounded(false);
    events.add(marker('r1', 100));
    await Future<void>.delayed(Duration.zero);
    expect(local.shown, isEmpty);

    // Backgrounded but different room (toggle off) → suppressed.
    svc.setBackgrounded(true);
    events.add(marker('r2', 100));
    await Future<void>.delayed(Duration.zero);
    expect(local.shown, isEmpty);

    // Backgrounded + enabled → shown once, titled, payload = prefs key.
    events.add(marker('r1', 100));
    await Future<void>.delayed(Duration.zero);
    expect(local.shown.length, 1);
    expect(local.shown.single.title, 'backend');
    expect(local.shown.single.body, contains('Task finished'));
    expect(local.shown.single.payload, SessionCompletionNotifications.prefsKey(
      'epkX',
      'r1',
    ));

    // Duplicate re-broadcast (same or older ended_at) → deduped.
    events.add(marker('r1', 100));
    events.add(marker('r1', 99));
    await Future<void>.delayed(Duration.zero);
    expect(local.shown.length, 1);

    // Newer marker → replaces (same stable id).
    events.add(marker('r1', 200, turnId: 't2'));
    await Future<void>.delayed(Duration.zero);
    expect(local.shown.length, 2);
    expect(local.shown.last.id, local.shown.first.id);

    // Permission revoked → suppressed (dedup state untouched by this test).
    local.permission = false;
    events.add(marker('r1', 300));
    await Future<void>.delayed(Duration.zero);
    expect(local.shown.length, 2);

    await events.close();
  });

  test('title falls back to "Session" when the resolver misses', () async {
    final local = _FakeLocalNotifications();
    final svc = build(local);
    final events = StreamController<RunDoneEvent>.broadcast();
    svc.attach(events.stream);
    await svc.setEnabled('otherEpk', 'r9', true);
    svc.setBackgrounded(true);

    events.add(
      RunDoneEvent(
        epk: 'otherEpk',
        roomId: 'r9',
        marker: const RunDoneMarker(turnId: null, endedAtMs: 5),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(local.shown.single.title, 'Session');
    await events.close();
  });

  test('stableNotificationId is deterministic, positive, 31-bit, and key-distinct', () {
    final a = SessionCompletionNotifications.stableNotificationId(
      'epkX:r1',
    );
    final b = SessionCompletionNotifications.stableNotificationId(
      'epkX:r1',
    );
    // Deterministic across calls (and across restarts — FNV-1a, NOT
    // String.hashCode, which Dart seeds randomly per isolate).
    expect(a, b);
    expect(a, greaterThanOrEqualTo(0));
    expect(a, lessThan(0x80000000));
    expect(
      SessionCompletionNotifications.stableNotificationId('epkX:r2'),
      isNot(equals(a)),
    );
  });

  test('parsePayload round-trips the prefs key', () {
    final key = SessionCompletionNotifications.prefsKey('epk+X=', 'r1');
    final back = SessionCompletionNotifications.parsePayload(key);
    expect(back, isNotNull);
    expect(back!.epk, 'epk+X=');
    expect(back.roomId, 'r1');
    expect(SessionCompletionNotifications.parsePayload('no-separator'),
        isNull);
    expect(SessionCompletionNotifications.parsePayload(':r1'), isNull);
    expect(SessionCompletionNotifications.parsePayload('epk:'), isNull);
  });
}
