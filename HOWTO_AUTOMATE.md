# UVP6 Automated Download & Cleanup — How-To Guide

## Overview

This automation suite connects to a UVP6 underwater camera via **OctOS**, downloads new data files, uploads them to an FTP server, and performs verified SD card cleanup on a weekly schedule.

### Schedule

| When | What | Script |
|------|------|--------|
| **Daily** | Download new files from UVP6, then upload to FTP | `daily_run.bat` |
| **Weekly** | Verify all files are downloaded + on FTP, then format SD | `weekly_cleanup.bat` |

### Daily workflow (automatic)

1. **Stop** the UVP6 acquisition
2. **sdlist** — get fresh file listing from SD card
3. **sddump** — download only new/missing files
4. **Reboot** UVP6 to resume acquisition
5. **FTP upload** — upload only newly downloaded files
6. **Copy** new files to Desktop\data

### Weekly workflow (automatic, safety-first)

1. **sdlist** — get fresh file listing from SD card
2. **Verify LOCAL** — check every file in tree.txt exists in filemanager/
3. **Verify FTP** — check every file in tree.txt exists on the FTP server
4. **ONLY if 100% verified** → **sdformat** to clean the SD card
5. If ANY file is missing → **ABORT** (no format, no data loss)

---

## Files

| File                 | Purpose                                                 |
| -------------------- | ------------------------------------------------------- |
| `.env`               | Configuration (COM port, IPs, timeouts, email settings)  |
| `daily_download.ps1` | Main PowerShell script — download logic                  |
| `daily_download.bat` | Launcher for Task Scheduler or double-click (download)   |
| `daily_ftp_upload.ps1` | FTP upload of new files to remote server                |
| `daily_ftp_upload.bat` | Launcher for FTP upload only                            |
| `daily_run.bat`      | **Daily launcher** — runs download then FTP upload        |
| `weekly_cleanup.ps1` | Weekly verify + SD format (safety-first cleanup)          |
| `weekly_cleanup.bat` | **Weekly launcher** — verify & format                     |
| `daily_cleanup.ps1`  | Standalone SD format (no verification — use weekly instead)|
| `daily_cleanup.bat`  | Launcher for standalone cleanup                           |
| `HOWTO_AUTOMATE.md`  | This documentation                                       |

Generated at runtime (inside `OCTOS_DIR`):

| File                                | Purpose                                       |
| ----------------------------------- | --------------------------------------------- |
| `logs/download_YYYYMMDD_HHmmss.log` | Detailed log for each run                     |
| `logs/download_history.csv`         | One-row-per-day history (open in Excel)       |
| `logs/dashboard.html`               | Visual monitoring dashboard (open in browser) |
| `status.txt`                        | Quick-glance status of the last run           |

---

## Prerequisites

- **Windows** PC connected to the UVP6 (serial + Ethernet)
- **OctOS** installed (the folder containing `bin/OctOS.exe`, `filemanager/`, etc.)
- **PowerShell 5.1+** (included in Windows 10/11)
- Virtual COM port driver installed and configured for the UVP6 serial link

---

## Setup

### 1. Edit the configuration file

Open `.env` in any text editor and fill in the values:

```ini
# Serial port number (e.g. 3 for COM3)
COM_PORT=3

# IP address of this computer's Ethernet port connected to UVP6
HOST_IP=193.49.112.130

# IP address of the UVP6
UVP6_IP=192.168.0.2

# Serial baudrate (must match UVP6 config)
BAUDRATE=115200

# Absolute path to the OctOS root folder
OCTOS_DIR=C:\OctOS_2024_00
```

> **Tip:** To find the COM port number, open Device Manager → Ports (COM & LPT).

### 2. Test manually

Open a terminal in the `automation/` folder and run:

```bat
.\daily_download.bat
```

Or directly with PowerShell:

```powershell
.\daily_download.ps1
```

Watch the console output. After completion, check:
- `status.txt` in the OctOS root folder
- `logs/` folder for the detailed log

### 3. Schedule with Task Scheduler

You need **two** scheduled tasks:

#### Task 1: Daily Download + FTP Upload

1. Open **Task Scheduler** (`taskschd.msc`)
2. Click **Create Basic Task**
3. Name: `UVP6 Daily Run`
4. Trigger: **Daily**, set your preferred time (e.g. 03:00)
5. Action: **Start a program**
   - Program: path to `daily_run.bat`
   - Start in: the `automation\` folder
6. Finish

This runs the download first, then automatically uploads new files to FTP.

#### Task 2: Weekly Verify & Cleanup

1. Create another task
2. Name: `UVP6 Weekly Cleanup`
3. Trigger: **Weekly**, pick a day (e.g. Sunday at 06:00)
4. Action: **Start a program**
   - Program: path to `weekly_cleanup.bat`
   - Start in: the `automation\` folder
5. Finish

This script **refuses to format** unless every file on the SD card has been confirmed present both locally and on FTP. Data loss is impossible under normal operation.

> **Important:** Schedule the weekly cleanup AFTER the daily run has had time to complete (e.g. daily at 03:00, weekly at 06:00 on Sunday).

#### FTP Configuration

Set these in `.env`:

```ini
FTP_HOST=plankton.obs-vlfr.fr
FTP_USER=ftp_plankton
FTP_PASSWORD=Pl@nkt0n4Ecotaxa
FTP_REMOTE_DIR=
```

#### Recommended settings (in task Properties)

- **Run whether user is logged on or not** — so it works unattended
- **Run with highest privileges** — may be needed for COM port access
- Under *Settings*: **Allow task to be run on demand** — useful for testing
- Under *Settings*: **Stop the task if it runs longer than** → `4 hours` (adjust to match `SDDUMP_TIMEOUT`)

---

## Monitoring

### Quick check: `status.txt`

Located at the OctOS root folder. Shows the result of the last run at a glance:

```
========================================
  UVP6 — DOWNLOAD STATUS
========================================
Last run       : 2026-03-13 04:00:12
Status         : [OK] OK
========================================
```

### History: `logs/download_history.csv`

A CSV file with one row per run. Open in Excel or any spreadsheet. Columns:

| Date | Time | Status | SD_Files | New | Downloaded | Failed | New_Acquisitions | Error | Log |
| ---- | ---- | ------ | -------- | --- | ---------- | ------ | ---------------- | ----- | --- |

### Dashboard: `logs/dashboard.html`

Open in any web browser. Features:
- **Summary cards** — files downloaded, acquisitions, failures (last 7 days)
- **Full history table** — color-coded rows (green/orange/red)
- **Auto-refresh** every 5 minutes (if kept open)

### Email notifications (optional)

Configure in `.env`:

```ini
SMTP_SERVER=smtp.example.com
SMTP_PORT=587
SMTP_USER=user@example.com
SMTP_PASSWORD=secret
EMAIL_FROM=uvp6@example.com
EMAIL_TO=team@example.com

# true = email only on errors; false = email every run
EMAIL_ONLY_ON_ERROR=true
```

Leave `SMTP_SERVER` empty to disable email notifications entirely.

---

## Troubleshooting

| Symptom                                          | Likely cause                                  | Fix                                                |
| ------------------------------------------------ | --------------------------------------------- | -------------------------------------------------- |
| Script fails immediately                         | `OCTOS_DIR` is wrong in `.env`                | Fix the path to your OctOS installation            |
| `tree.txt` not updated                           | `sdlist` command failed or timed out          | Increase `SDLIST_TIMEOUT`, check serial connection |
| No files downloaded but there should be new data | `sddump` timeout too short                    | Increase `SDDUMP_TIMEOUT`                          |
| OctOS doesn't respond to commands                | OctOS may use Console API instead of stdin    | See "Alternative approach" section below           |
| Email not sent                                   | SMTP settings incorrect or server unreachable | Test SMTP settings independently                   |

### Alternative approach: if OctOS doesn't accept stdin

If `OctOS.exe` reads input from the Windows Console API rather than standard input, piped commands won't work. In that case, consider:

1. **AutoHotkey** — simulate keyboard input to the OctOS window
2. **Python + pyserial** — send `$stop;` commands directly over the COM port, then launch OctOS only for `sdlist`/`sddump` (which need Ethernet)
3. **Expect for Windows** (via Cygwin or MSYS2) — drive interactive CLI programs

A commented-out Python/pyserial example is included at the bottom of `daily_download.ps1`.

---

## Log retention

Old log files are automatically deleted after **90 days** (configurable via `LOG_RETENTION_DAYS` in `.env`). The CSV history and dashboard are never pruned — only individual `.log` files are rotated.
