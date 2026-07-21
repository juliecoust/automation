@ECHO off
REM ============================================================
REM  UVP6 download via OctOS, then SFTP upload of the new files.
REM  Schedule this with Windows Task Scheduler at the desired
REM  frequency (the scripts are schedule-agnostic).
REM ============================================================

cd /d "%~dp0"

ECHO ---- STEP 1: UVP6 download ----
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0download.ps1"
SET RC=%ERRORLEVEL%

IF %RC% NEQ 0 (
    ECHO.
    ECHO [ERROR] Download failed with code %RC%
    ECHO Skipping SFTP upload. Check the logs\ folder.
    EXIT /B %RC%
)

ECHO.
ECHO ---- STEP 2: SFTP upload ----
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0sftp_upload.ps1"
SET RC=%ERRORLEVEL%

IF %RC% NEQ 0 (
    ECHO.
    ECHO [ERROR] SFTP upload failed with code %RC%
    ECHO Check the logs\ folder.
)

EXIT /B %RC%
