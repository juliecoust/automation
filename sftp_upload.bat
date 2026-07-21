@ECHO off
REM ============================================================
REM  Launcher for sftp_upload.ps1 (SFTP upload of new files only)
REM  Use with Windows Task Scheduler or run by double-clicking
REM ============================================================

cd /d "%~dp0"

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0sftp_upload.ps1"
SET RC=%ERRORLEVEL%

IF %RC% NEQ 0 (
    ECHO.
    ECHO [ERROR] The script returned code %RC%
    ECHO Check the logs in the logs\ folder
)

EXIT /B %RC%
