import 'package:cockpit/app/core/data/diagnostics/issue_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IssueReport', () {
    test('markdown inclui versão, erro e stack', () {
      final report = IssueReport(
        title: '[cockpit] boom',
        error: StateError('deu ruim'),
        stack: StackTrace.fromString('#0 foo\n#1 bar'),
        appVersion: '1.14.12+41',
      );
      final md = report.toMarkdown();
      expect(md, contains('1.14.12+41'));
      expect(md, contains('deu ruim'));
      expect(md, contains('#0 foo'));
    });

    test('log entra no relatório quando existe', () {
      final report = IssueReport(
        title: 't',
        error: 'e',
        logTail: 'linha de log',
        appVersion: '1.0.0',
      );
      expect(report.toMarkdown(), contains('linha de log'));
    });

    test('log ausente não cria seção vazia', () {
      final report = IssueReport(title: 't', error: 'e', appVersion: '1.0.0');
      expect(report.toMarkdown(), isNot(contains('### Log')));
    });

    test('URL curta preserva o corpo inteiro', () {
      final report = IssueReport(
        title: 'curto',
        error: 'pequeno',
        appVersion: '1.0.0',
      );
      final url = report.toIssueUrl();
      expect(url.host, 'github.com');
      expect(url.path, endsWith('/issues/new'));
      expect(url.queryParameters['title'], 'curto');
      expect(url.queryParameters['body'], contains('pequeno'));
    });

    test('corpo gigante é truncado para caber no limite do GitHub', () {
      final report = IssueReport(
        title: 'grande',
        error: 'erro',
        // Stack sintético bem acima do teto, com caracteres que incham no
        // encode — é o caso que faz o GitHub recusar a URL.
        stack: StackTrace.fromString(
          List.filled(4000, '#0 a/b c<>&').join('\n'),
        ),
        appVersion: '1.0.0',
      );
      final url = report.toIssueUrl();
      final body = url.queryParameters['body']!;
      expect(
        Uri.encodeComponent(body).length,
        lessThanOrEqualTo(IssueReport.maxUrlBytes),
      );
      expect(body, contains('truncated'));
    });

    test('truncagem termina — não entra em loop com corpo mínimo', () {
      final report = IssueReport(
        title: 't',
        error: 'x' * 50,
        appVersion: '1.0.0',
      );
      expect(() => report.toIssueUrl(), returnsNormally);
    });
  });
}
