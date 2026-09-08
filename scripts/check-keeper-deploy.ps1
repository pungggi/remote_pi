$ErrorActionPreference = 'Continue'
Write-Output '=== node procs (start times) ==='
Get-CimInstance Win32_Process -Filter "Name='node.exe'" | ForEach-Object {
  $cl = $_.CommandLine
  if ($cl -and ($cl -match 'supervisord|pi-coding-agent')) {
    if ($cl.Length -gt 120) { $cl = $cl.Substring(0,120) + '...' }
    Write-Output ($_.CreationDate.ToString('HH:mm:ss') + '  pid=' + $_.ProcessId + '  ' + $cl)
  }
}
Write-Output '=== supervisord.log raw tail ==='
Get-Content (Join-Path $env:USERPROFILE '.pi\piper\supervisord.log') -Tail 6
Write-Output '=== supervisord.err.log tail ==='
Get-Content (Join-Path $env:USERPROFILE '.pi\piper\supervisord.err.log') -Tail 6 -ErrorAction SilentlyContinue
Write-Output '=== watchdog: how does it start the supervisor? ==='
Select-String -Path (Join-Path $env:USERPROFILE '.pi\piper\piper-watchdog.ps1') -Pattern 'supervisord|Start-Process|RedirectStandard' | Select-Object -First 8 | ForEach-Object { $_.Line.Trim() }
