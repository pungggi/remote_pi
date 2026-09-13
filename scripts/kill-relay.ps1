# Kill whatever holds port 3000 and identify it
$c = Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue
if ($c) {
  $c | ForEach-Object {
    $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
    if ($p) { "listener: $($p.ProcessName) pid=$($p.Id) path=$($p.Path)" }
  }
} else { "no listener on 3000" }
# also any process named relay anywhere
Get-Process relay -ErrorAction SilentlyContinue | ForEach-Object { "relay proc pid=$($_.Id) path=$($_.Path)" }
