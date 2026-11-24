// Session domain model — chat message variants + streaming buffer.
// Lives in domain/ → no Flutter, no network, no storage.

// ---------------------------------------------------------------------------
// ChatMessage — sealed union of message variants in the conversation history
// ---------------------------------------------------------------------------

sealed class ChatMessage {
  final String id;

  /// Plan/172 — when this row's event happened, on the clock that produced
  /// it: the Pi's for frames the extension stamps (and for every replayed
  /// history row), the phone's where an older extension left the app to stamp
  /// arrival. Per variant:
  ///
  /// - [UserMsg]: when the message was sent / accepted by the Pi.
  /// - [AssistantMsg]: when the LLM reply STARTED (the SDK's assistant-message
  ///   timestamp), not when it finished streaming.
  /// - [ToolEvent]: legacy row time. The tool's execution window lives in
  ///   [ToolEvent.replyAt] / [ToolEvent.startedAt] / [ToolEvent.endedAt]; `ts`
  ///   is kept for ordering (paging, retention) and as the last-resort stamp
  ///   on rows persisted before plan/172.
  ///
  /// Every persisted row carries one (`MessageRecord.ts`). Null only on
  /// synthetic messages built without a time (tests): the UI then renders no
  /// stamp. Nullable so the const constructors stay const.
  final DateTime? ts;
  const ChatMessage({required this.id, this.ts});
}

/// Plan/24-fix-app-source-of-truth: every UserMsg is tagged with the
/// lifecycle stage of its rebroadcast. `pending` = sent over WS but Pi
/// hasn't echoed it back yet; `confirmed` = Pi rebroadcast it (or it
/// came from `session_history` / another device's echo); `failed` =
/// 15s elapsed without echo, user can retry.
///
/// Default is `confirmed` for back-compat — every persisted UserMsg
/// from before this fix was effectively confirmed (the Pi wasn't
/// rebroadcasting then, but the local cache treated it as
/// authoritative).
enum UserMsgStatus { pending, confirmed, failed }

/// Plan/30 — an image attached to a user message. Carries the JPEG bytes
/// base64-encoded plus its mime type, mirroring the SDK's `ImageContent`.
/// Bytes always travel inline (decision #8: history replays the image too),
/// so the bubble can render straight from [data] with no extra round-trip.
class MessageImage {
  /// Base64-encoded image bytes (no data-URI prefix).
  final String data;

  /// Mime type, e.g. `image/jpeg`.
  final String mime;

  const MessageImage({required this.data, required this.mime});

  @override
  bool operator ==(Object other) =>
      other is MessageImage && other.data == data && other.mime == mime;

  @override
  int get hashCode => Object.hash(data, mime);
}

/// Android-owned queued follow-up shown above the composer. Protocol-free
/// domain value; SyncService maps wire items into this shape.
class QueuedMsg {
  final String id;
  final String text;
  final bool editable;
  final DateTime createdAt;

  const QueuedMsg({
    required this.id,
    required this.text,
    required this.editable,
    required this.createdAt,
  });

  @override
  bool operator ==(Object other) =>
      other is QueuedMsg &&
      other.id == id &&
      other.text == text &&
      other.editable == editable &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, text, editable, createdAt);
}

class UserMsg extends ChatMessage {
  final String text;
  final UserMsgStatus status;
  final bool steering;

  /// Plan/127 — this message was sent as a follow-up (queued behind the
  /// running turn). Persistent display marker; distinct from [steering]
  /// (which is transient and cleared on consume).
  final bool followUp;

  /// Plan/30 — optional attached image (one max). `null` for text-only
  /// messages, which is every message before this feature.
  final MessageImage? image;

  const UserMsg({
    required super.id,
    required this.text,
    this.status = UserMsgStatus.confirmed,
    this.steering = false,
    this.followUp = false,
    this.image,
    super.ts,
  });

  /// Copies with a new lifecycle. [ts] is carried over; the Pi's echo is the
  /// only writer that moves it (see `SyncService`, plan/172).
  UserMsg copyWith({UserMsgStatus? status, bool? steering, bool? followUp}) =>
      UserMsg(
        id: id,
        text: text,
        status: status ?? this.status,
        steering: steering ?? this.steering,
        followUp: followUp ?? this.followUp,
        image: image,
        ts: ts,
      );

  @override
  bool operator ==(Object other) =>
      other is UserMsg &&
      other.id == id &&
      other.text == text &&
      other.status == status &&
      other.steering == steering &&
      other.followUp == followUp &&
      other.image == image &&
      other.ts == ts;

  @override
  int get hashCode =>
      Object.hash(id, text, status, steering, followUp, image, ts);
}

class AssistantMsg extends ChatMessage {
  final String text;

  /// Plan/172 — [ts] is when the LLM reply STARTED (see [ChatMessage.ts]).
  const AssistantMsg({required super.id, required this.text, super.ts});

  @override
  bool operator ==(Object other) =>
      other is AssistantMsg &&
      other.id == id &&
      other.text == text &&
      other.ts == ts;

  @override
  int get hashCode => Object.hash(id, text, ts);
}

/// Plan/114 — an image the agent pushed to the user from a file in the repo
/// (via the `show_image` tool). Rendered as a left-aligned, tappable bubble
/// that opens [ImageViewerPage] (full-screen pinch-zoom). Unlike [UserMsg]'s
/// static thumbnail, this one is interactive. [caption] (possibly empty) shows
/// under the image; [path] is the original repo path used as the viewer title.
class AgentImageMsg extends ChatMessage {
  final MessageImage image;
  final String? path;
  final String caption;

  const AgentImageMsg({
    required super.id,
    required this.image,
    this.path,
    this.caption = '',
    super.ts,
  });

  @override
  bool operator ==(Object other) =>
      other is AgentImageMsg &&
      other.id == id &&
      other.image == image &&
      other.path == path &&
      other.caption == caption &&
      other.ts == ts;

  @override
  int get hashCode => Object.hash(id, image, path, caption, ts);
}

/// Plan/126 - a document the agent pushed to the user from a file in the repo
/// (via the `show_file` tool): Markdown / plain text or code / PDF / HTML.
/// Rendered as a left-aligned, tappable card ([AgentFileBubble]) that opens
/// [DocViewerPage], which routes by [kind] to the right viewer.
///
/// Plan/158 — two shapes share this domain message:
/// - **inline** (legacy, pre-158 Pi extensions): [data] carries the base64
///   bytes; [path] is the repo path used as viewer title.
/// - **reference** (plan/158): [data] is null until fetched; [fileId] is the
///   `agent_file_fetch` key, [name] the announced basename and [bytes] the
///   declared size. The bubble fetches bytes when the user opens/saves/shares.
class AgentFileMsg extends ChatMessage {
  final String kind; // markdown | text | pdf | html | mermaid | file
  final String? data; // base64 raw file bytes (null on plan/158 refs)
  final String? mime;
  final String? path; // legacy inline: repo path (viewer title)
  final String? fileId; // plan/158 — ref shape: the agent_file_fetch key
  final String? name; // plan/158 — basename announced by the Pi
  final int? bytes; // plan/158 — declared size
  final String caption;
  final bool allowNetwork;

  const AgentFileMsg({
    required super.id,
    required this.kind,
    this.data,
    this.mime,
    this.path,
    this.fileId,
    this.name,
    this.bytes,
    this.caption = '',
    this.allowNetwork = false,
    super.ts,
  });

  @override
  bool operator ==(Object other) =>
      other is AgentFileMsg &&
      other.id == id &&
      other.kind == kind &&
      other.data == data &&
      other.mime == mime &&
      other.path == path &&
      other.fileId == fileId &&
      other.name == name &&
      other.bytes == bytes &&
      other.caption == caption &&
      other.allowNetwork == allowNetwork &&
      other.ts == ts;

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    data,
    mime,
    path,
    fileId,
    name,
    bytes,
    caption,
    allowNetwork,
    ts,
  );
}

class ToolEvent extends ChatMessage {
  final String toolCallId;
  final String tool;
  final dynamic args;
  final ToolEventStatus status;
  final dynamic result;
  final String? error;

  /// Plan/172 — when the LLM reply that issued this call STARTED. Live it is
  /// the `reply_ts` of the `tool_request` frame; replayed it is that event's
  /// `ts`. Null when neither carried one (old extensions, synthetic pairs).
  final DateTime? replyAt;

  /// Plan/172 — when the tool actually started executing. Live: `ts` of the
  /// `tool_request`. Replayed: `ts - duration_ms` of the `tool_result`. Null
  /// when the replay carried no duration (legacy session) and nothing live did.
  final DateTime? startedAt;

  /// Plan/172 — when the tool finished (the `tool_result` time). Null until
  /// the result arrives.
  final DateTime? endedAt;

  /// Plan/172 — wall time of the tool's `execute()` in ms. The SDK's monotonic
  /// measurement when reported, else `endedAt - startedAt`. Null when neither
  /// end is known.
  final int? durationMs;

  /// Plan/172 — [ts] is the legacy row time (see [ChatMessage.ts]); the four
  /// fields above are the tool's real execution window.
  const ToolEvent({
    required super.id,
    required this.toolCallId,
    required this.tool,
    required this.args,
    this.status = ToolEventStatus.pending,
    this.result,
    this.error,
    super.ts,
    this.replyAt,
    this.startedAt,
    this.endedAt,
    this.durationMs,
  });

  /// Copies with a new lifecycle ([status], [result], [error]). The timing
  /// window is carried over unchanged: the sync layer sets it through
  /// `ToolEventData`, which owns the persisted values.
  ToolEvent copyWith({
    ToolEventStatus? status,
    dynamic result,
    String? error,
  }) => ToolEvent(
    id: id,
    toolCallId: toolCallId,
    tool: tool,
    args: args,
    status: status ?? this.status,
    result: result ?? this.result,
    error: error ?? this.error,
    ts: ts,
    replyAt: replyAt,
    startedAt: startedAt,
    endedAt: endedAt,
    durationMs: durationMs,
  );

  /// True while the tool is running or waiting, i.e. no result has landed.
  bool get isRunning =>
      status == ToolEventStatus.pending || status == ToolEventStatus.allowed;

  @override
  bool operator ==(Object other) =>
      other is ToolEvent &&
      other.id == id &&
      other.toolCallId == toolCallId &&
      other.status == status &&
      other.ts == ts &&
      other.replyAt == replyAt &&
      other.startedAt == startedAt &&
      other.endedAt == endedAt &&
      other.durationMs == durationMs;

  @override
  int get hashCode => Object.hash(
    id,
    toolCallId,
    status,
    ts,
    replyAt,
    startedAt,
    endedAt,
    durationMs,
  );
}

/// Plan/32 — `denied` = the user/SDK declined the tool; `failed` = the tool
/// ran but errored (a distinct, red outcome). `expired` = approval timed out.
enum ToolEventStatus { pending, allowed, denied, expired, completed, failed }

/// Plan/32 — a context-compaction marker rendered as a system bubble
/// (distinct from user/assistant). [summary] is the Pi's recap of the
/// compacted thread; [tokensBefore] is the token count reclaimed (null when
/// the Pi didn't report it).
class CompactionMsg extends ChatMessage {
  final String summary;
  final int? tokensBefore;
  const CompactionMsg({
    required super.id,
    required this.summary,
    this.tokensBefore,
    super.ts,
  });

  @override
  bool operator ==(Object other) =>
      other is CompactionMsg &&
      other.id == id &&
      other.summary == summary &&
      other.tokensBefore == tokensBefore &&
      other.ts == ts;

  @override
  int get hashCode => Object.hash(id, summary, tokensBefore, ts);
}

// ---------------------------------------------------------------------------
// StreamingMessage — accumulated deltas while the assistant is typing
// ---------------------------------------------------------------------------

/// UI coalescing cadence for a growing Markdown response. Short replies stay
/// frame-responsive; long replies trade update frequency for less parsing,
/// layout, and string-copy churn. Finalization bypasses this policy
/// and flushes immediately.
int streamingFlushIntervalMs(int bufferedChars) {
  if (bufferedChars >= 100000) return 100;
  if (bufferedChars >= 50000) return 50;
  return 16;
}

class StreamingMessage {
  final String inReplyTo; // id of the UserMsg being answered
  final String buffer;

  const StreamingMessage({required this.inReplyTo, this.buffer = ''});

  StreamingMessage appendDelta(String delta) =>
      StreamingMessage(inReplyTo: inReplyTo, buffer: buffer + delta);

  @override
  bool operator ==(Object other) =>
      other is StreamingMessage &&
      other.inReplyTo == inReplyTo &&
      other.buffer == buffer;

  @override
  int get hashCode => Object.hash(inReplyTo, buffer);
}
