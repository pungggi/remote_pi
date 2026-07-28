// Regression test for `classifyTranscriptGrow` in chat_page.dart — the pure
// decision that drives the transcript auto-scroll policy (Plan/fixusrmsgscrolling).
//
// The list is oldest → newest and rendered `reverse: true`, so growth at the
// back of the list grows the *bottom* (newest), and growth at the front
// (load-more) grows the *top* (oldest). These cases pin each branch.
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _u(String id) => UserMsg(id: id, text: id);
List<ChatMessage> _msg(List<String> ids) => [for (final id in ids) _u(id)];

void main() {
  group('classifyTranscriptGrow', () {
    test('same list reference — only the streaming bubble can move', () {
      final msgs = _msg(['a', 'b']);
      expect(classifyTranscriptGrow(msgs, msgs, false), TranscriptGrow.none);
      expect(classifyTranscriptGrow(msgs, msgs, true), TranscriptGrow.bottom);
    });

    test('opening / switching into a chat (old empty) → replace', () {
      expect(classifyTranscriptGrow(_msg([]), _msg(['a', 'b']), false),
          TranscriptGrow.replace);
    });

    test('compaction (new shorter) → replace', () {
      expect(classifyTranscriptGrow(_msg(['a', 'b', 'c']), _msg(['x']), false),
          TranscriptGrow.replace);
    });

    test('same length, same ids (only streaming moved) → bottom', () {
      // Fresh instances, equal ids in equal order.
      expect(classifyTranscriptGrow(_msg(['a', 'b']), _msg(['a', 'b']), false),
          TranscriptGrow.bottom);
    });

    test('same length, swapped ids (wholesale replace) → replace', () {
      expect(classifyTranscriptGrow(_msg(['a', 'b']), _msg(['a', 'c']), false),
          TranscriptGrow.replace);
    });

    test('appended at the back (new message) → bottom', () {
      expect(classifyTranscriptGrow(_msg(['a', 'b']), _msg(['a', 'b', 'c']),
              false),
          TranscriptGrow.bottom);
    });

    test('prepended at the front (load-more / older) → top', () {
      expect(classifyTranscriptGrow(_msg(['b', 'c']), _msg(['a', 'b', 'c']),
              false),
          TranscriptGrow.top);
    });

    test('added several but neither prefix nor suffix → replace', () {
      expect(classifyTranscriptGrow(_msg(['a', 'b']), _msg(['x', 'b', 'c']),
              false),
          TranscriptGrow.replace);
    });

    test('load-more does not masquerade as a bottom append '
        '(regression: front-prepend must stay `top`)', () {
      // Two older messages loaded above an existing tail.
      expect(classifyTranscriptGrow(_msg(['c', 'd']), _msg(['a', 'b', 'c', 'd']),
              false),
          TranscriptGrow.top);
    });
  });
}
