# Plan 155 — Antigravity Native Sidecar, Hook Fixes & AgentAPI Real-Time Wakeup

## Context

Plan 154 established Google Antigravity (`agy`) as a first-class citizen of the `remote-pi` agent mesh:
- Multi-agent lock acquisition with per-`(cwd, name)` `#N` suffixing ([`cwd_lock.ts`](../pi-extension/src/session/cwd_lock.ts))
- MCP tools: `list_peers`, `agent_send`, `get_messages`, `wait_for_message`, and `mesh_status` ([`mesh_server.ts`](../pi-extension/src/mcp/mesh_server.ts))
- Lifecycle hooks ([`mesh_hook.mjs`](../pi-extension/agy-plugin/scripts/mesh_hook.mjs)): `PreInvocation` injects unread counts; `Stop` continues active turns when unread messages arrive.

### Pre-Existing Bugs in Plan 154 (Must Be Fixed First)
1. **Invalid `hooks.json` schema in [`agy_plugin.ts`](../pi-extension/src/session/agy_plugin.ts)**:
   - `writePluginHooksConfig` wrapped `PreInvocation` and `Stop` in Claude Code's `{ "hooks": [...] }` group wrapper.
   - In Antigravity's native `hooks.json` specification, only `PreToolUse` and `PostToolUse` use `{ "matcher": "...", "hooks": [...] }`. `SessionStart`, `PreInvocation`, `PostInvocation`, and `Stop` **must be flat arrays of handler objects** (`[{ "type": "command", "command": "...", "timeout": 5 }]`).
   - Because of the extra `{ "hooks": [...] }` wrapper, `agy plugin validate` fails (`invalid hook "hooks": command hook must specify 'command'. The loader skips this whole file`) and Antigravity skips the entire `hooks.json` file at runtime.
2. **Missing event identifier on `stdin` in [`mesh_hook.mjs`](../pi-extension/agy-plugin/scripts/mesh_hook.mjs)**:
   - `mesh_hook.mjs` checks `input.hook_event_name || input.event`, which are Claude Code fields.
   - Antigravity's protojson `stdin` payload uses camelCase (`conversationId`, `workspacePaths`, `invocationNum`, `terminationReason`, etc.) and **does not include an event name field**.
   - As a result, `eventName` evaluates to `""` in real Antigravity sessions unless passed via CLI argument (`--event=SessionStart`, `--event=PreInvocation`, `--event=Stop`) or inferred from the payload fields (`terminationReason` -> `Stop`, `invocationNum` -> `PreInvocation`, else `SessionStart`).

### The Remaining Gap: Idle Reactivity Across Antigravity Surfaces
When an Antigravity session completes its turn, it goes idle. When a peer agent sends a message (e.g. `agent_send body='{"event":"pr-merged"}'`), the message is queued in [`MeshInbox`](../pi-extension/src/mcp/inbox_state.ts) and synced to `~/.pi/piper/sessions/local/inbox/<roomId>.json`, but an idle session does not wake up until prompted.

While a background `mesh-listener` subagent can trigger Antigravity's **Reactive Wakeup**, subagents are session-scoped and get terminated if the language server restarts, if settings change, or if not persistently re-armed after each turn.

### The Solution: Dual-Path `agentapi send-message` Wakeup (Sidecar + Direct MCP Trigger)
Antigravity provides:
1. **Native Sidecars (`sidecar.json`)** (available on **Antigravity App 2.0**, where `SidecarManager` runs background daemons with `restart_policy: "always"` and injects `ANTIGRAVITY_LS_ADDRESS`, `ANTIGRAVITY_CSRF_TOKEN`, `ANTIGRAVITY_AGENTAPI_EXE`, and `ANTIGRAVITY_EXECUTABLE_DATA_DIR`).
2. **The `agentapi` CLI subcommand** (`agy agentapi send-message [--title=<title>] <conversation_id> <content>`), which injects a prompt directly into an active conversation's queue.
3. **In-process MCP server (`mesh_server.ts`)**, which is *already* running inside every `agy` CLI, IDE, and App session and receives incoming mesh envelopes in real time via `node.onMessage`.

To work reliably across **both** the Antigravity 2.0 App (`SidecarManager`) and standalone `agy` CLI/IDE sessions (where `enable-sidecars` is disabled by the runtime):
1. **Fix `hooks.json` & `mesh_hook.mjs`** to register `SessionStart`, `PreInvocation`, and `Stop` as flat handler arrays with `--event=<Event>`, recording the active `conversationId`, `hostPid` (the `agy` session host PID, **never** the ephemeral hook `process.pid`), normalized `workspacePath`, and turn `state` (`"busy"` on `SessionStart`/`PreInvocation`, `"idle"` on `Stop` when no continuation is requested).
2. **Package the `mesh-watcher` Sidecar** under `plugins/remote-pi-mesh/sidecars/mesh-watcher/` **and explicitly enable it in `~/.gemini/config/config.json`** (`sidecars["remote-pi-mesh/mesh-watcher"].enabled = true`, since Antigravity disables all sidecars by default).
3. **Correlate Inbox -> Conversation by Session Host PID (`ppid`)**:
   - Multiple agents (`pi`, `claude`, `agy`, `agy#2`) can share the same workspace (`cwd`).
   - Matching by `workspacePath` alone would wake `agy` when a message arrives for `claude` or `agy#2` in the same folder.
   - Both `mesh_server.ts` (`InboxStateRecord.ppid`) and `mesh_hook.mjs` share the same parent session host process (`hostPid`). Matching `conversation.hostPid === inboxRecord.ppid` (with workspace fallback only when unambiguous) guarantees 1-to-1 routing between an inbox and its owning `agy` conversation.

---

## Expected Structure

```text
pi-extension/
  agy-plugin/
    plugin.json                                # Validated against https://antigravity.google/schemas/v1/plugin.json (no custom "sidecars" key)
    sidecars/
      mesh-watcher/
        sidecar.json                           # Antigravity sidecar configuration ("command": "node", "args": ["watcher.mjs"])
        watcher.mjs                            # Zero-dependency Node daemon: watches inboxes and executes agentapi send-message
    scripts/
      mesh_hook.mjs                            # Flat-array hook handler (--event=...): records conversationId, hostPid, workspacePath, and busy/idle state
  skills/
    agent-network/
      SKILL.md                                 # Documents autonomous wakeup and reactive fallback for agy
  src/
    mcp/
      inbox_state.ts                           # Tracks lastMessageId in InboxStateRecord so >5 unread messages still trigger wakeups
    session/
      conversation_registry.ts                 # Host-PID & workspace <-> active conversationId registry writer/reader/cleaner
      conversation_registry.test.ts            # Unit tests for conversation registry mapping, hostPid correlation, and stale PID pruning
      agy_plugin.ts                            # Fixes flat hooks.json, deploys sidecars/, and enables sidecar in ~/.gemini/config/config.json
      agy_plugin.test.ts                       # Unit tests for flat hooks.json, config.json sidecar enablement, and sidecar deployment
```

---

## Step 1 — Fix `hooks.json` & Build the Session-Host Conversation Registry

### Design
1. **Fix `hooks.json` Format in [`agy_plugin.ts`](../pi-extension/src/session/agy_plugin.ts)**:
   - Replace the invalid `{ "hooks": [...] }` wrapper with a named hook group using flat handler arrays and explicit `--event` flags:
     ```json
     {
       "remote-pi-mesh": {
         "SessionStart": [
           {
             "type": "command",
             "command": "\"<nodeExec>\" \"<hookScriptPath>\" --event=SessionStart",
             "timeout": 5
           }
         ],
         "PreInvocation": [
           {
             "type": "command",
             "command": "\"<nodeExec>\" \"<hookScriptPath>\" --event=PreInvocation",
             "timeout": 5
           }
         ],
         "Stop": [
           {
             "type": "command",
             "command": "\"<nodeExec>\" \"<hookScriptPath>\" --event=Stop",
             "timeout": 5
           }
         ]
       }
     }
     ```
   - Verify with `agy plugin validate` that `hooks 1` is recognized with `0` errors.
2. **Event Detection in [`mesh_hook.mjs`](../pi-extension/agy-plugin/scripts/mesh_hook.mjs)**:
   - Resolve `eventName` in priority order:
     1. `--event=<Name>` CLI argument (`SessionStart`, `PreInvocation`, `Stop`).
     2. `input.hook_event_name || input.event` (backward compatibility for existing unit tests).
     3. Protojson field inference: `typeof input.terminationReason === "string"` -> `"Stop"`, `typeof input.invocationNum === "number"` -> `"PreInvocation"`, otherwise `"SessionStart"`.
3. **Registry Directory & Schema (`~/.pi/piper/sessions/local/conversations/<conversationId>.json`)**:
   - Content:
     ```json
     {
       "conversationId": "f550dfa1-9420-40f1-a017-7f69b94ccaef",
       "workspacePath": "c:/users/alessandro/source/pi/packages/remote_pi",
       "hostPid": 25548,
       "state": "idle",
       "lastWokenMessageId": "m-42",
       "updatedAt": 1730000000000
     }
     ```
   - **CRITICAL PID Pitfall**: `mesh_hook.mjs` is a transient process that exits in `<15ms`. Never write `process.pid` to the registry (it dies immediately). Write the **session host PID** (`process.ppid`, or `hostParentPid()` when wrapped by `cmd.exe /c` on Windows).
   - **Fast Path on Windows**: Avoid spawning `powershell.exe` (`Get-CimInstance`, which adds ~500-1000ms latency) on every empty-inbox hook invocation if a live conversation record for `conversationId` already exists and has a live `hostPid`; only resolve `hostParentPid()` once when creating/updating a new `conversationId` record or when matching a candidate inbox's `ppid`.
   - **Turn State Tracking (`"busy"` vs `"idle"`)**:
     - On `SessionStart` and `PreInvocation`: record `state: "busy"`.
     - On `Stop`: if returning `{ decision: "continue" }`, keep `state: "busy"`; if returning `{}` (turn is genuinely ending), record `state: "idle"`.
4. **Lookup & Cleanup (`conversation_registry.ts`)**:
   - `findConversationForInbox(inboxRecord)`:
     - Scans `~/.pi/piper/sessions/local/conversations/*.json`.
     - Unlinks records whose `hostPid` is no longer alive (`!isProcessAlive(record.hostPid)`).
     - Matches records where `normalizeWorkspacePath(record.workspacePath) === normalizeWorkspacePath(inboxRecord.cwd)` **AND** (when `inboxRecord.ppid` is present) `record.hostPid === inboxRecord.ppid` (or shares the session host lineage).
     - Never matches an inbox owned by a non-`agy` agent (`name: "pi"`, `name: "claude"` when another session's `ppid` owns it).

### Acceptance Criteria
- `agy plugin validate` passes with `0` hook errors and reports `hooks 1`.
- `mesh_hook.mjs` works when invoked with real Antigravity protojson payloads (which omit `hook_event_name`).
- `conversation_registry.ts` records `hostPid` (not the transient hook PID), tracks `state: "busy" | "idle"`, and prunes dead `hostPid` files.
- Coexisting `pi`, `claude`, `agy`, and `agy#2` sessions in the same folder never cross-trigger each other's conversation wakeup.

---

## Step 2 — The `mesh-watcher` Sidecar Daemon & `agentapi` Invocation

### Design
1. **Sidecar Manifest (`pi-extension/agy-plugin/sidecars/mesh-watcher/sidecar.json`)**:
   ```json
   {
     "command": "node",
     "args": ["watcher.mjs"],
     "restart_policy": "always",
     "display_name": "remote-pi Mesh Watcher",
     "description": "Monitors the remote-pi agent mesh and wakes idle Antigravity conversations via agentapi when messages arrive."
   }
   ```
2. **Include `lastMessageId` in [`InboxStateRecord`](../pi-extension/src/mcp/inbox_state.ts)**:
   - `InboxStateRecord.preview` is capped at `MAX_PREVIEW_ITEMS = 5` (`messages.slice(0, 5)`). If 5 messages are already unread and a 6th arrives, `preview` does not change!
   - Add `lastMessageId: string | null` (`messages[messages.length - 1]?.id ?? null`) to `InboxStateRecord` so `watcher.mjs` can reliably detect every newly arrived message regardless of queue depth.
3. **Watcher Implementation (`pi-extension/agy-plugin/sidecars/mesh-watcher/watcher.mjs`)**:
   - **Ensure Directory Exists Before Watching**: Call `mkdirSync(inboxStateDir(), { recursive: true })` before `fs.watch` so starting the sidecar before the first session does not throw `ENOENT`.
   - **Ignore Atomic Temp Files**: `writeInboxState` writes `<id>.json.<pid>.tmp` and renames it to `<id>.json`. Filter `fs.watch` events to `.json` files only (ignoring `.tmp` files) and debounce by ~100ms.
   - **Avoid Mid-Turn Duplicate Wakeups (`Stop` Hook Race)**:
     - If an envelope arrives while `conversation.state === "busy"`, do **not** immediately call `agentapi send-message` — the `Stop` hook will intercept `NO_TOOL_CALL` at the end of the turn and return `{ decision: "continue" }`.
     - Also watch `~/.pi/piper/sessions/local/conversations/` (or re-check after `Stop` transitions the conversation to `state === "idle"`): if `unreadCount > 0` and `conversation.state === "idle"`, fire `agentapi send-message` immediately.
   - **Persistent Deduplication Across Restarts**:
     - Store `lastWokenMessageId` in `conversation` registry JSON (and/or `process.env.ANTIGRAVITY_EXECUTABLE_DATA_DIR`) keyed by `${conversationId}:${lastMessageId}:${unreadCount}` so a sidecar restart (`restart_policy: "always"`) does not re-send a prompt for an already-woken message.
   - **Safe Cross-Platform `agentapi` Execution (Critical Windows Pitfall)**:
     - In Antigravity, `ANTIGRAVITY_AGENTAPI_EXE` points to the **language server / `agy.exe` executable itself**, where `agentapi` is a subcommand (`<exe> agentapi send-message ...`), whereas the `PATH` shim on Windows is `agentapi.bat` (which throws `ENOENT` in `execFileSync('agentapi', ...)` without a shell, and `shell: true` with peer message previews risks command injection).
     - Always invoke `agentapi` using Antigravity's canonical pattern without `shell: true`:
       ```js
       const exe = process.env.ANTIGRAVITY_AGENTAPI_EXE;
       const file = exe || (process.platform === "win32" ? "agy.exe" : "agentapi");
       const execArgs = exe || file.endsWith("agy.exe")
         ? ["agentapi", "send-message", conversationId, notification]
         : ["send-message", conversationId, notification];
       execFileSync(file, execArgs, { encoding: "utf8", env: process.env, timeout: 10_000 });
       ```
   - **CLI / IDE Fallback When `SidecarManager` Is Inactive**:
     - Because Antigravity only runs `SidecarManager` in the Antigravity 2.0 App (not in standalone `agy` CLI), allow `mesh_server.ts` (when connected as an `agy` session) to trigger the same idle-wake check on `node.onMessage` when `ANTIGRAVITY_LS_ADDRESS` / `ANTIGRAVITY_CSRF_TOKEN` are present in the environment and no sidecar has woken the conversation within 300ms.

### Acceptance Criteria
- `watcher.mjs` creates `~/.pi/piper/sessions/local/inbox/` if missing and ignores `.tmp` atomic write files.
- When an inbox record has `unreadCount > 0` and its owning `agy` conversation is `idle`, `agentapi send-message` is invoked safely via `execFileSync` (no `shell: true` injection risk).
- Messages arriving mid-turn (`state === "busy"`) are handled by the `Stop` hook without queuing a redundant second turn via `agentapi send-message`.
- Deduplication survives sidecar restarts and works even when `unreadCount > 5`.

---

## Step 3 — Plugin Bundling, Schema Compliance & `config.json` Enablement

### Design
1. **Packaging (`pi-extension/agy-plugin/sidecars/mesh-watcher/`)**:
   - Update [`ensureAgyMeshPluginInstalled`](../pi-extension/src/session/agy_plugin.ts) to copy `sidecars/mesh-watcher/sidecar.json` and `sidecars/mesh-watcher/watcher.mjs` into `<configDir>/plugins/remote-pi-mesh/sidecars/mesh-watcher/`.
2. **Do NOT Add Invalid Keys to `plugin.json`**:
   - `https://antigravity.google/schemas/v1/plugin.json` enforces `"additionalProperties": false` and does **not** have a `sidecars` property.
   - Antigravity discovers `plugins/remote-pi-mesh/sidecars/mesh-watcher/sidecar.json` automatically by directory structure. Keep `plugin.json` strictly schema-compliant.
   - Note: Because `mcp_config.json` is intentionally installed at `<configDir>/mcp_config.json` (so `mesh_server.js` inherits the workspace `cwd` instead of the plugin directory), `agy plugin validate` will report `skills 1 · agents 0 · rules 1 · hooks 1 · mcpServers 0 · sidecars 1`.
3. **Enable Sidecar in `<configDir>/config.json`**:
   - Per Antigravity's sidecar specification, sidecars are **disabled by default** unless enabled in `~/.gemini/config/config.json`.
   - In [`ensureAgyMeshPluginInstalled`](../pi-extension/src/session/agy_plugin.ts), safely upsert `<configDir>/config.json` (using `stripJsonComments` and refusing to overwrite malformed JSON, identical to `upsertGlobalMcpConfig`):
     ```json
     {
       "plugins": {
         "remote-pi-mesh": {
           "enabled": true
         }
       },
       "sidecars": {
         "remote-pi-mesh/mesh-watcher": {
           "enabled": true
         }
       }
     }
     ```

### Acceptance Criteria
- Running `remote-pi agy --install-plugin` (or launching `remote-pi agy`) installs `sidecars/mesh-watcher/sidecar.json` and `watcher.mjs`, writes flat `hooks.json`, and enables `remote-pi-mesh/mesh-watcher` in `<configDir>/config.json`.
- `agy plugin validate ~/.gemini/config/plugins/remote-pi-mesh` reports `0 errors` and discovers `skills 1 · agents 0 · rules 1 · hooks 1 · mcpServers 0 · sidecars 1`.
- Unit tests verify idempotent installation, `config.json` preservation, and valid JSON schema generation.

---

## Step 4 — Verification & End-to-End Testing

1. **Unit & CLI Validation Testing**:
   - `conversation_registry.test.ts`: verify conversation recording with `hostPid`, `busy`/`idle` state transitions, `ppid` session-host correlation across coexisting agents in the same workspace, and dead `hostPid` pruning.
   - `agy_plugin.test.ts`: verify flat `hooks.json` generation, protojson `stdin` handling (without `hook_event_name`), `config.json` sidecar enablement preservation, and `watcher.mjs` deduplication/execution.
   - Run `agy plugin validate C:\Users\Alessandro\.gemini\config\plugins\remote-pi-mesh` to confirm `0 errors`.
2. **Live Mesh Integration Testing**:
   - Verify hooks fire on real `agy` turns (`PreInvocation` and `Stop`) and populate `~/.pi/piper/sessions/local/conversations/<conversationId>.json`.
   - Send a mesh message to an idle `agy` conversation (`agent_send to="<cwd>@agy" body="ping"`) and verify `watcher.mjs` invokes `agentapi send-message <conversationId> ...` and wakes the conversation.

---

## Definition of Done (DoD)

- [x] `writePluginHooksConfig` in `agy_plugin.ts` outputs Antigravity-compliant flat hook arrays with `--event=<Event>`, passing `agy plugin validate` with 0 errors.
- [x] `mesh_hook.mjs` supports Antigravity protojson payloads (without `hook_event_name`) and records `conversationId`, `hostPid` (`ppid`), `workspacePath`, and `state` (`"busy"` / `"idle"`).
- [x] `conversation_registry.ts` correlates inboxes to conversations by `(workspacePath, hostPid)` and unlinks stale records when `hostPid` exits.
- [x] `InboxStateRecord` in `inbox_state.ts` includes `lastMessageId` so wake deduplication works beyond 5 unread messages.
- [x] `pi-extension/agy-plugin/sidecars/mesh-watcher/` provides `sidecar.json` and `watcher.mjs` using safe `execFileSync` (`ANTIGRAVITY_AGENTAPI_EXE` with `"agentapi"` subcommand, no `shell: true`).
- [x] `ensureAgyMeshPluginInstalled` deploys `sidecars/mesh-watcher/` and enables `sidecars["remote-pi-mesh/mesh-watcher"]` in `~/.gemini/config/config.json`.
- [x] All unit tests pass via `vitest`.

## Next Plans
- **Plan 156**: Cockpit & mobile app UI notifications for incoming mesh requests targeting background `agy` daemons.
