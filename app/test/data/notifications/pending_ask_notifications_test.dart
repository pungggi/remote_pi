// Plan/170 — PendingAskNotifications: badge set + notification lifecycle
// driven by device-room fanout hints (open/clear per (epk, roomId, flowId)),
// persistence across restarts, and the stale-badge self-heal (clearRoom).

import 'dart:async';
import 'dart:io';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/notifications/local_notifications.dart';
import 'package:app/data/notifications/pending_ask_notifications.dart';
import 'package:app/data/notifications/session_completion_notifications.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeLocalNotifications implements LocalNotifications {
  bool permission = true;
  final List<({int id, String title, String body, String? payload})> shown = [];
  final List<int> cancelled = [];

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
  Future<void> cancel(int id) async {
    cancelled.add(id);
  }

  @override
  Stream<String> get taps => const Stream.empty();

  @override
  Future<String?> consumeLaunchTap() async => null;
}

void main() {
  setUpAll(() async {
    final tmp = await Directory.systemTemp.createTemp('pending_ask_test');
    await LocalBoxes.initForTest(tmp.path);
  });

  setUp(() async {
    await LocalBoxes().runtimeBox().clear();
  });

  // 'epkX' is already standard base64 (no '-'/'_'), so the canonical key is
  // 'epkX:r1' — matches the completion-banner payload format verbatim.
  PendingAskEvent ask(
    bool open, {
    String flow = 'f1',
    String roomId = 'r1',
    String? title,
    int? questionCount,
  }) => PendingAskEvent(
    epk: 'epkX',
    roomId: roomId,
    flowId: flow,
    open: open,
    title: title,
    questionCount: questionCount,
  );

  test('open → badge + notification with the canonical tap payload', () async {
    final local = _FakeLocalNotifications();
    final svc = PendingAskNotifications(boxes: LocalBoxes(), local: local);
    await svc.attach(Stream.empty());

    final ctrl = StreamController<PendingAskEvent>.broadcast();
    await svc.attach(ctrl.stream);
    ctrl.add(ask(true, title: 'Direction', questionCount: 2));
    await pumpEventQueue();

    expect(svc.isAsking('epkX', 'r1'), isTrue);
    expect(local.shown, hasLength(1));
    expect(local.shown.single.payload, 'epkX:r1');
    expect(local.shown.single.title, 'Session is asking you');
    expect(local.shown.single.body, contains('Direction'));
    expect(local.shown.single.body, contains('2 questions'));
    // Same stable id the completion banners would derive for this room.
    expect(
      local.shown.single.id,
      SessionCompletionNotifications.stableNotificationId('epkX:r1'),
    );
    expect(local.cancelled, isEmpty);
  });

  test('replayed open for a known flow does not re-notify', () async {
    final local = _FakeLocalNotifications();
    final svc = PendingAskNotifications(boxes: LocalBoxes(), local: local);
    final ctrl = StreamController<PendingAskEvent>.broadcast();
    await svc.attach(ctrl.stream);
    ctrl.add(ask(true));
    ctrl.add(ask(true)); // journal replay after re-attach
    await pumpEventQueue();

    expect(local.shown, hasLength(1));
    expect(svc.isAsking('epkX', 'r1'), isTrue);
  });

  test('last flow closing cancels; earlier closes keep the badge', () async {
    final local = _FakeLocalNotifications();
    final svc = PendingAskNotifications(boxes: LocalBoxes(), local: local);
    final ctrl = StreamController<PendingAskEvent>.broadcast();
    await svc.attach(ctrl.stream);
    ctrl.add(ask(true, flow: 'f1'));
    ctrl.add(ask(true, flow: 'f2'));
    ctrl.add(ask(false, flow: 'f1'));
    await pumpEventQueue();

    expect(svc.isAsking('epkX', 'r1'), isTrue);
    expect(local.cancelled, isEmpty);

    ctrl.add(ask(false, flow: 'f2'));
    await pumpEventQueue();

    expect(svc.isAsking('epkX', 'r1'), isFalse);
    final id = SessionCompletionNotifications.stableNotificationId('epkX:r1');
    expect(local.cancelled, contains(id));
  });

  test('clear for an unknown flow is a no-op (no change event)', () async {
    final local = _FakeLocalNotifications();
    final svc = PendingAskNotifications(boxes: LocalBoxes(), local: local);
    final ctrl = StreamController<PendingAskEvent>.broadcast();
    await svc.attach(ctrl.stream);
    var changes = 0;
    // ignore: unawaited_futures
    svc.changes.listen((_) => changes++);
    ctrl.add(ask(true, flow: 'f1'));
    await pumpEventQueue();
    expect(changes, 1);

    ctrl.add(ask(false, flow: 'never-opened'));
    await pumpEventQueue();
    expect(changes, 1);
    expect(svc.isAsking('epkX', 'r1'), isTrue);
  });

  test('badges persist across restart; reload does not re-notify', () async {
    final local = _FakeLocalNotifications();
    final first = PendingAskNotifications(boxes: LocalBoxes(), local: local);
    final ctrl = StreamController<PendingAskEvent>.broadcast();
    await first.attach(ctrl.stream);
    ctrl.add(ask(true, flow: 'f1'));
    await pumpEventQueue();
    expect(local.shown, hasLength(1));
    first.dispose();

    // Fresh instance (app relaunch): the badge survives from the runtime
    // box, but no notification fires until a NEW edge arrives.
    final local2 = _FakeLocalNotifications();
    final second = PendingAskNotifications(boxes: LocalBoxes(), local: local2);
    await second.attach(Stream.empty());
    expect(second.isAsking('epkX', 'r1'), isTrue);
    expect(local2.shown, isEmpty);
  });

  test('self-heal clearRoom drops the badge + cancels the notification',
      () async {
    final local = _FakeLocalNotifications();
    final svc = PendingAskNotifications(boxes: LocalBoxes(), local: local);
    final ctrl = StreamController<PendingAskEvent>.broadcast();
    await svc.attach(ctrl.stream);
    ctrl.add(ask(true, flow: 'f1'));
    ctrl.add(ask(true, flow: 'f2'));
    await pumpEventQueue();

    await svc.clearRoom('epkX', 'r1');
    await pumpEventQueue();

    expect(svc.isAsking('epkX', 'r1'), isFalse);
    final id = SessionCompletionNotifications.stableNotificationId('epkX:r1');
    expect(local.cancelled, contains(id));

    // Persisted clear: a restart must NOT resurrect the badge.
    final revived = PendingAskNotifications(
      boxes: LocalBoxes(),
      local: _FakeLocalNotifications(),
    );
    await revived.attach(Stream.empty());
    expect(revived.isAsking('epkX', 'r1'), isFalse);
  });

  test('url-safe epk variants resolve to the same room', () async {
    final local = _FakeLocalNotifications();
    final svc = PendingAskNotifications(boxes: LocalBoxes(), local: local);
    final ctrl = StreamController<PendingAskEvent>.broadcast();
    await svc.attach(ctrl.stream);
    // {0xFB,0xEF,0xBE} encodes as '++++' (standard) / '----' (url-safe) —
    // the two flavors every epk exists in (QR/storage vs relay wire).
    // Normalized, they are ONE key: a clear arriving under the other
    // flavor must hit the same entry.
    ctrl.add(
      PendingAskEvent(
        epk: '----',
        roomId: 'r1',
        flowId: 'f1',
        open: true,
      ),
    );
    await pumpEventQueue();
    expect(svc.isAsking('++++', 'r1'), isTrue);

    ctrl.add(
      PendingAskEvent(
        epk: '++++',
        roomId: 'r1',
        flowId: 'f1',
        open: false,
      ),
    );
    await pumpEventQueue();
    expect(svc.isAsking('----', 'r1'), isFalse);
  });

  test('two rooms badge independently', () async {
    final local = _FakeLocalNotifications();
    final svc = PendingAskNotifications(boxes: LocalBoxes(), local: local);
    final ctrl = StreamController<PendingAskEvent>.broadcast();
    await svc.attach(ctrl.stream);
    ctrl.add(ask(true, roomId: 'r1', flow: 'f1'));
    ctrl.add(ask(true, roomId: 'r2', flow: 'f9'));
    await pumpEventQueue();

    expect(svc.isAsking('epkX', 'r1'), isTrue);
    expect(svc.isAsking('epkX', 'r2'), isTrue);
    expect(local.shown, hasLength(2));
    // Distinct stable ids → banners replace per room, never stack.
    expect(local.shown[0].id, isNot(local.shown[1].id));
  });
}
