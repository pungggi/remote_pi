import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// "Iniciar com o sistema" (plano 58 / General): registra o Cockpit como item
/// de login do SO. Wrapper fino sobre o `launch_at_startup` (macOS via
/// LaunchAgent plist, Windows via registro Run, Linux via .desktop autostart).
///
/// Toda operação é no-op fora de desktop e nunca lança — falha do SO vira um
/// `false` e um `debugPrint`; a preferência salva continua sendo a fonte de
/// verdade da UI, e a próxima troca tenta reconciliar de novo.
class LaunchAtStartupService {
  LaunchAtStartupService();

  static bool get _supported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  bool _configured = false;

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    final info = await PackageInfo.fromPlatform();
    launchAtStartup.setup(
      appName: info.appName,
      appPath: Platform.resolvedExecutable,
      // Silencioso: sem janela de terminal/splash extra ao subir com o SO.
      args: const ['--minimized'],
    );
    _configured = true;
  }

  /// Aplica o estado desejado ([enabled]) no SO. Devolve o estado efetivo lido
  /// de volta (pode divergir do pedido se o SO recusar).
  Future<bool> apply(bool enabled) async {
    if (!_supported) return enabled;
    try {
      await _ensureConfigured();
      if (enabled) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
      return await launchAtStartup.isEnabled();
    } catch (e) {
      debugPrint('launch_at_startup: apply($enabled) falhou: $e');
      return enabled;
    }
  }

  /// Estado atual registrado no SO (pro boot reconciliar com a preferência).
  Future<bool> isEnabled() async {
    if (!_supported) return false;
    try {
      await _ensureConfigured();
      return await launchAtStartup.isEnabled();
    } catch (e) {
      debugPrint('launch_at_startup: isEnabled falhou: $e');
      return false;
    }
  }
}
