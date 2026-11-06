# Review rules for the AI reviewer (repo: remote_pi)

The bot reads this file from the PR head of the target repo. Short, concrete
rules, one per line; 10-20 rules are optimal. Everything here is
project-specific; generic defaults live centrally in `pungggi/ai-review`.

## Project

- Monorepo, fork of `jacobaraujo7/remote_pi` with its own product line
  (merge direction: always upstream → fork, see `FORK.md`).
- Subprojects: `app/` (Flutter, Dart — Android phone client), `cockpit/`
  (Flutter desktop + Rust CLI), `relay/` (Rust server), `pi-extension/`
  (TypeScript/Node, runs inside the pi coding agent), `site/` (NextJS),
  `plan/` (numbered planning docs — prose, not code).
- Protocol contracts between the app and the extension must stay in sync:
  `app/lib/data/protocol.dart` and `pi-extension/src/daemon/control_protocol.ts`
  are two sides of the same wire format. New ops/types need both sides plus
  parse/serialize handling.
- Translations: user-facing strings go into `app/lib/i18n/` and
  `cockpit/lib/i18n/*.i18n.json` — new UI strings need keys in all shipped
  languages, not hardcoded text.

## Known contexts (do NOT report as findings)

- `.github/workflows/ai-review.yml` is deliberately a thin stub; the
  `pr_number` contract with the central reusable workflow in
  `pungggi/ai-review` is known and verified — empty inputs on
  `pull_request` events are intentional.
- Single-owner repo: PRs come from same-repo branches (no fork-PR secret
  scenarios; `secrets: inherit` is safe here).
- The single active `remote_pi` worktree line in `~/.pi/agent/settings.json`
  is a global machine setting, not a repo file; duplicate worktree worktrees
  by design register the same tool set.
- Keeper resurrection semantics: pruning `rooms.json` is sufficient to stop a
  deleted session from coming back; deleting whole encoded-cwd folders is
  unsafe by design (path collisions), so per-session transcript deletion is
  intentional.
- Release flows (npm packages, APK, Cockpit installers) run via GitHub Actions
  on tags; do not flag the absence of local build scripts.
- Lockfiles are excluded from review: `pubspec.lock`, `Cargo.lock`,
  `pnpm-lock.yaml`, `package-lock.json`.
- `flutter analyze` has 3 known pre-existing infos (`protocol.dart:3325`,
  `chat_page.dart:833`, `font_scale.dart:34`) — do not re-report those
  lines; new ones elsewhere still count.

## Rules

- No secrets, keys, or tokens in code, configs, or logs.
- TypeScript: no `any` in new code without justification.
- Dart: no `dynamic` in new code where a typed alternative exists; no
  force-unwraps (`!`) on values that can legitimately be null.
- Errors must be handled, not swallowed: no empty catch blocks.
- Do not silently break protocol contracts between app/ and pi-extension/:
  matching enum/JSON keys on both sides.
- New logic needs tests or a PR justification why not. Extension:
  `npm test` (vitest). App: `flutter test` + `flutter analyze` clean.
  Relay: `cargo test` + clippy clean.
- Breaking changes to internal APIs must be named in the PR description.
- Flutter app: follow the existing architecture (repositories + view models);
  no new state-management patterns in one PR.
- Rust relay: no unwrap()/expect() on request paths; propagate errors.
- Notification payloads stay generic: no message/chat content in local
  notifications (plan/36 §3 — applies to `app/lib/data/notifications/`).
- Per-user durable state changes need a migration story or a stated reason
  why none is needed (Hive boxes in `app/lib/data/local/`).
- User-facing changes need an `app/assets/CHANGELOG.md` entry
  (Keep-a-Changelog; newest entries on top under `[Unreleased]`).
- Fork plan files live in `plan/` with 100+ numbering; upstream-numbered
  plans (1-99) are upstream's and must not be edited here.
- Docs/markdown style (repo AGENTS.md): short paragraphs (2-3 sentences),
  bullet lists over wall-of-text, bold prefixes, no em-dash run-on clauses.
- CI workflows: changes to `app-release.yml` / `cockpit-release.yml` affect
  the signing/release chain; call out any secret or signing change
  explicitly. Release tags (`vX.Y.Z` / `app-vX.Y.Z`) must match the
  package/pubspec version at the tagged commit.
