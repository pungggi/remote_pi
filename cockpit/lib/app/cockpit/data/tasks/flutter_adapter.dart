import 'dart:io';

import 'package:cockpit/app/cockpit/data/tasks/project_paths.dart';
import 'package:cockpit/app/cockpit/domain/contracts/task_adapter.dart';
import 'package:cockpit/app/cockpit/domain/entities/task_definition.dart';
import 'package:cockpit/i18n/strings.g.dart';

/// Detecta tasks Flutter a partir do `pubspec.yaml`. É a ÚNICA borda que
/// conhece `flutter run`, as teclas `r`/`R` e o reload-on-save — o core ignora
/// tudo isso e só vê `command`/`args`/`interactiveKeys`/`watch`.
class FlutterAdapter implements TaskAdapter {
  const FlutterAdapter();

  @override
  Future<bool> matches(String cwd) async {
    final file = File(joinPath(cwd, 'pubspec.yaml'));
    if (!await file.exists()) return false;
    // Distingue Flutter de um package Dart puro (que não tem `flutter run`).
    final content = await file.readAsString();
    return RegExp(r'^\s*flutter\s*:', multiLine: true).hasMatch(content) ||
        content.contains('sdk: flutter');
  }

  @override
  Future<List<TaskDefinition>> tasksFor(String cwd) async {
    if (!await matches(cwd)) return const [];
    return [
      TaskDefinition(
        id: 'flutter:run',
        label: 'run',
        cwd: cwd,
        command: 'flutter',
        args: const ['run'],
        kind: TaskKind.watch,
        interactiveKeys: [
          InteractiveKey(
            key: 'r',
            label: t.cockpit.tasks.hotReload,
            icon: 'refresh',
            primary: true,
          ),
          InteractiveKey(
            key: 'R',
            label: t.cockpit.tasks.hotRestart,
            icon: 'restart',
            primary: true,
          ),
          InteractiveKey(key: 'p', label: t.cockpit.tasks.toggleDebugPaint),
          InteractiveKey(key: 'o', label: t.cockpit.tasks.togglePlatform),
          InteractiveKey(key: 'q', label: t.cockpit.tasks.quit, icon: 'stop'),
        ],
        // `flutter run` CLI não recarrega ao salvar — o cockpit observa e
        // manda `r` (o que o plugin do IDE faz por baixo).
        watch: const TaskWatch(
          paths: ['lib', 'assets'],
          ignore: ['build', '.dart_tool'],
          onChange: 'Hot reload',
        ),
        progressPatterns: const [
          ProgressPattern(
            begin: r'Performing hot reload',
            end: r'Reloaded .* in .*ms',
          ),
          ProgressPattern(
            begin: r'Performing hot restart',
            end: r'Restarted application in .*ms',
          ),
        ],
      ),
      TaskDefinition(
        id: 'flutter:test',
        label: 'test',
        cwd: cwd,
        command: 'flutter',
        args: const ['test'],
        kind: TaskKind.oneShot,
      ),
    ];
  }
}
