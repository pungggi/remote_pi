import 'dart:io';

/// Forma canônica de caminho **dentro** do Cockpit: sempre com `/`.
///
/// ## Por que existe
///
/// O app inteiro compara e monta caminho com `/` — `rootContaining`,
/// `_isUnder`, `_join`, os `split('/')` que extraem nome de arquivo. Só que o
/// `dart:io` devolve caminho **nativo**: no Windows, `C:\proj\src\a.dart`. O
/// resultado era `'C:\proj\src'.startsWith('C:\proj/')` → `false`, e com isso a
/// root nunca era encontrada: sem cor de git na árvore, e todo stage/discard
/// respondendo "File is outside the workspace roots".
///
/// A correção é normalizar **na fronteira de entrada** (onde o caminho nasce do
/// SO) em vez de espalhar `replaceAll` pelos ~40 lugares que consomem. As APIs
/// `File`/`Directory` do Dart aceitam `/` no Windows, então o caminho canônico
/// serve para tudo — menos para entregar a um programa nativo, onde entra
/// [toNativePath].
///
/// Caminho relativo do **git** já é `/` por definição; não precisa passar aqui.
String normalizePath(String path) => path.replaceAll(r'\', '/');

/// Converte de volta para o separador nativo do SO.
///
/// Só para entregar a programas externos que não aceitam `/` — o Explorer do
/// Windows é o caso conhecido: recebendo `C:/Users/...` ele abre a pasta
/// Documentos em silêncio, sem erro. Em macOS/Linux é identidade.
String toNativePath(String path) =>
    Platform.isWindows ? path.replaceAll('/', r'\') : path;

/// Último segmento do caminho, aceitando os dois separadores.
///
/// Tolerante a barra final (`/a/b/` → `b`) e a caminho sem separador
/// (`a.txt` → `a.txt`).
String basenameOf(String path) {
  final segments = normalizePath(
    path,
  ).split('/').where((s) => s.isNotEmpty).toList();
  return segments.isEmpty ? path : segments.last;
}

/// Diretório pai. Devolve o próprio caminho quando não há pai identificável
/// (raiz ou nome solto) — mesmo contrato do `_parentOf` que já existia.
String dirnameOf(String path) {
  final normalized = normalizePath(path);
  final i = normalized.lastIndexOf('/');
  return i <= 0 ? normalized : normalized.substring(0, i);
}

/// `true` se [path] é [root] ou um descendente dele. Normaliza os dois lados,
/// então funciona mesmo se um vier nativo e o outro canônico.
bool isUnderPath(String path, String root) {
  final p = normalizePath(path);
  final r = normalizePath(root);
  final base = r.endsWith('/') ? r.substring(0, r.length - 1) : r;
  return p == base || p.startsWith('$base/');
}

/// Junta diretório + nome na forma canônica, sem duplicar separador.
String joinPath(String dir, String name) {
  final base = normalizePath(dir);
  final trimmed = base.endsWith('/')
      ? base.substring(0, base.length - 1)
      : base;
  return '$trimmed/$name';
}
