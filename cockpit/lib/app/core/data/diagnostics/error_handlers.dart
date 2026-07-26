import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:cockpit/app/core/data/diagnostics/diagnostics_log.dart';
import 'package:flutter/foundation.dart';

/// Instala as capturas globais de erro e roda [body] dentro de uma zona
/// guardada. Chamado uma única vez pelo `main()`, antes do `runApp`.
///
/// São quatro caminhos distintos — nenhum cobre o do outro:
/// - `FlutterError.onError`: erros do framework (build/layout/paint).
/// - `PlatformDispatcher.instance.onError`: erros assíncronos do engine.
/// - `runZonedGuarded`: o que escapa de `Future`/`Timer` no nosso código.
/// - `Isolate.current.addErrorListener`: erros de Isolate **filho** só chegam
///   aqui se o filho registrar o próprio listener (ver [guardIsolate]) — o
///   listener do main cobre apenas o próprio.
///
/// Fora do alcance de todos eles: morte nativa (SIGPIPE, segfault, `exit()`).
/// Essa classe é coberta pelo marcador de sessão do [DiagnosticsLog].
Future<void> runGuarded(Future<void> Function() body) async {
  final log = DiagnosticsLog.instance;

  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    log.logError('flutter', details.exception, details.stack);
    previous?.call(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    log.logError('platform', error, stack);
    return true; // tratado: não derruba o processo
  };

  Isolate.current.addErrorListener(
    RawReceivePort((dynamic pair) {
      final list = pair as List<dynamic>;
      log.logError(
        'isolate',
        list.first ?? 'erro sem descrição',
        list.length > 1 && list[1] != null
            ? StackTrace.fromString(list[1].toString())
            : null,
      );
    }).sendPort,
  );

  // Encerramento por sinal (kill, logout, `q` do flutter run) conta como saída
  // limpa: o usuário/SO pediu, não é crash. Sem isso o boot seguinte acusaria
  // falso positivo. SIGKILL não é interceptável — esse vai aparecer como sujo,
  // e tudo bem.
  //
  // No Windows só SIGINT existe: observar SIGTERM lá lança, então nem entra na
  // lista. O try/catch cobre o resto (plataforma que recuse algum sinal).
  final signals = <ProcessSignal>[
    ProcessSignal.sigint,
    if (!Platform.isWindows) ProcessSignal.sigterm,
  ];
  for (final signal in signals) {
    try {
      signal.watch().listen((_) {
        log.log('exit', 'sinal $signal recebido');
        log.markCleanExit();
        exit(0);
      });
    } on Object catch (_) {
      /* sinal não observável nesta plataforma */
    }
  }

  await runZonedGuarded(body, (error, stack) {
    log.logError('zone', error, stack);
  });
}

/// Registra o listener de erro **dentro** de um Isolate filho, encaminhando
/// para o log do main.
///
/// Necessário porque erro em Isolate não sobe para os handlers do main: os
/// workers de banco (`anaki_*`) e o de scrollback morriam em silêncio. Chame na
/// primeira linha do entrypoint do worker.
void guardIsolateErrors(SendPort? logPort) {
  if (logPort == null) return;
  Isolate.current.addErrorListener(
    RawReceivePort((dynamic pair) => logPort.send(pair)).sendPort,
  );
}
