import 'package:cockpit/app/cockpit/domain/entities/notebook_document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses frontmatter title/tags/dates and strips it from body', () {
    final n = NotebookNote.parse('/nb/a.md', '''---
title: "Túnel: SSH"
tags: [Relay, agent]
created: 2026-09-07T10:12
---

Corpo.
''');
    expect(n.title, 'Túnel: SSH');
    expect(n.tags, ['relay', 'agent']);
    expect(n.fromAgent, isTrue);
    expect(n.created, DateTime(2026, 9, 7, 10, 12));
    expect(n.body, 'Corpo.\n');
  });

  test('no frontmatter → title from file name, untagged', () {
    final n = NotebookNote.parse('/nb/2026-09-07-ideia.md', '# Oi\n');
    expect(n.title, '2026-09-07-ideia');
    expect(n.tags, [kUntagged]);
    expect(n.body, '# Oi\n');
  });

  test('template + fileNameFor + touchUpdated round-trip', () {
    final now = DateTime(2026, 9, 7, 9, 5);
    final raw = NotebookNote.template(title: 'Nova nota', tags: [], now: now);
    final n = NotebookNote.parse('/nb/x.md', raw);
    expect(n.title, 'Nova nota');
    expect(n.tags, [kUntagged]);
    expect(
      NotebookNote.fileNameFor('Ação rápida!', now),
      '2026-09-07-acao-rapida.md',
    );
    final touched = NotebookNote.touchUpdated(raw, DateTime(2026, 9, 8, 1, 2));
    expect(
      NotebookNote.parse('/nb/x.md', touched).updated,
      DateTime(2026, 9, 8, 1, 2),
    );
  });

  test('setTags rewrites or creates the tags line', () {
    final a = NotebookNote.setTags('---\ntitle: x\ntags: [a]\n---\nb', [
      'Relay',
      'bug',
    ]);
    expect(NotebookNote.parse('/n.md', a).tags, ['relay', 'bug']);
    final b = NotebookNote.setTags('# solto\n', ['z']);
    expect(NotebookNote.parse('/n.md', b).tags, ['z']);
    expect(NotebookNote.parse('/n.md', b).body, '# solto\n');
    final c = NotebookNote.setTags(a, []);
    expect(NotebookNote.parse('/n.md', c).tags, [kUntagged]);
  });

  test('setTitle rewrites the title line only', () {
    final a = NotebookNote.setTitle(
      '---\ntitle: x\ntags: [a]\n---\nb',
      'Novo: t',
    );
    final n = NotebookNote.parse('/n.md', a);
    expect(n.title, 'Novo: t');
    expect(n.tags, ['a']);
    expect(n.body, 'b');
  });

  test('replaceBody keeps the frontmatter and swaps the body', () {
    const raw = '---\ntitle: x\n---\n\nold\n';
    final out = NotebookNote.replaceBody(raw, 'new **bold**\n');
    final n = NotebookNote.parse('/n.md', out);
    expect(n.title, 'x');
    expect(n.body, 'new **bold**\n');
    expect(NotebookNote.replaceBody('plain', 'x'), 'x');
  });

  test('multi-line title round-trips through the frontmatter', () {
    final raw = NotebookNote.setTitle(
      '---\ntags: [a]\n---\nb',
      'Linha 1\nLinha "2"',
    );
    expect(raw, contains('title: "Linha 1\\nLinha \\"2\\""'));
    expect(NotebookNote.parse('/n.md', raw).title, 'Linha 1\nLinha "2"');
  });
}
