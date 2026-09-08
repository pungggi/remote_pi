$ErrorActionPreference = 'Stop'
$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$rooms = [ordered]@{
  'EswcFM764p1-' = [ordered]@{ cwd = 'C:\Users\Alessandro\source\pi\packages\remote_pi'; roomId = 'EswcFM764p1-'; lastSeenAt = $now }
  'Agq7sYHlSb_l' = [ordered]@{ cwd = 'C:\Users\Alessandro\source'; roomId = 'Agq7sYHlSb_l'; lastSeenAt = $now }
}
$rooms | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $env:USERPROFILE '.pi\piper\rooms.json')
Write-Output "seeded rooms.json lastSeenAt=$now"
