# Review rules for the AI reviewer (repo: remote_pi)

The bot reads this file from the PR head of the target repo. Short, concrete
rules, one per line; 10-20 rules are optimal. Everything here is
project-specific.

## Project
- Monorepo for the remote_pi phone-bridge: `pi-extension/` (Node/TS, runs inside
  the pi coding agent), `app/` (Flutter phone app), `cockpit/` (Flutter desktop),
  `relay/` (Rust), `site/` (NextJS), `plan/` (fork plans).
- Protocol contracts between the app and the extension must stay in sync:
  `app/lib/data/protocol.dart` and `pi-extension/src/daemon/control_protocol.ts`
  are two sides of the same wire format. New ops/types need both sides plus
  parse/serialize handling.
- Translations: user-facing strings go into `app/lib/i18n/` and
  `cockpit/lib/i18n/*.i18n.json` — new UI strings need keys in all shipped
  languages, not hardcoded text.

## Known contexts (do NOT report as findings)
- The single active `remote_pi` worktree line in `~/.pi/agent/settings.json` is
  a global machine setting, not a repo file; duplicate worktree worktrees by
  design register the same tool set.
- Keeper resurrection semantics: pruning `rooms.json` is sufficient to stop a
  deleted session from coming back; deleting whole encoded-cwd folders is
  unsafe by design (path collisions), so per-session transcript deletion is
  intentional.
- Release flows (npm packages, APK, Cockpit installers) run via GitHub Actions
  on tags; do not flag the absence of local build scripts.

## Rules
- No secrets, keys, or tokens in code, configs, or logs.
- TypeScript: no `any` in new code without justification.
- Errors must be handled, not swallowed: no empty catch blocks.
- Do not silently break protocol contracts between app/ and pi-extension/:
  matching enum/JSON keys on both sides.
- New logic needs tests or a PR justification why not. Extension:
  `npm test` (vitest). App: `flutter test` + `flutter analyze` clean.
- Breaking changes to internal APIs must be named in the PR description.
- Flutter app: follow the existing architecture (repositories + view models);
  no new state-management patterns in one PR.
- Rust relay: no unwrap()/expect() on request paths; propagate errors.
- Fork plan files live in `plan/` with 100+ numbering; upstream-numbered plans
  (1-99) are upstream's and must not be edited here.
- CI workflows: changes to `app-release.yml` / `cockpit-release.yml` affect the
  signing/release chain; call out any secret or signing change explicitly.
