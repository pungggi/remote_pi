$ErrorActionPreference = 'Continue'
Write-Output '=== worktrees.json (pinned fleet config) ==='
Get-Content (Join-Path $env:USERPROFILE '.pi\piper\worktrees.json')
Write-Output ''
Write-Output '=== pi/node processes with cwd hints ==='
Get-CimInstance Win32_Process | Where-Object { ($_.Name -match 'node|pi') -and $_.CommandLine } |
  Select-Object ProcessId,Name,@{n='cmd';e={ if ($_.CommandLine.Length -gt 130) { $_.CommandLine.Substring(0,130) } else { $_.CommandLine } }} |
  Format-Table -AutoSize | Out-String -Width 160
Write-Output '=== supervisord.log tail ==='
Get-Content (Join-Path $env:USERPROFILE '.pi\piper\supervisord.log') -Tail 15
