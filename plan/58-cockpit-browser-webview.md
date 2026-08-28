# 58 — Cockpit: Navegador embutido + preview de markdown/HTML via webview

## Contexto

Duas dores convergem na mesma solução:

1. **Não há navegador no Cockpit.** Preview de localhost (dev server), docs e
   qualquer URL exigem sair do app. Queremos um pane de navegador de primeira
   classe, aberto manualmente ou disparado por task.
2. **O preview de markdown é limitado.** O `gpt_markdown` (widget Flutter) não
   renderiza HTML embutido em `.md` (tabelas complexas, `<details>`, `<img>`
   com atributos, badges). O caminho maduro é o do VS Code: renderizar
   markdown para HTML de verdade dentro de uma webview.

A mesma infra de webview atende os dois casos. Motor escolhido:
**`flutter_inappwebview` ^6.x** (WKWebView no macOS, WebView2 no Windows,
inline na árvore de widgets). **Linux não tem implementação** nesse pacote e
recebe fallbacks (seção própria abaixo).

### Decisões fechadas nesta conversa (2026-08-09)

| # | Decisão |
|---|---|
| A | Motor = `flutter_inappwebview` ^6.x, macOS + Windows. CEF descartado (peso, assinatura). `webview_flutter` oficial descartado (sem desktop) |
| B | Linux não veta a feature: gate por plataforma + fallbacks (abaixo). Mesma política do self-update (plano 47, Linux fora) |
| C | Preview de `.md`/`.mdx`/HTML usa a receita do VS Code: pipeline `markdown-it` local + sanitização allowlist + CSP + update incremental por diff de DOM + tema via CSS variables |
| D | O chat do agente **continua no `gpt_markdown`**. Webview por bolha de mensagem é inviável (um surface nativo por mensagem, scroll brigando com platform view) |
| E | Navegador vira mais um modo da tab polimórfica (mesmo padrão de `.dbq`/Mongo/Redis: session própria + branch no `_PaneBody`) |

## Estrutura esperada

```
cockpit/
├── pubspec.yaml                       # + flutter_inappwebview (registrar aqui, plano 37 aponta pra cá)
├── assets/md_preview/                 # pipeline de preview (asset local, sem rede)
│   ├── preview.html                   # esqueleto + CSP + CSS variables
│   ├── preview.js                     # markdown-it + plugins GFM + sanitizador + diff de DOM
│   └── preview.css                    # consome só variáveis de tema
└── lib/app/cockpit/
    ├── domain/                        # BrowserCapability (enum: inline | externalWindow | systemBrowser)
    ├── data/browser/                  # resolução da capability por plataforma; scheme handler p/ assets do workspace
    └── ui/
        ├── session/
        │   ├── browser_session.dart           # URL, histórico back/forward, título
        │   └── markdown_preview_session.dart  # arquivo alvo, re-render on change
        └── widgets/
            ├── browser_pane.dart              # toolbar compacta + InAppWebView
            └── markdown_preview_pane.dart     # webview com preview.html + postMessage
```

## Passos

### 1. Infra webview + `BrowserCapability`

- Adicionar `flutter_inappwebview` ao pubspec e registrar a dependência no
  plano 37.
- `BrowserCapability` resolvida uma vez no boot:
  - macOS / Windows → `inline`
  - Linux → `systemBrowser` (url_launcher). Se no futuro valer a pena,
    `externalWindow` via `desktop_webview_window` (WebKitGTK) entra como
    upgrade, sem mudar contrato.
- Toda UI que oferece "abrir navegador" consulta a capability: em `inline`
  abre pane; em `systemBrowser` delega ao browser do SO e **não** mostra
  opções que não existem (sem botão morto).

**Aceite**: `flutter build macos` ok; no macOS uma webview de teste renderiza;
em Linux (ou capability forçada) o caminho degrada pra `url_launcher` sem
crash e sem UI órfã.

### 2. Pane de navegador

- `BrowserSession` + `browser_pane.dart` com toolbar **compacta** (uma linha,
  altura da toolbar dos outros viewers): voltar, avançar, reload, campo de
  URL (Enter navega), só isso. Título da tab segue o `<title>` da página.
- Histórico back/forward vem do próprio webview (`canGoBack`/`goBack`).
- Ação de abertura no pane: junto de "Dividir à direita", "Dividir abaixo"
  e "Fechar" entra **"Abrir navegador"** (abre `BrowserSession` no pane alvo,
  URL inicial em branco ou `about:blank` com campo focado).
- i18n: chaves novas nos três `lib/i18n/*.i18n.json` (regra do CLAUDE.md).

**Aceite**: abrir navegador pelo menu do pane, navegar, voltar/avançar,
editar URL. Toolbar não passa de uma linha. Troca de idioma atualiza labels.

### 3. Preview de `.md`, `.mdx` e HTML no file viewer

- **Pipeline (receita VS Code)**, tudo asset local:
  - `markdown-it` + plugins GFM (tabelas, strikethrough, task lists) gera
    HTML; MDX é tratado como markdown com HTML embutido (sem executar JSX;
    componentes viram tags inertes sanitizadas).
  - Sanitização por allowlist de tags/atributos antes de injetar no DOM.
  - CSP restritiva no `preview.html`: sem script externo, imagem só de
    scheme permitido.
  - **Update incremental**: mudança no arquivo manda o markdown novo via
    `postMessage`; o JS re-renderiza e faz diff de DOM (estilo morphdom).
    Nunca `loadUrl` de novo, pra não piscar nem perder scroll.
  - **Tema**: tokens do `context.colors` injetados como CSS variables;
    troca de tema re-injeta variáveis, sem re-render.
  - **Imagens relativas**: custom scheme handler que só serve arquivos
    dentro do workspace (nada de `file://` cru).
- Arquivos `.html`/`.htm`: mesmo viewer, mas carregando o arquivo direto na
  webview (com a mesma CSP e o mesmo scheme handler pra recursos relativos).
- Toggle no viewer de `.md`/`.mdx`/HTML: **Código | Preview** (default
  preview; editar continua no editor de texto atual).
- Linux: sem webview, o toggle Preview não aparece; `.md` continua no
  renderer atual (`gpt_markdown`) e HTML abre como texto ou no browser do
  sistema.

**Aceite**: um `.md` com `<details>`, tabela HTML e badge renderiza
corretamente; editar o arquivo atualiza o preview sem perder scroll; tema
claro/escuro acompanha o app; imagem relativa do repo aparece; `.html` abre
renderizado; em Linux nada disso quebra o viewer atual.

### 4. CLI: `cockpit browse`

- Novo comando na CLI interna: `cockpit browse <url> [--pane-id <id>]`.
  - Capability `inline`: abre/reusa um `BrowserSession` (no pane do chamador
    por default, mesmo roteamento por `COCKPIT_PANE_ID` do `cockpit db`).
  - Capability `systemBrowser`: abre no browser do SO e responde indicando
    isso.
- Saída JSON de uma linha, em inglês (regra: saída de CLI não se traduz).
- Documentar na skill `cockpit-cli` embutida (`install-skill`).

**Aceite**: de dentro de um pane, `cockpit browse http://localhost:3000`
abre o navegador no workspace certo; JSON de resposta estável.

### 5. Auto-open a partir de tasks (dev server)

- Ao rodar uma task (plano 48) cujo output emite uma URL local (regex de
  `https?://(localhost|127\.0\.0\.1|0\.0\.0\.0):\d+`), o Cockpit abre
  automaticamente um pane de navegador nessa URL (ex.: `npm run dev`,
  `flutter run -d web-server`, `vite`).
- Regras pra não virar praga:
  - Só a **primeira** URL detectada por execução de task; re-runs reusam o
    pane de navegador já aberto naquela URL (naviga/reload, não abre outro).
  - Opt-out por task no `tasks.json`: `"preview": false`. Também aceita
    `"preview": "<url>"` pra forçar URL fixa sem depender de regex.
  - `0.0.0.0` é reescrito pra `localhost` antes de navegar.
- Linux: notificação/log com a URL + abre no browser do SO (respeitando o
  mesmo opt-out).

**Aceite**: `npm run dev` numa task abre o navegador na URL do servidor uma
única vez; segundo run reusa o pane; task com `"preview": false` não abre
nada.

## Fallbacks Linux (resumo)

| Recurso | macOS/Win | Linux |
|---|---|---|
| Pane navegador | inline (webview) | browser do SO via url_launcher; sem item de menu de pane |
| Preview `.md`/`.mdx` | webview (pipeline novo) | renderer atual (`gpt_markdown`), sem toggle |
| `.html` renderizado | webview | abre no browser do SO |
| `cockpit browse` | abre pane | abre browser do SO (JSON indica `"mode":"system"`) |
| Auto-open de task | abre pane | notifica + browser do SO |

## Definition of Done

- [x] `flutter_inappwebview` no pubspec e registrado no plano 37
- [x] `BrowserCapability` com gate por plataforma e zero UI órfã no Linux
- [x] Pane navegador com toolbar compacta (voltar, avançar, reload, URL)
- [x] "Abrir navegador" no menu do pane junto de Dividir/Fechar
- [x] Preview `.md`/`.mdx` via webview: HTML embutido, diff incremental, tema, imagens relativas, CSP
- [x] Viewer de `.html` renderizado
- [x] `cockpit browse` na CLI + skill atualizada
- [x] Auto-open por task com detecção de URL, reuso de pane e opt-out no `tasks.json`
- [x] i18n nos três locales + `dart run slang`
- [x] `flutter analyze` limpo (só infos pré-existentes do xterm vendorizado) + `flutter test` (869 ok) + testes wire da CLI (24 ok)
- [ ] E2E manual no macOS: navegador, preview de `.md` real do repo, `npm run dev` disparando auto-open

> Implementado 2026-08-09 na worktree `navegador` (cockpit/). Persistência da
> aba de navegador entra no descritor `{'type':'browser','url'}`; o preview de
> markdown reusa a FileViewerSession (toggle Código|Preview do FileViewer).

## Próximos planos (fora de escopo aqui)

- Scroll sync editor ↔ preview (mapeamento de linhas estilo VS Code)
- Mermaid no preview
- `externalWindow` no Linux via `desktop_webview_window`
- DevTools / inspeção da página no pane navegador
