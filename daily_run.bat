@ECHO off
REM ============================================================
REM  Daily run: download from UVP6, then upload new files to FTP
REM  Use with Windows Task Scheduler or run by double-clicking
REM ============================================================

cd /d "%~dp0"

ECHO ---- STEP 1: UVP6 Download ----
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0daily_download.ps1"

IF %ERRORLEVEL% NEQ 0 (
    ECHO.
    ECHO [ERROR] Download failed with code %ERRORLEVEL%
    ECHO Skipping FTP upload. Check logs\ folder.
    GOTO :END
)

ECHO.
ECHO ---- STEP 2: FTP Upload ----
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0daily_ftp_upload.ps1"

IF %ERRORLEVEL% NEQ 0 (
    ECHO.
    ECHO [ERROR] FTP upload failed with code %ERRORLEVEL%
    ECHO Check logs\ folder.
)

:END
REM Uncomment the following line to keep the window open (debug)
REM PAUSE
