# Compile and run pty_write_freeze_harness.c (Windows / MSVC only).
$ErrorActionPreference = 'Stop'

$dir = $PSScriptRoot
$src = (Resolve-Path (Join-Path $dir '..\..\src')).Path

$vcvarsCandidates = @(
    'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat',
    'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat',
    'C:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat',
    'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat',
    'C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat'
)

$vcvars = $vcvarsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $vcvars) {
    Write-Error 'vcvars64.bat not found. Install Visual Studio Build Tools (C++).'
}

$exe = Join-Path $dir 'pty_write_freeze_harness.exe'
$bat = Join-Path $env:TEMP 'cockpit_pty_write_freeze_build.bat'
@"
@echo off
call "$vcvars" >nul
if errorlevel 1 exit /b 1
cd /d "$dir"
cl /nologo /W3 /D_CRT_SECURE_NO_WARNINGS pty_write_freeze_harness.c "$src\include\dart_api_dl.c" /I "$src" /I "$src\include" /Fe:"$exe"
if errorlevel 1 exit /b 1
"$exe"
"@ | Set-Content -Path $bat -Encoding ASCII

cmd.exe /c $bat
exit $LASTEXITCODE
