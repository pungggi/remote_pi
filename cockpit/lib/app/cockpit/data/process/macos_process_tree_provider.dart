import 'dart:convert';
import 'dart:io';

import 'package:cockpit/app/cockpit/domain/contracts/process_tree_provider.dart';
import 'package:cockpit/app/cockpit/domain/entities/process_snapshot.dart';

typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

class MacosProcessTreeProvider implements ProcessTreeProvider {
  final ProcessRunner _runner;

  MacosProcessTreeProvider({ProcessRunner? runner})
    : _runner = runner ?? Process.run;

  @override
  Future<List<ProcessSnapshot>> getProcessSnapshots({
    required List<int> rootPids,
  }) async {
    if (rootPids.isEmpty) return const [];

    try {
      final result = await _runner('ps', [
        '-eo',
        'pid,ppid,state,tpgid,pgid,command',
      ]);

      if (result.exitCode != 0) return const [];

      return parsePsOutput(result.stdout.toString());
    } catch (_) {
      return const [];
    }
  }

  static List<ProcessSnapshot> parsePsOutput(String rawOutput) {
    final snapshots = <ProcessSnapshot>[];
    final lines = const LineSplitter().convert(rawOutput);

    if (lines.isEmpty) return snapshots;

    // Skip header line
    for (int i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 6) continue;

      final pid = int.tryParse(parts[0]);
      final ppid = int.tryParse(parts[1]);
      if (pid == null || ppid == null) continue;

      final state = parts[2];
      final tpgid = int.tryParse(parts[3]) ?? -1;
      final pgid = int.tryParse(parts[4]) ?? -2;
      final commandParts = parts.sublist(5);

      final isForeground = tpgid > 0 ? (pgid == tpgid) : true;

      snapshots.add(
        ProcessSnapshot(
          pid: pid,
          ppid: ppid,
          executable: commandParts.first,
          argv: commandParts,
          isForeground: isForeground,
          state: state,
        ),
      );
    }

    return snapshots;
  }
}
