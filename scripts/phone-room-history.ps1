$ErrorActionPreference = 'Continue'
$log = 'C:\Users\Alessandro\.pi\piper\relay.log'
Write-Output '=== phone (eTMyo14) auths by day+room (whole log) ==='
Get-Content $log | Where-Object { $_ -like '*authenticated peer=eTMyo14=*' } | ForEach-Object {
  if ($_ -match '^(2026-\d\d-\d\d)T.*room=([A-Za-z0-9_\-]+)') { $Matches[1] + '  room=' + $Matches[2] }
} | Group-Object | Sort-Object Name | ForEach-Object { $_.Count.ToString().PadLeft(4) + '  ' + $_.Name }
Write-Output ''
Write-Output '=== drops today (dest not found) ==='
Get-Content $log | Where-Object { $_ -like '*not found*' -and $_ -match '^2026-09-08' } | Select-Object -First 10
Write-Output ''
Write-Output '=== phone room=main first appearance ==='
Get-Content $log | Where-Object { $_ -like '*authenticated peer=eTMyo14=*room=main*' } | Select-Object -First 3
