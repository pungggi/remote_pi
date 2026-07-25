# Piper — Orchestrator

You are at the **root** of the Piper monorepo. This folder is the planning
and orchestration hub for the whole repo.

## What to do here

- Read and write `plan/NN-<slug>.md` (e.g. `plan/03-protocol.md`)
- Discuss architecture, product decisions, trade-offs
- Refine existing plans based on feedback
- Point out which subproject receives the next implementation

## Structure

See [README.md](./README.md) for the overview and [plan/](./plan/) for the plans.

## Decisions already made

Before proposing a change of direction (architecture, pairing, scope, UI,
security), read [`plan/00-decisions.md`](./plan/00-decisions.md). That file lists
decisions closed in exploratory conversation; they **must not be revisited
without strong evidence**.

If you still want to revisit one, open an explicit discussion — do not change it
silently.

## Plan conventions

- Sequential numbering: `01-bootstrap.md`, `02-ai-orchestration.md`, ...
- **Plans in this fork use the `100+` range** (`100-app-ask-user-ui.md`,
  `101-...`). The low range belongs to upstream and keeps growing there — reusing
  the same numbers causes file collisions on merge and ambiguity in code comments
  (`plan 51` ended up meaning two different things)
- Every plan has: Context, Expected structure, Steps with acceptance criteria,
  DoD, Next plans
- Plans describe **what** + **how to verify**, not the complete code
- Pseudocode or exact commands are welcome; the real implementation lives in the
  subproject

## Promoting a plan to implementation

Once a plan has the user's acceptance and the steps are concrete enough for an
agent to execute, the work moves to the target subproject. Each subproject has
its own `CLAUDE.md` and persona — read it before touching that subproject's code,
whether you open a separate Claude session there or implement from here.

## Available scouts

To snapshot the state of any subproject before planning, invoke the Scout
subagents in parallel with the `Agent` tool, passing the scout name as
`subagent_type` — they are read-only and report in a fixed format:

- `scout-app` — Flutter (`app/`)
- `scout-pi-extension` — Node/TS (`pi-extension/`)
- `scout-relay` — Rust (`relay/`)
- `scout-site` — NextJS (`site/`)
- `scout-cockpit` — Flutter Desktop (`cockpit/`)

Fire several `Agent` calls in a single message to run them in parallel. Each
report comes back with Stack & versions, Dependencies, Structure, Health
(lint/build/tests) and detected Smells.

## This repository is a fork

This monorepo is a **fork** of [`jacobaraujo7/remote_pi`](https://github.com/jacobaraujo7/remote_pi)
and follows its own product line. Before touching identity (bundle IDs, domains,
branding) or pulling changes from upstream, read [`FORK.md`](./FORK.md) — it
defines the merge direction (always upstream → fork), what counts as intentional
divergence, and how to sync.
