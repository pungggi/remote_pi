$ErrorActionPreference = 'Continue'
Write-Output '=== relay.log LAST 6 lines ==='
Get-Content (Join-Path $env:USERPROFILE '.pi\piper\relay.log') -Tail 6
Write-Output '=== any 2026-09-08 lines at all (tail 2000) ==='
(Get-Content (Join-Path $env:USERPROFILE '.pi\piper\relay.log') -Tail 2000 | Where-Object { $_ -match '^2026-09-08' } | Measure-Object).Count
Write-Output '=== PC LAN IP now ==='
(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '192.168.*' }).IPAddress
Write-Output '=== tailscale peers ==='
tailscale status 2>&1 | Select-Object -First 6
Write-Output '=== serve roundtrip ==='
& curl.exe -s -o NUL -w "%{http_code}" --max-time 8 https://chico.tail5d4821.ts.net/health
Write-Output ''
& curl.exe -s --max-time 8 https://chico.tail5d4821.ts.net/health
Write-Output ''
