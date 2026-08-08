// Session domain model — chat message variants + streaming buffer.
// Lives in domain/ → no Flutter, no network, no storage.

// ---------------------------------------------------------------------------
// ChatMessage — sealed union of message variants in the conversation history
// ---------------------------------------------------------------------------

sealed class ChatMessage {
  final String id;
  const ChatMessage({required this.id});
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
  });

  UserMsg copyWith({UserMsgStatus? status, bool? steering, bool? followUp}) => UserMsg(
    id: id,
    text: text,
    status: status ?? this.status,
    steering: steering ?? this.steering,
    followUp: followUp ?? this.followUp,
    image: image,
  );

  @override
  bool operator ==(Object other) =>
      other is UserMsg &&
      other.id == id &&
      other.text == text &&
      other.status == status &&
      other.steering == steering &&
      other.followUp == followUp &&
      other.image == image;

  @override
  int get hashCode => Object.hash(id, text, status, steering, followUp, image);
}

class AssistantMsg extends ChatMessage {
  final String text;
  const AssistantMsg({required super.id, required this.text});

  @override
  bool operator ==(Object other) =>
      other is AssistantMsg && other.id == id && other.text == text;

  @override
  int get hashCode => Object.hash(id, text);
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
  });

  @override
  bool operator ==(Object other) =>
      other is AgentImageMsg &&
      other.id == id &&
      other.image == image &&
      other.path == path &&
      other.caption == caption;

  @override
  int get hashCode => Object.hash(id, image, path, caption);
}

/// Plan/126 - a document the agent pushed to the user from a file in the repo
/// (via the `show_file` tool): Markdown / plain text or code / PDF / HTML.
/// Rendered as a left-aligned, tappable card ([AgentFileBubble]) that opens
/// [DocViewerPage], which routes by [kind] to the right viewer. [data] is the
/// raw file bytes base64-encoded (decoded in the viewer; valid UTF-8 for the
/// text-y kinds). [allowNetwork] is HTML-only and flips the WebView sandbox
/// state. [caption] (possibly empty) shows under the card; [path] is the
/// original repo path used as the viewer title.
class AgentFileMsg extends ChatMessage {
  final String kind; // markdown | text | pdf | html
  final String data; // base64 raw file bytes
  final String? mime;
  final String? path;
  final String caption;
  final bool allowNetwork;

  const AgentFileMsg({
    required super.id,
    required this.kind,
    required this.data,
    this.mime,
    this.path,
    this.caption = '',
    this.allowNetwork = false,
  });

  @override
  bool operator ==(Object other) =>
      other is AgentFileMsg &&
      other.id == id &&
      other.kind == kind &&
      other.data == data &&
      other.mime == mime &&
      other.path == path &&
      other.caption == caption &&
      other.allowNetwork == allowNetwork;

  @override
  int get hashCode =>
      Object.hash(id, kind, data, mime, path, caption, allowNetwork);
}

class ToolEvent extends ChatMessage {
  final String toolCallId;
  final String tool;
  final dynamic args;
  final ToolEventStatus status;
  final dynamic result;
  final String? error;

  const ToolEvent({
    required super.id,
    required this.toolCallId,
    required this.tool,
    required this.args,
    this.status = ToolEventStatus.pending,
    this.result,
    this.error,
  });

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
  );

  @override
  bool operator ==(Object other) =>
      other is ToolEvent &&
      other.id == id &&
      other.toolCallId == toolCallId &&
      other.status == status;

  @override
  int get hashCode => Object.hash(id, toolCallId, status);
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
  });

  @override
  bool operator ==(Object other) =>
      other is CompactionMsg &&
      other.id == id &&
      other.summary == summary &&
      other.tokensBefore == tokensBefore;

  @override
  int get hashCode => Object.hash(id, summary, tokensBefore);
}

// ---------------------------------------------------------------------------
// StreamingMessage — accumulated deltas while the assistant is typing
// ---------------------------------------------------------------------------

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
