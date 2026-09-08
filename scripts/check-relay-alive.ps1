$ErrorActionPreference = 'Continue'
Write-Output '=== relay process ==='
Get-Process -Name relay -ErrorAction SilentlyContinue | Select-Object Id,ProcessName,StartTime | Format-Table -AutoSize | Out-String
Write-Output '=== port 3000 ==='
netstat -ano | Select-String ':3000 ' | Select-Object -First 5
Write-Output '=== health ==='
try { $r = Invoke-WebRequest -Uri 'http://127.0.0.1:3000/health' -UseBasicParsing -TimeoutSec 5; Write-Output ("health=" + $r.StatusCode + " " + $r.Content) } catch { Write-Output ("health FAILED: " + $_.Exception.Message) }
Write-Output '=== watchdog tail ==='
Get-Content (Join-Path $env:USERPROFILE '.pi\piper\watchdog.log') -Tail 8
Write-Output '=== scheduled task ==='
schtasks /Query /TN "Piper Relay" /V /FO LIST 2>&1 | Select-String 'Status|Last Run Time|Last Result|Next Run'
