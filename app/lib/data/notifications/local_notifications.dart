import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Thin seam over `flutter_local_notifications` so the completion gate
/// ([SessionCompletionNotifications]) and tests can work against an
/// interface instead of the plugin singleton.
///
/// Plan/132 — Android-only feature; implementations degrade gracefully on
/// other platforms (no-op initialize / permission always granted / show
/// discarded by the OS as a heads-up-less notification).
abstract class LocalNotifications {
  /// Initialize the plugin. MUST run before `runApp` — both because the
  /// Android plugin needs it and so the launch details below are queryable
  /// at first frame.
  Future<void> initialize();

  /// Android 13+: request `POST_NOTIFICATIONS`. Returns whether it is
  /// granted afterwards (pre-13 → always true).
  Future<bool> requestPermission();

  /// Whether notifications are currently permitted.
  Future<bool> hasPermission();

  /// Show a notification on the session-completion channel. `id` should be
  /// stable per (epk, room) so a new completion REPLACES the previous banner
  /// instead of stacking. `payload` rides along to [taps] on tap.
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  });

  /// Payloads of tapped notifications **while the app was running** (warm
  /// taps). A notification that LAUNCHED a terminated app never fires the
  /// response callback — that payload is only available once, via
  /// [consumeLaunchTap].
  Stream<String> get taps;

  /// The payload of the notification that launched the app (cold start),
  /// or `null` when the app was not launched from a notification. One-shot:
  /// the first call consumes it, subsequent calls return `null`.
  Future<String?> consumeLaunchTap();
}

/// Production implementation on top of `flutter_local_notifications`.
class FlutterLocalNotifications implements LocalNotifications {
  /// Notification channel for session completion (Plan 132).
  static const String channelId = 'session-completion';
  static const String _channelName = 'Session completion';
  static const String _channelDescription =
      'Alerts when a monitored session finishes running a task.';

  /// Same monochrome launcher icon the keep-alive service notification uses
  /// (KeepAliveService.kt) — stays consistent in the status bar.
  static const String _icon = '@mipmap/ic_launcher_monochrome';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final StreamController<String> _taps = StreamController<String>.broadcast();
  bool _initialized = false;

  /// Payload captured from `getNotificationAppLaunchDetails()` during
  /// [initialize] — the notification that LAUNCHED the terminated app.
  /// Delivered once via [consumeLaunchTap] (the response callback only
  /// fires for taps while the app is running; and at initialize-time there
  /// is no listener on the broadcast `taps` stream yet to carry it).
  String? _launchPayload;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings(_icon),
    );
    // v22 — named `settings`; tap (and cold-start launch) delivery comes
    // through the response callback. Defensive: a platform/harness without
    // the plugin's method channel (desktop, tests) must not take `main()`
    // down — same lesson as KeepAliveController.reflect swallowing
    // MissingPluginException.
    try {
      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: (response) {
          final payload = response.payload;
          if (payload != null && payload.isNotEmpty) _taps.add(payload);
        },
      );
      // Cold start: the launch notification never fires the callback above —
      // the payload is only reachable here (plugin docs: "To handle when a
      // notification launched an application, use
      // getNotificationAppLaunchDetails").
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details != null && details.didNotificationLaunchApp) {
        final payload = details.notificationResponse?.payload;
        if (payload != null && payload.isNotEmpty) _launchPayload = payload;
      }
    } catch (_) {
      // Unavailable — show()/taps/consumeLaunchTap become no-ops, the app
      // keeps booting.
    }
    _initialized = true;
  }

  @override
  Future<String?> consumeLaunchTap() async {
    await initialize();
    final payload = _launchPayload;
    _launchPayload = null;
    return (payload == null || payload.isEmpty) ? null : payload;
  }

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  @override
  Future<bool> requestPermission() async {
    await initialize();
    try {
      // v22 — permission lives on the Android platform implementation, not
      // the generic plugin. Pre-13 it is a no-op returning null → granted.
      final granted = await _android?.requestNotificationsPermission();
      return granted ?? await hasPermission();
    } catch (_) {
      return await hasPermission();
    }
  }

  @override
  Future<bool> hasPermission() async {
    await initialize();
    try {
      final enabled = await _android?.areNotificationsEnabled();
      return enabled ?? true;
    } catch (_) {
      return true;
    }
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    await initialize();
    // Same defensive posture as initialize(): a show() that cannot reach the
    // platform must never crash the completion gate (it runs in a stream
    // listener with no error handling upstream).
    try {
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          icon: _icon,
        ),
      );
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: details,
        payload: payload,
      );
    } catch (_) {
      // Best-effort — the banner is an enhancement, never a hard dependency.
    }
  }

  @override
  Stream<String> get taps => _taps.stream;
}
