# Plan 155 — Antigravity Native Sidecar & AgentAPI Real-Time Wakeup

## Context

Plan 154 established Google Antigravity (`agy`) as a first-class citizen of the `remote-pi` agent mesh:
- Multi-agent lock acquisition with per-`(cwd, name)` `#N` suffixing ([`cwd_lock.ts`](../pi-extension/src/session/cwd_lock.ts))
- MCP tools: `list_peers`, `agent_send`, `get_messages`, `wait_for_message`, and `mesh_status` ([`mesh_server.ts`](../pi-extension/src/mcp/mesh_server.ts))
- Lifecycle hooks ([`mesh_hook.mjs`](../pi-extension/agy-plugin/scripts/mesh_hook.mjs)): `PreInvocation` injects unread counts; `Stop` continues active turns when unread messages arrive.

### The Remaining Gap: Idle Reactivity
When an `agy` session completes its turn, it returns to the interactive terminal prompt (`> `) and goes completely idle. When a peer agent sends a message (e.g. `agent_send body='{"event":"pr-merged"}'`), the message is safely queued in the local inbox file (`~/.pi/piper/sessions/local/inbox/<roomId>.json`), but `agy` does **not** wake up until the human user manually types a prompt.

While a background `mesh-listener` subagent can trigger Antigravity's **Reactive Wakeup**, subagents are session-scoped and get terminated if the language server restarts, if settings change, or if not persistently re-armed after each turn.

### The Solution: Native Antigravity Sidecar + `agentapi send-message`
Antigravity features a built-in background daemon mechanism called **Sidecars** (`sidecar.json`).
- Sidecars are background processes whose lifecycle is managed directly by Antigravity (`restart_policy: "always"` ensures continuous uptime across model switches and server restarts).
- In a sidecar environment, Antigravity injects `ANTIGRAVITY_LS_ADDRESS`, `ANTIGRAVITY_CSRF_TOKEN`, and the **`agentapi`** CLI tool into the process environment.
- The `agentapi` CLI tool provides:
  ```bash
  agentapi send-message [--title=<title>] <conversation_id> <content>
  agentapi new-conversation [--model=<model>] <prompt>
  agentapi get-conversation-metadata <conversation_id>
  ```
- By packaging a lightweight **`mesh-watcher`** sidecar inside `remote-pi-mesh`:
  1. The sidecar runs continuously in the background (restarted automatically by Antigravity).
  2. It watches `~/.pi/piper/sessions/local/inbox/` for new incoming messages.
  3. When an envelope arrives for an active workspace, it looks up the workspace's active `conversationId` and invokes `agentapi send-message <conversationId> ...`.
  4. Antigravity injects the message directly into the session's prompt queue, **waking the agent immediately from idle with zero user intervention**.

---

## Expected Structure

```text
pi-extension/
  agy-plugin/
    plugin.json                                # Updated with sidecars component declaration
    sidecars/
      mesh-watcher/
        sidecar.json                           # Antigravity sidecar configuration ("command": "node", "args": ["watcher.mjs"])
        watcher.mjs                            # Zero-dependency Node daemon: watches inboxes and executes agentapi send-message
    scripts/
      mesh_hook.mjs                            # Records conversationId <-> workspace mapping on hook invocations
  skills/
    agent-network/
      SKILL.md                                 # Documents sidecar-driven autonomous wakeup for agy
  src/
    session/
      conversation_registry.ts                 # Workspace <-> active conversationId registry writer/reader/cleaner
      conversation_registry.test.ts            # Unit tests for conversation registry mapping and stale PID pruning
      agy_plugin.ts                            # Updated installer deploying sidecars to ~/.gemini/config/plugins/remote-pi-mesh/sidecars/
      agy_plugin.test.ts                       # Unit tests for sidecar template rendering and file deployment
```

---

## Step 1 — Workspace to Conversation ID Registry

### Design
1. **Registry Directory & Schema**:
   - Location: `~/.pi/piper/sessions/local/conversations/`
   - File per active conversation: `<conversationId>.json`
   - Content:
     ```json
     {
       "conversationId": "f550dfa1-9420-40f1-a017-7f69b94ccaef",
       "workspacePath": "C:/Users/Alessandro/source/pi/packages/remote_pi",
       "pid": 25548,
       "updatedAt": 1730000000000
     }
     ```
2. **Hook Tracking (`mesh_hook.mjs`)**:
   - Every Antigravity hook invocation (`SessionStart`, `PreInvocation`, `Stop`) receives `conversationId` and `workspacePaths` / `cwd`.
   - `mesh_hook.mjs` updates `~/.pi/piper/sessions/local/conversations/<conversationId>.json` with the current PID and normalized workspace path.
3. **Lookup & Cleanup (`conversation_registry.ts`)**:
   - `findConversationForWorkspace(workspacePath)`: scans the directory for live records matching the canonical workspace path whose PID is still alive.
   - Automatically unlinks records whose PID has exited.

### Acceptance Criteria
- Starting an `agy` session records its `conversationId` and `workspacePath` in `~/.pi/piper/sessions/local/conversations/`.
- Dead conversation records are automatically pruned when their PID is no longer alive.
- Multiple conversations in different workspaces are tracked independently without collisions.

---

## Step 2 — The `mesh-watcher` Sidecar Daemon

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
2. **Watcher Implementation (`pi-extension/agy-plugin/sidecars/mesh-watcher/watcher.mjs`)**:
   - Executed by Antigravity with `ANTIGRAVITY_LS_ADDRESS`, `ANTIGRAVITY_CSRF_TOKEN`, and `agentapi` available on PATH.
   - Watches `~/.pi/piper/sessions/local/inbox/*.json` using `fs.watch` with a 100ms debounce.
   - When an inbox state file changes and has `unreadCount > 0`:
     - Reads the inbox record (`cwd`, `name`, `address`, `preview`).
     - Looks up the active `conversationId` for `cwd` via `findConversationForWorkspace(cwd)`.
     - Checks a memory debounce cache (`lastWokenMessageId`) to prevent duplicate prompts for the same message ID.
     - Formats a clear notification:
       ```text
       📨 [remote-pi mesh] Incoming message from <preview.from>:
       "<preview.bodyPreview>"
       Call `get_messages` on the `remote-pi-mesh` MCP server to process it.
       ```
     - Invokes `agentapi send-message <conversationId> <notification>` (using `ANTIGRAVITY_AGENTAPI_EXE` or `agentapi`).
     - If no conversation is currently open for that workspace, optionally invokes `agentapi new-conversation` (gated by config `auto_create_conversation: false` by default).

### Acceptance Criteria
- When an inbox record transitions to `unreadCount > 0` while `agy` is sitting idle at the prompt, `watcher.mjs` executes `agentapi send-message` within <500ms.
- Antigravity immediately opens a new turn with the injected notification.
- In-turn and duplicate messages are debounced and do not trigger duplicate calls.
- If the sidecar crashes or is killed, Antigravity automatically restarts it (`restart_policy: "always"`).

---

## Step 3 — Plugin Bundling & Auto-Installation

### Design
1. **Packaging**:
   - Store the sidecar template in `pi-extension/agy-plugin/sidecars/mesh-watcher/`.
   - Update [`ensureAgyMeshPluginInstalled`](../pi-extension/src/session/agy_plugin.ts) to copy `sidecars/` into `~/.gemini/config/plugins/remote-pi-mesh/sidecars/`.
   - Also register in global `~/.gemini/config/sidecars/remote-pi-mesh/sidecar.json` if required by the Antigravity runtime version.
2. **Plugin Manifest Update (`plugin.json`)**:
   - Declare the sidecar component in `plugin.json` so `agy plugin list` reports:
     ```text
     - remote-pi-mesh (enabled, 0.8.0)
         Components: 1 skill, 1 rule, 1 MCP server, 1 hook, 1 sidecar
     ```

### Acceptance Criteria
- Running `remote-pi agy --install-plugin` (or launching `remote-pi agy`) installs `sidecars/mesh-watcher/sidecar.json` and `watcher.mjs`.
- `agy plugin list` enumerates the sidecar component.
- Unit tests verify idempotent installation and valid JSON schema generation.

---

## Step 4 — Verification & End-to-End Testing

1. **Unit Testing**:
   - `conversation_registry.test.ts`: verify conversation recording, workspace resolution, and dead PID pruning.
   - `agy_plugin.test.ts`: verify sidecar deployment and manifest generation.
2. **Live Mesh Integration Testing**:
   - Launch an `agy` session in `remote_pi` and leave it idle at the prompt (`> `).
   - In a separate terminal (Pi or another Agy instance), run:
     ```text
     agent_send to="C:\Users\Alessandro\source\pi\packages\remote_pi@agy" body="ping"
     ```
   - **Verification**: `agy` starts a new turn automatically within 1-2 seconds with the prompt injected by `agentapi send-message`, calls `get_messages`, and replies without any user typing!

---

## Definition of Done (DoD)

- [ ] `conversation_registry.ts` tracks active conversation IDs by workspace and unlinks stale records on exit.
- [ ] `mesh_hook.mjs` records conversation IDs on every hook invocation.
- [ ] `pi-extension/agy-plugin/sidecars/mesh-watcher/` provides `sidecar.json` and `watcher.mjs`.
- [ ] `ensureAgyMeshPluginInstalled` in `agy_plugin.ts` installs the sidecar into the user configuration.
- [ ] Unit tests pass via `vitest`.
- [ ] Live end-to-end idle wakeup verified from Pi to an idle `agy` terminal.

## Next Plans
- **Plan 156**: Cockpit & mobile app UI notifications for incoming mesh requests targeting background `agy` daemons.
