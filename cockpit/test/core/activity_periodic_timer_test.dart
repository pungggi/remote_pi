import 'package:cockpit/app/core/ui/activity_periodic_timer.dart';
import 'package:cockpit/app/core/ui/window_activity_controller.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('visual timer executes zero ticks while the window is inactive', () {
    fakeAsync((async) {
      final activity = WindowActivityController();
      var ticks = 0;
      final timer = ActivityPeriodicTimer(
        activity: activity,
        interval: const Duration(seconds: 1),
        onTick: () => ticks++,
      );

      timer.start();
      async.elapse(const Duration(seconds: 2));
      expect(ticks, 2);

      activity.blur();
      async.elapse(const Duration(seconds: 10));
      expect(ticks, 2, reason: 'ticks during inactivity = 0');

      activity.focus();
      async.elapse(const Duration(seconds: 1));
      expect(ticks, 3);

      timer.dispose();
      activity.dispose();
    });
  });
}
