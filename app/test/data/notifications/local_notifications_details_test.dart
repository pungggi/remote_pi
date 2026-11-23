// Plan/171 — notification channel contract per urgency: the pure builder
// behind show()/showActionRequired(), plus the optional-capability seam
// (IActionRequiredNotifications) that keeps pre-plan/171 fakes untouched.

import 'package:app/data/notifications/local_notifications.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [LocalNotifications] that PREDATES plan/171: no capability interface.
/// `postActionRequired` must keep working for it (plain channel).
class _PlainFake implements LocalNotifications {
  final shown = <int>[];

  @override
  Future<void> initialize() async {}
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    shown.add(id);
  }

  @override
  Future<void> cancel(int id) async {}
  @override
  Stream<String> get taps => const Stream.empty();
  @override
  Future<String?> consumeLaunchTap() async => null;
}

/// Same fake plus the capability: the heads-up path must win.
class _CapableFake extends _PlainFake implements IActionRequiredNotifications {
  final urgent = <int>[];

  @override
  Future<void> showActionRequired({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    urgent.add(id);
  }
}

void main() {
  AndroidNotificationDetails androidOf(NotificationUrgency u) {
    final details = FlutterLocalNotifications.detailsFor(u).android;
    expect(details, isNotNull, reason: 'android details for $u');
    return details!;
  }

  test('normal urgency stays on the informational completion channel', () {
    final android = androidOf(NotificationUrgency.normal);
    expect(android.channelId, FlutterLocalNotifications.channelId);
    expect(android.importance, Importance.defaultImportance);
    expect(android.priority, Priority.defaultPriority);
  });

  test('action-required urgency is a NEW high-importance channel', () {
    final android = androidOf(NotificationUrgency.actionRequired);
    expect(
      android.channelId,
      FlutterLocalNotifications.actionRequiredChannelId,
    );
    // Android freezes a channel's importance at creation: re-using the
    // completion channel could never raise these to heads-up.
    expect(android.channelId, isNot(FlutterLocalNotifications.channelId));
    expect(android.importance, Importance.high);
    expect(android.priority, Priority.high);
  });

  test('postActionRequired falls back to show without the capability',
      () async {
    final fake = _PlainFake();
    await postActionRequired(
      fake,
      id: 42,
      title: 'Session is asking you',
      body: 'plan/170 test · 1 question',
    );
    expect(fake.shown, [42]);
  });

  test('postActionRequired takes the heads-up path with the capability',
      () async {
    final fake = _CapableFake();
    await postActionRequired(
      fake,
      id: 43,
      title: 'backend',
      body: 'Pi is waiting for input at the terminal.',
    );
    expect(fake.urgent, [43]);
    expect(fake.shown, isEmpty);
  });
}
