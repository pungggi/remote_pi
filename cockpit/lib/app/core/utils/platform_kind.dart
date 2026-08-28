import 'dart:io';

/// Fonte única de verdade pra "isto é mobile?" (plano 59). O cockpit no
/// iPad/Android é um cliente **remote-only**: sem motor local, sem plugins de
/// desktop. Todo gating de superfície (pseudo-workspace, abas de Settings,
/// menu, "+") lê daqui — não espalha `Platform.isIOS || Platform.isAndroid`.
bool get isMobilePlatform => Platform.isIOS || Platform.isAndroid;

/// Complemento de [isMobilePlatform]: macOS/Windows/Linux.
bool get isDesktopPlatform =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;
