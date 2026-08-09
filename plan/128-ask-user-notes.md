# 128 — Anexar nota a uma resposta `ask_user` no app

## Contexto

O [plano 100](./100-app-ask-user-ui.md) entregou a renderização interativa do
`ask_user` no app e o [101](./101-ask-user-sheet-layout.md) o reformatou como
bottom sheet arrastável. Mas o sheet só coleta **values** + **customText** — ele
ignora um recurso central do pi-ask: **anexar uma nota** a uma resposta.

No TUI do pi-ask, o usuário pressiona `n` (nota por opção, `main.optionNote`) ou
`Shift+N` (nota da questão, `main.questionNote`). No celular não há teclas, então
o recurso simplesmente não existe: o usuário mobile não consegue anotar a
escolha — exatamente o tipo de esclarecimento que um `ask_user` existe pra
capturar.

### O que já está pronto (por que isto é só UI)

O contrato **já carrega notas ponta a ponta** — o buraco é exclusivamente o
widget Flutter:

- **Wire TS** (`pi-extension/src/protocol/types.ts`): `AskAnswerWire` já tem
  `note?` e `optionNotes?: Record<string, string>`.
- **Bridge** (`pi-extension/src/extension_ui_bridge.ts`, `respond`): no caminho
  rico ele repassa `answers` **verbatim** ao evento `@eko24ive/pi-ask:submit`.
  Sem remapeamento, sem perda. **Zero mudanças de TS.**
- **Wire Dart** (`app/lib/protocol/protocol.dart`, `AskAnswerWire`): já tem
  `note` + `optionNotes` e `toJson()` já os serializa.
- **Relay**: frames viajam opacos. Sem mudança.

Logo, **todo o trabalho é em `extension_ui_sheet.dart`**: estado pra notas,
afordagem de UI, e inclusão das notas em `_buildResponse()`.

### Semântica do pi-ask (chave pra fidelidade)

Verificado em `@eko24ive/pi-ask/src/state/answers.ts` (`serializeAnswer`) e
`src/remote-ask.ts` (`applyRemoteAskResponse` → `normalizeRemoteAnswer`):

1. **Nota de questão** (`note`) **pode existir sem resposta selecionada** — é uma
   resposta válida por si (`isResultAnswerEmpty` retorna `false` quando há
   `note`). Sobrevive ao submit.
2. **Notas de opção** (`optionNotes`): o pi-ask armazena o que vem do wire
   verbatim, mas ao **serializar o resultado** mantém só as notas de opções
   **selecionadas** (`answer.selected.map(...)`). Uma nota em opção não
   selecionada é silenciosamente descartada em modo `submit` (só reaparece em
   `elaborate`, que o app não expõe — não-objetivo do plano 100).

Decisão de UX (confirmada com o maintainer): suportar **ambas** as notas
(questão + opção), na forma **inline expandável** (botão "Add note" revela um
`TextField`; chip com a nota quando preenchida).

## Objetivo

O usuário mobile consegue anexar uma nota a uma questão e/ou a uma opção
selecionada, e essa nota chega ao agente junto da resposta — espelhando `n` /
`Shift+N` do pi-ask.

## Não-objetivos

- **Modo elaborate** no mobile (mantém o não-objetivo do plano 100: o app sempre
  envia `mode: "submit"`). Notas em opções não selecionadas seguem sem efeito em
  submit — coerente com o próprio pi-ask.
- **Editor rico** (autocomplete `@`, multi-linha com diff). A nota é um
  `TextField` multiline simples.
- Mudanças no relay / cockpit / pi-extension (o contrato já cobre).

## Estrutura esperada

```
app/lib/ui/chat/widgets/extension_ui_sheet.dart
  _ExtensionUiSheetState
    + Map<String, TextEditingController> _questionNotes   // qid → nota da questão
    + Map<String, TextEditingController> _optionNotes     // "qid\x1Fvalue" → nota da opção
    + Set<String> _openNotes                              // editores abertos (compose key)
    _canSubmit       → conta nota de questão (nota sozinha habilita Submit)
    _buildResponse   → preenche note + optionNotes (só de opções em values)
    _noteEditor(...) → builder compartilhado: botão / chip / field (3 estados)
    _buildQuestion   → affordance de nota de questão após o custom text
    _optionTile      → affordance de nota de opção quando a opção está selecionada
```

## Passos

### 1. Estado + disposal

Campos `_questionNotes`, `_optionNotes`, `_openNotes`. Controllers criados
lazy (como `_custom`) e dispuestos no `dispose()` (evita leak; o sheet é
re-criado por `ValueKey(request.id)`).

**Aceite**: `flutter analyze` sem warnings de lifecycle; controllers de nota
dispostos junto aos de custom text.

### 2. Builder de nota compartilhado (`_noteEditor`)

Três estados visuais, inline:

- **fechado + vazio** → `TextButton.icon` "Add note" (`Icons.note_add`).
- **fechado + preenchido** → chip tocável (`Icons.note_alt` + texto truncado)
  que reabre o editor. Indica que há nota sem ocupar espaço.
- **aberto** → `TextField` multiline (`maxLines: 4`, `autofocus`) com hint,
  sufixo com **Remover** (limpa o texto + fecha → volta pra "Add note") e
  **Recolher** (fecha mantendo o texto → chip). `onChanged: setState` mantém
  `_canSubmit` e o chip
  atualizados por tecla.

**Aceite**: um único builder serve pra nota de questão e de opção; estado
aberto/fechado por compose-key em `_openNotes`.

### 3. Nota de questão (Shift+N equivalent)

Em `_buildQuestion`, após o `TextField` de custom text: `_noteEditor` keyado
por `qid`, hint "Add a note to this answer…". Sempre presente (nota de questão
é independente de seleção).

**Aceite**: digitar só a nota habilita Submit; submit envia `{ note: "…" }` para
essa questão.

### 4. Nota de opção (N equivalent)

Em `_optionTile`, o tile vira `Column([InkWell(tile), if (selected) nota])`.
A affordance de nota de opção aparece **só quando a opção está selecionada** —
espelha `serializeAnswer` (nota de opção não selecionada é descartada) e evita
silenciosamente perder input. O editor fica **fora** do `InkWell` (sibling), pra
que tocar nele não toggue a seleção.

**Aceite**: ao selecionar uma opção, aparece "Add note" abaixo dela; a nota vai
no `optionNotes[value]` só daquela opção; desselecionar (multi) some com o
editor e a nota não é enviada.

### 5. `_buildResponse` + `_canSubmit`

- `_canSubmit`: conta `_questionNoteFor(q.id).text` como resposta (nota sozinha
  habilita). Notas de opção não habilitam sozinhas (só acompanham seleção, que
  já habilita).
- `_buildResponse`: pra cada questão, monta `note` (trim; null se vazio) e
  `optionNotes` = `{ value: note }` apenas das opções presentes em `values`
  (usa `values.toSet()`, **não** o `_selected` cru — em single-select com
  customText, `values` é vazio e a nota da opção overshoot deve cair).

**Aceite**: resposta só com nota de questão envia `{note}`; resposta com seleção
+ nota de opção envia `values` + `optionNotes`; customText em single-select zera
`values` e descarta notas de opção.

### 6. Testes

- nota de questão sozinha habilita Submit e é enviada como `note`;
- nota de opção enviada para a opção selecionada;
- affordance de nota de opção só aparece após selecionar;
- customText em single-select descarta a nota de opção (values vazio).

Manter verdes os testes existentes do sheet (a árvore muda pouco: editores
fechados são `TextButton`, não `TextField`).

**Aceite**: `flutter analyze` 0 issues; `flutter test` verde (descontada a
falha ambiental pré-existente `speech_service_test`, macOS-only).

## Definition of Done

- [x] app: `flutter analyze` 0 issues; `flutter test` verde (sheet + suite) —
      2026-08-09: analyze 0 issues na app; sheet 16/16; suíte completa 664
      pass, 2 falhas pré-existentes/ambientais (`speech_service_test` macOS,
      `chat_page_appbar_test` `SharedTextInbox` provider) confirmadas no baseline.
- [x] pi-extension: **sem mudança** (`pnpm typecheck && pnpm test` segue verde;
      o bridge já repassa `note`/`optionNotes`) — 2026-08-09: typecheck ok,
      848 tests pass.
- [ ] Smoke: responder `ask_user` do celular com nota → nota aparece no
      resultado que o agente recebe no desktop

## Riscos

1. **Nota de opção perdida ao desselecionar (multi)**: o editor some, o texto
   fica no controller lazy; re-selecionar traz de volta. Inofensivo (nunca
   enviado enquanto desselecionado) e preserva o input do usuário.
2. **`autofocus` + sheet expande**: abrir o editor foca o campo → o `Focus`
   do `build` já chama `_expandForKeyboard()` (comportamento validado no
   plano 101 pro custom text). Sem novo risco.
3. **Fidelidade `n`/`Shift+N`**: o app não tem teclas; mapeamos pra affordances
   táteis. Semântica (nota de questão vs nota de opção, regra de seleção)
   idêntica ao pi-ask.

## Próximos planos

- Modo elaborate no mobile (botão "Elaborate" no review) pra que notas em
  opções não selecionadas tenham efeito.
- Editor de nota com autocomplete `@` (paridade total com o `noteEditor` do TUI).
