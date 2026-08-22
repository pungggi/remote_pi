import 'dart:async';

import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Plan/101 — sheet extents as a fraction of the available height. [_kInitial]
/// shows the question plus a few messages of chat; a drag (or focusing a text
/// field, see `_ExtensionUiSheetState._expandForKeyboard`) takes it to [_kMax]
/// for long multi-question flows.
const double _kMin = 0.35;
const double _kInitial = 0.55;
const double _kMax = 0.95;

/// Plan/100 — renders an interactive `extension_ui_request` (ask_user via
/// pi-ask). Plan/101 — as a draggable bottom sheet rather than a full-screen
/// modal: the question almost always refers to what the agent just said, so
/// covering the chat hid the very context needed to answer it.
///
/// Drives the rich `ask` envelope when present (single/multi/preview options +
/// custom text per question), else falls back to the plain SDK method
/// (select/input/confirm). Submits an [ExtensionUiResponse] via [onRespond];
/// the [ChatViewModel] clears the pending request (removing this sheet from the
/// tree) and relays the answer to pi-ask through the bridge.
///
/// Validation follows pi-ask's rules: for non-multi questions a custom text and
/// a selected value can't be combined, so custom text wins when present.
class ExtensionUiSheet extends StatefulWidget {
  final ExtensionUiRequest request;

  /// Plan/100 — submit-result rejection message for [request] (null when none /
  /// resolved). Surfaced so the user can retry instead of hitting a dead end
  /// when pi-ask rejects an answer.
  final String? error;
  final Future<void> Function(ExtensionUiResponse) onRespond;

  const ExtensionUiSheet({
    super.key,
    required this.request,
    this.error,
    required this.onRespond,
  });

  @override
  State<ExtensionUiSheet> createState() => _ExtensionUiSheetState();
}

class _ExtensionUiSheetState extends State<ExtensionUiSheet> {
  // Rich (ask) state: question id → selected option values.
  final Map<String, Set<String>> _selected = {};
  // Rich: question id → custom text controller (lazily created, disposed).
  final Map<String, TextEditingController> _custom = {};
  // Plan/128 — pi-ask notes. Question-level note (Shift+N equivalent), keyed by
  // question id. Lazily created + disposed like [_custom].
  final Map<String, TextEditingController> _questionNotes = {};
  // Plan/128 — per-option note (n equivalent), keyed by "questionId\x1Fvalue"
  // (unit separator so option values containing "|" can't collide).
  final Map<String, TextEditingController> _optionNotes = {};
  // Plan/128 — inline note editors currently expanded (compose key → open).
  final Set<String> _openNotes = {};
  // Degraded (no ask envelope) state.
  String? _singleValue;
  final TextEditingController _textController = TextEditingController();
  bool _submitting = false;
  // Plan/100 — backstop so a submit/cancel that never gets a `completed`/error
  // (relay drop, pi-ask gone) doesn't strand the user on a spinner forever.
  Timer? _submitTimeout;
  bool _awaitHint = false;
  // Plan/101 — drives the sheet extent from the grab handle and from keyboard
  // focus. `isAttached` is false until the sheet's first layout, so every use
  // is guarded.
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  AskEnrichmentWire? get _ask => widget.request.ask;

  @override
  void didUpdateWidget(covariant ExtensionUiSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Either a different request replaced this one, or a rejection arrived for
    // the same request — in both cases stop spinning so the user can act. An
    // error being CLEARED (non-null → null) must not reset: that's the
    // viewmodel wiping the old message at the start of a retry, and stopping
    // there would re-enable the buttons mid-flight (double submit).
    // NB: chat_page keys this sheet by ValueKey(request.id), so a different
    // request id never reaches didUpdateWidget (a fresh State is created
    // instead) — the id check below is defensive only; the live transition is
    // "error arrived for the same request".
    final errorArrived =
        widget.error != oldWidget.error && widget.error != null;
    if (widget.request.id != oldWidget.request.id || errorArrived) {
      _submitTimeout?.cancel();
      setState(() {
        _submitting = false;
        _awaitHint = false;
      });
    }
  }

  void _armSubmitTimeout() {
    _submitTimeout?.cancel();
    _submitTimeout = Timer(const Duration(seconds: 25), () {
      if (!mounted || !_submitting) return;
      setState(() {
        _submitting = false;
        _awaitHint = true;
      });
    });
  }

  @override
  void dispose() {
    _submitTimeout?.cancel();
    for (final c in _custom.values) {
      c.dispose();
    }
    for (final c in _questionNotes.values) {
      c.dispose();
    }
    for (final c in _optionNotes.values) {
      c.dispose();
    }
    _textController.dispose();
    _sheetController.dispose();
    super.dispose();
  }

  /// The handle is outside the scrollable, so `DraggableScrollableSheet` never
  /// sees the drag — forward it to the controller by hand.
  void _onHandleDrag(DragUpdateDetails d) {
    if (!_sheetController.isAttached) return;
    final height = MediaQuery.sizeOf(context).height;
    final delta = d.primaryDelta;
    if (height <= 0 || delta == null) return;
    _sheetController.jumpTo(
      (_sheetController.size - delta / height).clamp(_kMin, _kMax),
    );
  }

  /// A focused text field means the keyboard is coming up. Without this the
  /// field opens behind it whenever the sheet sits below full height.
  void _expandForKeyboard() {
    if (!_sheetController.isAttached) return;
    if (_sheetController.size >= _kMax - 0.001) return;
    _sheetController.animateTo(
      _kMax,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  TextEditingController _customFor(String qid) =>
      _custom.putIfAbsent(qid, TextEditingController.new);

  // Plan/128 — note controllers. Lazy + disposed in dispose().
  TextEditingController _questionNoteFor(String qid) =>
      _questionNotes.putIfAbsent(qid, TextEditingController.new);

  TextEditingController _optionNoteFor(String qid, String value) =>
      _optionNotes.putIfAbsent(_optionKey(qid, value), TextEditingController.new);

  String _optionKey(String qid, String value) => '$qid\x1F$value';

  bool _isMulti(AskQuestionWire q) =>
      q.type == AskQuestionWireType.multi ||
      q.presentedType == AskQuestionWireType.multi;

  bool get _canSubmit {
    final ask = _ask;
    if (ask != null) {
      for (final q in ask.questions) {
        // Plan/128 — a question note alone is a valid answer in pi-ask (a note
        // can exist without a selected option), so it enables Submit too.
        if ((_selected[q.id]?.isNotEmpty ?? false) ||
            _customFor(q.id).text.trim().isNotEmpty ||
            _questionNoteFor(q.id).text.trim().isNotEmpty) {
          return true;
        }
      }
      return false;
    }
    return switch (widget.request.method) {
      ExtensionUiMethod.select => _singleValue != null,
      ExtensionUiMethod.input ||
      ExtensionUiMethod.editor => _textController.text.trim().isNotEmpty,
      ExtensionUiMethod.confirm => true,
      ExtensionUiMethod.notify => false,
    };
  }

  Future<void> _submit() async {
    if (!_canSubmit || _submitting) return;
    setState(() {
      _submitting = true;
      _awaitHint = false;
    });
    _armSubmitTimeout();
    await widget.onRespond(_buildResponse());
    // The modal stays open until the ChatViewModel clears the pending request
    // on the `completed` dismiss notify (or surfaces an error for retry).
  }

  Future<void> _cancel() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _awaitHint = false;
    });
    _armSubmitTimeout();
    final ask = _ask;
    await widget.onRespond(
      ExtensionUiResponse(
        id: widget.request.id,
        cancelled: true,
        ask: ask != null
            ? AskResponseEnrichmentWire(flowId: ask.flowId, isCancel: true)
            : null,
      ),
    );
  }

  ExtensionUiResponse _buildResponse() {
    final id = widget.request.id;
    final ask = _ask;
    if (ask != null) {
      final answers = <String, AskAnswerWire>{};
      for (final q in ask.questions) {
        final selected =
            _selected[q.id]?.toList(growable: false) ?? const <String>[];
        final custom = _customFor(q.id).text.trim();
        final multi = _isMulti(q);

        // pi-ask forbids combining value + customText on non-multi questions.
        final values = multi
            ? selected
            : (custom.isNotEmpty ? const <String>[] : selected);
        final customText = custom.isEmpty ? null : custom;

        // Plan/128 — question note rides regardless of selection (pi-ask keeps
        // a note-only answer). A note is the only thing that can make an
        // otherwise-empty question count, so it gates the `continue` too.
        final note = _questionNoteFor(q.id).text.trim();
        // Option notes only survive for options that actually made it into the
        // answer: pi-ask's serializeAnswer keeps optionNotes for selected
        // options only. Use `values` (not the raw `_selected` set) so a
        // single-select customText that overrides the selection drops the
        // option note too, matching pi-ask exactly.
        final inAnswer = values.toSet();
        final optionNotes = <String, String>{};
        for (final o in q.options) {
          final n = _optionNoteFor(q.id, o.value).text.trim();
          if (n.isNotEmpty && inAnswer.contains(o.value)) {
            optionNotes[o.value] = n;
          }
        }

        if (values.isEmpty && customText == null && note.isEmpty) continue;
        answers[q.id] = AskAnswerWire(
          values: values,
          customText: customText,
          note: note.isEmpty ? null : note,
          optionNotes: optionNotes,
        );
      }
      return ExtensionUiResponse(
        id: id,
        ask: AskResponseEnrichmentWire(
          flowId: ask.flowId,
          mode: 'submit',
          answers: answers,
        ),
      );
    }
    // Degraded: plain SDK response shape. The bridge maps the select label back
    // to the option value via its per-request table.
    return switch (widget.request.method) {
      ExtensionUiMethod.select => ExtensionUiResponse(
        id: id,
        value: _singleValue ?? '',
      ),
      ExtensionUiMethod.input || ExtensionUiMethod.editor =>
        ExtensionUiResponse(id: id, value: _textController.text),
      ExtensionUiMethod.confirm => ExtensionUiResponse(id: id, confirmed: true),
      ExtensionUiMethod.notify => ExtensionUiResponse(id: id, cancelled: true),
    };
  }

  void _toggle(String qid, String value, bool multi) {
    setState(() {
      final set = _selected.putIfAbsent(qid, () => <String>{});
      if (multi) {
        if (set.contains(value)) {
          set.remove(value);
        } else {
          set.add(value);
        }
      } else {
        set
          ..clear()
          ..add(value);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final ask = _ask;
    final title = widget.request.title ?? ask?.title ?? 'Clarification needed';

    // System back (Android) mirrors the close button: cancel the flow instead
    // of popping the chat route underneath while the sheet is still overlaid.
    // Plan/101 — back still CANCELS; it deliberately does not merely collapse
    // the sheet, so the gesture keeps the meaning verified on device for #64.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_submitting) _cancel();
      },
      child: DraggableScrollableSheet(
        controller: _sheetController,
        initialChildSize: _kInitial,
        minChildSize: _kMin,
        maxChildSize: _kMax,
        snap: true,
        snapSizes: const [_kMin, _kInitial, _kMax],
        // This sheet is a Stack overlay, not a route: reaching the min extent
        // must never try to pop anything. It leaves the tree only when the
        // viewmodel clears the pending request.
        shouldCloseOnMinExtent: false,
        builder: (context, scrollController) => Material(
          color: colors.bg,
          elevation: 8,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              _buildHeader(context, title),
              Expanded(
                // Focus anywhere in the scrollable means a text field took the
                // keyboard — lift the sheet before it can cover the field.
                child: Focus(
                  onFocusChange: (hasFocus) {
                    if (hasFocus) _expandForKeyboard();
                  },
                  child: ask != null
                      ? _buildRich(context, ask, scrollController)
                      : _buildDegraded(context, scrollController),
                ),
              ),
              _buildActions(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, String title) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: _onHandleDrag,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Cancel',
                onPressed: _submitting ? null : _cancel,
              ),
              Expanded(
                child: Text(
                  title,
                  style: text.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 16),
            ],
          ),
          Divider(height: 1, color: colors.border),
        ],
      ),
    );
  }

  Widget _buildRich(
    BuildContext context,
    AskEnrichmentWire ask,
    ScrollController controller,
  ) {
    return ListView.separated(
      // The sheet only drags from its scrollable — this controller is the one
      // DraggableScrollableSheet handed us, so dragging the list past its top
      // resizes the sheet instead of overscrolling.
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: ask.questions.length,
      separatorBuilder: (_, _) => const SizedBox(height: 24),
      itemBuilder: (context, i) => _buildQuestion(context, ask.questions[i]),
    );
  }

  Widget _buildQuestion(BuildContext context, AskQuestionWire q) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final multi = _isMulti(q);
    final sel = _selected[q.id] ?? <String>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(q.prompt, style: text.titleMedium)),
            // pi-ask marks `required` as advisory only (never blocks
            // submission), so it renders as a hint, not a validation gate.
            if (q.required)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 4),
                child: Text(
                  'required',
                  style: text.labelSmall?.copyWith(color: colors.accent),
                ),
              ),
            if (multi)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 4),
                child: Text(
                  'multi',
                  style: text.labelSmall?.copyWith(color: colors.muted),
                ),
              ),
          ],
        ),
        if (q.label.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(q.label, style: text.labelSmall?.copyWith(color: colors.muted)),
        ],
        const SizedBox(height: 12),
        for (final o in q.options) ...[
          _optionTile(context, q, o, multi, sel),
          const SizedBox(height: 8),
        ],
        TextField(
          controller: _customFor(q.id),
          enabled: !_submitting,
          // _canSubmit reads this text; without a rebuild per keystroke the
          // Submit button would stay stale for text-only answers.
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Type your own…',
            isDense: true,
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Plan/128 — question note (pi-ask Shift+N). A note annotates the
        // whole answer and is valid even without a selection.
        _noteEditor(
          context,
          controller: _questionNoteFor(q.id),
          key: q.id,
          hint: 'Add a note to this answer…',
        ),
      ],
    );
  }

  Widget _optionTile(
    BuildContext context,
    AskQuestionWire q,
    AskOptionWire o,
    bool multi,
    Set<String> sel,
  ) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final selected = sel.contains(o.value);
    final isPreview = q.type == AskQuestionWireType.preview;

    // Plan/128 — the tile is a Column so the option-note editor can sit as a
    // sibling BELOW the InkWell (not inside it). Putting it inside would make
    // tapping the note affordance toggle the selection.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: _submitting ? null : () => _toggle(q.id, o.value, multi),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: selected
                  ? colors.accent.withValues(alpha: 0.10)
                  : colors.surface,
              border: Border.all(
                color: selected ? colors.accent : colors.border,
                width: selected ? 1.6 : 1,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      multi
                          ? (selected
                                ? Icons.check_box
                                : Icons.check_box_outline_blank)
                          : (selected
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked),
                      size: 20,
                      color: selected ? colors.accent : colors.muted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        o.label,
                        style: text.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          // pi-ask `recommended` marker: tint only (no badge).
                          // A selected tile is already accent-colored, so the
                          // tint matters only when unselected.
                          color: o.recommended && !selected
                              ? colors.accent
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
                if (o.description != null && o.description!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(left: 30),
                    child: Text(
                      o.description!,
                      style: text.bodyMedium?.copyWith(color: colors.muted),
                    ),
                  ),
                ],
                if (isPreview && o.preview != null && o.preview!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: colors.codeBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: colors.border),
                    ),
                    child: Text(
                      o.preview!,
                      style: TextStyle(
                        fontFamily: kMonoFamily,
                        fontSize: 12,
                        color: colors.text,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        // Plan/128 — per-option note (pi-ask `n`). Only for a selected option:
        // pi-ask's serializeAnswer keeps option notes for selected options only,
        // so annotating an unselected one would be silently dropped on submit.
        // Indented to sit under the option label (past the caret icon).
        if (selected)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 30),
            child: _noteEditor(
              context,
              controller: _optionNoteFor(q.id, o.value),
              key: _optionKey(q.id, o.value),
              hint: 'Note for this option…',
            ),
          ),
      ],
    );
  }

  /// Plan/128 — inline, expandable note editor shared by question notes
  /// (Shift+N equivalent) and per-option notes (n equivalent). Three visual
  /// states: closed + empty → an "Add note" affordance; closed + filled → a
  /// tappable chip that reopens the editor; open → a multiline TextField.
  /// [key] is the compose id tracked in [_openNotes].
  Widget _noteEditor(
    BuildContext context, {
    required TextEditingController controller,
    required String key,
    required String hint,
  }) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final hasText = controller.text.trim().isNotEmpty;
    final open = _openNotes.contains(key);

    if (open) {
      return TextField(
        controller: controller,
        enabled: !_submitting,
        minLines: 1,
        maxLines: 4,
        autofocus: true,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          prefixIcon: const Icon(Icons.note_alt_outlined, size: 18),
          // Plan/128 — Collapse (expand_less) closes the editor but keeps the
          // text, which is what surfaces the "filled chip" state below. Clear
          // (x) wipes the text and stays open. Clear only shows when there's
          // text; an empty editor collapses straight back to "Add note".
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasText)
                IconButton(
                  tooltip: 'Remove note',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: _submitting
                      ? null
                      : () {
                          controller.clear();
                          setState(() => _openNotes.remove(key));
                        },
                ),
              IconButton(
                tooltip: 'Collapse',
                icon: const Icon(Icons.expand_less, size: 18),
                onPressed: _submitting
                    ? null
                    : () => setState(() => _openNotes.remove(key)),
              ),
            ],
          ),
          border: const OutlineInputBorder(),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      );
    }

    if (hasText) {
      // Collapsed but filled → chip; tap reopens the editor.
      return Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          onTap: _submitting
              ? null
              : () => setState(() => _openNotes.add(key)),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(16),
              border:
                  Border.all(color: colors.accent.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.note_alt, size: 14, color: colors.accent),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    controller.text.trim(),
                    style: text.labelMedium?.copyWith(color: colors.accent),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: _submitting
            ? null
            : () => setState(() => _openNotes.add(key)),
        icon: const Icon(Icons.note_add, size: 18),
        label: const Text('Add note'),
      ),
    );
  }

  Widget _buildDegraded(BuildContext context, ScrollController controller) {
    final text = Theme.of(context).textTheme;
    final message = widget.request.message ?? widget.request.title ?? '';
    // Scrollable (not a bare Column) for the same reason as _buildRich: the
    // drag-to-resize gesture needs the sheet's own controller, and short
    // content must not overflow when the sheet sits at its minimum extent.
    return ListView(
      controller: controller,
      padding: const EdgeInsets.all(16),
      children: [
        if (message.isNotEmpty) ...[
          Text(message, style: text.bodyLarge),
          const SizedBox(height: 16),
        ],
        switch (widget.request.method) {
          ExtensionUiMethod.select => RadioGroup<String>(
            groupValue: _singleValue,
            onChanged: (v) => setState(() => _singleValue = v),
            child: Column(
              children: [
                for (final opt in widget.request.options)
                  RadioListTile<String>(
                    value: opt,
                    title: Text(opt),
                    enabled: !_submitting,
                  ),
              ],
            ),
          ),
          ExtensionUiMethod.input || ExtensionUiMethod.editor => TextField(
            controller: _textController,
            maxLines: 5,
            enabled: !_submitting,
            // _canSubmit reads this text; rebuild per keystroke or the
            // Submit button never enables.
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: widget.request.placeholder ?? '',
              border: const OutlineInputBorder(),
            ),
          ),
          ExtensionUiMethod.confirm => Text(
            'Please confirm.',
            style: text.titleMedium,
          ),
          // ChatViewModel consumes notify requests without opening this
          // sheet. Keep the defensive enum branch empty; [message] above
          // already renders it once if this path ever becomes reachable.
          ExtensionUiMethod.notify => const SizedBox.shrink(),
        },
      ],
    );
  }

  Widget _buildActions(BuildContext context) {
    final colors = context.colors;
    final showError = widget.error != null && widget.error!.isNotEmpty;
    // Pinned to the sheet's bottom at every extent, so the error banner stays
    // readable with the sheet collapsed — which is exactly when the user is
    // looking at the chat behind it. There is no Scaffold here any more, so
    // `resizeToAvoidBottomInset` can't lift the buttons: pad by the keyboard
    // inset by hand or Submit/Cancel open behind the keyboard.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.bg,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 12 + keyboard),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showError)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    widget.error!,
                    style: TextStyle(color: colors.error, fontSize: 13),
                  ),
                )
              else if (_awaitHint)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'No response from Pi yet — retry or cancel.',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _submitting ? null : _cancel,
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: (_canSubmit && !_submitting) ? _submit : null,
                      child: _submitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Submit'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
