# Windows PTY write-freeze harness

Standalone C program used to **reproduce and validate** the Windows-only UI
freeze (plan 58). It is **not** part of `flutter test`.

It `#include`s the real `src/cockpit_pty_win.c` and runs three cases:

| # | What | Expected |
|---|---|---|
| T1 | `pty_write("echo …")` into a live ConPTY | optional integrity check — the standalone ConPTY here does not echo `cmd` (same WARN as the 2026-08-13 run); not the freeze proof |
| T2 | Old semantics (`WriteFile` + `FlushFileBuffers`) with `conhost` suspended via `NtSuspendProcess` | **blocks** (the production hang) |
| T3 | New `pty_write` under the same suspended consumer | 500×4KB returns immediately (worst call ≪ 50 ms) |

macOS/Linux have no equivalent: their `forkpty` backends never called
`FlushFileBuffers`.

## Run

Needs Visual Studio Build Tools (MSVC) and Windows 10 1809+ (ConPTY).

```powershell
# from this directory, or from the plugin root:
powershell -File test/windows/build.ps1
```

The script locates `vcvars64.bat`, compiles against `src/cockpit_pty_win.c`,
and runs the exe. Exit 0 = all executed cases passed (T2/T3 skip if
`NtSuspendProcess` cannot open the spawned `conhost`).

## What this is not

- A Dart unit test. Flutter's test runner cannot call `NtSuspendProcess` on
  the ConPTY host of a live tab.
- A throughput benchmark. The +14% vs Windows Terminal number in plan 58 was
  a **manual** 20k-line dump in the real 1.26.1 app, not this harness.
