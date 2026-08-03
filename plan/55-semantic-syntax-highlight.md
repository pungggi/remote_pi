# 55 — Semantic syntax highlight (LSP `semanticTokens`)

## Contexto

Pergunta do usuário: dá pra ver o código no cockpit colorido por
**classe/variável** (tipo o tema Dracula do VSCode) e não só léxico?

Investigação (scout-cockpit, 2026-07-24) mostrou dois achados:

1. **Tema Dracula léxico já existe e já é selecionável** —
   `SyntaxColors.draculaDark`/`draculaLight` (`core/ui/themes/syntax_colors.dart:74-103`),
   enum `SyntaxThemeId.dracula`, picker em `settings/ui/settings_page.dart:1384`.
   Nada a fazer aqui — é escolha de tema em Settings, não trabalho de código.
2. **Semantic highlight (cor por classe/variável) não existe** — o highlight
   atual (`buildCodeSpan()`, `core/ui/widgets/code_highlight.dart:224`) é
   **léxico**: regex do highlight.js por tipo de token (keyword/string/number),
   sem noção de símbolo. Comentário no próprio arquivo (linha 107-110) já
   registra isso como adiado para depois.

O que faltava pra semantic highlight não é o parser (analyzer/tree-sitter do
zero) — é **reusar o client LSP que já existe**
(`core/data/lsp/lsp_client_impl.dart`), que já fala JSON-RPC com servers reais
(`request()` genérico, linha 160) e já publica diagnostics por stream
(`file_viewer.dart:174-178`). Falta só um método LSP a mais:
`textDocument/semanticTokens/full`.

## Decisão de escopo

| # | Decisão |
|---|---|
| A | Reusa o client LSP existente — **não** spawna analyzer/tree-sitter próprio. Se o server do arquivo não anunciar `semanticTokensProvider`, degrada pro léxico atual (mesmo padrão do diagnostics: no-op gracioso) |
| B | Cores semânticas mapeiam pra **paleta de tema existente** (`SyntaxColors`) — sem paleta nova. Semantic token type (`class`/`variable`/`parameter`/`function`/…) resolve pros campos já existentes (`klass`, `variable`, `function`...), como o léxico já faz por scope |
| C | Overlay, não substituição: quando semantic tokens chegam, **sobrescrevem** a cor do léxico no range coberto (léxico continua sendo o fallback pra linguagens sem server, ou enquanto o request não voltou) |
| D | Debounce/versão segue o mesmo ciclo do `didChange` já existente (full sync) — sem novo mecanismo de invalidação |
| G | **Tokens remapeados na edição (2026-07-28)**: os offsets dos semantic tokens são absolutos e valem só pro conteúdo analisado. O controller **guardava** o batch anterior, então digitar deslocava o texto e os tokens seguiam apontando pros offsets velhos — a cor caía nas letras erradas até o batch novo chegar (400ms), e errava de novo na tecla seguinte. Era o "highlight de outras letras mudando enquanto digito". `CodeEditingController.value` agora remapeia: token antes da edição fica, token depois desloca pelo delta, token que **cruza** a edição é descartado (o batch novo resolve). Vale pra **qualquer tamanho** de arquivo — o remendo léxico só entra acima de 32KB e por isso não cobria esse caso |
| F | **Tokens versionados (2026-07-28)**: os offsets de um batch de semantic tokens só valem pro conteúdo que o servidor tinha. Três guardas: (1) `file_viewer` **aguarda** o `didChange` antes de pedir tokens — antes o request saía junto com a notificação e o servidor respondia pela versão anterior; (2) a resposta é descartada se o buffer mudou desde o pedido; (3) o pool tira snapshot do texto **antes** do await e decodifica contra ele (ler `doc.lastText` depois pegava versão já avançada). Sem isso, os offsets caíam nas letras erradas e o texto **já digitado** piscava a cada rodada de digitação |
| E | **Teto de 100KB (2026-07-28)**: acima disso o arquivo fica só no léxico (`LspServerPool._kMaxSemanticTokensChars`). Medido num arquivo de 5.371 linhas / 144KB (debug/JIT): aplicar os tokens custa ~40ms de merge **e força um segundo layout de texto completo de ~310ms**, porque chegam async depois do primeiro paint — era ~metade do custo de abrir. A 59KB o mesmo layout fica em ~19ms. 100KB de Dart ≈ 3.500 linhas, então o caso comum mantém o semântico |

## Perfil de performance (medido 2026-07-28, debug/JIT)

Arquivo Dart de 5.371 linhas / 144KB, 38.664 spans:

| fase | abrir | por tecla |
|---|---|---|
| parse léxico + spans | ~100ms | ~47ms |
| layout de texto do Flutter | ~310ms | ~73ms |

Otimizações aplicadas: cache LRU do parse léxico por identidade da String
(`code_highlight.dart`), memo do span pintado (`code_editing_controller.dart`),
sweep de ponteiro monotônico no merge de overlays, gutter virtualizado
(`ListView.builder`), o teto da decisão E, e o reparse adiado abaixo.

### Reparse adiado na digitação (2026-07-28)

Cada tecla gerava texto novo → miss no cache → re-tokenizava o arquivo inteiro
(~47ms a 5k linhas). Agora, acima de 32KB, a rajada de digitação reusa as folhas
do último parse **exato** e remenda só a região editada
(`buildApproximateCodeSpan` + `_patchLeaves`): calcula prefixo/sufixo comuns,
mantém as folhas que caem inteiras neles e substitui o meio por uma folha sem
estilo. O parse exato roda 120ms depois de parar de digitar.

Medido (debug/JIT, via controller): **0.5ms por tecla a 5k linhas** (era ~47ms),
com **zero** execuções do tokenizer numa rajada de 8 teclas.

O remendo é **dentro da folha atingida**: todas as outras são preservadas byte a
byte (mesmo texto, mesmo estilo, mesma instância). Essa é a propriedade que
importa — nenhuma letra fora da edição troca de cor.

Duas versões erradas antes desta, ambas com o mesmo sintoma visível (cor de
outras letras mudando a cada tecla, porque digitação normal tem intervalos
maiores que os 120ms do debounce):
1. meio remendado **sem estilo** → a região editada perdia a cor;
2. meio remendado com **um estilo herdado só** → as folhas que *cruzavam* a
   fronteira da edição eram descartadas e fundidas, então o texto **vizinho** já
   digitado perdia a cor própria até o parse exato.

Limitação inerente que sobra (coberta por teste explícito): se a edição muda a
tokenização do texto vizinho — inserir `X` antes de `int` faz `Xint`, que deixa
de ser keyword — nenhuma aproximação acerta sem re-tokenizar; o parse exato
corrige em 120ms.

A **cobertura** do texto continua exata — invariante coberta por teste; se
quebrasse, cursor/seleção/hit-test sairiam de lugar. Cai no parse exato quando
a edição passa de 2KB (colar bloco grande) ou quando as folhas base já saíram do
LRU.

Alternativa descartada nesta escolha: fork do engine `highlight` com tokenização
por linha e estado do lexer cacheado. Motivo — o estado de **sublanguage**
(`continuations`) é variável local dentro de `_parse` e não é exposto
(`Result.top` só carrega o modo principal), e a gramática Dart usa
`subLanguage: ["markdown"]` nos doc comments: retomar de uma linha dentro de um
doc comment coloraria errado. Expor isso exigiria **modificar a lógica** do
engine, não só um parâmetro — vendorizar deixaria de ser cópia e passaria a ser
fork a manter, com import de `package:highlight/src/` sem proteção de semver.

Descartado **com medição**:
- **Tokenizar por viewport** — atacaria só o parse (~24% do custo de abrir);
  o layout do Flutter domina 3:1 na abertura.
- **Fundir spans adjacentes de estilo igual** — A/B deu 3% menos spans e ~2% de
  layout, dentro do ruído: com semantic tokens densos quase todo trecho vizinho
  tem estilo genuinamente diferente.

Só o layout resta, e ele é inerente ao `TextField` (um `Paragraph` único pro
documento). Cortá-lo exigiria renderer de linhas próprio, o que custa toda a
stack nativa de edição (IME/`TextInputClient`, seleção multi-linha, caret,
`DefaultTextEditingShortcuts`, undo/redo, acessibilidade) — e não dá pra
contornar com um `TextField` por linha, pois seleção entre linhas quebra.
Próximo passo viável, se necessário: tokenização por linha com estado do lexer
cacheado — o pacote `highlight` suporta (`_parse(continuation:)` + `Result.top`)
mas não expõe, então exigiria vendorizar (padrão já usado no repo: xterm,
`cockpit_pty`).

## Estrutura esperada (cockpit/)

- `core/data/lsp/lsp_client_impl.dart` — anunciar capability
  `textDocument.semanticTokens` no `_handshake()` (linha 106-115); capturar
  `serverCapabilities.semanticTokensProvider` (tipos de token/modificador que o
  server suporta) da resposta do `initialize`
- `core/domain/contracts/lsp_client.dart` (ou onde vive a interface) — novo
  método `Future<Result<SemanticTokens?, LspError>> semanticTokensFull(String path)`
- `core/domain/entities/` — nova entity `SemanticTokens` (lista de
  `(deltaLine, deltaStart, length, tokenType, tokenModifiers)`, formato LSP
  cru — decodificação do array plano fica num helper, não na UI)
- `core/ui/widgets/code_highlight.dart` — `buildCodeSpan()` ganha parâmetro
  opcional `List<SemanticRange> semanticTokens` (mesmo padrão de
  `DiagnosticRange`/`MatchSpan`); overlay de cor por semantic type funde por
  cima do léxico igual ao squiggle de diagnostics
- `cockpit/ui/widgets/file_viewer.dart` — `_startLsp()` ganha companion
  `_requestSemanticTokens()`; resultado guardado em state (`_semanticTokens`),
  igual ao `_diagnostics`; re-pedido no debounce do `didChange` (mesmo timer,
  não um novo)
- `core/ui/themes/syntax_colors.dart` — mapa `tokenType LSP → campo SyntaxColors`
  (`class`→`klass`, `variable`/`parameter`/`property`→`variable`,
  `function`/`method`→`function`, `enum`/`interface`/`typeParameter`→`klass`,
  `namespace`→`meta`, etc. — mapear pelo [spec padrão de semantic tokens](
  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_semanticTokens))

## Passos

1. **Capability + captura de server capabilities**: handshake anuncia suporte
   a `semanticTokens` (full, sem range/delta por ora); guarda o
   `SemanticTokensLegend` (tokenTypes/tokenModifiers, arrays de string cujo
   índice é usado na resposta) devolvido pelo server no `initialize`.
   Aceite: log/estado mostra `legend` capturado quando o server anuncia
   (ex.: `typescript-language-server`, `dart language-server` se suportar —
   checar caso a caso, nem todo server implementa).
2. **`semanticTokensFull()`**: novo método no client, chama
   `textDocument/semanticTokens/full`, decodifica o array plano LSP (5 ints
   por token: deltaLine, deltaStartChar, length, tokenType index, modifiers
   bitmask) em offsets absolutos usando o mesmo `lineStarts`/`offsetFor` já
   usado por `diagnosticRangesFor()` (reusar a lógica, não duplicar).
   Aceite: teste unitário com payload LSP fixo → offsets esperados.
3. **Mapear tokenType → cor da paleta**: função pura
   `SyntaxColors.styleForSemanticType(String legendName)` (paralela à
   `styleFor(scope)` do léxico). Sem tipo mapeado → `null` (mantém léxico).
   Aceite: tabela de mapeamento cobre os tipos padrão da spec LSP.
4. **Overlay em `buildCodeSpan()`**: nova lista `SemanticRange` cortada nos
   mesmos moldes de `_applyOverlays()` — cor semântica tem prioridade sobre a
   cor léxica no range coberto (merge de `TextStyle`, léxico primeiro,
   semântico por cima). Aceite: teste com token semântico sobre keyword léxico
   → cor final é a semântica.
5. **Wiring no `file_viewer.dart`**: `_startLsp()` dispara
   `semanticTokensFull()` após `didOpen`; resultado em `_semanticTokens`
   (state); re-pedido no mesmo debounce Timer do `didChange` (linha ~154-178,
   reusar `_lspDebounce`). Sem server ou sem suporte → lista vazia, zero
   diferença visual do que já existe hoje. Aceite: abrir arquivo `.ts`/`.dart`
   com server rodando, ver cor de classe/variável divergir da cor léxica de
   `variable`/`klass` genérica.
6. **Toggle em Settings** (opcional, avaliar no passo 5 se o resultado visual
   já é bom sem toggle): se semantic highlight ficar "ruidoso" em algum
   idioma, expor liga/desliga em Settings ao lado do picker de tema — decisão
   adiada pro fim, só se necessário.

## Riscos / notas

- **Cobertura de servers**: nem todo language server implementa
  `semanticTokensProvider` (ex.: alguns servers minimalistas só fazem
  diagnostics). Nesses casos, fica no léxico — comportamento idêntico ao de
  hoje, sem regressão.
- **Custo**: `semanticTokensFull` é um request a mais por `didOpen`/debounce de
  `didChange` — mesmo padrão de custo que diagnostics já paga hoje; não
  introduz polling novo.
- **`.dbq`/mongo/redis viewers** (reusam `buildCodeSpan()`, plano 53): ganham
  semantic highlight de graça **se** o arquivo/conteúdo tiver LSP associado
  (não é o caso de JSON de documento Mongo, então não muda nada ali).

## DoD

- [x] `semanticTokensFull()` implementado + decodificação testada
      (payload fixo → offsets)
- [x] Mapeamento tokenType→cor cobre tipos padrão da spec LSP
- [x] Overlay semântico funde sobre léxico em `buildCodeSpan()` (teste
      unitário de precedência)
- [x] `file_viewer.dart` pede semantic tokens no open + debounce de change
- [ ] Teste manual: arquivo `.ts` com `typescript-language-server` rodando —
      classe/variável com cor diferente do genérico léxico
- [ ] Degrade gracioso confirmado: arquivo sem server ou server sem
      `semanticTokensProvider` → idêntico ao highlight atual (zero regressão)
- [x] `flutter analyze` zero issues; testes novos passando

## Próximos planos

- Se o ruído visual pedir controle fino: toggle semantic on/off em Settings
  (passo 6 acima, hoje adiado)
- Formatting via LSP (`textDocument/formatting`) — já citado como adiado em
  `code_highlight.dart:96` (Wave 3), fora de escopo deste plano
