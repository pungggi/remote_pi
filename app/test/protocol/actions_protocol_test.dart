// Plan/28 Wave C — protocol surface for typed app actions.
//
// Mirrors the contract in `pi-extension/src/protocol/types.ts`:
//   ClientMessage:  session_compact, session_new, model_set,
//                   thinking_set, list_models
//   ServerMessage:  action_ok, action_error, models_list

import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ClientMessage — typed actions', () {
    test('SessionCompact encodes as session_compact', () {
      final j = SessionCompact(id: 'r1').toJson();
      expect(j, {'type': 'session_compact', 'id': 'r1'});
    });

    test('SessionNew encodes as session_new', () {
      final j = SessionNew(id: 'r2').toJson();
      expect(j, {'type': 'session_new', 'id': 'r2'});
    });

    test('SessionShutdown encodes as session_shutdown', () {
      final j = SessionShutdown(id: 'r2q').toJson();
      expect(j, {'type': 'session_shutdown', 'id': 'r2q'});
    });

    test('ModelSet encodes provider + model_id', () {
      final j =
          ModelSet(id: 'r3', provider: 'anthropic', modelId: 'claude-opus-4-7')
              .toJson();
      expect(j, {
        'type': 'model_set',
        'id': 'r3',
        'provider': 'anthropic',
        'model_id': 'claude-opus-4-7',
      });
    });

    test('ThinkingSet encodes level wire value', () {
      expect(
        ThinkingSet(id: 'r4', level: ThinkingLevel.minimal).toJson(),
        {'type': 'thinking_set', 'id': 'r4', 'level': 'minimal'},
      );
      expect(
        ThinkingSet(id: 'r5', level: ThinkingLevel.xhigh).toJson(),
        {'type': 'thinking_set', 'id': 'r5', 'level': 'xhigh'},
      );
    });

    test('ListModels encodes as list_models', () {
      expect(ListModels(id: 'r6').toJson(),
          {'type': 'list_models', 'id': 'r6'});
    });
  });

  group('ThinkingLevel — wire round-trip', () {
    test('all six values parse from their wire string', () {
      const expected = [
        ('off', ThinkingLevel.off),
        ('minimal', ThinkingLevel.minimal),
        ('low', ThinkingLevel.low),
        ('medium', ThinkingLevel.medium),
        ('high', ThinkingLevel.high),
        ('xhigh', ThinkingLevel.xhigh),
      ];
      for (final (wire, level) in expected) {
        expect(ThinkingLevel.fromWire(wire), level);
        expect(level.wire, wire);
      }
    });

    test('unknown wire string returns null (forward-compat)', () {
      expect(ThinkingLevel.fromWire('mega'), isNull);
    });
  });

  group('ActionName — wire round-trip', () {
    test('parses each known action', () {
      expect(ActionName.fromWire('session_new'), ActionName.sessionNew);
      expect(
        ActionName.fromWire('session_shutdown'),
        ActionName.sessionShutdown,
      );
      expect(
        ActionName.fromWire('session_compact'),
        ActionName.sessionCompact,
      );
      expect(ActionName.fromWire('model_set'), ActionName.modelSet);
      expect(ActionName.fromWire('thinking_set'), ActionName.thinkingSet);
    });

    test('unknown action returns null', () {
      expect(ActionName.fromWire('explode'), isNull);
    });
  });

  group('ServerMessage — action replies', () {
    test('action_ok parses in_reply_to and action', () {
      final m = ServerMessage.fromJson({
        'type': 'action_ok',
        'in_reply_to': 'r1',
        'action': 'session_compact',
      });
      final ok = m as ActionOk;
      expect(ok.inReplyTo, 'r1');
      expect(ok.action, ActionName.sessionCompact);
      expect(ok.rawAction, 'session_compact');
    });

    test('action_error parses error field', () {
      final m = ServerMessage.fromJson({
        'type': 'action_error',
        'in_reply_to': 'r2',
        'action': 'model_set',
        'error': 'no auth configured',
      });
      final err = m as ActionError;
      expect(err.error, 'no auth configured');
      expect(err.action, ActionName.modelSet);
    });

    test('action_ok with unknown action keeps rawAction', () {
      final m = ServerMessage.fromJson({
        'type': 'action_ok',
        'in_reply_to': 'r3',
        'action': 'future_op',
      });
      final ok = m as ActionOk;
      expect(ok.rawAction, 'future_op');
    });

    test('models_list parses models and current', () {
      final m = ServerMessage.fromJson({
        'type': 'models_list',
        'in_reply_to': 'r4',
        'models': [
          {
            'id': 'claude-opus-4-7',
            'name': 'Claude Opus 4.7',
            'provider': 'anthropic',
            'reasoning': true,
            'context_window': 200000,
          },
          {
            'id': 'gpt-4o',
            'name': 'GPT-4o',
            'provider': 'openai',
            'reasoning': false,
            'context_window': 128000,
          },
        ],
        'current': {
          'id': 'claude-opus-4-7',
          'name': 'Claude Opus 4.7',
          'provider': 'anthropic',
          'reasoning': true,
          'context_window': 200000,
        },
      });
      final list = m as ModelsList;
      expect(list.models, hasLength(2));
      expect(list.models.first.id, 'claude-opus-4-7');
      expect(list.models.first.reasoning, isTrue);
      expect(list.current?.id, 'claude-opus-4-7');
    });

    test('models_list without current returns null current', () {
      final m = ServerMessage.fromJson({
        'type': 'models_list',
        'in_reply_to': 'r5',
        'models': const <Map<String, dynamic>>[],
      });
      final list = m as ModelsList;
      expect(list.current, isNull);
      expect(list.models, isEmpty);
    });
  });

  // Plan/168 — device-daemon control surface (repair verbs).
  group('daemon_control (plan/168)', () {
    test('DaemonControlRequest encodes restart op', () {
      expect(DaemonControlRequest(id: 'r7', op: 'restart').toJson(), {
        'type': 'daemon_control',
        'id': 'r7',
        'op': 'restart',
      });
    });

    test('DaemonControlRequest encodes status op + optional daemon selector', () {
      expect(
        DaemonControlRequest(id: 'r8', op: 'status', daemon: 'device')
            .toJson(),
        {
          'type': 'daemon_control',
          'id': 'r8',
          'op': 'status',
          'daemon': 'device',
        },
      );
    });

    test('ActionName round-trips daemon_control', () {
      expect(ActionName.fromWire('daemon_control'), ActionName.daemonControl);
      expect(ActionName.daemonControl.wire, 'daemon_control');
    });

    test('action_ok daemon_control parses restart result', () {
      final m = ServerMessage.fromJson({
        'type': 'action_ok',
        'in_reply_to': 'r7',
        'action': 'daemon_control',
        'result': {
          'op': 'restart',
          'daemon': 'device',
          'restarted': true,
          'note': 'alive daemon self-restarting via supervisor crash-respawn',
          'pid': 4242,
        },
      });
      final ok = m as DaemonControlOk;
      expect(ok.inReplyTo, 'r7');
      final r = ok.result as DaemonRestartResult;
      expect(r.daemon, 'device');
      expect(r.restarted, isTrue);
      expect(r.note, contains('self-restarting'));
      expect(r.pid, 4242);
    });

    test('action_ok daemon_control parses status rows', () {
      final m = ServerMessage.fromJson({
        'type': 'action_ok',
        'in_reply_to': 'r8',
        'action': 'daemon_control',
        'result': {
          'op': 'status',
          'daemons': [
            {
              'id': 'device',
              'cwd': 'C:\\dev',
              'state': 'running',
              'pid': 17260,
              'uptime_s': 1234,
            },
          ],
        },
      });
      final r = (m as DaemonControlOk).result as DaemonStatusResult;
      expect(r.daemons, hasLength(1));
      final row = r.daemons.single;
      expect(row.id, 'device');
      expect(row.state, 'running');
      expect(row.pid, 17260);
      expect(row.uptimeS, 1234);
    });

    test('unknown result op stays typed (forward-compat)', () {
      final m = ServerMessage.fromJson({
        'type': 'action_ok',
        'in_reply_to': 'r9',
        'action': 'daemon_control',
        'result': {'op': 'migrate'},
      });
      expect(
        (m as DaemonControlOk).result,
        isA<DaemonControlUnknown>()
            .having((u) => u.op, 'op', 'migrate'),
      );
    });

    test('action_ok with another action still parses as ActionOk', () {
      final m = ServerMessage.fromJson({
        'type': 'action_ok',
        'in_reply_to': 'r10',
        'action': 'session_new',
      });
      expect(m, isA<ActionOk>());
    });

    test('action_error daemon_control carries the refusal message', () {
      final m = ServerMessage.fromJson({
        'type': 'action_error',
        'in_reply_to': 'r11',
        'action': 'daemon_control',
        'error':
            'remote session control disabled on this peer (allow_remote_session_control:false)',
      });
      final e = m as ActionError;
      expect(e.action, ActionName.daemonControl);
      expect(e.error, contains('allow_remote_session_control'));
    });
  });
}
