# 60 — Cockpit Mobile: polish do MVP (iOS/Android)

## Contexto

O cliente mobile (plano 59) está funcional em iPad real: conecta por SSH ao
`cockpit-server` do host, abre terminal (login shell do host, oh-my-zsh), árvore
de arquivos e git. Este plano recolhe os ajustes de UX, latência e empacotamento
levantados no primeiro ciclo de testes do MVP, para deixar o app apresentável e
distribuível.

Regras herdadas: mobile é **cliente remoto puro** (sem motor local, sem server no
device), **sempre landscape**, superfície enxuta (ver `59-cockpit-ipad.md`).
Transporte: desktop = system `ssh -L`; mobile = `dartssh2` (`forwardLocalUnix`).

### Decisões fechadas nesta conversa (2026-08-15)

| # | Tema | Decisão |
|---|---|---|
| **A** | Auth por senha | Suportar nos **dois**: mobile via `dartssh2` (`password:` nativo), desktop via `SSH_ASKPASS` no caminho system-ssh. Senha guardada no Keychain (`flutter_secure_storage`), nunca em claro. |
| **B** | Reorder de panes no touch | Drag **só por handle** (ícone de grip) no mobile; desktop mantém drag livre por mouse. |
| **C** | Nome/ícone do app | "**Cockpit Remote**" + ícone próprio **só no mobile** (iOS/Android). Desktop segue "Cockpit". |

## Waves

### Wave A — Latência / percepção (só cliente, sem tocar no server)

Servidores lentos expõem esperas sem feedback. Abrir a UI primeiro, popular
depois.

- **A1. Dialog de "adicionar workspace" abre já em loading.** Hoje o dialog só
  aparece depois de listar o diretório remoto (segundos de tela morta). Abrir o
  dialog imediatamente em estado `loading` e preencher a lista quando o
  `fs.list` retornar; estado de erro se falhar.
  - Aceite: tocar em "adicionar workspace" abre o dialog em < 100 ms com spinner;
    a lista aparece quando chega; erro de rede vira mensagem no próprio dialog.
- **A2. Abrir arquivo mostra a aba na hora.** Abrir a `FileViewerSession`
  imediatamente em skeleton/"carregando" e preencher quando o `fs.read`
  retornar; estado de erro tipado se falhar (sem frase pronta no `data/`).
  - Aceite: tocar num arquivo abre a aba instantânea com placeholder; conteúdo
    entra ao chegar; arquivo grande/rede ruim não trava a UI.

### Wave B — Gestos de touch

- **B1. Reorder por handle no mobile (decisão B).** Panes de workspace e
  arquivos: no mobile, o arraste inicia só a partir de um handle de grip; o resto
  da linha rola normalmente. `isMobilePlatform` gate; desktop inalterado.
  - Aceite: swipe vertical sobre a lista **rola** (nunca inicia drag); arraste
    pelo handle reordena; desktop segue com drag por mouse.
- **B2. Scroll vs seleção no terminal touch.** Na camada de gesto do terminal
  (`CockpitTerminalGesture`): 1 dedo arrastando = scroll do buffer; seleção de
  texto = long-press pra entrar em modo seleção (padrão Termius/Blink).
  - Aceite: no touch dá pra subir/descer o scrollback com 1 dedo sem selecionar;
    long-press entra em seleção; desktop (mouse) inalterado.

### Wave C — Cadastro de host

- **C1. Seção de ajuda na aba Remote hosts.** Explicar que o host precisa do
  Cockpit (desktop) ou do `cockpit-server` instalado, e mostrar a chave pública
  do device (a mesma do `_DeviceKeySection`) com botão de copiar e um passo-a-passo
  curto de "cole em `~/.ssh/authorized_keys`".
  - Aceite: aba mostra requisito + chave + copiar; texto i18n (en/pt-BR/es).
- **C2. Campos separados: usuário / host / porta.** Trocar o campo único
  `user@host` por três campos; porta default 22. Modelo do host passa a carregar
  `port`. Ambos transportes usam (`-p` no ssh; `port:` no dartssh2).
  - Aceite: cadastro sem precisar digitar `@`; porta custom conecta; hosts
    existentes migram (porta ausente = 22).
- **C3. Auth por senha (decisão A).** Adicionar modo de auth "senha" no cadastro,
  guardado no Keychain. Mobile: `dartssh2` `password:`. Desktop: `SSH_ASKPASS`
  fornecendo a senha ao `ssh -L` não-interativo.
  - Aceite: host só-senha conecta no mobile e no desktop; senha persiste no
    Keychain (nunca em claro/JSON); chave continua funcionando como antes.

### Wave D — Tasks remotas sem output (bug)

Encanamento existe (`RemoteTaskRunner` → `task.out` → `TaskTerminalStore` →
terminal da aba). "Não aparece retorno" é runtime.

- **D1. Diagnóstico.** Rodar uma task remota com log instrumentado: confirmar se
  `RemoteTaskRunner.output(taskId)` emite bytes e se a aba de output monta o
  `CockpitTerminalController`. Hipótese primária: a aba (`TaskOutputSession`) não
  abre/renderiza no mobile; secundária: replay/attach do PTY de task.
- **D2. Fix + aceite.** Rodar uma task remota (ex.: `echo`/`ls`) e ver o output
  streamar na aba de detalhes no mobile; exit status reflete na chip.

### Wave E — Empacotamento e distribuição

- **E1. Bundle IDs com flavor `.debug`.** Espelhar o padrão desktop
  (`work.jacobmoura.cockpit` / `.debug`) em iOS (schemes/xcconfig) e Android
  (`productFlavors`), pra E2E isolado não colidir com o app instalado.
  - Aceite: build debug instala lado a lado do release; ids corretos nos dois OS.
- **E2. Nome + ícone "Cockpit Remote" (decisão C), só mobile.** `CFBundleDisplayName`
  / label Android = "Cockpit Remote"; ícone próprio (iOS asset catalog + Android
  mipmaps/adaptive). Desktop inalterado.
  - Aceite: home screen mostra "Cockpit Remote" + ícone novo; desktop segue "Cockpit".
- **E3. Teste em tablet Android real.** Validar landscape, gestos (B1/B2) e
  conexão remota. Sem código; checklist de validação. Depende de B pronto.

## Definition of Done

- [x] A1 — dialog de add workspace abre em loading imediato
- [x] A2 — abrir arquivo mostra aba com skeleton na hora
- [x] B1 — reorder por handle no rail (mobile); árvore de arquivos usa
      long-press pra iniciar o move (swipe simples rola)
- [ ] B2 — scroll de 1 dedo no terminal sem virar seleção. Investigado: as
      camadas do Cockpit já ignoram touch pra seleção (`terminal_pane` retorna
      cedo em `PointerDeviceKind.touch`; `CockpitTerminal` só rola no touch). O
      leak é harness/modo-específico (provável no mouse-reporting/alt-buffer,
      onde o touch fica sem caminho de scroll). PRECISA de repro no device pra
      corrigir sem regressão no desktop (plataforma primária)
- [x] C1 — seção de ajuda (requisito cockpit/server + chave) na aba Remote hosts
- [x] C2 — campos separados user/host/porta; `port` na entidade (fromJson
      retrocompat: legado `user@host:porta` migra; teste em remote_host_test)
- [x] C3 — auth por senha no Keychain (mobile via dartssh2 onPasswordRequest;
      desktop via SSH_ASKPASS + host key accept-new). Desktop PRECISA de repro
      num host só-senha (não validável nesta sessão)
- [x] D1 — causa do output de task remota diagnosticada (`TaskTerminalStore` só
      assinava o runner local; runner remoto nunca era observado)
- [x] D2 — output de task remota aparece na aba no mobile (store observa N
      runners; `RemoteTaskRunner` registrado na criação). Pendente E2E no device
- [ ] E1 — bundle ids + flavor .debug em iOS e Android
- [ ] E2 — nome/ícone "Cockpit Remote" no mobile
- [ ] E3 — validado em tablet Android real

## Ciclo 2 — testes no device (notas)

Funcionou: conexão remota, terminal remoto (Ghostty reabilitado após casar
ABI flterm/libghostty), arquivos de texto, restauração de layout remoto.

Não funcionou (a reabrir):
- **Controle do teclado (mobile)**: o teclado não some, clicar fora não ajuda.
  O botão flutuante no canto da pane ou ficava sob o teclado ou não bastava.
  DECISÃO: botão dedicado **ao lado do nome do workspace** (top bar mobile),
  sempre visível/alcançável, que tira o foco (unfocus + `TextInput.hide`).
- **Som/turn-status no terminal remoto**: confirmado que é gap de transporte
  (hook roda no host, socket é local do host). Precisa do caminho server-side
  (cockpit-server detecta o hook e emite evento no protocolo RPC). É a Wave G.

Medidas a decidir (este ciclo):
- **Portrait + drawers (F)**: reabilitar portrait no iOS/Android e, quando a
  largura for pequena, colapsar as panes de workspaces (esquerda) e files
  (direita) em **drawers**. Detecção recomendada: **breakpoint de largura**
  (ex.: < ~600dp) em vez de orientação estrita — cobre portrait de celular E
  janela estreita, e mantém inline no tablet portrait (que tem largura).
- **Tasks como modo do painel direito**: Tasks **já é** sub-modo do
  `FileTreePanel` (junto de Files/Search/Database) — o trabalho é garantir que
  o drawer mobile exponha todos os modos. Recomendação: manter para todas as
  plataformas (consistência), sem divergência mobile-only.

### Wave F — Portrait + drawers (decidido 2026-08-15)

Detecção: **breakpoint de largura** (`< ~600dp`), não orientação estrita.

- [x] F0 — botão de dispensar teclado na top bar mobile (FocusManager.
      primaryFocus.unfocus() + TextInput.hide); botão flutuante antigo removido.
- [x] F1 — portrait reabilitado (Info.plist, AndroidManifest fullSensor,
      SystemChrome com as 4 orientações no mobile).
- [x] F2 — `_PanelScaffold`: largura `< 600dp` (mobile) → rail e painel direito
      viram drawers (scrim + toggles da top bar); largura maior mantém inline.
      Selecionar workspace / abrir arquivo fecha o drawer. Pendente E2E no device.
- [x] F3 — `tasksPanel` já é modo do FileTreePanel (Files/Search/DB/Tasks), sem
      gate de remoto → exposto no drawer mobile. Comentário obsoleto atualizado.

### Wave G — Turn-status remoto (som/spinner)

Decisão (2026-08-16): **embarcar o `cockpit-cli` no server**. Ele é necessário
no modo server de qualquer forma (`send`/`send-keys`/`list-panes` cross-pane),
e já traz o `cockpit hook` — então instalar o hook no `~/.claude` do host e ter
o receptor de status vira trivial. Sem redeploy só pra isso: entra junto do CLI.

- [x] G1 — server sobe `TurnStatusReceiver` (socket `<sock>.status` no host) +
      injeta `COCKPIT_STATUS_SOCK` nas PTYs + instala o hook do Claude no
      `~/.claude` do host (`HostHookInstaller`, resolve a CLI ao lado do server).
      `build_server.sh` embarca a `cockpit` CLI no bundle; o bootstrap desktop a
      empurra pro host. Pendente: Codex hook server-side + host Windows.
- [x] G2 — `TurnStatus {pane, st, ev, sid, tx, hn}` no protocolo (broadcast do
      server); `fromJson` tolerante (UnknownMessage) → sem bump de versão.
- [x] G3 — `RemoteTerminalService.turnStatus` → connector → controller → VM
      `_onClaudeStatus` (reusa spinner/chime). Requer server novo + CLI no host
      (redeploy: bootstrap desktop OU manual). Pendente E2E no device.

## Próximos planos

- Auto-update / versionamento de protocolo do `cockpit-server` remoto (pendência
  herdada do 58/59: como o fix do shell/login chega ao host sem redeploy manual).
- Guard dos build hooks do anaki no upstream (iOS/Android) — hoje patch local no
  pub-cache.
