# UVP6 Automated Download & Cleanup — How-To Guide

## Overview

This automation suite connects to a UVP6 underwater camera via **OctOS**, downloads new data files, uploads them to an SFTP server, and performs verified SD card cleanup.

The scripts are **schedule-agnostic**: how often each one runs is entirely defined by the triggers you set in Windows Task Scheduler. A typical setup runs the download+upload frequently (e.g. daily) and the cleanup less often (e.g. weekly), but any cadence works.

### Entry points

| What | Script | Typical cadence |
|------|--------|-----------------|
| Download new files from UVP6, then upload to SFTP | `download_and_upload.bat` | Frequent (e.g. daily) |
| Verify all files are downloaded + on SFTP, then format the SD card | `cleanup.bat` | Occasional (e.g. weekly) |

### Download + upload workflow (`download_and_upload.bat`)

1. **Stop** the UVP6 acquisition
2. **sdlist** — get fresh file listing from the SD card (`tree.txt`)
3. **sddump** — download only new/missing files
4. **Reboot** the UVP6 to resume acquisition
5. **SFTP upload** — upload only newly downloaded files (diff of `tree.txt` vs `previous_tree.txt`)

### Verify & cleanup workflow (`cleanup.bat`, safety-first)

1. **Stop** the UVP6, then **sdlist** + **sddump** — refresh the listing and download any remaining files
2. **Verify LOCAL** — every file in `tree.txt` must exist in `filemanager/`
3. **Verify SFTP** — every file must exist on the SFTP server **with the expected size** (one recursive remote listing, then per-file comparison); missing or mismatched files are re-uploaded and re-verified
4. **ONLY if 100% verified** → **sdformat** to clean the SD card
5. **Reboot** the UVP6 (resumes acquisition), then clean the local `filemanager/` copies
6. If ANY check fails → **ABORT**: reboot without formatting, no data loss
7. A **timing dashboard** (`cleanup_dashboard_*.html`) is generated at the end of every run, and a one-line summary is appended to `cleanup_history.json` for cross-run comparison

Safety properties:

- After a `$stop;` the UVP6 **never restarts acquisition by itself** — only a reboot resumes it. The instrument therefore stays stopped between the listing and the format, so no new (unlisted) data can appear in between.
- A failed `sdformat` attempt is retried **without rebooting in between**, so a retry can never format data acquired after the verified listing.
- Every error path ends with a reboot attempt so the instrument is not left stopped. If the reboot cannot be confirmed, the log says so explicitly (`Manual check required`).
- An empty `tree.txt` (which is indistinguishable from a truncated listing) also aborts the format.
- `download.ps1` and `cleanup.ps1` take a shared lock (`octos.lock`): if one is still running when the other starts, the second exits immediately instead of fighting over the COM port.

> **UVP6 scheduled acquisition mode:** If the UVP6 is configured in scheduled mode (acquires at :00 and :30 each hour), a `reboot` command must only be sent while the instrument is idle. The scripts automatically send `$stop;` three times and wait for `$stopack;` before every reboot. After a reboot, the scripts accept `HW_CONF` (sent on every boot) as the confirmation signal rather than waiting for `$startack;` (which only arrives at the next acquisition window).

---

## Files

| File | Purpose |
| ---- | ------- |
| `.env` | Configuration (COM port, IPs, timeouts, SFTP credentials) — **never commit it** |
| `.env.empty` | Template: copy to `.env` and fill in |
| `common.ps1` | Shared code (ConPTY session driver for OctOS, logging, SFTP helpers, lock) |
| `download.ps1` | Download logic (stop, sdlist, sddump, reboot) |
| `sftp_upload.ps1` | SFTP upload of newly downloaded files |
| `cleanup.ps1` | Verify local + SFTP, then SD format (safety-first) |
| `download_and_upload.bat` | **Launcher**: download then SFTP upload |
| `download.bat` | Launcher: download only |
| `sftp_upload.bat` | Launcher: SFTP upload only |
| `cleanup.bat` | **Launcher**: verify & format |
| `HOWTO_AUTOMATE.md` | This documentation |

Generated at runtime (inside `OCTOS_DIR`):

| File | Purpose |
| ---- | ------- |
| `logs/download_YYYYMMDD_HHmmss.log` | Detailed log for each download run |
| `logs/sftp_upload_YYYYMMDD_HHmmss.log` | Detailed log for each upload run |
| `logs/cleanup_YYYYMMDD_HHmmss.log` | Detailed log for each cleanup run |
| `logs/cleanup_dashboard_YYYYMMDD_HHmmss.html` | Per-run timing dashboard (open in a browser) |
| `logs/cleanup_dashboard_YYYYMMDD_HHmmss.json` | Per-run timing data (raw JSON) |
| `logs/cleanup_history.json` | Accumulated summary of all past cleanup runs |
| `logs/octos_output_*.log` | Raw OctOS output (only if `OCTOS_OUTPUT_LOG=true`) |

Also generated in the `automation/` folder while a script runs: `octos.lock` (removed automatically at the end of the run; a stale lock left by a killed process is detected and replaced).

---

## Prerequisites

- **Windows** PC connected to the UVP6 (serial + Ethernet)
- **OctOS** installed (the folder containing `bin/OctOS.exe`, `filemanager/`, etc.)
- **PowerShell 5.1+** (included in Windows 10/11)
- Virtual COM port driver installed and configured for the UVP6 serial link
- **Posh-SSH** PowerShell module for the SFTP upload, installed once:

  ```powershell
  Install-Module -Name Posh-SSH -Scope CurrentUser
  ```

---

## Setup

### 1. Create the configuration file

Copy `.env.empty` to `.env` (in the same `automation/` folder), then open `.env` in any text editor and fill in the values:

```ini
# Serial port number (e.g. 3 for COM3)
COM_PORT=3

# IP address of this computer's Ethernet port connected to UVP6
HOST_IP=192.168.0.1

# Serial baudrate (must match the UVP6 config)
BAUDRATE=38400

# Absolute path to the OctOS root folder
OCTOS_DIR=C:\OctOS_2024_00

# SFTP upload
SFTP_HOST=sftp.example.org
SFTP_USER=your-username
SFTP_PORT=22
SFTP_PASSWORD=your-password
SFTP_REMOTE_DIR=path/on/server
```

> **Tip:** To find the COM port number, open Device Manager → Ports (COM & LPT).

> **Security:** `.env` contains the SFTP password in plain text. It is excluded from git via `.gitignore` — never commit it — and its NTFS permissions should be restricted to the account that runs the scheduled tasks.

### 2. Test manually

Open a terminal in the `automation/` folder and run:

```bat
.\download_and_upload.bat
```

Watch the console output. After completion, check the `logs/` folder inside `OCTOS_DIR` for the detailed logs.

Then test the cleanup the same way:

```bat
.\cleanup.bat
```

### 3. Schedule with Task Scheduler

Create **two scheduled tasks**. Pick any cadence you want — the only constraint is that the cleanup should be scheduled so the download+upload task has time to finish first (the lock makes an overlap harmless: the second script simply aborts and retries at its next trigger).

| Task | Script | Example trigger |
|------|--------|-----------------|
| **Task 1 — UVP6 Download + Upload** | `download_and_upload.bat` | Every day at 03:00 |
| **Task 2 — UVP6 Verify & Cleanup** | `cleanup.bat` | Every Sunday at 06:00 |

For each task:

1. Open **Task Scheduler** (`taskschd.msc`)
2. Click **Create Basic Task**
3. Trigger: pick the frequency and time
4. Action: **Start a program**
   - Program: path to the `.bat` file
   - Start in: the `automation\` folder
5. Finish

The cleanup task **refuses to format** unless every file on the SD card has been confirmed present both locally and on the SFTP server (existence and size). Data loss is impossible under normal operation.

#### Recommended settings (in task Properties)

- **Run whether user is logged on or not** — so it works unattended
- **Run with highest privileges** — may be needed for COM port access
- Under *Settings*: **Allow task to be run on demand** — useful for testing
- Under *Settings*: **Stop the task if it runs longer than** — either disable it, or set it **well above** the sum of the script's own timeouts (`SDLIST_TIMEOUT` + `SDDUMP_TIMEOUT` + margin). If Task Scheduler kills the script mid-run, the safety reboot cannot happen and the UVP6 may be left stopped until the next run.

---

## Monitoring

- **Exit codes**: every `.bat` propagates the script's exit code (0 = OK, 1 = error), so the Task Scheduler "Last Run Result" column is meaningful.
- **Logs**: one timestamped log per run in `OCTOS_DIR\logs\`.
- **Cleanup dashboard** (`logs/cleanup_dashboard_*.html`): one HTML file per cleanup run, with one row per action (sdlist, sddump, SFTP check, sdformat, reboot, …) showing start/end time, duration, colour-coded status and details. The "Past runs" panel (fed by `cleanup_history.json`) shows every previous run for spotting regressions or slow runs.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| Script fails immediately | `OCTOS_DIR` wrong or `.env` missing | Copy `.env.empty` to `.env` and fix the values |
| `Another automation script is already running` | Previous run still active (or was killed very recently) | Wait for it to finish; a stale lock from a dead process is cleaned automatically |
| `tree.txt` not updated | `sdlist` command failed or timed out | Increase `SDLIST_TIMEOUT`, check the serial connection |
| `sdlist` fails with socket error 10049 | Transient UDP socket not ready on the UVP6 Ethernet interface | Scripts retry automatically (`MAX_RETRIES` times); usually resolves itself |
| No files downloaded but there should be new data | `sddump` timeout too short | Increase `SDDUMP_TIMEOUT` |
| `(SUmode) Unable to put UVP6 into SU mode` | `reboot` sent while UVP6 is actively acquiring (scheduled mode) | Scripts send `$stop;` ×3 before every reboot and wait for `$stopack;` |
| Script hangs after reboot (timeout on `$startack;`) | UVP6 in scheduled mode — `$startack;` only arrives at the next :00/:30 window | Scripts accept `HW_CONF` (sent on every boot) as the reboot signal |
| Cleanup aborts with `SIZE MISMATCH` | A previous upload was truncated | Nothing to do: the file is re-uploaded and re-verified in the same run |
| `UVP6 reboot could NOT be confirmed` in the log | Serial link or instrument issue during the final reboot | Check the instrument manually — it may be stopped |
| SFTP `CreateDirectory` reports `Failure` | Some servers return a generic failure for already-existing directories | Handled automatically: the scripts re-check existence before failing |
