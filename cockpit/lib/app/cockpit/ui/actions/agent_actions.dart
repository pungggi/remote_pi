import 'dart:async' show unawaited;

import 'package:cockpit/app/cockpit/ui/session/agent_session.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/cockpit_viewmodel.dart';
import 'package:cockpit/app/cockpit/ui/widgets/widgets.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Ações do menu de uma aba de agente: histórico de sessões, renomear e o
/// toggle de auto-start do relay.

CockpitViewModel _vm(BuildContext context) => context.read<CockpitViewModel>();

/// "Histórico": lista as sessões salvas do pi para a pasta do agente ativo e,
/// ao escolher, substitui o transcript pela sessão carregada.
Future<void> openAgentHistory(BuildContext context, String agentId) async {
  final vm = _vm(context);
  final session = vm.session(agentId);
  if (session is! AgentSession || !session.isAlive) return; // agente vivo
  final sessions = await vm.historyFor(session.workingDirectory);
  if (!context.mounted) return;
  final picked = await showHistoryDialog(context, sessions: sessions);
  if (picked == null) return;
  await session.loadHistory(picked.path);
}

void renameAgent(BuildContext context, String agentId, String name) {
  final vm = _vm(context);
  final session = vm.session(agentId);
  if (session is! AgentSession) return;
  unawaited(
    vm.saveAgentConfig(
      agentId,
      agentName: name,
      autoStartRelay: session.autoStartRelay,
    ),
  );
}

void toggleRelayAgent(BuildContext context, String agentId) {
  final vm = _vm(context);
  final session = vm.session(agentId);
  if (session is! AgentSession) return;
  unawaited(
    vm.saveAgentConfig(
      agentId,
      agentName: session.title,
      autoStartRelay: !session.autoStartRelay,
    ),
  );
}
