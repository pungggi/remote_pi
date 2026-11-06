import 'package:app/protocol/protocol.dart' show WireWorktree;

/// Plan/158 — outcome of one consolidated "Clean up session" run.
///
/// The UI toasts/summarizes from these fields instead of guessing: a cleanup
/// can partially succeed (worktree gone, PC drop before the forget), and the
/// user deserves the truth. `ok` means the tile may disappear (PC forgot the
/// room + phone record dropped); `ok:false` keeps everything and [message]
/// says why. [epk]/[roomId] ride along so the batch summary can name tiles.
class SessionCleanupReport {
  final String epk;
  final String roomId;

  /// `true` when the phone record is gone and the PC forgot the room.
  final bool ok;

  /// User-presentable one-liner (success summary or the failure reason).
  final String message;

  /// Step 1 ran (a tracked worktree existed and removal was requested).
  final bool worktreeAttempted;

  /// The PC's own words about the worktree removal (git refusal reason).
  final String? worktreeMessage;

  /// Step 2 — the PC's rooms.json no longer lists this room.
  final bool roomForgotten;

  /// Step 2b — history deletion ran and its outcome (null = not requested).
  final bool? historyRemoved;

  /// The PC's honest note about the history step ("deleted 2 transcript
  /// file(s)" / "kept: transcript files locked (in use?)").
  final String? historyNote;

  const SessionCleanupReport({
    required this.epk,
    required this.roomId,
    required this.ok,
    required this.message,
    this.worktreeAttempted = false,
    this.worktreeMessage,
    this.roomForgotten = false,
    this.historyRemoved,
    this.historyNote,
  });
}

/// Plan/158 — what the "Clean up session…" dialog needs to render one
/// offline tile: the itemized destructive steps with their current state.
/// The dialog shows the worktree row only when [worktree] is non-null
/// (matched at tap time via the tracked-worktree registry).
/// [epk]/[roomId] map a plan row back to its item for the batch flow.
class SessionCleanupPlan {
  final String epk;
  final String roomId;
  final String sessionTitle;
  final WireWorktree? worktree;

  /// The session's linked GitHub ref label (open-PR warning), or null.
  final String? ghRefLabel;
  final bool ghRefOpenPr;

  const SessionCleanupPlan({
    required this.epk,
    required this.roomId,
    required this.sessionTitle,
    this.worktree,
    this.ghRefLabel,
    this.ghRefOpenPr = false,
  });
}

/// Plan/158 — everything the batch sheet needs after tap-time resolution:
/// the cleanable rows (one per offline session with a routed PC) and the
/// PCs that could not be reached (their sessions are skipped, honestly).
class CleanupBatchPrep {
  final List<SessionCleanupPlan> plans;

  /// Nickname/session labels of peers whose registry could not be fetched.
  final List<String> unreachablePeers;

  const CleanupBatchPrep({
    required this.plans,
    required this.unreachablePeers,
  });
}
