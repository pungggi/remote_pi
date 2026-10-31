# Plan 154 — Antigravity (`agy`) First-Class Mesh Integration

## Context

`remote-pi` currently supports two classes of mesh citizens:
1. **Pi native sessions** (`remote-pi [cwd]` / [`index.ts`](../pi-extension/src/index.ts)): in-process [`MeshNode`](../pi-extension/src/session/mesh_node.ts) with [`registerAgentSendTool`](../pi-extension/src/session/tools.ts) and [`createMeshDeliveryQueue`](../pi-extension/src/session/mesh_delivery.ts) (`pi.sendUserMessage` turn injection).
2. **Claude Code MCP sessions** (`remote-pi claude` / [`mesh_server.ts`](../pi-extension/src/mcp/mesh_server.ts)): stdio MCP server exposing `list_peers`, `agent_send`, and `get_messages`, plus `notifications/claude/channel` push notifications.

To make **Google Antigravity (`agy` CLI & IDE)** a first-class citizen of the `remote-pi` mesh at every level (transport, multi-agent same-folder coexistence, event-driven turn delivery/continuation, zero-config plugin discovery, and CLI launcher), four gaps must be closed:

1. **Same-folder lock collision in [`mesh_server.ts`](../pi-extension/src/mcp/mesh_server.ts)**:
   - [`_cmdRootInner`](../pi-extension/src/main.ts) acquires a per-`(cwd, name)` lock via `acquireCwdLock(cwd, candidate)` with `#2..#1000` auto-suffixing, then constructs `MeshNode({ name: lockedName, cwd: canonCwd })`.
   - [`mesh_server.ts`](../pi-extension/src/mcp/mesh_server.ts) constructs `MeshNode` before acquiring the lock and calls `acquireCwdLock(_cwd)` *without* the `name` argument. Because `roomIdFor(cwd, name)` hashes only `cwd` when `name` is omitted (or equals `basename(cwd)`), an `agy` session and a `pi` or `claude` session in the same folder collide on the lock and `mesh_server.ts` aborts after 4 attempts.
2. **Event-driven inbox delivery & turn continuation in `agy`**:
   - `notifications/claude/channel` is a Claude-specific MCP extension that `agy` ignores.
   - However, `agy` natively supports **Lifecycle Hooks** (`PreInvocation` with `injectSteps: [{ ephemeralMessage }]` and `Stop` with `{ decision: "continue", reason }`) as well as blocking MCP tool calls.
   - By maintaining a lightweight per-node inbox status file from `mesh_server.ts` and pairing it with an Antigravity hook script + a blocking `wait_for_message` MCP tool, `agy` achieves:
     - **Zero-token overhead when idle** (`PreInvocation` returns `{}` when `inbox.length === 0`).
     - **Automatic turn injection before any prompt** (`PreInvocation` injects an `ephemeralMessage` alerting `agy` to call `get_messages()` when `unreadCount > 0`).
     - **Automatic turn continuation when a peer replies mid-turn** (`Stop` hook intercepts `terminationReason === "NO_TOOL_CALL"` when `unreadCount > 0` and returns `decision: "continue"` so `agy` processes the newly arrived mesh message without stopping).
     - **Synchronous / subagent reply waiting** via `wait_for_message({ timeout_ms, from, re })` without busy-polling.
3. **Antigravity Native Plugin (`remote-pi-mesh`)**:
   - Unlike `claude --mcp-config`, `agy` discovers MCP servers, hooks, rules, and skills via its native plugin layout (`~/.gemini/config/plugins/remote-pi-mesh/` or `.agents/plugins/remote-pi-mesh/`).
   - Packaging a self-contained plugin (`plugin.json`, `mcp_config.json`, `hooks.json`, `scripts/mesh_hook.mjs`, `rules/AGENTS.md`, `skills/agent-network/SKILL.md`) makes the mesh available across both `remote-pi agy` and bare `agy` sessions.
4. **CLI Launcher & Fleet Integration (`remote-pi agy`)**:
   - Add `remote-pi agy [cwd] [agy-flags...]` in [`main.ts`](../pi-extension/src/main.ts) (mirroring `_cmdClaudeCli`), plus support for launching/resuming `agy` in terminal/fleet workflows.

---

## Expected Structure

```text
pi-extension/
  agy-plugin/
    plugin.json                        # Antigravity plugin manifest (name: "remote-pi-mesh")
    hooks.json                         # PreInvocation & Stop hooks invoking scripts/mesh_hook.mjs
    rules/
      AGENTS.md                        # Concise always-on mesh instructions for agy
    scripts/
      mesh_hook.mjs                    # Zero-dependency Node hook script reading inbox state files
  skills/
    agent-network/
      SKILL.md                         # Updated for pi, claude, and agy + wait_for_message / mesh_status
  src/
    mcp/
      inbox_state.ts                   # Per-session inbox state file writer/reader/cleanup for hooks
      inbox_state.test.ts              # Unit tests for inbox state persistence & workspace matching
      mesh_server.ts                   # Per-(cwd,name) #N lock, --auto-join, wait_for_message, mesh_status
      mesh_server.test.ts              # Unit tests for lock suffixing, wait_for_message, and inbox state
    session/
      agy_plugin.ts                    # Installer/renderer for ~/.gemini/config/plugins/remote-pi-mesh
      agy_plugin.test.ts               # Unit tests for plugin rendering & idempotent install
    main.ts                            # `remote-pi agy [cwd] [agy-flags...]` command & help entries
```

---

## Step 1 — Upgrade `mesh_server.ts` Lock Acquisition, Auto-Join & Tools

### Design
1. **Canonical `(cwd, name)` lock with `#N` collision fallback**:
   - Resolve `_canonCwd = canonicalizePath(_cwd)` first.
   - Determine base requested name:
     - Explicit `--name <name>` or `REMOTE_PI_MCP_NAME`
     - Or `localConfig?.name` from `.pi/remote-pi/config.json`
     - Or `path.basename(_canonCwd)` (or `REMOTE_PI_MCP_DEFAULT_NAME_PREFIX` if specified).
   - In `tryJoinMesh()`, acquire the lock using `acquireCwdLock(_canonCwd, candidate)` looping `n = 1..1000` (`candidate = n === 1 ? baseName : `${baseName}#${n}``), matching `_cmdRootInner` in [`main.ts`](../pi-extension/src/main.ts).
   - Construct `MeshNode({ name: lockedName, cwd: _canonCwd })` (or update `MeshNode` name before `join()`) only after the lock is acquired so `agy`, `pi`, and `claude` in the same folder automatically coexist as e.g. `remote_pi@remote_pi`, `remote_pi@agy` (or `remote_pi@remote_pi#2`).
2. **Auto-join support (`--auto-join` / `REMOTE_PI_MCP_AUTO_JOIN=1`)**:
   - When `--auto-join` or `REMOTE_PI_MCP_AUTO_JOIN=1` is set (used by `remote-pi agy` or global `agy` plugin), allow joining the local mesh even if `.pi/remote-pi/config.json` does not exist yet, unless an existing `.pi/remote-pi/config.json` explicitly sets `joinMesh: false`.
3. **New MCP tools in [`mesh_server.ts`](../pi-extension/src/mcp/mesh_server.ts)**:
   - `mesh_status({})`:
     - Returns JSON with `{ joined, name, cwd: _canonCwd, address: "<cwd>@<name>", role: mesh?.role, hasBridge: mesh?.hasBridge, unreadCount: inbox.length, peersCount }`.
   - `wait_for_message({ timeout_ms?: number, from?: string, re?: string })`:
     - Blocks up to `timeout_ms` (default `30000`, clamped to `1000..120000`) waiting for at least one matching message in `inbox`.
     - If matching message(s) are already in `inbox`, drains the matching message(s) immediately and returns `{ status: "received", messages: [...] }`.
     - Otherwise registers a waiter callback triggered by `mesh.onMessage`; on match, removes the message from `inbox`, updates the inbox state file, and resolves `{ status: "received", messages: [msg] }`. On timeout, returns `{ status: "timeout", messages: [] }`.

### Acceptance Criteria
- Multiple agents (`pi`, `claude`, `agy`) launched in the same directory simultaneously all join the mesh with distinct `<cwd>@<name>` / `<cwd>@<name>#N` addresses without `acquireCwdLock` aborting.
- `wait_for_message` resolves immediately when `inbox` is non-empty, wakes up within milliseconds when `mesh.onMessage` fires during the wait window, and times out cleanly otherwise.
- `mesh_status` reports the active node's canonical address, role (`leader` or `follower`), bridge status, and unread inbox count.

---

## Step 2 — Inbox State Sidecar & Antigravity Lifecycle Hooks (`PreInvocation` + `Stop`)

### Design
1. **Per-node Inbox State File (`pi-extension/src/mcp/inbox_state.ts`)**:
   - Directory: `~/.pi/piper/sessions/local/inbox/`
   - File per active MCP mesh node: `<roomIdFor(canonCwd, lockedName)>.json`
   - Schema:
     ```json
     {
       "pid": 12345,
       "cwd": "C:/Users/Alessandro/source/pi/packages/remote_pi",
       "name": "agy",
       "address": "C:/Users/Alessandro/source/pi/packages/remote_pi@agy",
       "unreadCount": 2,
       "updatedAt": 1730000000000,
       "preview": [
         { "id": "...", "from": "remote_pi@pi", "bodyPreview": "Can you check..." }
       ]
     }
     ```
   - Written atomically whenever `inbox` changes (`mesh.onMessage`, `get_messages`, `wait_for_message`) and unlinked in `shutdown()`.
   - Stale files whose `pid` is no longer alive (`process.kill(pid, 0)` check) are ignored and cleaned up by readers.
2. **Antigravity Hook Script (`pi-extension/agy-plugin/scripts/mesh_hook.mjs`)**:
   - Reads hook payload JSON from `stdin` (`hook_event_name`, `workspace_roots` / `cwd`, `terminationReason`, etc.).
   - Scans `~/.pi/piper/sessions/local/inbox/*.json` for live nodes matching the current workspace root (canonicalized path match or parent/child workspace match) with `unreadCount > 0`.
   - On **`PreInvocation`**:
     - If `unreadCount === 0`: outputs `{}` and exits `0` (zero prompt bloat).
     - If `unreadCount > 0`: outputs:
       ```json
       {
         "injectSteps": [
           {
             "ephemeralMessage": "📨 [remote-pi mesh] You have 1 unread mesh message(s) waiting (from remote_pi@pi). Call `get_messages` on the `remote-pi-mesh` MCP server to read and process them."
           }
         ]
       }
       ```
   - On **`Stop`**:
     - If `unreadCount > 0` (a message arrived while `agy` was executing its turn): outputs:
       ```json
       {
         "decision": "continue",
         "reason": "📨 [remote-pi mesh] 1 unread mesh message(s) arrived in your inbox (from remote_pi@pi). Call `get_messages` on the `remote-pi-mesh` MCP server now to handle them."
       }
       ```
     - Otherwise outputs `{}` and exits `0`.

### Acceptance Criteria
- When `inbox` is empty, `mesh_hook.mjs` outputs `{}` in `<15ms` for both `PreInvocation` and `Stop`.
- When a peer sends a message to `agy` via `agent_send`, the inbox state file reflects `unreadCount > 0`; `mesh_hook.mjs` emits `injectSteps` on `PreInvocation` and `decision: "continue"` on `Stop`.
- Once `agy` calls `get_messages` or `wait_for_message`, `unreadCount` resets to `0` and subsequent hooks return `{}`.
- On `mesh_server` shutdown, the inbox state file is removed.

---

## Step 3 — Package & Auto-Install the `remote-pi-mesh` Antigravity Plugin

### Design
1. **Plugin Template (`pi-extension/agy-plugin/`)**:
   - `plugin.json`:
     ```json
     {
       "name": "remote-pi-mesh",
       "version": "0.1.0",
       "description": "First-class remote-pi agent mesh integration for Google Antigravity (agy)"
     }
     ```
   - `mcp_config.json` (rendered at install time with absolute paths to `process.execPath` and `dist/mcp/mesh_server.js`):
     ```json
     {
       "mcpServers": {
         "remote-pi-mesh": {
           "command": "<node-exec-path>",
           "args": ["<dist/mcp/mesh_server.js>", "--auto-join"],
           "env": {
             "REMOTE_PI_MCP_NAME": "agy",
             "REMOTE_PI_MCP_AUTO_JOIN": "1"
           }
         }
       }
     }
     ```
   - `hooks.json` (rendered with the absolute path to `scripts/mesh_hook.mjs` under `~/.gemini/config/plugins/remote-pi-mesh/scripts/mesh_hook.mjs`):
     - Registers `PreInvocation` and `Stop` command hooks (`timeout: 5`).
   - `rules/AGENTS.md`: concise mesh usage rules for `agy` (how to discover peers with `list_peers`, check identity with `mesh_status`, send messages with `agent_send`, drain inbox with `get_messages`, and wait for replies with `wait_for_message`).
   - `skills/agent-network/SKILL.md`: synced from `pi-extension/skills/agent-network/SKILL.md`, updated to document `agy`, `claude`, and `pi` workflows.
2. **Installer helper (`pi-extension/src/session/agy_plugin.ts`)**:
   - `ensureAgyMeshPluginInstalled(options?)`: idempotently installs/updates `~/.gemini/config/plugins/remote-pi-mesh/` whenever `remote-pi agy` (or `remote-pi install`) runs.
   - Respects `AGY_CONFIG_DIR` or defaults to `~/.gemini/config`.

### Acceptance Criteria
- Running `ensureAgyMeshPluginInstalled()` populates `~/.gemini/config/plugins/remote-pi-mesh/` with valid `plugin.json`, `mcp_config.json`, `hooks.json`, `scripts/mesh_hook.mjs`, `rules/AGENTS.md`, and `skills/agent-network/SKILL.md`.
- `agy plugin list` / `agy` session startup recognizes `remote-pi-mesh` and exposes `list_peers`, `agent_send`, `get_messages`, `wait_for_message`, and `mesh_status`.

---

## Step 4 — CLI Command `remote-pi agy` (`main.ts`)

### Design
1. Add `_cmdAgyCli(rawArgs: string[])` in [`pi-extension/src/main.ts`](../pi-extension/src/main.ts), mirroring `_cmdClaudeCli`:
   - Parses optional `[cwd]` positional argument and forwards all remaining flags (`-i`, `-p`, `--mode`, `--model`, `--continue`, etc.) to `agy`.
   - Runs first-time local config prompt (`promptFirstTimeSetup(absCwd)`) if `.pi/remote-pi/config.json` does not exist and stdin is a TTY.
   - Calls `ensureAgyMeshPluginInstalled()` so the `remote-pi-mesh` plugin in `~/.gemini/config/plugins/remote-pi-mesh/` is always up to date with the current `dist/mcp/mesh_server.js` build.
   - Spawns `agy` in `absCwd` with environment variables:
     - `REMOTE_PI_MCP_CWD = absCwd`
     - `REMOTE_PI_MCP_NAME = localConfig?.name ?? "agy"`
     - `REMOTE_PI_MCP_AUTO_JOIN = "1"`
2. Wire `remote-pi agy` into `runCli()` dispatch and `--help` output in [`main.ts`](../pi-extension/src/main.ts).

### Acceptance Criteria
- `remote-pi agy` launches `agy` in the target directory with the `remote-pi-mesh` plugin active and joins the mesh under `<absCwd>@<name>`.
- `remote-pi --help` documents `remote-pi agy [cwd] [agy-flags...]`.
- Bidirectional `agent_send` works between:
  - `pi` ↔ `agy`
  - `claude` ↔ `agy`
  - `agy` ↔ `agy` (both local UDS/Named Pipe and cross-machine Relay `BrokerRemote`).

---

## Definition of Done (DoD)

- [x] `mesh_server.ts` uses per-`(cwd, name)` lock acquisition with `#2..#1000` collision suffixing, supports `--auto-join` / `REMOTE_PI_MCP_AUTO_JOIN=1`, and exposes `wait_for_message` and `mesh_status`.
- [x] `inbox_state.ts` persists per-node unread inbox counts and cleans up on shutdown or stale PID detection.
- [x] `pi-extension/agy-plugin/` provides `plugin.json`, `hooks.json`, `scripts/mesh_hook.mjs` (`PreInvocation` ephemeral injection + `Stop` continuation), `rules/AGENTS.md`, and `skills/agent-network/SKILL.md`.
- [x] `agy_plugin.ts` installs/updates `~/.gemini/config/plugins/remote-pi-mesh/` idempotently.
- [x] `remote-pi agy [cwd] [agy-flags...]` is implemented in `main.ts` and documented in CLI help and `SKILL.md`.
- [x] Unit tests (`inbox_state.test.ts`, `mesh_server.test.ts`, `agy_plugin.test.ts`) and `npm run build` + `npm test` pass in `pi-extension/`.

## Next Plans
- **Plan 155**: Fleet dashboard & Android app launcher actions for spawning/attaching `agy` sessions remotely (`open_terminal` / daemon fleet commands).
