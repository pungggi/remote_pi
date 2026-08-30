// Plan/134 — WaitingInputNotifications: the notification gate
// (rising-edge → backgrounded → sheet-dedupe → permission).

import 'dart:async';

import 'package:app/data/notifications/local_notifications.dart';
import 'package:app/data/notifications/session_completion_notifications.dart';
import 'package:app/data/notifications/waiting_input_notifications.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeLocalNotifications implements LocalNotifications {
  bool permission = true;
  final List<({int id, String title, String body, String? payload})> shown = [];

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
  Future<String?> consumeLaunchTap() async => null;
}

void main() {
  WaitingForInputEvent event(bool waiting, {String roomId = 'r1'}) =>
      WaitingForInputEvent(
        epk: 'epkX',
        roomId: roomId,
        waiting: waiting,
      );

  test('rising edge + backgrounded fires the generic banner', () async {
    final local = _FakeLocalNotifications();
    final svc = WaitingInputNotifications(local: local)
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

  test('falling edge never fires (the badge just clears)', () async {
    final local = _FakeLocalNotifications();
    final svc = WaitingInputNotifications(local: local);
    svc.setBackgrounded(true);

    final ctrl = StreamController<WaitingForInputEvent>.broadcast();
    svc.attach(ctrl.stream);
    ctrl.add(event(false));
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(local.shown, isEmpty);

    await ctrl.close();
    svc.dispose();
  });

  test('foreground suppresses the banner (tiles already show the badge)',
      () async {
    final local = _FakeLocalNotifications();
    final svc = WaitingInputNotifications(local: local);
    svc.setBackgrounded(false);

    final ctrl = StreamController<WaitingForInputEvent>.broadcast();
    svc.attach(ctrl.stream);
    ctrl.add(event(true));
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(local.shown, isEmpty);

    await ctrl.close();
    svc.dispose();
  });

  test(
      'pi-ask sheet already open for the room suppresses the generic banner',
      () async {
    final local = _FakeLocalNotifications();
    final svc = WaitingInputNotifications(local: local)
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

  test('denied permission suppresses the banner', () async {
    final local = _FakeLocalNotifications()..permission = false;
    final svc = WaitingInputNotifications(local: local);
    svc.setBackgrounded(true);

    final ctrl = StreamController<WaitingForInputEvent>.broadcast();
    svc.attach(ctrl.stream);
    ctrl.add(event(true));
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(local.shown, isEmpty);

    await ctrl.close();
    svc.dispose();
  });

  test('missing title resolver falls back to "Session"', () async {
    final local = _FakeLocalNotifications();
    final svc = WaitingInputNotifications(local: local);
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
    final svc = WaitingInputNotifications(local: local);
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
}

