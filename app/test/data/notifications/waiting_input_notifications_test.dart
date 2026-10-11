// Plan/134 — WaitingInputNotifications: the notification gate
// (rising-edge → backgrounded → sheet-dedupe → permission).
// Plan/141 — background snapshot, cancel-on-clear, proactive permission ask.

import 'dart:async';
import 'dart:io';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/notifications/local_notifications.dart';
import 'package:app/data/notifications/session_completion_notifications.dart';
import 'package:app/data/notifications/waiting_input_notifications.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeLocalNotifications implements LocalNotifications {
  bool permission = true;
  final List<({int id, String title, String body, String? payload})> shown = [];
  final List<int> cancelled = [];
  int requests = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> requestPermission() async {
    requests++;
    return permission;
  }

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
    final tmp = await Directory.systemTemp.createTemp('waiting_notif_test');
    await LocalBoxes.initForTest(tmp.path);
  });

  setUp(() async {
    await LocalBoxes().notifyPrefsBox().clear();
  });

  WaitingForInputEvent event(bool waiting, {String roomId = 'r1'}) =>
      WaitingForInputEvent(
        epk: 'epkX',
        roomId: roomId,
        waiting: waiting,
      );

  test('rising edge + backgrounded fires the generic banner', () async {
    final local = _FakeLocalNotifications();
    final svc = WaitingInputNotifications(boxes: LocalBoxes(), local: local)
      ..roomTitle = (epk, roomId) => 'backend';
    svc.setBackgrounded(true);

    final ctrl = StreamController<WaitingForInputEvent>.broadcast();
    svc.attach(ctrl.stream);
    ctrl.add(event(true));
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(local.shown.length, 1);
    expect(local.shown.single.title, 'backend');
    expect(local.shown.single.body, 'Pi is waiting for input at the terminal.');
    expect(local.shown.single.payload, 'epkX:r1');

    await ctrl.close();
    svc.dispose();
  });

  test('falling edge cancels the banner (plan/141 — no stale tray entry)',
      () async {
    final local = _FakeLocalNotifications();
    final svc = WaitingInputNotifications(boxes: LocalBoxes(), local: local);
    svc.setBackgrounded(true);

    final ctrl = StreamController<WaitingForInputEvent>.broadcast();
    svc.attach(ctrl.stream);
    ctrl.add(event(true));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    ctrl.add(event(false));
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(local.shown.length, 1);
    expect(local.cancelled, [local.shown.single.id],
        reason: 'the cancelled id is exactly the id the banner showed');

    await ctrl.close();
    svc.dispose();
  });

  test('foreground rising edge ALSO fires the banner (amended 2026-10-11 — always notify)',
      () async {
    final local = _FakeLocalNotifications();
    final svc = WaitingInputNotifications(boxes: LocalBoxes(), local: local);
    svc.setBackgrounded(false);

    final ctrl = StreamController<WaitingForInputEvent>.broadcast();
    svc.attach(ctrl.stream);
    ctrl.add(event(true));
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(local.shown.length, 1,
        reason: 'the tile dot alone proved too easy to miss with the app '
            'open on the desk — the banner fires in the foreground too');
    expect(local.shown.single.payload, 'epkX:r1');

    await ctrl.close();
    svc.dispose();
  });

  test(
      'pi-ask sheet already open for the room suppresses the generic banner',
      () async {
    final local = _FakeLocalNotifications();
    final svc = WaitingInputNotifications(boxes: LocalBoxes(), local: local)
      // The sheet IS the signal for that room; another room still notifies.
      ..hasOpenAskSheet = (epk, roomId) => epk == 'epkX' && roomId == 'r1';
    svc.setBackgrounded(true);

    final ctrl = StreamController<WaitingForInputEvent>.broadcast();
    svc.attach(ctrl.stream);
    ctrl.add(event(true, roomId: 'r1')); // sheet open → suppressed
    ctrl.add(event(true, roomId: 'r2')); // foreign room → banner
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(local.shown.length, 1);
    expect(local.shown.single.payload, 'epkX:r2');

    await ctrl.close();
    svc.dispose();
  });

  test('denied permission suppresses the banner and never asks from the '
      'background', () async {
    final local = _FakeLocalNotifications()..permission = false;
    final svc = WaitingInputNotifications(boxes: LocalBoxes(), local: local);
    svc.setBackgrounded(true);

    final ctrl = StreamController<WaitingForInputEvent>.broadcast();
    svc.attach(ctrl.stream);
    ctrl.add(event(true));
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(local.shown, isEmpty);
    expect(local.requests, 0,
        reason: 'the OS dialog cannot appear while backgrounded — the '
            'once-per-install ask stays reserved for a foreground edge');

    await ctrl.close();
    svc.dispose();
  });

  test('missing title resolver falls back to "Session"', () async {
    final local = _FakeLocalNotifications();
    final svc = WaitingInputNotifications(boxes: LocalBoxes(), local: local);
    svc.setBackgrounded(true);

    final ctrl = StreamController<WaitingForInputEvent>.broadcast();
    svc.attach(ctrl.stream);
    ctrl.add(event(true));
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(local.shown.single.title, 'Session');

    await ctrl.close();
    svc.dispose();
  });

  test('a second rising edge for the same room replaces the banner (stable id)',
      () async {
    final local = _FakeLocalNotifications();
    final svc = WaitingInputNotifications(boxes: LocalBoxes(), local: local);
    svc.setBackgrounded(true);

    final ctrl = StreamController<WaitingForInputEvent>.broadcast();
    svc.attach(ctrl.stream);
    ctrl.add(event(true));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    ctrl.add(event(false));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    ctrl.add(event(true));
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(local.shown.length, 2);
    expect(local.shown[0].id, local.shown[1].id,
        reason: 'stable per-session id — the new banner replaces the old one');
    // And it never collides with the completion banner's id namespace.
    expect(
      local.shown.last.id !=
          SessionCompletionNotifications.stableNotificationId(
            SessionCompletionNotifications.prefsKey('epkX', 'r1'),
          ),
      isTrue,
    );

    await ctrl.close();
    svc.dispose();
  });

  group('plan/141 — background snapshot', () {
    test('backgrounding fires for every live waiting room', () async {
      final local = _FakeLocalNotifications();
      final svc =
          WaitingInputNotifications(boxes: LocalBoxes(), local: local)
            ..roomTitle = ((epk, roomId) => 'room-$roomId')
            // r1's sheet is open (user mid-answer) — suppressed; r2/r3 fire.
            ..hasOpenAskSheet = ((epk, roomId) => roomId == 'r1')
            ..liveWaitingRooms = () => const [
                  (epk: 'epkX', roomId: 'r1'),
                  (epk: 'epkX', roomId: 'r2'),
                  (epk: 'epkY', roomId: 'r3'),
                ];

      svc.setBackgrounded(true);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(
        local.shown.map((s) => s.payload).toList(),
        unorderedEquals(['epkX:r2', 'epkY:r3']),
      );
      // Distinct stable ids per (peer, room).
      expect(local.shown.map((s) => s.id).toSet().length, 2);

      svc.dispose();
    });

    test('resuming (setBackgrounded(false)) never snapshots', () async {
      final local = _FakeLocalNotifications();
      final svc =
          WaitingInputNotifications(boxes: LocalBoxes(), local: local)
            ..liveWaitingRooms =
                () => const [(epk: 'epkX', roomId: 'r1')];

      svc.setBackgrounded(false);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(local.shown, isEmpty);

      svc.dispose();
    });

    test('no liveWaitingRooms callback (unset) is a no-op', () async {
      final local = _FakeLocalNotifications();
      final svc = WaitingInputNotifications(boxes: LocalBoxes(), local: local);

      svc.setBackgrounded(true);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(local.shown, isEmpty);

      svc.dispose();
    });

    test('snapshot is idempotent — same ids replace, never stack', () async {
      final local = _FakeLocalNotifications();
      final svc =
          WaitingInputNotifications(boxes: LocalBoxes(), local: local)
            ..liveWaitingRooms =
                () => const [(epk: 'epkX', roomId: 'r1')];

      svc.setBackgrounded(true);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      svc.setBackgrounded(false);
      svc.setBackgrounded(true);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(local.shown.length, 2);
      expect(local.shown[0].id, local.shown[1].id);

      svc.dispose();
    });
  });

  group('plan/141 — proactive permission ask', () {
    test('foreground rising edge with permission missing asks exactly once',
        () async {
      final local = _FakeLocalNotifications()..permission = false;
      final svc = WaitingInputNotifications(boxes: LocalBoxes(), local: local);
      svc.setBackgrounded(false);

      final ctrl = StreamController<WaitingForInputEvent>.broadcast();
      svc.attach(ctrl.stream);
      ctrl.add(event(true));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      ctrl.add(event(true, roomId: 'r2'));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(local.requests, 1, reason: 'durable flag prevents re-asking');
      expect(local.shown, isEmpty,
          reason: 'permission still denied after the ask — no banner');

      await ctrl.close();
      svc.dispose();
    });

    test('the ask survives a facade restart (durable flag)', () async {
      final local = _FakeLocalNotifications()..permission = false;
      final first = WaitingInputNotifications(boxes: LocalBoxes(), local: local);
      first.setBackgrounded(false);

      final ctrl = StreamController<WaitingForInputEvent>.broadcast();
      first.attach(ctrl.stream);
      ctrl.add(event(true));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await ctrl.close();
      first.dispose();

      final second =
          WaitingInputNotifications(boxes: LocalBoxes(), local: local);
      second.setBackgrounded(false);
      final ctrl2 = StreamController<WaitingForInputEvent>.broadcast();
      second.attach(ctrl2.stream);
      ctrl2.add(event(true, roomId: 'r9'));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(local.requests, 1, reason: 'once per INSTALL, not per run');
      await ctrl2.close();
      second.dispose();
    });

    test('sheet open defers the ask (never interrupt answering)', () async {
      final local = _FakeLocalNotifications()..permission = false;
      final svc =
          WaitingInputNotifications(boxes: LocalBoxes(), local: local)
            ..hasOpenAskSheet = (epk, roomId) => true;
      svc.setBackgrounded(false);

      final ctrl = StreamController<WaitingForInputEvent>.broadcast();
      svc.attach(ctrl.stream);
      ctrl.add(event(true));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(local.requests, 0);

      await ctrl.close();
      svc.dispose();
    });

    test('granted permission shows the banner without ever asking',
        () async {
      final local = _FakeLocalNotifications(); // permission = true
      final svc = WaitingInputNotifications(boxes: LocalBoxes(), local: local);
      svc.setBackgrounded(false);

      final ctrl = StreamController<WaitingForInputEvent>.broadcast();
      svc.attach(ctrl.stream);
      ctrl.add(event(true));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(local.requests, 0);
      expect(local.shown.length, 1,
          reason: 'granted installs go straight to the banner');
      expect(
        LocalBoxes().notifyPrefsBox().get('permission_asked'),
        isNot(true),
        reason: 'the flag only matters on the denied path — granted '
            'installs never consume it',
      );

      await ctrl.close();
      svc.dispose();
    });
  });
}
