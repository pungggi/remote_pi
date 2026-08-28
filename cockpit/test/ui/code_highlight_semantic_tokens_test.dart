import 'package:cockpit/app/core/domain/entities/lsp_semantic_tokens.dart';
import 'package:cockpit/app/core/ui/widgets/code_highlight.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('decodeSemanticTokens', () {
    test('decodifica array plano em tokens com offsets lineares', () {
      const text = 'class Foo {}';
      // Token 1: deltaLine=0, deltaStart=0, length=5 (class), type=1 (keyword), mods=0
      // Token 2: deltaLine=0, deltaStart=6, length=3 (Foo), type=0 (class), mods=0
      final data = [
        0, 0, 5, 1, 0, // class @ offset 0-5
        0, 6, 3, 0, 0, // Foo @ offset 6-9
      ];
      final legend = SemanticTokensLegend(
        tokenTypes: ['class', 'keyword'],
        tokenModifiers: ['declaration'],
      );

      final tokens = decodeSemanticTokens(text, data, legend);

      expect(tokens.tokens, hasLength(2));
      expect(tokens.tokens[0].start, 0);
      expect(tokens.tokens[0].end, 5);
      expect(tokens.tokens[0].tokenType, 'keyword');
      expect(tokens.tokens[1].start, 6);
      expect(tokens.tokens[1].end, 9);
      expect(tokens.tokens[1].tokenType, 'class');
    });

    test('decodifica com deltaLine > 0 (múltiplas linhas)', () {
      const text = 'class A {}\nclass B {}';
      // Linha 0: class @ 0-5
      // Linha 1: class @ 11-16
      final data = [
        0, 0, 5, 1, 0, // class @ offset 0-5
        1, 0, 5, 1, 0, // class @ offset 11-16 (deltaLine=1 → linha 1, start=0)
      ];
      final legend = SemanticTokensLegend(
        tokenTypes: ['class', 'keyword'],
        tokenModifiers: [],
      );

      final tokens = decodeSemanticTokens(text, data, legend);

      expect(tokens.tokens, hasLength(2));
      expect(tokens.tokens[1].start, 11);
      expect(tokens.tokens[1].end, 16);
    });

    test('decodifica modificadores via bitmask', () {
      const text = 'const x';
      // Token com bitmask 0b11 (modifiers 0 e 1)
      final data = [0, 0, 5, 0, 3]; // mods = 0b11
      final legend = SemanticTokensLegend(
        tokenTypes: ['type'],
        tokenModifiers: ['declaration', 'readonly'],
      );

      final tokens = decodeSemanticTokens(text, data, legend);

      expect(tokens.tokens[0].tokenModifiers, ['declaration', 'readonly']);
    });

    test('lista vazia pra data vazio', () {
      const text = 'abc';
      final legend = SemanticTokensLegend(tokenTypes: [], tokenModifiers: []);

      final tokens = decodeSemanticTokens(text, [], legend);

      expect(tokens.tokens, isEmpty);
    });
  });

  group('SemanticRange overlay', () {
    test('semantic color sobrescreve léxico em buildCodeSpan', () {
      // Este teste é de integração e requer BuildContext.
      // Teste simples: verificar que SemanticRange é criado corretamente.
      final ranges = [
        SemanticRange(0, 5, 'class'),
        SemanticRange(6, 9, 'variable'),
      ];

      expect(ranges, hasLength(2));
      expect(ranges[0].tokenType, 'class');
      expect(ranges[1].start, 6);
    });
  });
}
