// Plan 125 — foreground-service lifecycle tests.
// (Layer 0) the service must only run while backgrounded. (Layer 4) the three-way
// KeepAliveMode (off / always / whenCharging) + the charging gate. `isAndroid:
// () => true` exercises the Android-only branch on a desktop host; tests drive
// the charging state explicitly via [KeepAliveController.setCharging].
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/keep_alive_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('ch.pungitore.piper/keepalive');

/// Minimal Preferences double: only `keepAliveMode` matters here. Everything
/// else forwards to `noSuchMethod` so the test fails loudly if the controller
/// starts depending on another preference.
class _KeepAlivePrefs extends Preferences {
  _KeepAlivePrefs(this._mode) : super(_NoopSecureStorage());
  final KeepAliveMode _mode;
  @override
  KeepAliveMode get keepAliveMode => _mode;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// `FlutterSecureStorage` stand-in that answers everything via noSuchMethod.
/// The fake never calls any storage method, so a no-op is sufficient.
class _NoopSecureStorage implements FlutterSecureStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records service lifecycle calls (start / stop / update). Permission probes
/// and `isCharging` are handled separately and NOT recorded; tests drive the
/// charging state explicitly via [KeepAliveController.setCharging].
List<String> recordChannel(WidgetTester tester) {
  final calls = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
    call,
  ) async {
    switch (call.method) {
      case 'hasNotificationPermission':
      case 'requestNotificationPermission':
        return true; // pretend granted → no prompt
      case 'isCharging':
        return false; // tests drive charging via setCharging() directly
      case 'start':
      case 'stop':
      case 'update':
        calls.add(call.method);
        return true;
      default:
        return null;
    }
  });
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      null,
    ),
  );
  return calls;
}

void main() {
  KeepAliveController sut({required KeepAliveMode mode}) => KeepAliveController(
    _KeepAlivePrefs(mode),
    isAndroid: () => true,
    enableChargingPoll: false,
  );

  testWidgets(
    'plan 125: never starts the service while foregrounded, even with a peer',
    (tester) async {
      final calls = recordChannel(tester);
      final c = sut(mode: KeepAliveMode.always);
      addTearDown(c.dispose);

      await c.reflect(const StatusConnecting());
      await tester.pump();

      expect(
        calls,
        isEmpty,
        reason: 'service must not start while foregrounded',
      );
    },
  );

  testWidgets(
    'plan 125: starts on background (with peer) and stops on foreground',
    (tester) async {
      final calls = recordChannel(tester);
      final c = sut(mode: KeepAliveMode.always);
      addTearDown(c.dispose);

      await c.reflect(const StatusConnecting());
      await tester.pump();
      expect(calls, isEmpty);

      c.setBackgrounded(true);
      await tester.pump();
      expect(calls, containsAllInOrder(<String>['start']));

      c.setBackgrounded(false);
      await tester.pump();
      expect(calls, containsAllInOrder(<String>['start', 'stop']));
    },
  );

  testWidgets(
    'plan 125: backgrounding with StatusNoPeer does NOT start the service',
    (tester) async {
      final calls = recordChannel(tester);
      final c = sut(mode: KeepAliveMode.always);
      addTearDown(c.dispose);

      await c.reflect(const StatusNoPeer());
      await tester.pump();
      c.setBackgrounded(true);
      await tester.pump();

      expect(
        calls,
        isEmpty,
        reason: 'no peer ⇒ no service even if backgrounded',
      );
    },
  );

  testWidgets(
    'plan 125 (Layer 4): mode OFF ⇒ service never starts, even backgrounded',
    (tester) async {
      final calls = recordChannel(tester);
      final c = sut(mode: KeepAliveMode.off);
      addTearDown(c.dispose);

      await c.reflect(const StatusConnecting());
      await tester.pump();
      c.setBackgrounded(true);
      await tester.pump();
      c.setCharging(true); // even charging must not override OFF
      await tester.pump();

      expect(calls, isEmpty, reason: 'mode off ⇒ service never starts');
    },
  );

  testWidgets(
    'plan 125: a status change while backgrounded updates the notification',
    (tester) async {
      final calls = recordChannel(tester);
      final c = sut(mode: KeepAliveMode.always);
      addTearDown(c.dispose);

      await c.reflect(const StatusConnecting());
      await tester.pump();
      c.setBackgrounded(true);
      await tester.pump();
      expect(calls, <String>['start']);

      await c.reflect(
        const StatusRetrying(nextRetry: Duration.zero, attempt: 0),
      );
      await tester.pump();
      expect(calls, containsAllInOrder(<String>['start', 'update']));
    },
  );

  testWidgets(
    'plan 125 (Layer 4): whenCharging starts only while charging + backgrounded',
    (tester) async {
      final calls = recordChannel(tester);
      final c = sut(mode: KeepAliveMode.whenCharging);
      addTearDown(c.dispose);

      await c.reflect(const StatusConnecting());
      await tester.pump();

      // Not charging + backgrounded → no service.
      c.setCharging(false);
      c.setBackgrounded(true);
      await tester.pump();
      expect(calls, isEmpty, reason: 'whenCharging + not charging ⇒ no start');

      // Plug in → service starts.
      c.setCharging(true);
      await tester.pump();
      expect(calls, containsAllInOrder(<String>['start']));

      // Unplug → service stops (the core battery-saving behaviour).
      c.setCharging(false);
      await tester.pump();
      expect(calls, containsAllInOrder(<String>['start', 'stop']));

      // Foreground → stays stopped.
      c.setBackgrounded(false);
      await tester.pump();
      expect(calls, containsAllInOrder(<String>['start', 'stop']));
    },
  );

  testWidgets(
    'plan 125 (Layer 4): whenCharging + charging but foregrounded → no start',
    (tester) async {
      final calls = recordChannel(tester);
      final c = sut(mode: KeepAliveMode.whenCharging);
      addTearDown(c.dispose);

      c.setCharging(true);
      await c.reflect(const StatusConnecting());
      await tester.pump();

      expect(
        calls,
        isEmpty,
        reason: 'foregrounded ⇒ no service even if charging',
      );
    },
  );
}
