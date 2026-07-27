# Plan 108 — Pin a project path & open a terminal there (remote `/ps clone`)

## Context

From the **phone**, the user wants to tap once and open a new terminal session
(running `pi`) at a chosen project folder on the paired **PC** — the same thing
pi-ps's `/ps clone` does locally:

- `/ps clone` → `wt.exe -w 0 new-tab -d <pi-cwd> pwsh -NoExit -Command pi`
  (inside Windows Terminal), with a `Start-Process` window fallback.

Today Piper can already steer an existing pi session (chat, model, git status),
but it cannot **spawn a new terminal/agent** on the PC. This plan adds that:
pin a folder per PC, then launch a Windows Terminal tab running `pi` there.

Two design anchors, matching existing UX:

- **Default cwd = the PC's session cwd** (`room_meta.cwd`). With no pin, the
  feature is pure `/ps clone` (open at the current folder). The pin is an
  **optional override** for a different folder.
- **Action rides the same typed-action request/response channel** as plan 107's
  git status (`id` ↔ `in_reply_to`). **No relay change** — user envelopes are
  forwarded verbatim; only the app + pi-extension change.

Windows-first. The PC in scope is Windows (matches pi-ps). Non-Windows replies
`method:"none", ok:false` with a clear message (Mac/Linux launcher = future
plan 108b); the feature degrades gracefully rather than silently failing.

## Expected structure

### Protocol (app `protocol.dart` + pi-extension `types.ts`)

Two new messages, modelled on `GitStatusRequest`/`GitStatusResult` (plan 107):

```
ClientMessage +=
  | OpenTerminalRequest   { type:"open_terminal_request", id, cwd?: string, runPi?: bool }

ServerMessage +=
  | OpenTerminalResult    { type:"open_terminal_result", in_reply_to,
                            ok: bool, message: string,
                            method?: "wt" | "window" | "none" }
```

- `cwd` optional. `null`/absent → pi-extension uses its own session cwd.
- `runPi` optional, default `true` (matches `/ps clone`). `false` → plain shell.
- `method` describes what was launched (`wt` tab, `window` fallback, `none`).

Wire codec: add `open_terminal_request` (client) + `open_terminal_result`
(server) to `types.ts`; add `open_terminal_result` to `codec.ts` `SERVER_TYPES`.

### pi-extension (`src/actions/open_terminal.ts` + dispatch case)

Port pi-ps `open-tab.ts` logic (host detection + spawn + 2s safety net):

1. Resolve `cwd = msg.cwd ?? _myRoomMeta?.cwd`. Missing → `ok:false, "no working directory"`.
2. `fs.existsSync(cwd)` false → `ok:false, "path not found: <cwd>"`.
3. Platform guard: `process.platform !== "win32"` → `ok:false, method:"none", "unsupported on this platform"`.
4. Build command: `runPi ? "pi" : undefined`.
5. If `WT_SESSION` set → `spawn("wt.exe -w 0 new-tab -d \"<cwd>\" \"<shell>\"[-NoExit -Command pi]", {detached, shell:true, windowsHide:true})`.
6. Else fallback → `Start-Process <shell> -WorkingDirectory <cwd> [-ArgumentList '-NoExit -Command pi']` via a hidden launcher.
7. Shell resolve: prefer `pwsh.exe` (where on PATH), fall back to `powershell.exe`. Minimal resolver (no pi-ps `shell-resolve` dep).
8. 2s safety-net timer → resolve `ok:true` (target runs independently).
9. Reply `OpenTerminalResult({ ok, message, method })` — always replies (no timeout path, like git status).

Dispatch: new `case "open_terminal_request": void handleOpenTerminal(sender, msg, _myRoomMeta?.cwd ?? null);` in `_routeClientMessageFrom` (after `git_status_request`). App `sync_service.dart` ignore-group gains `OpenTerminalResult()`.

### App

**Storage — pinned path per peer.** `Preferences` (flat `FlutterSecureStorage`)
gains a per-peer nullable string keyed by `terminal_cwd.<epk>`:

- `String? terminalCwdFor(String epk)` / `setTerminalCwdFor(String epk, String? cwd)`.
- Empty/absent → null → launch uses session cwd. ChangeNotifier notifies so the
  ℹ dialog and quick-action label rebuild live.

**`IActionsRepository.openTerminal({String? cwd, bool runPi = true})`** →
`Future<({bool ok, String message, String? method})>` via the existing
`_dispatch` envelope (returns the `OpenTerminalResult` payload).

**UI — launcher (quick actions sheet).** New `_ActionRow`:

```
icon: LucideIcons.terminalSquare
label: 'Open terminal'   (or 'Open at <basename>' when a path is pinned)
onTap: → _onOpenTerminal(vm)
```

- Resolves pinned cwd for the current peer; sends `openTerminal(cwd: pin, runPi: true)`.
- While awaiting → spinner on the row (`QuickActionsBusy(action: terminal)` — add
  `ActionName.terminal`). On result → snackbar (`ok ? info : error`).
- A new `ActionName.terminal` value in the quick-actions enum/state.

**UI — config (session-info ℹ dialog).** A new "Terminal" section:

```
TERMINAL
<resolved cwd — pinned path, or "<session folder>" when using default>
[ Edit path… ]   [ Clear ]   (Clear only when a pin is set)
```

- "Edit path…" → small dialog with a `TextField` (mono font) prefilled with the
  pinned path (or empty). Save → `setTerminalCwdFor(epk, value.trim())`.
  Validates non-empty + trims trailing separator.
- Shows the resolved folder so the user knows where "Open terminal" will land.
- Lives next to the Git row (plan 107) — same per-PC context.

## Steps

1. **Protocol (app).** Add `OpenTerminalRequest` (ClientMessage) +
   `OpenTerminalResult` + `OpenTerminalMethod` (ServerMessage) to
   `protocol.dart` with `toJson`/`fromJson`. Unit-test the round-trip.
2. **Protocol (pi-extension).** Add the two wire types to `types.ts`; add
   `open_terminal_result` to `codec.ts` `SERVER_TYPES`. `tsc --noEmit` clean.
3. **pi-extension handler.** Create `src/actions/open_terminal.ts` porting
   pi-ps open-tab logic (WT detection, spawn, fallback, 2s net, platform guard,
   cwd resolution + `existsSync`). Wire `case "open_terminal_request"` in
   `index.ts`. **`npx tsc` to rebuild `dist/`** (daemon loads dist — see
   SESSION-STATUS gotcha), then restart the paired session.
4. **App repository.** `IActionsRepository.openTerminal(...)` + `_onMessage`
   case for `OpenTerminalResult` + `sync_service.dart` ignore-group. Update the
   two quick-actions test fakes to stub `openTerminal()`.
5. **App storage.** `Preferences.terminalCwdFor/setTerminalCwdFor` (per-peer,
   ChangeNotifier). Persist round-trip test.
6. **App UI — quick action.** Add `ActionName.terminal` + the `_ActionRow` +
   `_onOpenTerminal` (resolve pin → call → snackbar + busy state).
7. **App UI — ℹ dialog.** Add the "Terminal" section (resolved-cwd readout +
   Edit/Clear). Reuses `_InfoRow` styling.
8. **Verify on device.** Install, open chat, tap quick action → confirm a new
   WT tab running `pi` opens at the pinned path on the PC. Test: no pin
   (session cwd), bad path (snackbar "path not found"), clear pin.

### Acceptance criteria

- [ ] Tapping "Open terminal" with **no pin** opens a WT tab running `pi` at the
      PC's session cwd (pure `/ps clone` parity).
- [ ] With a **pinned path**, the tab opens at that folder; the ℹ dialog shows
      it and "Open terminal" label includes its basename.
- [ ] **Bad path** → snackbar `"path not found: …"`; no tab spawned.
- [ ] **Edit/Clear** in ℹ dialog updates the pin live and persists across app
      restarts.
- [ ] Result always returns in <3s (no 15s timeout) — handler replies even on
      failure (ok:false), like git status.
- [ ] `dart analyze lib test` clean; app tests pass (incl. updated fakes);
      `tsc --noEmit` clean; existing 7 vitest failures unchanged (pre-existing).

## DoD

Feature works end-to-end on the Fold4 ↔ PC pair: pin a folder in the ℹ dialog,
tap "Open terminal" in quick actions, a Windows Terminal tab running `pi` opens
there. No relay rebuild. Committed + pushed; SESSION-STATUS notes the dist
rebuild step was applied.

## Next plans

- **108b** — Mac/Linux launcher (`open -a Terminal` / `x-terminal-emulator`) so
  the feature works cross-platform (currently Windows-first).
- **108c** — PC-side folder picker: `list_dirs_request` returns recent git repos
  / common dirs so the user can pick rather than type the path on the phone.
- **108d** — "Run pi" toggle in the ℹ Terminal section (plain shell vs second
  agent), and remembering the last-used command per peer.
