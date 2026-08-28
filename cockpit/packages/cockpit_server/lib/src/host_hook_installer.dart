import 'dart:convert';
import 'dart:io';

/// Instala o hook do Claude Code no `~/.claude/settings.json` do HOST (plano 60,
/// Wave G, G1). Espelha o installer do cliente (`ClaudeHookInstallerImpl`), mas
/// headless (sem Flutter) — roda dentro do `cockpit-server`. Assim, uma sessão
/// de agente num terminal REMOTO reporta o turno via `cockpit hook` → socket de
/// status do host → protocolo → cliente (spinner/chime).
///
/// Idempotente: remove/reinsere só o entry marcado (`_cockpit`), preservando
/// hooks do usuário. Falha (sem HOME, sem CLI) é silenciosa e não-fatal — o
/// servidor segue sem turn-status.
class HostHookInstaller {
  HostHookInstaller({this.cliPathOverride});

  /// Caminho explícito da CLI `cockpit` (arg `--cli` do server). Se nulo,
  /// resolve ao lado do executável do server ou no PATH.
  final String? cliPathOverride;

  static const String _marker = '_cockpit';
  static const String _markerValue = 'v1';

  static const List<String> _events = <String>[
    'UserPromptSubmit',
    'PreToolUse',
    'PostToolUse',
    'Notification',
    'Stop',
    'SessionStart',
    'SessionEnd',
  ];

  /// Instala o hook se der pra resolver HOME + a CLI. No-op silencioso senão.
  Future<void> ensureInstalled() async {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return;
    final cli = await resolveCli();
    if (cli == null) return;
    await _writeClaudeConfig(home, '${_quote(cli)} hook');
  }

  /// Resolve a CLI `cockpit` que sabe o subcomando `hook`. Público porque o
  /// servidor também precisa do caminho: é a pasta dela que entra no PATH das
  /// PTYs, para `cockpit …` resolver num terminal remoto. Ordem: override →
  /// ao lado do executável do server → PATH (`which`). Confirma pelo sufixo `r`
  /// da versão (só a CLI Rust o emite).
  Future<String?> resolveCli() async {
    final candidates = <String?>[
      if (cliPathOverride != null && cliPathOverride!.isNotEmpty)
        cliPathOverride!,
      _besideServer('cockpit'),
      await _which('cockpit'),
    ].whereType<String>();
    for (final c in candidates) {
      if (await _handlesHook(c)) return c;
    }
    return null;
  }

  String _besideServer(String name) {
    final dir = File(Platform.resolvedExecutable).parent.path;
    return '$dir/$name';
  }

  Future<String?> _which(String name) async {
    try {
      final out = await Process.run('which', <String>[name]);
      if (out.exitCode != 0) return null;
      final path = '${out.stdout}'.trim();
      return path.isEmpty ? null : path;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _handlesHook(String cliPath) async {
    if (!File(cliPath).existsSync()) return false;
    try {
      final out = await Process.run(cliPath, const <String>['--version']);
      if (out.exitCode != 0) return false;
      return '${out.stdout}'.trim().endsWith('r');
    } catch (_) {
      return false;
    }
  }

  Future<void> _writeClaudeConfig(String home, String command) async {
    final file = File('$home/.claude/settings.json');
    Map<String, dynamic> root = <String, dynamic>{};
    if (file.existsSync()) {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) root = Map<String, dynamic>.from(decoded);
    } else {
      await file.parent.create(recursive: true);
    }

    final hooksRaw = root['hooks'];
    final hooks = hooksRaw is Map
        ? Map<String, dynamic>.from(hooksRaw)
        : <String, dynamic>{};

    Map<String, dynamic> ourGroup() => <String, dynamic>{
      'matcher': '',
      'hooks': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'command',
          'command': command,
          _marker: _markerValue,
        },
      ],
    };

    for (final event in _events) {
      final existing = hooks[event];
      final list = existing is List
          ? List<dynamic>.from(existing)
          : <dynamic>[];
      list.removeWhere(_isOurs);
      list.add(ourGroup());
      hooks[event] = list;
    }
    root['hooks'] = hooks;

    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(root),
      flush: true,
    );
  }

  bool _isOurs(dynamic group) {
    if (group is! Map) return false;
    final hooks = group['hooks'];
    if (hooks is! List) return false;
    return hooks.any((h) => h is Map && h[_marker] == _markerValue);
  }

  String _quote(String path) => path.contains(' ') ? '"$path"' : path;
}
