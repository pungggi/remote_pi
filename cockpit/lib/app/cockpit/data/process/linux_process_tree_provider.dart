import 'dart:collection';
import 'dart:io';

import 'package:cockpit/app/cockpit/domain/contracts/process_tree_provider.dart';
import 'package:cockpit/app/cockpit/domain/entities/process_snapshot.dart';

class LinuxProcessTreeProvider implements ProcessTreeProvider {
  final Directory procDir;

  LinuxProcessTreeProvider({Directory? procDir})
    : procDir = procDir ?? Directory('/proc');

  @override
  Future<List<ProcessSnapshot>> getProcessSnapshots({
    required List<int> rootPids,
  }) async {
    if (rootPids.isEmpty) return const [];

    try {
      if (!await procDir.exists()) return const [];

      // Prefer walking only the PTY trees via /proc/<pid>/task/<pid>/children.
      // Full /proc enumeration is reserved for kernels without that file —
      // never mix the two: a children-less walk would return only the roots.
      int? probePid;
      for (final pid in rootPids) {
        if (await File('${procDir.path}/$pid/stat').exists()) {
          probePid = pid;
          break;
        }
      }
      if (probePid == null) return const [];

      if (await _childrenApiAvailable(probePid)) {
        return _collectTrees(rootPids);
      }
      return _collectByFullScan(rootPids);
    } catch (_) {
      return const [];
    }
  }

  Future<bool> _childrenApiAvailable(int samplePid) async {
    final file = File('${procDir.path}/$samplePid/task/$samplePid/children');
    return file.exists();
  }

  Future<List<ProcessSnapshot>> _collectTrees(List<int> rootPids) async {
    final snapshots = <ProcessSnapshot>[];
    final seen = <int>{};
    final queue = Queue<int>.from(rootPids);

    while (queue.isNotEmpty) {
      final pid = queue.removeFirst();
      if (!seen.add(pid)) continue;

      final snapshot = await _readProcess('${procDir.path}/$pid', pid);
      if (snapshot == null) continue;

      snapshots.add(snapshot);
      for (final child in await _readChildren(pid)) {
        if (!seen.contains(child)) queue.add(child);
      }
    }

    return snapshots;
  }

  Future<List<int>> _readChildren(int pid) async {
    try {
      final file = File('${procDir.path}/$pid/task/$pid/children');
      if (!await file.exists()) return const [];
      final text = await file.readAsString();
      if (text.trim().isEmpty) return const [];
      return text
          .trim()
          .split(RegExp(r'\s+'))
          .map(int.tryParse)
          .whereType<int>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// Fallback when `children` is unavailable: one /proc pass, then filter to
  /// the descendant closure of [rootPids].
  Future<List<ProcessSnapshot>> _collectByFullScan(List<int> rootPids) async {
    final all = <ProcessSnapshot>[];
    final entities = await procDir.list().toList();
    for (final entity in entities) {
      if (entity is! Directory) continue;
      final pidName = entity.path.split('/').last;
      final pid = int.tryParse(pidName);
      if (pid == null) continue;
      final snapshot = await _readProcess(entity.path, pid);
      if (snapshot != null) all.add(snapshot);
    }

    if (all.isEmpty) return const [];

    final byParent = <int, List<int>>{};
    final byPid = <int, ProcessSnapshot>{};
    for (final s in all) {
      byPid[s.pid] = s;
      byParent.putIfAbsent(s.ppid, () => []).add(s.pid);
    }

    final keep = <int>{};
    final queue = Queue<int>.from(rootPids);
    while (queue.isNotEmpty) {
      final pid = queue.removeFirst();
      if (!keep.add(pid)) continue;
      for (final child in byParent[pid] ?? const <int>[]) {
        queue.add(child);
      }
    }

    return [
      for (final pid in keep)
        if (byPid[pid] != null) byPid[pid]!,
    ];
  }

  Future<ProcessSnapshot?> _readProcess(String path, int pid) async {
    try {
      final statFile = File('$path/stat');
      if (!await statFile.exists()) return null;

      final statContent = await statFile.readAsString();
      // Format: pid (comm) state ppid pgrp session tty_nr tpgid ...
      final lastParen = statContent.lastIndexOf(')');
      if (lastParen == -1) return null;

      final comm = statContent.substring(
        statContent.indexOf('(') + 1,
        lastParen,
      );
      final rest = statContent
          .substring(lastParen + 2)
          .trim()
          .split(RegExp(r'\s+'));

      if (rest.length < 6) return null;

      final state = rest[0];
      final ppid = int.tryParse(rest[1]) ?? 0;
      final pgrp = int.tryParse(rest[2]) ?? 0;
      final tpgid = int.tryParse(rest[5]) ?? -1;

      final cmdlineFile = File('$path/cmdline');
      List<String> argv = [comm];
      if (await cmdlineFile.exists()) {
        final bytes = await cmdlineFile.readAsBytes();
        if (bytes.isNotEmpty) {
          final parts = String.fromCharCodes(
            bytes,
          ).split('\x00').where((s) => s.isNotEmpty).toList();
          if (parts.isNotEmpty) {
            argv = parts;
          }
        }
      }

      final isForeground = tpgid > 0 ? (pgrp == tpgid) : true;

      return ProcessSnapshot(
        pid: pid,
        ppid: ppid,
        executable: argv.first,
        argv: argv,
        isForeground: isForeground,
        state: state,
      );
    } catch (_) {
      return null;
    }
  }
}
