$ErrorActionPreference = 'Continue'
Write-Output '=== serve ==='
tailscale serve status 2>&1
Write-Output '=== https probe ==='
try { $r = Invoke-WebRequest -Uri 'https://chico.tail5d4821.ts.net/health' -UseBasicParsing -TimeoutSec 8; Write-Output ("https health=" + $r.StatusCode + " " + $r.Content) } catch { Write-Output ("https FAILED: " + $_.Exception.Message) }
Write-Output '=== tailscale status ==='
tailscale status 2>&1 | Select-Object -First 8
Write-Output '=== LAN IPv4 ==='
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '192.168.*' -or $_.IPAddress -like '100.*' } | Select-Object IPAddress,InterfaceAlias | Format-Table -AutoSize | Out-String
Write-Output '=== boot-window relay.log ==='
Get-Content (Join-Path $env:USERPROFILE '.pi\piper\relay.log') -Tail 60 | Where-Object { $_ -match '^2026-09-08' } | Select-Object -First 25
