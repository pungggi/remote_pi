$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:USERPROFILE '.pi\agent\sessions\--C--Users-Alessandro-source-pi-packages-remote_pi--'
$f = Get-ChildItem $dir -Filter *.jsonl | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output ("FILE: " + $f.Name)
$lines = Get-Content $f.FullName -Tail 8
foreach ($l in $lines) {
  try {
    $o = $l | ConvertFrom-Json
    $role = $o.message.role
    if (-not $role) { $role = $o.type }
    $ts = $o.message.timestamp
    if (-not $ts) { $ts = $o.timestamp }
    $c = ''
    if ($o.message.content -is [string]) { $c = $o.message.content }
    elseif ($o.message.content) { $c = ($o.message.content | ConvertTo-Json -Compress -Depth 3) }
    if ($c.Length -gt 110) { $c = $c.Substring(0, 110) + '...' }
    Write-Output ($o.type + ' | role=' + $role + ' | ts=' + $ts + ' | ' + $c)
  } catch {
    Write-Output ('UNPARSEABLE line, len=' + $l.Length)
  }
}
