$ErrorActionPreference = 'Continue'
$log = Join-Path $env:USERPROFILE '.pi\piper\relay.log'
Write-Output '=== relay.log 13:49-13:55Z (15:49-15:55 local) ==='
Get-Content $log | Where-Object { $_ -match '^2026-09-05T13:(49|5[0-5])' -and $_ -notmatch 'firehose' } | Select-Object -First 40
Write-Output ''
Write-Output '=== relay startup banners today ==='
Get-Content $log | Where-Object { $_ -match 'relay (starting|listening)|listening on|version' } | Select-Object -Last 6
Write-Output ''
Write-Output '=== watchdog.log tail ==='
Get-Content (Join-Path $env:USERPROFILE '.pi\piper\watchdog.log') -Tail 25
