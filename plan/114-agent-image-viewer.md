# Plano 114 — Viewer de imagem que o agente mostra a partir do repo

**Objetivo**: quando o usuário (no app mobile) pede "me mostra a imagem X" (ou o
agente decide mostrá-la), o agente consegue **empurrar um arquivo de imagem que
está no disco** para o app, e o app abre um **viewer full-screen com zoom/pan**.
Hoje imagens só fluem **app → agente** (plano 30: foto anexada no celular) e o
plano 49 só renderiza essa foto **localmente na TUI do desktop**. Não existe
caminho **agente → usuário**, nem viewer algum no app.

Resultado esperado: usuário pede "mostra `assets/logo.png`" → o agente chama a
tool `show_image` → a extensão lê/valida o arquivo no disco e faz broadcast de um
`agent_image` com os bytes inline → o app renderiza um **balão de imagem
(tappable)** na linha do assistant → tap abre uma página full-screen com
`InteractiveViewer` (pinch-zoom, pan, duplo-tap reset, dismiss por Hero/swipe) +
barra com nome do arquivo, fechar, salvar e compartilhar.

## Por que essa direção

A infraestrutura já existe, só falta conectar:

- **`pi.registerTool`** — a extensão já expõe tools chamáveis pelo agente
  (`agent_send`, `list_peers`, `agent_request` em `src/session/tools.ts`). Uma
  tool `show_image` segue o mesmo molde: o agente decide mostrar, chama a tool.
- **`_broadcastToActive(ServerMessage)`** — todo evento de sessão já vai pra
  todos os owners conectados. Um novo `agent_image` usa o mesmo canal.
- **`WireImage` / `MessageImage` / `ImageBubble`** — tipos e widget de imagem já
  existem (plano 30). Reusamos o tipo no fio e o modelo no app; o `ImageBubble`
  vira a thumbnail tappable do balão.
- **Relay opaco** — a imagem vai **inline base64** dentro do `ct` atual, igual ao
  plano 30. Relay **não muda**. Custo double-base64 (~+77%) aceito nesta fatia
  (imagem com teto de tamanho).

O ponto-chave de disciplina (espelha plano 49): **os bytes da imagem nunca
entram no contexto do modelo**. A tool `show_image` retorna ao modelo só
metadados pequenos (`{ shown, path, mime, width, height, bytes }`); os bytes
seguem só no `agent_image` que vai pro app, e esse `customType` é filtrado do
context do provider.

## Não-objetivos (cortados explicitamente)

- ❌ **Cockpit (desktop)** fora do escopo — quem está no PC abre o arquivo direto.
  Follow-up plan se houver demanda (a TUI do Pi já mostra a imagem via plano 49).
- ❌ **Vídeo, PDF, arquivo genérico** — só imagem (consistente com planos 30/49:
  imagem é o único tipo não-texto com caminho de 1ª classe).
- ❌ **Múltiplas imagens por chamada** — uma tool call = uma imagem (o agente pode
  chamar N vezes). Carrossel/galeria fica pra depois.
- ❌ **Replay via `session_sync`** no MVP — o `agent_image` é broadcast ao vivo;
  persistência é **local no app** (sobrevive a restart do app, não a re-sync). Gap
  vs decisão #8 do plano 30, anotado em Riscos.
- ❌ **Resize server-side** (`sharp`) no MVP — a extensão só valida+teto; o app
  comprime a thumbnail e usa os bytes originais no viewer. `sharp` + canal binário
  são follow-ups (Trilha 2 do plano 30).
- ❌ **Geração de imagem pelo agente** (ex.: chart, screenshot via tool) — este
  plano é "mostrar arquivo existente no disco". Gerar+mostrar pode reusar a mesma
  tool depois, mas não está no escopo.

---

## Decisões fixadas

| # | Decisão | Valor |
|---|---|---|
| 1 | Escopo | **Agente → usuário (imagem do disco)**. Toca `app` + `pi-extension` + protocolo; **relay inalterado** |
| 2 | Gatilho | Tool **`show_image`** chamável pelo agente. Params: `path` (relativo ao cwd da sessão, obrigatório), `caption?` (opcional) |
| 3 | Protocolo | Novo `ServerMessage` **`agent_image`** com `image: WireImage` inline + `path` + dims + `in_reply_to` (turn atual). Opcional = retrocompatível |
| 4 | Transporte | **Inline base64** no `agent_image`, dentro do `ct` opaco. Relay não muda. Double-base64 aceito (consistente c/ plano 30) |
| 5 | Tamanho/MIME | Whitelist `jpeg/png/webp/gif`. **Teto bruto 4 MiB** no arquivo lido (rejeita maior). Sem resize server-side no MVP |
| 6 | Contexto do modelo | Tool_result do `show_image` devolve só **metadados** (`shown`, `path`, `mime`, `width`, `height`, `bytes`). `agent_image` é **filtrado** do `context` (como o `remote-pi:received-image` do plano 49) |
| 7 | Viewer | Página **full-screen** preta, `InteractiveViewer` (pinch-zoom + pan), duplo-tap reset, dismiss por Hero + swipe-down. Barra topo: nome/path + X. Ações rodapé: **Salvar na galeria** + **Compartilhar** |
| 8 | Timeline | `agent_image` renderiza como **balão próprio left-aligned** (lado do assistant), ancorado ao turn por `in_reply_to`. Não anexa ao texto do `AssistantMsg` (que vem de `agent_chunk`) |
| 9 | Persistência | App grava a row localmente (DB do plano 31) — sobrevive a restart do app. **Não** vai em `session_history` no MVP (ver Não-objetivos / Riscos) |
| 10 | `caption` | Vira subtítulo do balão e título do viewer (fallback: basename do `path`) |

### Defaults assumidos (vetar se discordar)

- **Resolução do path**: `path.resolve(p)` contra o cwd do processo Pi (== cwd da
  sessão). Rejeita se não for arquivo regular ou não existir.
- **Detecção de MIME**: por extensão (`jpeg/jpg/png/webp/gif`) com checagem de
  *magic bytes* pra não confiar cegamente na extensão. MIME fora da whitelist →
  erro de tool (não derruba o turn).
- **Thumbnail no balão**: app gera thumbnail comprimido (`flutter_image_compress`,
  já no projeto) a partir dos bytes recebidos — não guarda full-res no list. O
  viewer usa os bytes originais (cap em memória pelo teto de 4 MiB).
- **Salvar/Compartilhar**: `gal` (ou `image_gallery_saver`) pra salvar; `share_plus`
  pra compartilhar. Se alguma lib não estiver no projeto, adicionar.
- **Sem rede/offline**: se não há owner conectado no momento da tool, a extensão
  ainda retorna sucesso ao agente com `shown:false, reason:"no active peer"` (a
  imagem não é mostrada, mas o turn não trava). O agente pode mencionar.
- **Ordem**: a tool pode ser chamada antes/depois/durante o texto do assistant. O
  `agent_image` é enfileirado e broadcast no momento da chamada; o app insere na
  posição de chegada (igual `tool_result`).
- **Dedup**: `agent_image.id` é estável (UUID v7 gerado pela extensão); o app
  dedupa por id (defensivo contra rebroadcast).

---

## Estrutura esperada

```text
pi-extension/src/
├── protocol/
│   ├── types.ts          ← +ServerMessage "agent_image"; +WireShowImageParams (tool) (Wave A)
│   └── codec.ts          ← + "agent_image" no SERVER_TYPES (Wave A)
├── session/
│   └── tools.ts          ← registerTool show_image (Wave B)
└── index.ts              ← handler de show_image: read+validate+broadcast agent_image; filter context (Wave B)

app/lib/
├── protocol/protocol.dart          ← +AgentImage ServerMessage parse (Wave A)
├── domain/session_state.dart       ← +AgentImageMsg (ChatMessage variant) (Wave C)
├── ui/chat/
│   ├── chat_page.dart              ← case AgentImageMsg() → AgentImageBubble (Wave C)
│   └── widgets/
│       ├── agent_image_bubble.dart ← thumbnail tappable (Hero) → abre viewer (novo) (Wave C)
│       └── image_bubble.dart       ← (reusado/extraído helper de decode se fizer sentido)
└── ui/image_viewer/
    └── image_viewer_page.dart      ← full-screen InteractiveViewer + ações (novo) (Wave C)
```

---

## Wave A — Protocolo (app + pi-extension)

**pi-extension** (`src/protocol/types.ts`):

```ts
// Novo ServerMessage — imagem que o agente mostra ao usuário.
| {
    type: "agent_image";
    id: string;                 // UUID v7 (dedup no app)
    in_reply_to: string;        // _currentTurnId (ancoragem na timeline)
    image: WireImage;           // { data: base64, mime } — já existe do plano 30
    path?: string;              // path original no repo (display)
    caption?: string;           // legenda opcional
    width?: number;
    height?: number;
  }
```

`src/protocol/codec.ts`: adicionar `"agent_image"` ao set `SERVER_TYPES`.

**app** (`lib/protocol/protocol.dart`): novo `class AgentImage extends ServerMessage`
com `fromJson` (espelhar `WireImage` já parseado no plano 30). Adicionar case em
`ServerMessage.fromJson`.

**Aceite**: `pnpm typecheck` (pi-ext) + `flutter analyze` verdes; codec roundtrip
com `agent_image`; `PROTOCOL.md` com seção "Imagens do agente".

---

## Wave B — pi-extension

### B1 — Tool `show_image` (`src/session/tools.ts`)

Registrar via `pi.registerTool` (mesmo molde de `agent_send`):

```ts
const ShowImageParams = Type.Object({
  path: Type.String({ description: "Path to an image file in the repo (relative to session cwd). jpeg/png/webp/gif." }),
  caption: Type.Optional(Type.String({ description: "Optional caption shown under the image." })),
});

pi.registerTool<typeof ShowImageParams, ShowImageResult>({
  name: "show_image",
  label: "Show image to user",
  description: "Display an image file from the repo to the user on their mobile app (full-screen viewer with zoom). Use when the user asks to see/show an image, or when showing a generated chart/screenshot. Returns metadata only; bytes go out-of-band to the app, never to the model.",
  promptSnippet: 'show_image({path, caption?}): display an image file from disk to the user on their phone.',
  parameters: ShowImageParams,
  execute: async (_toolCallId, params) => { /* ver B2 */ },
});
```

### B2 — Handler (read + validate + broadcast)

`execute`:

1. Resolver `path.resolve(params.path)`; rejeitar se não existir / não for arquivo regular.
2. Whitelist MIME por extensão **+ magic bytes** (`jpeg/jpg/png/webp/gif`). Fora → `{ shown:false, error:"unsupported mime" }`.
3. `stat` → rejeitar `> 4 MiB` brutos (`{ shown:false, error:"file too large (max 4 MiB)" }`).
4. Ler bytes → base64. Extrair dims (`width`/`height`) se barato (PNG/JPEG header parse; webp/gif opcional — omitir se incerto).
5. Broadcast **`agent_image`** via `_broadcastToActive`:
   - `id`: UUID v7; `in_reply_to`: `_currentTurnId ?? ""` (pode ocorrer sem turn se chamado fora de turn — raro).
   - `image: { data, mime }`; `path`, `caption`, `width?`, `height?`.
6. Retornar ao modelo só metadados: `{ shown: <anyPeerActive>, path, mime, width?, height?, bytes }`. Se `!_anyPeerActive()`: `{ shown:false, reason:"no active peer" }` (não é erro — só informativo).
7. Em qualquer exceção (IO, parse), `console.error` + retornar `{ shown:false, error: String(e) }` — **nunca** derrubar o turn.

### B3 — Filtrar do contexto do modelo

Em `pi.on("context", ...)` (já existe filtrando `remote-pi:received-image`), o
`agent_image` **não** é uma custom message do tipo TUI — ele é um `ServerMessage`
do canal app, então naturalmente não entra no `context`. Confirmar no spike: o
`agent_image` nunca vira buffer de mensagem nem provider request. O tool_result
(bloco B2.6) já é lean. **Nada de base64 no tool_result.**

### B4 (opcional, barato) — Preview local na TUI do Pi

Reaproveitar o renderer do plano 49: ao broadcast do `agent_image`, emitir também
um `pi.sendMessage({ customType: "remote-pi:shown-image", display:true, details:{path,...} })`
com `convertToPng` pra o dev no PC ver o que foi mostrado. Reusa
`_registerReceivedImageRenderer` ou um sibling. **Opcional** — se atrapalhar o
escopo, deixar pro follow-up.

**Aceite B**: `pnpm test` cobre (a) `show_image` com PNG válido → broadcast
`agent_image` com base64 + tool_result só com metadados; (b) MIME inválido →
`shown:false` e **nenhum** broadcast; (c) arquivo > 4 MiB → `shown:false`, sem
broadcast; (d) path inexistente → `shown:false`; (e) sem peer ativo → broadcast
ocorre + tool_result `shown:false, reason`; (f) `agent_image` não aparece em
`context`/provider. `pnpm typecheck && pnpm test` verdes, sem regressão.

> **Spike rápido (não-bloqueante)**: confirmar se o Pi SDK expõe um helper de
> dimensão de imagem (reaproveitar de onde `convertToPng` vem). Se não, omitir
> `width/height` — não bloqueia o viewer.

---

## Wave C — app

### C1 — Domínio (`domain/session_state.dart`)

Novo `ChatMessage` variant:

```dart
class AgentImageMsg extends ChatMessage {
  final MessageImage image;   // reusa o modelo do plano 30
  final String? path;
  final String caption;       // '' se ausente
  const AgentImageMsg({required super.id, required this.image, this.path, this.caption = ''});
  // == / hashCode por id + image
}
```

### C2 — Protocolo → estado (`SyncService` / repo)

- Ao receber `AgentImage`: decode base64 → `Uint8List`, monta `MessageImage`,
  insere `AgentImageMsg` na lista (posição de chegada) e **persiste localmente**
  (DB do plano 31 — nova row/coluna pra image bytes ou tabela de anexos).
- Dedup por `id`.
- `caption` fallback → `path` basename.

### C3 — Balão (`ui/chat/widgets/agent_image_bubble.dart`)

Left-aligned (lado assistant). Thumbnail comprimido (altura limitada, ~`220px`
como `ImageBubble`) via `flutter_image_compress`. **Tappable**: `GestureDetector`
→ `Navigator.push` com `Hero` (tag = `msg.id`) → `ImageViewerPage`. Legenda embaixo
se houver. Reusar/extrair o helper de decode do `ImageBubble`.

`chat_page.dart`: adicionar `case AgentImageMsg() => AgentImageBubble(msg)` no
`switch (msg)`.

### C4 — Viewer (`ui/image_viewer/image_viewer_page.dart`)

Full-screen (`SystemUiOverlayStyle` dark, `Scaffold` black `backgroundColor`):

- `InteractiveViewer` (min 1.0, max ~4–5x) com o `Image.memory(bytes)`; pan + pinch.
- **Duplo-tap** alterna entre 1x e ~2.5x (animado via `TransformationController`).
- **Hero** from/to o balão (tag = `msg.id`).
- **Swipe-down** ou tap fora → `Navigator.pop` (back). Botão X no topo.
- **Top bar**: nome do arquivo (`path` basename) + close.
- **Bottom bar**: botões **Salvar** (galeria via `gal`/`image_gallery_saver`) e
  **Compartilhar** (`share_plus` + `XFile` em memória temporária). Feedback
  (snackbar) em sucesso/falha. Hide/show on tap (overlay).
- Decode uma vez; segurar bytes em state.

**Aceite C**: widget tests — receber `AgentImage` popula `AgentImageMsg` +
persiste; tap no balão abre o viewer; `InteractiveViewer` responde a gesto
(scale/pan testável); duplo-tap alterna escala; salvar/compartilhar chamam o
serviço mockado; dedup por id não duplica. `flutter analyze` 0 issues; `flutter
test` verde; builds Android (e iOS se aplicável) passam.

---

## Wave D — integração + docs

- **Persistência local** (#9): confirmar que o restart do app re-hidrata o
  `AgentImageMsg` do DB (row + bytes). Smoke: mostrar imagem, matar app, reabrir,
  balão + tap→viewer funcionam.
- **Smoke manual** (device): pedir "mostra assets/foo.png" → balão aparece → tap
  → viewer zoom/pan → salvar → confere na galeria. Imagem > 4 MiB → agente avisa
  que não pode mostrar. MIME inválido → idem.
- **Docs**: `PROTOCOL.md` (seção "Imagens do agente"), `pi-extension/README.md`
  ("Mobile app actions" + lista de tools do agente ganha `show_image`).

---

## Riscos

1. **Wire size**: imagem bruta até 4 MiB → ~7 MiB double-base64 no fio. Aceito no
   MVP (raro; screenshots/logos/charts costumam < 1 MiB). Mitigação futura: resize
   server-side (`sharp`) e/ou canal binário no relay (Trilha 2 do plano 30).
2. **Sem replay de `session_sync`** (#9 / gap vs plano 30 #8): se o DB local do
   app for limpo, balões de `agent_image` somem (a imagem foi "vista" e passou).
   Aceito no MVP; reabrir como follow-up se doer (colocar `agent_image` em
   `session_history` com bytes inflaria o sync — mesma tensão do plano 30 risco #1).
3. **OOM no viewer**: imagem até 4 MiB decodificada em RAM. `InteractiveViewer`
   lida bem; ainda assim, thumbnail separado do full-res no list evita N imagens
   full-res vivas na lista.
4. **Libs novas no app** (`gal`/`share_plus`): adicionar só se ausentes; checar
   permissões (Android: `WRITE_EXTERNAL_STORAGE` só < API 29; `gal` lida com
   scoped storage ≥ 29).
5. **Tool chamada fora de turn** (`_currentTurnId == null`): `in_reply_to` vazio;
  o app ancora no final da lista. Caso raro; aceito.

---

## Definition of Done

- [x] Wave A: `agent_image` ServerMessage + parse nos 2 lados; `PROTOCOL.md`; **pi-ext `pnpm typecheck` verde**. ⚠️ `flutter analyze` não rodado neste env (sem toolchain Flutter) — revisor precisa rodar.
- [x] Wave B: tool `show_image` (read+validate+whitelist+teto 4 MiB + magic bytes + dims PNG/JPEG) + broadcast `agent_image` + tool_result só metadados + bytes fora do contexto (confirmado por teste); **`pnpm test` verde** (7 testes novos: `src/show_image.test.ts` + 1 broadcast em `extension.test.ts`). Sem novas regressões (8 falhas pré-existentes são ambientais — symlinks/realpath no Windows).
- [x] Wave C1: `AgentImageMsg` no domínio (`session_state.dart`)
- [x] Wave C2: ingest `AgentImage` → estado + persistência local (`MessageRecord.imagePath`) + dedup por id (`sync_service.dart`)
- [x] Wave C3: `AgentImageBubble` tappable (Hero) no chat (`agent_image_bubble.dart`); switch do `chat_page.dart` cobre o novo variante
- [x] Wave C4: `ImageViewerPage` (InteractiveViewer zoom/pan, duplo-tap 2.5×, salvar via `gal`, compartilhar via `share_plus`, swipe-down dismiss, Hero)
- [x] Wave D docs: `PROTOCOL.md` (seção "Imagens do agente") + `pi-extension/README.md` (tool `show_image`). Deps novas no `pubspec.yaml`: `gal ^2.0.0`, `share_plus ^13.3.0`.
- [ ] Wave D verificação: persistência sobrevive a restart + **smoke manual device** (precisa de device + Flutter; não executável neste env)
- [x] Verificação: relay inalterado; bytes nunca entram no contexto do modelo (teste B confirma)
- [ ] Commit: `feat(plan-114): agent image viewer`

### Status de verificação (importante)

Implementado nos 4 pacotes afetados (pi-extension + app + protocolo + docs). O
lado **pi-extension está verificado**: `pnpm typecheck` verde e `pnpm test` sem
regressões (7 testes novos passando). O lado **app (Flutter) NÃO foi verificado**
porque este ambiente não tem o toolchain Flutter/Dart. Antes de promover a
release, rodar no `app/`:

```bash
flutter pub get          # resolve gal + share_plus
flutter analyze          # deve dar 0 issues
flutter test             # conferir que a sealed union + switches fecham
```

Riscos conhecidos do lado app: (a) `gal ^2.0.0` / `share_plus ^13.3.0` podem
precisar de ajuste fino de versão; (b) o viewer usa `Matrix4`/`Hero`/
`InteractiveViewer` (APIs estáveis, padrão foto-app); (c) `AgentImageMsg` foi
adicionado à sealed union `ChatMessage` — o único switch exaustivo de
produção (`chat_page.dart`) foi atualizado; testes que façam switch exaustivo
sobre `ChatMessage` podem precisar do novo caso.

---

## Próximos planos

- **Resize server-side** (`sharp` na extensão): permite baixar o teto de fio e
  enviar previews maiores sem inflar. Pré-requisito natural pra Trilha 2.
- **Trilha 2 — canal binário no relay**: elimina o imposto double-base64 pra
  imagens grandes (mesma direção já anotada no plano 30).
- **Replay de `agent_image` em `session_sync`**: se a perda pós-DB-wipe dor,
  incluir na história (com política de retenção de bytes).
- **Múltiplas imagens / carrossel**: `show_image` aceitando array, ou viewer com
  paginação entre imagens do mesmo turn.
- **Cockpit**: mesmo viewer no desktop (RPC path diferente do relay app).
