import 'dart:async';

import 'window_activity_controller.dart';

/// Timer periódico que preserva a intenção de rodar, mas não produz ticks
/// enquanto a janela está inativa.
class ActivityPeriodicTimer {
  ActivityPeriodicTimer({
    required this.activity,
    required this.interval,
    required this.onTick,
  }) {
    activity.addListener(_sync);
  }

  final WindowActivityController activity;
  final Duration interval;
  final void Function() onTick;
  Timer? _timer;
  bool _requested = false;
  bool _disposed = false;

  void start() {
    _requested = true;
    _sync();
  }

  void stop() {
    _requested = false;
    _cancel();
  }

  void _sync() {
    if (_disposed) return;
    if (!_requested || !activity.isActive) {
      _cancel();
      return;
    }
    _timer ??= Timer.periodic(interval, (_) => onTick());
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    activity.removeListener(_sync);
    _cancel();
  }
}
