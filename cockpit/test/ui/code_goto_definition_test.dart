import 'package:cockpit/app/core/domain/entities/lsp_location.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('offsetToPosition', () {
    test('offset 0 → linha 0, char 0', () {
      const text = 'hello';
      final pos = offsetToPosition(text, 0);
      expect(pos.line, 0);
      expect(pos.character, 0);
    });

    test('offset meio da linha → char correto', () {
      const text = 'hello world';
      final pos = offsetToPosition(text, 6); // 'w'
      expect(pos.line, 0);
      expect(pos.character, 6);
    });

    test('offset multi-linha', () {
      const text = 'hello\nworld';
      // \n @ offset 5, 'w' @ offset 6
      final pos = offsetToPosition(text, 6);
      expect(pos.line, 1);
      expect(pos.character, 0);
    });

    test('offset beyond text → clampa', () {
      const text = 'hello';
      final pos = offsetToPosition(text, 999);
      expect(pos.line, 0);
      expect(pos.character, 5);
    });
  });

  group('parseDefinitionResponse', () {
    test('Location simples', () {
      final response = {
        'uri': 'file:///path/to/file.ts',
        'range': {
          'start': {'line': 10, 'character': 5},
          'end': {'line': 10, 'character': 8},
        },
      };
      final loc = parseDefinitionResponse(response);
      expect(loc, isNotNull);
      expect(loc?.uri, 'file:///path/to/file.ts');
      expect(loc?.range.start.line, 10);
    });

    test('Location[] — pega primeira', () {
      final response = [
        {
          'uri': 'file:///first.ts',
          'range': {
            'start': {'line': 0, 'character': 0},
            'end': {'line': 0, 'character': 1},
          },
        },
        {
          'uri': 'file:///second.ts',
          'range': {
            'start': {'line': 5, 'character': 0},
            'end': {'line': 5, 'character': 1},
          },
        },
      ];
      final loc = parseDefinitionResponse(response);
      expect(loc?.uri, 'file:///first.ts');
    });

    test('LocationLink (targetUri format)', () {
      final response = {
        'targetUri': 'file:///target.ts',
        'targetRange': {
          'start': {'line': 20, 'character': 0},
          'end': {'line': 20, 'character': 5},
        },
        'originSelectionRange': {
          'start': {'line': 0, 'character': 0},
          'end': {'line': 0, 'character': 5},
        },
      };
      final loc = parseDefinitionResponse(response);
      expect(loc?.uri, 'file:///target.ts');
      expect(loc?.range.start.line, 20);
    });

    test('null response → null', () {
      final loc = parseDefinitionResponse(null);
      expect(loc, isNull);
    });

    test('empty list → null', () {
      final loc = parseDefinitionResponse([]);
      expect(loc, isNull);
    });
  });
}
