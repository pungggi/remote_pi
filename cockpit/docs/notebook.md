# `*.notebook` — Cadernos de notas

Uma pasta cujo nome termina em `.notebook` é um **caderno**: um `.md` por nota,
cada um com um frontmatter YAML raso. O Cockpit mostra a pasta como **item
único** na árvore (logo do Cockpit, sem expandir) e abre como uma tab de notas.
Fora do app é uma pasta comum: git, Obsidian e o agente no terminal veem os
`.md` direto. Plano de referência: `plan/62-cockpit-gallery.md`, passo 4.

## Formato de uma nota

```markdown
---
title: Túnel SSH no host
tags: [relay, agent]
created: 2026-09-07T10:12
updated: 2026-09-07T11:40
---

Corpo livre em markdown.
```

| Campo | Obrigatório | Notas |
|---|---|---|
| `title` | não | Sem ele, o título é o nome do arquivo sem `.md` |
| `tags` | não | Lista `[a, b]`. Sem tags a nota cai no grupo "sem tag" |
| `created` | não | `YYYY-MM-DDTHH:MM` |
| `updated` | não | O app reescreve ao salvar |

O parser **nunca lança**: arquivo sem frontmatter, ou com `---` sem fechamento,
vira uma nota com o conteúdo inteiro como corpo. O app só reescreve as linhas
`title:`, `tags:` e `updated:` — o corpo e qualquer outra chave ficam como
estão.

## Nomes de arquivo

Nota nova = `YYYY-MM-DD-<slug-do-titulo>.md` (`2026-09-07-tunel-ssh-no-host.md`),
com sufixo ` 2`, ` 3`… no título se colidir. **O nome não acompanha o título**
depois de criado — o título é metadado. Qualquer `.md` na pasta é uma nota,
independente do nome.

## Tags reservadas

- `agent` — nota escrita por um agente. A CLI sempre adiciona; a UI marca com
  uma faísca e agrupa logo depois de "sem tag".

## Na UI

- Lista à esquerda agrupada por tag (sem tag → `agent` → alfabético). Uma nota
  com N tags aparece em N grupos. Grupos colapsam.
- O título é sempre um campo (uma linha; Enter grava). Tags ficam no rodapé da
  nota (chips com ✕ + campo "adicionar tag").
- A nota é **sempre editável**, num só modo: o markdown é pintado ao vivo
  enquanto se digita (negrito em negrito, títulos grandes, checklist com
  marcador, código mono). Os marcadores (`**`, `#`, `-`) ficam visíveis,
  esmaecidos — o arquivo continua markdown puro. O frontmatter fica escondido e
  é preservado byte a byte. Barra de formatação: negrito `⌘B`, itálico `⌘I`,
  riscado, H1–H3, listas, checklist, citação, código `⌘E`, bloco, link `⌘K`,
  divisor. **Salva sozinho** (~1,5 s depois de parar de digitar, e ao trocar de
  nota ou fechar a aba); `⌘S` força na hora. Não há modo de leitura separado.
- **Imagens**: colar (`⌘V`) ou arrastar no editor grava em `_assets/` dentro do
  caderno e insere `![](_assets/nome.png)`. A imagem é desenhada **inline no
  editor** (altura limitada) em toda linha fora do cursor; na linha do cursor
  volta a ser a sintaxe, pra editar ou apagar. Apagar nota não apaga assets.
- Botão direito numa nota → **Apagar** (vai pra lixeira).
- A pasta é observada (local): nota escrita por fora aparece sozinha. No
  workspace remoto use o botão de recarregar.

## Links entre notas

`[[Título da nota]]` no corpo vira um chip clicável (abre a nota; se não
existe, cria com esse título). Digitar `[[` mostra sugestões de títulos sob a
barra; clicar completa. O botão de "link pra nota" da barra abre um menu com
busca. No rodapé da nota, **Citada em** lista as notas que apontam pra ela
(backlinks). A comparação de título ignora maiúsculas.

## CLI

```sh
cockpit note add <dir.notebook> --title <t> [--tag <a>]... [--body <texto> | --body -]
cockpit note list <dir.notebook> [--json]
```

`add` cria a pasta se faltar, grava a nota e recarrega a tab aberta; imprime o
caminho. `--body -` lê o corpo do stdin. O wire é `note-add` / `note-list`
(ver `cockpit_cli_handler.dart`).

## Gallery

O card **Caderno** cria `notes.notebook/welcome.md` na raiz do workspace e abre
a tab. Se a pasta já existe, só abre.
