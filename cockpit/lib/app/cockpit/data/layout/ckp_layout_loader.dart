import 'dart:io';

import 'package:yaml/yaml.dart';

import 'package:cockpit/app/cockpit/domain/contracts/layout_loader.dart';
import 'package:cockpit/app/cockpit/domain/entities/layout_spec.dart';
import 'package:cockpit/app/core/domain/result.dart';

/// Parser do `.ckp` — YAML de orquestração de panes. Valida com mensagens
/// legíveis (o layout é ação explícita do usuário; erro nunca é silencioso).
///
/// Regras de portabilidade do `cwd`: **relativo à pasta do arquivo** e com
/// `/` — absolutos e `\` são rejeitados pra garantir que o mesmo arquivo
/// commitado rode em macOS, Linux e Windows.
class CkpLayoutLoader implements LayoutLoader {
  const CkpLayoutLoader({this.hostOs});

  /// SO usado no filtro de `platforms` — só sobrescrito em teste.
  final String? hostOs;

  String get _os => hostOs ?? Platform.operatingSystem;

  @override
  Future<Result<LayoutSpec, String>> load(String ckpPath) async {
    final file = File(ckpPath);
    if (!await file.exists()) {
      return Failure('layout file not found: "$ckpPath"');
    }

    final Object? doc;
    try {
      doc = loadYaml(await file.readAsString());
    } on YamlException catch (e) {
      return Failure('invalid YAML: ${e.message}');
    }
    if (doc is! Map) return const Failure('layout must be a YAML mapping');

    final rawPanes = doc['panes'];
    if (rawPanes is! List || rawPanes.isEmpty) {
      return const Failure('layout needs a non-empty "panes" list');
    }

    final autorun = doc['autorun'];
    if (autorun != null && autorun != 'worktree') {
      return Failure('invalid autorun "$autorun" (only "worktree" exists)');
    }

    final panes = <LayoutPane>[];
    final seen = <String>{};
    for (final (i, raw) in rawPanes.indexed) {
      if (raw is! Map) return Failure('panes[$i] must be a mapping');
      final parsed = _parsePane(raw, i);
      switch (parsed) {
        case Failure(:final error):
          return Failure(error);
        case Success(:final value):
          if (!seen.add(value.name.toLowerCase())) {
            return Failure('duplicated pane name "${value.name}"');
          }
          if (_visibleOnThisOs(value.platforms)) panes.add(value);
      }
    }

    final base = ckpPath.split(RegExp(r'[/\\]')).last;
    final dot = base.lastIndexOf('.');
    return Success(
      LayoutSpec(
        name: dot > 0 ? base.substring(0, dot) : base,
        autorunWorktree: autorun == 'worktree',
        panes: panes,
      ),
    );
  }

  Result<LayoutPane, String> _parsePane(Map<dynamic, dynamic> m, int i) {
    final name = m['name'];
    if (name is! String || name.trim().isEmpty) {
      return Failure('panes[$i] needs a non-empty "name"');
    }

    final cwd = m['cwd'] ?? '.';
    if (cwd is! String) return Failure('panes[$i].cwd must be a string');
    if (cwd.contains(r'\')) {
      return Failure(
        'panes[$i].cwd: use forward slashes ("/") — backslashes break the '
        'file on other OSes',
      );
    }
    if (cwd.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(cwd)) {
      return Failure(
        'panes[$i].cwd must be relative to the .ckp file (absolute paths '
        'are not portable across machines)',
      );
    }

    final LayoutSplit split;
    switch (m['split']) {
      case null || 'tab':
        split = LayoutSplit.tab;
      case 'right':
        split = LayoutSplit.right;
      case 'down':
        split = LayoutSplit.down;
      case final other:
        return Failure(
          'panes[$i].split: invalid "$other" (use tab, right or down)',
        );
    }

    final command = m['command'];
    if (command != null && command is! String) {
      return Failure('panes[$i].command must be a string');
    }

    return Success(
      LayoutPane(
        name: name.trim(),
        cwd: cwd,
        split: split,
        command: (command as String?)?.trim(),
        platforms: _platforms(m['platforms']),
      ),
    );
  }

  /// Mesma semântica do `platforms` do tasks.json: string ou lista de
  /// `macos|windows|linux`; ausente/tipo errado → todos.
  List<String> _platforms(Object? v) {
    if (v is String) return [v];
    if (v is List) return v.map((e) => e.toString()).toList();
    return const [];
  }

  bool _visibleOnThisOs(List<String> platforms) =>
      platforms.isEmpty || platforms.any((p) => p.toLowerCase() == _os);
}
