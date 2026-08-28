import 'package:path/path.dart' as p;

class NormalizedHarnessInvocation {
  final String entryPointName;
  final List<String> harnessArgs;

  const NormalizedHarnessInvocation({
    required this.entryPointName,
    required this.harnessArgs,
  });
}

abstract class TerminalHarnessNormalizer {
  static const Set<String> _knownRuntimes = {
    'node',
    'bun',
    'deno',
    'python',
    'python3',
    'npx',
    'uvx',
  };

  static const Map<String, String> _scriptPackageAlias = {
    'pi-coding-agent': 'pi',
    'claude-code': 'claude',
    'cursor-agent': 'cursor-agent',
  };

  /// Normalizes an executable path and process argument list into a candidate
  /// entry point name and harness arguments.
  static NormalizedHarnessInvocation? normalize({
    required String executable,
    required List<String> argv,
  }) {
    final execBase = _cleanBinaryName(executable);
    if (execBase.isEmpty) return null;

    final args = argv.length > 1 ? argv.sublist(1) : <String>[];

    if (_knownRuntimes.contains(execBase)) {
      return _normalizeRuntime(execBase, args);
    }

    return NormalizedHarnessInvocation(
      entryPointName: execBase,
      harnessArgs: args,
    );
  }

  static String _cleanBinaryName(String pathOrName) {
    var name = p.basename(pathOrName).toLowerCase();
    if (name.endsWith('.exe') ||
        name.endsWith('.cmd') ||
        name.endsWith('.bat')) {
      name = p.basenameWithoutExtension(name);
    }
    return name;
  }

  static NormalizedHarnessInvocation? _normalizeRuntime(
    String runtime,
    List<String> args,
  ) {
    int scriptIdx = -1;
    for (int i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg.startsWith('-')) {
        // Skip flags to runtime e.g. --max-old-space-size=4096
        continue;
      }
      scriptIdx = i;
      break;
    }

    if (scriptIdx == -1) return null;

    final scriptPath = args[scriptIdx];
    final harnessArgs = args.sublist(scriptIdx + 1);

    var scriptBase = p.basename(scriptPath).toLowerCase();
    if (scriptBase.endsWith('.js') ||
        scriptBase.endsWith('.py') ||
        scriptBase.endsWith('.ts')) {
      scriptBase = p.basenameWithoutExtension(scriptBase);
    }

    if (scriptBase == 'cli' || scriptBase == 'index' || scriptBase == 'main') {
      // Check package directory in path
      final normalizedPath = p.normalize(scriptPath).toLowerCase();
      for (final entry in _scriptPackageAlias.entries) {
        if (normalizedPath.contains(entry.key)) {
          return NormalizedHarnessInvocation(
            entryPointName: entry.value,
            harnessArgs: harnessArgs,
          );
        }
      }
    }

    return NormalizedHarnessInvocation(
      entryPointName: scriptBase,
      harnessArgs: harnessArgs,
    );
  }
}
