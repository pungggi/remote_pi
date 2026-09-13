$ErrorActionPreference = 'Continue'
Set-Location C:\Users\Alessandro\.pi\piper
$lines = Get-Content relay.log -Tail 3000 | Select-String 'authenticated' | Select-String '2026-09-13T11:34'
Write-Output ("keeper-burst auth count: " + $lines.Count)
$rooms = $lines | ForEach-Object { [regex]::Match($_.Line, 'room=([A-Za-z0-9_\-]+)').Groups[1].Value }
Write-Output ("unique rooms: " + ($rooms | Sort-Object -Unique).Count)
