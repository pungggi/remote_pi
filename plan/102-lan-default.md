# 102 — LAN como padrão (relay na própria rede)

## Contexto

O Remote Pi original assume um relay público na internet
(`relay-rp1.jacobmoura.work`). Para o Piper o cenário padrão é outro: celular e
Pi na **mesma rede WLAN**, com o relay rodando na máquina do desenvolvedor.
Nada de tráfego nem de metadado de pareamento sai da rede local.

### O relay continua sendo necessário

App e `pi-extension` são ambos **clientes** WebSocket — nenhum dos dois escuta
em porta, e não há descoberta na rede local (sem mDNS). Falta a peça onde os
dois se encontram, e essa peça é o relay. Não existe modo P2P direto.

O que muda não é a arquitetura, é **onde** o relay roda: `relay/` é um binário
Rust autossuficiente (axum + SQLite embutido, sem dependência externa), faz
bind em `0.0.0.0:3000` e tem Dockerfile pronto. Rodar dentro da LAN é trivial.

### O que já existia

- Os dois lados aceitam `http://` de propósito para relay local — a mensagem de
  validação em `relay_config.dart` diz literalmente *"or http:// for local
  relays"*, e o transporte converte para `ws://` na hora de abrir o socket.
- O iOS já declara `NSAllowsLocalNetworking` + `NSLocalNetworkUsageDescription`.
- O app **ainda parseia** `r=<url>` do QR (`qr_scanner.dart`) e guarda em
  `QrPairPayload.relayUrl`. O plano 14 removeu só a *emissão* do lado da
  extensão; a plumbing do lado do app sobreviveu.

### O que faltava

1. **Android bloqueava.** `minSdk = 34` e nenhum `networkSecurityConfig` no
   manifest — cleartext é barrado desde a API 28, então `ws://<ip-local>`
   falhava silenciosamente.
2. **O celular não tinha como saber o IP.** O endereço da LAN vem do DHCP e
   muda de rede para rede; não dá para compilar no app nem pedir para o usuário
   digitar a cada troca de Wi-Fi.
3. **O default apontava para o relay público**, não para um local.

## Desenho

```
  Pi (pi-extension) ──loopback──► relay (mesma máquina) ◄──WLAN── App
         │                                                        ▲
         └── QR: r=http://<ip-lan>:3000 ──────────────────────────┘
                        (o app adota e persiste)
```

A extensão fala com o relay por **loopback** (rota mais robusta para um
processo no mesmo host: sobrevive a troca de IP, roaming e ausência de LAN). O
QR anuncia a forma **LAN** do mesmo relay, que é a única que o celular alcança.

## Passos

### 1. Android: permitir cleartext

`app/android/app/src/main/res/xml/network_security_config.xml` +
`android:networkSecurityConfig` no `<application>`.

`cleartextTrafficPermitted` fica no `base-config`, não num `<domain-config>`
estreito, porque a network security config só casa **hostname ou IP literal** —
não existe forma CIDR ou wildcard, então "qualquer endereço em 192.168.0.0/16"
não é expressável, e o IP do relay é o que o DHCP deu.

O que limita a exposição: o app só abre conexão para o relay configurado, e
`isValidRelayUrl` faz de `http://` uma escolha explícita (digitada ou adotada de
um QR). O update checker usa `https://` e continua em TLS.

- **Aceite:** APK debug conecta em `ws://<ip-lan>:3000` num device Android 14+.

### 2. `pi-extension`: descobrir o endereço da LAN

Novo `src/lan.ts`: `detectLanIPv4()`, `isPrivateIPv4()`, `isLoopbackUrl()`,
`toPhoneReachableUrl()`.

A escolha da interface é estreitada, não adivinhada: pula `internal`, exige
IPv4 RFC 1918, exclui link-local (169.254/16 aparece quando o DHCP falhou) e
**prefere 192.168/16** — WLAN doméstica/escritório é o alvo, enquanto 10/8 e
172.16/12 são tipicamente Docker, VPN e overlays corporativos. `REMOTE_PI_RELAY`
continua sobrepondo tudo quando a escolha não serve.

- **Aceite:** `pnpm test src/lan.test.ts` verde, incluindo Docker+VPN+Wi-Fi
  simultâneos e a máquina sem LAN nenhuma.

### 3. `pi-extension`: default vira relay local

`kDefaultRelayUrl` = `http://127.0.0.1:3000`. O relay público continua exportado
como `kPublicRelayUrl`, opt-in explícito para acesso de fora da WLAN. A ordem de
precedência (`env` > `config` > `default`) não muda.

- **Aceite:** `/remote-pi status` sem configuração mostra `http://127.0.0.1:3000`.

### 4. `pi-extension`: `r` volta para o QR

`buildQRUri(..., relayUrl?)` grava `r` quando recebe um valor;
`_cmdPair` passa `toPhoneReachableUrl(resolveRelayUrl().url)`.

`null` (sem endereço de LAN — Wi-Fi caído, só interfaces virtuais) emite o QR
**sem** `r`: um endereço inalcançável no QR é pior que nenhum, porque o app
adotaria e perderia a configuração que tinha.

- **Aceite:** QR gerado numa máquina com LAN traz `r=http://<ip>:3000`; numa
  sem LAN, não traz `r`.

### 5. App: adotar o relay do QR

`PairingViewModel._adoptRelayFromQr` persiste `qr.relayUrl` **antes** de montar
o transporte (a factory lê `resolveRelayUrl(prefs)`).

Adotar não é só conveniência, é o comportamento correto: o Pi que gerou aquele
QR está esperando **naquele** relay, então parear em qualquer outro falha. É
no-op quando o QR não traz `r`, quando o valor não passa em `isValidRelayUrl`
(um QR malformado não pode brickar o pareamento) ou quando já é igual ao atual.

O guard `relay_mismatch` de `pair_request_flow.dart` fica atrás como rede de
segurança para os casos que a adoção pula.

- **Aceite:** `flutter test test/ui/pairing/pairing_viewmodel_test.dart` verde
  nos três casos novos (adota / não reescreve igual / ignora inválido).

## DoD

- [x] `network_security_config.xml` + referência no manifest (passo 1)
- [x] `src/lan.ts` + 16 testes (passo 2)
- [x] `kDefaultRelayUrl` local, `kPublicRelayUrl` como opt-in (passo 3)
- [x] `r` de volta no QR, omitido quando não há LAN (passo 4)
- [x] Adoção no `PairingViewModel` + 3 testes (passo 5)
- [x] `pnpm typecheck` + `pnpm test` verdes (38 arquivos, 803 testes)
- [ ] `flutter analyze` + `flutter test` — **não rodados**, sem toolchain
      Flutter no ambiente onde isto foi escrito
- [ ] Verificação em device: Android 14+ e iOS, pareando contra relay na LAN
- [ ] Firewall do host liberando a porta 3000 (macOS e Windows bloqueiam por
      padrão) — documentar no README da extensão

## Fora de escopo / próximos

- **Copy do onboarding.** O passo de relay ainda oferece "community relay vs
  custom". Com o default LAN o texto certo é "o relay vem do QR ao parear", com
  o campo manual como avançado. Funcionalmente já funciona (o campo pode ficar
  vazio e a adoção corrige depois do scan), então é ajuste de texto.
- **Subir o relay junto com a extensão.** Hoje `cargo run` / `docker run` é
  manual. Já existe infra de daemon (`supervisord`) que poderia gerenciá-lo.
- **TLS na LAN.** Alternativa ao cleartext: Caddy com CA interna, ou Tailscale
  — que ainda resolve o acesso de fora da WLAN sem relay público.
