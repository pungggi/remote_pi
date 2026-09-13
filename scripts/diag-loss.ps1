# v3 — fixed (.Line bug): full-day relay picture
$p = "$env:USERPROFILE\.pi\piper"
"== drops / route_error today =="
Get-Content "$p\relay.log" | Where-Object { $_ -match '2026-09-13' -and $_ -match 'not found, dropping|route_error' } | Select-Object -Last 40
"`n== non-keeper conn lifecycle today (last 45) =="
Get-Content "$p\relay.log" | Where-Object { $_ -match '2026-09-13' -and $_ -match 'authenticated|stream ended|reaped' -and $_ -notmatch 'keeper' } | Select-Object -Last 45
"`n== supervisord.log tail (keeper activity) =="
Get-Content "$p\supervisord.log" -Tail 30
