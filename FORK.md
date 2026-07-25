# Piper — fork do Remote Pi

**Piper** é um **hard fork** de
[`jacobaraujo7/remote_pi`](https://github.com/jacobaraujo7/remote_pi).
Ele não pretende voltar pro upstream: a divergência de identidade (bundle IDs,
domínios, branding) é intencional e permanente.

O upstream continua sendo a fonte de correções e features novas, então o
repositório precisa continuar mergeável. Este documento define como.

---

## Direção do merge

**Sempre `upstream → fork`. Nunca o contrário.**

```
upstream/main ──merge──► main ──merge──► <branch de trabalho>
```

`main` é o **tronco do Piper**: o upstream mergeado mais os commits de
divergência (identidade, branding, docs deste fork). Nada de feature vai direto
pra `main` sem passar por um branch de trabalho.

Não existe branch local espelhando o upstream, e não precisa: `git fetch
upstream` já mantém `upstream/main` como referência somente leitura. É ela o
espelho.

## Remotes

```bash
git remote add upstream https://github.com/jacobaraujo7/remote_pi.git
git fetch upstream
```

`origin` = este fork. `upstream` = repositório original, somente leitura.

## Sincronizar com o upstream

```bash
git fetch upstream
git checkout main
git merge upstream/main        # merge, não rebase
git push origin main
```

**Merge, não rebase.** Os commits deste fork já estão publicados; rebase
reescreveria história compartilhada. O custo é um histórico com merges — que é
exatamente o registro que queremos ("neste ponto trouxemos o upstream").

Ligue o `rerere` uma vez para não resolver o mesmo conflito a cada sync:

```bash
git config rerere.enabled true
```

## Contribuir de volta pro upstream

Desde que a renomeação para Piper entrou, **nenhum PR pro upstream pode sair de
`main`**. Um PR tirado dali carregaria junto `ch.pungitore.piper`, "Piper
Cockpit", os placeholders de assinatura Apple e a CLAUDE.md reescrita —
impossível de mergear no repositório do Jacob.

Branch de contribuição sai sempre de `upstream/main`, nunca de `main`:

```bash
git fetch upstream
git checkout -b fix/<tema> upstream/main
# … commits que valem para os dois lados …
git push -u origin fix/<tema>
```

Os branches `feature/mobile-ask-user` (PR #64) e `feature/ask-user-sheet-layout`
(follow-up do plano 101, ainda não aberto) existem exatamente por isso e ficam
**congelados**: são a versão do trabalho sem a identidade do fork. Apagá-los
quebraria o PR aberto.

Quando algo nasce em `main` e depois se mostra útil pro upstream, o caminho é
`git cherry-pick` do commit sobre um branch novo tirado de `upstream/main` —
conferindo que ele não toca em nenhum ponto da tabela de divergência abaixo.

## Conflitos recorrentes esperados

Os pontos de divergência intencional colidem toda vez que o upstream mexe neles.
Em conflito nesses arquivos, **a versão do fork vence** — a menos que o upstream
tenha mudado a lógica em volta, não só o identificador.

| Área | Arquivos típicos |
|---|---|
| Bundle / package IDs | `app/android/app/build.gradle.kts`, `app/ios/Runner.xcodeproj/project.pbxproj`, `app/packages/remote_pi_identity/**`, `cockpit/**` |
| URLs de relay / site / downloads | `app/lib/data/transport/relay_config.dart`, `pi-extension/src/config.ts`, `cockpit/lib/app/cockpit/cockpit_module.dart`, `site/src/**` |
| Branding | `branding/**`, `README.md`, `app/store_listing.md` |
| Instruções de agente | `CLAUDE.md` da raiz |
| Âncora de confiança do self-update | `cockpit/windows/runner/Runner.rc`, `cockpit/macos/Runner/Info.plist` |
| Apple fora de escopo | `app/ios/ExportOptions.plist` (removida — conflito modify/delete) |

## Numeração de planos

`plan/` do upstream ocupa a faixa baixa e continua crescendo (já está em 53).
**Planos deste fork usam `100+`.** Sem isso, dois planos diferentes com o mesmo
número colidem no merge e `plano NN` vira ambíguo nos comentários de código.

## O caso do PR #64 (upstream)

O trabalho de `ask_user` deste fork ([`plan/100`](./plan/100-app-ask-user-ui.md)
e [`plan/101`](./plan/101-ask-user-sheet-layout.md)) também foi proposto ao
upstream como PR #64. Se o upstream fizer **squash merge**, o mesmo conteúdo
volta como *um* commit estranho e conflita com os 17 commits originais daqui.

Quando isso acontecer, uma vez só:

```bash
git fetch upstream
git merge upstream/main
# nos arquivos de app/ e pi-extension/ do ask_user: manter a versão do fork
git checkout --ours <arquivo>   # depois de conferir se o upstream não mudou a lógica
```

A alternativa (`git rebase --onto upstream/main <base-antiga>`, descartando os
17 commits duplicados) só vale se os branches ainda não tiverem descendentes
publicados.

## Verificação antes de mergear qualquer coisa

Não há CI de pull request neste repositório — só workflows de release
(`app-release.yml`, `cockpit-release.yml`). O que não for rodado à mão não foi
verificado:

```bash
cd app          && flutter analyze && flutter test
cd pi-extension && pnpm install && pnpm typecheck && pnpm test   # pnpm, não npm
cd relay        && cargo test
```

## Identidade do fork

| Upstream | Piper |
|---|---|
| `work.jacobmoura.remotepi` | `ch.pungitore.piper` |
| `work.jacobmoura.cockpit` | `ch.pungitore.piper.cockpit` |
| `dev.remotepi.identity` | `ch.pungitore.piper.identity` |
| `dev.remotepi.owner.identity` | `ch.pungitore.piper.owner.identity` |
| `dev.remotepi.{peers,rooms,pi,mac}` | `ch.pungitore.piper.{peers,rooms,pi,mac}` |
| `dev.remotepi.supervisord` | `ch.pungitore.piper.supervisord` |
| "Remote Pi" / "Remote Pi Cockpit" | "Piper" / "Piper Cockpit" |

Os identificadores de keyring (`*.peers`, `*.rooms`, `*.pi`, `*.owner.identity`)
guardam as chaves de pareamento. **Nunca aponte a migração legada de
`pairing/storage.ts` de volta pro namespace `dev.remotepi.*`**: ela copia a
entrada antiga e *apaga* a original, ou seja, quebraria o pareamento de uma
instalação Remote Pi na mesma máquina.

## Plataformas Apple: fora de escopo

**Decisão (2026-07-25): este fork não entrega iOS nem macOS.** Não há
membership no Apple Developer Program, não há identidade de assinatura, e o
desenvolvimento acontece só em Windows. Isso não é pendência — é escopo.

O que decorre disso:

- `cockpit-release.yml` não tem job de macOS (saiu no `bf9914b`) e não lê mais
  `secrets.APPLE_SIGN_ID`.
- `app-release.yml` sempre foi só Android. **Nenhum workflow chama `xcodebuild`**
  — `DEVELOPMENT_TEAM = ""` nos três alvos de `app/ios/Runner.xcodeproj` não
  bloqueia nada, porque não existe pipeline pra bloquear.
- `app/ios/ExportOptions.plist` foi **removida**: era `method:
  app-store-connect` com `APPLE_TEAM_ID_NOT_SET`, referenciada por nenhum
  script, e um placeholder assim se lê como TODO em vez de decisão. Se o
  upstream mexer nela, o merge dá conflito modify/delete — resolver mantendo a
  remoção.
- `app/store_listing.md` mantém as seções de iOS como referência herdada, com
  aviso no topo de que não descrevem caminho de publicação.
- `cockpit/distribute_options.yaml` ainda traz o release `macos` (dmg) e a
  variável `APPLE_SIGNING_IDENTITY: "… APPLE_SIGN_ID_NOT_SET"`. Inertes: o
  `cockpit-release.yml` só invoca o Fastforge com `--platform windows` e
  `--platform linux`. Ficam pelo mesmo motivo das pastas — é arquivo que o
  upstream edita.

As pastas `app/ios/` e `cockpit/macos/`, e os ramos `Platform.isIOS` /
`Platform.isMacOS` do código Dart, **ficam**. Arrancá-los renderia conflito em
todo merge do upstream em troca de nenhum ganho funcional — o scaffold do
Flutter é inerte quando ninguém compila pra aquela plataforma.

### Armadilha herdada: o Debug do macOS exige certificado de distribuição

Em `cockpit/macos/Runner.xcodeproj`, a config **Debug** do alvo Runner traz:

```
CODE_SIGN_IDENTITY = "Developer ID Application";
CODE_SIGN_STYLE    = Manual;
DEVELOPMENT_TEAM   = "";
```

enquanto a **Release** está em `Automatic` — o inverso do que se espera. Veio do
`e9a5bff` do upstream ("flavor debug no macOS"), onde faz sentido: o autor tem
o certificado. Aqui significa que `flutter run -d macos` falha na assinatura numa
máquina sem "Developer ID Application" instalado, apesar de `cockpit/CLAUDE.md`
listar esse comando como padrão. `flutter build macos` (Release, `Automatic`)
não é afetado.

Deixado como está de propósito: mexer criaria divergência num arquivo que o
upstream edita, para consertar um build que este fork não faz. Se algum dia
alguém aqui for compilar no macOS, é o primeiro lugar pra olhar.

## Segredos de release

Os cinco segredos que os workflows consomem estão configurados desde
2026-07-25 (antes disso a API devolvia `total_count: 0` e nenhum release podia
rodar):

| Segredo | Workflow | Para quê |
|---|---|---|
| `ANDROID_KEYSTORE` | `app-release` | keystore `.jks` em base64 |
| `ANDROID_KEYSTORE_PASSWORD` | `app-release` | senha do keystore |
| `ANDROID_KEY_ALIAS` | `app-release` | alias da chave (`piper`) |
| `ANDROID_KEY_PASSWORD` | `app-release` | senha da chave |
| `SPARKLE_PRIVATE_KEY` | `cockpit-release` | seed ed25519 (base64) que assina o `.exe` do appcast |

**As duas chaves são identidades permanentes e não têm cópia no GitHub** — um
secret é write-only, não dá pra recuperar o valor depois. Perder o backup
local é perder a chave.

- **Keystore Android**: o Android recusa update assinado por outra chave.
  Perdê-lo trava toda instalação existente num beco sem saída — o usuário
  precisa desinstalar (perdendo dados) e instalar de novo. Fingerprint atual
  (o `app-release` compara contra ele e falha se o Gradle cair pras debug keys):
  `63:D8:82:B7:A0:59:E2:64:D8:9D:72:46:5E:EC:25:BD:0B:40:C3:64:BE:FB:84:C7:0F:70:33:E0:D5:D6:37:71`
- **Seed ed25519**: perder só obriga a rotacionar, mas rotacionar **trava a
  base instalada do Cockpit** — os apps antigos só confiam na pública embutida
  neles. Ver `cockpit/packaging/README.md`.

### Âncora de confiança do self-update

`cockpit/windows/runner/Runner.rc` embarca a chave **pública** ed25519 contra a
qual o WinSparkle verifica o instalador; `macos/Runner/Info.plist` tem a mesma
em `SUPublicEDKey` (inerte, sem release de macOS). Até 2026-07-25 as duas eram
a chave do autor do upstream — uma âncora de confiança de terceiro, e na
prática impossível de usar, já que a privada correspondente nunca foi nossa.
Hoje são do fork.

Rotacionar exige os três passos **juntos**: par novo, `EdDSAPub` do `Runner.rc`
e `SUPublicEDKey` do `Info.plist` trocados, seed nova em `SPARKLE_PRIVATE_KEY`.
Mexer num só quebra a verificação.

Ainda não migrado: `site/` (copy e links de loja do upstream), `branding/`
(o logo continua sendo o do Remote Pi) e os registros históricos (`plan/`,
`CHANGELOG.md`), que descrevem o que foi decidido na época e ficam como estão.

## Rodar num único WLAN (o padrão)

Esta é a divergência funcional mais importante do fork: o padrão do Piper é
relay **na sua própria rede**, não o relay público do upstream. Desenho e
decisões em [`plan/102`](./plan/102-lan-default.md).

App e `pi-extension` são ambos **clientes** WebSocket — nenhum dos dois escuta,
e não há descoberta na rede local (nada de mDNS), então um relay continua
necessário. O que muda é onde ele roda:

```bash
cd relay && cargo run --release
# ou: docker build -t relay . && docker run -p 3000:3000 -v relay-data:/data relay
```

Com o relay de pé, o resto é automático:

- a extensão fala com ele por loopback (`http://127.0.0.1:3000`, o default);
- o QR de pareamento anuncia a forma LAN (`r=http://<ip>:3000`), descoberta via
  `src/lan.ts`;
- o app adota esse endereço ao escanear e o persiste.

Nada de digitar IP no celular, e a cada troca de rede basta parear de novo.
`REMOTE_PI_RELAY` sobrepõe tudo quando a detecção erra a interface.

Para alcançar o Pi **de fora** da WLAN ainda é preciso um relay público —
`kPublicRelayUrl` continua apontando pro do upstream. Alternativa que resolve os
dois casos sem relay público: Tailscale.

**Firewall:** macOS e Windows bloqueiam a porta 3000 de entrada por padrão. Se o
celular não conectar mas o relay estiver de pé, é o primeiro lugar pra olhar.
