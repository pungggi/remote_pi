import 'package:cockpit/app/core/data/setup/storage_location.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A montagem de paths do storage é testada com contexto Windows explícito
/// (`p.windows`) — dá pra validar o comportamento com `\` e separadores mistos
/// mesmo rodando em macOS/Linux (bug de campo: interpolação com `/` literal
/// gerava paths mistos que quebravam criação/resolução de diretório).
void main() {
  group('StorageLocation.dataDirUnder', () {
    test('usa o separador da plataforma (Windows)', () {
      expect(
        StorageLocation.dataDirUnder(r'C:\Users\x\AppData\Roaming', p.windows),
        r'C:\Users\x\AppData\Roaming'
        '\\$storageSubdir',
      );
    });

    test('normaliza separadores mistos (Windows)', () {
      expect(
        StorageLocation.dataDirUnder(r'C:\Users\x/Documents', p.windows),
        r'C:\Users\x\Documents'
        '\\$storageSubdir',
      );
    });

    test('apara espaços e normaliza no POSIX', () {
      expect(
        StorageLocation.dataDirUnder('  /Users/x//Documents/ ', p.posix),
        '/Users/x/Documents/$storageSubdir',
      );
    });
  });

  group('StorageLocation.normalizeRoot', () {
    test('ponteiro gravado com `/` por versão antiga vira `\\` no Windows', () {
      expect(
        StorageLocation.normalizeRoot('C:/Users/x/Sync', p.windows),
        r'C:\Users\x\Sync',
      );
    });

    test('apara whitespace e barras redundantes', () {
      expect(StorageLocation.normalizeRoot(' /a//b/c/ \n', p.posix), '/a/b/c');
    });
  });
}
