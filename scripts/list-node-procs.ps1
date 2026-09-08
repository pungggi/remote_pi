$ErrorActionPreference = 'Continue'
Get-CimInstance Win32_Process -Filter "Name='node.exe'" | ForEach-Object {
  $cl = $_.CommandLine
  if ($cl -and ($cl -match 'pi-coding-agent|piper|remote_pi')) {
    Write-Output ('PID=' + $_.ProcessId + '  started=' + $_.CreationDate)
    if ($cl.Length -gt 220) { $cl = $cl.Substring(0,220) + '...' }
    Write-Output ('  cmd: ' + $cl)
    Write-Output ''
  }
}
