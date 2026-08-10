import 'package:cockpit/app/core/domain/contracts/service.dart';
import 'package:cockpit/app/cockpit/domain/entities/agent_snapshot.dart';
import 'package:cockpit/app/cockpit/domain/entities/pi_command.dart';
import 'package:cockpit/app/cockpit/domain/entities/pi_model.dart';
import 'package:cockpit/app/cockpit/domain/entities/prompt_image.dart';
import 'package:cockpit/app/cockpit/domain/entities/rpc_event.dart';
import 'package:cockpit/app/cockpit/domain/entities/thinking_level.dart';
import 'package:cockpit/app/cockpit/domain/entities/transcript_message.dart';
import 'package:cockpit/app/cockpit/domain/exceptions/rpc_error.dart';
import 'package:cockpit/app/core/domain/result.dart';

/// Contrato de baixo nível que esconde o `Process.start` do `pi --mode rpc`.
///
/// Declarado no domínio, implementado em `data/rpc/`. O domínio só conhece
/// **esta interface** — não sabe que existe `dart:io`, stdin/stdout ou JSON.
///
/// MVP (plano 37): um único processo por gateway — multiplexação (N panes) é
/// adiada. `events` é um stream broadcast que persiste pela vida do gateway
/// (sobrevive a `spawn`/`kill` sucessivos).
abstract class RpcProcessGateway implements Service {
  /// Stream tipado de eventos do stdout do agente. Broadcast: a `ui/` assina
  /// e re-assina entre spawns sem perder o controller.
  Stream<RpcEvent> get events;

  /// Há um agente vivo nesta sessão?
  bool get isRunning;

  /// Pasta do agente atual (cwd do child), ou `null` se nenhum.
  String? get workingDirectory;

  /// Sobe um `pi --mode rpc` puro em [workingDirectory]. Falha se já houver um
  /// agente vivo (dedup é responsabilidade de quem chama, no MVP single-pane).
  ///
  /// [environment] é **fundido** com o ambiente do processo pai — variáveis
  /// ausentes aqui são herdadas normalmente. Use para injetar
  /// `REMOTE_PI_DIRECT_CONFIG` sem perder PATH/HOME/etc.
  ///
  /// [sessionId] (opcional) é o ID da sessão a restaurar (basename do `.jsonl`
  /// sem extensão). Quando presente, passa `--session <id>` ao pi para que ele
  /// inicie já carregado na sessão — sem `switch_session` posterior.
  Future<Result<void, RpcError>> spawn({
    required String workingDirectory,
    Map<String, String>? environment,
    String? sessionId,
  });

  /// Envia um prompt do usuário pelo stdin. Se [steerIfBusy], anexa
  /// `streamingBehavior: "steer"` para enfileirar durante streaming. [images]
  /// viram o campo `images` do comando (anexos de visão).
  Future<Result<void, RpcError>> sendPrompt(
    String message, {
    bool steerIfBusy = false,
    List<PromptImage> images = const <PromptImage>[],
  });

  /// Responde a um `extension_ui_request` interativo (select/confirm/input/
  /// editor) — escreve `{type:"extension_ui_response", id, ...response}` no
  /// stdin. [response] é `{value:…}` / `{confirmed:…}` / `{cancelled:true}`.
  Future<Result<void, RpcError>> respondUi(
    String id,
    Map<String, dynamic> response,
  );

  /// Mata o child limpo: fecha o stdin (encerramento gracioso, code 0) e só
  /// escala para SIGTERM/SIGKILL se ele não sair. Sem processo órfão.
  Future<void> kill();

  // --- Comandos request/response (correlacionados por `id`) ----------------

  /// `get_available_models` — catálogo de modelos configurados.
  Future<Result<List<PiModel>, RpcError>> availableModels();

  /// `get_commands` — slash commands disponíveis (vêm das extensions).
  Future<Result<List<PiCommand>, RpcError>> commands();

  /// `get_state` — recorte do estado atual (modelo + effort + streaming).
  Future<Result<AgentSnapshot, RpcError>> state();

  /// `set_model` — troca o modelo ativo; devolve o modelo aplicado.
  Future<Result<PiModel, RpcError>> setModel(PiModel model);

  /// `set_thinking_level` — ajusta o effort de raciocínio.
  Future<Result<void, RpcError>> setThinkingLevel(ThinkingLevel level);

  /// `abort` — interrompe o turno atual **sem** matar o processo.
  Future<Result<void, RpcError>> abort();

  /// `new_session` — começa uma sessão nova (zera a conversa do agente).
  Future<Result<void, RpcError>> newSession();

  /// `compact` — compacta o contexto da sessão atual.
  Future<Result<void, RpcError>> compact();

  /// `switch_session` — carrega uma sessão salva do pi (por caminho).
  Future<Result<void, RpcError>> switchSession(String sessionPath);

  /// `get_messages` — mensagens da sessão atual, já mapeadas pro transcript.
  Future<Result<List<TranscriptMessage>, RpcError>> getMessages();

  /// Envia um controle de relay diretamente no stdin, sem envolver o LLM nem
  /// aparecer no transcript. [verb]: `relay:on` | `relay:off` | `relay:toggle`
  /// | `relay:status`. O pi engole silenciosamente; a resposta chega como
  /// evento customizado `remote-pi:relay-state` no stdout.
  Future<Result<void, RpcError>> sendControl(String verb);
}
