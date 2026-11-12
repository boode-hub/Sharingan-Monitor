@echo off
REM Sharingan Monitor - enable at startup and launch now.
REM No admin needed: this writes to the per-user Run key only.

set "SCRIPT=%~dp0Sharingan.ps1"
set "VBS=%~dp0launcher.vbs"

if not exist "%SCRIPT%" (
    echo ERROR: Sharingan.ps1 not found next to this batch file.
    pause
    exit /b 1
)

REM A 2-line WScript shim so PowerShell starts fully hidden - "-WindowStyle Hidden"
REM alone still flashes a console window on every boot.
> "%VBS%" echo Set s = CreateObject("WScript.Shell")
>>"%VBS%" echo s.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""%SCRIPT%""", 0, False

REM PowerShell writes the Run entry and reads the path from the environment, so a
REM folder name with & or other special characters cannot break the command.
powershell -NoProfile -Command "Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'SharinganMonitor' -Value ('wscript.exe //nologo ' + [char]34 + $env:VBS + [char]34) -ErrorAction Stop" >nul 2>&1
if errorlevel 1 (
    echo ERROR: could not write the startup registry entry.
    pause
    exit /b 1
)

REM Don't stack a second tray icon if it's already running. A pid file left behind
REM by a crash or a shutdown does not count: that process must still be alive.
set "RUNNING="
set "RPID="
if exist "%~dp0sharingan.pid" set /p RPID=<"%~dp0sharingan.pid"
if defined RPID powershell -NoProfile -Command "$id = 0; if ([int]::TryParse('%RPID%'.Trim(), [ref]$id) -and (Get-Process -Id $id -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'powershell|pwsh' })) { exit 0 } else { exit 1 }" && set "RUNNING=1"
if not defined RUNNING (
    start "" wscript.exe //nologo "%VBS%"
    echo Started.
) else (
    echo Already running - startup entry added, not relaunching.
)

echo.
echo Sharingan Monitor will now start automatically when you log in.
echo Run remove-startup.bat to undo this.
pause
