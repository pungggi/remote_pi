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
function Test-Supervisor {
  # Liveness by CONNECT, not by directory listing: GetFiles can serve stale
  # names after the server died (2026-11-07: watchdog reported supervisor=OK
  # for cycles while the CLI got no answer). A successful connect means a
  # listener is actually accepting - mirrors the node code's _probeSupervisor.
  $user = ($env:USERNAME -replace '[^A-Za-z0-9_.-]', '_')
  $pipeName = "remote-pi-supervisor-$user"
  try {
    $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    $client.Connect(500)
    $alive = $client.IsConnected
    $client.Close()
    return $alive
  } catch { return $false }
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
Log "watchdog gestartet (pid=$PID; alle ${IntervalSec}s; restart nach $MaxFail fails)"

while ($true) {
  # ── Relay ──
  # Health-first: a relay we cannot inspect (e.g. started elevated) is still
  # serving; /health is the source of truth. Never spawn duplicates when
  # health is OK. $proc is only used when health has failed.
  $proc = Get-RelayProcess
  if (Test-Relay) {
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
  if (Test-Supervisor) {
    $failSup = 0
  }
  else {
    $failSup++
    Log "supervisor: pipe fehlt ($failSup/$MaxFail)"
    if ($failSup -ge $MaxFail) {
      Log 'supervisor: -> starte pi-supervisord'
      Start-Supervisor
      Start-Sleep -Seconds 3
      $failSup = 0
    }
  }

  # ── Heartbeat-Statuszeile ──
  $relayState = if (Test-Relay) { 'OK' } else { 'FAIL' }
  $relayPid   = (Get-RelayProcess | Select-Object -First 1).Id
  $supState   = if (Test-Supervisor) { 'OK' } else { 'FAIL' }
  Log "heartbeat relay=$relayState pid=$relayPid supervisor=$supState"

  Start-Sleep -Seconds $IntervalSec
}
