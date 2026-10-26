# 62 — Cockpit: aba Gallery (documentos especiais)

> **Status**: PARCIAL. Passos 1 e 2 implementados (2026-09-07). Mermaid
> cortado. Caderno (passo 4) com **design aprovado**; 4a–4d e CLI feitos. Caderno
> completo; resta só limpeza de assets órfãos (baixa prioridade).

## Contexto

O painel direito do Cockpit tinha quatro abas: Files, Search, Source Control e
Database. Os "documentos especiais" que o app renderiza de forma própria
(`.dbq` editor SQL, `.kanban` quadro, `.ckp` layout de panes, `.http` cliente
HTTP) não tinham porta de entrada: o usuário precisava saber que existiam e
criar o arquivo à mão.

A aba **Gallery** resolve isso: uma vitrine de cards (ícone colorido, título,
descrição) onde um clique cria o documento na **raiz do workspace** e abre a
tab. Texto de introdução da aba, fixado pelo usuário:

> Documentos especiais do Cockpit para que você tenha o visual do que o agente
> de IA esteja fazendo.

Esse é o critério de entrada de um card novo: ele precisa dar ao humano uma
**vista** do trabalho do agente. Diagramas, quadros, listas de tarefas entram;
utilitários genéricos não.

Decisões fechadas:

| # | Decisão |
|---|---|
| **A** | Cria sempre na raiz do workspace ativo. Multi-root = pasta-mãe, não um dos repos. Funciona local e remoto (`fs.list` + `fs.write`) |
| **B** | Nome fixo por tipo com sufixo numérico se já existe (`dev.ckp` → `dev-2.ckp`). Sem diálogo de nome; o usuário renomeia na árvore |
| **C** | Templates moram no enum `GalleryTemplate` (`domain/entities`). Conteúdo do arquivo fica em inglês (é conteúdo de arquivo, não UI). Título/descrição são i18n |
| **D** | Erro de criação = `FileOperationError` tipado, traduzido na borda da UI |

## Estrutura (o que já existe)

```
cockpit/lib/app/cockpit/
├── domain/entities/gallery_template.dart   # enum: baseName, extension, iconAsset, content
├── ui/widgets/gallery_panel.dart           # lista de cards, onCreate(template)
├── ui/widgets/file_tree_panel.dart         # _RightPaneTab.gallery + slot galleryPanel
├── ui/viewmodels/cockpit_viewmodel.dart    # createFromTemplate(template) → Result<String, FileOperationError>
└── ui/cockpit_page.dart                    # fiação + diálogo de erro
cockpit/test/domain/gallery_template_test.dart
cockpit/test/ui/gallery_panel_test.dart
```

## Passos

### 1. Aba Gallery com os quatro documentos existentes — FEITO

`.dbq`, `.kanban`, `.ckp`, `.http`. Ícones do tema material (`database`,
`todo`, `http`) e o logo do Cockpit para `.ckp`.

Aceite: clicar num card cria o arquivo na raiz e abre a tab correspondente;
segundo clique cria `-2`; workspace remoto grava no host; erro vira diálogo
traduzido.

### 2. Cards **Tarefas** e **Visual HTML** — FEITO

Dois cards que só apontam para coisas que **já existem** no app:

- **Tarefas** cria `.cockpit/tasks.json` com o exemplo do painel de Tasks (o
  conteúdo saiu de `tasks_viewmodel.dart` para `GalleryTemplate.tasks.content`
  e o painel consome dali). O enum ganhou `relativeDir` (subpasta criada
  quando falta) e `fixedName` (se o arquivo já existe, **abre** em vez de criar
  `-2`). No remoto, o `NativeFileService.write` do servidor passou a criar a
  pasta-pai — hosts com servidor antigo mostram o erro cru até atualizar.
- **Visual HTML** cria `view.html`. O viewer já renderiza `.html` direto onde
  há webview (macOS/Windows; Linux cai na fonte). É o card que cobre "o agente
  desenha qualquer coisa": mapa mental, diagrama, gráfico.

### 3. Mermaid — CORTADO

Cortado em conversa (2026-09-07). Critério que ficou: render nativo só quando o
documento precisa ser **editado pelo humano e lido de volta pelo agente** como
dado estruturado. Mermaid, mapa mental e Excalidraw são visualização de mão
única — o agente gera um `.html` (card Visual) e o resultado é melhor e sem
motor nosso. Kanban e Caderno passam no critério; Tarefas e Layout são
operacionais.

### 4. Card **Caderno** (`.notebook`) — DESIGN APROVADO, EM ANDAMENTO

Um caderno de notas curtas com tags, no lugar de "um `.md` longo que o usuário
edita cru e depois troca pra preview". Decisões fechadas (2026-09-07):

| # | Decisão |
|---|---|
| **N1** | `nome.notebook/` é uma **pasta**, um `.md` por nota. Diff por nota no git, o agente edita uma sem tocar as outras, e o Obsidian abre a mesma pasta sem conversão |
| **N2** | Frontmatter por nota: `title`, `tags` (lista), `created`, `updated`. Sem tag = grupo "sem tag" na UI |
| **N3** | Imagens **entram**: pasta `_assets/` dentro do `.notebook`, colar imagem grava o arquivo e insere `![](_assets/x.png)` |
| **N4** | Sincronização é o **git**, nada próprio. Sem plugins |
| **N5** | Tag reservada `agent` marca notas criadas pelo agente |
| **N6** | Edição segue a regra do kanban: mutações como emenda de linhas sobre o texto original; markdown que não modelamos fica intacto |
| **N7** | Na árvore a pasta é **item único** com o logo do Cockpit, sem expandir (como o `.app` do Finder). Duplo clique abre a tab |
| **N8** | **Duas colunas**, sem coluna de tags: lista à esquerda **agrupada por tag** (sem tag primeiro, depois `agent`, depois alfabético; nota com N tags aparece em N grupos, estilo Apple Notes) e nota no centro |
| **N9** | Tags editáveis **no rodapé da nota**: chips removíveis + campo "adicionar tag". Título edita **inline** ao clicar (campo sem borda). **Sem datas** na UI |
| **N10** | "Nova nota" cria `Untitled` direto, seleciona e foca o título. O nome do arquivo não acompanha o título (metadado só) |
| **N11** | Edição é **markdown ao vivo** num só modo (sem alternar fonte/preview): formatação pintada sobre o texto, marcadores visíveis esmaecidos. Sem editor rico de terceiros |

Implementado (commits `5ed3d60` → `d1e19fe`): `NotebookNote` (domain),
`NotebookSession`, `NotebookView` (lista agrupada, preview markdown, edição do
fonte com save, tags e título inline), pasta como item único na árvore, card na
Gallery (`notes.notebook/welcome.md`), persistência da tab, local e remoto via
`readTextAt`/`writeTextAt`.

Falta, em ordem:

- ~~**4a — Robustez do protótipo**~~ FEITO: watcher da pasta, apagar nota
  (lixeira), ⌘S, aviso de alteração não salva. Rename do arquivo pelo título
  segue **não** (N10).
- **4b — Imagens** (N3): colar/arrastar imagem grava em `_assets/` e insere o
  markdown; preview resolve o caminho relativo à pasta; "assets órfãos" limpa.
- **4c — Edição rica** (WYSIWYG sem alternar modo). Avaliar pacote de editor
  rico que serialize para markdown; blocos não modelados caem no editor de
  texto. Só depois de 4a estável.
- **4d — Links `[[titulo]]`** entre notas + backlinks. Base do mapa mental
  futuro, se um dia voltar.
- ~~**CLI**~~ FEITO: `cockpit note add|list`, `cockpit open x.notebook`,
  `docs/notebook.md`, seção Notebooks na skill (`cockpit install-skill --force`
  atualiza a cópia local) e no `--help`.

Aceite (wave inteira): card cria o caderno; nota escrita à mão pelo agente (ou
pelo Obsidian) aparece sozinha; colar imagem grava em `_assets/`; edição rica
não alterna modo e preserva blocos não modelados; `[[titulo]]` navega e aparece
em backlinks; funciona em workspace remoto.

## Ordem

O que resta é o **Caderno** (passo 4), em wave única. Depois dele, nada
comprometido — ver ideias futuras.

## Definition of Done

- [x] Aba Gallery com `.dbq`, `.kanban`, `.ckp`, `.http` (passo 1)
- [x] Cards Tarefas (`.cockpit/tasks.json`, reutilizando o exemplo do painel) e Visual HTML (passo 2)
- [x] Caderno completo (passo 4: pasta `.notebook`, tags, busca, imagens, edição rica, links) e card na galeria
- [ ] `flutter analyze` limpo e `flutter test` verde em cada passo
- [ ] i18n en/pt-BR/es para todo card novo

## Ideias futuras (fora deste plano)

Cortados em conversa (2026-09-07), com o porquê para ninguém reabrir sem motivo:

- **Trace de sessão** e **Roadmap**: o kanban cobre planejamento; se faltar
  eixo de tempo, entra como data opcional no card e visão de timeline dentro
  da própria tab `.kanban`.
- **Mermaid, Mapa mental, Excalidraw**: atendidos pelo card Visual HTML (o
  agente gera a página). Só voltam se o humano precisar editar e o agente ler
  de volta.

Sem aceite, registradas para não perder:

1. **Painel de métricas** (`.dash`): cards com `.dbq` embutido + gráfico.
2. **ADR / registro de decisão** (`.adr`): baixa prioridade. Não é o mesmo que
   um diagrama: registra contexto, opções, escolha e consequências.

## Próximos planos

- Caderno (passo 4) vira plano próprio quando o desenho fechar — é grande o
  bastante para não caber como passo aqui.
