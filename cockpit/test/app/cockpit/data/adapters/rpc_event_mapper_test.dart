import 'package:cockpit/app/cockpit/data/adapters/rpc_event_mapper.dart';
import 'package:cockpit/app/cockpit/domain/entities/rpc_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const mapper = RpcEventMapper();

  group('RpcEventMapper — plano 134 (ui_prompt brackets)', () {
    test('ui_prompt_start mapeia kind + title', () {
      final e = mapper.fromJson(const {
        'type': 'ui_prompt_start',
        'reason': 'ui_prompt',
        'kind': 'select',
        'title': 'Pick one',
      });
      expect(e, isA<RpcUiPromptStart>());
      final start = e as RpcUiPromptStart;
      expect(start.kind, 'select');
      expect(start.title, 'Pick one');
    });

    test('ui_prompt_start sem title (custom) fica null', () {
      final e = mapper.fromJson(const {
        'type': 'ui_prompt_start',
        'reason': 'ui_prompt',
        'kind': 'custom',
      });
      final start = e as RpcUiPromptStart;
      expect(start.kind, 'custom');
      expect(start.title, isNull);
    });

    test('ui_prompt_end mapeia kind', () {
      final e = mapper.fromJson(const {
        'type': 'ui_prompt_end',
        'reason': 'ui_prompt',
        'kind': 'confirm',
      });
      expect(e, isA<RpcUiPromptEnd>());
      expect((e as RpcUiPromptEnd).kind, 'confirm');
    });

    test('kind ausente degrada para custom (nunca quebra)', () {
      final e = mapper.fromJson(const {'type': 'ui_prompt_start'});
      expect((e as RpcUiPromptStart).kind, 'custom');
    });

    test(
        'PR #58 review — remote-pi:ui-prompt custom message mapeia para start/end',
        () {
      // O canal que realmente entrega o bracket hoje: a extensão espelha a
      // transição como custom message (o RPC não encaminha os eventos crus).
      final start = mapper.fromJson(const {
        'type': 'message_start',
        'message': {
          'role': 'custom',
          'customType': 'remote-pi:ui-prompt',
          'content': 'Waiting for your input (Pick one)',
          'display': false,
          'details': {
            'waiting': true,
            'kind': 'select',
            'title': 'Pick one',
          },
        },
      });
      expect(start, isA<RpcUiPromptStart>());
      final s = start as RpcUiPromptStart;
      expect(s.kind, 'select');
      expect(s.title, 'Pick one');

      final end = mapper.fromJson(const {
        'type': 'message_start',
        'message': {
          'role': 'custom',
          'customType': 'remote-pi:ui-prompt',
          'details': {'waiting': false, 'kind': 'select'},
        },
      });
      expect(end, isA<RpcUiPromptEnd>());
      expect((end as RpcUiPromptEnd).kind, 'select');

      // Degradations: sem details / sem kind → Unknown-start custom ou
      // kind=custom, nunca exceção.
      final noDetails = mapper.fromJson(const {
        'type': 'message_start',
        'message': {
          'role': 'custom',
          'customType': 'remote-pi:ui-prompt',
        },
      });
      expect(noDetails, isA<RpcUnknown>());
      final noKind = mapper.fromJson(const {
        'type': 'message_start',
        'message': {
          'role': 'custom',
          'customType': 'remote-pi:ui-prompt',
          'details': {'waiting': true},
        },
      });
      expect((noKind as RpcUiPromptStart).kind, 'custom');
    });

    test('tipos desconhecidos seguem RpcUnknown', () {
      final e = mapper.fromJson(const {'type': 'something_new'});
      expect(e, isA<RpcUnknown>());
    });
  });
}
