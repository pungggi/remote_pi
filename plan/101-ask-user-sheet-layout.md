# 101 — `ask_user` como bottom sheet arrastável (chat visível)

## Contexto

O [plano 100](./100-app-ask-user-ui.md) entregou a renderização do `ask_user` no
app, e o fluxo foi verificado em hardware (PR #64). O uso real expôs uma
limitação de **layout**, não de protocolo:

> O modal ocupa a tela inteira (`Positioned.fill` → `Scaffold`), então enquanto
> a pergunta está aberta o usuário **não vê o chat**. Mas a pergunta quase
> sempre se refere ao que o agente acabou de dizer — a informação necessária
> para responder está exatamente atrás do modal que a esconde.

No TUI do desktop isso não acontece: a pergunta aparece *dentro* da conversa,
com todo o histórico acima dela.

Este plano NÃO é continuação do 51 no mesmo PR. O #64 já está em review e
reportado como testado; o rework de layout entra como **PR de follow-up** para
manter o #64 revisável.

### Direção escolhida

Bottom sheet arrastável: abre a ~55% da altura, chat visível e **scrollável**
acima, arrastável até quase full para formulários longos.

Alternativas descartadas e por quê:

- **Embutir o contexto no modal** (últimas mensagens dentro do sheet): mais
  barato e sem risco de teclado, mas só entrega o que for empacotado — o
  usuário não consegue rolar arbitrariamente para trás, que é justamente o
  caso que motivou o plano.
- **Card inline no stream de mensagens**: espelha melhor o TUI, mas a pergunta
  pode rolar para fora da tela (exige barra sticky "pergunta aberta"), e
  redesenha o ciclo de vida de `PopScope`/cancel que acabou de ser validado em
  hardware. Fica registrado como possível evolução se o sheet não convencer.

## Estrutura atual (o que muda)

```
chat_page.dart:96        Positioned.fill(child: ExtensionUiSheet(...))
extension_ui_sheet.dart  PopScope > Material > SafeArea > Scaffold(
                           appBar: AppBar(close, title),
                           body: ask != null ? _buildRich : _buildDegraded,
                           bottomNavigationBar: _buildActions,
                         )
_buildRich               ListView.separated  ← controller próprio
```

O `ListView` com controller próprio é o ponto crítico: um
`DraggableScrollableSheet` só arrasta se o scrollable interno usar **o
`ScrollController` que o builder entrega**. Sem isso o gesto é engolido pela
lista e o sheet não sobe.

## Passos

### 1. Trocar o `Positioned.fill` por um sheet ancorado embaixo

`chat_page.dart`: o overlay deixa de cobrir a tela. Mantém-se o `Stack` e o
`ValueKey(uiRequest.id)` (o reset de State por flow já está correto e testado).

**Aceite**: com uma pergunta aberta, o chat continua visível acima do sheet e
**responde a scroll** — dá para rolar a conversa sem fechar nem perturbar a
pergunta. Nenhum scrim bloqueia o toque na área do chat.

### 2. Sheet arrastável com o controller certo

`DraggableScrollableSheet` com `initialChildSize ≈ 0.55`,
`minChildSize ≈ 0.35`, `maxChildSize ≈ 0.95`. O `ScrollController` do builder
é repassado para `_buildRich` (`ListView.separated`) e para o caminho
degradado.

**Aceite**: arrastar o punho move o sheet entre as três posições; com o sheet
expandido, continuar arrastando para baixo **rola a lista** em vez de encolher
(comportamento padrão do widget quando o controller é o correto).

### 3. Barra de ações fixa

`_buildActions` sai de `bottomNavigationBar` (não existe mais Scaffold) e passa
a ficar fixa no rodapé do sheet, acima do conteúdo rolável.

**Aceite**: Cancel/Send visíveis em qualquer altura do sheet, inclusive
colapsado a 0.35. Nunca ficam atrás do conteúdo rolável.

### 4. Teclado — o risco conhecido

Hoje o `Scaffold(resizeToAvoidBottomInset: true)` resolve. Fora dele, é preciso
tratar `MediaQuery.viewInsets.bottom` explicitamente **e** expandir o sheet
para `maxChildSize` quando um `TextField` (custom text) ganha foco — senão o
campo abre atrás do teclado. Esta é a limitação que o plano 100 já registrou
como v1; aqui ela precisa ser fechada, não herdada.

**Aceite**: com o sheet colapsado, tocar num campo de texto livre expande o
sheet e o campo fica visível acima do teclado. Ao fechar o teclado o sheet
mantém a altura expandida (não pula de volta sozinho no meio da digitação).

### 5. Preservar a semântica validada em hardware

Nada aqui pode regredir o que o PR #64 verificou no device:

- `PopScope` — back do Android **cancela o flow** (não colapsa o sheet). Manter
  a semântica atual; introduzir "back colapsa primeiro" seria mudança de
  comportamento sem demanda.
- Estado `submitting`, banner de erro (`Not connected — …`) e o backstop de 25s
  seguem iguais. O banner precisa continuar visível **com o sheet colapsado** —
  é justamente quando o usuário está olhando o chat.
- Seleções e custom text sobrevivem ao arrasto (o State é keyado por request
  id; o arrasto não deve recriar o widget).

**Aceite**: repetir no device os três fluxos já verdes do #64 (happy path,
rendering rico, cancel/back) + o retry por falha de envio, todos com o sheet
em altura colapsada e expandida.

### 6. Testes

Os 6 widget tests existentes do sheet devem continuar passando (podem precisar
de ajuste de árvore, não de semântica). Adicionar:

- sheet colapsado mostra prompt + ações;
- foco em campo de texto expande o sheet;
- banner de erro visível na altura mínima.

**Aceite**: `flutter analyze` 0 issues; `flutter test` verde (descontada a
falha ambiental pré-existente de `speech_service_test`, macOS-only).

## Definition of Done

- [x] Chat visível e scrollável com pergunta aberta (passo 1)
- [x] Sheet arrasta entre 0.35 / 0.55 / 0.95 com o controller do builder (passo 2)
- [x] Ações fixas no rodapé em qualquer altura (passo 3)
- [x] Campo de texto nunca fica atrás do teclado (passo 4)
- [x] `PopScope`, submitting, banner de erro e backstop 25s inalterados (passo 5)
- [x] `flutter analyze` 0 issues + `flutter test` verde (passo 6) — 2026-07-21:
      analyze 0 issues na app inteira; suíte completa 541 pass, 1 falha
      ambiental pré-existente (`speech_service_test`, assume host macOS,
      rodamos em Windows). Os 7 widget tests do sheet passaram **sem
      alteração** — o rework mexeu em layout, não em semântica; +3 testes
      novos de layout (extent parcial, expansão no foco, banner visível).
- [x] Re-verificação em device dos fluxos do #64 nas duas alturas (passo 5) —
      2026-07-21, Samsung SM-F936B (Galaxy Z Fold 4), Android 16 / One UI 8.1,
      APK debug desta branch. Verificados à mão: sheet parcial com chat
      scrollável atrás, drag entre as três alturas, lista rolando com o sheet
      em 0.95 (sem encolher), teclado não cobrindo o campo nem as ações,
      back cancelando o flow, e o banner de retry legível com o sheet
      colapsado.
- [ ] PR de follow-up aberto **separado** do #64

## Próximos planos

- Se o sheet não resolver na prática (ex: formulários longos continuam
  incômodos), avaliar o card inline no stream com barra sticky — descartado
  aqui por custo, não por mérito.
- `elaborate mode` no mobile segue fora de escopo (limitação v1 do plano 100).
