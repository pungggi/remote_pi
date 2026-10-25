# Plan 151 — Cockpit upstream sync, 25 October 2026

## Context

The fork is 272 commits behind `upstream/main`. Upstream moved Cockpit from the local 1.28.x line to 2.1.x, including Windows process handling, ConPTY, terminal performance, usability, documents, and remote-workspace changes.

`git merge-tree` reports 31 conflicts, including 11 modify/delete conflicts. Most deletions are the legacy `pi --mode rpc` harness that upstream removed while the fork kept modifying it.

## Closed decisions

- **Merge direction**: upstream into the fork, never rebase published fork history.
- **Legacy RPC**: remove it during this sync. The user explicitly revised the old no-big-bang rule on 2026-10-25; see `plan/00-decisions.md`.
- **Fork identity**: Piper bundle IDs, URLs, branding, signing anchors, and release scope win over upstream identifiers.
- **Apple scope**: no new Apple release jobs or signing requirements. Existing inert scaffolds may remain.
- **Feature scope**: no post-sync PR (#260/#264/#257) before the merged baseline is green.

## Expected conflict policy

- **RPC modify/delete**: accept upstream deletion. Remove remaining imports, tests, tools, and documentation references that only describe the deleted harness.
- **Release identity**: keep Piper names, IDs, feeds, public keys, and Android/Windows/Linux release behavior.
- **Site**: take the Cockpit 2.x information architecture and features without reverting Piper branding or fork download destinations.
- **Tasks/changelog/lockfiles**: combine both histories semantically. Regenerate locks instead of choosing a side line by line.
- **Local behavior**: preserve fork-specific socket diagnostics, remote-server hardening, and reliability fixes unless upstream provides a complete equivalent.

## Steps and acceptance criteria

1. **Merge upstream**
   - Record and resolve all 31 conflicts.
   - Keep a conflict-to-decision trail in this plan or the session state.
2. **Remove the legacy RPC stack**
   - No live imports of deleted RPC files remain.
   - No stale release/test command requires `tool/rpc_smoke.dart`.
3. **Restore fork invariants**
   - `ch.pungitore.piper*` identities and Piper branding remain.
   - Fork update anchors and configured release platforms remain intact.
4. **Verify the merged baseline**
   - `flutter analyze` and `flutter test` in `app/`.
   - `pnpm typecheck`, `pnpm test`, and `pnpm build` in `pi-extension/`.
   - `cargo test` in `relay/`.
   - `flutter analyze` and `flutter test` in `cockpit/`.
   - Cockpit CLI Rust tests.
   - Site lint and production build.
5. **Build and manual review**
   - Attempt a Windows Cockpit release build when the local Zig/Rust toolchain allows it.
   - Record physical/manual scenarios separately from automated verification; never mark them green by assumption.

## Verification matrix

| Area | Automated gate | Manual gate |
|---|---|---|
| App | Existing full suite after sync | Streaming/resume/device checks remain separate |
| Extension | Full suite, typecheck, build | Real multi-session mesh smoke remains separate |
| Relay | Full Rust suite | Relay reconnect smoke remains separate |
| Cockpit | Flutter suite, CLI tests, analyze | Startup, terminal create/close, links/find, shutdown, documents |
| Site | ESLint and `next build` | Branding and download-link review |
| Release | Windows build if toolchain permits | No tag or publish in this plan |

## Verification result

- **Cockpit**: 1646 tests passed, 8 skipped; analyze has no errors, only existing deprecation/style info.
- **Cockpit CLI**: 35 tests plus fmt and clippy green.
- **App**: 926 tests passed.
- **Extension**: 1138 tests passed, 17 skipped; typecheck and build green.
- **Relay**: 155 tests passed.
- **Site**: ESLint and production build green.
- **Windows release**: `cockpit.exe` and `cockpit-cli.exe` built; bundled server announced a valid endpoint in the smoke test.
- **Toolchain notes**: Flutter 3.50, Zig 0.16.0, NuGet, and ATL/MFC were required. A short `C:\ckp` junction avoided the Windows path-length limit.
- **Not manually verified**: interactive streaming/resume, real mesh, physical Cockpit startup/shutdown, and device-specific UI behavior.

## DoD

- [x] Upstream merged; all conflicts resolved and indexed.
- [x] Legacy RPC removed without live references.
- [x] Piper identity and release invariants checked.
- [x] Automated verification matrix completed or exceptions documented.
- [x] Manual/device checks explicitly listed as pending when not run.
- [ ] Post-sync follow-ups scoped only after the baseline is green.

## Next plans

- Evaluate #260 for Tailscale SSH TCP fallback against the new remote-workspace code.
- Evaluate #264 editor soft wrap and split #257 terminal status line/Ctrl-Tab if selected by the user.
