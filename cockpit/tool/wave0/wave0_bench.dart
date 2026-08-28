// Wave 0 (plano 58) — benchmark do gate de latência:
// eco de keystroke via `cat` em PTY, caminho FFI direto (NativeTerminalService
// in-process) vs caminho loopback (cockpit-server + UDS + JSONL/base64).
// Orçamento do plano: acréscimo < 1ms no p50.
//
// Também mede throughput de despejo (yes | head) nos dois caminhos.
//
// Uso (da pasta cockpit/):
//   ./tool/wave0/build_pty_dylib.sh
//   (cd tool/wave0 && dart pub get)
//   dart run tool/wave0/wave0_bench.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cockpit_core/cockpit_core.dart';
import 'package:cockpit_engine/cockpit_engine.dart';
import 'package:cockpit_remote/cockpit_remote.dart';

const _iterations = 300;
const _dumpBytes = 32 * 1024 * 1024;

Future<void> main() async {
  final repoRoot = _cockpitRoot();
  final dylib = '$repoRoot/build/wave0/libcockpit_pty.dylib';

  stdout.writeln('== FFI direto (in-process) ==');
  final native = NativeTerminalService();
  final ffiEcho = await _echoLatency(native);
  final ffiDump = await _dumpThroughput(native);
  await native.dispose();

  stdout.writeln('== loopback (cockpit-server via UDS) ==');
  final socketPath =
      '${Directory.systemTemp.path}/wave0-bench-${DateTime.now().millisecondsSinceEpoch}.sock';
  final server = await Process.start(
    'dart',
    [
      'run',
      'packages/cockpit_server/bin/cockpit_server.dart',
      '--socket',
      socketPath,
    ],
    workingDirectory: repoRoot,
    environment: {...Platform.environment, 'COCKPIT_PTY_DYLIB': dylib},
  );
  await server.stdout
      .transform(utf8.decoder)
      .firstWhere((line) => line.contains('listening'));

  final connection = await RemoteConnection.connect(socketPath);
  final remote = RemoteTerminalService(connection);
  final remoteEcho = await _echoLatency(remote);
  final remoteDump = await _dumpThroughput(remote);
  await connection.close();
  server.kill();

  stdout.writeln('\n== resultado ==');
  _report('echo p50', ffiEcho.p50, remoteEcho.p50);
  _report('echo p95', ffiEcho.p95, remoteEcho.p95);
  final delta = remoteEcho.p50 - ffiEcho.p50;
  stdout.writeln(
    'acréscimo p50 do loopback: ${delta.toStringAsFixed(3)} ms '
    '(orçamento: < 1.000 ms) → ${delta < 1.0 ? 'PASS' : 'FAIL'}',
  );
  stdout.writeln(
    'dump 32MiB: ffi ${ffiDump.toStringAsFixed(0)} MiB/s, '
    'loopback ${remoteDump.toStringAsFixed(0)} MiB/s',
  );
  if (delta >= 1.0) exit(1);
}

class _Latency {
  _Latency(List<double> samplesMs) {
    samplesMs.sort();
    p50 = samplesMs[samplesMs.length ~/ 2];
    p95 = samplesMs[(samplesMs.length * 95) ~/ 100];
  }
  late final double p50;
  late final double p95;
}

/// Mede o RTT de 1 byte: escreve um byte no `cat` e espera ele voltar.
Future<_Latency> _echoLatency(TerminalService terminals) async {
  final info = await terminals.open(const PtySpawnSpec(executable: '/bin/cat'));
  var received = 0;
  Completer<void> pending = Completer();
  final sub = terminals.attach(info.id).listen((event) {
    if (event is PtyOutputEvent) {
      received += event.chunk.bytes.length;
      if (!pending.isCompleted) pending.complete();
    }
  });

  final samples = <double>[];
  final payload = Uint8List.fromList([0x78]); // 'x'
  final watch = Stopwatch();
  for (var i = 0; i < _iterations; i++) {
    final before = received;
    pending = Completer();
    watch
      ..reset()
      ..start();
    await terminals.write(info.id, payload);
    while (received <= before) {
      await pending.future;
      if (received <= before) pending = Completer();
    }
    watch.stop();
    samples.add(watch.elapsedMicroseconds / 1000.0);
  }

  await sub.cancel();
  await terminals.kill(info.id);
  final result = _Latency(samples);
  stdout.writeln(
    '  echo p50 ${result.p50.toStringAsFixed(3)} ms, '
    'p95 ${result.p95.toStringAsFixed(3)} ms (n=$_iterations)',
  );
  return result;
}

/// Mede MiB/s de um despejo grande (head -c N /dev/zero via sh).
Future<double> _dumpThroughput(TerminalService terminals) async {
  final info = await terminals.open(
    PtySpawnSpec(
      executable: '/bin/sh',
      arguments: ['-c', 'head -c $_dumpBytes /dev/zero; echo DONE-MARKER'],
    ),
  );
  var received = 0;
  final done = Completer<void>();
  final sub = terminals.attach(info.id).listen((event) {
    if (event is PtyOutputEvent) {
      received += event.chunk.bytes.length;
      if (!done.isCompleted && received >= _dumpBytes) {
        done.complete();
      }
    }
  });

  final watch = Stopwatch()..start();
  await done.future.timeout(const Duration(seconds: 120));
  watch.stop();
  await sub.cancel();
  await terminals.kill(info.id);
  final mibPerSecond =
      (_dumpBytes / (1024 * 1024)) / (watch.elapsedMicroseconds / 1e6);
  stdout.writeln('  dump ${mibPerSecond.toStringAsFixed(0)} MiB/s');
  return mibPerSecond;
}

void _report(String label, double ffi, double remote) {
  stdout.writeln(
    '$label: ffi ${ffi.toStringAsFixed(3)} ms · '
    'loopback ${remote.toStringAsFixed(3)} ms',
  );
}

String _cockpitRoot() {
  var dir = Directory.current;
  while (!Directory('${dir.path}/packages/cockpit_server').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('run from cockpit/');
    dir = parent;
  }
  return dir.path;
}
