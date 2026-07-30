import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/share/shared_text_inbox.dart';
import 'package:app/data/share/composer_draft.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/git_status_span.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/chat/quick_actions/widgets/quick_actions_sheet.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/chat/widgets/attach_sheet.dart';
import 'package:app/ui/chat/widgets/agent_image_bubble.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:app/ui/chat/widgets/message_bubble.dart';
import 'package:app/ui/chat/widgets/streaming_bubble.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:app/ui/chat/widgets/extension_ui_sheet.dart';
import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
// Plan/jumpusermsg — ScrollCacheExtent (pixels) for the transcript's larger
// build cache, so prev/next user-message targets stay mounted for
// ensureVisible. material.dart only `show`s TextSelectionHandleType from
// rendering, so we import the symbol directly (same as the SDK's own
// scroll_view.dart).
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

class ChatPage extends StatelessWidget {
  /// Plan/24-fix-title: optional title hint passed via `go_router`
  /// `extra` from the Home tile. Used as the peer-label fallback in
  /// the AppBar so the user sees the right name *immediately* on
  /// navigation, instead of "—" / "Piper" until the PeerRecord
  /// is loaded by the ViewModel and the first `room_meta_updated`
  /// arrives.
  final String? initialTitle;

  /// Plan/32g — the paired-device (Mac) label Home already knows, passed via
  /// `extra` / [SessionSelection]. Drives the AppBar's line 2 immediately so
  /// it never flickers empty/room-title while the PeerRecord loads async.
  /// When the PeerRecord arrives it resolves to the same string, so there's no
  /// visible change.
  final String? initialDevice;

  /// Plan/32g — the live state of the tile Home tapped (its green dot). Seeds
  /// the AppBar status dot so it doesn't flash "reconnecting" before the VM
  /// reads the real runtime. Superseded by the live signal once it resolves
  /// ([ChatViewModel.connectionResolved]).
  final bool initialOnline;

  /// Plan/tablet — `false` when the chat is embedded as the tablet's
  /// detail pane (no navigation stack to pop back to). Hides the back
  /// arrow; defaults to `true` for the phone full-screen route.
  final bool showBack;

  const ChatPage({
    super.key,
    this.initialTitle,
    this.initialDevice,
    this.initialOnline = false,
    this.showBack = true,
  });

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ChatViewModel>();
    final state = vm.state;

    final scaffold = Scaffold(
      backgroundColor: context.colors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(context, state),
            // Pairing revocation is the only banner kept — it's a hard
            // failure (can't proceed without re-pairing), red, with an
            // explicit action. Plain offline / Pi-gone / presence-off
            // banners were removed: the AppBar status line already
            // surfaces those, and stacking duplicates noise the surface.
            if (state is ChatReady && state.pairingRevoked)
              _RevokedBanner(onRePair: () => context.go('/pair')),
            Expanded(child: _buildBody(context, state, vm)),
            _buildInput(context, state, vm),
          ],
        ),
      ),
    );

    // Plan/100 — an interactive extension_ui_request (ask_user via pi-ask)
    // renders layered ABOVE the Scaffold. Purely reactive: the overlay leaves
    // the tree when the pending request clears (completed dismiss) — no route
    // lifecycle to manage. `error` carries a submit-result rejection so the
    // sheet can offer a retry instead of a dead end.
    //
    // Plan/101 — the sheet sizes itself (DraggableScrollableSheet), so this fill
    // is just the coordinate space it lays out in. The area above the sheet
    // paints nothing and hit-tests through to the chat, which is the point:
    // the user can read and scroll the conversation while answering.
    final ready = state is ChatReady ? state : null;
    final uiRequest = ready?.pendingUiRequest;
    if (uiRequest == null) return scaffold;
    return Stack(
      children: [
        scaffold,
        Positioned.fill(
          // Keyed by request id: a new flow must get a fresh State — question
          // ids repeat across flows (e.g. "goal"), so reusing the State would
          // leak old selections/custom text into the new modal.
          child: ExtensionUiSheet(
            key: ValueKey(uiRequest.id),
            request: uiRequest,
            error: ready?.pendingUiError,
            onRespond: vm.respondExtensionUi,
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar(BuildContext context, ChatState state) {
    // Plan-17 follow-up — two-line AppBar:
    //   Line 1: ROOM name (cwd basename / room.name / fallback).
    //   Line 2: peer (Mac nickname or sessionName) + presence dot.
    // The dot reads from the ChatReady.peerPresence flag (which the
    // ViewModel sources from `isRoomLive`).
    final colors = context.colors;
    final typo = context.typo;
    final vm = context.watch<ChatViewModel>();
    final peer = vm.activePeer;
    final room = vm.activeRoom;
    // Plan/32g — until the VM has read a real runtime, trust the `initialOnline`
    // hint Home passed (the tile's live dot) so the status dot doesn't flash
    // "reconnecting" on the default runtime. The live signal takes over once
    // resolved.
    final resolved = vm.connectionResolved;
    final isOnline = resolved ? vm.isRoomLive : initialOnline;
    // Plan-18 follow-up — when the chat is "offline" (WS to relay
    // down or retrying), prefer a "reconectando" amber pill so the
    // user knows it's the relay, not the Pi cwd, that's gone.
    final isReconnecting = resolved && state is ChatReady && (state).isOffline;
    // Plan-18 follow-up — when the agent is currently producing a
    // response, show "working…" instead of online/offline.
    final isWorking = vm.isWorking;
    // While the agent is working, show the model running this turn next to
    // the "working…" pill. `room.model` is kept current via room_meta_updated.
    final rawModel = room?.model;
    final modelLabel = (isWorking && rawModel != null && rawModel.isNotEmpty)
        ? rawModel
        : null;
    // Plan/115 — live context-window fill (tokens/contextWindow/percent),
    // shown next to the working indicator. Null until the first response.
    final usage = room?.contextUsage;

    // Plan/24-fix-title: pass the navigation hint into the helpers so
    // either line of the AppBar (room or peer) shows it instead of
    // the generic placeholders when the ViewModel hasn't finished
    // bootstrapping yet.
    final roomName = _roomDisplayName(room, state, initialTitle);
    // Plan/32g — line 2 (device) falls back to `initialDevice` (the Mac name
    // Home passed), NOT `initialTitle` (the room name) — so it shows the right
    // device from frame 1 and doesn't flip when the PeerRecord loads.
    final peerLabel = _peerDisplayName(peer, initialDevice);

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: colors.bg,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          if (showBack)
            IconButton(
              icon: Icon(LucideIcons.chevronLeft, size: 18, color: colors.text),
              tooltip: 'Back',
              onPressed: () =>
                  context.canPop() ? context.pop() : context.go('/home'),
            )
          else
            const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _truncate(roomName, 28),
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontSize: 13,
                    color: colors.text,
                    letterSpacing: -0.2,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _truncate(peerLabel, 24),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: kMonoFamily,
                          fontSize: 10,
                          color: colors.muted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Builder(
                      builder: (_) {
                        // Plan-18 follow-up — 4-state pill:
                        // working / reconnecting / online / offline.
                        // Priority: working > reconnecting > online > offline.
                        final color = isWorking
                            ? colors.working
                            : isReconnecting
                            ? colors.warning
                            : isOnline
                            ? colors.success
                            : colors.muted;
                        final label = isWorking
                            ? 'working…'
                            : isReconnecting
                            ? 'reconnecting…'
                            : isOnline
                            ? 'online'
                            : 'offline';
                        final pill = Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: color,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              label,
                              style: TextStyle(
                                fontFamily: kMonoFamily,
                                fontSize: 10,
                                color: color,
                              ),
                            ),
                          ],
                        );
                        // Plan 114 (B) — tap the "reconnecting…" pill to
                        // force a reconnect now (resets the backoff).
                        if (!isReconnecting) return pill;
                        return Tooltip(
                          message: 'Reconnect now',
                          child: GestureDetector(
                            onTap: vm.reconnect,
                            child: pill,
                          ),
                        );
                      },
                    ),
                    // Model running the current turn (only while working).
                    if (modelLabel != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        _truncate(modelLabel, 24),
                        style: typo.monoSmall.copyWith(
                          fontSize: 10,
                          color: colors.accent,
                        ),
                      ),
                    ],
                    // Plan/115 — context-window fill, shown only while the
                    // agent is working (percent colored by pressure).
                    if (isWorking && usage != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        usage.percent != null ? '${usage.percent}%' : '·',
                        style: typo.monoSmall.copyWith(
                          fontSize: 10,
                          color: (usage.percent ?? 0) >= 90
                              ? colors.error
                              : (usage.percent ?? 0) >= 70
                              ? colors.warning
                              : colors.muted,
                        ),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '${usage.tokens != null ? '${(usage.tokens! / 1000).round()}k' : '—'}/'
                        '${(usage.contextWindow / 1000).round()}k',
                        style: typo.monoSmall.copyWith(
                          fontSize: 10,
                          color: colors.muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          // Plan/32g follow-up: ALWAYS render the info button. Gating it on the
          // async PeerRecord made it pop in on load → an AppBar layout shift
          // (the flicker the user saw). Title + device already render from the
          // nav hints, so the bar is stable from frame 1. The dialog needs the
          // loaded PeerRecord; we read it at tap time (loaded within ms of
          // mount for the connection) and no-op in the unlikely pre-load tap.
          IconButton(
            icon: Icon(LucideIcons.info, size: 18, color: colors.muted2),
            tooltip: 'Session info',
            onPressed: () {
              final p = vm.activePeer;
              if (p != null) {
                _showSessionInfo(
                  context,
                  p,
                  vm.activeRoom,
                  roomName,
                  context.read<IActionsRepository>(),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  /// Session details dialog — surfaced from the AppBar info action.
  /// Shows the human name, the Pi-side path (cwd), the owning device,
  /// plus model/room/paired-date when known.
  static Future<void> _showSessionInfo(
    BuildContext context,
    PeerRecord peer,
    RoomInfo? room,
    String name,
    IActionsRepository actions,
  ) {
    // Plan/107 — kick the git-status request off immediately so it's already
    // in flight when the dialog paints (the row shows "loading…" meanwhile).
    final gitFuture = actions.gitStatus();
    final owner = (peer.nickname?.isNotEmpty ?? false)
        ? peer.nickname!
        : peer.sessionName.isNotEmpty
        ? peer.sessionName
        : peer.remoteEpk.substring(0, 8);
    final model = room?.model;
    final paired = peer.pairedAt.contains('T')
        ? peer.pairedAt.split('T').first
        : peer.pairedAt;
    return showDialog<void>(
      context: context,
      builder: (dCtx) {
        final colors = dCtx.colors;
        return AlertDialog(
          backgroundColor: colors.bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: colors.border),
          ),
          title: Text(
            'Session info',
            style: TextStyle(
              fontFamily: kMonoFamily,
              fontSize: 15,
              color: colors.text,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _InfoRow(label: 'Name', value: name),
              _InfoRow(label: 'Path', value: room?.cwd ?? '—'),
              _InfoRow(label: 'Owner', value: owner),
              _InfoRow(label: 'Relay', value: peer.relayUrl),
              if (model != null && model.isNotEmpty)
                _InfoRow(label: 'Model', value: model),
              _InfoRow(label: 'Room', value: room?.roomId ?? '—'),
              _InfoRow(label: 'Paired', value: paired),
              FutureBuilder<GitStatus?>(
                future: gitFuture,
                builder: (ctx, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const _InfoRow(label: 'Git', value: 'loading…');
                  }
                  if (snap.hasError) {
                    return const _InfoRow(label: 'Git', value: 'unavailable');
                  }
                  final s = snap.data;
                  if (s == null) {
                    return const _InfoRow(
                      label: 'Git',
                      value: 'not a git repo',
                    );
                  }
                  return _InfoRow(
                    label: 'Git',
                    richValue: _gitTextSpan(s, ctx.colors),
                  );
                },
              ),
              // Plan/112 — tracked worktrees (reopen / remove).
              _WorktreesSection(actions: actions, base: room?.cwd),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(),
              child: Text(
                'Close',
                style: TextStyle(fontFamily: kMonoFamily, color: colors.accent),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Plan/107 — posh-git-style COLORED git status. Delegates to the shared
  /// [gitStatusSpans] helper so the dialog + Home tile render identically
  /// (and match pi-posh-git's footer). Returns a TextSpan for SelectableText.rich.
  static TextSpan _gitTextSpan(GitStatus s, AppColors c) =>
      TextSpan(children: gitStatusSpans(s, c, fontSize: 13));

  static String _roomDisplayName(
    RoomInfo? room,
    ChatState state,
    String? initialTitle,
  ) {
    if (room != null) {
      if (room.name != null && room.name!.isNotEmpty) return room.name!;
      final cwd = room.cwd;
      if (cwd != null && cwd.isNotEmpty) {
        final segs = cwd.split('/').where((s) => s.isNotEmpty).toList();
        if (segs.isNotEmpty) return segs.last;
      }
    }
    if (state is ChatReady && state.messages.isNotEmpty) {
      return _inferSessionName(state.messages);
    }
    // Plan/24-fix-title: Home knows the peer label before /chat
    // mounts; use it instead of the generic 'Piper' placeholder
    // while we wait for the first room_meta_updated to populate
    // `room.name`.
    if (initialTitle != null && initialTitle.isNotEmpty) return initialTitle;
    return '';
  }

  static String _peerDisplayName(PeerRecord? peer, String? fallback) {
    if (peer == null) {
      // Plan/32g: while the ViewModel hasn't loaded the PeerRecord yet, fall
      // back to the device label Home passed (initialDevice) — same value the
      // PeerRecord resolves to, so no flicker on load.
      if (fallback != null && fallback.isNotEmpty) return fallback;
      return '—';
    }
    if (peer.nickname != null && peer.nickname!.isNotEmpty) {
      return peer.nickname!;
    }
    if (peer.sessionName.isNotEmpty) return peer.sessionName;
    return peer.remoteEpk.substring(0, 8);
  }

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max - 1)}…';

  Widget _buildBody(BuildContext context, ChatState state, ChatViewModel vm) {
    final hideToolCalls = context.watch<Preferences>().hideToolCalls;
    return switch (state) {
      // Edge case: opened /chat without a peer (e.g. peer revoked while
      // user was here). The chat is not the place to pair — render
      // a minimal empty state without an action. User navigates back
      // and uses Home / Settings → pairing.
      ChatNoPeer() => const _EmptyState(
        icon: LucideIcons.messageCircle,
        message: 'No active device',
      ),
      ChatConnecting() => const _EmptyState(
        icon: LucideIcons.refreshCw,
        message: 'Connecting…',
      ),
      ChatFatalError(:final message) => _EmptyState(
        icon: LucideIcons.circleAlert,
        message: message,
        actionLabel: 'Re-pair',
        onAction: () => context.go('/pair'),
      ),
      ChatReady(:final messages, :final streaming) => () {
        final visible = hideToolCalls
            ? messages.where((m) => m is! ToolEvent).toList()
            : messages;
        // Empty body → the default placeholder (Pi brand icon + "Nothing
        // here"), shown whenever there's nothing to render — including while
        // reconnecting (the reconnect handshake never swaps the body).
        if (visible.isEmpty && streaming == null) {
          return const _EmptyState(
            icon: LucideIcons.terminal,
            message: 'Nothing here',
          );
        }
        return _MessageList(
          messages: visible,
          streaming: streaming,
          onDecide: (id, decision) => vm.approveTool(id, decision),
          truncated: state.truncated,
          onLoadMore: vm.loadMoreHistory,
        );
      }(),
    };
  }

  Widget _buildInput(BuildContext context, ChatState state, ChatViewModel vm) {
    final isReady = state is ChatReady;
    final isOffline = isReady && state.isOffline;
    final isRevoked = isReady && state.pairingRevoked;
    final isPeerOffline = isReady && state.peerOfflineReason != null;
    // Live relay-reported offline (no `bye`): Pi is just not reachable.
    final isPresenceOffline = isReady && state.peerPresence is PresenceOffline;
    // Plan/31 — the composer is locked + the send button becomes "stop" for
    // the WHOLE working turn (send/echo → agent_done), not just the narrow
    // token-streaming window. Driven by the broad working signal so it matches
    // the AppBar/Home "working" indicator.
    final isWorking = isReady && vm.isWorking;
    final cancelId = vm.cancelTargetId;
    // Quick actions need an open channel to dispatch — only offer the
    // entry point when the chat input itself is enabled. Hiding the
    // ⚙ button on offline avoids a tap that would just throw inside
    // the sheet.
    final actionsEnabled =
        isReady &&
        !isOffline &&
        !isRevoked &&
        !isPeerOffline &&
        !isPresenceOffline;

    return InputBar(
      disabled:
          !isReady ||
          isOffline ||
          isRevoked ||
          isPeerOffline ||
          isPresenceOffline,
      streaming: isWorking,
      model: vm.activeRoom?.model,
      // Plan/109 — second send button: pick a scoped model → send this draft
      // with it as a one-shot override (session default unchanged).
      onLoadModels: () async =>
          (await context.read<IActionsRepository>().listModels()).models,
      onSendWithModel: (text, m) =>
          vm.sendMessage(text, model: (provider: m.provider, id: m.id)),
      onCancel: cancelId != null ? () => vm.cancel(cancelId) : null,
      onOpenQuickActions: actionsEnabled
          ? () => showQuickActionsSheet(context)
          : null,
      queuedMessages: isReady ? state.queuedMessages : const [],
      onSetQueued: vm.queueMessage,
      onClearQueued: vm.clearQueuedMessage,
      // Plan/29 — hold-to-talk voice input. The VM is route-scoped (bound in
      // app_router alongside ChatViewModel); InputBar listens to it directly,
      // so a read() is enough here.
      voice: context.read<VoiceInputViewModel>(),
      onVoiceHint: (hint) => _handleVoiceHint(context, hint),
      // Plan/30 — image attachments. takeImageForSend() reads + clears the
      // attached image so the inline image rides along with the (optionally
      // empty) caption. Attach-button gating by vision / already-attached is
      // internal to InputBar; the host only gates by channel availability.
      attachment: context.read<AttachmentViewModel>(),
      onOpenAttach: actionsEnabled
          ? () => _openAttach(context, context.read<AttachmentViewModel>())
          : null,
      // Plan/30-followup — paste image from clipboard (long-press field →
      // "Paste image"). Same channel-availability gate as the attach button.
      onPasteImage: actionsEnabled
          ? () => _pasteImage(context, context.read<AttachmentViewModel>())
          : null,
      sharedText: context.read<SharedTextInbox>(),
      draft: context.read<ComposerDraft>(),
      onSend: (text) {
        final image = context.read<AttachmentViewModel>().takeImagesForSend();
        vm.sendMessage(text, images: image);
      },
    );
  }

  /// Open the Camera/Gallery sheet and drive the picker. Captures the
  /// messenger up front so a permission-denied hint can deep-link to Settings
  /// after the async pick.
  static Future<void> _openAttach(
    BuildContext context,
    AttachmentViewModel vm,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final source = await showAttachSheet(context);
    if (source == null) return;
    AttachHint? hint;
    final sub = vm.hints.listen((h) => hint = h);
    switch (source) {
      case AttachSource.camera:
        await vm.pickFromCamera();
      case AttachSource.gallery:
        await vm.pickFromGallery();
    }
    await Future<void>.delayed(Duration.zero); // flush the hint microtask
    await sub.cancel();
    if (hint != null) _handleAttachHint(messenger, hint!);
  }

  /// Plan/30-followup — paste an image from the clipboard (no picker sheet).
  static Future<void> _pasteImage(
    BuildContext context,
    AttachmentViewModel vm,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    AttachHint? hint;
    final sub = vm.hints.listen((h) => hint = h);
    await vm.pickFromClipboard();
    await Future<void>.delayed(Duration.zero); // flush the hint microtask
    await sub.cancel();
    if (hint != null) _handleAttachHint(messenger, hint!);
  }

  static void _handleAttachHint(
    ScaffoldMessengerState messenger,
    AttachHint hint,
  ) {
    messenger.hideCurrentSnackBar();
    switch (hint) {
      case AttachHint.cameraPermissionDenied:
        messenger.showSnackBar(
          SnackBar(
            content: const Text(
              'Camera access is off — enable it in Settings to attach a photo.',
            ),
            duration: const Duration(seconds: 5),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: 'Settings',
              onPressed: AppSettings.openAppSettings,
            ),
          ),
        );
      case AttachHint.pickFailed:
        messenger.showSnackBar(
          const SnackBar(
            content: Text("Couldn't attach that image."),
            duration: Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      case AttachHint.noImageInClipboard:
        messenger.showSnackBar(
          const SnackBar(
            content: Text('No image in the clipboard.'),
            duration: Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  /// Surfaces the InputBar's voice hints (decision #10 permission path +
  /// the "hold to talk" nudge) as snackbars. Captures the messenger up front
  /// so the settings deep-link is safe across the async permission round-trip.
  static void _handleVoiceHint(BuildContext context, VoiceHint hint) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    switch (hint) {
      case VoiceHint.holdToTalk:
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Hold the mic to talk'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      case VoiceHint.permissionDenied:
        messenger.showSnackBar(
          SnackBar(
            content: const Text(
              'Microphone access is off — enable it in Settings to dictate.',
            ),
            duration: const Duration(seconds: 5),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: 'Settings',
              onPressed: AppSettings.openAppSettings,
            ),
          ),
        );
    }
  }

  static String _inferSessionName(List<ChatMessage> msgs) {
    for (final m in msgs) {
      if (m is UserMsg) return m.text.substring(0, m.text.length.clamp(0, 32));
    }
    return 'Piper';
  }
}

// ---------------------------------------------------------------------------

/// Maps a normal-message slot of the reverse transcript `ListView` to its
/// index in `messages`.
///
/// The list is `reverse: true`, so slot 0 is the bottom (newest). The
/// streaming bubble occupies slot 0 when [streaming]; the "Load more" tile
/// occupies the top slot (`itemCount - 1`) — both are handled by their own
/// branches in the item builder and are never passed here. Real messages
/// fill the remaining slots contiguously from the bottom, so slot `s` holds
/// the `(s - streamingOffset)`-th newest message → index
/// `msgCount - 1 - (s - streamingOffset)`.
///
/// Pre-existing bug this fixes: the old inline formula subtracted an extra 1
/// whenever the load-more tile was present, which duplicated the newest
/// message and dropped the oldest. Regression test:
/// `test/ui/chat/message_indexing_test.dart`.
@visibleForTesting
int messageIndexForSlot(int slot, int msgCount, {required bool streaming}) {
  final streamingOffset = streaming ? 1 : 0;
  return msgCount - 1 - (slot - streamingOffset);
}

/// Plan/fixusrmsgscrolling — how the transcript changed on a single update.
/// Drives the auto-scroll policy in [_MessageListState._applyScrollPolicy].
@visibleForTesting
enum TranscriptGrow {
  /// No change since last frame.
  none,

  /// Content grew at the bottom (newest): the streaming bubble grew, a message
  /// was finalized/appended, or only the streaming bubble moved.
  bottom,

  /// Content grew at the top (oldest): "Load more" prepended older messages.
  top,

  /// Wholesale replace: open, session switch, reconnect re-sync, compaction.
  replace,
}

/// Classifies how the transcript changed between two builds so the scroll
/// policy knows whether to re-pin (replace), follow the bottom (bottom
/// growth), or leave the viewport alone (top growth / none).
///
/// `messages` is oldest → newest; `reverse: true` puts the newest at the
/// bottom (index 0). So items appended at the *back* of the list grow the
/// bottom, while items prepended at the *front* (load-more) grow the top.
/// [streamChanged] flags a move of the bottom streaming bubble (the only thing
/// that can change while the message list is otherwise identical). Regression
/// test: `test/ui/chat/transcript_grow_test.dart`.
@visibleForTesting
TranscriptGrow classifyTranscriptGrow(
  List<ChatMessage> oldMsgs,
  List<ChatMessage> newMsgs,
  bool streamChanged,
) {
  if (identical(oldMsgs, newMsgs)) {
    return streamChanged ? TranscriptGrow.bottom : TranscriptGrow.none;
  }
  if (oldMsgs.isEmpty) return TranscriptGrow.replace; // open / switch in
  if (newMsgs.length < oldMsgs.length)
    return TranscriptGrow.replace; // compaction
  if (newMsgs.length == oldMsgs.length) {
    for (var i = 0; i < oldMsgs.length; i++) {
      if (oldMsgs[i].id != newMsgs[i].id) return TranscriptGrow.replace;
    }
    return TranscriptGrow.bottom; // same ids → only streaming moved
  }
  // newMsgs is longer: added at the back (newest = bottom) or front (oldest = top)?
  final added = newMsgs.length - oldMsgs.length;
  var prefix = true; // old is a prefix of new → appended at the back (bottom)
  for (var i = 0; i < oldMsgs.length; i++) {
    if (oldMsgs[i].id != newMsgs[i].id) {
      prefix = false;
      break;
    }
  }
  if (prefix) return TranscriptGrow.bottom;
  var suffix = true; // old is a suffix of new → prepended at the front (top)
  for (var i = 0; i < oldMsgs.length; i++) {
    if (oldMsgs[i].id != newMsgs[i + added].id) {
      suffix = false;
      break;
    }
  }
  if (suffix) return TranscriptGrow.top;
  return TranscriptGrow.replace;
}

class _MessageList extends StatefulWidget {
  final List<ChatMessage> messages;
  final StreamingMessage? streaming;
  final void Function(String, ApproveDecision) onDecide;
  final bool truncated;
  final VoidCallback? onLoadMore;

  const _MessageList({
    required this.messages,
    required this.streaming,
    required this.onDecide,
    required this.truncated,
    this.onLoadMore,
  });

  @override
  State<_MessageList> createState() => _MessageListState();
}

/// Plan/jumpusermsg — prev/next navigation between **user** messages.
///
/// The list is a `reverse: true` ListView (offset 0 = newest, at the
/// bottom). To jump to a given [UserMsg] we keep one [GlobalKey] per user
/// message id and drive [Scrollable.ensureVisible] on its context. A
/// generous [scrollCacheExtent] keeps the neighbour user messages mounted so
/// the step target is always reachable.
class _MessageListState extends State<_MessageList> {
  final ScrollController _scroll = ScrollController();

  /// One [GlobalKey] per user message id → its BuildContext feeds
  /// [Scrollable.ensureVisible]. Lazily created in build; pruned in
  /// [didUpdateWidget] when a message leaves the list (history reload /
  /// dedup).
  final Map<String, GlobalKey> _userKeys = {};

  /// Index (oldest → newest) of the user message we last jumped to. `-1` =
  /// not navigating → the next jump re-anchors to whatever user message sits
  /// at the top of the viewport. Reset on a user-driven flick so a manual
  /// scroll re-anchors instead of stepping from a stale position.
  int _navIndex = -1;

  /// Plan/fixusrmsgscrolling — whether the viewport is pinned to the bottom
  /// (newest). `reverse: true` makes the bottom = offset
  /// [ScrollPosition.minScrollExtent], so we're "pinned" while within
  /// [_bottomEpsilon] of it. Drives the auto-scroll policy in
  /// [_applyScrollPolicy]: pinned → new content keeps us at the bottom (and a
  /// history reload re-lands us there); unpinned → the viewport is held fixed
  /// while we read older history, and only resumes following the bottom once
  /// the user scrolls back to the end.
  bool _pinnedToBottom = true;

  /// How the transcript changed on the last [didUpdateWidget] — decides what
  /// [_applyScrollPolicy] does in the post-frame callback.
  TranscriptGrow _grow = TranscriptGrow.none;

  /// Previous frame's [ScrollPosition.maxScrollExtent], used to measure how
  /// much the content grew at the bottom so an unpinned viewport can be held
  /// in place instead of drifting toward the newest message.
  double _prevMaxExtent = 0;

  /// Tolerance (scroll px) within which we still count as "at the bottom".
  static const double _bottomEpsilon = 48;

  /// User messages in conversation order (oldest first). `messages` itself is
  /// oldest → newest, so this preserves that order.
  List<UserMsg> get _userMsgs => [
    for (final m in widget.messages)
      if (m is UserMsg) m,
  ];

  GlobalKey _keyFor(UserMsg m) => _userKeys.putIfAbsent(m.id, GlobalKey.new);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  /// Tracks [_pinnedToBottom] from the live position. Fires on every change —
  /// gesture OR programmatic — so the flag stays correct whether the user
  /// flicks up, we jump-to-bottom, or a guided jump scrolls away from the end.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    _pinnedToBottom = p.pixels <= p.minScrollExtent + _bottomEpsilon;
  }

  @override
  void didUpdateWidget(_MessageList old) {
    super.didUpdateWidget(old);
    final changed =
        !identical(old.messages, widget.messages) ||
        old.streaming != widget.streaming;
    if (changed) {
      _grow = classifyTranscriptGrow(
        old.messages,
        widget.messages,
        old.streaming != widget.streaming,
      );
      final live = <String>{};
      for (final m in widget.messages) {
        if (m is UserMsg) live.add(m.id);
      }
      _userKeys.removeWhere((id, _) => !live.contains(id));
      // History replaced (session switch / load-more / dedup) → the guided
      // pointer is no longer valid. Re-anchor on the next press.
      _navIndex = -1;
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  /// Post-frame auto-scroll policy (scheduled once per build).
  void _applyScrollPolicy() {
    // The post-frame callback is registered in build and can fire after this
    // State has been unmounted — bail before touching a disposed `_scroll`.
    if (!mounted) return;
    if (!_scroll.hasClients) {
      _grow = TranscriptGrow.none;
      return;
    }
    final p = _scroll.position;
    switch (_grow) {
      case TranscriptGrow.replace:
        // History reloaded (open / session switch / compaction) → land at the
        // newest, like opening a fresh chat.
        _pinnedToBottom = true;
        if ((p.pixels - p.minScrollExtent).abs() > 0.5) {
          p.jumpTo(p.minScrollExtent);
        }
        break;
      case TranscriptGrow.bottom:
        if (_pinnedToBottom) {
          // Following the live reply — stay glued to the newest.
          if ((p.pixels - p.minScrollExtent).abs() > 0.5) {
            p.jumpTo(p.minScrollExtent);
          }
        } else {
          // Reading older history while new content grows at the bottom. A
          // reverse list would otherwise drift the viewport toward the newest;
          // offset by exactly the bottom growth so the same content stays put.
          final delta = p.maxScrollExtent - _prevMaxExtent;
          if (delta.abs() > 0.5) {
            // Clamp the target: a net shrink at the bottom (e.g. the streaming
            // bubble replaced by a shorter finalized message) makes `delta < 0`,
            // which could push the target outside [min, max]ScrollExtent.
            double target = p.pixels + delta;
            if (target < p.minScrollExtent) {
              target = p.minScrollExtent;
            } else if (target > p.maxScrollExtent) {
              target = p.maxScrollExtent;
            }
            p.jumpTo(target);
          }
        }
        break;
      case TranscriptGrow.top:
        break; // load-more keeps the viewport; nothing to do.
      case TranscriptGrow.none:
        break;
    }
    _prevMaxExtent = p.maxScrollExtent;
    _grow = TranscriptGrow.none;
  }

  /// Index of the topmost user message overlapping the viewport — the natural
  /// "where am I" anchor for the first jump. Falls back to the newest user
  /// message when none is on screen.
  int _anchorIndex(List<UserMsg> userMsgs) {
    // The State's own render box is the Stack, which fills the Expanded
    // transcript area — same rect as the scroll viewport.
    final vp = context.findRenderObject() as RenderBox?;
    if (vp == null || !vp.hasSize) return userMsgs.length - 1;
    final vpTop = vp.localToGlobal(Offset.zero).dy;
    final vpBottom = vpTop + vp.size.height;
    int best = -1;
    double bestTop = double.infinity;
    for (var i = 0; i < userMsgs.length; i++) {
      final rb =
          _userKeys[userMsgs[i].id]?.currentContext?.findRenderObject()
              as RenderBox?;
      if (rb == null || !rb.hasSize) continue;
      final top = rb.localToGlobal(Offset.zero).dy;
      final bottom = top + rb.size.height;
      if (bottom <= vpTop || top >= vpBottom) continue; // off-screen
      if (top < bestTop) {
        bestTop = top;
        best = i;
      }
    }
    return best >= 0 ? best : userMsgs.length - 1;
  }

  void _jump({required bool older}) {
    final userMsgs = _userMsgs;
    final n = userMsgs.length;
    if (n < 2) return;
    // Defense-in-depth: didUpdateWidget already resets on history change,
    // but clamp anyway so a stale index can never range-error.
    final hasIdx = _navIndex >= 0 && _navIndex < n;
    final from = hasIdx ? _navIndex : _anchorIndex(userMsgs);
    final target = older ? from - 1 : from + 1;
    if (target < 0 || target >= n) return;
    final ctx = _userKeys[userMsgs[target].id]?.currentContext;
    if (ctx == null) return; // beyond cache — no-op; scroll closer first
    // alignment 0.5 = center: unambiguous in a reverse-anchored list, and
    // keeps the user message + the start of its answer on screen.
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    setState(() => _navIndex = target);
  }

  @override
  Widget build(BuildContext context) {
    final userMsgs = _userMsgs;
    final n = userMsgs.length;
    final showNav = n >= 2;
    // While navigating we know our index → disable at the bounds. Before that
    // (just anchored) both are enabled; the press clamps to a bound.
    final canOlder = _navIndex >= 0 ? _navIndex > 0 : true;
    final canNewer = _navIndex >= 0 ? _navIndex < n - 1 : true;

    final itemCount =
        widget.messages.length +
        (widget.streaming != null ? 1 : 0) +
        (widget.truncated && widget.onLoadMore != null ? 1 : 0);

    // `reverse: true` anchors the viewport to the bottom (offset 0 = newest).
    // Auto-scroll is driven explicitly by [_applyScrollPolicy] (scheduled
    // post-frame): pin to the bottom while the user is there, hold the
    // viewport fixed while they read older history, and re-pin on a history
    // reload. We never animate-on-every-rebuild — that fought reverse:true and
    // caused overlapping animations (flicker / runaway scroll) during streaming.
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyScrollPolicy());
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          // A user-driven flick abandons the guided pointer so the next jump
          // re-anchors to the new viewport.
          onNotification: (notif) {
            if (notif is UserScrollNotification && _navIndex != -1 && mounted) {
              setState(() => _navIndex = -1);
            }
            return false;
          },
          child: ListView.separated(
            controller: _scroll,
            reverse: true,
            // Keep ~1.5 screens of slack built above the viewport so the
            // prev/next user message (usually a few hundred px away) is
            // already mounted for ensureVisible to target.
            scrollCacheExtent: ScrollCacheExtent.pixels(1500),
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
            itemCount: itemCount,
            separatorBuilder: (context, idx) => const SizedBox(height: 14),
            itemBuilder: (_, i) {
              // "Load more" button at the top (index = itemCount - 1)
              if (widget.truncated &&
                  widget.onLoadMore != null &&
                  i == itemCount - 1) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: TextButton.icon(
                      icon: const Icon(LucideIcons.refreshCw, size: 16),
                      label: const Text('Load more messages'),
                      onPressed: widget.onLoadMore,
                    ),
                  ),
                );
              }
              // Streaming bubble at bottom (index 0)
              if (widget.streaming != null && i == 0) {
                return KeyedSubtree(
                  key: const ValueKey('streaming'),
                  child: StreamingBubble(widget.streaming!),
                );
              }
              // `reverse: true` → slot 0 is the bottom (newest). The streaming
              // bubble (slot 0, when present) and the "Load more" tile (the top
              // slot) are handled by their own branches above; real messages fill
              // the remaining slots contiguously from the bottom, so a message
              // slot maps directly via [messageIndexForSlot].
              final msgIdx = messageIndexForSlot(
                i,
                widget.messages.length,
                streaming: widget.streaming != null,
              );
              final msg = widget.messages[msgIdx];
              return KeyedSubtree(
                key: ValueKey(msg.id),
                child: switch (msg) {
                  // Plan/jumpusermsg — tag the bubble so we can scroll to it.
                  UserMsg() => UserBubble(msg, key: _keyFor(msg)),
                  AssistantMsg() => AssistantBubble(msg),
                  // Plan/114 — agent-pushed image (show_image tool): tappable
                  // bubble that opens the full-screen viewer.
                  AgentImageMsg() => AgentImageBubble(msg),
                  ToolEvent() => ToolRequestCard(
                    tool: msg,
                    onDecide: widget.onDecide,
                  ),
                  CompactionMsg() => CompactionBubble(msg),
                },
              );
            },
          ),
        ),
        if (showNav)
          Positioned(
            top: 8,
            right: 10,
            child: _UserMsgNav(
              canOlder: canOlder,
              canNewer: canNewer,
              position: _navIndex >= 0 ? _navIndex + 1 : null,
              total: n,
              onOlder: () => _jump(older: true),
              onNewer: () => _jump(older: false),
            ),
          ),
      ],
    );
  }
}

/// Floating prev/next (older/newer user message) control — a compact vertical
/// pill pinned top-right of the transcript. Shows a `k/total` counter while a
/// guided jump is in progress; hides entirely until there are ≥ 2 user
/// messages.
class _UserMsgNav extends StatelessWidget {
  final bool canOlder;
  final bool canNewer;
  final int? position;
  final int total;
  final VoidCallback onOlder;
  final VoidCallback onNewer;

  const _UserMsgNav({
    required this.canOlder,
    required this.canNewer,
    required this.position,
    required this.total,
    required this.onOlder,
    required this.onNewer,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.bg.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _button(
            context,
            LucideIcons.chevronUp,
            onOlder,
            canOlder,
            'Previous question',
          ),
          if (position != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '$position/$total',
                style: context.typo.monoSmall.copyWith(
                  color: colors.muted,
                  fontSize: 10,
                ),
              ),
            ),
          _button(
            context,
            LucideIcons.chevronDown,
            onNewer,
            canNewer,
            'Next question',
          ),
        ],
      ),
    );
  }

  Widget _button(
    BuildContext context,
    IconData icon,
    VoidCallback onTap,
    bool enabled,
    String tooltip,
  ) {
    final colors = context.colors;
    return IconButton(
      icon: Icon(icon, size: 18, color: enabled ? colors.text : colors.muted2),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      onPressed: enabled ? onTap : null,
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _EmptyState({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: colors.muted, size: 48),
          const SizedBox(height: 16),
          Text(message, style: TextStyle(color: colors.muted, fontSize: 14)),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 24),
            FilledButton(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: colors.onAccent,
              ),
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

class _RevokedBanner extends StatelessWidget {
  final VoidCallback onRePair;
  const _RevokedBanner({required this.onRePair});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.red.shade900.withValues(alpha: 0.85),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(LucideIcons.unlink, color: Colors.white, size: 15),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Pairing revoked by Mac — re-pair to continue',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          GestureDetector(
            onTap: onRePair,
            child: const Text(
              'Re-pair',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One labelled key/value row in the session-info dialog. The value is
/// selectable so the user can copy the path / device name.
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  /// Plan/107 — optional colored value (posh-git-style git status). When
  /// set, renders as a RichText instead of the plain [value] string.
  final TextSpan? richValue;
  const _InfoRow({required this.label, this.value = '', this.richValue});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontFamily: kMonoFamily,
              fontSize: 10,
              color: colors.muted,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 2),
          richValue != null
              ? SelectableText.rich(richValue!)
              : SelectableText(
                  value,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontSize: 13,
                    color: colors.text,
                  ),
                ),
        ],
      ),
    );
  }
}

/// Plan/112 — list of tracked git worktrees for the active session's base
/// repo. Each row reopens the worktree (opens a terminal there, no new
/// worktree) on tap and removes it (git worktree remove + branch delete) via
/// the trailing trash icon. Refreshes after a remove; auto-drops stale entries
/// (the Pi reconciles the registry against the filesystem on each list).
class _WorktreesSection extends StatefulWidget {
  final IActionsRepository actions;
  final String? base;
  const _WorktreesSection({required this.actions, required this.base});

  @override
  State<_WorktreesSection> createState() => _WorktreesSectionState();
}

class _WorktreesSectionState extends State<_WorktreesSection> {
  Future<List<WireWorktree>>? _future;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _future = widget.actions.listWorktrees(base: widget.base);
    });
  }

  Future<void> _reopen(WireWorktree w) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await widget.actions.openTerminal(worktreePath: w.path);
      messenger.showSnackBar(
        SnackBar(
          content: Text(res.ok ? res.message : 'Failed: ${res.message}'),
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Offline — try again.')),
      );
    }
  }

  Future<void> _remove(WireWorktree w) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: Text(
          'Remove worktree ${w.branch}?\nThis deletes the folder and branch.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final res = await widget.actions.removeWorktree(w.id);
      messenger.showSnackBar(
        SnackBar(
          content: Text(res.ok ? res.message : 'Failed: ${res.message}'),
        ),
      );
      if (res.ok) _refresh();
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Offline — try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FutureBuilder<List<WireWorktree>>(
      future: _future,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const _InfoRow(label: 'Worktrees', value: 'loading…');
        }
        if (snap.hasError) {
          return const _InfoRow(label: 'Worktrees', value: 'unavailable');
        }
        final value = snap.data ?? const <WireWorktree>[];
        if (value.isEmpty) {
          return const _InfoRow(label: 'Worktrees', value: 'none');
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'WORKTREES',
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontSize: 10,
                  color: colors.muted,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            for (final w in value)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => _reopen(w),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: SelectableText(
                            '${w.branch}  ·  ${_relativeAge(w.createdAt)}',
                            style: TextStyle(
                              fontFamily: kMonoFamily,
                              fontSize: 12,
                              color: colors.accent,
                            ),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        LucideIcons.trash2,
                        size: 16,
                        color: colors.error,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () => _remove(w),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Compact relative age from an ISO timestamp ("just now" / "5m ago" / …).
String _relativeAge(String iso) {
  if (iso.isEmpty) return '';
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return '';
  final d = DateTime.now().difference(dt);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}
