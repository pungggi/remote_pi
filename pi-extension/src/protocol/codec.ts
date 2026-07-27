import type { ClientMessage, ServerMessage } from "./types.js";

const SERVER_TYPES = new Set<ServerMessage["type"]>([
  "pair_ok",
  "pair_error",
  "user_input",
  "queued_message_state",
  "agent_chunk",
  "agent_done",
  "agent_message",
  "tool_request",
  "tool_result",
  "error",
  "cancelled",
  "pong",
  "bye",
  "session_history",
  // Plan/100 — interactive extension prompt (ask_user via pi-ask).
  "extension_ui_request",
  // Plan/107 — on-demand git status reply for the session-info dialog.
  "git_status_result",
  // Plan/108 — terminal-launch reply (remote `/ps clone`).
  "open_terminal_result",
  // Plan/112 — worktree tracking replies (list / remove).
  "list_worktrees_result",
  "remove_worktree_result",
]);

export class DecodeError extends Error {
  constructor(
    public readonly code: "invalid_message" | "unsupported_type",
    message: string,
  ) {
    super(message);
    this.name = "DecodeError";
  }
}

export function encodeClient(msg: ClientMessage): string {
  return JSON.stringify(msg) + "\n";
}

export function decodeServer(line: string): ServerMessage {
  let obj: unknown;
  try {
    obj = JSON.parse(line.trim());
  } catch (e) {
    throw new DecodeError("invalid_message", `not JSON: ${(e as Error).message}`);
  }
  if (
    !obj ||
    typeof obj !== "object" ||
    typeof (obj as Record<string, unknown>).type !== "string"
  ) {
    throw new DecodeError("invalid_message", "missing 'type'");
  }
  const t = (obj as Record<string, unknown>).type as string;
  if (!SERVER_TYPES.has(t as ServerMessage["type"])) {
    throw new DecodeError("unsupported_type", `unknown type: ${t}`);
  }
  return obj as ServerMessage;
}
