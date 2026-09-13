$ErrorActionPreference = 'Continue'
$env:PATH = "C:\Users\Alessandro\flutter\bin;" + $env:PATH
Set-Location C:\Users\Alessandro\source\pi\packages\remote_pi\app
dart analyze lib test 2>&1 | Select-Object -Last 15
