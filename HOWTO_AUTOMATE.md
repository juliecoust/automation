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

1. **Stop** UVP6 acquisition, then **sdlist** + **sddump** — verify SD listing and dump tree
2. **Verify LOCAL** — check every file in tree.txt exists in filemanager/
3. **Verify FTP** — check every file in tree.txt exists on the FTP server
4. **ONLY if 100% verified** → **Stop** UVP6, then **sdformat** to clean the SD card
5. **Reboot** UVP6 to resume acquisition
6. If ANY file is missing → **ABORT** (no format, no data loss)
7. A **timing dashboard** (`weekly_cleanup_dashboard_*.html`) is generated at the end of every run, and a one-line summary is appended to `weekly_cleanup_history.json` for cross-run comparison.

> **UVP6 scheduled acquisition mode:** If the UVP6 is configured in scheduled mode (acquires at :00 and :30 each hour), a `reboot` command must only be sent while the instrument is idle. The scripts automatically send `$stop;` three times and wait for `$stopack;` before every reboot. After reboot, the script accepts `HW_CONF` (sent on every boot) as the reboot confirmation signal rather than waiting for `$startack;` (which only arrives at the next acquisition window).

---

## Files

| File                 | Purpose                                                 |
| -------------------- | ------------------------------------------------------- |
| `.env`               | Configuration (COM port, IPs, timeouts)                  |
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

| File                                                  | Purpose                                                      |
| ----------------------------------------------------- | ------------------------------------------------------------ |
| `logs/download_YYYYMMDD_HHmmss.log`                   | Detailed log for each daily run                              |
| `logs/weekly_cleanup_YYYYMMDD_HHmmss.log`             | Detailed log for each weekly run                             |
| `logs/download_history.csv`                           | One-row-per-day download history (open in Excel)             |
| `logs/weekly_cleanup_dashboard_YYYYMMDD_HHmmss.html`  | Per-run timing dashboard (open in browser)                   |
| `logs/weekly_cleanup_dashboard_YYYYMMDD_HHmmss.json`  | Per-run timing data (raw JSON)                               |
| `logs/weekly_cleanup_history.json`                    | Accumulated summary of all past weekly runs                  |
| `status.txt`                                          | Quick-glance status of the last run                          |

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

# Retry logic — number of attempts and delay (seconds) between retries
MAX_RETRIES=3
RETRY_DELAY=10

# Set to true to write octos_output_*.log files (verbose, slow on large sessions)
# Set to false (recommended) to skip them and rely on the per-run log instead
OCTOS_OUTPUT_LOG=false
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

The automation requires ** two scheduled tasks** in Windows Task Scheduler. They are independent scripts but must be scheduled so the weekly cleanup always runs after the daily run has finished.

| Task | Script | Recommended trigger |
|------|--------|-------------------|
| **Task 1 — Daily Download + Upload** | `daily_run.bat` | Every day at 03:00 |
| **Task 2 — Weekly Verify & Cleanup** | `weekly_cleanup.bat` | Every Sunday at 06:00 |

> **Why two tasks?** The daily task keeps data flowing every day (download + FTP upload). The weekly task does the heavier verification and SD card format — it depends on the daily task having run first so that all files are already present locally and on FTP before it checks.

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

> **Important:** Schedule the weekly cleanup AFTER the daily run has had time to complete (e.g. daily at 03:00, weekly at 06:00 on Sunday). On the day the weekly cleanup runs, the daily task will have already downloaded and uploaded everything — the weekly task then verifies and formats.

#### SFTP Configuration

Set these in `.env`:

```ini
SFTP_HOST=data.obsea.es
SFTP_USER=uvp6
SFTP_PORT=22
SFTP_PASSWORD=secret
SFTP_REMOTE_DIR=uvp6/data
```

> **Requirement:** The **Posh-SSH** PowerShell module must be installed once on the PC:
> ```powershell
> Install-Module -Name Posh-SSH -Scope CurrentUser
> ```
> After that, the scripts load it automatically at runtime with no further setup.

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

### Weekly cleanup dashboard: `logs/weekly_cleanup_dashboard_*.html`

A new HTML file is generated after every weekly run. Open in any web browser.

**Current run panel** — one row per action (sdlist, sddump, FTP check, sdformat, reboot, …) with:
- Start time, end time, duration (HHhMMmSSs format)
- Status (OK / WARN / ERROR) — colour-coded green/amber/red
- Details (file counts, error messages)

**Past runs panel** — loaded from `weekly_cleanup_history.json`, shows every previous run with its total duration, file count, and final status. Useful for spotting regressions or slow runs over time.

---

## Troubleshooting

| Symptom                                          | Likely cause                                                         | Fix                                                                       |
| ------------------------------------------------ | -------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| Script fails immediately                         | `OCTOS_DIR` is wrong in `.env`                                       | Fix the path to your OctOS installation                                   |
| `tree.txt` not updated                           | `sdlist` command failed or timed out                                 | Increase `SDLIST_TIMEOUT`, check serial connection                        |
| `sdlist` fails with socket error 10049           | Transient UDP socket not ready on the UVP6 Ethernet interface        | Scripts retry automatically (`MAX_RETRIES` times); usually resolves itself |
| No files downloaded but there should be new data | `sddump` timeout too short                                           | Increase `SDDUMP_TIMEOUT`                                                 |
| `(SUmode) Unable to put UVP6 into SU mode`       | `reboot` sent while UVP6 is actively acquiring (scheduled mode)      | Scripts now send `$stop;` ×3 before every reboot and wait for `$stopack;` |
| Script hangs after reboot (timeout on `$startack;`) | UVP6 in scheduled mode — `$startack;` only arrives at next :00/:30 window | Scripts accept `HW_CONF` (sent on every boot) as the reboot signal  |
| OctOS doesn't respond to commands                | OctOS may use Console API instead of stdin                           | See "Alternative approach" section below                                  |

### Alternative approach: if OctOS doesn't accept stdin

If `OctOS.exe` reads input from the Windows Console API rather than standard input, piped commands won't work. In that case, consider:

1. **AutoHotkey** — simulate keyboard input to the OctOS window
2. **Python + pyserial** — send `$stop;` commands directly over the COM port, then launch OctOS only for `sdlist`/`sddump` (which need Ethernet)
3. **Expect for Windows** (via Cygwin or MSYS2) — drive interactive CLI programs

A commented-out Python/pyserial example is included at the bottom of `daily_download.ps1`.

---

