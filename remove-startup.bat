@echo off
setlocal disabledelayedexpansion
REM Sharingan Monitor - remove from startup and stop the running instance.

reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "SharinganMonitor" /f >nul 2>&1
if errorlevel 1 (
    echo Startup entry was not present.
) else (
    echo Startup entry removed.
)

REM PowerShell reads the pid file itself (its path comes from the environment), so
REM neither the folder name nor the file's content can change the command. The pid
REM must be a PowerShell running Sharingan.ps1: a file left by a crash or a shutdown
REM can name a number Windows has since given to another program.
set "PIDFILE=%~dp0sharingan.pid"
powershell -NoProfile -Command "$id = 0; $p = $null; if ((Test-Path -LiteralPath $env:PIDFILE) -and [int]::TryParse([string](Get-Content -LiteralPath $env:PIDFILE -TotalCount 1), [ref]$id)) { $p = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $id) | Where-Object { $_.Name -in 'powershell.exe', 'pwsh.exe' -and $_.CommandLine -like '*Sharingan.ps1*' } }; if ($p) { Stop-Process -Id $id -Force; 'Stopped running instance.' } else { 'No running instance found.' }; Remove-Item -LiteralPath $env:PIDFILE -ErrorAction SilentlyContinue"

if exist "%~dp0launcher.vbs" del "%~dp0launcher.vbs" >nul 2>&1

echo.
echo Sharingan Monitor will no longer start at login.
echo Your settings.json is kept - delete it if you want a clean slate.
pause
