import 'dart:io' show Platform;

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/relay_config.dart';
import 'package:app/domain/contracts/service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Plan 116 — connection reliability helpers. Bridges Dart to the native
/// `ch.pungitore.piper/reliability` method channel (Android only; a no-op on
/// every other platform).
///
/// Two responsibilities:
/// 1. **One-tap self-exemption** from battery optimization — keeps Piper's
///    retry loop running while backgrounded (belt-and-suspenders with the
///    plan-103 foreground service, which already grants foreground priority).
/// 2. **Deep-links** to the Tailscale app-info (battery) + system VPN
///    (always-on) screens — Piper cannot configure another app's settings, so
///    this is the closest we can get: the user is one tap from the right
///    screen instead of digging through system Settings.
///
/// `isTailscaleRelay` gates the Tailscale-specific UI: it's true only when the
/// resolved relay URL is in the Tailscale CGNAT range (`100.64.0.0/10`).
class ReliabilityService extends Service {
  ReliabilityService(this._prefs);

  final Preferences _prefs;
  static const _channel = MethodChannel('ch.pungitore.piper/reliability');

  /// `true` when the app is currently subject to doze/app-standby (i.e. NOT on
  /// the battery whitelist). Always `false` off Android (no doze) or below
  /// API 23. Surfaced as a ✓/✗ on the reliability page.
  Future<bool> isBatteryOptimized() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isBatteryOptimized') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Shows the system "Allow Piper to always run in background?" dialog. The
  /// user must confirm — we cannot silently exempt ourselves. No-op off Android.
  Future<void> requestBatteryExemption() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('requestBatteryExemption');
    } on PlatformException {
      // Channel not ready or OEM blocked the intent — non-fatal.
    }
  }

  /// Deep-links to Tailscale's app-info screen (user then taps Battery →
  /// Unrestricted). Returns `false` if Tailscale isn't installed so Dart can
  /// hide the row.
  Future<bool> openTailscaleBatterySettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openTailscaleBatterySettings') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// Deep-links to the system VPN list (user enables Always-on for Tailscale).
  Future<void> openVpnSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('openVpnSettings');
    } on PlatformException {
      // Non-fatal — some OEM ROMs lack a dedicated VPN settings activity.
    }
  }

  /// `true` when the resolved relay URL points at a Tailscale CGNAT address
  /// (`100.64.0.0/10`), i.e. the setup relies on Tailscale. Drives whether the
  /// reliability page shows the Tailscale-specific guidance.
  bool get isTailscaleRelay => isTailscaleCgnat(resolveRelayUrl(_prefs));
}

/// `true` when [url]'s host is an IPv4 in the Tailscale CGNAT range
/// `100.64.0.0/10` (100.64.0.0 – 100.127.255.255). Pure + testable.
@visibleForTesting
bool isTailscaleCgnat(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  if (host.isEmpty) return false;
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  if (a == null || b == null) return false;
  return a == 100 && b >= 64 && b <= 127;
}
