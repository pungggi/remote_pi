import 'dart:io';

import 'package:cockpit/app/core/utils/path_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizePath', () {
    test('converte separador do Windows', () {
      expect(normalizePath(r'C:\proj\src\a.dart'), 'C:/proj/src/a.dart');
    });

    test('é idempotente', () {
      const p = 'C:/proj/src/a.dart';
      expect(normalizePath(normalizePath(p)), p);
    });

    test('não mexe em caminho POSIX', () {
      expect(normalizePath('/Users/jacob/proj'), '/Users/jacob/proj');
    });

    test('preserva a letra do drive', () {
      expect(normalizePath(r'D:\x'), startsWith('D:'));
    });
  });

  group('basenameOf', () {
    test('caminho do Windows devolve só o nome', () {
      // Era o bug: split('/') devolvia o caminho inteiro como "nome", e a
      // cópia recursiva montava destino inválido a partir dele.
      expect(basenameOf(r'C:\proj\src\a.dart'), 'a.dart');
    });

    test('caminho POSIX', () {
      expect(basenameOf('/a/b/c.txt'), 'c.txt');
    });

    test('tolera barra final', () {
      expect(basenameOf('/a/b/'), 'b');
      expect(basenameOf(r'C:\a\b\'), 'b');
    });

    test('nome solto volta inteiro', () {
      expect(basenameOf('a.txt'), 'a.txt');
    });
  });

  group('dirnameOf', () {
    test('pai em caminho do Windows', () {
      expect(dirnameOf(r'C:\proj\src\a.dart'), 'C:/proj/src');
    });

    test('pai em caminho POSIX', () {
      expect(dirnameOf('/a/b/c.txt'), '/a/b');
    });

    test('sem pai identificável volta o próprio', () {
      expect(dirnameOf('a.txt'), 'a.txt');
    });
  });

  group('isUnderPath', () {
    test('o próprio caminho conta como sob a raiz', () {
      expect(isUnderPath('/a/b', '/a/b'), isTrue);
    });

    test('descendente POSIX', () {
      expect(isUnderPath('/a/b/c.txt', '/a/b'), isTrue);
    });

    test('descendente com separador do Windows dos dois lados', () {
      // O caso que quebrava tudo: startsWith('$root/') nunca casava, então
      // rootContaining devolvia null e o workspace inteiro perdia git/staging.
      expect(isUnderPath(r'C:\proj\src\a.dart', r'C:\proj'), isTrue);
    });

    test('separadores misturados ainda casam', () {
      expect(isUnderPath(r'C:\proj\src', 'C:/proj'), isTrue);
      expect(isUnderPath('C:/proj/src', r'C:\proj'), isTrue);
    });

    test('irmão com prefixo comum NÃO conta', () {
      expect(isUnderPath('/a/bc', '/a/b'), isFalse);
      expect(isUnderPath(r'C:\projeto', r'C:\proj'), isFalse);
    });

    test('tolera barra final na raiz', () {
      expect(isUnderPath('/a/b/c', '/a/b/'), isTrue);
    });

    test('fora da raiz', () {
      expect(isUnderPath('/x/y', '/a/b'), isFalse);
    });
  });

  group('joinPath', () {
    test('junta sem duplicar separador', () {
      expect(joinPath('/a/b', 'c.txt'), '/a/b/c.txt');
      expect(joinPath('/a/b/', 'c.txt'), '/a/b/c.txt');
    });

    test('normaliza o diretório do Windows', () {
      expect(joinPath(r'C:\a\b', 'c.txt'), 'C:/a/b/c.txt');
    });
  });

  group('toNativePath', () {
    test('devolve a forma que o SO atual entende', () {
      final out = toNativePath('C:/a/b');
      if (Platform.isWindows) {
        expect(out, r'C:\a\b');
      } else {
        expect(out, 'C:/a/b'); // identidade fora do Windows
      }
    });
  });
}
