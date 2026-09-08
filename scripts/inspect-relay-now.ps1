$ErrorActionPreference = 'Continue'
$log = Join-Path $env:USERPROFILE '.pi\piper\relay.log'
Write-Output '=== last 12 min, non-firehose ==='
Get-Content $log -Tail 400 | Where-Object { $_ -notmatch 'firehose' } | Select-Object -Last 30
