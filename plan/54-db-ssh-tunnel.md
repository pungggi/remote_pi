# 54 — DB connection over SSH tunnel

## Contexto

Conexões de banco em servidor privado normalmente não são acessíveis direto: o
Postgres/MySQL escuta em `localhost` do host remoto (ou atrás de um bastion) e o
acesso passa por SSH. Hoje a DB tab do Cockpit (planos 51/52/53) só fala TCP
direto, então esses bancos simplesmente não entram no `.cockpit/databases.json`.

Este plano adiciona **túnel SSH opcional por conexão** — a conexão continua
descrita pela URL do banco, e o túnel é um bloco à parte que, quando presente,
reescreve o destino para um listener local antes de qualquer driver ser tocado.

Decidido em conversa 2026-07-27:

| # | Decisão |
|---|---|
| **A** | **Costura no chokepoint**: o túnel é aplicado no fim de `DbQueryService._resolve`, reescrevendo host/port da `DbConnection` para `127.0.0.1:<porta local>`. Drivers (`AnakiDbDriver`, `NoSqlRunnerImpl`), views, sessões e CLI **não mudam** — os 6 caminhos públicos do serviço já passam por lá |
| **B** | **Túnel mora no isolate principal.** Os drivers rodam dentro de `Isolate.run` e sockets não são sendable; o isolate só enxerga `127.0.0.1:<porta>`. Isso também é o que permite o túnel sobreviver ao modelo efêmero (`open→query→close`) dos drivers |
| **C** | **Transporte = `dartssh2`** (Dart puro), não o binário `ssh -L`. Paridade macOS/Windows/Linux é requisito, e o binário só *provavelmente* funciona no Windows: é Feature on Demand (removível), valida **ACL** da chave privada (não `chmod`) e o `ssh-agent` é serviço desligado por padrão. Custo assumido: **não** herdamos `~/.ssh/config`, `ProxyJump`, `known_hosts` nem o agent |
| **D** | **Só autenticação por chave** na v1 (User + Key path). Password auth fica de fora — bastion sério costuma ter `PasswordAuthentication no`, e cortar isso remove um segmented control inteiro do dialog. `dartssh2` suporta password se um dia precisar |
| **E** | **Passphrase**: detecta PEM encriptado ao escolher o arquivo — campo só aparece se necessário. Chave limpa = conexão sem segredo nenhum. Encriptada: "Save passphrase" opt-in → `DbSecrets` (mesmo cofre do SO já usado pelas senhas de banco). Sem salvar: prompt 1× por sessão na GUI, **erro honesto na CLI** (agente não tem como perguntar) |
| **F** | **`ssh-agent` fora de escopo**: `dartssh2` não fala o protocolo, e implementar exigiria socket Unix (POSIX) + named pipe (Windows, sem suporte no `dart:io`) — quebraria justamente a paridade que motivou a decisão C. Salvar a passphrase no cofre é o substituto equivalente (é o mesmo Keychain que o `ssh-add --apple-use-keychain` usa) |
| **G** | **Host key por TOFU**: primeira conexão mostra o fingerprint e pede confirmação; guardado em store nosso. Mudança posterior = recusa com aviso alto. Aceitar cego seria MITM silencioso num túnel cuja razão de existir é segurança |
| **H** | **Segredo nunca no `databases.json`.** O *path* da chave vai (é referência, versionável num repo de time); passphrase vai pro cofre; conteúdo da chave nunca é copiado pra dentro do Cockpit |
| **J** | **Mongo vai por SOCKS5, os demais por port-forward** (2026-07-27, depois do primeiro uso real). Não é preferência: o driver do Mongo descobre os membros do replica set pelo `hello` e passa a discar os **hostnames que o servidor anuncia** — uma porta local fixa só alcança o primeiro nó, e `mongodb+srv://` nem isso. Com SOCKS quem escolhe o destino é o driver e o túnel só roteia. É o mesmo desenho do MongoDB Compass (`@mongodb-js/ssh-tunnel` é um servidor SOCKS5 sobre `ssh2`, não um `-L`). Usa `SSHClient.forwardDynamic()` do próprio dartssh2 (equivalente a `ssh -D`; NO AUTH + CONNECT, loopback-only) |
| **K** | **Depende do driver com SOCKS5 habilitado.** A spec dos drivers MongoDB define `proxyHost`/`proxyPort`; no crate Rust `mongodb` isso existe desde a 3.5.0 atrás da feature opcional `socks5-proxy`. **Resolvido em 2026-07-27**: `anaki_mongodb` 0.1.5 publicado com a feature ligada, cross-build `cargo-zigbuild` verde nas 5 plataformas (`fast-socks5` é Rust puro, sem C). Validado pelo Anaki: conexão direta segue funcionando e, contra proxy morto, o erro agora é `error occurred when connecting to a proxy host: Connection refused` — ou seja, a opção é consumida de verdade, não mais recusada pelo parser |
| **I** | **SQLite não tem túnel** — é path local. Seção some do dialog nesse engine. SQLite remoto (sshfs) é não-objetivo |

## Estrutura esperada (cockpit/)

- `domain/entities/ssh_tunnel_config.dart` — value object (`host`, `port`,
  `user`, `keyPath`, `savePassphrase`) + `toJson`/`fromJson`
- `domain/contracts/ssh_tunnel.dart` — `SshTunnel` (`ensure`/`closeAll`) e
  `SshHostKeyStore` (TOFU)
- `data/db/ssh_tunnel_impl.dart` — `dartssh2` + `ServerSocket` local, cache por
  config, TTL ocioso
- `data/db/ssh_host_key_store_impl.dart` — fingerprints conhecidos (Hive)
- `domain/entities/db_connection.dart` — campo `ssh`, round-trip no JSON,
  `copyWith`, badge no `displayTarget`
- `domain/services/db_query_service.dart` — aplicação do túnel no `_resolve`
- `ui/widgets/db_connection_dialog.dart` — seção inline "SSH Tunnel"
- `ui/widgets/ssh_host_key_dialog.dart` — confirmação de fingerprint (TOFU)
- `cockpit_module.dart` — binds novos
- Docs: `.cockpit/databases.json` na skill `cockpit-cli` + cópia embutida do
  `install-skill`

## Passos

1. **Entidade + persistência**. `SshTunnelConfig` e o campo `ssh` na
   `DbConnection`, serializado como objeto irmão de `url`. `fromJson` sem o
   bloco → `null` (retrocompatível com todo `databases.json` existente).
   Aceite: teste de round-trip `toJson`/`fromJson`, incluindo JSON legado sem
   `ssh`; `displayTarget` de conexão tunelada mostra o alvo real (não o
   `127.0.0.1`).

2. **Contrato + host key store**. `SshTunnel.ensure(config, {passphrase})
   → TunnelEndpoint(host, port)` e `SshHostKeyStore` (`known(host)` /
   `trust(host, fingerprint)`), com impl Hive. Aceite: unit test do store
   (desconhecido → null; confiado → devolve; fingerprint diferente é detectável
   pelo chamador).

3. **`SshTunnelImpl`**. Conecta via `dartssh2` com `SSHKeyPair.fromPem(pem,
   passphrase)`, valida host key contra o store no `onVerifyHostKey`, abre
   `ServerSocket.bind(loopbackIPv4, 0)` e faz bridge de cada conexão aceita para
   `client.forwardLocal(dbHost, dbPort)`. **Cache por config**: um túnel serve N
   queries (handshake por query custaria ~1s cada); TTL ocioso derruba. `closeAll`
   no dispose / troca de workspace.
   Aceite: teste de integração contra um servidor SSH local (ou skip marcado)
   provando que uma conexão TCP no porto local chega ao destino; segundo `ensure`
   com a mesma config **não** reabre.

4. **Detecção de PEM encriptado**. Helper que lê o arquivo e responde se exige
   passphrase (`ENCRYPTED` no PEM clássico; `openssh-key-v1` com cipher ≠ `none`).
   Aceite: unit test com fixtures de chave limpa e encriptada.

5. **Costura no `DbQueryService`**. No fim do `_resolve`: se `conn.ssh != null`,
   resolve passphrase (cofre → cache em memória → callback de prompt, nesta
   ordem), `ensure`, e devolve `conn.copyWith(url:)` com host/port reescritos.
   O prompt é um callback injetado — **ausente no caminho CLI**, que falha com
   `DbQueryException('ssh_credential_required', …)` em vez de pendurar.
   Aceite: teste com `SshTunnel` fake provando que os 6 caminhos públicos
   (`query`, `schema`, `runStatements`, `redisCommand`, `redisBatch`,
   `mongoCommand`) recebem a URL reescrita; e que sem prompt e sem cofre o erro
   é o kind acima, não timeout.

6. **UI do dialog**. Botão "SSH Tunnel" abaixo dos campos do banco (escondido no
   SQLite) → **seção inline expansível**, não sub-dialog: o usuário precisa ver
   host/porta do banco enquanto configura, porque com túnel o campo Host passa a
   significar "localhost *do servidor SSH*" — é a confusão nº 1 do recurso.
   Campos: Host · Port (22) · User · Key path (picker; default
   `~/.ssh/id_ed25519`, senão `id_rsa`, se existirem) · Passphrase + "Save
   passphrase" **só quando o passo 4 detecta chave encriptada**. Configurado, o
   botão vira chip `SSH · user@host` com "×" pra limpar. Linha discreta:
   *"Agents can only use this connection if the passphrase is saved."*
   Aceite: criar/editar/limpar túnel com round-trip fiel no `databases.json`;
   chave limpa não mostra campo de passphrase.

7. **TOFU dialog**. Fingerprint desconhecido → dialog com host + fingerprint
   (SHA256, formato do OpenSSH) e Trust/Cancel. Mudança de fingerprint conhecido
   → recusa com aviso explícito de possível MITM, sem opção de aceitar inline.
   Aceite: primeira conexão pede; segunda não; fingerprint trocado recusa.

8. **Docs**. Bloco `ssh` documentado no snippet de `.cockpit/databases.json` da
   skill `cockpit-cli` (arquivo em `~/.claude/skills/` **e** a cópia embutida no
   `cockpit_cli.dart`), incluindo a regra de que agente exige passphrase salva.

## Não-objetivos

- Password auth SSH (decisão D) — reabrir só sob demanda real
- `ssh-agent`, `~/.ssh/config`, `ProxyJump`, `known_hosts` do sistema (C/F)
- SQLite sobre SSH / sshfs (I)
- Túnel reverso, multi-hop
- Autenticação no SOCKS (loopback-only + cliente no mesmo processo)

## DoD

- [x] `DbConnection` carrega bloco `ssh` com round-trip fiel; JSON legado intacto
- [x] `SshTunnelImpl` abre/cacheia/derruba túnel; segundo `ensure` reusa
- [x] Chave sem passphrase conecta sem tocar no cofre (GUI e CLI)
- [x] Chave com passphrase salva no cofre conecta na GUI e na CLI
- [x] Chave com passphrase não salva: prompt 1× por sessão na GUI; erro
      `ssh_credential_required` na CLI (nunca pendura)
- [x] Host key nova pede confirmação; alterada é recusada
- [x] Os 6 caminhos do `DbQueryService` funcionam tunelados (SQL + Redis + Mongo)
- [x] Dialog: criar/editar/limpar túnel; seção ausente no SQLite
- [x] Skill `cockpit-cli` documenta o bloco `ssh`
- [x] `flutter analyze` zero issues; `flutter test` verde
- [ ] E2E manual: Postgres atrás de bastion, nos três SOs (macOS obrigatório;
      Windows/Linux best-effort na primeira rodada)
- [x] **anakiORM: feature `socks5-proxy` habilitada** — `anaki_mongodb` 0.1.5
      no pub.dev (2026-07-27), cross-build verde nas 5 plataformas
- [x] Cockpit bumpado pra `anaki_mongodb` 0.1.5; teste de regressão
      (`mongo_socks_support_test`) prova, na **nossa** dylib, que `proxyHost` é
      consumido ("connecting to a proxy host") e não recusado pelo parser
- [ ] E2E manual: Atlas (`mongodb+srv`) atrás de bastion

Implementado 2026-07-27 (cockpit/). Notas de implementação:

- **Chokepoint confirmado**: a costura são ~3 linhas em `_resolve` +
  `_tunneled()`. Nenhum driver, view, sessão ou handler de CLI foi tocado.
- **`SshKeyInspector`**: contrato extra não previsto no plano. Surgiu porque
  `domain/` não pode importar `data/` — a pergunta "essa chave pede
  passphrase?" precisava atravessar a fronteira, e o dialog (ui/) também
  precisa dela sem falar com `data/`. Impl `SshKeyPemInspector`, injetada no
  serviço e exposta à UI pela `DatabaseViewModel`.
- **`withEndpoint` não carrega o túnel adiante** (`ssh: null` na cópia): a
  conexão redirecionada já está *dentro* dele; propagá-lo convidaria a tunelar
  o túnel.
- **`_opening`**: duas queries disparadas juntas na mesma conexão compartilham
  um handshake (dedup de abertura em voo), em vez de abrir dois túneis.
- **`mongodb+srv` recusado** com erro explícito — a seed list resolveria os
  hosts reais e o driver sairia pela rede ignorando o túnel. Melhor recusar do
  que "funcionar" vazando por fora.
- **Host key esquecida ao apagar a conexão** — fingerprint de bastion órfão é
  lixo com aparência de decisão de segurança.
- **Botão Test corrigido junto** (achado no primeiro uso real): ele chamava o
  driver direto, furando o túnel — validava um host que a query real nunca
  usaria. Virou `DbQueryService.ping()`, que tuneliza igual à execução real e
  passou a **testar Redis/Mongo também** (antes o registry SQL devolvia null e
  a mensagem era o enganoso "arrives with the anakiORM integration"). A
  passphrase digitada no dialog tem precedência sobre a do cofre, senão testar
  uma chave nova validaria a antiga.
- **Testes**: 27 novos (`ssh_tunnel_config_test`, `db_query_service_ssh_test`)
  provando round-trip, os 6 caminhos tunelados, a matriz de passphrase e a
  tradução de erro. Suíte total 584 verde, `flutter analyze` sem novos issues,
  `flutter build macos` ok.

## Riscos

- **`dartssh2` sem `~/.ssh/config`**: se aparecer necessidade de `ProxyJump` ou
  aliases, a conta vira a favor do binário `ssh`. A interface `SshTunnel` é o
  ponto único de troca — migrar não toca `DbQueryService`, dialog nem drivers.
- **Porta local em corrida**: `bind(port: 0)` guarda o listener (não fecha e
  reabre), então não há janela pra outro processo tomar a porta.
- **Túnel cai no meio do uso**: `ensure` valida o cliente vivo antes de devolver
  o endpoint cacheado; morto → reabre.

## Próximos planos

- Password auth + `~/.ssh/config`, se a demanda aparecer
- Reuso do `SshTunnel` fora do DB (ex.: LSP remoto) — nada planejado
