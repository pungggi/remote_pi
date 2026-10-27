# Plan 152 — Resume the exact offline Pi session

## Context

Home already offers **Start session** for an offline room. It currently asks the supervisor to start `pi --mode rpc --continue` in the session folder.

That resumes the most recent conversation in the folder, not necessarily the conversation represented by the selected room. Multiple Pi sessions in one folder can therefore resume the wrong history.

The replacement behavior is:

- **Known Pi session ID**: open a new visible terminal window in the original folder and run `pi --session <id>`.
- **No stored ID**: retain the existing headless `--continue` fallback for older rooms.
- **Entry point**: replace only Home → long-press → **Start session**. Tile taps keep their current behavior.

This gives the user a visible terminal and exact conversation continuity without creating a worktree or pinning a daemon.

## Expected structure

- `pi-extension/src/session/rooms_registry.ts`: persist an optional Pi `sessionId` on each room.
- `pi-extension/src/extension-state.ts` and `main.ts`: capture the current SDK session ID and refresh the registry on session replacement and relay connection.
- `pi-extension/src/actions/start_session.ts`: choose exact terminal resume when the registry has an ID; otherwise call the existing supervisor fallback.
- `pi-extension/src/actions/open_terminal.ts`: build the safely quoted Pi resume command through the existing terminal launcher.
- `app/lib/ui/home/home_page.dart`: show the action result message so terminal-launch failures and success are visible.
- Focused registry, session-lifecycle, handler, and app tests.

No relay change is required. The existing `start_session_request {cwd, name}` already identifies the registry room through `roomIdFor(cwd, name)`.

## Steps

1. **Persist the session ID**
   - Add `sessionId` to the registry entry and sanitize loaded values.
   - Preserve the ID when unrelated room metadata is rewritten.
   - Capture `ctx.sessionManager.getSessionId()` on every `session_start`.
   - Update an already-connected room immediately so `/new`, resume, and fork do not leave a stale ID.
   - **Acceptance:** registry round-trip and room replacement tests prove that the current ID survives and replaces the previous ID.

2. **Resume exactly in a terminal**
   - Resolve `roomIdFor(cwd, name)` in the device-daemon start handler.
   - If its registry entry has a session ID, call the existing Windows terminal launcher with `pi --session <id>`.
   - Quote the ID for the PowerShell command payload.
   - Return the existing `start_session_result` with the derived room ID and a user-facing message.
   - **Acceptance:** handler tests prove exact terminal launch and that the supervisor is not called on this path.

3. **Preserve legacy fallback**
   - If the room is absent or has no ID, retain the current `start_transient` supervisor call unchanged.
   - **Acceptance:** existing fallback tests stay green, with explicit no-ID coverage.

4. **Surface the outcome**
   - Display a non-empty `StartSessionResult.message`; retain the current generic success toast otherwise.
   - **Acceptance:** app tests remain green and the code displays terminal-launch errors instead of replacing them with a generic success message.

5. **Verify**
   - Run focused extension/app tests, extension typecheck/build, full relevant suites, and `git diff --check`.
   - Rebuild `dist/` for the affected-session deployment.
   - **Acceptance:** all automated checks pass. Any live resume verification is reported separately and never triggered merely to inspect visibility.

## DoD

- [x] Start session resumes the stored Pi session ID in the original cwd.
- [x] The exact-resume path opens a visible terminal and does not create a worktree.
- [x] `/new` and other session replacements update the stored ID.
- [x] Rooms without an ID retain the existing `--continue` fallback.
- [x] No relay protocol or app request-shape change is introduced.
- [x] Focused and full tests, typecheck, and build pass.
- [x] Deployment and affected-session restart requirements are stated explicitly.
- [ ] Verify the complete flow with a physical Windows Terminal and phone.

## Deployment

- **Relay**: no change and no restart required.
- **Extension**: rebuild `dist/`, then restart the device daemon to load the new Start session handler.
- **Existing sessions**: restart each target session once with the updated extension. Its next relay connection stores the current Pi session ID for later exact resume.
- **App**: an app update is only needed for the more specific success toast. The existing request works unchanged with older app builds.
- **Open PR #74**: deploy from a tree that also contains PR #74 if its Quit and provider-error changes must remain installed. This independent branch is based on `main`.

## Next plans

- Add session-ID metadata to the phone only if a future UI needs to display or copy it. The current feature deliberately keeps it PC-side.
- Consider cross-platform terminal launchers separately; the existing launcher currently supports Windows only.
