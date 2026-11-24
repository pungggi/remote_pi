// Plan/172 — Pi-clock timestamps on the wire (the app's parsing half).
//
// Every new field is OPTIONAL so a pre-172 extension's frames decode exactly
// as before (nulls), and the sync layer falls back to arrival time.

import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('live frames with Pi-clock timestamps', () {
    test('user_input echo carries ts', () {
      final msg =
          ServerMessage.fromJson({
                'type': 'user_input',
                'id': 'u1',
                'text': 'hi',
                'ts': 1716234600123,
              })
              as UserInput;
      expect(msg.ts, 1716234600123);
    });

    test('agent_chunk carries the reply-start ts', () {
      final msg =
          ServerMessage.fromJson({
                'type': 'agent_chunk',
                'in_reply_to': 'u1',
                'delta': 'Hel',
                'ts': 1716234600000,
              })
              as AgentChunk;
      expect(msg.ts, 1716234600000);
    });

    test('tool_request carries execution start (ts) + reply_ts', () {
      final msg =
          ServerMessage.fromJson({
                'type': 'tool_request',
                'tool_call_id': 'tc1',
                'tool': 'Bash',
                'args': {'command': 'ls'},
                'ts': 1716234607100,
                'reply_ts': 1716234600000,
              })
              as ToolRequest;
      expect(msg.ts, 1716234607100);
      expect(msg.replyTs, 1716234600000);
    });

    test('tool_result carries execution end (ts) + duration_ms', () {
      final msg =
          ServerMessage.fromJson({
                'type': 'tool_result',
                'tool_call_id': 'tc1',
                'result': 'ok',
                'ts': 1716234613921,
                'duration_ms': 6821,
              })
              as ToolResult;
      expect(msg.ts, 1716234613921);
      expect(msg.durationMs, 6821);
    });
  });

  group('pre-172 frames (no timestamps) decode as before', () {
    test('every new field is null, nothing throws', () {
      final echo =
          ServerMessage.fromJson({
                'type': 'user_input',
                'id': 'u1',
                'text': 'hi',
              })
              as UserInput;
      final chunk =
          ServerMessage.fromJson({
                'type': 'agent_chunk',
                'in_reply_to': 'u1',
                'delta': 'x',
              })
              as AgentChunk;
      final req =
          ServerMessage.fromJson({
                'type': 'tool_request',
                'tool_call_id': 'tc1',
                'tool': 'Bash',
                'args': null,
              })
              as ToolRequest;
      final res =
          ServerMessage.fromJson({
                'type': 'tool_result',
                'tool_call_id': 'tc1',
                'error': 'boom',
              })
              as ToolResult;
      expect(echo.ts, isNull);
      expect(chunk.ts, isNull);
      expect(req.ts, isNull);
      expect(req.replyTs, isNull);
      expect(res.ts, isNull);
      expect(res.durationMs, isNull);
    });
  });

  group('session_history', () {
    test('tool_result event replays duration_ms', () {
      final evt =
          SessionHistoryEvent.fromJson({
                'ts': 1716234613921,
                'type': 'tool_result',
                'tool_call_id': 'tc1',
                'result': 'ok',
                'duration_ms': 6821,
              })
              as ToolResultEvt;
      expect(evt.ts, 1716234613921);
      expect(evt.durationMs, 6821);
    });

    test('legacy tool_result event (no duration) decodes with null', () {
      final evt =
          SessionHistoryEvent.fromJson({
                'ts': 1716234613921,
                'type': 'tool_result',
                'tool_call_id': 'tc1',
                'error': 'boom',
              })
              as ToolResultEvt;
      expect(evt.durationMs, isNull);
    });

    test('a fractional duration is truncated to whole ms', () {
      final msg =
          ServerMessage.fromJson({
                'type': 'tool_result',
                'tool_call_id': 'tc1',
                'result': 'ok',
                'duration_ms': 6821.9,
              })
              as ToolResult;
      expect(msg.durationMs, 6821);
    });
  });
}
