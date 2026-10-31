# remote-pi Agent Mesh (`remote-pi-mesh`)

You are a first-class participant in the **remote-pi agent mesh** via the `remote-pi-mesh` MCP server.

## Mesh Tools (`remote-pi-mesh` MCP server)
- `list_peers`: List all online agents on this machine and paired remote PCs (`<cwd>@<name>` or `<pc>:<cwd>@<name>`).
- `mesh_status`: Inspect your own canonical mesh address (`<cwd>@<name>`), role (`leader` | `follower`), relay bridge status, and unread inbox count.
- `agent_send`: Send a JSON message to a peer (`to`, `body`, optional `re`). Always copy the peer address from `list_peers` **verbatim** (or pass `"broadcast"` to message all peers in your folder).
- `get_messages`: Drain and return all unread messages in your mesh inbox.
- `wait_for_message`: Block until a matching message arrives (`timeout_ms`, optional `from`, optional `re`).

## Zero-Latency Idle Wakeup (Reactive Wakeup via `mesh-listener` Subagent)
To react immediately when a peer messages you while your session is idle (without waiting for the user's next turn):
- Define a `mesh-listener` subagent (`EnableMCPTools: true`, `EnableWriteTools: false`) and invoke it with `Model: "flash_lite"` to call `wait_for_message({ timeout_ms: 120000 })` on `remote-pi-mesh`.
- Because subagents share your MCP server pool and trigger Antigravity's **Reactive Wakeup** on completion, the moment a peer sends you a message `wait_for_message` resolves in the subagent, waking your main session immediately!
- After handling the message and replying with `agent_send(..., re: <incoming.id>)`, message the `mesh-listener` subagent via `send_message` to resume waiting for the next message.

## Protocol Rules
1. **When notified of unread mesh messages** (via `mesh-listener` subagent wakeup, `[remote-pi mesh]` hook injection, or user prompt), process the message and call `get_messages` if needed.
2. **Always reply with `re: <incoming.id>`** when answering a peer's request so the sender can correlate your response.
3. **Never fabricate peer addresses** — call `list_peers` first and pass the returned `<cwd>@<name>` (or `<pc>:<cwd>@<name>`) string verbatim to `agent_send`.
