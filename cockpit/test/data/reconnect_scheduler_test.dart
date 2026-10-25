import 'package:cockpit/app/cockpit/data/remote/reconnect_scheduler.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('com foco: backoff cresce e tenta a cada tique', () {
    fakeAsync((async) {
      var attempts = 0;
      final s = ReconnectScheduler(onAttempt: () => attempts++);
      s.schedule();
      async.elapse(const Duration(seconds: 1));
      expect(attempts, 1);
      s.schedule();
      async.elapse(const Duration(seconds: 1));
      expect(attempts, 1, reason: '2º intervalo é 2s');
      async.elapse(const Duration(seconds: 1));
      expect(attempts, 2);
    });
  });

  test('sem foco: o tique NÃO tenta e fica adiado, sem timer', () {
    fakeAsync((async) {
      var attempts = 0;
      final s = ReconnectScheduler(
        onAttempt: () => attempts++,
        isFocused: () => false,
      );
      s.schedule();
      async.elapse(const Duration(minutes: 10));
      expect(attempts, 0);
      expect(s.isDeferred, isTrue);
      expect(s.isScheduled, isFalse);
      // Agendar de novo enquanto adiado não arma outro timer.
      s.schedule();
      expect(s.isScheduled, isFalse);
    });
  });

  test('resume com tentativa adiada tenta na hora e zera o backoff', () {
    fakeAsync((async) {
      var attempts = 0;
      var focused = false;
      final s = ReconnectScheduler(
        onAttempt: () => attempts++,
        isFocused: () => focused,
      );
      s.schedule();
      s.schedule();
      async.elapse(const Duration(seconds: 1));
      expect(s.isDeferred, isTrue);
      focused = true;
      s.resume();
      expect(attempts, 1);
      expect(s.isDeferred, isFalse);
      expect(s.nextDelay, const Duration(seconds: 1));
    });
  });

  test('resume sem nada adiado é no-op', () {
    var attempts = 0;
    ReconnectScheduler(onAttempt: () => attempts++).resume();
    expect(attempts, 0);
  });

  test('foco lido no tique: perder o foco durante a espera adia', () {
    fakeAsync((async) {
      var attempts = 0;
      var focused = true;
      final s = ReconnectScheduler(
        onAttempt: () => attempts++,
        isFocused: () => focused,
      );
      s.schedule();
      focused = false;
      async.elapse(const Duration(seconds: 1));
      expect(attempts, 0);
      expect(s.isDeferred, isTrue);
    });
  });

  test('reset zera passo e descarta pendências; dispose silencia', () {
    fakeAsync((async) {
      var attempts = 0;
      final s = ReconnectScheduler(onAttempt: () => attempts++);
      s.schedule();
      s.reset();
      async.elapse(const Duration(minutes: 1));
      expect(attempts, 0);
      expect(s.nextDelay, const Duration(seconds: 1));
      s.schedule();
      s.dispose();
      async.elapse(const Duration(minutes: 1));
      expect(attempts, 0);
    });
  });
}
