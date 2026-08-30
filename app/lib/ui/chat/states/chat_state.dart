import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';

// Sealed state for ChatViewModel.
// Switch exhaustively in ChatPage.build().

sealed class ChatState {
  const ChatState();
}

// No peer paired yet — show QR scanner redirect.
class ChatNoPeer extends ChatState {
  const ChatNoPeer();
}

// Establishing connection after boot or reconnect.
class ChatConnecting extends ChatState {
  const ChatConnecting();
}

// Connected and ready.
class ChatReady extends ChatState {
  final List<ChatMessage> messages;
  final StreamingMessage? streaming;
  final bool isOffline; // true → input disabled, banner visible
  // True once the Mac signalled this device is no longer in peers.json
  // (relay returned an `unknown_peer` error). Stays true until the user
  // re-pairs or revokes; suppresses input and surfaces a re-pair banner.
  final bool pairingRevoked;
  // Set when the Pi sent a `bye` (graceful disconnect). Stops retry,
  // shows banner offering manual reconnect. `peerOfflineReason` is the
  // raw wire reason (peer_stop / session_replaced / shutdown / …).
  final String? peerOfflineReason;
  /// Live relay-reported presence of the active peer. When the peer is
  /// [PresenceOffline] the chat enters read-only mode (history visible,
  /// input disabled). Defaults to [PresenceUnknown] until the relay
  /// reports.
  final PresenceState peerPresence;

  /// Plan/32 — whether the room this chat is viewing has an in-flight
  /// agent turn (drives the working pill + input-lock + stop button).
  /// Part of the state identity so a relay `meta.working` flip (which is
  /// per-room, like Home) actually triggers a rebuild even when nothing
  /// else changed. See [ChatViewModel.isWorking].
  final bool isWorking;

  /// Plan/134 — whether the room this chat is viewing is blocked on a
  /// user-facing ctx.ui prompt (drives the amber "Waiting for your
  /// answer…" pill + composer hint). Part of the state identity for the
  /// same reason as [isWorking]: the pill reads the VM getter, and without
  /// it in `==` a pure `meta.waiting_for_input` flip produced an equal
  /// ChatReady and [ViewModel.emit] skipped notifyListeners — the UI kept
  /// showing "working…" until something else changed. See
  /// [ChatViewModel.isWaitingForInput].
  final bool isWaitingForInput;

  /// Active model name for this room (from `room_meta.model`). Part of the
  /// state identity for the same reason as [isWorking]: the AppBar / composer
  /// hint read it via side-channel getters (`activeRoom.model`), and without
  /// it in `==` a pure model switch (model_set → room_meta_updated) produced
  /// an equal ChatReady and [ViewModel.emit] skipped notifyListeners — the
  /// UI kept showing the old model even though the PC had switched.
  final String? model;

  /// Plan/115 — live context-window usage. Same identity reason as [model]:
  /// a pure usage tick must rebuild the header gauge.
  final ContextUsage? contextUsage;

  final List<QueuedMsg> queuedMessages;

  /// Plan/100 — an interactive extension_ui_request (ask_user via pi-ask)
  /// awaiting an answer. Non-null → the chat renders a full-screen modal.
  /// Cleared on submit/cancel/completed. Identity compared (the ViewModel
  /// reuses the same instance across recomputes until it changes).
  final ExtensionUiRequest? pendingUiRequest;

  /// Plan/100 — last submit-result error for [pendingUiRequest] (null when none
  /// or resolved). Shown in the modal so the user can retry instead of hitting a
  /// dead end when pi-ask rejects an answer.
  final String? pendingUiError;

  // Plan/111 — true when session history is truncated (Pi has more messages
  /// than returned). The UI shows a "Load more messages" button at the top.
  final bool truncated;

  /// Plan/137 — a pending `ask_user` tool call has been sitting WITHOUT a
  /// rendered question sheet (the request frame was lost). Drives the
  /// recovery card above the composer: Retry (re-sync → bridge replay) and
  /// Cancel question (abort the blocked turn, releasing queued steering).
  /// Part of the state identity like [isWorking] so the card appearing needs
  /// no other state change (nothing else fires while the agent is blocked).
  final bool askRecovery;

  String? get queuedText =>
      queuedMessages.isEmpty ? null : queuedMessages.first.text;

  const ChatReady({
    required this.messages,
    this.streaming,
    this.isOffline = false,
    this.pairingRevoked = false,
    this.peerOfflineReason,
    this.peerPresence = const PresenceUnknown(),
    this.isWorking = false,
    this.isWaitingForInput = false,
    this.model,
    this.contextUsage,
    this.queuedMessages = const [],
    this.pendingUiRequest,
    this.pendingUiError,
    this.truncated = false,
    this.askRecovery = false,
  });

  ChatReady copyWith({
    List<ChatMessage>? messages,
    StreamingMessage? streaming,
    bool? isOffline,
    bool? pairingRevoked,
    String? peerOfflineReason,
    PresenceState? peerPresence,
    bool? isWorking,
    bool? isWaitingForInput,
    String? model,
    bool clearModel = false,
    ContextUsage? contextUsage,
    bool clearContextUsage = false,
    List<QueuedMsg>? queuedMessages,
    bool clearStreaming = false,
    bool clearPeerOffline = false,
    bool clearQueuedMessages = false,
    ExtensionUiRequest? pendingUiRequest,
    bool clearPendingUiRequest = false,
    String? pendingUiError,
    bool clearPendingUiError = false,
    bool? truncated,
    bool? askRecovery,
  }) =>
      ChatReady(
        messages: messages ?? this.messages,
        streaming: clearStreaming ? null : (streaming ?? this.streaming),
        isOffline: isOffline ?? this.isOffline,
        pairingRevoked: pairingRevoked ?? this.pairingRevoked,
        peerOfflineReason: clearPeerOffline
            ? null
            : (peerOfflineReason ?? this.peerOfflineReason),
        peerPresence: peerPresence ?? this.peerPresence,
        isWorking: isWorking ?? this.isWorking,
        isWaitingForInput: isWaitingForInput ?? this.isWaitingForInput,
        model: clearModel ? null : (model ?? this.model),
        contextUsage: clearContextUsage
            ? null
            : (contextUsage ?? this.contextUsage),
        queuedMessages: clearQueuedMessages
            ? []
            : (queuedMessages ?? this.queuedMessages),
        pendingUiRequest: clearPendingUiRequest
            ? null
            : (pendingUiRequest ?? this.pendingUiRequest),
        pendingUiError: clearPendingUiError
            ? null
            : (pendingUiError ?? this.pendingUiError),
        truncated: truncated ?? this.truncated,
        askRecovery: askRecovery ?? this.askRecovery,
      );

  @override
  bool operator ==(Object other) =>
      other is ChatReady &&
      other.messages == messages &&
      other.streaming == streaming &&
      other.isOffline == isOffline &&
      other.pairingRevoked == pairingRevoked &&
      other.peerOfflineReason == peerOfflineReason &&
      other.peerPresence.runtimeType == peerPresence.runtimeType &&
      other.isWorking == isWorking &&
      other.isWaitingForInput == isWaitingForInput &&
      other.model == model &&
      other.contextUsage == contextUsage &&
      other.queuedMessages == queuedMessages &&
      other.pendingUiRequest == pendingUiRequest &&
      other.pendingUiError == pendingUiError &&
      other.truncated == truncated &&
      other.askRecovery == askRecovery;

  @override
  int get hashCode => Object.hash(
        messages,
        streaming,
        isOffline,
        pairingRevoked,
        peerOfflineReason,
        peerPresence.runtimeType,
        isWorking,
        isWaitingForInput,
        model,
        contextUsage,
        queuedMessages,
        pendingUiRequest,
        pendingUiError,
        truncated,
        askRecovery,
      );
}

// Permanent offline — must re-pair.
class ChatFatalError extends ChatState {
  final String message;
  const ChatFatalError(this.message);

  @override
  bool operator ==(Object other) =>
      other is ChatFatalError && other.message == message;

  @override
  int get hashCode => message.hashCode;
}
