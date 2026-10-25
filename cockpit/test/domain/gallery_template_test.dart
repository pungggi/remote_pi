import 'package:cockpit/app/cockpit/domain/entities/gallery_template.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GalleryTemplate.uniqueFileName', () {
    test('returns the base name when free', () {
      expect(GalleryTemplate.layout.uniqueFileName(['a.txt']), 'dev.ckp');
    });

    test('suffixes -2, -3… when taken (case-insensitive)', () {
      expect(GalleryTemplate.layout.uniqueFileName(['DEV.CKP']), 'dev-2.ckp');
      expect(
        GalleryTemplate.kanban.uniqueFileName([
          'board.kanban',
          'board-2.kanban',
        ]),
        'board-3.kanban',
      );
    });
  });

  test('tasks lives under .cockpit with a fixed name', () {
    expect(GalleryTemplate.tasks.relativePath, '.cockpit/tasks.json');
    expect(GalleryTemplate.tasks.fixedName, isTrue);
    expect(GalleryTemplate.html.relativePath, 'view.html');
  });

  test('every template has content and a colored asset', () {
    for (final t in GalleryTemplate.values) {
      expect(t.content, isNotEmpty);
      expect(t.iconAsset, startsWith('assets/'));
      expect(t.fileName, endsWith('.${t.extension}'));
    }
  });
}
