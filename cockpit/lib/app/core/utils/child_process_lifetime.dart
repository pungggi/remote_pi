import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Amarra um processo filho à vida DESTE processo, no Windows.
///
/// O `cockpit-server` sobrevive de propósito à queda do app (é o que permite
/// retomar sessões), e o `--exit-on-idle` cobre o caso normal. Mas um órfão que
/// continua dono do socket é problema real: um app novo o encontra respondendo
/// e passa a falar com uma build antiga. Já aconteceu — uma correção publicada
/// não chegou a rodar porque o sidecar de uma instalação anterior seguia vivo
/// no caminho anunciado.
///
/// No Windows a amarra é um **Job Object** com `KILL_ON_JOB_CLOSE`: quando o
/// app morre, inclusive por crash ou fim forçado, o kernel fecha o job e leva o
/// filho junto. Em POSIX não há equivalente portátil, e o par `--exit-on-idle`
/// + vigia de posse do socket já cobre; por isso é no-op fora do Windows.
///
/// **Nunca é fatal.** Qualquer falha (job aninhado proibido, permissão, versão
/// de Windows) deixa o comportamento como era: filho independente.
void tieChildToThisProcess(int pid) {
  if (!Platform.isWindows) return;
  try {
    _WindowsJob.instance.adopt(pid);
  } on Object catch (e) {
    debugPrint('sidecar: não consegui amarrar o filho ao app ($e)');
  }
}

/// Job único do processo: criado na primeira vez e mantido aberto pelo resto da
/// vida do app — fechar o handle é justamente o que mata os filhos.
class _WindowsJob {
  _WindowsJob._();
  static final _WindowsJob instance = _WindowsJob._();

  static const _jobObjectExtendedLimitInformation = 9;
  static const _limitKillOnJobClose = 0x2000;
  static const _processTerminate = 0x0001;
  static const _processSetQuota = 0x0100;

  /// `JOBOBJECT_EXTENDED_LIMIT_INFORMATION` em x64: 144 bytes, com o
  /// `LimitFlags` no deslocamento 16 (depois de dois LARGE_INTEGER).
  static const _extendedLimitSize = 144;
  static const _limitFlagsOffset = 16;

  int? _job;

  void adopt(int pid) {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final job = _job ??= _createJob(kernel32);
    if (job == 0) return;

    final openProcess = kernel32
        .lookupFunction<
          IntPtr Function(Uint32, Int32, Uint32),
          int Function(int, int, int)
        >('OpenProcess');
    final assign = kernel32
        .lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>(
          'AssignProcessToJobObject',
        );
    final closeHandle = kernel32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'CloseHandle',
        );

    final handle = openProcess(_processSetQuota | _processTerminate, 0, pid);
    if (handle == 0) return;
    try {
      assign(job, handle);
    } finally {
      closeHandle(handle);
    }
  }

  int _createJob(DynamicLibrary kernel32) {
    final createJob = kernel32
        .lookupFunction<
          IntPtr Function(Pointer<Void>, Pointer<Utf16>),
          int Function(Pointer<Void>, Pointer<Utf16>)
        >('CreateJobObjectW');
    final setInfo = kernel32
        .lookupFunction<
          Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32),
          int Function(int, int, Pointer<Void>, int)
        >('SetInformationJobObject');

    final job = createJob(nullptr, nullptr);
    if (job == 0) return 0;

    final info = calloc<Uint8>(_extendedLimitSize);
    try {
      (info + _limitFlagsOffset).cast<Uint32>().value = _limitKillOnJobClose;
      final ok = setInfo(
        job,
        _jobObjectExtendedLimitInformation,
        info.cast<Void>(),
        _extendedLimitSize,
      );
      if (ok == 0) return 0;
    } finally {
      calloc.free(info);
    }
    return job;
  }
}
