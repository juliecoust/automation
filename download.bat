@ECHO off
REM ============================================================
REM  Launcher for download.ps1 (UVP6 download only, no upload)
REM  Use with Windows Task Scheduler or run by double-clicking
REM ============================================================

cd /d "%~dp0"

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0download.ps1"
SET RC=%ERRORLEVEL%

IF %RC% NEQ 0 (
    ECHO.
    ECHO [ERROR] The script returned code %RC%
    ECHO Check the logs in the logs\ folder
)

EXIT /B %RC%
