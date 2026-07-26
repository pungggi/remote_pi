import 'dart:io';

/// Monta o relatório de erro que o usuário revisa antes de reportar, e a URL de
/// issue já preenchida no repositório do Remote Pi.
///
/// Não há envio automático nem telemetria: o relatório só sai da máquina se o
/// usuário clicar. É o que mantém o Cockpit local-only — ele enxerga caminhos de
/// arquivo, connection strings e prompts de agente, e nada disso deve viajar sem
/// o usuário ter visto o texto antes.
class IssueReport {
  const IssueReport({
    required this.title,
    required this.error,
    this.stack,
    this.logTail = '',
    required this.appVersion,
  });

  /// Repositório de destino das issues.
  static const String repoUrl = 'https://github.com/jacobaraujo7/remote_pi';

  /// Teto prático da URL de issue do GitHub. Acima disso o servidor recusa, então
  /// o corpo é truncado e o usuário é instruído a colar o resto (que já vai
  /// inteiro para o clipboard pelo botão "Copy details").
  static const int maxUrlBytes = 6000;

  final String title;
  final Object error;
  final StackTrace? stack;
  final String logTail;
  final String appVersion;

  /// Texto completo, sem truncar — é o que vai para o clipboard.
  String toMarkdown() {
    final buffer = StringBuffer()
      ..writeln('### What happened')
      ..writeln()
      ..writeln('<!-- Describe what you were doing when this happened. -->')
      ..writeln()
      ..writeln('### Environment')
      ..writeln()
      ..writeln('- Cockpit: $appVersion')
      ..writeln(
        '- OS: ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion}',
      )
      ..writeln('- Locale: ${Platform.localeName}')
      ..writeln()
      ..writeln('### Error')
      ..writeln()
      ..writeln('```')
      ..writeln(error.toString())
      ..writeln('```');

    if (stack != null) {
      buffer
        ..writeln()
        ..writeln('### Stack trace')
        ..writeln()
        ..writeln('```')
        ..writeln(stack.toString().trimRight())
        ..writeln('```');
    }

    if (logTail.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('### Log')
        ..writeln()
        ..writeln('```')
        ..writeln(logTail.trimRight())
        ..writeln('```');
    }

    return buffer.toString();
  }

  /// URL de `issues/new` com título e corpo preenchidos, truncando o corpo para
  /// caber no limite do GitHub.
  Uri toIssueUrl() {
    var body = toMarkdown();
    // Encolhe até a URL inteira caber — o encode pode triplicar o tamanho de
    // um stack trace cheio de símbolos, então medir o texto cru não basta.
    while (Uri.encodeComponent(body).length > maxUrlBytes &&
        body.length > 200) {
      body =
          '${body.substring(0, (body.length * 0.8).round())}\n'
          '```\n\n_(truncated — use "Copy details" for the full report)_\n';
    }
    return Uri.parse(
      '$repoUrl/issues/new',
    ).replace(queryParameters: {'title': title, 'body': body});
  }
}
