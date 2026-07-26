import 'package:cockpit/app/bootstrapper.dart';
import 'package:cockpit/app/core/data/diagnostics/diagnostics_log.dart';
import 'package:cockpit/app/core/data/diagnostics/error_handlers.dart';
import 'package:cockpit/app/core/ui/widgets/app_error_view.dart';
import 'package:cockpit/app/core/ui/widgets/error_report_dialog.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Bootstrap real (Hive, shell, cleanup de órfãos, hooks, AppModule) mora no
/// [CockpitBootstrapper]: a janela abre imediatamente com tela de loading e o
/// setup lento roda atrás, com tela de erro + retry se algo falhar.
///
/// Aqui fica só o que precisa envolver *tudo*: a captura global de erros. Um app
/// GUI não tem stdout visível, então sem isso qualquer falha em produção some
/// sem deixar rastro — inclusive as que fecham o app sozinho.
Future<void> main() async {
  await runGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Versão primeiro: alimenta o log e os relatórios de issue.
    final version = await _resolveVersion();
    setDiagnosticsAppVersion(version);
    await DiagnosticsLog.instance.init(appVersion: version);

    // Erro de build vira painel legível em vez da caixa cinza do Flutter.
    AppErrorView.install();

    // Plano 46 — inicializa o media_kit (libmpv) antes de qualquer Player.
    MediaKit.ensureInitialized();

    runApp(const CockpitBootstrapper());
  });
}

/// Versão do pubspec via `PackageInfo`. Falha aqui não pode impedir o boot — o
/// diagnóstico degrada para "unknown" e o app abre normalmente.
Future<String> _resolveVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return '${info.version}+${info.buildNumber}';
  } on Object catch (_) {
    return 'unknown';
  }
}
