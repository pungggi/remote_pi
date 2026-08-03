# Handoff → anakiORM: SRV quebra quando o driver é usado de um `Isolate.run`

> **Correção do handoff anterior (2026-07-27).** A primeira versão deste
> documento acusava `replicaSet` + `proxyHost` de estarem quebrados no driver
> Rust. **Estava errado, e o erro foi meu**: no caso F eu usei o `replicaSet` do
> cluster **QA** (`atlas-rc7ys8-shard-0`, tirado do TXT de `cluster1.zqq0pbr`)
> contra o cluster **PRD** (`cluster0.vgx4fp`, cujo set é
> `atlas-nesa32-shard-0`). Nome de set trocado → o SDAM remove os nós por spec →
> topologia sem servidores. O diagnóstico do Anaki estava certo em cada ponto.
> Refeito com o nome correto, o caso F passa em 2s.

**Resumo em uma linha:** a resolução `mongodb+srv://` falha quando o driver é
chamado de dentro de um `Isolate.run` do Dart, e passa a degradar o processo
inteiro depois disso. URL direta (`mongodb://`) funciona no isolate sem
problema, então não é o isolate em si — é o caminho de DNS/SRV.

Isto **não tem relação com proxy nem com `replicaSet`**: os dois estão
inocentados abaixo com controle no mesmo processo.

## Ambiente

- `anaki_mongodb` **0.1.5** (crate `mongodb` 3.8.0, feature `socks5-proxy`)
- macOS arm64, `flutter test`; Atlas real (replica set de 3 nós, TLS)
- Proxy SOCKS5: `ssh -D 127.0.0.1:1080` (OpenSSH). O mesmo comportamento
  aparecia com o `forwardDynamic` do dartssh2.

## Evidência 1 — sem `Isolate.run`, tudo passa (6/6)

Chamadas diretas em `AnakiMongoDb`/`MongoDriver.uri` no isolate principal, duas
rodadas, todas com proxy:

| Caso | Tempo |
|---|---|
| 1 seed + `replicaSet` correto | OK 2s / 1s |
| 3 seeds + `replicaSet` correto | OK 1s / 1s |
| **SRV** | **OK 1s / 1s** |

Ou seja: proxy ok, `replicaSet` ok, multi-seed ok, **SRV ok**.

## Evidência 2 — pelo runner de produção (todo call em `Isolate.run`), SRV falha 3/3

`NoSqlRunnerImpl.mongo` (Cockpit) envolve cada chamada em `Isolate.run`, porque
a FFI do anaki é bloqueante e não pode rodar na thread de UI:

```
[1] ERRO 30s : timeout
[2] ERRO 30s : timeout
[3] ERRO 30s : timeout
```

Mesma URL SRV que passa em 1s pelo caminho direto.

## Evidência 3 — matriz cruzada no mesmo processo (o discriminador)

| | main isolate | `Isolate.run` |
|---|---|---|
| **URL direta** (`mongodb://`) | OK 2s | **OK 2s** |
| **SRV** (`mongodb+srv://`) | OK **60s** | **timeout** |

Dois fatos importantes desta tabela:

1. **URL direta funciona dentro do isolate.** Logo o problema não é "usar a
   dylib de um isolate" em geral — é especificamente o caminho SRV.
2. **SRV no main isolate levou 60s aqui, mas 1s na Evidência 1.** A diferença é
   que nesta matriz um `Isolate.run` rodou antes. Sugere **estado global na
   dylib** que, depois de tocado por outra thread/isolate, deixa a resolução
   DNS degradada para todo o processo.

## Hipótese

O caminho SRV usa o `dns-resolver` (hickory) e precisa de um runtime async vivo
para as consultas SRV/TXT. A suspeita é que o runtime/resolver seja criado uma
vez, global por dylib, e fique amarrado à thread que o criou — quando a chamada
vem de outra thread (isolate Dart novo a cada `Isolate.run`), as futures de DNS
não são drivadas, enquanto o caminho de conexão TCP puro segue funcionando.

Casa com a nota que já existe no anaki sobre o **slot de conexão ser global por
dylib**; aqui o sintoma aparece no DNS.

## Como reproduzir (mínimo)

```dart
// passa em ~1s
await ping('mongodb+srv://user:pass@cluster.xxxxx.mongodb.net/?authSource=admin');

// mesma URL, mesmo processo: pendura
await Isolate.run(() => ping('mongodb+srv://user:pass@cluster.xxxxx.mongodb.net/?authSource=admin'));

// controle: URL direta no isolate passa em ~2s
await Isolate.run(() => ping('mongodb://user:pass@shard-00-00.xxxxx.mongodb.net:27017/?tls=true&authSource=admin'));
```

Não precisa de proxy para reproduzir — o proxy estava presente aqui só porque o
Atlas do cliente só é alcançável pelo bastion.

## O que isso significa pro Cockpit

O plano 54 (DB over SSH tunnel) está funcional e provado com dado real: SSH +
SOCKS de pé, TLS até o shard, query respondendo `ok:1` em 1–2s pelo túnel. O que
não funciona hoje é **URL de Atlas (`mongodb+srv://`) pelo runner**, porque o
runner obrigatoriamente usa `Isolate.run`.

**Workaround em uso:** trocar a URL SRV por um seed direto —

```
mongodb://<user>:<pass>@<cluster>-shard-00-00.<id>.mongodb.net:27017/?tls=true&authSource=admin
```

O driver descobre os outros nós sozinho (testado, 2s), então não se perde
failover. A ressalva é que o hostname do shard pode mudar se a Atlas remanejar o
cluster.

> Credenciais reais não estão neste arquivo de propósito — elas vivem no
> `.cockpit/databases.json` do workspace.
