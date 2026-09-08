$ErrorActionPreference = 'Continue'
# Restart pi-supervisord so the plan/140 room-keeper comes up on the new dist.
$procs = Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -like '*dist\bin\supervisord.js*' -or $_.CommandLine -like '*dist/bin/supervisord.js*' }
foreach ($p in $procs) {
  Write-Output ("killing supervisor pid=" + $p.ProcessId)
  Stop-Process -Id $p.ProcessId -Force
}
if (-not $procs) { Write-Output 'no supervisor process found' }
