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

    test('tipos desconhecidos seguem RpcUnknown', () {
      final e = mapper.fromJson(const {'type': 'something_new'});
      expect(e, isA<RpcUnknown>());
    });
  });
}
