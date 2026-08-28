# 59 — Cockpit no iPad/Android: cliente remoto puro

> Continuação natural do [`58-cockpit-remote.md`](./58-cockpit-remote.md). O 58
> provou o cliente/servidor (terminais, arquivos, git, DB, tasks rodando no host
> via `cockpit-server`, transporte SSH). Este plano leva o **cliente** para
> iPadOS/Android, sem motor local.

## Contexto

O Cockpit já é cliente/servidor: todo o motor (PTY, git, DB, LSP, tasks) roda no
host; o cliente só renderiza e troca RPC. Logo o mobile **não porta engine
nenhum** — ele é uma "tela" para um host remoto. O trabalho é (a) fazer o cliente
**conectar** sem depender de coisa de desktop e (b) fazer ele **compilar** sem os
plugins de desktop.

Cenário-alvo: "controlo meus agentes do sofá / da rua, do iPad", falando com um
host (iMac/VPS) que já tem o `cockpit-server` instalado.

## Princípio de corte (o que sobrevive no mobile)

> **No mobile só sobrevive o que é (a) consumível remotamente ou (b) pura
> apresentação. Tudo que é motor-local ou plugin de desktop some.**

Esse princípio faz features futuras se auto-classificarem: se depende de
`Process.start`/FFI/plugin desktop, é motor-local e não vai pro mobile.

## Decisões deste plano

| # | Decisão |
|---|---|
| **A** | **Paridade total remota**: iPad faz tudo que o desktop faz (terminal + arquivos + git + DB + tasks), só que 100% contra um host remoto. Uma base de código, gating por plataforma — não um app separado. |
| **B** | **Transporte único em `dartssh2`** (Dart puro), para desktop **e** mobile. Substitui o `SshTunnel` baseado no binário `ssh` do sistema (plano 58). Verificado: `dartssh2` tem `forwardLocalUnix` (`direct-streamlocal@openssh.com`), então encaminha direto pro socket UNIX remoto `~/.cockpit/cockpit-server.sock` — **zero mudança no `cockpit-server`**. |
| **C** | **Sempre landscape** no iOS/Android (o shell multi-pane é pensado pra largura de desktop). Travado em 3 camadas: `Info.plist`, `AndroidManifest` (`sensorLandscape`), e `SystemChrome.setPreferredOrientations` no `main`. |
| **D** | **Mobile não roda nem instala server**: não há binário local pra empurrar por SSH. O mobile só conecta a hosts **já provisionados** (de um desktop, ou pelo próprio usuário). O painel de hosts no mobile é "conectar + gerenciar chave", sem "install server". |
| **E** | **Auth por chave guardada no dispositivo**: `flutter_secure_storage` (Keychain iOS) para a chave privada; geração de chave in-app (ed25519). Sem `~/.ssh`. |

## Superfície mobile — matriz de Configurações

| Categoria / item | Mobile | Motivo |
|---|---|---|
| General → toggle "Cockpit terminal" | ❌ | sem shell local; pseudo-workspace nem existe |
| General → "Enable agents" | ❌ | agente é motor-local |
| General → "Check for updates" | ❌ | `auto_updater` é desktop; a loja atualiza |
| General → "Launch at login" | ❌ | desktop-only |
| General → Idioma (locale) / Storage / Diagnostics | ✅ | apresentação/app |
| Appearance (tema/fonte) | ✅ | apresentação |
| Notifications | ✅ | `flutter_local_notifications` roda no iOS |
| Terminal (engine/fonte/profile) | ❌ | config de PTY local |
| Languages (LSP) | ❌ | LSP roda no host |
| Automations (commit msg) | ❌ | harness local |
| Connectivity / Daemon Agents / Schedules | ❌ | agente/relay/supervisor |
| Remote hosts | ✅ | é o ponto (sem "install server", ver decisão D) |

Fora das configs:
- **Pseudo-workspace "Cockpit" sempre desativado** (nem renderiza no rail).
- **Empty-state (`WelcomeView`)**: hoje 1 botão (criar workspace local). Passa a
  ter **duas ações** — "Abrir pasta local" + "Conectar a um host" — construídas
  pra todas as plataformas; no mobile só a de host aparece. Gating por flag, não
  build separado.
- **"+" do rail**: hoje sempre abre menu Local vs Remoto. No mobile, o "+" **pula
  o menu e chama direto o fluxo de host**. Mesmo par de callbacks
  (`onCreateWorkspace` / `onConnectHost`); o gating é só "que opções aponto".
- **Titlebar**: um terceiro branch de `buildAppMenus()` — `MobileMenuBar` = layout
  Win/Linux (`Menubar` shadcn) **sem os `window_controls`** (min/max/close, que
  dependem de `window_manager`) e sem arraste de janela.

## Refactor de fundo: `RemoteConnection` sobre transporte duplex

Hoje o `RemoteConnection` (em `cockpit_remote`) está preso ao `Socket` do
`dart:io` (UDS). O `SSHForwardChannel` do `dartssh2` é um duplex equivalente
(`implements SSHSocket`, tem `stream`+`sink`). Então:

- Abstrair `RemoteConnection` sobre um **transporte duplex genérico** (stream de
  bytes + sink), com dois adaptadores: `Socket` UDS (desktop sidecar local) e
  `SSHForwardChannel` (dartssh2, desktop remoto + mobile). Codec, handshake e
  streaming de terminal **não mudam**.
- Trocar o `SshTunnel` do plano 58 por um baseado em `forwardLocalUnix`, reusando
  o `SshHostKeyStore` e o parsing de PEM que o túnel de **DB** já tem
  (`data/db/ssh_tunnel_impl.dart`). Isso **unifica os dois túneis num só**.

## Verificações (spikes) antes de fechar o desenho de build

| # | Verificar | Se falhar |
|---|---|---|
| 1 | ✅ `dartssh2 forwardLocalUnix` → UDS remoto | resolvido (existe) |
| 2 | `flutter build ios/apk` arranca? quais plugins dão hard-fail | vira a lista concreta do guardrail de gating |
| 3 | `libghostty`/`flterm` compila pra iOS (Zig aarch64-ios)? | cair pro renderer xterm puro-Dart no alvo mobile |
| 4 | cliente linka `anaki_*`/`cockpit_pty` direto? (não deveria — é no host) | isolar atrás de fábrica com fallback |
| 5 | `window_manager`/`auto_updater`/`launch_at_startup`/`media_kit`/`desktop_drop` gateáveis por plataforma | gating condicional / stub mobile |
| 6 | geração de chave ed25519 + `flutter_secure_storage` (Keychain iOS) | ajustar auth |
| 7 | teclado virtual iOS vs handling kitty/atalhos do terminal | ajuste de UX de input |

## Passos (waves)

### Wave 0 — Scaffolding + landscape ✅ (2026-08-13)
- [x] `flutter create --platforms=android,ios --org work.jacobmoura .`
- [x] Landscape travado: `Info.plist`, `AndroidManifest` (`sensorLandscape`),
      `SystemChrome` no `main` (gated iOS/Android).

### Wave 1 — Spike de build mobile ✅ (2026-08-13)
Resultado: **os dois alvos compilam** (`app-debug.apk` e `Runner.app`). Bem
melhor que o esperado. O que precisou:
- [x] **Native-asset hooks do `anaki_*` (6 pacotes)**: lançavam
      `UnsupportedError('Unsupported OS')` mesmo sem o código ser chamado.
      Guard aplicado (no-op em OS não-desktop). **PENDENTE UPSTREAM**: a correção
      está só no pub-cache local (efêmera). Jacob precisa aplicar o guard nos
      repos anaki e republicar (ou usar `dependency_overrides` de path). Diff:
      após `final os = input.config.code.targetOS;`, inserir
      `if (os != OS.macOS && os != OS.linux && os != OS.windows) return;`.
- [x] **Android — desugaring**: `flutter_local_notifications` exige
      `isCoreLibraryDesugaringEnabled = true` + `coreLibraryDesugaring(desugar_jdk_libs:2.1.4)`.
- [x] **Android — compileSdk**: `desktop_drop` (desktop-only) fixa SDK 33 mas
      puxa deps que exigem 34+. `compileSdk = 36` no app + override `subprojects`
      forçando 36 nos módulos de plugin.
- [x] **iOS**: compilou direto (pods via CocoaPods; `cockpit_pty`/`media_kit`/
      `pasteboard`/`flutter_secure_storage` têm podspec iOS). SPM ainda não, mas
      CocoaPods resolve.
- [x] **Renderer (item 3)**: `libghostty`/`flterm` **compilaram** pra iOS e
      Android sem patch — o Ghostty passou no nível de build. Falta validar em
      **runtime** (abrir no simulador/device); se não rodar, cai pro xterm puro-Dart.

> Observação: build ≠ runtime. O próximo passo real é **abrir no simulador iOS**
> e ver o app subir (transporte ainda é o desktop; a UI mobile é a Wave 4).

**Runtime no iPad Pro 13" (simulador) ✅ (2026-08-13)**: o app **sobe e renderiza
em landscape** — titlebar estilo Windows ("☰ Cockpit"), aba Terminal, teclado
virtual, e o `cockpit_pty` até **spawnou um shell** (`I have no name!$`, o sim é
macOS por baixo). Exceções observadas, **todas não-fatais** e todas itens de
gating da Wave 2:
- **`status-server` (som/chime, UDS)**: `bind falhou` no iOS (path do container
  excede o limite de UDS + é feature desktop). Gatear off no mobile.
- **update check**: `setLastUpdateCheckTime` no boot dispara `notifyListeners`
  durante o build (auto_updater é desktop). Gatear off no mobile.
- `cleanOrphans` já se protege (`if (!isMacOS && !isLinux) return`); `login_shell`
  não derrubou o boot.

Confirma que Wave 2 (gating) é sobre **desligar subsistemas desktop**, não
consertar compilação — o app já roda.

### Wave 2 — Guardrail de compilação + gating de runtime ✅ (2026-08-14, parcial)
- [x] `core/utils/platform_kind.dart`: helper único `isMobilePlatform`/`isDesktopPlatform`.
- [x] **Gates de runtime** (as 2 exceções do spike): `TerminalStatusServer.start`
      no-op no mobile; update-check no boot só desktop. App sobe **sem exceção**.
- [ ] Isolar o **motor-local de DB** (anaki) do app (hoje só o build hook está
      guardado localmente; falta o guard upstream + idealmente tirar anaki do
      pubspec do cliente). `cockpit_pty`/`libghostty` compilam no mobile, então
      não bloqueiam — só o anaki precisa de tratamento.

### Wave 3 — Transporte dartssh2 no mobile ✅ (2026-08-14)
> **Decisão revisada (2026-08-14)**: `dartssh2` **só no mobile**; o desktop fica
> no system-ssh (mantém ssh-agent/`~/.ssh/config`/ProxyJump, sem regressão no
> fluxo validado). Os dois convivem atrás do `RemoteDuplex`. Unificar o desktop
> fica pra quando o mobile estiver provado em campo.
- [x] `RemoteConnection` sobre `RemoteDuplex` (Socket + `SSHForwardChannel`).
- [x] `SshChannelDuplex` (`forwardLocalUnix` → UDS remoto) + `DartSshHostConnection`
      (parse `user@host[:port]`, host-key TOFU, `forwardUnix`, `run` p/ `$HOME`).
- [x] `MobileSshKeyStore`: gera ed25519 (pinenacl) na 1ª conexão, PEM no Keychain
      (`flutter_secure_storage`), linha `authorized_keys` exposta. Keygen testado
      (round-trip `fromPem`).
- [x] `RemoteHostConnector` ramifica: mobile = dartssh2 (sem bootstrap, decisão D).
- [x] UI: aba Remote hosts mostra a chave pública do device (copiar).
- [ ] **E2E real**: conectar de um device/simulador a um host com a chave no
      `authorized_keys` (a chave nasce no Keychain do device — validação é do
      Jacob com host real). Build iOS/Android verde com as deps novas.

### Wave 4 — Superfície mobile (UI) — núcleo feito 2026-08-14
- [x] Gating de Configurações (matriz): esconde Terminal/Languages/Automations/
      Connectivity/Daemons/Scheduling + seções Agent/Cockpit/Updates do General.
- [x] Pseudo-workspace "Cockpit" nunca injeta no mobile.
- [x] `WelcomeView` com duas ações ("Conectar a um host" sempre; "Abrir pasta
      local" só desktop); "+" do rail direto pro host no mobile.
      **Validado no simulador iPad Pro 13"** (screenshot: só o botão de host).
- [ ] `MobileMenuBar` (titlebar sem window controls) — a titlebar Win/Linux já
      renderiza no iOS de forma aceitável; refino pendente.
- [ ] UX de input (teclado virtual + terminal) — a validar com host real.

## Definition of Done

- [ ] iPad conecta a um host provisionado e opera terminal + arquivos + git + DB
      + tasks (paridade total remota).
- [ ] Cliente compila para iOS e Android sem os plugins desktop.
- [ ] Um único transporte SSH (`dartssh2`) serve desktop e mobile.
- [ ] Sempre landscape no mobile; sem pseudo-workspace local; sem "install server".

## Fora de escopo

- Rodar/instalar `cockpit-server` no próprio dispositivo mobile (decisão D).
- Relay próprio / fora-de-casa (é a Wave 5 do plano 58).
