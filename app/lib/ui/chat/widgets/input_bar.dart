import 'dart:async';

import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/share/composer_draft.dart';
import 'package:app/data/share/shared_text_inbox.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/voice/states/voice_input_state.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/chat/voice/widgets/recording_strip.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// InputBar — bottom message composer.
// - Disabled (grayed) when offline.
// - During streaming, empty composer shows Stop; typed text sends steering.
// - Plan/28 — quick actions (⚙) icon sits to the left of the attach
//   button and is visible only while the field is empty (so it never
//   competes with the send affordance).
// - Plan/29 — when [voice] is provided, the mic becomes hold-to-talk:
//   long-press starts recording (a WhatsApp-style RecordingStrip replaces
//   the row), slide left past the threshold cancels, release transcribes
//   and drops the text into the (empty) field for manual review/send. The
//   recognizer never auto-sends.

/// One-shot UI hint the composer asks the host page to surface (snackbar /
/// settings deep-link). Keeps InputBar free of `BuildContext`-bound effects.
enum VoiceHint {
  /// User tapped the mic instead of holding it.
  holdToTalk,

  /// Mic / speech permission was denied — guide to system Settings (#10).
  permissionDenied,
}

/// Plan/127 — composer delivery mode while the room is working.
/// Steer injects into the active turn; Follow-up queues behind it.
enum _SteerMode { steer, followUp }

class InputBar extends StatefulWidget {
  final bool disabled; // offline or no peer
  final bool streaming; // show cancel instead of send

  /// Plan/134 — the room is blocked on a user-facing ctx.ui prompt. The
  /// composer hint switches to "Waiting for your answer…" (taking priority
  /// over the steer hint) so the user understands why the turn stalled.
  /// The field stays ENABLED: typing queues/steers like any working turn —
  /// pi-ask sheets are answered in the sheet, foreign prompts at the
  /// terminal.
  final bool waitingForInput;

  /// Plan/107c — active model name shown as the composer hint when idle
  /// (replaces the generic "Send a message…" so the user always sees which
  /// model a send will use). Null/empty → falls back to "Send a message…".
  final String? model;
  /// Plan/127 — carries the chosen delivery mode while working (steer |
  /// followUp); null on idle sends (a normal fresh turn).
  final void Function(String text, UserMessageStreamingBehavior? behavior) onSend;
  final VoidCallback? onCancel;
  final VoidCallback? onOpenQuickActions;
  final VoidCallback? onStartAudio;

  /// Pi-side queued follow-ups. Empty means no queued messages.
  final List<QueuedMsg> queuedMessages;
  final void Function(String text)? onSetQueued;
  final void Function(String id)? onClearQueued;

  /// Plan/29 — voice-input ViewModel. When null the mic falls back to the
  /// legacy [onStartAudio] tap (and existing tests pump InputBar without it).
  final VoiceInputViewModel? voice;

  /// Plan/29 — surfaces a [VoiceHint] to the host page for a snackbar /
  /// settings deep-link.
  final void Function(VoiceHint hint)? onVoiceHint;

  /// Plan/30 — image-attachment ViewModel (preview state + model vision).
  /// Null in tests / when attachments aren't wired.
  final AttachmentViewModel? attachment;

  /// Plan/30 — open the Camera/Gallery sheet. Null disables the attach
  /// button (offline/streaming); vision/has-image gating is internal.
  final VoidCallback? onOpenAttach;

  /// Plan/30-followup — paste an image from the clipboard (e.g. a
  /// screenshot). Wired into the text field's "Paste image" toolbar entry.
  /// Null hides the entry (offline/streaming).
  final VoidCallback? onPasteImage;

  /// Plan/104 — text shared into the app (Share sheet → ACTION_SEND
  /// text/plain). When provided, the InputBar consumes any pending text on
  /// mount + when a deposit arrives, dropping it into the field (replace if
  /// empty, append on a new line otherwise). Null in tests.
  final SharedTextInbox? sharedText;

  /// Plan/106 — the follow-me composer draft. When provided, the field
  /// restores its text on mount and writes every edit back, so an unsent
  /// draft survives a session switch. Null in tests.
  final ComposerDraft? draft;

  /// Plan/109 — load the scoped model list for the send-with-model dropdown.
  final Future<List<WireModel>> Function()? onLoadModels;

  /// Plan/109 — send the draft with a ONE-SHOT model override (the second
  /// send button). Null disables the dropdown button. The Pi extension
  /// switches the live model for this message only, then reverts; the
  /// session default is never changed.
  final void Function(String text, WireModel model)? onSendWithModel;

  const InputBar({
    super.key,
    required this.onSend,
    this.onCancel,
    this.onOpenQuickActions,
    this.onStartAudio,
    this.queuedMessages = const [],
    this.onSetQueued,
    this.onClearQueued,
    this.voice,
    this.onVoiceHint,
    this.attachment,
    this.onOpenAttach,
    this.onPasteImage,
    this.sharedText,
    this.draft,
    this.disabled = false,
    this.streaming = false,
    this.waitingForInput = false,
    this.model,
    this.onLoadModels,
    this.onSendWithModel,
  });

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  /// How far left the press must slide to arm slide-to-cancel (logical px).
  static const double _cancelThreshold = 90;

  final _controller = TextEditingController();
  // Owns the field's focus so we can intercept hardware Enter on its OWN
  // node (the primary/leaf focus). An ancestor Focus runs too late: the
  // FocusManager dispatches leaf→root, so the field's multiline newline
  // handling would consume Enter before an ancestor ever sees it.
  late final FocusNode _focusNode = FocusNode(onKeyEvent: _onComposerKey);
  bool _empty = true;
  bool _cancelArmed = false;
  // Plan/127 — composer delivery mode while working (Steer | Follow-up).
  // Defaults to Steer; reset per working turn in didUpdateWidget.
  _SteerMode _steerMode = _SteerMode.steer;
  // True while the hold-to-talk gesture is active. Lets `_beginVoice` tell
  // whether the user is still holding once `startRecording` resolves — if not
  // (the permission prompt ended the hold), the recording is discarded.
  bool _holding = false;
  StreamSubscription<String>? _transcriptSub;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChange);
    _subscribeTranscripts();
    // Plan/104 — shared text (Share sheet). Consume any pending text now
    // (cold-start share) + react to a warm share while the chat is open.
    widget.sharedText?.addListener(_onSharedText);
    // Plan/106 — restore the follow-me draft text (survives a session switch).
    final draft = widget.draft;
    if (draft != null && draft.text.isNotEmpty) {
      _controller.text = draft.text;
      _controller.selection =
          TextSelection.collapsed(offset: draft.text.length);
    }
    _onSharedText();
  }

  @override
  void didUpdateWidget(InputBar old) {
    super.didUpdateWidget(old);
    if (!identical(old.voice, widget.voice)) {
      _transcriptSub?.cancel();
      _subscribeTranscripts();
    }
    // Plan/127 — each new working turn starts the toggle at Steer (default).
    if (widget.streaming && !old.streaming) {
      _steerMode = _SteerMode.steer;
    }
  }

  void _subscribeTranscripts() {
    _transcriptSub = widget.voice?.transcripts.listen(_onTranscript);
  }

  void _onTranscript(String text) {
    if (!mounted || text.isEmpty) return; // empty → no-op (#12)
    // The field is empty by construction (mic only shows when empty), so we
    // replace rather than concatenate (#non-objetivo: no merge).
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
  }

  // Plan/104 — a shared text (URL/snippet via the Share sheet) lands here.
  // Replace when the field is empty, append on a new line when it isn't.
  void _onSharedText() {
    final inbox = widget.sharedText;
    if (inbox == null || !mounted) return;
    final t = inbox.consume();
    if (t == null || t.isEmpty) return;
    final existing = _controller.text;
    _controller.text = existing.isEmpty ? t : '$existing\n$t';
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
  }

  void _onTextChange() {
    widget.draft?.setText(_controller.text);
    final next = _controller.text.isEmpty;
    if (next == _empty) return;
    setState(() {
      _empty = next;
    });
  }

  @override
  void dispose() {
    widget.sharedText?.removeListener(_onSharedText);
    _transcriptSub?.cancel();
    _controller.removeListener(_onTextChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    // Plan/30 — an attached image makes an empty-caption send valid.
    final hasImage = widget.attachment?.hasImage ?? false;
    if (text.isEmpty && !hasImage) return;
    _controller.clear();
    // Plan/127 — while working, deliver in the toggle's chosen mode; while
    // idle, a normal send (null).
    final behavior = widget.streaming
        ? (_steerMode == _SteerMode.followUp
            ? UserMessageStreamingBehavior.followUp
            : UserMessageStreamingBehavior.steer)
        : null;
    widget.onSend(text, behavior);
  }

  /// Plan/109 — send the current draft with a one-shot model override.
  void _submitWithModel(WireModel m) {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    widget.onSendWithModel?.call(text, m);
  }

  /// Plan/109 — open the scoped-model dropdown; picking one sends the draft
  /// with that model for this turn only.
  Future<void> _openModelSendPicker() async {
    final loader = widget.onLoadModels;
    final cb = widget.onSendWithModel;
    if (loader == null || cb == null) return;
    if (_controller.text.trim().isEmpty) return;
    final models = await loader().catchError((_) => <WireModel>[]);
    if (!mounted || models.isEmpty) return;
    final picked = await showModalBottomSheet<WireModel>(
      context: context,
      backgroundColor: context.colors.bg,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      isScrollControlled: true,
      showDragHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _ModelSendSheet(models: models),
    );
    if (picked != null) _submitWithModel(picked);
  }

  void _editQueued(QueuedMsg item) {
    if (!item.editable) return;
    widget.onClearQueued?.call(item.id);
    _controller.text = item.text;
    _controller.selection = TextSelection.collapsed(offset: item.text.length);
    _focusNode.requestFocus();
  }

  /// Hardware-keyboard behaviour (iPad keyboard case, etc.): plain Enter
  /// SENDS, Shift+Enter inserts a newline. On a touch soft-keyboard the
  /// newline arrives via `performAction` (not a key event), so this never
  /// fires there — the field keeps growing and the user sends with the
  /// composer button, exactly as before.
  KeyEventResult _onComposerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;
    // TEMP diag (input multiline Enter): if this line never prints when you
    // press Enter on the emulator, Android is routing it through the IME and
    // NOT as a hardware key event — remove once the behaviour is confirmed.
    debugPrint(
      '[input.enter] shift=${HardwareKeyboard.instance.isShiftPressed} '
      'disabled=${widget.disabled} streaming=${widget.streaming}',
    );
    // Don't intercept while disabled, or mid-IME-composition (a CJK
    // candidate is confirmed with Enter, not sent) — let the field/IME deal.
    if (widget.disabled || !_controller.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      // Shift+Enter → newline. Inserted explicitly (and consumed) so the
      // behaviour is identical on every platform instead of depending on
      // the framework's default multiline key handling.
      _insertNewlineAtCursor();
      return KeyEventResult.handled;
    }
    _submit();
    return KeyEventResult.handled;
  }

  /// Replaces the current selection (or inserts at the caret) with a newline
  /// and leaves the caret right after it.
  void _insertNewlineAtCursor() {
    final value = _controller.value;
    final sel = value.selection;
    if (!sel.isValid) {
      final text = '${value.text}\n';
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      return;
    }
    final text = '${sel.textBefore(value.text)}\n${sel.textAfter(value.text)}';
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: sel.start + 1),
    );
  }

  // --- voice gesture ---------------------------------------------------------

  void _onVoiceStart() {
    _holding = true;
    if (_cancelArmed) setState(() => _cancelArmed = false);
    unawaited(_beginVoice());
  }

  Future<void> _beginVoice() async {
    final voice = widget.voice;
    if (voice == null) return;
    await voice.startRecording();
    if (!mounted) return;
    // Bug fix: on first use the OS permission prompt steals the hold — the
    // finger lifts to tap "Allow", so the press ends BEFORE recording actually
    // begins (state isn't VoiceRecording yet, so the release no-ops). When
    // `startRecording` then resolves and starts, the composer was left stuck
    // "recording" with no finger down. If the gesture is already over by the
    // time we get here, discard that phantom recording.
    if (!_holding && voice.state is VoiceRecording) {
      await voice.cancel();
      if (!mounted) return;
    }
    final s = voice.state;
    if (s is VoiceUnavailable &&
        s.reason == VoiceUnavailableReason.permissionDenied) {
      widget.onVoiceHint?.call(VoiceHint.permissionDenied);
    }
  }

  void _onVoiceMove(LongPressMoveUpdateDetails details) {
    if (widget.voice?.state is! VoiceRecording) return;
    final armed = details.offsetFromOrigin.dx < -_cancelThreshold;
    if (armed != _cancelArmed) setState(() => _cancelArmed = armed);
  }

  void _onVoiceEnd() {
    _holding = false;
    final voice = widget.voice;
    final armed = _cancelArmed;
    if (_cancelArmed) setState(() => _cancelArmed = false);
    if (voice == null || voice.state is! VoiceRecording) return;
    if (armed) {
      unawaited(voice.cancel());
    } else {
      // Transcript arrives via voice.transcripts → _onTranscript, the same
      // path the 60s cap uses — release never populates the field directly.
      unawaited(voice.stopAndTranscribe());
    }
  }

  void _onVoiceTap() => widget.onVoiceHint?.call(VoiceHint.holdToTalk);

  @override
  Widget build(BuildContext context) {
    final listenables = <Listenable>[
      if (widget.voice != null) widget.voice!,
      if (widget.attachment != null) widget.attachment!,
    ];
    if (listenables.isEmpty) return _composer(context);
    // Rebuild on every voice/attachment emit (tick / level / availability /
    // pick) so the strip + preview animate even when no ancestor watches them.
    return ListenableBuilder(
      listenable: Listenable.merge(listenables),
      builder: (context, _) => _composer(context),
    );
  }

  Widget _composer(BuildContext context) {
    final colors = context.colors;
    final voiceState = widget.voice?.state;
    final attachState = widget.attachment?.state;
    final canInteract = !widget.disabled;
    final hasQuickActions = widget.onOpenQuickActions != null;
    final recording = voiceState is VoiceRecording;
    final transcribing = voiceState is VoiceTranscribing;
    final showStrip = recording || transcribing;
    final voiceUnsupported =
        voiceState is VoiceUnavailable &&
        voiceState.reason == VoiceUnavailableReason.unsupported;

    // Plan/30 — attachment. Plan/103-followup: do NOT hard-disable on the
    // model's declared `vision` flag. Runtime packages (e.g.
    // pi-multimodal-proxy) add image support to text-only models WITHOUT
    // flipping that flag (fallback mode routes images to a vision model),
    // so the gate was unreliable and hid a working feature. The button now
    // gates only on channel availability, not streaming, and no image
    // already attached.
    final hasImage = attachState is AttachmentAttached;
    final hasContent = !_empty || hasImage;
    final attachEnabled =
        widget.onOpenAttach != null &&
        canInteract &&
        !widget.streaming &&
        !showStrip &&
        !hasImage;

    final showQuickActions =
        _empty &&
        !hasImage &&
        canInteract &&
        !widget.streaming &&
        !showStrip &&
        hasQuickActions;

    // Plan/109 — the second (dropdown) send button: send the draft with a
    // one-shot model override. Only with text + an open channel + callbacks.
    final canSendWithModel =
        !_empty &&
        canInteract &&
        !widget.streaming &&
        widget.onSendWithModel != null &&
        widget.onLoadModels != null;

    // During a working turn with typed content, the main action sends steering;
    // keep a compact Stop affordance beside it so cancellation remains reachable.
    final showInlineStop =
        widget.streaming &&
        hasContent &&
        canInteract &&
        !showStrip &&
        widget.onCancel != null;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 22),
      decoration: BoxDecoration(
        color: colors.bg,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Stack(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasImage)
                _AttachmentPreview(
                  images: attachState.images,
                  onRemoveAt: widget.attachment!.removeImageAt,
                ),
              for (final item in widget.queuedMessages)
                _QueuedMessagePreview(
                  text: item.text,
                  editable: item.editable,
                  onTap: item.editable ? () => _editQueued(item) : null,
                  onClear: item.editable
                      ? () => widget.onClearQueued?.call(item.id)
                      : null,
                ),
              if (widget.streaming && canInteract && !showStrip)
                _SteerModeToggle(
                  mode: _steerMode,
                  onChanged: (m) => setState(() => _steerMode = m),
                ),
              Row(
                children: [
                  _QuickActionsButton(
                    show: showQuickActions,
                    onPressed: widget.onOpenQuickActions,
                  ),
                  _AttachButton(
                    enabled: attachEnabled,
                    onTap: widget.onOpenAttach,
                  ),
                  const SizedBox(width: 10),
                  // Text field (doubles as the image caption when one is set).
                  Expanded(
                    child: TextField(
                      // Intercept hardware Enter on the field's OWN focus
                      // node (the primary/leaf): plain Enter sends,
                      // Shift+Enter newlines — see _onComposerKey. Must be
                      // the leaf, not an ancestor Focus, or the multiline
                      // newline handling consumes Enter first.
                      focusNode: _focusNode,
                      controller: _controller,
                      enabled: canInteract,
                      // Grow with the content: starts at one line, expands up
                      // to 6 then scrolls internally. On a touch soft-keyboard
                      // Enter inserts a newline; sending is via the composer
                      // button (hardware Enter sends — see _onComposerKey).
                      minLines: 1,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      // Plan/30-followup — add a "Paste image" entry to the
                      // long-press selection toolbar so a clipboard screenshot
                      // (or any copied image) attaches directly.
                      contextMenuBuilder: (context, editableTextState) {
                        return AdaptiveTextSelectionToolbar.buttonItems(
                          buttonItems: <ContextMenuButtonItem>[
                            ...editableTextState.contextMenuButtonItems,
                            if (widget.onPasteImage != null)
                              ContextMenuButtonItem(
                                label: 'Paste image',
                                onPressed: () {
                                  editableTextState.hideToolbar();
                                  widget.onPasteImage!();
                                },
                              ),
                          ],
                          anchors: editableTextState.contextMenuAnchors,
                        );
                      },
                      style: TextStyle(
                        fontFamily: kMonoFamily,
                        fontSize: 13,
                        color: colors.text,
                      ),
                      cursorColor: colors.accent,
                      decoration: InputDecoration(
                        hintText: widget.disabled
                            ? 'Offline…'
                            : widget.waitingForInput
                            ? 'Waiting for your answer…'
                            : widget.streaming
                            ? (_steerMode == _SteerMode.followUp
                                ? 'Queue a follow-up…'
                                : 'Steer current response…')
                            : hasImage
                            ? 'Add a caption…'
                            : (widget.model != null &&
                                    widget.model!.isNotEmpty
                                ? widget.model!
                                : 'Send a message…'),
                        hintStyle: TextStyle(
                          color: colors.muted,
                          fontFamily: kMonoFamily,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        filled: true,
                        fillColor: colors.inputFill,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(19),
                          borderSide: BorderSide(color: colors.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(19),
                          borderSide: BorderSide(color: colors.border),
                        ),
                        disabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(19),
                          borderSide: BorderSide(
                            color: colors.border.withValues(alpha: 0.5),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(19),
                          borderSide: BorderSide(
                            color: colors.accent,
                            width: 1.2,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _ComposerActionButton(
                    streaming: widget.streaming,
                    hasContent: hasContent,
                    disabled: widget.disabled,
                    onSendText: _submit,
                    onCancel: widget.onCancel,
                    onStartAudio: widget.onStartAudio,
                    voiceEnabled: widget.voice != null,
                    voiceUnsupported: voiceUnsupported,
                    onVoiceLongPressStart: _onVoiceStart,
                    onVoiceLongPressMoveUpdate: _onVoiceMove,
                    onVoiceLongPressEnd: _onVoiceEnd,
                    onVoiceTap: _onVoiceTap,
                  ),
                  if (canSendWithModel) ...[
                    const SizedBox(width: 6),
                    _ModelSendButton(onTap: _openModelSendPicker),
                  ],
                  if (showInlineStop) ...[
                    const SizedBox(width: 8),
                    _InlineStopButton(onTap: widget.onCancel!),
                  ],
                ],
              ),
            ],
          ),
          // Recording strip — overlays the row (decision #11) while the mic's
          // GestureDetector stays mounted underneath so the same long-press
          // keeps feeding move/end events across the swap. IgnorePointer so
          // the overlay never steals the in-flight gesture.
          if (showStrip)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: colors.bg,
                  child: Center(
                    child: recording
                        ? RecordingStrip(
                            level: voiceState.level,
                            elapsed: voiceState.elapsed,
                            maxDuration:
                                widget.voice?.maxDuration ??
                                const Duration(seconds: 60),
                            cancelArmed: _cancelArmed,
                          )
                        : const _TranscribingStrip(),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shows the message committed for auto-send after the current turn ends.
/// Tapping pulls it back into the composer for edit and cancels the pending
/// auto-send; X drops it.
class _QueuedMessagePreview extends StatelessWidget {
  const _QueuedMessagePreview({
    required this.text,
    required this.editable,
    this.onTap,
    this.onClear,
  });

  final String text;
  final bool editable;
  final VoidCallback? onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4, bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('input-bar-queued-preview'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: colors.accent.withValues(alpha: 0.35)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    LucideIcons.messageCircle,
                    size: 15,
                    color: colors.accent,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        editable ? 'Queued. Tap to edit.' : 'Queued follow-up.',
                        style: TextStyle(
                          color: colors.accent,
                          fontFamily: kMonoFamily,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        text,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontFamily: kMonoFamily,
                          fontSize: 12,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onClear != null) ...[
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: IconButton(
                      key: const Key('input-bar-clear-queued'),
                      tooltip: 'Clear queued message',
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      splashRadius: 16,
                      onPressed: onClear,
                      icon: Icon(LucideIcons.x, color: colors.muted2),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Plan/127 — segmented [Steer | Follow-up] toggle shown above the composer
/// while the room is working. Steer injects into the active turn (route
/// glyph, accent); Follow-up queues behind it (clock glyph). Full-width so
/// both targets are unambiguous one-taps; selection is owned by the composer.
class _SteerModeToggle extends StatelessWidget {
  const _SteerModeToggle({required this.mode, required this.onChanged});

  final _SteerMode mode;
  final ValueChanged<_SteerMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget segment({
      required _SteerMode value,
      required IconData icon,
      required String label,
    }) {
      final selected = mode == value;
      final fg = selected ? colors.onAccent : colors.muted2;
      return Expanded(
        child: Tooltip(
          message: label,
          child: InkWell(
            onTap: () => onChanged(value),
            borderRadius: BorderRadius.circular(9),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: selected ? colors.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 14, color: fg),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4, bottom: 8),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: colors.inputFill,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.border),
        ),
        padding: const EdgeInsets.all(3),
        child: Row(
          children: [
            segment(
              value: _SteerMode.steer,
              icon: LucideIcons.route,
              label: 'Steer',
            ),
            segment(
              value: _SteerMode.followUp,
              icon: LucideIcons.clock,
              label: 'Follow-up',
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact Stop affordance shown beside Send while steering text is typed.
class _InlineStopButton extends StatelessWidget {
  const _InlineStopButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GestureDetector(
      key: const Key('input-bar-inline-stop'),
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: colors.error.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: colors.error.withValues(alpha: 0.55)),
        ),
        child: Icon(LucideIcons.square600, color: colors.error, size: 18),
      ),
    );
  }
}

/// Plan/109 — the second send button. Opens the scoped-model dropdown;
/// picking a model sends the draft with it as a one-shot override.
class _ModelSendButton extends StatelessWidget {
  const _ModelSendButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      message: 'Send with model',
      child: GestureDetector(
        key: const Key('input-bar-model-send'),
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: colors.accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(19),
            border: Border.all(color: colors.accent.withValues(alpha: 0.55)),
          ),
          child: Icon(LucideIcons.layers, color: colors.accent, size: 18),
        ),
      ),
    );
  }
}

/// Plan/109 — dropdown sheet listing the scoped models. Tapping one returns
/// it via [Navigator.pop]; the caller sends the draft with it (one-shot).
class _ModelSendSheet extends StatelessWidget {
  const _ModelSendSheet({required this.models});

  final List<WireModel> models;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mq = MediaQuery.of(context);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: mq.size.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Send with model (this message only)',
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontSize: 12,
                    color: colors.muted,
                  ),
                ),
              ),
            ),
            Divider(color: colors.border, height: 1, thickness: 1),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 16),
                itemCount: models.length,
                separatorBuilder: (_, _) =>
                    Divider(color: colors.border, height: 1, thickness: 1),
                itemBuilder: (_, i) {
                  final m = models[i];
                  return InkWell(
                    onTap: () => Navigator.of(context).pop(m),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  m.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: kMonoFamily,
                                    fontSize: 13,
                                    color: colors.text,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${m.provider} · ${m.id}',
                                  style: TextStyle(
                                    fontFamily: kMonoFamily,
                                    fontSize: 10,
                                    color: colors.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (m.reasoning)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: colors.accent.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Text(
                                'reasoning',
                                style: TextStyle(
                                  fontFamily: kMonoFamily,
                                  fontSize: 9,
                                  color: colors.accent,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Plan/30 — the attach (paperclip) button. Always visible; greyed + inert
/// when [enabled] is false (offline/streaming, or an image is already
/// attached). A text-only model no longer greys it — runtime packages (e.g.
/// pi-multimodal-proxy) can add image support without flipping the declared
/// vision flag.
class _AttachButton extends StatelessWidget {
  const _AttachButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        key: const Key('input-bar-attach'),
        padding: EdgeInsets.zero,
        iconSize: 18,
        splashRadius: 18,
        tooltip: 'Attach image',
        icon: Icon(
          LucideIcons.paperclip,
          color: enabled
              ? context.colors.muted2
              : context.colors.muted.withValues(alpha: 0.35),
        ),
        onPressed: enabled ? onTap : null,
      ),
    );
  }
}

/// Plan/30 — the composer image preview: rounded thumbnails with an "X"
/// each to discard before sending (decision #4). Plan/105: renders N pages
/// for a shared PDF in a horizontal scroll.
class _AttachmentPreview extends StatelessWidget {
  const _AttachmentPreview({required this.images, required this.onRemoveAt});

  final List<PickedImage> images;
  final void Function(int index) onRemoveAt;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('attach-preview'),
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: SizedBox(
        height: 84,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var i = 0; i < images.length; i++)
                _AttachmentThumb(
                  key: ValueKey('attach-thumb-$i'),
                  image: images[i],
                  onRemove: () => onRemoveAt(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A single 84×84 thumbnail with a discard "X".
class _AttachmentThumb extends StatelessWidget {
  const _AttachmentThumb({super.key, required this.image, required this.onRemove});

  final PickedImage image;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 84,
      height: 84,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              image.bytes,
              width: 72,
              height: 72,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
          ),
          Positioned(
            top: -4,
            right: 8,
            child: GestureDetector(
              key: const Key('attach-remove'),
              onTap: onRemove,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  shape: BoxShape.circle,
                  border: Border.all(color: context.colors.border),
                ),
                padding: const EdgeInsets.all(3),
                child: Icon(
                  LucideIcons.x,
                  size: 13,
                  color: context.colors.text,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TranscribingStrip extends StatelessWidget {
  const _TranscribingStrip();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      key: const Key('transcribing-strip'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colors.accent,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          'transcribing…',
          style: TextStyle(
            fontFamily: kMonoFamily,
            fontSize: 12,
            color: colors.muted2,
          ),
        ),
      ],
    );
  }
}

class _QuickActionsButton extends StatefulWidget {
  const _QuickActionsButton({required this.show, required this.onPressed});

  final bool show;
  final VoidCallback? onPressed;

  @override
  State<_QuickActionsButton> createState() => _QuickActionsButtonState();
}

class _QuickActionsButtonState extends State<_QuickActionsButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _sizeFactor;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      value: widget.show ? 1.0 : 0.0,
    );
    // Timeline (forward = appear): first grow [0.0–0.5], then fade in [0.5–1.0].
    // On reverse (disappear) the order flips → fade out first, then shrink.
    _sizeFactor = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.5, curve: Curves.easeInOut),
    );
    _fade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.5, 1.0, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(covariant _QuickActionsButton old) {
    super.didUpdateWidget(old);
    if (widget.show == old.show) return;
    if (widget.show) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: _sizeFactor,
      axis: Axis.horizontal,
      // -1.0 = start (centerLeft) — `alignment:` only exists on Flutter
      // ≥3.44 and breaks the 3.41 CI toolchain; drop the ignore once CI
      // moves to ≥3.44.
      // ignore: deprecated_member_use
      axisAlignment: -1.0,
      child: FadeTransition(
        opacity: _fade,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                key: const Key('input-bar-quick-actions'),
                padding: EdgeInsets.zero,
                iconSize: 18,
                splashRadius: 18,
                tooltip: 'Quick actions',
                icon: Icon(
                  LucideIcons.slidersHorizontal,
                  color: context.colors.muted,
                ),
                onPressed: widget.onPressed,
              ),
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

enum _ComposerMode { sendAudio, sendText, cancel }

class _ComposerActionButton extends StatelessWidget {
  const _ComposerActionButton({
    required this.streaming,
    required this.hasContent,
    required this.disabled,
    required this.onSendText,
    required this.onCancel,
    required this.onStartAudio,
    required this.voiceEnabled,
    required this.voiceUnsupported,
    required this.onVoiceLongPressStart,
    required this.onVoiceLongPressMoveUpdate,
    required this.onVoiceLongPressEnd,
    required this.onVoiceTap,
  });

  final bool streaming;

  /// Text typed OR an image attached → the button is "send" (decision #6).
  final bool hasContent;
  final bool disabled;
  final VoidCallback onSendText;
  final VoidCallback? onCancel;
  final VoidCallback? onStartAudio;

  // Plan/29 voice wiring.
  final bool voiceEnabled;
  final bool voiceUnsupported;
  final VoidCallback onVoiceLongPressStart;
  final void Function(LongPressMoveUpdateDetails) onVoiceLongPressMoveUpdate;
  final VoidCallback onVoiceLongPressEnd;
  final VoidCallback onVoiceTap;

  _ComposerMode get _mode {
    if (streaming && !hasContent) return _ComposerMode.cancel;
    if (hasContent) return _ComposerMode.sendText;
    return _ComposerMode.sendAudio;
  }

  IconData get _icon {
    switch (_mode) {
      case _ComposerMode.cancel:
        return LucideIcons.square600;
      case _ComposerMode.sendText:
        return LucideIcons.send600;
      case _ComposerMode.sendAudio:
        return LucideIcons.mic600;
    }
  }

  VoidCallback? _resolveTap() {
    switch (_mode) {
      case _ComposerMode.cancel:
        return onCancel;
      case _ComposerMode.sendText:
        return disabled ? null : onSendText;
      case _ComposerMode.sendAudio:
        return disabled ? null : onStartAudio;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Decision #9 edge — no on-device recognition anywhere: hide the mic so
    // the empty field shows just the attach placeholder (dictate via keyboard).
    if (_mode == _ComposerMode.sendAudio && voiceUnsupported) {
      return const SizedBox.shrink();
    }

    // Hold-to-talk mic (decision #4): long-press records, slide cancels,
    // release transcribes. A plain tap surfaces the "hold to talk" hint.
    if (_mode == _ComposerMode.sendAudio && voiceEnabled) {
      return GestureDetector(
        onTap: disabled ? null : onVoiceTap,
        onLongPressStart: disabled ? null : (_) => onVoiceLongPressStart(),
        onLongPressMoveUpdate: disabled ? null : onVoiceLongPressMoveUpdate,
        onLongPressEnd: disabled ? null : (_) => onVoiceLongPressEnd(),
        child: _button(context),
      );
    }

    return GestureDetector(
      key: const Key('input-bar-action'),
      onTap: _resolveTap(),
      child: _button(context),
    );
  }

  Widget _button(BuildContext context) {
    final colors = context.colors;
    final visualEnabled = !disabled;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: visualEnabled
            ? colors.accent
            : colors.muted.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(19),
        boxShadow: visualEnabled
            ? [
                BoxShadow(
                  color: colors.accent.withValues(alpha: 0.33),
                  blurRadius: 16,
                ),
              ]
            : null,
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(scale: anim, child: child),
        ),
        child: Icon(
          _icon,
          key: ValueKey(_mode),
          color: visualEnabled ? colors.onAccent : colors.muted,
          size: 20,
        ),
      ),
    );
  }
}
