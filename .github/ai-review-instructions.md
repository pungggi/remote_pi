# Review rules for the AI reviewer (repo: remote_pi / "Piper")

The bot reads this file from the PR head. Short, concrete rules, one per
line; project-specific content only — generic defaults live centrally in
`pungggi/ai-review`.

## Project

- Monorepo, fork of `jacobaraujo7/remote_pi` with its own product line
  (merge direction: always upstream → fork, see `FORK.md`).
- Subprojects: `app/` (Flutter, Dart — Android phone client), `cockpit/`
  (Flutter desktop + Rust CLI), `relay/` (Rust server), `pi-extension/`
  (TypeScript/Node, pi coding-agent extension), `site/` (NextJS),
  `pi-extension/agy-plugin/`, `plan/` (numbered planning docs — prose,
  not code; the fork uses the `100+` number range).

## Known contexts (do not report as findings)

- `.github/workflows/ai-review.yml` is deliberately a thin stub; the
  `pr_number` contract with the central reusable workflow in
  `pungggi/ai-review` is known and verified — empty inputs on
  `pull_request` events are intentional.
- Single-owner repo: PRs come from same-repo branches (no fork-PR secret
  scenarios; `secrets: inherit` is safe here).
- `[skip review]` handling and reusable-workflow permissions live
  centrally in `pungggi/ai-review` — check there, not here.
- Lockfiles are excluded from review: `pubspec.lock`, `Cargo.lock`,
  `pnpm-lock.yaml`, `package-lock.json`.
- `flutter analyze` has 3 known pre-existing infos (`protocol.dart:3325`,
  `chat_page.dart:833`, `font_scale.dart:34`) — do not re-report those
  lines; new ones elsewhere still count.

## Rules

- No secrets, keys, or tokens in code, configs, or logs — ever.
- Dart: no `dynamic` in new code where a typed alternative exists; no
  force-unwraps (`!`) on values that can legitimately be null.
- Errors must be handled, not swallowed: no empty `catch`/`on ... catch {}`.
- Rust: no `unwrap()`/`expect()` on fallible paths in production code;
  errors go through the crate's established error types.
- TypeScript: strict mode, no `any` in new code without justification.
- New logic needs tests or a PR-stated reason why not (`flutter test`,
  `cargo test`, `vitest` are the suites).
- Notification payloads stay generic: no message/chat content in local
  notifications (plan/36 §3 discipline — applies to `app/lib/data/
  notifications/`).
- Per-user durable state changes need a migration story or a stated
  reason why none is needed (Hive boxes in `app/lib/data/local/`).
- User-facing changes need a `app/assets/CHANGELOG.md` entry
  (Keep-a-Changelog; newest entries on top under `[Unreleased]`).
- Cross-cutting protocol changes (relay ↔ app ↔ pi-extension) must be
  called out in the PR description if any consumer is not updated.
- Docs/markdown style (repo AGENTS.md): short paragraphs (2–3 sentences),
  bullet lists over wall-of-text, bold prefixes for scannable lists, no
  em-dash run-on clauses.
- Release discipline: git tags `vX.Y.Z` / `app-vX.Y.Z` must match the
  package/pubspec version at the tagged commit.
