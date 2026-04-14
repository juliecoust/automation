@ECHO off
REM ============================================================
REM  Weekly verify & cleanup: checks all files are downloaded
REM  AND uploaded to FTP before formatting the SD card.
REM  Use with Windows Task Scheduler (weekly trigger).
REM ============================================================

cd /d "%~dp0"

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0weekly_cleanup.ps1"

IF %ERRORLEVEL% NEQ 0 (
    ECHO.
    ECHO [ERROR] Weekly cleanup returned code %ERRORLEVEL%
    ECHO SD card was NOT formatted. Check logs\ folder.
)

REM Uncomment the following line to keep the window open (debug)
REM PAUSE
