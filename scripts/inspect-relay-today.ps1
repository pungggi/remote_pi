$ErrorActionPreference = 'Continue'
$dir = Join-Path $env:USERPROFILE '.pi\piper'
Write-Output '=== files ==='
Get-ChildItem $dir -Filter 'relay*.log*' | Sort-Object LastWriteTime -Descending | Select-Object -First 4 Name,Length,LastWriteTime | Format-Table -AutoSize | Out-String -Width 140
$latest = Get-ChildItem $dir -Filter 'relay.log' | Select-Object -First 1
Write-Output ('=== relay.log tail since 2026-09-08T02:30Z (non-firehose) ===')
Get-Content $latest.FullName -Tail 800 | Where-Object { $_ -match '^2026-09-08T0[2-9]' -and $_ -notmatch 'firehose' } | Select-Object -Last 40
Write-Output '=== any eTMyo14 (phone) lines today ==='
Get-Content $latest.FullName -Tail 3000 | Where-Object { $_ -match '^2026-09-08' -and $_ -match 'eTMyo14' } | Select-Object -Last 15
Write-Output '=== any YqJWq1g (ext daemon) lines today ==='
Get-Content $latest.FullName -Tail 3000 | Where-Object { $_ -match '^2026-09-08' -and $_ -match 'YqJWq1g' } | Select-Object -Last 15
