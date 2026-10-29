import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/keep_alive_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('ch.pungitore.piper/keepalive');

class _Prefs extends Preferences {
  @override
  KeepAliveMode get keepAliveMode => KeepAliveMode.balanced;
}

class _AlwaysPrefs extends Preferences {
  @override
  KeepAliveMode get keepAliveMode => KeepAliveMode.always;
}

void main() {
  testWidgets('Balanced starts only for active/grace and stops for Sleeping', (
    tester,
  ) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
      call,
    ) async {
      if (call.method == 'hasNotificationPermission') return true;
      if (call.method == 'isCharging') return false;
      if (call.method == 'start' || call.method == 'stop') {
        calls.add(call.method);
      }
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _channel,
        null,
      ),
    );
    final controller = KeepAliveController(
      _Prefs(),
      isAndroid: () => true,
      enableChargingPoll: false,
    );
    addTearDown(controller.dispose);

    await controller.reflect(const StatusConnecting());
    controller.setBackgrounded(true);
    await tester.pump();
    expect(calls, isEmpty);

    controller.setBalancedActive(true);
    await tester.pump();
    expect(calls, ['start']);
    await controller.reflect(const StatusSleeping());
    await tester.pump();
    expect(calls, ['start', 'stop']);
  });

  testWidgets('Android start refusal blocks retries until foreground', (
    tester,
  ) async {
    final starts = <String>[];
    var refused = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
      call,
    ) async {
      if (call.method == 'hasNotificationPermission') return true;
      if (call.method == 'isCharging') return false;
      if (call.method == 'start') {
        starts.add(call.method);
        return starts.length > 1;
      }
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _channel,
        null,
      ),
    );
    final controller = KeepAliveController(
      _Prefs(),
      isAndroid: () => true,
      enableChargingPoll: false,
    )..onServiceStartRefused = (() => refused++);
    addTearDown(controller.dispose);

    controller.setBackgrounded(true);
    controller.setBalancedActive(true);
    await tester.pump();
    await controller.reflect(const StatusConnecting());
    await controller.reflect(
      const StatusRetrying(nextRetry: Duration.zero, attempt: 0),
    );
    await tester.pump();
    expect(starts, hasLength(1));
    expect(refused, 1);

    controller.setBackgrounded(false);
    controller.setBackgrounded(true);
    await tester.pump();
    expect(starts, hasLength(2));
  });

  testWidgets('legacy start refusal keeps retrying without Balanced sleep', (
    tester,
  ) async {
    final starts = <String>[];
    var refused = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
      call,
    ) async {
      if (call.method == 'hasNotificationPermission') return true;
      if (call.method == 'isCharging') return false;
      if (call.method == 'start') {
        starts.add(call.method);
        return false;
      }
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _channel,
        null,
      ),
    );
    final controller = KeepAliveController(
      _AlwaysPrefs(),
      isAndroid: () => true,
      enableChargingPoll: false,
    )..onServiceStartRefused = (() => refused++);
    addTearDown(controller.dispose);

    controller.setBackgrounded(true);
    await controller.reflect(const StatusConnecting());
    await controller.reflect(
      const StatusRetrying(nextRetry: Duration.zero, attempt: 0),
    );
    await tester.pump();
    expect(starts, hasLength(2));
    expect(refused, 0);
    expect(controller.isStartBlocked, isFalse);
  });
}
