// Names the process serving a Windows named pipe (fork addition to upstream
// PR #124's /proc-based diagnosis; see socket_owner.ts).
//
// Windows has no /proc to walk, but the kernel can answer the question
// directly: open a short-lived client handle to the pipe and call
// GetNamedPipeServerProcessId. Both halves are answered by the kernel even
// when the owning process is suspended or its event loop is blocked — which is
// exactly the case being diagnosed; a user-mode query would hang with it.
//
// Node exposes no binding for GetNamedPipeServerProcessId, and Windows
// PowerShell 5.1 (.NET Framework) does not expose it on NamedPipeClientStream
// either, so the query rides a `powershell.exe -NoProfile` child that P/Invokes
// kernel32 via Add-Type. That costs one process spawn plus one csc compile
// (~0.5 s measured), which is why the Windows budget is larger than the /proc
// walk's; see WIN_OWNER_LOOKUP_BUDGET_MS.
//
// Unlike the Linux path (pure reads), this probe is observable: it queues one
// more connection in the server's backlog. The handle is closed immediately
// after the query, so a server that later accepts sees an already-closed pipe
// and moves on — a transient, bounded side effect, weighed against leaving the
// operator to guess which process is holding the mesh hostage.
//
// Classification stays evidence-based:
//   - all threads in Wait/Suspended  → halted (resumable)
//   - pid named but Get-Process finds nothing → exited
//   - anything else → active ("may be busy", no action prescribed)
// Thread details can be unreadable for elevated processes; unreadable is not
// proof of suspension, so it classifies as active.
import { spawn, type ChildProcess } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";
import type { OwnerLiveness, SocketOwner } from "./socket_owner.js";

/**
 * Ceiling on the Windows diagnosis. The Linux walk reads tables it already
 * owns in 250 ms; this route pays a powershell.exe spawn plus an Add-Type
 * compile (~0.5 s measured, but not bounded on a loaded machine), so the
 * ceiling absorbs that without letting a wedged child stall the error report.
 */
export const WIN_OWNER_LOOKUP_BUDGET_MS = 2_000;

/**
 * The full pipe address (`\\.\pipe\…`) goes in an environment variable, not
 * the command line: pipe names contain backslashes and dots, and an env var
 * is immune to every layer of quoting between here and $env:.
 */
const ENV_PIPE_NAME = "REMOTE_PI_DIAG_PIPE";

const PS_SCRIPT = `
$full = $env:REMOTE_PI_DIAG_PIPE
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RemotePiPipeOwner {
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool GetNamedPipeServerProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool CloseHandle(IntPtr h);
  public static uint Query(string fullPipePath) {
    IntPtr h = CreateFile(fullPipePath, 0xC0000000u, 0u, IntPtr.Zero, 3u, 0u, IntPtr.Zero);
    if (h == new IntPtr(-1)) throw new Exception("CreateFile failed: " + Marshal.GetLastWin32Error());
    try {
      uint pid;
      if (!GetNamedPipeServerProcessId(h, out pid)) throw new Exception("GetNamedPipeServerProcessId failed: " + Marshal.GetLastWin32Error());
      return pid;
    } finally { CloseHandle(h); }
  }
}
'@
try {
  $serverPid = [RemotePiPipeOwner]::Query($full)
  $proc = Get-Process -Id $serverPid -ErrorAction SilentlyContinue
  if ($null -eq $proc) {
    @{ pid = $serverPid; command = ''; state = 'not running'; liveness = 'exited' } | ConvertTo-Json -Compress
    exit 0
  }
  $suspended = $false
  try {
    $threads = @($proc.Threads)
    if ($threads.Count -gt 0) {
      $suspended = $true
      foreach ($t in $threads) {
        if ($t.ThreadState -ne 'Wait' -or $t.WaitReason -ne 'Suspended') { $suspended = $false; break }
      }
    }
  } catch { $suspended = $false }
  $cmd = ''
  try { if ($proc.Path) { $cmd = [System.IO.Path]::GetFileName($proc.Path) } } catch { }
  if ($cmd -eq '') { $cmd = $proc.Name }
  if ($suspended) {
    @{ pid = $serverPid; command = $cmd; state = 'suspended'; liveness = 'halted' } | ConvertTo-Json -Compress
  } else {
    @{ pid = $serverPid; command = $cmd; state = 'running'; liveness = 'active' } | ConvertTo-Json -Compress
  }
} catch {
  # No listening instance completed the connect, or the kernel query was
  # refused: the owner cannot be named from here.
  exit 1
}
`;

function parseOwnerLine(line: string): SocketOwner | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null) return null;
  const o = parsed as Record<string, unknown>;
  const liveness = o["liveness"];
  if (typeof o["pid"] !== "number" || typeof o["command"] !== "string"
    || typeof o["state"] !== "string"
    || (liveness !== "halted" && liveness !== "exited" && liveness !== "active")) {
    return null;
  }
  return {
    pid: o["pid"],
    command: o["command"],
    state: o["state"],
    liveness: liveness as OwnerLiveness,
  };
}

/**
 * Resolves the process serving the named pipe at `sockPath`, or null when it
 * cannot be determined within `budgetMs`. Never throws — a failed diagnosis
 * must degrade to the generic message, not surface a second error.
 */
export async function describeWindowsPipeOwner(
  sockPath: string,
  budgetMs: number,
): Promise<SocketOwner | null> {
  let child: ChildProcess;
  try {
    child = spawn(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", PS_SCRIPT],
      {
        env: { ...process.env, [ENV_PIPE_NAME]: sockPath },
        windowsHide: true,
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
  } catch {
    return null;
  }
  // Neither the child nor its pipes may hold the host process open; a pending
  // diagnosis is never a reason for pi to linger. (`Readable` doesn't declare
  // unref in the stream typings, hence the structural cast.)
  child.unref();
  (child.stdout as { unref?: () => void } | null)?.unref?.();
  (child.stderr as { unref?: () => void } | null)?.unref?.();

  const query = new Promise<SocketOwner | null>((resolve) => {
    let out = "";
    child.stdout?.on("data", (chunk: Buffer) => { out += chunk.toString("utf8"); });
    child.once("error", () => resolve(null));
    child.once("close", () => {
      const lines = out.trim().split(/\r?\n/).filter((l) => l !== "");
      resolve(lines.length > 0 ? parseOwnerLine(lines[lines.length - 1]!) : null);
    });
  });
  const expired = delay(budgetMs, null, { ref: false });
  const answer = await Promise.race([query, expired]);
  // Losing the race must not leave a powershell.exe behind (a wedged child
  // would outlive the very error it was spawned to explain).
  if (answer === null && child.exitCode === null) child.kill();
  return answer;
}
