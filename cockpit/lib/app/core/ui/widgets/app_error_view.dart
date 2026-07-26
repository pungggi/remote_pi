import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/core/ui/widgets/error_report_dialog.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Substitui a caixa cinza (release) / faixa vermelha (debug) que o Flutter
/// desenha quando um widget falha no build.
///
/// O default não dá ao usuário nem o texto do erro nem uma saída — o app parece
/// simplesmente quebrado. Aqui a subárvore que falhou vira um painel legível com
/// caminho para reportar; o resto da UI continua funcionando.
class AppErrorView extends StatelessWidget {
  const AppErrorView({super.key, required this.details});

  final FlutterErrorDetails details;

  /// Registra este widget como o renderizador padrão de erro de build.
  /// Chamado uma vez no boot.
  static void install() {
    ErrorWidget.builder = (details) => AppErrorView(details: details);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.all(16),
      color: colors.panel,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 28, color: colors.error),
            const SizedBox(height: 10),
            Text(
              'This part of the app failed to render',
              textAlign: TextAlign.center,
              style: context.typo.title.copyWith(
                fontSize: 14,
                color: colors.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              details.exceptionAsString(),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: context.typo.mono.copyWith(
                fontSize: 11.5,
                color: colors.text3,
              ),
            ),
            const SizedBox(height: 12),
            OutlineButton(
              onPressed: () => showErrorReportDialog(
                context,
                title: 'Render error',
                error: details.exception,
                stack: details.stack,
              ),
              child: const Text('Details'),
            ),
          ],
        ),
      ),
    );
  }
}
