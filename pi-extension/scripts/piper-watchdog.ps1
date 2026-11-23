# piper-watchdog.ps1 — Autostart + Heartbeat + Auto-Restart fuer Piper
# Ueberwacht: relay.exe (HTTP /health) + pi-supervisord (named pipe).
# Startet fehlende Prozesse, startet bei $MaxFail gescheiterten Heartbeats neu,
# loggt jeden Zyklus nach watchdog.log (mit groben Cap).
#
# Plan/159 — this is the SHIPPED copy of the host-local watchdog. The live
# script lives at ~/.pi/piper/piper-watchdog.ps1 (started by the Startup
# shortcut "Piper Watchdog"). Copy it there after adjusting the paths below
# to this host. Design rules (learned the hard way, 2026-11-07 incident):
#
#   - RELAY: health-first. A relay we cannot inspect (started elevated, Path
#     unreadable) is still serving — never spawn a duplicate while /health
#     answers. Process visibility is only consulted when health FAILS.
#   - SUPERVISOR: start via `cmd /c node … >> supervisord.log 2>&1` (the
#     VBS quoting — single-quoted PS strings need NO "" escaping). Direct
#     Start-Process -RedirectStandard* silently produced no files here.
#   - ONE start path per machine: keep exactly ONE of {Task Scheduler
#     RemotePiSupervisor, this watchdog} launching the supervisor. The
#     supervisor's single-instance guard covers races, but duplicate
#     launchers double the log noise and the confusion.
#
# Plan/168 — two upgrades:
#   - SUPERVISOR PROBE: real request/response round-trip (`{"op":"status"}`),
#     not connect-only. Windows completes named-pipe connects at the OS
#     level even when the server's event loop is wedged (2026-11-22: the
#     daemon answered nothing for 5.5 h while "connect" kept succeeding).
#   - DEVICE lastSeenAt STALENESS BOUNCE: the device daemon heartbeats
#     rooms.json every 60 s (plan/168 daemon-side tick). If it freezes for
#     $StaleSec the supervisor's own self-heal missed it (this catches the
#     shape where the child's RPC loop still answers get_state while the
#     extension tick is dead). Kill ONLY the device child — the status probe
#     just proved the supervisor alive, and it crash-respawns the child with
#     --continue. Rate-limited so a longer relay outage cannot turn this
#     into a kill loop; a non-running child (plan/159 crash-loop backoff)
#     is never bounced from here.
$ErrorActionPreference = 'Continue'

# ── Config ────────────────────────────────────────────────────────────────
$RelayExe    = 'C:\Users\Alessandro\source\pi\packages\remote_pi\relay\target\release\relay.exe'
$RelayCwd    = 'C:\Users\Alessandro\source\pi\packages\remote_pi\relay'
$SupEntry    = 'C:\Users\Alessandro\source\pi\packages\remote_pi\pi-extension\dist\bin\supervisord.js'
$SupCwd      = 'C:\Users\Alessandro\source\pi\packages\remote_pi\pi-extension'
$HealthUrl   = 'http://127.0.0.1:3000/health'
$IntervalSec = 30      # Heartbeat alle 30 s
$MaxFail     = 3       # nach 3 aufeinanderfolgenden Fails -> Restart
$LogPath     = 'C:\Users\Alessandro\.pi\piper\watchdog.log'
$SupLogPath  = 'C:\Users\Alessandro\.pi\piper\supervisord.log'
$MaxLogBytes = 1MB
# Plan/168 — registry heartbeat + staleness bounce
$RoomsJson        = 'C:\Users\Alessandro\.pi\piper\rooms.json'
$StaleSec         = 300   # daemon heartbeats every 60 s; 5 min = 5 missed ticks
$BounceCooldownSec = 600   # min seconds between supervisor bounces

function Log([string]$msg) {
  $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Add-Content -Path $LogPath -Value $line
  try {
    if ((Get-Item $LogPath).Length -gt $MaxLogBytes) {
      $keep = Get-Content $LogPath -Tail 500
      Set-Content -Path $LogPath -Value $keep
    }
  } catch { }
}

# ── Single-Instance-Guard (Task feuert evtl. mehrfach) ────────────────────
$mutex = New-Object System.Threading.Mutex($false, 'Local\PiperWatchdog')
if (-not $mutex.WaitOne(0)) { exit 0 }

# ── Checks / Starters ─────────────────────────────────────────────────────
function Get-RelayProcess {
  Get-Process relay -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $RelayExe }
}
function Start-Relay {
  Start-Process -FilePath $RelayExe -WorkingDirectory $RelayCwd -WindowStyle Hidden
}
function Test-Relay {
  try {
    $r = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 5
    return ($r.StatusCode -eq 200 -and $r.Content -match 'OK')
  } catch { return $false }
}
function Invoke-SupervisorStatus {
  # Plan/168 — round-trip probe, not connect-only: the OS accepts
  # named-pipe connects even when the server's event loop is wedged
  # (2026-11-22 incident shape). Only a processed `status` reply proves
  # the loop is alive. Framing per control_protocol.ts: one JSON line in,
  # one JSON line out, then close. Returns the parsed reply object, or
  # $null when unreachable / wedged / malformed — callers use it BOTH as
  # the liveness proof AND as the source of the device child pid.
  $user = ($env:USERNAME -replace '[^A-Za-z0-9_.-]', '_')
  $pipeName = "remote-pi-supervisor-$user"
  $client = $null
  try {
    $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    $client.Connect(1500)
    $writer = New-Object System.IO.StreamWriter($client)
    $writer.NewLine = "`n"
    $writer.WriteLine('{"op":"status"}')
    $writer.Flush()
    $reader = New-Object System.IO.StreamReader($client)
    $t = $reader.ReadLineAsync()
    if (-not $t.Wait(3000)) { return $null }  # connected but wedged
    $reply = $t.Result
    if (-not $reply) { return $null }
    $obj = $reply | ConvertFrom-Json
    if ($obj.ok -ne $true) { return $null }
    return $obj
  } catch { return $null }
  finally { if ($client) { try { $client.Close() } catch { } } }
}
function Get-SupervisorProcess {
  # node running dist/bin/supervisord.js — matched by command line, the
  # process name alone (node.exe) is ambiguous on this host.
  Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'supervisord\.js' }
}
function Stop-Supervisor {
  Get-SupervisorProcess | ForEach-Object {
    Log "supervisor: kill node pid=$($_.ProcessId)"
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  }
}
function Get-DeviceAgeSec {
  # Plan/168 — age of the device room's registry heartbeat, $null when
  # unknown (no registry / no entry yet: nothing to judge, never bounce).
  try {
    if (-not (Test-Path $RoomsJson)) { return $null }
    $reg = Get-Content $RoomsJson -Raw -ErrorAction Stop | ConvertFrom-Json
    $dev = $reg.PSObject.Properties['device']
    if (-not $dev -or -not $dev.Value.lastSeenAt) { return $null }
    return (([DateTimeOffset]::Now.ToUnixTimeMilliseconds() - [long]$dev.Value.lastSeenAt) / 1000)
  } catch { return $null }
}
function Start-Supervisor {
  # Same proven pattern as RemotePiSupervisorLauncher.vbs: cmd /c with >>
  # redirection (append, works hidden). Start-Process -RedirectStandardError
  # silently produced no files here, so keep the VBS approach.
  $cmd = 'cmd /c ""C:\Program Files\nodejs\node.exe" "' + $SupEntry + '" >> "' + $SupLogPath + '" 2>&1"'
  Start-Process -FilePath 'cmd.exe' -ArgumentList $cmd -WorkingDirectory $SupCwd -WindowStyle Hidden
}

# ── Loop ──────────────────────────────────────────────────────────────────
$failRelay = 0
$failSup   = 0
$lastBounce = [datetime]::MinValue   # plan/168 — staleness-bounce rate limit
Log "watchdog gestartet (pid=$PID; alle ${IntervalSec}s; restart nach $MaxFail fails)"

while ($true) {
  # ── Relay ──
  # Health-first: a relay we cannot inspect (e.g. started elevated) is still
  # serving; /health is the source of truth. Never spawn duplicates when
  # health is OK. $proc is only used when health has failed.
  $proc = Get-RelayProcess
  $relayOk = Test-Relay
  if ($relayOk) {
    $failRelay = 0
  }
  elseif (-not $proc) {
    Log 'relay: unhealthy + Prozess fehlt -> starte'
    Start-Relay
    Start-Sleep -Seconds 3
    $failRelay = 0
  }
  else {
    $failRelay++
    Log "relay: heartbeat FAIL ($failRelay/$MaxFail)"
    if ($failRelay -ge $MaxFail) {
      Log "relay: $MaxFail fails -> kill + restart"
      Get-RelayProcess | Stop-Process -Force
      Start-Sleep -Seconds 1
      Start-Relay
      Start-Sleep -Seconds 3
      if (Test-Relay) { Log 'relay: wieder OK'; $failRelay = 0 }
      else { Log 'relay: restart NICHT gesund (naechster Zyklus retry)' }
    }
  }

  # ── pi-supervisord ──
  $supStatus = Invoke-SupervisorStatus
  $supOk = ($null -ne $supStatus)
  $devicePid = $null
  if ($supOk -and $supStatus.data -and $supStatus.data.daemons) {
    $dev = @($supStatus.data.daemons) | Where-Object { $_.id -eq 'device' } | Select-Object -First 1
    if ($dev -and $dev.state -eq 'running' -and $dev.pid) { $devicePid = [int]$dev.pid }
  }
  if ($supOk) {
    $failSup = 0
  }
  else {
    $failSup++
    Log "supervisor: pipe/antwort FAIL ($failSup/$MaxFail)"
    if ($failSup -ge $MaxFail) {
      # Plan/168 — kill first when the process exists but is wedged: the
      # single-instance guard would make a plain Start-Supervisor exit
      # immediately and the wedge would never heal.
      if (Get-SupervisorProcess) {
        Log 'supervisor: Prozess da, aber wedged -> kill + restart (plan/168)'
        Stop-Supervisor
        Start-Sleep -Seconds 2
      } else {
        Log 'supervisor: Prozess fehlt -> starte'
      }
      Start-Supervisor
      Start-Sleep -Seconds 3
      $failSup = 0
      $lastBounce = Get-Date   # fresh daemon needs time to connect + heartbeat
    }
  }

  # ── Device-Heartbeat-Staleness (plan/168) ──
  # Outer belt for the shape the supervisor ping loop CANNOT see: the
  # child's RPC loop still answers get_state while the extension tick
  # (registry heartbeat) is frozen. Kill ONLY the device child — the
  # supervisor crash-respawns it with --continue. Never bounce a
  # non-running child (plan/159 crash-loop backoff owns that state),
  # never kill faster than $BounceCooldownSec. Silent while suppressed:
  # the heartbeat line below carries device_age every cycle.
  $devAge = Get-DeviceAgeSec
  if ($null -ne $devAge -and $devAge -ge $StaleSec -and $devicePid) {
    if (((Get-Date) - $lastBounce).TotalSeconds -ge $BounceCooldownSec) {
      Log ('device: lastSeenAt stale ({0:n0}s >= {1}s) -> kill child pid={2}, supervisor respawns (plan/168)' -f $devAge, $StaleSec, $devicePid)
      Stop-Process -Id $devicePid -Force -ErrorAction SilentlyContinue
      $lastBounce = Get-Date
    }
  }

  # ── Heartbeat-Statuszeile ──
  $relayPid = ($proc | Select-Object -First 1).Id
  $devAgeTxt = if ($null -ne $devAge) { '{0:n0}s' -f $devAge } else { 'n/a' }
  Log ("heartbeat relay={0} pid={1} supervisor={2} device_age={3}" -f `
    $(if ($relayOk) { 'OK' } else { 'FAIL' }), $relayPid, `
    $(if ($supOk) { 'OK' } else { 'FAIL' }), $devAgeTxt)

  Start-Sleep -Seconds $IntervalSec
}
