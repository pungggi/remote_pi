import 'package:cockpit/app/cockpit/domain/contracts/git_command_runner.dart';
import 'package:cockpit/app/cockpit/domain/contracts/git_status_reader.dart';
import 'package:cockpit/app/cockpit/domain/entities/git_info.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/git_controller.dart';
import 'package:cockpit/app/core/ui/window_activity_controller.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reader nulo — nenhuma pasta é repo git; o poll roda mas `refresh` é no-op.
class _NullReader implements GitStatusReader {
  @override
  Future<GitInfo?> read(String path) async => null;
}

class _CountingReader implements GitStatusReader {
  var reads = 0;

  @override
  Future<GitInfo?> read(String path) async {
    reads++;
    return null;
  }
}

/// Runner que nunca é exercido neste teste (o poll só lê estado).
class _UnusedRunner implements GitCommandRunner {
  @override
  GitRun run(String repoPath, List<String> args) => throw UnimplementedError();
  @override
  GitRun syncPullPush(String repoPath) => throw UnimplementedError();
  @override
  GitMergeOutcome mergeIntoParent(
    String parentPath,
    String worktreePath,
    String worktreeBranch,
  ) => throw UnimplementedError();
}

void main() {
  test('startPoll dispara onPoll a cada tick (reconciliação de worktrees)', () {
    fakeAsync((async) {
      final activity = WindowActivityController();
      final git = GitController(_NullReader(), _UnusedRunner(), activity)
        // Sem alvos de status: isola o teste no gancho onPoll.
        ..pollTargets = (() => const <String>[]);

      var ticks = 0;
      git.onPoll = () => ticks++;

      git.startPoll();
      expect(ticks, 0, reason: 'nada dispara antes do primeiro intervalo');

      // 3 intervalos de 3s = 3 ticks.
      async.elapse(const Duration(seconds: 9));
      expect(ticks, 3);

      git.dispose();
      activity.dispose();
      // Após dispose o timer para → nenhum tick novo.
      async.elapse(const Duration(seconds: 9));
      expect(ticks, 3, reason: 'dispose cancela o poll');
    });
  });

  test('inactivity pauses poll and repeated resume events reconcile once', () {
    fakeAsync((async) {
      final activity = WindowActivityController();
      final reader = _CountingReader();
      final git = GitController(reader, _UnusedRunner(), activity)
        ..resolvePath = ((_) => '/repo')
        ..pollTargets = (() => const <String>['repo']);
      var reconciliations = 0;
      git.onPoll = () => reconciliations++;
      git.startPoll();

      activity
        ..blur()
        ..minimize();
      async.elapse(const Duration(seconds: 9));
      expect(reconciliations, 0, reason: 'Git ticks during inactivity = 0');
      expect(reader.reads, 0, reason: 'Git reads during inactivity = 0');

      activity
        ..focus()
        ..focus()
        ..restore()
        ..restore();
      expect(
        reconciliations,
        1,
        reason: 'reconciliations for one resume cycle = 1',
      );
      expect(reader.reads, 1, reason: 'one Git read for one resume cycle');
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();
      expect(reconciliations, 2, reason: 'one periodic timer was rearmed');
      expect(reader.reads, 2, reason: 'one periodic Git read was rearmed');

      git.dispose();
      activity.dispose();
    });
  });
}
