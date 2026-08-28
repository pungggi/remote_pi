import 'dart:io';
import 'dart:typed_data';

import 'package:cockpit/app/cockpit/data/filesystem/content_searcher_impl.dart';
import 'package:cockpit/app/cockpit/domain/entities/content_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const searcher = ContentSearcherImpl();
  late Directory root;

  Future<void> write(String rel, String content) async {
    final f = File('${root.path}/$rel');
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
  }

  Future<List<FileMatches>> run(
    String term, {
    bool caseSensitive = false,
    bool wholeWord = false,
    bool regex = false,
  }) => searcher
      .search(
        ContentQuery(
          root: root.path,
          term: term,
          caseSensitive: caseSensitive,
          wholeWord: wholeWord,
          regex: regex,
        ),
      )
      .toList();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cockpit_search_test_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('acha matches e reporta linha + range + caminho relativo', () async {
    await write(
      'app/auth/session.ts',
      'import { Clock } from "x";\n'
          'class SessionStore {\n'
          '  now() { return this.clock.now(); }\n'
          '}\n',
    );

    final results = await run('clock');
    expect(results, hasLength(1));
    final file = results.single;
    expect(file.relativePath, 'app/auth/session.ts');
    // "Clock" (linha 1) + "clock" (linha 3) = 2 matches, case-insensitive.
    expect(file.matchCount, 2);
    expect(file.matches.first.lineNumber, 1);
    final r = file.matches.first.ranges.single;
    expect(file.matches.first.text.substring(r.start, r.end), 'Clock');
  });

  test('case-sensitive respeita a caixa', () async {
    await write('a.txt', 'Clock\nclock\n');
    final cs = await run('clock', caseSensitive: true);
    expect(cs.single.matchCount, 1);
    expect(cs.single.matches.single.lineNumber, 2);
  });

  test('whole word não casa substring', () async {
    await write('a.txt', 'clock\nclockwork\n');
    final ww = await run('clock', wholeWord: true);
    expect(ww.single.matchCount, 1);
    expect(ww.single.matches.single.lineNumber, 1);
  });

  test('regex funciona e regex inválida emite erro', () async {
    await write('a.txt', 'foo123bar\n');
    final re = await run(r'\d+', regex: true);
    expect(re.single.matches.single.ranges.single, isA<MatchRange>());

    expect(() => run('[', regex: true), throwsA(isA<FormatException>()));
  });

  test('pula pastas ruidosas (node_modules) e arquivos binários', () async {
    await write('node_modules/dep/index.js', 'needle');
    await write('src/app.js', 'needle');
    // Binário: byte nulo no começo.
    final bin = File('${root.path}/blob.bin');
    await bin.writeAsBytes(
      Uint8List.fromList([0, 110, 101, 101, 100, 108, 101]),
    );

    final results = await run('needle');
    expect(results, hasLength(1));
    expect(results.single.relativePath, 'src/app.js');
  });

  test('termo vazio → sem resultados', () async {
    await write('a.txt', 'anything');
    expect(await run('   '), isEmpty);
  });
}
