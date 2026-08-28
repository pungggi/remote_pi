import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/core/utils/platform_kind.dart';
import 'package:cockpit/i18n/strings.g.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Tela inicial quando ainda não há workspace. Diferente do antigo onboarding,
/// **não** força instalar nada: o Cockpit serve como multiplexador de terminal
/// sem o Pi. O checklist do ambiente de agente vive agora dentro da aba de
/// agente (ver `AgentSetupChecklist`).
///
/// Duas ações (plano 59): abrir pasta local **e** conectar a um host remoto.
/// No mobile (iPad/Android), remote-only, só a de host aparece.
class WelcomeView extends StatelessWidget {
  const WelcomeView({
    super.key,
    required this.onCreateWorkspace,
    required this.onConnectHost,
    required this.onConfigureHost,
    required this.hasHosts,
  });

  /// Dispara o fluxo de criação local (escolher pasta → dialog → criar).
  final Future<void> Function() onCreateWorkspace;

  /// Dispara o fluxo de conexão a um host remoto (adicionar workspace). Recebe o
  /// `context` do botão como âncora do menu de seleção de host.
  final Future<void> Function(BuildContext anchor) onConnectHost;

  /// Abre Configurações já na aba "Remote hosts" (onde mora a chave pública do
  /// device pra copiar no servidor). Usado no mobile quando ainda não há host.
  final VoidCallback onConfigureHost;

  /// Se já existe pelo menos um host cadastrado (muda a ação primária no mobile:
  /// sem host → configurar; com host → adicionar workspace).
  final bool hasHosts;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    return ColoredBox(
      color: colors.bg,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.asset(
                  'assets/branding/cockpit_logo.png',
                  width: 64,
                  height: 64,
                  filterQuality: FilterQuality.medium,
                ),
              ),
              const SizedBox(height: 22),
              Text(
                context.t.cockpit.welcomeView.title,
                style: context.typo.title.copyWith(
                  fontSize: 20,
                  color: colors.text,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.t.cockpit.welcomeView.subtitle,
                textAlign: TextAlign.center,
                style: context.typo.body.copyWith(
                  fontSize: 13.5,
                  color: colors.text2,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              _actions(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actions(BuildContext context) {
    final tr = context.t.cockpit.welcomeView;
    if (isMobilePlatform) {
      // Sem host ainda → manda pras Configurações (aba Remote hosts), onde está
      // a chave pública pra copiar no servidor. Com host → adicionar workspace.
      if (!hasHosts) {
        return PrimaryButton(
          onPressed: onConfigureHost,
          leading: const Icon(Icons.settings_outlined, size: 16),
          child: Text(tr.configureHost),
        );
      }
      return Builder(
        builder: (btnContext) => PrimaryButton(
          onPressed: () => onConnectHost(btnContext),
          leading: const Icon(Icons.add, size: 16),
          child: Text(tr.addWorkspace),
        ),
      );
    }
    // Desktop: pasta local + host (o host resolve pick-or-add internamente).
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Builder(
          builder: (btnContext) => PrimaryButton(
            onPressed: () => onConnectHost(btnContext),
            leading: const Icon(Icons.cloud_outlined, size: 16),
            child: Text(tr.connectHost),
          ),
        ),
        const SizedBox(width: 10),
        SecondaryButton(
          onPressed: () => onCreateWorkspace(),
          leading: const Icon(Icons.folder_outlined, size: 16),
          child: Text(tr.openLocalFolder),
        ),
      ],
    );
  }
}
