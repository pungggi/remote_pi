// Grouped Home (by-model) — HomeViewModel.previewPrompt(): the last user
// prompt as a single-line, 200-char-capped tile preview.

import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('previewPrompt', () {
    test('collapses newlines and runs of whitespace onto one line', () {
      expect(
        HomeViewModel.previewPrompt('fix the\n\n  auth   timeout\nplease'),
        'fix the auth timeout please',
      );
    });

    test('caps at 200 characters with an ellipsis', () {
      final raw = 'x' * 350;
      final out = HomeViewModel.previewPrompt(raw)!;
      expect(out.length, 201); // 200 kept + ellipsis
      expect(out.startsWith('x' * 200), isTrue);
      expect(out.endsWith('…'), isTrue);
    });

    test('short prompts pass through unchanged (no ellipsis)', () {
      expect(HomeViewModel.previewPrompt('ship it'), 'ship it');
      final exactly200 = 'y' * 200;
      expect(HomeViewModel.previewPrompt(exactly200), exactly200);
    });

    test('code-point-safe cap — never splits a surrogate pair', () {
      // 201 rocket emoji = 402 UTF-16 code units; the cap must keep 200
      // COMPLETE emoji, not 200 code units.
      final raw = '🚀' * 201;
      final out = HomeViewModel.previewPrompt(raw)!;
      expect(out, '🚀' * 200 + '…');
    });

    test('null / blank-only input stays null', () {
      expect(HomeViewModel.previewPrompt(null), isNull);
      expect(HomeViewModel.previewPrompt('  \n\t '), isNull);
    });
  });
}
