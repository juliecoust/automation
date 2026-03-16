# UVP6 Automated Daily Download — How-To Guide

## Overview

This automation suite connects to a UVP6 underwater camera via **OctOS**, downloads new data files daily, and provides monitoring tools to track download health over time.

### What it does (step by step)

1. **Stops** the current UVP6 acquisition (`$stop;`)
2. **Updates** the file listing from the SD card (`sdlist` → `tree.txt`)
3. **Downloads** only new/missing files (`sddump` — compares automatically)
4. **Reboots** the UVP6 to resume acquisition

---

## Files

| File                 | Purpose                                                 |
| -------------------- | ------------------------------------------------------- |
| `.env`               | Configuration (COM port, IPs, timeouts, email settings) |
| `daily_download.ps1` | Main PowerShell script — all logic lives here           |
| `daily_download.bat` | Launcher for Task Scheduler or double-click             |
| `HOWTO_AUTOMATE.md`  | This documentation                                      |

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

### 3. Schedule for daily execution

#### Using Windows Task Scheduler

1. Open **Task Scheduler** (`taskschd.msc`)
2. Click **Create Basic Task**
3. Name: `UVP6 Daily Download`
4. Trigger: **Daily**, set your preferred time (e.g. 03:00)
5. Action: **Start a program**
   - Program: `C:\OctOS_2024_00\automation\daily_download.bat`
   - Start in: `C:\OctOS_2024_00\automation\`
6. Finish

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
