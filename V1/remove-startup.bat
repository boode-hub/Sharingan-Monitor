@echo off
setlocal enabledelayedexpansion
REM Sharingan Monitor - remove from startup and stop the running instance.

reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "SharinganMonitor" /f >nul 2>&1
if errorlevel 1 (
    echo Startup entry was not present.
) else (
    echo Startup entry removed.
)

if exist "%~dp0sharingan.pid" (
    set /p TARGETPID=<"%~dp0sharingan.pid"
    REM Confirm the PID still belongs to a PowerShell process before killing it -
    REM a stale pid file could otherwise point at something Windows has recycled.
    powershell -NoProfile -Command "$p = Get-Process -Id !TARGETPID! -ErrorAction SilentlyContinue; if ($p -and $p.ProcessName -match 'powershell|pwsh') { Stop-Process -Id !TARGETPID! -Force; 'Stopped running instance.' } else { 'No running instance found.' }"
    del "%~dp0sharingan.pid" >nul 2>&1
) else (
    echo No running instance found.
)

if exist "%~dp0launcher.vbs" del "%~dp0launcher.vbs" >nul 2>&1

echo.
echo Sharingan Monitor will no longer start at login.
echo Your settings.json is kept - delete it if you want a clean slate.
pause
