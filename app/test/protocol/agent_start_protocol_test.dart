import 'package:flutter_test/flutter_test.dart';
import 'package:app/protocol/protocol.dart';

// Plan/173 — agent + device identity on the wire: `agent`, `provider` and
// `model_id` on the start requests, `list_models {agent}`, and the
// `device_info_request` / `device_info_result` pair. Mirrors
// `pi-extension/src/protocol/agent_selection.test.ts`.
void main() {
  group('AgentKind — wire round-trip', () {
    test('both agents parse from their wire string', () {
      expect(AgentKind.fromWire('pi'), AgentKind.pi);
      expect(AgentKind.fromWire('agy'), AgentKind.agy);
    });

    test('unknown wire string returns null (forward-compat)', () {
      expect(AgentKind.fromWire('claude'), isNull);
      expect(AgentKind.fromWire(null), isNull);
      expect(AgentKind.fromWire(''), isNull);
    });
  });

  group('OpenTerminalRequest — plan/173 fields', () {
    test('without the fields the shape is exactly the pre-173 one', () {
      final req = OpenTerminalRequest(id: '01J', cwd: '/repo');
      expect(req.toJson(), {
        'type': 'open_terminal_request',
        'id': '01J',
        'cwd': '/repo',
        'runPi': true,
      });
    });

    test('agent, provider and model_id are sent only when set', () {
      final req = OpenTerminalRequest(
        id: '01J',
        cwd: '/repo',
        agent: AgentKind.agy,
        provider: 'google',
        modelId: 'gemini-4-neon-high',
      );
      expect(req.toJson(), {
        'type': 'open_terminal_request',
        'id': '01J',
        'cwd': '/repo',
        'runPi': true,
        'agent': 'agy',
        'provider': 'google',
        'model_id': 'gemini-4-neon-high',
      });
    });
  });

  group('StartSessionRequest — plan/173 fields', () {
    test('untouched request sends no agent and no model', () {
      final req = StartSessionRequest(id: '01J', cwd: '/repo');
      expect(req.toJson(), {
        'type': 'start_session_request',
        'id': '01J',
        'cwd': '/repo',
      });
      expect(req.toJson().containsKey('agent'), isFalse);
      expect(req.toJson().containsKey('provider'), isFalse);
      expect(req.toJson().containsKey('model_id'), isFalse);
    });

    test('a picked model is sent with the agent', () {
      final req = StartSessionRequest(
        id: '01J',
        cwd: '/repo',
        name: 'demo',
        agent: AgentKind.pi,
        provider: 'zai',
        modelId: 'glm-5.3-flash',
      );
      expect(req.toJson(), {
        'type': 'start_session_request',
        'id': '01J',
        'cwd': '/repo',
        'name': 'demo',
        'agent': 'pi',
        'provider': 'zai',
        'model_id': 'glm-5.3-flash',
      });
    });
  });

  group('ListModels — agent selector', () {
    test('without agent the shape is the original one', () {
      expect(ListModels(id: '01J').toJson(), {
        'type': 'list_models',
        'id': '01J',
      });
    });

    test('agent travels as its wire value', () {
      expect(ListModels(id: '01J', agent: AgentKind.agy).toJson(), {
        'type': 'list_models',
        'id': '01J',
        'agent': 'agy',
      });
    });
  });

  group('startModelProblem: the extension token rule, mirrored', () {
    test('no model is fine, and so is a well-formed pair', () {
      expect(startModelProblem(), isNull);
      expect(startModelProblem(provider: 'zai', modelId: 'glm-5.3-flash'), isNull);
      expect(startModelProblem(provider: 'google', modelId: 'gemini-4-neon/high'), isNull);
    });

    test('a model needs both halves', () {
      const half = 'a start model needs both provider and model_id (or neither)';
      expect(startModelProblem(provider: 'zai'), half);
      expect(startModelProblem(modelId: 'glm-5.3-flash'), half);
    });

    test('forbidden characters in a token are refused with a clear error', () {
      // What the extension refuses (agent_selection.test.ts): an empty string,
      // whitespace, shell syntax, a leading slash or dot, dot-dot anywhere,
      // and a trailing newline.
      const badTokens = ['', 'a b', 'a;b', 'a&b', 'a|b', '../etc', '/abs', 'a..b', 'a\n'];
      for (final bad in badTokens) {
        expect(startModelProblem(provider: 'zai', modelId: bad),
            'invalid model id: "$bad"');
        expect(startModelProblem(provider: bad, modelId: 'glm-5.3-flash'),
            'invalid model provider: "$bad"');
      }
    });
  });

  group('DeviceInfoRequest', () {
    test('encodes as device_info_request', () {
      expect(DeviceInfoRequest(id: '01J').toJson(), {
        'type': 'device_info_request',
        'id': '01J',
      });
    });
  });

  group('DeviceInfoResult', () {
    final androidHost = {
      'platform': 'android',
      'label': 'localhost',
      'terminal': 'tmux',
    };

    test('parses host, agents and version', () {
      final m = ServerMessage.fromJson({
        'type': 'device_info_result',
        'in_reply_to': '01J',
        'ok': true,
        'host': androidHost,
        'agents': ['pi', 'agy'],
        'version': '0.11.0',
      });
      expect(m, isA<DeviceInfoResult>());
      final r = m as DeviceInfoResult;
      expect(r.inReplyTo, '01J');
      expect(r.ok, isTrue);
      expect(r.host, const WireDeviceHost(
        platform: DevicePlatform.android,
        label: 'localhost',
        terminal: DeviceTerminal.tmux,
      ));
      expect(r.agents, [AgentKind.pi, AgentKind.agy]);
      expect(r.version, '0.11.0');
      expect(r.message, isNull);
    });

    test('a PC without agy reports Pi only', () {
      final m = ServerMessage.fromJson({
        'type': 'device_info_result',
        'in_reply_to': '01J',
        'ok': true,
        'host': {'platform': 'windows', 'label': 'DESKTOP', 'terminal': 'wt'},
        'agents': ['pi'],
        'version': '0.11.0',
      }) as DeviceInfoResult;
      expect(m.host?.platform, DevicePlatform.windows);
      expect(m.host?.terminal, DeviceTerminal.wt);
      expect(m.agents, [AgentKind.pi]);
    });

    test('a failure keeps the reason and no host', () {
      final m = ServerMessage.fromJson({
        'type': 'device_info_result',
        'in_reply_to': '01J',
        'ok': false,
        'agents': <dynamic>[],
        'version': '0.11.0',
        'message': 'boom',
      }) as DeviceInfoResult;
      expect(m.ok, isFalse);
      expect(m.host, isNull);
      expect(m.agents, isEmpty);
      expect(m.message, 'boom');
    });

    test('unknown platform and terminal values degrade, never crash', () {
      final m = ServerMessage.fromJson({
        'type': 'device_info_result',
        'in_reply_to': '01J',
        'ok': true,
        'host': {'platform': 'freebsd', 'label': 'x', 'terminal': 'gui'},
        'agents': ['pi', 'copilot'],
        'version': '0.11.0',
      }) as DeviceInfoResult;
      expect(m.host?.platform, DevicePlatform.other);
      expect(m.host?.terminal, DeviceTerminal.none);
      // An agent this app does not know is dropped, not misread as Pi.
      expect(m.agents, [AgentKind.pi]);
    });
  });

  group('ModelsList — agent echo', () {
    final agyModel = {
      'id': 'gemini-4-neon-high',
      'name': 'Gemini 4 Neon (High)',
      'provider': 'google',
      'reasoning': false,
      'context_window': 0,
      'vision': false,
    };

    test('a Pi catalogue has no agent (original shape)', () {
      final m = ServerMessage.fromJson({
        'type': 'models_list',
        'in_reply_to': '01J',
        'models': [agyModel],
      }) as ModelsList;
      expect(m.agent, isNull);
      expect(m.models.single.id, 'gemini-4-neon-high');
    });

    test('an AGY catalogue echoes its agent', () {
      final m = ServerMessage.fromJson({
        'type': 'models_list',
        'in_reply_to': '01J',
        'models': [agyModel],
        'agent': 'agy',
      }) as ModelsList;
      expect(m.agent, AgentKind.agy);
      expect(m.models.single.provider, 'google');
    });
  });
}
