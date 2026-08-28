import 'package:cockpit/app/cockpit/data/remote/remote_host_connector.dart';
import 'package:cockpit/app/cockpit/ui/remote/remote_hosts_controller.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/remote_workspace_controller.dart';
import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/core/ui/widgets/hover_tap.dart';
import 'package:cockpit/i18n/strings.g.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Faixa de "host fora do ar" no topo do workspace REMOTO.
///
/// Aparece quando o host do workspace ativo está reconectando ou falhou. A
/// reconexão já acontece sozinha (o connector insiste indefinidamente, com
/// intervalo crescente até 30s); o botão aqui só antecipa a próxima tentativa,
/// para quem sabe que a VPN/rede voltou e não quer esperar o tique.
///
/// Enquanto a faixa está visível as abas de terminal daquele host estão
/// CONGELADAS: mantêm o conteúdo e recusam digitação, e ao reconectar re-anexam
/// a sessão do ponto exato onde pararam (o host guarda a sessão viva). Nada do
/// que rodava lá se perdeu.
///
/// Em workspace local o widget não ocupa espaço nenhum.
class RemoteDisconnectedBanner extends StatelessWidget {
  const RemoteDisconnectedBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final remote = context.watch<RemoteWorkspaceController>();
    final hosts = context.watch<RemoteHostsController>();
    // SÓ o host do workspace ativo. Nada de cair para "qualquer host fora do
    // ar": um host caído que não é o que você está usando não é assunto desta
    // tela — o aviso apareceria em workspace local e em workspace de outro
    // host, poluindo tudo. Quem cobre os demais é a lista em Settings.
    final host = remote.activeHost;
    if (host == null || !hosts.isDisconnected(host.id)) {
      return const SizedBox.shrink();
    }

    final colors = context.colors;
    final typo = context.typo;
    final tr = context.t.cockpit.remoteHost;
    final label = switch (hosts.phaseOf(host.id)) {
      RemoteHostPhase.failed => tr.offline(host: host.name),
      RemoteHostPhase.reconnecting => tr.reconnecting(host: host.name),
      // openingTunnel / connecting / installingServer: abertura em curso (ou
      // pendurada). O botão vale aqui também — é o que destrava um connect que
      // não volta.
      _ => tr.connecting(host: host.name),
    };

    return ColoredBox(
      color: colors.panel2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.cloud_off, size: 15, color: colors.warn),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: typo.body.copyWith(fontSize: 12, color: colors.warn),
              ),
            ),
            HoverTap(
              borderRadius: BorderRadius.circular(6),
              color: colors.panel3,
              onTap: () => hosts.reconnect(host.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                child: Text(
                  tr.reconnect,
                  style: typo.label.copyWith(fontSize: 12, color: colors.warn),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
