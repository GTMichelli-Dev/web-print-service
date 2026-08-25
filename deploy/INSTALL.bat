@echo off
REM ===========================================================================
REM  Web Print Service - Windows installer (wrapper)
REM
REM  Right-click -> "Run as administrator", or run from an admin prompt.
REM  Exists so the PowerShell script runs without changing the machine's
REM  execution policy.
REM
REM  Usage:
REM    INSTALL.bat https://valleyag.scaledata.net
REM    INSTALL.bat https://valleyag.scaledata.net -ServiceId scalehouse
REM    INSTALL.bat https://valleyag.scaledata.net -TestPrinter "Zebra ZD421"
REM
REM  Everything after the URL is passed through to install.ps1.
REM  Run  powershell -File install.ps1 -?  to see all options.
REM ===========================================================================

setlocal

REM Capture the script's own folder BEFORE any shift: `shift` moves %0 as well,
REM so %~dp0 read after shifting resolves to the caller's current directory
REM instead of this file's location.
set SCRIPTDIR=%~dp0

if "%~1"=="" (
    echo.
    echo  ERROR: the web app URL is required.
    echo.
    echo    INSTALL.bat https://valleyag.scaledata.net
    echo.
    echo  It must match the web app's real scheme and port - a wrong URL leaves
    echo  the service in an endless reconnect loop.
    echo.
    exit /b 1
)

set WEBURL=%~1
shift

REM Collect any remaining switches (-ServiceId x, -Port n, -TestPrinter "x", ...).
set EXTRA=
:collect
if "%~1"=="" goto run
set EXTRA=%EXTRA% %1
shift
goto collect

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPTDIR%install.ps1" -WebUrl "%WEBURL%"%EXTRA%
set RC=%ERRORLEVEL%

echo.
if not "%RC%"=="0" (
    echo  Install FAILED with code %RC%.
) else (
    echo  Press any key to close.
)
pause >nul
exit /b %RC%

endlocal
