# Swap the relay binary safely: pause watchdog -> kill relay -> caller builds
# -> restart. Usage: -Mode pause|resume
param([Parameter(Mandatory=$true)][ValidateSet('pause','resume')][string]$Mode)
$wd = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -match 'piper-watchdog' }
if ($Mode -eq 'pause') {
  foreach ($p in $wd) { "stopping watchdog pid=$($p.ProcessId)"; Stop-Process -Id $p.ProcessId -Force }
  schtasks /End /TN "Piper Relay" | Out-Null
  Get-Process relay -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep 2
  if (Get-Process relay -ErrorAction SilentlyContinue) { "relay STILL ALIVE"; exit 1 } else { "relay dead, watchdog paused" }
} else {
  schtasks /Run /TN "Piper Relay" | Out-Null
  Start-Sleep 3
  Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Users\Alessandro\.pi\piper\piper-watchdog.ps1"'
  Start-Sleep 2
  $h = (Invoke-WebRequest -Uri 'http://127.0.0.1:3000/health' -UseBasicParsing -TimeoutSec 5).Content
  $wd2 = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'piper-watchdog' }
  "health=$h watchdog_pids=$($wd2.ProcessId -join ',')"
}
