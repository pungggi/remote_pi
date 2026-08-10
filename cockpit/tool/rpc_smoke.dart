// Manual headless smoke for PiRpcProcess (the real Dart gateway — no Flutter
// engine needed). Drives spawn → sendPrompt → stream → kill and prints what
// flows; handy to re-validate the RPC path without the GUI. NOT run by
// `flutter test`. Requires a working provider/model (edit below).
//
//   dart run tool/rpc_smoke.dart
//
// See docs/rpc-protocol.md for the schema this exercises.
import 'dart:async';
import 'dart:io';

import 'package:cockpit/app/core/env.dart';
import 'package:cockpit/app/cockpit/data/rpc/pi_rpc_process.dart';
import 'package:cockpit/app/cockpit/domain/entities/rpc_event.dart';
import 'package:cockpit/app/cockpit/domain/entities/thinking_level.dart';

Future<void> main(List<String> args) async {
  // dart run tool/rpc_smoke.dart [provider] [model]
  // Sem args → default do pi (settings.json).
  final provider = args.isNotEmpty ? args[0] : null;
  final model = args.length > 1 ? args[1] : null;
  final gateway = PiRpcProcess(
    PiSpawnConfig(
      executable: '/opt/homebrew/bin/pi',
      provider: provider,
      model: model,
    ),
  );

  final ended = Completer<void>();
  gateway.events.listen((event) {
    switch (event) {
      case RpcTextDelta(:final delta):
        stdout.write(delta);
      case RpcThinkingDelta():
        stdout.write('.');
      case RpcToolStart(:final toolName, :final args):
        stdout.writeln('\n[tool-start] $toolName $args');
      case RpcToolEnd(:final toolName, :final isError):
        stdout.writeln('[tool-end] $toolName error=$isError');
      case RpcCommandResponse(:final command, :final success):
        stdout.writeln('[response] $command success=$success');
      case RpcStreamError(:final message):
        stdout.writeln('[stream-error] $message');
      case RpcAutoRetry(:final attempt, :final maxAttempts, :final message):
        stdout.writeln('[auto-retry] $attempt/$maxAttempts — $message');
      case RpcDiagnostic(:final text):
        stdout.writeln('[stderr] $text');
      case RpcAgentEnd():
        stdout.writeln('\n[agent_end]');
        if (!ended.isCompleted) ended.complete();
      case RpcProcessExit(:final code):
        stdout.writeln('[exit] code=$code');
      default:
        break;
    }
  });

  final spawn = await gateway.spawn(workingDirectory: Directory.current.path);
  stdout.writeln('spawn success=${spawn.isSuccess}');

  // Comandos request/response (modelo / effort / contexto).
  final models = await gateway.availableModels();
  models.fold(
    (list) => stdout.writeln('[models] ${list.length} disponíveis'),
    (e) => stdout.writeln('[models] erro: ${e.message}'),
  );
  final state = await gateway.state();
  state.fold(
    (s) => stdout.writeln(
      '[state] model=${s.model?.id} effort=${s.thinkingLevel.wire}',
    ),
    (e) => stdout.writeln('[state] erro: ${e.message}'),
  );
  final setLevel = await gateway.setThinkingLevel(ThinkingLevel.low);
  stdout.writeln('[set_thinking_level low] success=${setLevel.isSuccess}');

  await gateway.sendPrompt(
    'List the files in the current directory using your tools, then one short sentence.',
  );

  await ended.future.timeout(
    const Duration(seconds: 60),
    onTimeout: () {
      stdout.writeln('[timeout]');
    },
  );

  stdout.writeln('--- killing ---');
  await gateway.kill();
  stdout.writeln('--- killed ---');
  gateway.dispose();
}
