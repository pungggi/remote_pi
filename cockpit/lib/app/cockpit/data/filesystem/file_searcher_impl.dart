import 'dart:io';

import 'package:cockpit/app/cockpit/domain/contracts/file_searcher.dart';
import 'package:cockpit/app/core/utils/path_utils.dart';

/// Indexa os arquivos de uma pasta (walk recursivo, pulando pastas pesadas) e
/// filtra por relevância. O índice por raiz é **cacheado** com TTL curto pra não
/// re-andar o disco a cada tecla.
class FileSearcherImpl implements FileSearcher {
  FileSearcherImpl();

  static const int _maxFiles = 6000;
  static const Duration _ttl = Duration(seconds: 15);

  /// Pastas ruidosas/pesadas que não entram no índice (além de qualquer `.dir`).
  static const Set<String> _ignored = <String>{
    'node_modules',
    'build',
    '.dart_tool',
    '.next',
    'dist',
    'out',
    'Pods',
    'DerivedData',
    '.gradle',
    '.venv',
    'venv',
    '__pycache__',
    'target',
    'vendor',
    'coverage',
  };

  final Map<String, _Cache> _cache = <String, _Cache>{};

  @override
  Future<List<String>> search(
    String root,
    String query, {
    int limit = 12,
  }) async {
    final files = await _files(root);
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return files.take(limit).toList();

    final ranked = <_Ranked>[];
    for (final path in files) {
      final lower = path.toLowerCase();
      final base = lower.split('/').last;
      final int score;
      if (base.startsWith(q)) {
        score = 0; // nome do arquivo começa com a query
      } else if (base.contains(q)) {
        score = 1; // nome do arquivo contém a query
      } else if (lower.contains(q)) {
        score = 2; // o caminho contém a query
      } else {
        continue;
      }
      ranked.add(_Ranked(path, score));
    }
    ranked.sort((a, b) {
      if (a.score != b.score) return a.score - b.score;
      return a.path.length - b.path.length; // empate → caminho mais curto
    });
    return ranked.take(limit).map((r) => r.path).toList();
  }

  Future<List<String>> _files(String root) async {
    final cached = _cache[root];
    if (cached != null && DateTime.now().difference(cached.builtAt) < _ttl) {
      return cached.files;
    }
    final files = await _walk(Directory(root));
    files.sort();
    _cache[root] = _Cache(DateTime.now(), files);
    return files;
  }

  Future<List<String>> _walk(Directory root) async {
    final out = <String>[];
    if (!await root.exists()) return out;
    final rootPath = root.path;
    final stack = <Directory>[root];
    while (stack.isNotEmpty && out.length < _maxFiles) {
      final dir = stack.removeLast();
      final List<FileSystemEntity> entries;
      try {
        entries = await dir.list(followLinks: false).toList();
      } catch (_) {
        continue; // pasta sem permissão etc.
      }
      for (final entity in entries) {
        final name = basenameOf(entity.path);
        if (entity is Directory) {
          if (name.startsWith('.') || _ignored.contains(name)) continue;
          stack.add(entity);
        } else if (entity is File) {
          if (name == '.DS_Store') continue; // lixo do Finder (macOS)
          if (out.length >= _maxFiles) break;
          // Normaliza antes de recortar o prefixo: no Windows `entity.path` vem
          // com `\` e o `startsWith('$rootPath/')` nunca casava, devolvendo
          // caminho absoluto onde a UI espera relativo.
          final p = normalizePath(entity.path);
          final root = normalizePath(rootPath);
          out.add(p.startsWith('$root/') ? p.substring(root.length + 1) : p);
        }
      }
    }
    return out;
  }
}

class _Cache {
  _Cache(this.builtAt, this.files);
  final DateTime builtAt;
  final List<String> files;
}

class _Ranked {
  _Ranked(this.path, this.score);
  final String path;
  final int score;
}
