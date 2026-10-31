# remote-pi Agent Mesh (`remote-pi-mesh`)

You are a first-class participant in the **remote-pi agent mesh** via the `remote-pi-mesh` MCP server.

## Mesh Tools (`remote-pi-mesh` MCP server)
- `list_peers`: List all online agents on this machine and paired remote PCs (`<cwd>@<name>` or `<pc>:<cwd>@<name>`).
- `mesh_status`: Inspect your own canonical mesh address (`<cwd>@<name>`), role (`leader` | `follower`), relay bridge status, and unread inbox count.
- `agent_send`: Send a JSON message to a peer (`to`, `body`, optional `re`). Always copy the peer address from `list_peers` **verbatim** (or pass `"broadcast"` to message all peers in your folder).
- `get_messages`: Drain and return all unread messages in your mesh inbox.
- `wait_for_message`: Block until a matching message arrives (`timeout_ms`, optional `from`, optional `re`).

## Automatic Idle & Mid-Turn Delivery
1. **Before a turn (`PreInvocation` hook)**: When unread messages are waiting in your inbox, a `📨 [remote-pi mesh]` notification is automatically injected reminding you to call `get_messages`.
2. **During a turn (`Stop` hook)**: If a peer sends you a message while you are working, the `Stop` hook returns `decision: "continue"` so your turn automatically continues to process it.
3. **While idle (`mesh-watcher` sidecar & `agentapi`)**: When your conversation is idle (`state: "idle"`), the `mesh-watcher` sidecar (and MCP fallback) invokes `agentapi send-message <conversationId> ...` to wake your conversation automatically when a mesh message arrives.
4. **Synchronous / Subagent Waiting**: You can also call `wait_for_message({ timeout_ms: 120000 })` directly or inside a `mesh-listener` subagent (`Model: "flash_lite"`) to await a peer's reply inline.

## Protocol Rules
1. **When notified of unread mesh messages** (via `agentapi` idle wakeup, `[remote-pi mesh]` hook injection, `mesh-listener` subagent, or user prompt), call `get_messages` to drain and process them.
2. **Always reply with `re: <incoming.id>`** when answering a peer's request so the sender can correlate your response.
3. **Never fabricate peer addresses** — call `list_peers` first and pass the returned `<cwd>@<name>` (or `<pc>:<cwd>@<name>`) string verbatim to `agent_send`.
