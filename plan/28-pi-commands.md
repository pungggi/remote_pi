# Plano 28 — App actions tipadas

**Objetivo**: dar à app mobile um conjunto curado de **ações tipadas** sobre a
sessão do Pi — `compact`, `new session`, `set model`, `set thinking` — sem
tentar espelhar o picker genérico de slash commands do TUI. Cada ação é uma
mensagem own-wire estruturada, mapeada pra uma API pública do SDK do Pi.

## Por que essa direção (e não picker genérico)

Tentamos primeiro um `list_commands` / `command_invoke` genérico (Slice 1
escrito e depois removido). Findings que motivaram o pivot:

1. **SDK não expõe API genérica de invocação de builtins.** Apenas alguns
   têm equivalente programático em `ExtensionContextActions` — `compact`,
   `shutdown`, `setModel`, `setThinkingLevel`, `newSession`. O resto
   (`/copy`, `/share`, `/fork`, `/tree`, `/login`, ...) só roda na TUI.
2. **Mirror manual de builtins** vira débito vivo — a cada bump do SDK,
   sincronizar lista manual no pi-extension.
3. **Subset útil em mobile é pequeno**: `/copy`, `/import`, `/share`,
   `/fork`, `/tree`, `/settings`, `/login`, `/logout`, `/scoped-models` não
   fazem sentido sem a TUI ou exigem fluxos próprios.
4. **UX**: chip canonizado + parsing de args é overhead pra um conjunto
   pequeno de ações. Botões dedicados, segmented control, sub-picker nativo
   são UX melhor pra cada caso.
5. **Validação no pi-telegram** (estudado 2026-05-28): adapter Telegram
   maduro pro Pi faz exatamente isto — vocabulário curado de ações
   (`TELEGRAM_RESERVED_COMMAND_NAMES`, 12 itens), cada uma dispatchada pra
   API SDK específica via dependency injection. Não é workaround; é o
   padrão de adapter Pi.

**Status (2026-05-28)**: Wave 0 ✅ (scout do SDK + decisão de pivot). Wave A
em execução pelo orquestrador (pi-pane ocupado).

---

## Wave 0 — Findings do SDK (CONCLUÍDA)

### APIs públicas relevantes em `@mariozechner/pi-coding-agent` 0.73.1

```ts
// ExtensionAPI (instância `pi` passada pra extensão)
pi.setModel(model: Model<any>): Promise<boolean>
pi.setThinkingLevel(level: ThinkingLevel): void
pi.getThinkingLevel(): ThinkingLevel

// ExtensionContextActions (acessível via `ctx` dentro de handlers)
ctx.compact(options?: CompactOptions): void
ctx.shutdown(): void
ctx.abort(): void

// ExtensionCommandContextActions (acessível via `ctx` em command handlers)
ctx.newSession(options?: NewSessionOptions): Promise<{cancelled: boolean}>
ctx.fork(...)
ctx.switchSession(...)
ctx.reload(): Promise<void>

// Factories públicos
ModelRegistry.create(authStorage, modelsJsonPath?): ModelRegistry
AuthStorage.create(authPath?): AuthStorage

// ModelRegistry instance methods
reg.refresh(): void                 // re-lê auth + models.json do disco
reg.getAll(): Model<Api>[]          // todos modelos conhecidos pelo SDK
reg.getAvailable(): Model<Api>[]    // apenas com auth configurada
reg.find(provider, modelId): Model<Api> | undefined
```

### ThinkingLevel — enum fixo

```ts
type ThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh";
```

6 valores. `"xhigh"` só em modelos selecionados — app pode mostrar todos com
grayed-out no não-suportado, ou filtrar pelo `model.thinkingLevelMap`.

### ModelRegistry — discovery validada

Probe local (2026-05-28): `ModelRegistry.create(AuthStorage.create())` lê os
mesmos arquivos que o próprio Pi (`~/.pi/auth/*`, `~/.pi/models.json`).
Retorna 971 modelos totais, 279 disponíveis (com auth) no setup atual.

Decisão: pi-extension cria **sua própria instância** em vez de tentar acessar
a interna do `AgentSession`. Custo: chamar `reg.refresh()` antes de cada
`list_models` pra capturar mudanças feitas via `/login` no Pi.

---

## Wave A — Protocolo (em execução)

Adicionar a `pi-extension/src/protocol/types.ts`:

```ts
// ClientMessage — novas variantes:
| { type: "session_new"; id: string }
| { type: "session_compact"; id: string }
| { type: "model_set"; id: string; provider: string; model_id: string }
| { type: "thinking_set"; id: string; level: ThinkingLevel }
| { type: "list_models"; id: string }

// ServerMessage — novas variantes:
| { type: "action_ok"; in_reply_to: string; action: ActionName }
| { type: "action_error"; in_reply_to: string; action: ActionName; error: string }
| { type: "models_list"; in_reply_to: string; models: WireModel[]; current?: WireModel }

// Novos tipos:
export type ActionName =
  | "session_new"
  | "session_compact"
  | "model_set"
  | "thinking_set";

export type ThinkingLevel =
  | "off" | "minimal" | "low" | "medium" | "high" | "xhigh";

export interface WireModel {
  /** Stable id within the provider (e.g. "claude-opus-4-7"). */
  id: string;
  /** Display name shown in the picker (e.g. "Claude Opus 4.7"). */
  name: string;
  /** Provider slug (e.g. "anthropic"). */
  provider: string;
  /** Whether the model supports the thinking surface. */
  reasoning: boolean;
  /** Context window in tokens. */
  context_window: number;
}
```

Não há `list_thinking_levels` — os 6 valores são hardcoded no app.

Atualizar `PROTOCOL.md` com seção "App actions" (substituindo o que estava
sendo proposto pro picker genérico).

**DoD Wave A**:
- [ ] Tipos novos em `protocol/types.ts`
- [ ] `pnpm typecheck` verde
- [ ] Seção "App actions" no `PROTOCOL.md` honesta sobre modelo (curado, não
      genérico)

---

## Wave B — Handlers no pi-extension

### B.1 — Estado adicional na extensão

```ts
// index.ts
let _modelRegistry: ModelRegistry | null = null;

function _ensureModelRegistry(): ModelRegistry {
  if (!_modelRegistry) {
    _modelRegistry = ModelRegistry.create(AuthStorage.create());
  }
  return _modelRegistry;
}
```

### B.2 — Dispatch das ações em `_routeClientMessageFrom`

```ts
case "session_compact":
  _handleAction(sender, msg, "session_compact", () => {
    if (!_lastCtx?.compact) throw new Error("compact unavailable");
    _lastCtx.compact();
  });
  break;

case "session_new":
  _handleActionAsync(sender, msg, "session_new", async () => {
    if (!_lastCtx?.newSession) throw new Error("newSession unavailable");
    const result = await _lastCtx.newSession();
    if (result.cancelled) throw new Error("cancelled");
  });
  break;

case "thinking_set":
  _handleAction(sender, msg, "thinking_set", () => {
    _pi!.setThinkingLevel(msg.level);
  });
  break;

case "model_set":
  _handleActionAsync(sender, msg, "model_set", async () => {
    const reg = _ensureModelRegistry();
    reg.refresh();
    const model = reg.find(msg.provider, msg.model_id);
    if (!model) throw new Error(`model ${msg.provider}/${msg.model_id} not found`);
    const ok = await _pi!.setModel(model);
    if (!ok) throw new Error("no auth configured for model");
  });
  break;

case "list_models":
  _handleListModels(sender, msg);
  break;
```

`_handleAction` / `_handleActionAsync` são helpers tiny que:
- chamam o bloco
- em sucesso enviam `action_ok`
- em erro pegam o `.message` e enviam `action_error`

### B.3 — `_handleListModels`

```ts
function _handleListModels(sender, msg) {
  const reg = _ensureModelRegistry();
  reg.refresh();
  const models: WireModel[] = reg.getAvailable().map(m => ({
    id: m.id,
    name: m.name,
    provider: m.provider,
    reasoning: m.reasoning,
    context_window: m.contextWindow,
  }));
  const current = _pi?.getModel?.();  // se exposto no ExtensionAPI
  sender.send({
    type: "models_list",
    in_reply_to: msg.id,
    models,
    current: current ? wireFromModel(current) : undefined,
  });
}
```

Investigar se `pi.getModel()` existe — caso contrário, app rastreia o
modelo atual via `model_select` event (já broadcast hoje).

**DoD Wave B**:
- [ ] `_ensureModelRegistry` + reuso entre chamadas
- [ ] 5 cases novos no `switch`
- [ ] `_handleListModels` + `wireFromModel` helper
- [ ] `action_ok`/`action_error` consistente em todos os casos
- [ ] Tests vitest cobrindo cada handler com fakes do `pi` / `_lastCtx`
- [ ] `pnpm typecheck && pnpm test` verdes, sem regressão (baseline 384)

---

## Wave C — App UI

**Toca**: `app/lib/ui/chat/`, `app/lib/data/actions/` (novo)

### Bottom sheet "Quick actions"

Botão ⚙ ao lado do botão de arquivos no TextField, visível só com input
vazio. Tap → bottom sheet:

```
┌─────────────────────────────┐
│ Quick actions               │
├─────────────────────────────┤
│ 🗜️  Compact context        │
│ ✨  New session             │
├─────────────────────────────┤
│ Model                       │
│ Claude Opus 4.7         ›   │  ← tap abre sub-picker
├─────────────────────────────┤
│ Thinking                    │
│ [off ·min·low·med·high·x]   │  ← segmented inline
└─────────────────────────────┘
```

- **Compact** / **New session**: tap → envia ação → mostra toast em
  `action_ok` ou erro em `action_error`. New session pede confirmação
  ("Vai limpar o contexto").
- **Model sub-picker**: novo screen ou bottom sheet maior. App envia
  `list_models` na abertura, cacheia por `(piPeerId, sessionId)`,
  permite filtrar por provider. Tap em model → `model_set`.
- **Thinking segmented**: 6 botões. Reflete `getThinkingLevel` atual
  (sincronizado via `model_select` event que já carrega thinking
  level). Tap → `thinking_set` otimista + revert em erro.

### Reflexão de mudanças externas

Outros owners (outro celular) podem invocar as mesmas ações. Pi-extension
já faz broadcast de `model_select` pra todos os attached owners. App
escuta esse evento pra refletir mudanças de modelo. Pra thinking precisa
ver se o broadcast atual cobre — senão adicionar.

**DoD Wave C**:
- [ ] Botão ⚙ visível só com input vazio
- [ ] Bottom sheet funcional com 4 ações
- [ ] Model sub-picker com filtro por provider
- [ ] Thinking segmented + estado sincronizado
- [ ] Toast/inline error em `action_error`
- [ ] `flutter test` cobrindo cada ação
- [ ] Smoke: pair → compact → ver chat compactado; trocar modelo → ver
      `model_select` propagado

---

## Wave D — Polish + futuras integrações

- **Abort/shutdown**: adicionar `session_abort` e `session_shutdown` se
  user demandar. Shutdown precisa confirmação dupla.
- **Cross-PC**: ações sobre Pis irmãos. Hoje app só age sobre o Pi
  pareado direto. Cross-PC fica pro plan/26 quando UI de multi-Pi entrar.
- **Models refresh manual**: pull-to-refresh no model picker chamando
  `reg.refresh()` antes do retorno.
- **Docs**:
  - `pi-extension/README.md` ganha seção "Mobile app actions"
  - `site/` doc ganha screenshot do quick actions sheet

**DoD Wave D**:
- [ ] Abort/shutdown decidido (incluído ou backloged explicitamente)
- [ ] Docs atualizadas

---

## DoD consolidado

- [x] Wave 0: scout do SDK + pivot decidido
- [x] Wave A: tipos no protocolo + seção em PROTOCOL.md
- [x] Wave B: handlers + ModelRegistry + tests (388 → 399 tests pi-extension)
- [x] Wave C: UI do app (bottom sheet + sub-picker + segmented). 11 arquivos, +46 tests (342 total), `flutter analyze` 0 issues, iOS build OK. Notas em `.orchestration/results/28-wave-c.md`
- [x] Wave D.1 (pi-extension): thinking hydration via room_meta. `pi.on("thinking_level_select")` mirroring model handler + seed inicial via `pi.getThinkingLevel()` em `_cmdStart`. `_myRoomMeta` agora carrega `{model?, thinking?}`. tsc + 399 tests verdes.
- [x] Wave D.3 (pi-extension README): nova seção "Mobile app actions" com tabela + nota sobre por que NÃO é picker genérico
- [x] Wave D.4: bump 0.2.1 → **0.3.0** (Quick Actions feature complete)
- [x] Wave D.2 (app): consumir `meta.thinking` + invalidar models cache em mudança externa. 365 tests (+23), `flutter analyze` 0 issues, iOS build OK. Notas em `.orchestration/results/28-wave-d-app.md`
- [x] Wave D.3 (site): copy do site atualizada. lint+build verde, também corrigiu copy stale dos stores ("coming soon" → links reais). Notas em `.orchestration/results/28-wave-d-site.md`
- [x] Wave D.6 (relay): propagar `meta.thinking` ponta-a-ponta. 76 cargo tests (+3), clippy clean. **Bonus**: refatorou `update_room_meta` pra semântica RFC 7396 de merge patch — corrige bug pré-existente que zerava silenciosamente campos ausentes. Notas em `.orchestration/results/28-wave-d-relay.md`. Nota arquitetural pendente: shape inconsistente entre `room_announced` (flat) e `room_meta_updated` (nested) — vira issue futura.

### Notas pendentes

3. **Flake test pré-existente** (`pending UserMsg survives WS reconnect`) falhou na primeira run da Wave C, ficou verde depois. Agent não tocou. Suspeito de timing flake — registrar pra observação.
4. **`abort`/`shutdown` actions**: shutdown foi adicionado em 2026-10-27 como
   Quick Action **Quit session**, com confirm dialog e retorno à Home. O usuário
   escolheu especificamente Quick Action, não um parser `/quit` no composer.
   `session_shutdown` chama `ctx.shutdown()`, envia `bye{reason:"shutdown"}`
   e, em daemon RPC, sai com código 0 para o supervisor não reiniciar o filho.
   Abort continua backloged.

## Próximos planos

- Plan 26 retomado: ações sobre sessões cross-PC (lista de irmãos +
  ação targetada)
- PR upstream opcional: `pi.getModel()` + `pi.getActiveProvider()` se
  ainda não existirem, pra reduzir o tracking via events no app
