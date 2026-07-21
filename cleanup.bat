@ECHO off
REM ============================================================
REM  Verify & cleanup: checks that all files are downloaded AND
REM  uploaded to SFTP (existence + size) before formatting the
REM  UVP6 SD card. Aborts without formatting on any doubt.
REM  Use with Windows Task Scheduler.
REM ============================================================

cd /d "%~dp0"

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0cleanup.ps1"
SET RC=%ERRORLEVEL%

IF %RC% NEQ 0 (
    ECHO.
    ECHO [ERROR] Cleanup returned code %RC%
    ECHO SD card was NOT formatted. Check the logs\ folder.
)

EXIT /B %RC%
