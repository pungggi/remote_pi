# Remote Pi — Site (NextJS)

Landing page institucional do Remote Pi. Apresenta projeto, links pro GitHub,
documentação do MVP. **Apenas apresentação — não tem lógica de produto.**

## Stack

- NextJS 16 (App Router)
- React 19
- TypeScript 5
- Tailwind 4 (via `@tailwindcss/postcss`)
- ESLint 9
- Package manager: **pnpm** (com `allowBuilds` para `sharp` e `unrs-resolver` em `pnpm-workspace.yaml`)

## Comandos

- `pnpm install` — instala deps
- `pnpm dev` — dev server em :3000
- `pnpm build` — build de produção
- `pnpm start` — serve build
- `pnpm lint` — ESLint

## Convenções

- **Server Components por padrão** — só usar `"use client"` quando necessário (state, events, hooks)
- **Pasta de rotas**: `src/app/` (App Router)
- **Estilos**: Tailwind utility-first. Sem CSS modules / styled-components
- **Imagens**: `next/image` com fallback estático onde possível
- **Tipagem**: props de componentes sempre tipadas, sem `any`

## NÃO fazer

- Não adicionar features de produto (chat, pareamento, etc) — isso vai no `app/`
- Não comitar `.next/`, `out/`, `node_modules/` (já no .gitignore raiz)
- Não desabilitar lint pra fazer passar — corrigir o erro
- Não introduzir backend (API routes) sem registrar plano

## Publicação (deploy)

O site **não está em produção** neste fork — sem domínio nem registry próprios
ainda. Código-fonte: <https://github.com/pungggi/remote_pi>. O fluxo de imagem
Docker abaixo é herdado do upstream (imagem `jacobmoura7/remote-pi-site`); adaptar
antes de qualquer publicação real.

```bash
./push-docker.sh            # build multi-plataforma + push, tag :latest
./push-docker.sh v1.2.3     # tag :v1.2.3 E :latest
```

O que o script faz: cria (idempotente) um builder buildx `multiarch`
(`docker-container`), builda para `linux/amd64,linux/arm64` a partir do
`Dockerfile` (multi-stage → `next build` com `output: "standalone"`, runtime
`node:22-alpine` na porta 3000 com healthcheck em `/`) e dá `--push` pro Docker
Hub.

Pré-requisitos: **`docker login`** (Docker Hub) feito antes, e `docker buildx`
(vem no Docker moderno). Sem login, o push falha no fim do build.

Fluxo típico de publicação: commit + push no git → `pnpm lint && pnpm build`
verdes → `./push-docker.sh` → o host redeploya da `:latest`. Passe uma versão
(`vX.Y.Z`) quando quiser uma tag fixada além da `:latest`.

## Modo orquestrado

Se receber um prompt começando com `[ORCH:<task-id>]`, leia
`../.orchestration/INSTRUCTIONS.md` antes de qualquer outra ação. Esse marker
indica que outro agente está coordenando o trabalho e tem regras específicas
(onde escrever resultado, não comitar, etc).
