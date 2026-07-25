# Remote Pi — Orquestrador

Você está na **raiz** do monorepo Remote Pi. Esta pasta é exclusivamente para **planejamento**.

## O que fazer aqui

- Ler e escrever em `plan/NN-<slug>.md` (ex: `plan/03-protocol.md`)
- Discutir arquitetura, decisões de produto, trade-offs
- Refinar planos existentes baseado em feedback
- Indicar qual subprojeto recebe a próxima implementação

## O que NÃO fazer aqui

- Não editar código em `app/`, `pi-extension/`, `relay/`, `site/`, `cockpit/`
- Não rodar comandos de build/test dos subprojetos a partir daqui
- Para implementar algo, abra o Claude **dentro** do subprojeto alvo — cada um
  tem sua própria `CLAUDE.md` e persona. Daqui sai o plano, não o código.

## Estrutura

Veja [README.md](./README.md) para visão geral e [plan/](./plan/) para os planos.

## Decisões já tomadas

Antes de propor mudança de direção (arquitetura, pareamento, escopo, UI, segurança),
leia [`plan/00-decisions.md`](./plan/00-decisions.md). Esse arquivo lista decisões
fechadas em conversa exploratória e **não devem ser revisitadas sem evidência forte**.

Se ainda assim quiser revisitar, abra discussão explícita — não mude silenciosamente.

## Convenções de planos

- Numeração sequencial: `01-bootstrap.md`, `02-ai-orchestration.md`, ...
- **Planos deste fork usam a faixa `100+`** (`100-app-ask-user-ui.md`,
  `101-...`). A faixa baixa pertence ao upstream e continua crescendo lá —
  usar os mesmos números causa colisão de arquivo no merge e ambiguidade nos
  comentários de código (`plano 51` chegou a significar duas coisas)
- Cada plano tem: Contexto, Estrutura esperada, Passos com critério de aceite, DoD, Próximos planos
- Planos descrevem **o que** + **como verificar**, não o código completo
- Pseudocódigo ou comandos exatos são bem-vindos; implementação real fica no subprojeto

## Quando promover um plano a implementação

Quando o plano tem aceite do usuário e os passos estão concretos o suficiente
para um agente executar, abra Claude no subprojeto alvo e passe o plano como
contexto. O agente daquele subprojeto seguirá sua própria persona.

## Scouts disponíveis

Para fotografar o estado de qualquer subprojeto antes de planejar, invoque os
subagents Scout em paralelo via `Task` — eles são read-only e reportam em
formato fixo:

- `scout-app` — Flutter (`app/`)
- `scout-pi-extension` — Node/TS (`pi-extension/`)
- `scout-relay` — Rust (`relay/`)
- `scout-site` — NextJS (`site/`)
- `scout-cockpit` — Flutter Desktop (`cockpit/`)

Dispare múltiplos numa única mensagem para rodar em paralelo. Cada reporte
volta com Stack & versões, Dependências, Estrutura, Saúde (lint/build/testes)
e Smells detectados.

## Este repositório é um fork

Este monorepo é um **fork** de [`jacobaraujo7/remote_pi`](https://github.com/jacobaraujo7/remote_pi)
e segue uma linha de produto própria. Antes de mexer em identidade (bundle IDs,
domínios, branding) ou de trazer mudanças do upstream, leia
[`FORK.md`](./FORK.md) — ele define a direção do merge (sempre upstream →
fork), o que é divergência intencional e como sincronizar.
