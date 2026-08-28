## 1.0.7

* **Fix UI freeze on Windows when writing to a stalled terminal** — `pty_write`
  is a synchronous FFI call on the Flutter platform (UI) thread, and the Windows
  backend called `FlushFileBuffers` on the ConPTY input pipe after every write.
  On a pipe, `FlushFileBuffers` blocks until the *other end consumes everything
  written* — so a child that stopped draining stdin (suspended process, busy
  shell) froze the entire window indefinitely ("Not responding"; confirmed by
  minidump in production, inherited from kyroon_pty). The flush is removed: it
  was semantically wrong for pipes and unnecessary (`WriteFile` already hands
  the data to the pipe). This was the only `FlushFileBuffers` call site in the
  plugin.
* **Non-blocking terminal input on Windows** — `WriteFile` itself can also block
  the UI thread when the pipe buffer fills (e.g. a large paste into a suspended
  shell) — same bug class, rarer trigger. Writes now go through a per-PTY writer
  thread with a FIFO queue: `pty_write` only copies the buffer, enqueues and
  signals. Anonymous pipes don't support overlapped I/O, so a writer thread is
  the canonical fix. If the pipe breaks (child/ConPTY gone) the thread drains
  the queue and exits; later writes are discarded. POSIX backends (`forkpty`)
  are untouched — they never had the flush. The Windows-only repro harness
  that proved the hang (old `FlushFileBuffers` blocks; new `pty_write` does
  not) lives in `test/windows/`.

## 1.0.6

* Absorbed into the Cockpit monorepo as an internal plugin
  (`plugins/cockpit_pty`), renamed from `kyroon_pty`; not published.
* **Fix blank/PSReadLine-less PowerShell in GUI builds** — the
  `STARTF_USESTDHANDLES` + NULL std handles hack is now applied only when the
  host process owns a real console (e.g. `flutter run`). In GUI builds it made
  console programs see their stdio as redirected, so PowerShell disabled
  PSReadLine; the plain ConPTY attribute path is used instead.

## 1.0.5

* **Fix PTY spawn failure on Windows ARM64** — `build_working_directory` copied
  the path with `block[i] = src[i++]`, which reads and modifies `i` with no
  sequence point between the two uses (undefined behavior). MSVC's ARM64 backend
  can evaluate it differently than x64/clang and corrupt the working-directory
  string, so `CreateProcessW` failed with "Failed to create process" whenever a
  `workingDirectory` was passed. The increment is now its own statement, matching
  `build_command`/`build_environment`. Callers that pass no `workingDirectory`
  were never affected.
* **Surface the real Win32 error** — on a `CreateProcessW` failure the error now
  includes `GetLastError` plus the executable and working directory, so the cause
  reaches the Dart exception instead of a `printf` the GUI swallows.

## 1.0.4

* **Inherit the full environment by default** — `Pty.start` now passes the whole
  parent environment to the child instead of a small allow-list
  (`PATH`/`HOME`/`USER`/…). On Windows the old behavior dropped
  `SystemRoot`/`APPDATA`/`USERPROFILE`/`TEMP`, which made Node/Bun-based CLIs
  (e.g. `claude`) fail to start silently — the terminal stayed blank even though
  shells worked. `TERM`/`LANG` are still defaulted when the parent doesn't set
  them, and anything passed via `environment:` still overrides. Callers that
  already passed `Map.from(Platform.environment)` (like the example) are
  unaffected.

## 1.0.3

* **Fix blank Windows terminal (regression from 1.0.2)** — 1.0.2 dropped the
  `STARTF_USESTDHANDLES` setup, which made the child process inherit the host's
  real console (or none) instead of attaching to the pseudoconsole. Shells like
  `cmd`, PowerShell and bash then produced no output and accepted no input — the
  terminal view stayed black. The child's inherited std handles are cleared
  again (verified against `cmd` both under `flutter run` and as a built app), so
  console programs route all I/O through the ConPTY as before.
* **Proper ConPTY handle cleanup** — the parent now closes its copies of the
  pipe ends duplicated into conhost (`inputReadSide` / `outputWriteSide`), frees
  the proc-thread attribute list (`DeleteProcThreadAttributeList`) and closes the
  process's thread handle. Without closing `outputWriteSide` the read loop never
  saw EOF on child exit.

## 1.0.2

* **Windows ConPTY stdin change (superseded by 1.0.3)** — stopped setting
  `STARTF_USESTDHANDLES` with NULL handles. This regressed plain shells (blank
  terminal) and is reverted in 1.0.3; avoid 1.0.2 on Windows.

## 1.0.1

Example app improvements (the plugin API in `lib/` is unchanged):

* **Input events** — `PtySession.onInput` (`Stream<String>`) fires when input is
  sent to the process. Live typing is buffered and emitted once per committed
  line (on Enter); the command bar emits the whole command at once. Useful for
  activity tracking, audit logs or idle-timer resets.

  ```dart
  session.onInput.listen((line) => print('input: $line'));
  ```

* **CLI idle detection** — `PtySession.onIdle` (`Stream<TerminalIdleEvent>`)
  fires when the process stops producing output after a burst of activity — a
  heuristic for "the CLI (claude/codex/qwen/…) finished and is idle". Tunable
  via `session.idleThreshold` (default 1.5s) and an optional
  `session.idleReadyPattern` (a `RegExp` matched against recent output so a long
  *silent* task doesn't look idle until its prompt returns). A reactive
  `session.busy` drives the RUNNING/IDLE status badge.

  ```dart
  session.idleThreshold = const Duration(milliseconds: 1200);
  session.idleReadyPattern = RegExp(r'\$ $'); // fire only when the prompt is back
  session.onIdle.listen((e) => print('idle after ${e.busyFor.inMilliseconds}ms'));
  ```

* **Accented input in the terminal** — dead-key composition (´ ` ^ ~ ¨ + letter →
  á ã ê ç ü …) for typing directly into the PTY on desktop, where the IME path
  is unavailable on Windows.

* **Ctrl+Enter / Shift+Enter** — send a newline (LF) instead of submitting (CR),
  matching how CLIs like Claude/readline insert a line break.

* **Command bar ⇄ direct-PTY toggle** — switch between typing through the input
  bar and typing straight into the terminal.

* **WebSocket host input event** — `PtyWebSocketServer.onInput`
  (`Stream<Uint8List>`) notifies the host when a remote client sends input.

## 1.0.0

* First stable release of `cockpit_pty`.
* Native PTY implementation: `forkpty` on Linux/macOS/Android and ConPTY on
  Windows (Windows 10 1809+).
* Spawn a child process attached to a pseudo-terminal with full support for
  line editing, ANSI colors, cursor control, job control and resize.
* Core API: `Pty.start`, `output` stream, `write`, `resize`, `kill`,
  `exitCode`, `pid` and optional read acknowledgement (`ackRead`) for
  backpressure.
* Configurable working directory and environment variables.
* Designed to pair with [`xterm`](https://pub.dev/packages/xterm) for a fully
  interactive terminal widget.
* Example app with tabbed local terminals, pluggable backends (local PTY vs.
  remote stream) and a batteries-included WebSocket transport + server for
  remote/web terminals.
