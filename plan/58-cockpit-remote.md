# 58 — Cockpit Remote: cliente/servidor, hosts acima de realms

> **Status**: RASCUNHO em discussão (2026-08-10). Nada aprovado para implementação.
> Reabre formalmente a decisão B do plano 37 ("Cockpit é local-only"). Registrar
> em `plan/00-decisions.md` quando este plano for aprovado.

## Contexto

O Cockpit hoje é 100% local: spawna PTY, roda git, LSP e drivers de DB na
máquina onde a GUI está. Queremos três cenários novos, em ordem de prioridade:

1. **MacBook → iMac**: o iMac roda o Cockpit (ou só o servidor) e o MacBook
   conecta remotamente, vendo e operando tudo que está lá (estilo tmux attach).
2. **VPS headless**: uma máquina SEM Cockpit instalado, só com o **servidor**
   standalone (binário leve), à qual qualquer cliente Cockpit conecta.
3. **iPad**: build Flutter do cliente Cockpit para iPadOS, obrigatoriamente
   sem engines nativos locais (iOS não permite spawn de processo). O iPad é a
   prova de que o split cliente/servidor está correto: se o cliente compilar
   para iPadOS, a separação está limpa.

Referência de mercado: **Orca ADE** (stablyai/orca, MIT). Desktop hospeda um
servidor WebSocket RPC (porta 6768), app mobile pareia por código/QR + token de
dispositivo, transportes LAN direto e relay próprio, modo `orca serve` headless.
Valida o desenho; nosso diferencial é a camada de databases (anaki), que eles
não têm.

## Decisões deste plano

| # | Decisão |
|---|---|
| **A** | **Sem agente RPC.** O harness `pi --mode rpc` fica FORA do escopo remoto e entra em rota de deprecação. Agentes (pi, claude, codex) rodam como processos dentro de terminais, alinhado ao flag `enableAgent` terminal-first. A fatia `cockpit/data/rpc/` vira legado. |
| **B** | **Escopo remoto = 4 domínios**: Terminais (PTY), Arquivos (árvore/viewer/ops), Git (source control) e Databases (anaki + túneis, executando no servidor). LSP, tasks e o resto ficam para depois. |
| **C** | **Host é a entidade nova do cliente.** O cliente persiste só o registro de hosts (id, nome, transporte, endpoint, token) + pins. Realms/workspaces/layouts/estado de sessão vivem no host dono; realms de host remoto são organização interna DELE (o cliente pina workspaces, endereçados por `(hostId, workspaceId)`, sem importar a estrutura de realms remota pro rail local). Host "Local" é implícito. |
| **D** | **Workspace remoto por pin, misto no mesmo rail** (revisado 2026-08-10; substitui o modelo "janela assume o host"). O cliente pina workspaces remotos como ponteiros `(hostId, workspaceId)` ao lado dos locais; abrir um pin conecta ao host e roteia os serviços DAQUELE workspace pra lá. N conexões simultâneas, roteamento por workspace (a base multi-root já resolve serviço por root). Motivos: não depende de multi-window (incompleto no Flutter) e é o modelo certo pra iPadOS/Android tablet. Badge de host sempre visível no workspace remoto. Dentro de um workspace, o espelhamento segue literal (semântica tmux: mesmo scrollback, N clientes veem o mesmo, last-write-wins no servidor). |
| **E** | **Servidor é a única fonte de verdade** do seu estado: workspaces, layouts, scrollback, worktrees, conexões e senhas de DB (Keychain de lá). O pin no cliente é atalho, nunca dono: se o alvo sumir no servidor, o pin quebra como atalho quebra, sem merge. Cliente guarda apenas preferências de exibição (tema, fonte, idioma) + registro de hosts/pins + cache read-only para exibição offline. Regra geral: preferência de exibição é do cliente; estado de trabalho é do dono. |
| **F** | **Um único servidor, em Dart** (`cockpit-server`, binário `dart compile exe` headless, sem Flutter engine), usado em TODOS os cenários: no desktop como serviço local (transporte loopback), na VPS standalone. Decidido 2026-08-10 (era Rust): o domínio já existe em Dart em `data/` (extração, não reescrita) e cliente+servidor compartilham os tipos do protocolo (mesma classe dos dois lados do fio, zero codegen/drift). Risco único a validar no spike da Wave 0: empacotar as dylibs FFI (cockpit_pty, anaki_*) fora do build do Flutter. **Fallback documentado: Rust**, se o empacotamento FFI afundar o spike. Nunca duas implementações de servidor. |
| **G** | **Transportes plugáveis, SEM relay no primeiro momento** (revisado 2026-08-10): (1) loopback (sidecar local, prova o protocolo), (2) SSH (túnel para o canal do servidor; auth/cifragem/chaves de graça, sem crypto manual). Loopback+SSH cobrem os cenários MacBook→iMac e VPS. **O relay do Remote Pi NÃO será usado**; se um dia o cenário fora-de-casa (tablet em rede celular) exigir relay, será um relay PRÓPRIO do Cockpit, novo, com E2E obrigatório desde o dia 1 — decisão adiada, fora do escopo atual. |
| **H** | **Pareamento estilo Orca**: servidor gera código curto/QR, cliente troca por token de dispositivo persistente (Keychain no cliente). Válido para SSH? Não: SSH usa as chaves SSH do usuário; pareamento por código é pro futuro relay próprio (e eventual LAN direto sem SSH). No escopo atual (loopback+SSH), pareamento nem entra. |
| **I** | **Ciclo de vida: o servidor sobrevive à GUI** (nas máquinas com modo servidor ligado; ver "Arquitetura de pacotes"). `cockpit-server` roda como serviço de usuário (launchd/systemd) que o app instala e garante de pé; a GUI local é só mais um cliente que faz attach/detach. Fechar a GUI do host servido não mata shells nem agentes. Pré-requisito físico: host servidor não pode dormir (avisar/configurar "prevent sleep when display off" ao habilitar o modo servidor). Habilitar o modo servidor exige UI de dispositivos pareados com revogação (é acesso shell completo à máquina; parte do MVP, não polimento). |
| **J** | **Sem allowlist de pastas no servidor (MVP).** Dispositivo pareado = full-trust, modelo SSH: com terminal aberto, restrição de pasta é teatro de segurança (`cd` fura tudo). A segurança mora no pareamento + revogação (decisão I). Config de conveniência permitida: raiz de navegação do picker/árvore (default `~`), sem pretensão de conter ninguém. Escopo de pastas REAL só fará sentido com perfis de capacidade por dispositivo (ex.: "view-only, sem terminal"), evolução futura no espírito dos guardrails de DB (access/agents por conexão). |
| **K** | **Targets mobile via feature flags de compilação** (anotado 2026-08-10, detalhar depois): iPadOS/Android tablet consomem o MESMO cliente com capacidades desligadas em build time (sem PTY local, sem anaki local, sem auto_updater etc.). Complementa os guardrails do iPad abaixo; pensamento a desenvolver em plano próprio. |

## Desenho

```
┌─ MacBook (cliente Flutter) ─┐        ┌─ iMac / VPS ──────────────────┐
│ UI (rail, tabs, ghostty,    │  ws/   │ cockpit-server (Dart AOT)     │
│ viewer, db grid)            │◄──────►│ ├ PTY (cockpit_pty extraído)  │
│ data/ = proxies remotos     │ loop/  │ ├ fs walker + file ops        │
│ hosts.json + pins + tokens  │ ssh/   │ ├ git (binário + parse)       │
│ prefs de exibição           │        │ ├ anaki + túneis SSH de DB    │
└─────────────────────────────┘        │ └ estado: workspaces/layouts  │
                                       └───────────────────────────────┘
```

- No desktop local, o app garante o `cockpit-server` de pé (serviço de
  usuário) e conecta via loopback: workspace local e remoto viram o mesmo
  código de cliente com endpoints diferentes. Espelhamento sai de graça.
- Rail de workspaces mistura locais e **pins remotos** (decisão D), cada pin
  com badge/cor do host (nunca commitar na máquina errada). Host offline =
  pin acinzentado; abrir tenta conectar. N conexões simultâneas, serviços
  roteados por workspace (base multi-root).
- "Add remote workspace" conecta ao host, abre o picker do filesystem REMOTO
  e manda o servidor criar/registrar; o cliente só guarda o pin. Zero
  dualidade de dono.
- **UI do pin no rail** (definido 2026-08-10): badge com o NOME do host (não
  um "REMOTE" genérico — com N hosts no rail, o acidente a evitar é agir na
  máquina errada) + cor do host, carregando também o estado da conexão:
  conectado (quieto) / reconectando (âmbar, panes congelam sem fechar) /
  offline (acinzentado, pin permanece, clicar reconecta). Context menu do
  workspace mostra detalhes: host/endpoint/transporte, estado + latência
  (heartbeat do protocolo), versão do servidor remoto; ações Reconnect,
  Disconnect, Remove pin (só desfaz o atalho, nada apagado no servidor) e
  atalho pras Settings do host. Estados chegam como enum tipado de `data/`;
  frases nascem na UI via `context.t` (padrão dos tradutores de erro).
- **Abertura do pin — estados na área central** (não modal; rail e demais
  workspaces seguem utilizáveis): (1) loading progressivo por etapa do
  protocolo (SSH tunnel → handshake/versão → snapshot), mostrando ONDE travou;
  (2) tela de erro tipada com ação: ssh unreachable (Retry + dica Remote
  Login/macOS), auth recusada (Retry), servidor ausente (**Install server** =
  bootstrap pelo túnel), versão incompatível (**Update server**); (3) queda
  DURANTE o uso NUNCA volta pra tela de erro — vira o estado "reconnecting" do
  badge (banner, panes congelados, auto-retry com backoff). Erros =
  `RemoteConnectError` enum de `data/`, frase via `context.t`, stderr do ssh
  em `detail` cru.
- VPS: nada a instalar manualmente — só precisa de `sshd`. Na primeira
  conexão o cliente faz bootstrap pelo túnel (sobe o binário + unit systemd,
  botão "Install server"); o mesmo caminho atualiza em versão incompatível.
  Script standalone de provisionamento (CI/Ansible) é conveniência futura,
  não requisito.

## Identidade e conexão: sem contas, identidade é criptográfica

(Definido 2026-08-10.) Não existe conta, cadastro nem backend que saiba quem o
usuário é. A lista de hosts vive só no cliente; não há diretório central.

| Transporte | Autenticação | Cerimônia |
|---|---|---|
| Loopback | permissão de SO (UDS; Windows: TCP local + token, como o status-hook) | nenhuma |
| SSH | as chaves SSH do usuário; servidor escuta só localhost, canal tunelado | a de dar `ssh` na máquina (sem pareamento Cockpit por cima — seria autenticar 2x) |
| Relay próprio (futuro, fora do escopo atual; NÃO é o relay do Remote Pi) | pareamento código/QR → Ed25519 + token de dispositivo (Keychain do cliente); relay roteia por chave pública e, com E2E desde o dia 1, não lê nada | uma vez por dispositivo; lição do app: retry de Keychain + falha alta, NUNCA regenerar chave silenciosa |

"Mesma conta nos dois lados?" dissolve: o vínculo é o par de chaves do
pareamento (ou a relação SSH pré-existente); desvincular = revogar o
dispositivo na lista do servidor (decisão I). Futuro consciente: relay
hospedado para terceiros pode um dia exigir conta/API key por controle de
abuso/custo (modelo Orca), decisão de negócio fora deste plano; self-host
segue sem conta sempre.

## Arquitetura de pacotes: Data compartilhado, composição via Modular

(Definido 2026-08-10; DI refinada 2026-08-11.) O motor sai de
`cockpit/lib/app/**/data/` para pacotes Dart puros. **Os pacotes são
agnósticos de DI** (classes com injeção por construtor, sem depender de
auto_injector nem Modular): flutter_modular v7 é Flutter-only, então cada
executável compõe com a própria ferramenta — e como a GUI nunca compõe
`native()`, não há grafo nativo pra "portar" pro Modular:

```
packages/
├── cockpit_core/      contratos domain, Result, erros tipados (zero deps pesadas)
├── cockpit_protocol/  mensagens do fio (depende só de core)
├── cockpit_engine/    impls nativas: pty/dylib, fs, git, anaki, catálogo
│                      (dart:io + dart:ffi — SÓ o servidor importa)
└── cockpit_remote/    proxies dos contratos falando protocol (cliente importa)

cockpit-server  → core + protocol + engine  (compõe com auto_injector puro,
                  mesmas convenções do app: .new, factory-interface, value
                  object p/ primitivos — mesmo parser regex)
GUI Flutter     → core + protocol + remote  (flutter_modular como hoje:
                  proxies e ViewModels nos binds das features)
```

- Enforcement por pubspec, não disciplina: o target tablet simplesmente NÃO
  importa `cockpit_engine` — o guardrail do iPad vira erro de compilação
  (reduz a decisão K a quase nada).
- Ciclo de vida no servidor: markers `Service`/`Disposable` do core; o `main`
  do servidor percorre e dá `dispose()` no shutdown (papel que o Modular faz
  por rota na GUI).
- Pins/N conexões: proxies do cliente recebem a `Connection` do host certo
  via factory-interface injetável (regra existente do auto_injector).

**Política de composição** (revisada 2026-08-10): a GUI é SEMPRE cliente;
`native()` só é composto pelo `cockpit-server`. O que muda entre os modos é
quem supervisiona o processo do servidor:

| Máquina | Processo do servidor | GUI local |
|---|---|---|
| Modo servidor DESLIGADO (default) | **sidecar**: GUI faz `Process.start`, derruba ao fechar | `remote(loopback)` |
| Modo servidor LIGADO (iMac, VPS) | serviço de usuário (launchd/systemd) | `remote(loopback)` |
| Tablets (iPadOS/Android) | não existe | só `remote(...)` a hosts |

Um único caminho de código na GUI; o toggle "Enable server mode" só troca o
supervisor (sidecar → serviço), SEM migração de estado (o `state/` sempre foi
do servidor). Gestão de processo do sidecar: descoberta pelo socket antes de
spawnar (nunca dois servidores no mesmo `state/`), reconexão/respawn com
backoff se o sidecar cair, auto-shutdown do sidecar quando o último cliente
desconecta, handshake com versão (app embarca o binário como o `cli/`, em
`~/.cockpit/bin`), guards conhecidos de spawn no macOS (SIG_IGN de SIGPIPE;
reparent launchd). Composição `native()` in-process na GUI fica como
**fallback documentado** apenas se o benchmark da Wave 0 reprovar o loopback.
No modo desligado o comportamento visível é o de hoje (fechar a GUI encerra
as sessões).

## CLI interna e hooks no modo cliente/servidor

O socket que atende o `cockpit` (CLI) e o `cockpit-hook` (status de turno)
passa da GUI para o `cockpit-server` — mesmos binários, mesmo protocolo de
linha (manter o gotcha: despacho por LINHA, não onDone), mesmo transporte
(UDS/POSIX, TCP+token/Windows), env injetado por PTY pelo servidor
(`COCKPIT_PANE_ID`, PATH escopado, endereço do socket).

- Comandos de engine (`send`, `send-key`, `list-panes`, `list-workspaces`,
  `orchestrate`/`.ckp`, `db`/`mongo`/`redis`, scrollback) são atendidos
  integralmente pelo servidor → **CLI e orquestração entre agentes funcionam
  sem GUI aberta** (VPS/24/7): dispatch, `[ORCH:]`, result files viram
  infraestrutura da máquina.
- Efeitos de UI (spinner/badge, chime, notificação do SO) viram **eventos
  rebroadcastados** pelo protocolo aos clientes attached; quem apresenta é o
  cliente (regra de foco atual). Sem cliente attached, o evento só atualiza o
  estado do pane.
- Escopo por host: o CLI enxerga apenas os panes da máquina onde roda; não há
  `send` cross-host nesta fase (quem cruza máquinas é o cliente GUI via pins).

## Ponto crítico: extração do motor local para o servidor

Com o servidor em Dart (decisão F), o custo dominante deixou de ser reescrita
e virou **extração**: mover o que hoje vive em `data/` (PTY, walker, parser de
git, orquestração anaki, catálogo/migrator) para pacotes consumidos tanto pelo
app quanto pelo binário `cockpit-server` (`dart compile exe`). O risco técnico
concentrado, e gate do spike da Wave 0, é o **empacotamento das dylibs FFI
fora do build do Flutter** (cockpit_pty, anaki_*): carregamento manual de
dylib + bundling por plataforma no CI, e Keychain sem plugin Flutter (chamar
`security`/libsecret direto). O protocolo (WebSocket + mensagens tipadas,
documentado em `docs/remote-protocol.md`) nasce na Wave 0; as classes de
mensagem são um pacote Dart compartilhado entre cliente e servidor (mesma
classe dos dois lados do fio).

## Guardrails para o iPad (valem desde a Wave 1)

- Nenhum `Process.start`, `dart:ffi` de engine ou path de filesystem local no
  código de cliente dos 4 domínios; tudo atrás dos contratos de `cockpit_core`.
- Enforcement por pubspec: código nativo vive em `cockpit_engine`, que o
  cliente NUNCA importa — o guardrail é erro de compilação, não disciplina.
  Sobram poucas deps Flutter desktop-only (media_kit, auto_updater) para
  flags/compilação condicional (decisão K).
- Transporte no iPad: **revisado em 2026-08-13** — o mobile usa `dartssh2`
  (SSH em Dart puro) com `forwardLocalUnix` pro UDS remoto, unificado com o
  transporte do desktop. O relay próprio segue como futuro (decisão G). Ver
  [`59-cockpit-ipad.md`](./59-cockpit-ipad.md), decisão B.
- Teclado virtual + terminal é problema de UX próprio; detalhado no
  [`59-cockpit-ipad.md`](./59-cockpit-ipad.md), não neste.

## Passos (waves)

### Wave 0 — Spike: pacotes + servidor Dart mínimo (terminais) ✅ (2026-08-11)
- [x] Pacotes `cockpit_core` / `cockpit_protocol` / `cockpit_engine` /
      `cockpit_remote` / `cockpit_server` em `cockpit/packages/`; binário
      `cockpit-server` (dart compile exe OK, sem Flutter) composto com
      auto_injector puro; UDS listener + handshake com versão.
- [x] **Gate FFI: PASSOU.** cockpit_pty compilado standalone com `cc` puro
      (`tool/wave0/build_pty_dylib.sh`, sem CMake/Flutter), carregado via
      `DynamicLibrary.open` + native ports em Dart puro. Bindings à mão em
      `cockpit_engine` (a API são 6 funções). Anaki: mesmo caminho, provar
      na Wave 4.
- [x] `docs/remote-protocol.md` (handshake + Terminais; JSONL, envelope,
      offsets, erros); mensagens em `cockpit_protocol`, mesma classe dos
      dois lados.
- [x] Terminais ponta a ponta: open/input/output/resize/kill/attach com
      replay. **Decidido: ring buffer de bytes crus** (4 MiB/sessão,
      offset absoluto; emulador fica no cliente). E2E
      `tool/wave0/wave0_e2e.dart`: 8/8 PASS, incluindo detach da conexão +
      reattach com scrollback completo + live após replay.
- [x] Benchmark `tool/wave0/wave0_bench.dart`: eco FFI 0.016ms p50 vs
      loopback 0.132ms p50 → **acréscimo 0.116ms (orçamento 1ms) PASS**.
      Dump 32MiB: 105 vs 90 MiB/s (base64/JSONL custa ~14%; frame binário
      fica anotado como otimização se precisar).
- **Aceite**: CUMPRIDO (e2e 8/8 + gate FFI + benchmark). Lição aplicada:
  dispatch do servidor serializado por conexão (listen não espera handler
  async; sem isso pty.list ultrapassa pty.kill).

### Wave 1 — GUI vira cliente (sidecar loopback) — núcleo feito 2026-08-11
- [x] `SidecarTerminalGateway` + `SidecarTerminalConnector` em
      `data/terminal/sidecar/`: mesmo contrato `TerminalGateway`, PTY no
      servidor, emulador no cliente. `start()` síncrono vira fila de
      operações até o backend abrir; sem sidecar disponível, fallback
      automático pro `PtyTerminalGateway` in-process (app se comporta como
      antes por construção).
- [x] Ciclo de vida do sidecar: descoberta pelo socket
      (`~/.cockpit/cockpit-server.sock`) ANTES de spawnar; spawn com
      `--exit-on-idle 15` (seguro contra órfão: servidor sem clientes se
      encerra); reconexão via `ensure()` por gateway novo. Binário resolvido:
      env `COCKPIT_SERVER_BIN` → `~/.cockpit/bin` → `build/wave0` (dev,
      `tool/build-sidecar.sh [--install]`).
- [x] **Flow control fim-a-fim** (integra o plano 57 ao protocolo):
      `pty.open{flow:true}` + `pty.ack{n}`; servidor abre o PTY com ackRead
      e gate por janela de créditos (256KiB, amortiza o RTT — ack por chunk
      serializaria a ~8MiB/s); cliente devolve crédito por CONTADOR acumulado
      (imune ao Utf8Decoder segurando sequência parcial + coalescer
      suprimindo add vazio, que vazaria janela até stall). Sem consumidor
      attached, leitura corre livre pro scrollback (semântica tmux).
- [x] Verificação: e2e 9/9 (novo passo de flow control), teste de integração
      `test/data/sidecar_terminal_gateway_test.dart` (gateway real via
      sidecar: eco, fila de ops, resize, ack, kill), suíte 884 verde,
      `flutter build macos` ok, analyze sem issues novos.
- [x] E2E manual no app real (2026-08-11, validado pelo Jacob): terminais
      idênticos ao comportamento anterior; `ps` confirma o desenho — shell
      `/bin/zsh -l` filho do `cockpit-server` (~17MB RSS), GUI conectada no
      UDS, zero duplicados/órfãos.
- [x] Empacotamento no bundle `.app` (2026-08-11): `macos/build_server.sh` +
      fase Run Script no Xcode (padrão do `build_cli.sh`); Resources ganha
      `cockpit-server` (AOT, FATIA ÚNICA do host — AOT Dart não sobrevive ao
      lipo, mesma razão que levou a CLI pra Rust; Mac Intel com build arm64
      cai no fallback in-process, pendência: fatia x64 por runner no CI) +
      `libcockpit_pty.dylib` universal; connector resolve Resources antes de
      `~/.cockpit/bin`. Verificação do binário por probe socket (NUNCA rodar
      sem --socket: vira servidor órfão — bug real corrigido).
- [ ] **Pendente da wave**: benchmark revalidado dentro do app real.
- **Aceite**: Cockpit local funciona igual a hoje com terminais servidos pelo
  sidecar; benchmark revalidado no app real; `flutter analyze` + testes
  verdes.
- **Fora do escopo da wave (decidido na implementação)**: tasks
  (`PtyTaskRunner`) seguem in-process — migram junto com o domínio de tasks
  em wave futura.

### Wave 2 — Transporte SSH + primeiro workspace remoto (terminais)
**Backend feito 2026-08-11; UI pendente.**
- [x] `SshTunnel` (`data/remote/`): binário `ssh` do sistema, forward
      UDS→UDS, BatchMode (senha interativa falha alto), ServerAlive.
      Aprendizados de implementação: forward streamlocal exige path remoto
      ABSOLUTO (resolvemos `$HOME` via exec antes); EPIPE assíncrono do
      forward derruba o processo sem guard no `socket.done`; `pkill -f` em
      comando ssh precisa do padrão `[c]...` pra não matar o próprio shell.
- [x] Bootstrap "Install server" (`RemoteHostConnector`): binário + dylib do
      bundle local sobem por `cat > arquivo` via stdin do ssh (sem depender
      de scp no host), servidor remoto inicia com `nohup --exit-on-idle 0`
      (host servido não morre sozinho; launchd/systemd = Wave 3). Fases
      observáveis (openingTunnel → installingServer → connecting →
      connected/reconnecting/failed) + erros tipados (`RemoteHostErrorKind`)
      prontos pro loading progressivo e telas de erro da UI.
- [x] `RemoteHost` (entity) + `RemoteHostsStore` (contrato) +
      `JsonRemoteHostsStore` (impl no JsonStateStore) — ainda sem bind (a UI
      é quem passa a usar).
- [x] E2E `tool/wave0/wave2_e2e.dart <user@host>` (validado contra
      localhost via sshd real, 6/6): install via ssh, servidor remoto,
      handshake pelo túnel, shell remoto, **sessão sobrevive à queda do
      túnel**, reattach com scrollback.
- [x] Bridge UI↔backend (2026-08-11): `RemoteHostTerminalGateway`
      (`data/remote/`) adapta o `RemoteHostConnector` ao contrato
      `TerminalGateway` — mesma maquinaria de sessão do app, flow control por
      contador, SEM fallback in-process (host inalcançável = aba encerra, nunca
      shell local na máquina errada). Bind do `RemoteHostsStore` no módulo.
      i18n `cockpit.remoteHost.*` nas 3 línguas (slang gerado) + tradutores
      `remoteHostErrorMessage`/`remoteHostPhaseLabel` no padrão do core.
      Teste de integração `remote_host_terminal_gateway_test.dart` (gateway
      remoto real via SSH: eco/ack/kill) verde; suíte 884, build macos ok.
- [ ] **Último passo da wave (integração no rail, pra fechar)**: widget do pin
      no `projects_rail` + workspace kind remoto no `CockpitViewModel`
      (roteia `_terminalFactory` pro `RemoteHostTerminalGateway` do host) +
      dialog "Add remote host". Deixado à parte por ser cirurgia no VM de
      ~4000 linhas (alto risco sem muitas iterações na GUI); todas as peças
      que ele consome já existem, testadas.
- **Aceite**: MacBook abre pin do iMac, terminal remoto utilizável; queda de
  rede congela e reata sem perder a sessão; "Install server" funciona numa
  máquina virgem.

### Wave 3 — Arquivos + Git remotos — backend feito 2026-08-11
- [x] Camada RPC no protocolo: `RpcRequest{rid,method,params}` /
      `RpcResponse{rid,ok,data,code,detail}` — envelope genérico
      request/response para domínios não-streaming, correlação por rid
      (N chamadas concorrentes), erros tipados. O terminal (streaming) fica
      com suas mensagens próprias.
- [x] Domínio **Arquivos** (`FileService`): `fs.list`/`fs.read`/`fs.write`,
      impl nativa `NativeFileService`, proxy `RemoteFileService`. Erros
      tipados (`FileErrorKind`), bytes em base64.
- [x] Domínio **Git** (`GitService`): `git.status`/`diff`/`stage`/`unstage`/
      `commit`, impl nativa `NativeGitService` (roda `git -C` no host, parse
      do porcelain=v1 -z), proxy `RemoteGitService`. Erros tipados
      (`GitErrorKind`, stderr cru em `detail`). Mesmo modelo do
      `data/filesystem/git_*` do app, agora do lado do servidor.
- [x] Servidor injeta os dois serviços (auto_injector) e roteia RPC por
      método; `RemoteConnection.call()` no cliente.
- [x] Verificação: e2e estendido 14/14 (fs.write/read, fs.list, git
      untracked→staged→commit na MESMA conexão dos terminais) + unit
      `native_git_service_test`. Suíte 884, analyze limpo nos pacotes.
- [x] **Integração de UI (2026-08-11)**: "+" vira menu Local/Remoto; workspace
      remoto = PASTA de um host (RemoteWorkspacePin persistido; vários por
      host, igual local); seleção de pasta ao conectar via picker remoto;
      **árvore de arquivos remota** (listChildren → fs.list) e **abrir arquivo
      remoto** no viewer (fs.read → texto/md/svg). Rotas por `_activeRemoteHost`.
- [x] **Source control remoto (2026-08-11)**: RemoteGitAdapter (porcelain XY →
      GitInfo, testado); cache `_remoteGitInfo` no VM recarregado no select e
      pós-mutação; getters/ações git roteiam pro RemoteGitService quando o
      workspace ativo é remoto. Funciona: status, stage/unstage, commit, **diff
      lado-a-lado** (parseUnifiedDiff extraído, reuso local+remoto). Painel de
      Source Control igual ao local.
- [ ] **Pendente da wave**: discard/amend remotos (bloqueados com msg);
      histórico de commits remoto (falta `git log` no GitService); **write
      remoto** (editar/salvar via fs.write); imagem/mídia remota (download);
      worktrees remotos; catálogo servido pelo servidor (decisão E); sockets
      CLI/`cockpit-hook` no servidor + rebroadcast.
- **Aceite**: do MacBook, navegar árvore, abrir arquivo, stage/commit no
  iMac; GUI do iMac aberta ao mesmo tempo espelha (decisão D); `cockpit send`
  funciona com GUI fechada.

### Wave 4 — Databases remotos + VPS de ponta a ponta
- [x] Anaki + túneis de DB executando no servidor; grid/.dbq no cliente
      recebem só resultados paginados. **Entregue e validado na GUI
      (2026-08-12)**: SQL (Postgres/MySQL/MSSQL/SQLite) + Redis + Mongo rodam no
      `cockpit-server` do host via `dart build cli` (native assets do anaki);
      grid, `.dbq` e painéis Redis/Mongo consomem os resultados do host.
      Conexões lidas do `.cockpit/databases.json` do host; senha cacheada por
      sessão (sem re-prompt do Keychain).
- **Aceite**: workspace numa VPS sem GUI (terminal + arquivos + git +
  commit) e query num Postgres acessível só pela VPS, tudo do MacBook.
  > Mecanismo validado contra `jacob@localhost` (mesmo caminho SSH→server); um
  > VPS real usa exatamente o mesmo fluxo.

### Pendência — Task Run remoto (plano 48) NÃO remotizado
> O **Task Run** (`tasks.json`, plano 48) ficou **fora** do escopo dos domínios
> remotos do plano 58 (que cobriu terminais/arquivos/git/databases). Hoje é
> **local-only por construção**: a descoberta lê `.cockpit/tasks.json` do disco
> **local** (`File(...).readAsString`, não `fs.read`) e a execução spawna **PTY
> local** (`Process.start` + `launchctl asuser`). Num workspace remoto rodaria
> na máquina errada, então **o painel de Task é escondido em workspace remoto**
> (gate por `isRemoteTerminal` em `cockpit_page`, 2026-08-12).
>
> **ENTREGUE (2026-08-13)**:
> - [x] Descoberta remota: `RemoteTaskDiscovery` lê `tasks.json` via `fs.read` do
>   host (reusa o parser `TasksJsonLoader.parseContent`); sem auto-detect por
>   adapters (no remoto as tasks vêm só do JSON).
> - [x] Execução remota: `RemoteTaskRunner` spawna a task num PTY do host via o
>   domínio de terminal (`TerminalService.open` + attach), mapeando `PtyEvent`→
>   `TaskRun`. Login shell (`/bin/sh -lc 'exec …'`) pro PATH; teclas interativas
>   (stdin), stop/restart/resize funcionam. Painel des-gateado no remoto.
> - **Fica de fora (não-MVP)**: reload-on-save (sem watch de FS remoto), detecção
>   de progresso (badge building→running), criar `tasks.json` de exemplo pelo app
>   (edita-se no host).

### Pendência — Status de turno (som/notificação) NÃO chega do host
> O chime/notificação de fim de turno do claude é **100% local** hoje: o
> `cockpit-hook` reporta por um **socket Unix na máquina cliente**
> (`TerminalStatusServer`). Quando o claude roda num **terminal remoto**, o hook
> dispara **no host** — que não tem o `cockpit-hook` instalado nem alcança o
> socket do cliente — então **turnos remotos não produzem som/notificação**
> (confirmado 2026-08-13). Não é regressão; é lacuna do setup remoto.
>
> **A adicionar** (domínio "status" remoto, contraparte do que já existe pra
> terminais/arquivos/git/db/tasks):
> - [ ] **Protocolo**: evento `status` push server→cliente (mesma conexão RPC
>       que já faz streaming de output do terminal).
> - [ ] **Server**: mini status-listener no host (socket Unix, igual o do
>       cliente) + forward do evento pela conexão.
> - [ ] **Bootstrap**: instalar o `cockpit-hook` no host (empurrar o binário,
>       como o server + dylibs). **Pegadinha**: `cockpit-hook` é exe Dart AOT →
>       host Linux (VPS) precisa da fatia Linux empacotada; macOS→macOS direto.
> - [ ] **Spawn remoto**: injetar `COCKPIT_TAB_ID` + caminho do socket **do
>       host** no env do terminal/task remoto (hoje injeta o do cliente).
> - [ ] **Cliente**: rotear o evento recebido pro `onTurnFinished` da sessão
>       remota certa (por `COCKPIT_TAB_ID`) → reusa a lógica de som/notificação
>       atual (foco/aba ativa/settings valem igual).

### Wave 5 — Relay próprio + E2E (pré-requisito do tablet fora de casa)
> **Wave condicional, fora do escopo atual** (decisão G): só entra se o
> cenário fora-de-casa justificar; relay PRÓPRIO do Cockpit, não o do
> Remote Pi.

- [ ] **Melhorias de CI/CD** (pedido 2026-08-13): validar o job `server-x64`
      numa release real; automatizar a validação E2E remota; revisar a matriz de
      build (fatias/assinatura) e o gate de publicação do bundle do servidor.
- [ ] Pareamento código/QR (Ed25519 + token de dispositivo) + revogação.
- [ ] E2E sobre o pareamento (Noise ou equivalente; NUNCA plaintext).
- [ ] Relay próprio + transporte no cliente e no servidor.
- **Aceite**: MacBook em rede celular (hotspot) opera o iMac via relay; captura
  de tráfego no relay não revela conteúdo.

## Definition of Done (do plano inteiro)

- [ ] Os 3 cenários do Contexto funcionam (iMac attach, VPS, base pronta p/ iPad)
- [x] `plan/00-decisions.md` atualizado (local-only reaberto; pi RPC deprecado)
- [ ] `docs/remote-protocol.md` completo e versionado
- [ ] Guardrails iPad verificados: cliente compila sem os plugins desktop
- [ ] Zero crypto manual (SSH ou E2E de biblioteca auditada)

## Fora de escopo (explícito)

- Attach de host inteiro ("a janela vira o iMac") e multi-janela por host
  (futuros; o modelo v1 é pin por workspace)
- LSP, tasks, self-update remotos
- Views independentes por cliente attached (v1 é espelho puro)
- Cliente iPad em si (plano próprio quando Wave 5 fechar)

## Próximos planos

- `59-cockpit-ipad.md` (cliente iPadOS)
- Deprecação formal de `cockpit/data/rpc/` (pi --mode rpc)
