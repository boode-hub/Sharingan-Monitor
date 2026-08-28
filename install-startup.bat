@echo off
REM Sharingan Monitor - enable at startup and launch now.
REM No admin needed: this writes to the per-user Run key only.

set "SCRIPT=%~dp0p2.ps1"
set "VBS=%~dp0launcher.vbs"

if not exist "%SCRIPT%" (
    echo ERROR: p2.ps1 not found next to this batch file.
    pause
    exit /b 1
)

REM A 2-line WScript shim so PowerShell starts fully hidden - "-WindowStyle Hidden"
REM alone still flashes a console window on every boot.
> "%VBS%" echo Set s = CreateObject("WScript.Shell")
>>"%VBS%" echo s.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""%SCRIPT%""", 0, False

reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "SharinganMonitor" /t REG_SZ /d "wscript.exe //nologo \"%VBS%\"" /f >nul
if errorlevel 1 (
    echo ERROR: could not write the startup registry entry.
    pause
    exit /b 1
)

REM Don't stack a second tray icon if it's already running.
if not exist "%~dp0sharingan.pid" (
    start "" wscript.exe //nologo "%VBS%"
    echo Started.
) else (
    echo Already running - startup entry added, not relaunching.
)

echo.
echo Sharingan Monitor will now start automatically when you log in.
echo Run remove-startup.bat to undo this.
pause
