import 'dart:io';

import 'package:cockpit/app/core/utils/user_home.dart';

/// Resultado de [resolveSpawnDirectory]: a pasta em que dá pra spawnar de fato,
/// e se ela é a que foi pedida.
class SpawnDirectory {
  const SpawnDirectory({required this.path, required this.requested});

  /// Pasta existente onde o processo pode nascer. Vazio = deixa o SO decidir
  /// (herda o cwd do app): último recurso, quando nem a home existe.
  final String path;

  /// O que foi pedido originalmente. Diferente de [path] = houve fallback.
  final String requested;

  bool get fellBack => path != requested;
}

/// Resolve uma pasta **existente** para spawnar um processo.
///
/// Spawnar num diretório que não existe é erro fatal do SO, não algo que dê
/// pra ignorar: no Windows o `CreateProcessW` falha com
/// `GetLastError=267` (ERROR_DIRECTORY) e no POSIX o `chdir` do filho falha.
/// Isso acontece na vida real quando o usuário apaga a pasta de um workspace e
/// abre o Cockpit depois: o layout salvo ainda aponta pra lá.
///
/// A ordem do fallback preserva o máximo de contexto:
/// 1. a pasta pedida, se existir;
/// 2. o ancestral existente mais próximo (`C:\projects\api` some, mas
///    `C:\projects` continua lá);
/// 3. a home do usuário;
/// 4. string vazia (o chamador deixa o SO herdar o cwd do app).
SpawnDirectory resolveSpawnDirectory(String wanted) {
  final requested = wanted.trim();
  if (requested.isEmpty) {
    return SpawnDirectory(path: _homeOrEmpty(), requested: requested);
  }
  if (Directory(requested).existsSync()) {
    return SpawnDirectory(path: requested, requested: requested);
  }

  final ancestor = _nearestExistingAncestor(requested);
  if (ancestor != null) {
    return SpawnDirectory(path: ancestor, requested: requested);
  }
  return SpawnDirectory(path: _homeOrEmpty(), requested: requested);
}

String _homeOrEmpty() {
  final home = userHome();
  if (home == null || home.isEmpty) return '';
  return Directory(home).existsSync() ? home : '';
}

/// Sobe a árvore até achar uma pasta que exista. `null` se chegar na raiz sem
/// achar nada (drive removido, share de rede fora do ar).
String? _nearestExistingAncestor(String path) {
  var current = Directory(path).parent;
  // `parent` da raiz devolve ela mesma: comparar o caminho detecta o topo.
  while (true) {
    if (current.existsSync()) return current.path;
    final next = current.parent;
    if (next.path == current.path) return null;
    current = next;
  }
}
