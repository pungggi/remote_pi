import 'package:cockpit/app/cockpit/domain/entities/process_snapshot.dart';

abstract class ProcessTreeProvider {
  /// Acquires a snapshot of processes relevant to [rootPids].
  Future<List<ProcessSnapshot>> getProcessSnapshots({
    required List<int> rootPids,
  });
}
