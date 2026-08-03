# 56 — Go to definition (⌘/Ctrl+clique num símbolo)

## Contexto

Pergunta do usuário: ao segurar Command (macOS) ou Control (Windows/Linux) e
clicar numa classe/símbolo usado em algum ponto do código, quer pular direto
pro arquivo/linha onde ela é definida — como VSCode/IntelliJ fazem.

Depende da mesma infra LSP do [`plano 55`](55-semantic-syntax-highlight.md)
(client já fala JSON-RPC, `request()` genérico em
`core/data/lsp/lsp_client_impl.dart:160`), mas é feature **de navegação**, não
de cor — arquivo de plano separado porque o trabalho de UI (gesture + hit-test
de texto) é independente do semantic highlight.

**Peças que já existem e este plano reusa, não reinventa**:

1. **Padrão Cmd+clique-pra-abrir-arquivo já existe** —
   `cockpit_viewmodel.dart:1014` (`openTerminalPath(token, {cwd, line})`),
   usado pelo terminal (Cmd+clique num caminho de arquivo no output do shell).
   Faz `openFile(abs)` + `session.reveal(line)` — é o mesmo par de chamadas que
   este plano precisa pra abrir a definição.
2. **Convenção de modificador cross-platform já existe** —
   `cockpit_page.dart:657-658`:
   `HardwareKeyboard.instance.isMetaPressed || .isControlPressed` (Alt exclui).
   Reusar a mesma condição, não inventar detecção nova.
3. **`FileViewerSession.reveal(line)`** (`file_viewer_session.dart:95`) já
   revela linha (base 1) numa aba já aberta — usado por busca/grep hoje.

O que falta é só a ponte entre "clique numa posição de texto" → "offset →
posição LSP" → "`textDocument/definition`" → "abrir resultado".

## Decisão de escopo

| # | Decisão |
|---|---|
| A | Só **single-target** definition (resposta LSP mais comum): se o server devolver múltiplas locations, abre a primeira — picker de múltiplas definições fica pra depois se se mostrar necessário |
| B | Cross-file: se a definição é noutro arquivo do projeto, abre nova aba (via `openFile`, mesmo fluxo do terminal); mesmo arquivo, só revela a linha na aba atual |
| C | **Resolvida (2026-07-24)**: arquivo fora do workspace (classe do SDK Flutter aberta por go-to-definition, pacote do pub-cache) é roteado pro servidor **que já existe** do projeto — highlight semântico e navegação funcionam lá dentro. Funciona porque esses arquivos são dependências do projeto e já estão no contexto de análise do servidor. Um servidor por workspace, igual VSCode. Ver `LspServerPool._rootFor`.<br><br>Duas tentativas erradas antes: (1) desligar o LSP pra arquivo externo — sem highlight semântico nem navegação lá; (2) subir um servidor **separado** com raiz no SDK (via o `pubspec.yaml` dele, achado pelo walk-up) — ele tentava indexar o pacote inteiro, milhares de arquivos, e travava a UI. O walk-up do `ProjectRootFinder` segue valendo **só dentro** do workspace (caso monorepo: subpacote com `pubspec.yaml` próprio ganha servidor próprio) |
| D | Feedback visual: enquanto o modificador está pressionado **e** o mouse paira sobre um identifier, sublinha + cursor de mão (padrão VSCode) — evita clique "cego" sem saber se ali é navegável |

## Estrutura esperada (cockpit/)

- `core/domain/contracts/lsp_client.dart` — novo método
  `Future<Result<List<LspLocation>, LspError>> definition(String path, {required int line, required int character})`
- `core/domain/entities/` — `LspLocation { uri, range }` (reaproveita os tipos
  de posição já usados por `LspDiagnostic`)
- `core/data/lsp/lsp_client_impl.dart` — implementa `definition()` sobre o
  `request()` genérico existente (`textDocument/definition`); anuncia
  capability no handshake (`textDocument.definition.dynamicRegistration: false`)
- `core/ui/widgets/code_highlight.dart` — hit-test: função que mapeia
  `Offset` local do render → offset de texto. Provável abordagem: expor a
  posição de clique via o `TextField`/`RenderEditable` já usado pelo
  `CodeEditingController` (ver nota técnica abaixo), não reinventar layout de
  texto
- `cockpit/ui/widgets/file_viewer.dart` — gesture layer: `Listener`/
  `MouseRegion` sobre o editor pra (a) rastrear estado do modificador +
  posição do mouse (hover) e (b) interceptar o tap quando modificador ativo,
  antes do comportamento padrão de posicionar cursor
- `cockpit/ui/viewmodels/cockpit_viewmodel.dart` — novo método
  `Future<void> goToDefinition(String path, int line, int character)` que
  chama `lspClient.definition(...)`, resolve o path do resultado, e reusa
  `openFile()` + `session.reveal(line)` (mesmo par do `openTerminalPath`)

## Nota técnica: hit-test de clique → offset de texto

O editor é um `TextField` padrão (`CodeEditingController extends
TextEditingController`, ver plano 55/`code_editing_controller.dart:11`), não
um widget de texto custom. Duas rotas possíveis pra saber **onde** o usuário
clicou (offset no texto):

1. **Deixar o `TextField` resolver**: um tap normal já move
   `controller.selection.baseOffset` pra posição clicada (comportamento nativo
   do Flutter). Sob modificador pressionado, ler
   `_ctrl.selection.baseOffset` **depois** do tap (via `onTap`/post-frame
   callback) em vez de recalcular manualmente — mais simples, zero código de
   layout duplicado.
2. **Hit-test manual** (só se a opção 1 não der pra distinguir clique-de-tap
   de "clique que deveria abrir definição" sem mover o cursor visualmente):
   usar `RenderEditable` (via `GlobalKey` no `EditableText` interno do
   `TextField`) e seu `getPositionForPoint`.

Preferir (1) — mais simples, menos superfície nova. Avaliar (2) só se o UX
ficar estranho (ex.: cursor pula antes de decidir se era go-to-definition).

Depois do offset: converter texto→linha/coluna com a mesma lógica de
`lineStarts`/`offsetFor` inversa já usada em `diagnosticRangesFor()`
(`code_highlight.dart:181-217`) — reusar, não duplicar.

## Passos

1. **`LspClientImpl.definition()`**: método novo sobre `request()`, decodifica
   resposta (`Location | Location[] | LocationLink[] | null`). Aceite: teste
   com payload fixo de cada formato de resposta.
2. **Detecção de modificador + hover**: `MouseRegion` no editor rastreia
   posição; handler de teclado (reusar padrão `HardwareKeyboard.instance`)
   liga/desliga estado "definition mode". Aceite: sublinhado aparece sob o
   identifier ao segurar Cmd/Ctrl e passar o mouse por cima (sem clicar).
3. **Offset → linha/coluna**: função pura que converte offset (mesma unidade
   UTF-16 já usada pelos diagnostics) pra `{line, character}` LSP. Aceite:
   teste unitário com string multi-linha.
4. **Intercepta o tap sob modificador**: `onTapDown`/`onTap` do editor, quando
   modificador ativo, chama `goToDefinition` em vez do comportamento padrão de
   posicionar cursor (ou além dele — decidir no passo se cursor deve mover
   junto, provável que sim, é inofensivo).
5. **`CockpitViewModel.goToDefinition()`**: chama `definition()`, resolve
   `uri`→path absoluto, `openFile()` + `session.reveal(line)` (idêntico ao
   `openTerminalPath`). Sem resultado (`null`/lista vazia) → no-op silencioso
   (sem toast de erro — mesma UX do terminal quando o token não resolve).
   Aceite: Cmd/Ctrl+clique numa chamada de classe/função com
   `typescript-language-server` rodando abre o arquivo de definição na linha
   certa; mesmo arquivo → só revela.
6. **Fora do workspace / sem LSP**: confirma que clique normal (sem
   modificador, ou com modificador mas sem LSP ativo) continua só
   posicionando o cursor — zero regressão.

## Riscos / notas

- **Cobertura de servers**: nem todo language server implementa
  `textDocument/definition` (raro, mas existe) — degrada pro clique normal.
- **LocationLink vs Location**: servers mais novos (ex. alguns TS servers)
  podem devolver `LocationLink[]` (com `targetRange` além de `originSelectionRange`)
  em vez de `Location[]` simples — decodificação precisa tratar os dois
  formatos (campo `uri`/`targetUri` diverge).
- **Multi-root/symlink**: resolução de `uri`→path já deve seguir o mesmo
  `_uri()`/path handling do client LSP existente (`lsp_client_impl.dart`) —
  não inventar normalização de path nova.

## DoD

- [x] `definition()` implementado no client LSP + teste de decodificação
      (Location, Location[], LocationLink[], null)
- [x] Hover sob modificador sublinha o identifier (feedback visual antes do
      clique)
- [x] Cmd (macOS) / Ctrl (Windows/Linux) + clique num símbolo abre o arquivo
      de definição na linha certa (mesmo arquivo ou outro)
- [x] Sem LSP/fora do workspace: clique comportamento idêntico ao atual
- [x] `flutter analyze` zero issues; testes novos passando
- [ ] Teste manual real: projeto TS/Dart com server rodando, classe chamada
      em outro arquivo → ⌘/Ctrl+clique pula certo

## Próximos planos

- Picker de múltiplas definições (quando o server devolve mais de uma
  location) — hoje decisão A adia isso
- "Find references" (`textDocument/references`) — mesma infra, direção
  inversa (quem chama X), fora de escopo aqui
- Hover tooltip (`textDocument/hover`) — mostra assinatura/doc ao pairar sem
  clicar, complementar ao go-to-definition, fora de escopo aqui
