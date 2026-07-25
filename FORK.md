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

`main` é espelho do upstream mais os commits de divergência (identidade,
branding, docs deste fork). Nada de feature vai direto pra `main` sem passar
por um branch de trabalho.

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

Assinatura Apple não vem configurada — `DEVELOPMENT_TEAM` está vazio nos três
projetos Xcode, `ExportOptions.plist` traz `APPLE_TEAM_ID_NOT_SET` e o
`cockpit-release.yml` lê `secrets.APPLE_SIGN_ID`.

Ainda não migrado: `site/` (copy e links de loja do upstream), `branding/`
(o logo continua sendo o do Remote Pi) e os registros históricos (`plan/`,
`CHANGELOG.md`), que descrevem o que foi decidido na época e ficam como estão.

## Rodar num único WLAN (sem relay público)

App e `pi-extension` são ambos **clientes** WebSocket — nenhum dos dois escuta,
e não há descoberta na rede local (nada de mDNS). Um relay é sempre necessário,
mas ele pode rodar dentro da sua rede:

```bash
cd relay && cargo run --release          # ou: docker build -t relay . && docker run -p 3000:3000 -v relay-data:/data relay
```

Aponte os dois lados pro IP da máquina na LAN:

```bash
# pi-extension
REMOTE_PI_RELAY=http://192.168.1.10:3000 pi      # ou: /remote-pi set-relay http://192.168.1.10:3000
```

No app, o mesmo endereço em Onboarding/Settings. `http://` é aceito de
propósito para relays locais e convertido pra `ws://` no transporte.

**Pendência conhecida no Android:** `minSdk = 34` e o manifest não declara
`networkSecurityConfig` nem `usesCleartextTraffic`, então tráfego em claro é
bloqueado e `ws://<ip-local>` falha. O iOS já está preparado
(`NSAllowsLocalNetworking` + `NSLocalNetworkUsageDescription` no `Info.plist`).
Alternativa sem texto em claro: TLS local (Caddy com CA interna) ou Tailscale.
