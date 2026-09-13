$ErrorActionPreference = 'Continue'
Set-Location C:\Users\Alessandro\.pi\piper
Write-Output '=== watchdog ==='
Get-Content watchdog.log -Tail 3
Write-Output '=== keeper auths (last 25 authenticated lines) ==='
Get-Content relay.log -Tail 800 | Select-String 'authenticated' | Select-Object -Last 25 | ForEach-Object { $_.Line }
Write-Output '=== rooms.json entry count ==='
(Get-Content rooms.json | ConvertFrom-Json).PSObject.Properties.Name.Count
