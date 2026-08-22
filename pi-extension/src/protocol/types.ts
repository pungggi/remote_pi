export type PairErrorCode =
  | "token_expired"
  | "token_consumed"
  | "token_unknown"
  | "internal_error";

/** Plan/127 — delivery mode for a user_message while the room is working.
 *  `"steer"` injects into the active streaming turn (a mid-flight correction);
 *  `"followUp"` queues the message to start a fresh turn after the current
 *  one ends. Omitted entirely on idle sends (a normal fresh turn). */
export type StreamingBehavior = "steer" | "followUp";

export type QueuedMessageItem = {
  id: string;
  text: string;
  editable: boolean;
  created_at: number;
};

// ── Plan/100 — extension_ui_request bridge (mirror SDK RPC contract) ───────
// The paired app renders interactive extension prompts (ask_user today, via
// @eko24ive/pi-ask) natively instead of stranding the mobile user. The wire
// mirrors the SDK's `pi --mode rpc` extension_ui_request/response contract
// (RpcExtensionUIRequest/Response in dist/modes/rpc/rpc-types.d.ts) so the
// mobile app and the Cockpit share one interactive-UI vocabulary. Casing is
// snake_case to match the rest of the relay protocol (mirror is semantic, not
// literal). pi-ask's richer schema (multi/preview/notes) rides in an optional
// `ask` envelope; strict clients ignore it. Inert when pi-ask is absent.

export type ExtensionUiMethod =
  | "select"
  | "confirm"
  | "input"
  | "editor"
  | "notify";

export type AskQuestionWireType = "single" | "multi" | "preview";

export interface AskOptionWire {
  value: string;
  label: string;
  description?: string;
  /** Preview-pane content (preview questions only). */
  preview?: string;
  /** pi-ask addition: option allows freeform custom entry. */
  freeform?: boolean;
  /** pi-ask 1.2.0 addition: presentation-only marker (never affects submit). */
  recommended?: boolean;
}

export interface AskQuestionWire {
  id: string;
  label: string;
  prompt: string;
  type: AskQuestionWireType;
  required: boolean;
  /** pi-ask addition: type actually presented after live toggle / policy. */
  presentedType?: AskQuestionWireType;
  /** pi-ask addition: type originally requested by the model. */
  requestedType?: AskQuestionWireType;
  options: AskOptionWire[];
}

/** Optional pi-ask enrichment on an extension_ui_request — lets the app render
 *  the full flow (multi/preview/notes) instead of the degraded SDK select. A
 *  flow maps to ONE request carrying every question; the app renders a
 *  full-screen modal and submits ONE response with all answers (pi-ask resolves
 *  a flow in a single submit). When `ask` is absent the SDK method/options
 *  drive rendering (future generic prompts). */
export interface AskEnrichmentWire {
  flow_id: string;
  tool_call_id: string | null;
  /** pi-ask RemoteAskSource: "tool" | "answer" | "answer:again" | "ask:replay". */
  source: string;
  title: string | null;
  questions: AskQuestionWire[];
}

/** pi-ask RemoteAskAnswer — one question's answered parts.
 *
 *  CASING EXCEPTION: inside the `ask` envelope the keys mirror pi-ask's own
 *  schema VERBATIM (camelCase: `presentedType`, `requestedType`, `customText`,
 *  `optionNotes`) so the bridge can forward the response to pi-ask's submit
 *  event without a remap pass. The snake_case convention of this protocol
 *  applies at the frame level (`flow_id`, `tool_call_id`, `notify_type`). */
export interface AskAnswerWire {
  values?: string[];
  customText?: string;
  note?: string;
  optionNotes?: Record<string, string>;
}

/** Optional pi-ask enrichment on an extension_ui_response — carries the
 *  structured answer so multi/preview/notes survive the round-trip. */
export type AskResponseEnrichmentWire =
  | {
      flow_id: string;
      kind: "answer";
      mode?: "submit" | "elaborate";
      answers: Record<string, AskAnswerWire>;
    }
  | { flow_id: string; kind: "cancel" };

/** ServerMessage: interactive extension prompt. Mirrors RpcExtensionUIRequest
 *  (select/confirm/input/editor/notify). The `ask` envelope is present when the
 *  prompt originates from a pi-ask flow, carrying the full question schema. */
export type ExtensionUiRequestWire =
  | {
      type: "extension_ui_request";
      id: string;
      method: "select";
      title: string;
      options: string[];
      ask?: AskEnrichmentWire;
    }
  | {
      type: "extension_ui_request";
      id: string;
      method: "confirm";
      title: string;
      message: string;
      ask?: AskEnrichmentWire;
    }
  | {
      type: "extension_ui_request";
      id: string;
      method: "input";
      title: string;
      placeholder?: string;
      ask?: AskEnrichmentWire;
    }
  | {
      type: "extension_ui_request";
      id: string;
      method: "editor";
      title: string;
      prefill?: string;
      ask?: AskEnrichmentWire;
    }
  | {
      type: "extension_ui_request";
      id: string;
      method: "notify";
      message: string;
      notify_type?: "info" | "warning" | "error";
    };

/** ClientMessage: response to an extension_ui_request. Mirrors
 *  RpcExtensionUIResponse (value / confirmed / cancelled). The `ask` envelope
 *  carries pi-ask's structured answer when the app rendered the rich flow. */
export type ExtensionUiResponseWire =
  | {
      type: "extension_ui_response";
      id: string;
      value: string;
      ask?: AskResponseEnrichmentWire;
    }
  | {
      type: "extension_ui_response";
      id: string;
      confirmed: boolean;
      ask?: AskResponseEnrichmentWire;
    }
  | {
      type: "extension_ui_response";
      id: string;
      cancelled: true;
      ask?: AskResponseEnrichmentWire;
    }
  // Rich pi-ask answer: a client that rendered the full flow from the `ask`
  // envelope submits ONLY the envelope — no value/confirmed/cancelled
  // discriminator (the structured `answers` supersede them). This is the
  // shape the app actually sends for rich submits; routing keys off
  // `ask.kind` before any discriminator is read.
  | {
      type: "extension_ui_response";
      id: string;
      ask: AskResponseEnrichmentWire;
    };

export type ClientMessage =
  | { type: "pair_request"; id: string; token: string; device_name: string }
  // Plan/30: optional `images` carry inline base64 attachments (one today).
  // Omitted entirely on text-only messages — the no-image path is unchanged.
  | {
      type: "user_message";
      id: string;
      text: string;
      images?: WireImage[];
      streaming_behavior?: StreamingBehavior;
      /** Plan/109 — one-shot model override: send THIS message with a
       *  different model without changing the session default. The Pi
       *  extension switches the live model, injects the message, then
       *  reverts on turn_end. Omitted on the normal send path. */
      model?: { provider: string; id: string };
    }
  | { type: "queued_message_set"; id: string; text: string }
  | { type: "queued_message_clear"; id: string; target_id?: string }
  | { type: "approve_tool"; id: string; tool_call_id: string; decision: "allow" | "deny" }
  | { type: "cancel"; id: string; target_id: string }
  | { type: "ping"; id: string }
  // Plan/128 — `before` is an opaque backward cursor (the app threads the
  // `next_before` it received). Omitted ⇒ newest N (legacy shape). The
  // server now honors `limit` up to a payload-guard max instead of clamping
  // to the old 30-event window.
  | { type: "session_sync"; id: string; limit?: number; before?: string }
  // Plan/28 — Typed app actions on the paired Pi session. Each carries a
  // structured payload (no string parsing) and gets either `action_ok` or
  // `action_error` back. Visible side-effects (chat output, model change
  // broadcasts, compaction notice) still flow through the normal channels.
  | { type: "session_new"; id: string }
  | { type: "session_compact"; id: string }
  | { type: "model_set"; id: string; provider: string; model_id: string }
  | { type: "thinking_set"; id: string; level: ThinkingLevel }
  | { type: "list_models"; id: string }
  // Plan/107 — on-demand git status snapshot for the session-info dialog.
  // The Pi runs `git status --porcelain=2 --branch` in the session cwd and
  // replies with `git_status_result` (status null when not a git repo).
  | { type: "git_status_request"; id: string }
  // Plan/108 — open a new terminal tab at a project folder (remote `/ps
  // clone`). `cwd` optional (null/omitted → use the session cwd); `runPi`
  // default true launches `pi` in the new tab (plain shell when false).
  // Plan/112 — `worktree_path` reopens an existing tracked worktree (skip
  // creation, just open a terminal there); mutually exclusive with spawning
  // a new one.
  | {
      type: "open_terminal_request";
      id: string;
      cwd?: string | null;
      runPi?: boolean;
      worktree_path?: string | null;
      /** Plan/112b — name for the new worktree's git branch. Validated with
       *  `git check-ref-format`; also drives the worktree folder name
       *  (`<basename>_<sanitized>`). Falls back to `work/<stamp>` when null. */
      branch?: string | null;
    }
  // Plan/112 — worktree tracking: list tracked worktrees (optionally
  // filtered by base repo path) and remove one by id.
  | { type: "list_worktrees_request"; id: string; base?: string | null }
  | { type: "remove_worktree_request"; id: string; worktree_id: string }
  // Plan/121 — list git projects discovered under the configured roots
  // (served by the always-on device daemon so the phone can show a Projects
  // list with no live pi). The chosen project is then spawned as a worktree
  // via open_terminal_request.
  | { type: "list_projects_request"; id: string }
  // api.changeLayout — apply a NAMED `.ckp` layout on the PC (Cockpit
  // orchestration). The daemon resolves `layout` (a plain basename, no
  // extension) to a `.ckp` under the configured projects roots and runs the
  // Cockpit CLI's `orchestrate` verb; see actions/change_layout.ts.
  | { type: "change_layout_request"; id: string; layout: string }
  // Plan/124 — bring an offline session back to life in its OWN cwd (no new
  // worktree, no pin). The device daemon asks the supervisor to spawn a
  // transient `pi --mode rpc --continue` at `cwd`; `--continue` resumes the
  // existing conversation and the room re-announces, flipping the tile live.
  // `name` scopes the room for custom-named sessions (omit/default → legacy
  // cwd-only room).
  | { type: "start_session_request"; id: string; cwd: string; name?: string | null }
  // Plan/100 — interactive extension prompt response (ask_user via pi-ask).
  // Mirrors RpcExtensionUIResponse; the optional `ask` envelope carries
  // pi-ask's structured answer so multi/preview/notes survive the round-trip.
  | ExtensionUiResponseWire;

/**
 * Plan/30 — one inline image attachment on a `user_message`. Mirrors the
 * SDK's `ImageContent` ({@link https }) split across the wire: `data` is the
 * base64-encoded (compressed) image bytes, `mime` its content type
 * (e.g. `"image/jpeg"`). The Pi maps `{ data, mime }` → the SDK's
 * `{ type:"image", data, mimeType }` before handing it to the model.
 */
export interface WireImage {
  /** Base64-encoded image bytes (compressed app-side). */
  data: string;
  /** MIME type, e.g. `"image/jpeg"`. Maps to the SDK's `mimeType`. */
  mime: string;
}

export type Usage = { input_tokens: number; output_tokens: number };

export type KnownErrorCode =
  | "tool_approval_required"
  | "invalid_message"
  | "unsupported_type"
  | "too_large"
  | "rate_limited"
  | "timeout"
  | "internal_error";

// aberto para forward-compat — receivers toleram codes desconhecidos
export type ErrorCode = KnownErrorCode | (string & {});

export type SessionHistoryEvent =
  // Plan/30: `images` replayed in history so a re-sync rebuilds the image
  // bubble (the bytes live in `_messageBuffer`). Omitted on text-only inputs.
  | { ts: number; type: "user_input"; id: string; text: string; images?: WireImage[] }
  | {
      ts: number;
      type: "tool_request";
      tool_call_id: string;
      tool: string;
      args: Record<string, unknown>;
    }
  | {
      ts: number;
      type: "tool_result";
      tool_call_id: string;
      result?: unknown;
      error?: string;
    }
  | {
      ts: number;
      type: "agent_message";
      in_reply_to: string;
      text: string;
      usage?: Usage;
    }
  // Plan/32: a context-compaction marker, replayed in history (survives
  // re-sync like images) so the app re-renders the "context compacted" notice.
  | { ts: number; type: "compaction"; summary: string; tokens_before: number };

export type ServerMessage =
  | {
      type: "pair_ok";
      in_reply_to: string;
      session_name: string;
      session_started_at: number;
      room_id: string;
      /**
       * Plan/27 Wave A: identifies the host coding agent driving this
       * pi-extension instance. `name` is hardcoded to "Pi coding agent"
       * today; future Pi forks (Claude Code, OpenCode) populate their own
       * here. `version` is the pi-extension `package.json` version.
       * Optional in the wire schema so app-side parsing tolerates older
       * Pi builds that predate this field — every new pairing emits both.
       */
      harness?: { name: string; version: string };
      /**
       * Plan/27 Wave A: `os.hostname()` of the machine the Pi runs on.
       * App displays it in the device list so the user can distinguish
       * two paired PCs that happen to share a nickname or sit in the
       * same project folder.
       */
      hostname?: string;
    }
  | { type: "pair_error"; in_reply_to: string; code: PairErrorCode; message: string }
  | { type: "user_input"; id: string; text: string; streaming_behavior?: StreamingBehavior }
  // Echo of an app-originated user_message, broadcast by the Pi to every
  // connected owner (including the sender). Source-of-truth model: each
  // app waits for this echo to render the message it sent, so all owners
  // see the same session timeline regardless of who typed.
  // Field shape mirrors the inbound ClientMessage `user_message` exactly,
  // and `id` is the sender-provided id — Pi never re-generates it (lets
  // future dedup logic use id as a stable key). See plan/24 W2D fix.
  // Plan/30: `images` echoed back so every owner renders the same image bubble.
  | {
      type: "user_message";
      id: string;
      text: string;
      images?: WireImage[];
      streaming_behavior?: StreamingBehavior;
      /** Plan/109 — echoed so other owners see the one-shot override model. */
      model?: { provider: string; id: string };
    }
  | { type: "queued_message_state"; id?: string; text?: string; items?: QueuedMessageItem[] }
  | { type: "steer_consumed"; id: string }
  | { type: "agent_chunk"; in_reply_to: string; delta: string }
  // Reconciliation fallback (2026-08-22, "final answer never renders"): `text`
  // carries the turn's CUMULATIVE streamed text (same accumulator the daemon
  // replays for mid-run attaches — `_turnText`). Omitted when the turn
  // produced no text (tool-only turns). Receivers that streamed the turn live
  // use it only to heal a lost TAIL (their local text must be a prefix); it
  // is authoritative for nothing else — session_history remains the replay
  // source of truth.
  | { type: "agent_done"; in_reply_to: string; usage?: Usage; text?: string }
  | { type: "agent_message"; in_reply_to: string; text: string; usage?: Usage }
  // Plan/114 — image the agent pushes to the user from a file in the repo.
  // Triggered by the `show_image` tool (see src/index.ts `_registerShowImageTool`).
  // The bytes travel inline base64 to every connected owner so each device
  // renders the same bubble + viewer; the tool_result back to the model carries
  // ONLY metadata (never bytes) — same context-hygiene discipline as plan/49.
  // Relay is unchanged (opaque `ct`); `agent_image` is a live broadcast, not
  // replayed via `session_history` (plan/114 risk #2). Anchored to the turn via
  // `in_reply_to` like `agent_chunk`/`agent_done`.
  | {
      type: "agent_image";
      id: string;
      in_reply_to: string;
      image: WireImage;
      /** Repo path the agent read from (display only). */
      path?: string;
      /** Optional caption shown under the bubble and as the viewer title. */
      caption?: string;
      width?: number;
      height?: number;
    }
  // Plan/126 — a document the agent pushes to the user from a file in the repo
  // (Markdown / text / PDF / HTML). Triggered by the `show_file` tool (see
  // src/index.ts `_registerShowFileTool`). Same discipline as `agent_image`:
  // inline base64 `data` to every connected owner, tool_result carries ONLY
  // metadata, live broadcast (not replayed via `session_history`), anchored to
  // the turn via `in_reply_to`. `kind` drives which viewer the app opens.
  // `allow_network` is HTML-only: when true the WebView sandbox permits remote
  // resources; default (absent/false) blocks all network (JS still runs inline).
  | {
      type: "agent_file";
      id: string;
      in_reply_to: string;
      kind: "markdown" | "text" | "pdf" | "html";
      /** Base64-encoded raw file bytes. Text kinds are valid UTF-8. */
      data: string;
      /** Original MIME for display/save (text/markdown, text/plain, text/html,
       *  application/pdf). */
      mime?: string;
      /** Repo path the agent read from (display / save name). */
      path?: string;
      /** Optional caption shown under the bubble and as the viewer title. */
      caption?: string;
      /** Raw file size in bytes. */
      size?: number;
      /** HTML only: when true the app's WebView allows remote resources
       *  (scripts/images/fetch/ws). Absent/false = sandboxed (JS runs, network
       *  blocked). Ignored for non-html kinds. */
      allow_network?: boolean;
    }
  // Plan/32: pushed after a context compaction (live, and replayed on history
  // re-sync). `tokens_before` is the pre-compaction token count.
  | { type: "compaction"; summary: string; tokens_before: number; ts?: number }
  | { type: "tool_request"; tool_call_id: string; tool: string; args: Record<string, unknown> }
  | { type: "tool_result"; tool_call_id: string; result?: unknown; error?: string }
  | { type: "error"; in_reply_to?: string; code: ErrorCode; message: string }
  | { type: "cancelled"; in_reply_to: string; target_id: string }
  | { type: "pong"; in_reply_to: string }
  | { type: "bye"; reason: ByeReason }
  | {
      type: "session_history";
      in_reply_to: string;
      session_started_at: number;
      events: SessionHistoryEvent[];
      eos: boolean;
      truncated: boolean;
      // Plan/128 — cursor pagination for durable full-history paging.
      // `next_before` is the cursor to send back to fetch the page OLDER than
      // this one (omitted when nothing older remains). `has_more` is the
      // boolean form of `truncated`. Both optional for back-compat with older
      // clients/servers; `truncated` mirrors `has_more`.
      next_before?: string;
      has_more?: boolean;
    }
  // Plan/28 — Replies for typed app actions.
  // `action_ok` / `action_error` carry the original `ActionName` so the
  // app can demultiplex by action type rather than having to remember
  // every in-flight request id.
  // `models_list` is the response to a `list_models` request; the optional
  // `current` echoes the model the Pi is using right now so the app can
  // highlight the selected row without a second round-trip.
  | { type: "action_ok"; in_reply_to: string; action: ActionName }
  | { type: "action_error"; in_reply_to: string; action: ActionName; error: string }
  | { type: "models_list"; in_reply_to: string; models: WireModel[]; current?: WireModel }
  // Plan/107 — Reply to `git_status_request`. `status` is null when the cwd
  // isn't a git repo or git is unavailable.
  | { type: "git_status_result"; in_reply_to: string; status: WireGitStatus | null }
  // Plan/108 — Reply to `open_terminal_request`. `ok` is false when the
  // platform is unsupported, the path is missing, or the launcher failed.
  // `method` describes what was launched: "wt" (Windows Terminal tab),
  // "window" (console-window fallback), or "none" (never spawned).
  | {
      type: "open_terminal_result";
      in_reply_to: string;
      ok: boolean;
      message: string;
      method?: "wt" | "window" | "none";
      /** Plan/112 — the newly-created worktree (absent on reopen / failure). */
      worktree?: WireWorktree;
    }
  // Plan/112 — worktree tracking replies.
  | {
      type: "list_worktrees_result";
      in_reply_to: string;
      ok: boolean;
      worktrees: WireWorktree[];
    }
  | {
      type: "remove_worktree_result";
      in_reply_to: string;
      ok: boolean;
      message: string;
    }
  // Plan/121 — reply to list_projects_request. `ok:false` only if discovery
  // itself threw (best-effort; an empty list is a valid, ok:true answer).
  | {
      type: "list_projects_result";
      in_reply_to: string;
      ok: boolean;
      projects: WireProject[];
      message?: string;
    }
  // api.changeLayout — reply to change_layout_request. `created`/`skipped`
  // mirror the Cockpit orchestrate report (panes created vs. merged away
  // because a tab of the same name already existed). `ok:false` + `message`
  // for unknown layout name, Cockpit CLI missing, or Cockpit not running.
  | {
      type: "change_layout_result";
      in_reply_to: string;
      ok: boolean;
      created: string[];
      skipped: string[];
      message?: string;
    }
  // Plan/124 — reply to start_session_request. `room_id` is the room the
  // spawned pi will (re)announce = roomIdFor(cwd, name); the app can sanity-
  // check it against the tapped tile's room. `ok:false` (with `message`)
  // when the supervisor is offline or the cwd is invalid.
  | {
      type: "start_session_result";
      in_reply_to: string;
      ok: boolean;
      room_id?: string;
      message?: string;
    }
  // Plan/100 — interactive extension prompt (ask_user via pi-ask). Mirrors
  // RpcExtensionUIRequest (select/confirm/input/editor/notify); the optional
  // `ask` envelope carries pi-ask's full question so the app renders richly.
  | ExtensionUiRequestWire;

/**
 * Plan/28 — Stable names for the typed actions the app can request. Kept
 * as a closed string union so a switch in either side gets exhaustiveness
 * checking from the compiler.
 */
export type ActionName =
  | "session_new"
  | "session_compact"
  | "model_set"
  | "thinking_set";

/**
 * Plan/28 — Mirror of the SDK's `ThinkingLevel` (defined in
 * `@earendil-works/pi-agent-core/types`). Re-declared locally so the wire
 * protocol owns its own enum and we don't leak SDK-internal types onto
 * the app's network surface.
 *
 * Note: `"xhigh"` is only honored by select model families — the SDK uses
 * each `Model.thinkingLevelMap` to decide if the requested level is
 * supported, falling back to a sensible neighbour when not. The app
 * surfaces all 6 buttons but can grey out unsupported ones using the
 * model's metadata if the picker fetches it later.
 */
export type ThinkingLevel =
  | "off" | "minimal" | "low" | "medium" | "high" | "xhigh";

/**
 * Plan/28 — Wire shape for one model entry in the app's model picker.
 *
 * Subset of the SDK's `Model<Api>` interface — only the fields the app
 * actually renders. Cost / max-tokens / API class are left off the wire
 * deliberately; if the app's picker grows to need them, they get added
 * here and to the handler's mapping in `index.ts` in one diff.
 */
export interface WireModel {
  /** Stable identifier inside the provider's catalog. E.g. `"claude-opus-4-7"`. */
  id: string;
  /** Display name for the picker row. E.g. `"Claude Opus 4.7"`. */
  name: string;
  /** Provider slug. E.g. `"anthropic"`, `"openai"`. */
  provider: string;
  /** Whether the model supports the thinking surface (`reasoning: true`
   *  in the SDK). Useful so the app can decide whether the thinking
   *  segmented control should be enabled when this model is selected. */
  reasoning: boolean;
  /** Context window in tokens, for display in the picker subtitle. */
  context_window: number;
  /** Plan/30: true when the model accepts image input (SDK `Model.input`
   *  includes `"image"`). The app uses it to enable/disable the attach
   *  button — a text-only model greys out image attachments. */
  vision: boolean;
}

/**
 * Plan/107 — Git status snapshot of the session cwd (the same data
 * pi-posh-git renders in its footer). Computed on demand by the
 * pi-extension; the app shows it in the session-info dialog.
 */
export interface WireGitStatus {
  branch: string;
  upstream: string | null;
  aheadBy: number;
  behindBy: number;
  upstreamGone: boolean;
  indexAdded: number;
  indexModified: number;
  indexDeleted: number;
  indexUnmerged: number;
  workingAdded: number;
  workingModified: number;
  workingDeleted: number;
  workingUnmerged: number;
  stashCount: number;
}

/**
 * Plan/112 — one tracked git worktree created by "Open terminal". The
 * pi-extension persists these in `~/.pi/piper/worktrees.json` so the app
 * can list / reopen / remove them. `id` == the stamp == the folder name ==
 * the `work/<id>` branch suffix.
 */
export interface WireWorktree {
  id: string;
  base: string;
  path: string;
  branch: string;
  created_at: string;
}

/**
 * Plan/121 — one discovered git project (main repo) for the phone's Projects
 * list. `path` is the repo root; `name` is `basename(path)` (display name).
 */
export interface WireProject {
  path: string;
  name: string;
}

export type ByeReason = "peer_stop" | "session_replaced" | "shutdown";
