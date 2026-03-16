@ECHO off
REM ============================================================
REM  Launcher for daily_download.ps1
REM  Use with Windows Task Scheduler or run by double-clicking
REM ============================================================

cd /d "%~dp0"

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0daily_download.ps1"

IF %ERRORLEVEL% NEQ 0 (
    ECHO.
    ECHO [ERROR] The script returned code %ERRORLEVEL%
    ECHO Check the logs in the logs\ folder
)

REM Uncomment the following line to keep the window open (debug)
REM PAUSE
