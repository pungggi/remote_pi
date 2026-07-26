import 'dart:io';

import 'package:cockpit/app/cockpit/domain/contracts/file_system_reader.dart';
import 'package:cockpit/app/cockpit/domain/entities/file_node.dart';
import 'package:cockpit/app/core/utils/path_utils.dart';

/// Lê a árvore via `dart:io`: pastas primeiro (ordenadas), depois arquivos.
/// Inclui ocultos úteis (`.pi`, `.claude`, `.env`…), mas **esconde pastas de
/// VCS** ([_hiddenDirs]) em qualquer nível — `.git` nunca interessa navegar.
class FileSystemReaderImpl implements FileSystemReader {
  const FileSystemReaderImpl();

  /// Pastas de versionamento ocultadas em toda a árvore (não só na raiz).
  static const Set<String> _hiddenDirs = <String>{'.git', '.hg', '.svn'};

  @override
  Future<List<FileNode>> children(String dirPath) async {
    if (dirPath.isEmpty) return const <FileNode>[];
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const <FileNode>[];

    final dirs = <FileNode>[];
    final files = <FileNode>[];
    try {
      await for (final entity in dir.list(followLinks: false)) {
        // Fronteira de entrada: `entity.path` vem nativo (`\` no Windows) e
        // todo o resto do app compara/monta com `/`. Normaliza aqui.
        final path = normalizePath(entity.path);
        final name = basenameOf(path);
        final isDir = entity is Directory;
        if (isDir && _hiddenDirs.contains(name)) continue;
        if (name == '.DS_Store') continue; // lixo do Finder (macOS)
        final node = FileNode(name: name, path: path, isDirectory: isDir);
        (isDir ? dirs : files).add(node);
      }
    } on FileSystemException {
      return const <FileNode>[];
    }

    int byName(FileNode a, FileNode b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());
    dirs.sort(byName);
    files.sort(byName);
    return <FileNode>[...dirs, ...files];
  }
}
