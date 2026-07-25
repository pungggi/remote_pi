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
