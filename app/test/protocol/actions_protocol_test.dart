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
}
