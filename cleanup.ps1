<#
.SYNOPSIS
    UVP6 verification and SD card cleanup (schedule-agnostic; run it as often
    as needed, typically less frequently than download.ps1).

.DESCRIPTION
    SAFETY-FIRST workflow - the SD card is ONLY formatted after verifying
    that every single file has been:
      1. Downloaded to the local filemanager/ folder
      2. Uploaded to the remote SFTP server (existence AND size checked)

    If ANY file is missing locally or on SFTP, the script ABORTS without
    formatting. No data is ever lost.

    Sequence:
      1) Connect to UVP6 via OctOS
      2) Stop UVP6 acquisition (UVP6 stays stopped until the final reboot;
         after a $stop; the instrument never restarts acquisition by itself)
      3) sdlist  - get fresh SD card file listing
      4) sddump  - download any remaining files
      5) Quit OctOS (UVP6 still stopped - no new data can appear)
      6) Verify every file exists locally
      7) Upload any missing files to SFTP
      8) Verify every file exists on SFTP with the expected size
      9) If 100% verified - reconnect and sdformat
     10) Reboot UVP6 (resumes acquisition)
     11) Clean local filemanager/ folder (SD card is now empty)
     12) On ANY failure - reboot without formatting (no data loss)

    A failed sdformat attempt is retried WITHOUT rebooting in between: the
    UVP6 must stay stopped so a retry can never format data acquired after
    the verified listing.

    Designed to run after the download+upload cycle has had time to finish
    (the scripts also hold a lock so they can never drive OctOS at the same
    time).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'common.ps1')

# ---------------------------
# Dashboard helpers
# ---------------------------

function Format-Duration {
    param([double]$Seconds)
    $ts = [TimeSpan]::FromSeconds([Math]::Round($Seconds))
    return "{0:D2}h{1:D2}m{2:D2}s" -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds
}

function Escape-Html {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Initialize-Dashboard {
    param([string]$LogDirectory)

    $runStamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:RunStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:RunStart = Get-Date
    $script:DashboardActions = New-Object System.Collections.Generic.List[object]
    $script:DashboardActive = @{}
    $script:DashboardJsonFile = Join-Path $LogDirectory ("cleanup_dashboard_" + $runStamp + ".json")
    $script:DashboardHtmlFile = Join-Path $LogDirectory ("cleanup_dashboard_" + $runStamp + ".html")
    $script:DashboardHistoryFile = Join-Path $LogDirectory "cleanup_history.json"

    # Load existing history entries (falls back to the pre-rename file once).
    $script:DashboardHistory = New-Object System.Collections.Generic.List[object]
    $legacyHistoryFile = Join-Path $LogDirectory "weekly_cleanup_history.json"
    $historySource = $null
    if (Test-Path $script:DashboardHistoryFile) { $historySource = $script:DashboardHistoryFile }
    elseif (Test-Path $legacyHistoryFile)       { $historySource = $legacyHistoryFile }
    if ($historySource) {
        try {
            $loaded = Get-Content $historySource -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($entry in $loaded) {
                $script:DashboardHistory.Add($entry)
            }
        } catch { <# ignore corrupt history #> }
    }
}

function Start-DashboardAction {
    param(
        [string]$Key,
        [string]$Label
    )

    $script:DashboardActive[$Key] = @{
        Label = $Label
        Start = Get-Date
    }
}

function Complete-DashboardAction {
    param(
        [string]$Key,
        [ValidateSet("OK", "WARN", "ERROR")]
        [string]$Status,
        [string]$Details = ""
    )

    if (-not $script:DashboardActive.ContainsKey($Key)) { return }

    $start = $script:DashboardActive[$Key].Start
    $end = Get-Date
    $durationSec = [Math]::Round((New-TimeSpan -Start $start -End $end).TotalSeconds, 1)
    $durationFmt = Format-Duration $durationSec

    $script:DashboardActions.Add([pscustomobject]@{
        Label = $script:DashboardActive[$Key].Label
        Start = $start.ToString("yyyy-MM-dd HH:mm:ss")
        End = $end.ToString("yyyy-MM-dd HH:mm:ss")
        DurationSec = $durationSec
        Duration = $durationFmt
        Status = $Status
        Details = $Details
    })

    $script:DashboardActive.Remove($Key) | Out-Null
    Write-DashboardFiles
}

function Write-DashboardFiles {
    if (-not $script:DashboardActions) { return }

    $script:DashboardActions | ConvertTo-Json -Depth 5 | Set-Content -Path $script:DashboardJsonFile -Encoding UTF8

    $rows = foreach ($a in $script:DashboardActions) {
        $css = if ($a.Status -eq "OK") { "ok" } elseif ($a.Status -eq "WARN") { "warn" } else { "err" }
        "<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td class='{4}'>{5}</td><td>{6}</td></tr>" -f `
            (Escape-Html $a.Label), (Escape-Html $a.Start), (Escape-Html $a.End), (Escape-Html $a.Duration), $css, (Escape-Html $a.Status), (Escape-Html $a.Details)
    }
    $rowsHtml = ($rows -join [Environment]::NewLine)
    $totalSec = if ($script:RunStopwatch) { $script:RunStopwatch.Elapsed.TotalSeconds } else { 0 }
    $totalFmt = Format-Duration $totalSec

    # History table
    $histRows = foreach ($h in ($script:DashboardHistory | Sort-Object RunStart -Descending)) {
        $css = if ($h.RunStatus -eq "OK") { "ok" } elseif ($h.RunStatus -eq "WARN") { "warn" } else { "err" }
        "<tr><td>{0}</td><td>{1}</td><td>{2}</td><td class='{3}'>{4}</td><td>{5}</td></tr>" -f `
            (Escape-Html $h.RunStart), (Escape-Html $h.TotalDuration), (Escape-Html ([string]$h.FileCount)), $css, (Escape-Html $h.RunStatus), (Escape-Html $h.Note)
    }
    $histHtml = if ($histRows) { $histRows -join [Environment]::NewLine } else { "<tr><td colspan='5'>No past runs yet.</td></tr>" }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>UVP6 Verify &amp; Cleanup Dashboard</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; background: #f4f6f8; color: #1f2937; }
.card { background: #fff; border-radius: 10px; padding: 16px; box-shadow: 0 1px 4px rgba(0,0,0,0.08); margin-bottom: 16px; }
h3 { margin: 0 0 10px 0; font-size: 15px; color: #374151; }
table { width: 100%; border-collapse: collapse; background: #fff; }
th, td { border-bottom: 1px solid #e5e7eb; text-align: left; padding: 8px; font-size: 13px; }
th { background: #f9fafb; }
.ok { color: #0f766e; font-weight: 700; }
.warn { color: #b45309; font-weight: 700; }
.err { color: #b91c1c; font-weight: 700; }
</style>
</head>
<body>
  <div class="card">
    <h2>UVP6 Verify &amp; Cleanup Dashboard</h2>
    <div><strong>Total elapsed:</strong> $totalFmt</div>
    <div><strong>Log file:</strong> $(Escape-Html $script:LogFile)</div>
    <div><strong>Generated:</strong> $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</div>
  </div>
  <div class="card">
    <h3>Current run</h3>
    <table>
      <thead>
        <tr>
          <th>Action</th><th>Start</th><th>End</th><th>Duration</th><th>Status</th><th>Details</th>
        </tr>
      </thead>
      <tbody>
        $rowsHtml
      </tbody>
    </table>
  </div>
  <div class="card">
    <h3>Past runs</h3>
    <table>
      <thead>
        <tr>
          <th>Run start</th><th>Total duration</th><th>Files</th><th>Status</th><th>Note</th>
        </tr>
      </thead>
      <tbody>
        $histHtml
      </tbody>
    </table>
  </div>
</body>
</html>
"@
    [System.IO.File]::WriteAllText($script:DashboardHtmlFile, $html, [System.Text.Encoding]::UTF8)
}

function Finalize-Dashboard {
    param([string]$RunStatus)

    foreach ($k in @($script:DashboardActive.Keys)) {
        Complete-DashboardAction -Key $k -Status "WARN" -Details "Action still active at end of run"
    }

    # Compute summary fields for history.
    $totalSec = if ($script:RunStopwatch) { $script:RunStopwatch.Elapsed.TotalSeconds } else { 0 }
    $fileCountAction = $script:DashboardActions | Where-Object { $_.Label -like 'Phase 2*' -and $_.Status -eq 'OK' } | Select-Object -First 1
    $fileCount = if ($fileCountAction -and $fileCountAction.Details -match '(\d+)') { [int]$Matches[1] } else { '' }

    $histEntry = [pscustomobject]@{
        RunStart      = if ($script:RunStart) { $script:RunStart.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        TotalDuration = Format-Duration $totalSec
        FileCount     = $fileCount
        RunStatus     = $RunStatus
        Note          = ""
        DashboardJson = $script:DashboardJsonFile
        DashboardHtml = $script:DashboardHtmlFile
    }
    $script:DashboardHistory.Add($histEntry)

    # Persist history.
    try {
        $script:DashboardHistory | ConvertTo-Json -Depth 5 | Set-Content -Path $script:DashboardHistoryFile -Encoding UTF8
    } catch { <# history write failure is non-fatal #> }

    Write-DashboardFiles

    if ($script:DashboardHtmlFile) { Write-Log "Dashboard: $script:DashboardHtmlFile" }
    if ($script:DashboardJsonFile) { Write-Log "Dashboard JSON: $script:DashboardJsonFile" }
    if ($script:DashboardHistoryFile) { Write-Log "History: $script:DashboardHistoryFile" }
}

function Exit-WithDashboard {
    param(
        [int]$Code,
        [string]$RunStatus
    )
    Finalize-Dashboard -RunStatus $RunStatus
    exit $Code
}

# ---- Helper: reboot UVP6 (fresh session) before exiting on error ----
# Called whenever the script must stop while the UVP6 may still be stopped.
# Uses script-scope variables set in Main.
function Invoke-RebootAndExit {
    param(
        [int]$ExitCode,
        [string]$RunStatus = "ABORT"
    )

    if ($script:needsReboot) {
        Write-Log ""
        Write-Log "Rebooting UVP6 to resume acquisition before exiting..."
        $rbLog = if ($script:OCTOS_LOG_EN) { Join-Path $script:logDir ("octos_output_cleanup_reboot_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log") } else { $null }
        $ok = Invoke-StandaloneReboot -OctOSExe $script:octosExe -WorkDir $script:OCTOS_DIR -Arguments $script:octosArgs -OutputLogPath $rbLog -WaitSecs $script:WAIT_SECS
        if ($ok) {
            $script:needsReboot = $false
        } else {
            Write-Log "UVP6 reboot could NOT be confirmed - the instrument may be stopped. Manual check required." "ERROR"
        }
    }

    Write-Log "================================================================="
    Write-Log "  UVP6 VERIFY & CLEANUP - End ($RunStatus)"
    Write-Log "================================================================="
    Exit-WithDashboard -Code $ExitCode -RunStatus $RunStatus
}

# ---------------------------
# Main
# ---------------------------

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile = Join-Path $scriptDir ".env"
$cfg = Load-EnvFile -Path $envFile

$OCTOS_DIR    = $cfg["OCTOS_DIR"]
$COM_PORT     = $cfg["COM_PORT"]
$UVP_IP       = $cfg["UVP_IP"]
$HOST_IP      = $cfg["HOST_IP"]
$BAUDRATE     = $cfg["BAUDRATE"]
$OCTOS_PORT   = $cfg["OCTOS_PORT"]
$WAIT_SECS    = if ($cfg["WAIT_BETWEEN_COMMANDS"]) { [int]$cfg["WAIT_BETWEEN_COMMANDS"] } else { 3 }
$SDLIST_TMO   = if ($cfg["SDLIST_TIMEOUT"])  { [int]$cfg["SDLIST_TIMEOUT"] }  else { 600 }
$SDDUMP_TMO   = if ($cfg["SDDUMP_TIMEOUT"])  { [int]$cfg["SDDUMP_TIMEOUT"] }  else { 14400 }
$SDFORMAT_TMO = if ($cfg["SDFORMAT_TIMEOUT"]){ [int]$cfg["SDFORMAT_TIMEOUT"]} else { 180 }
$DATA_WAIT    = if ($cfg["DATA_WAIT_TIMEOUT"]){ [int]$cfg["DATA_WAIT_TIMEOUT"]} else { 15 }
$MAX_RETRIES  = if ($cfg["MAX_RETRIES"])      { [int]$cfg["MAX_RETRIES"] }      else { 3 }
$RETRY_DELAY  = if ($cfg["RETRY_DELAY"])      { [int]$cfg["RETRY_DELAY"] }      else { 10 }
$SDLIST_SESSION_RETRIES = if ($cfg["SDLIST_SESSION_RETRIES"]) { [int]$cfg["SDLIST_SESSION_RETRIES"] } else { 10 }
$SDLIST_RETRY_DELAY     = if ($cfg["SDLIST_RETRY_DELAY"]) { [int]$cfg["SDLIST_RETRY_DELAY"] } else { 10 }
$MAX_DOWNLOAD_MINUTES   = if ($cfg["MAX_DOWNLOAD_MINUTES"]) { [int]$cfg["MAX_DOWNLOAD_MINUTES"] } else { 28 }
$SDDUMP_SESSION_RETRIES = if ($cfg["SDDUMP_SESSION_RETRIES"]) { [int]$cfg["SDDUMP_SESSION_RETRIES"] } else { 5 }
$OCTOS_LOG_EN = $cfg["OCTOS_OUTPUT_LOG"] -eq 'true'
$SFTP_HOST    = $cfg["SFTP_HOST"]
$SFTP_USER    = $cfg["SFTP_USER"]
$SFTP_PASS    = $cfg["SFTP_PASSWORD"]
$SFTP_REMOTE  = $cfg["SFTP_REMOTE_DIR"]
$SFTP_PORT    = if ($cfg["SFTP_PORT"]) { [int]$cfg["SFTP_PORT"] } else { 22 }

if (-not $OCTOS_DIR) { throw "OCTOS_DIR is not set in .env" }
$octosExe = Join-Path $OCTOS_DIR "bin\OctOS.exe"
if (-not (Test-Path $octosExe)) { throw "OctOS.exe not found: $octosExe" }

$logDir = Join-Path $OCTOS_DIR "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$script:LogFile = Join-Path $logDir ("cleanup_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")

Write-Log "================================================================="
Write-Log "  UVP6 VERIFY & CLEANUP - Start"
Write-Log "================================================================="
Write-Log "Configuration: COM$COM_PORT | Host=$HOST_IP | SFTP=$SFTP_HOST"

# Only one script may drive OctOS / the COM port at a time.
$lockFile = Join-Path $scriptDir "octos.lock"
if (-not (Enter-ScriptLock -LockFile $lockFile)) {
    Write-Log "Another automation script is already running (lock: $lockFile)." "ERROR"
    Write-Log "Nothing was formatted. This run will be retried at the next schedule." "ERROR"
    exit 1
}

try {
    Initialize-Dashboard -LogDirectory $logDir
    Write-Log "Dashboard will be generated at: $script:DashboardHtmlFile"

    # OctOS.exe launch args, positional order: COM HOST_IP UVP_IP BAUDRATE PORT
    # (HOST_IP = this computer, UVP_IP = the instrument - confirmed by OctOS's
    #  own "Host IP (this computer)=... / UVP6 IP=..." startup banner).
    $octosArgs = "$COM_PORT"
    if ($HOST_IP)    { $octosArgs += " $HOST_IP" }
    if ($UVP_IP)     { $octosArgs += " $UVP_IP" }
    if ($BAUDRATE)   { $octosArgs += " $BAUDRATE" }
    if ($OCTOS_PORT) { $octosArgs += " $OCTOS_PORT" }

    $filemanagerDir = Join-Path $OCTOS_DIR "filemanager"
    $treeFile = Join-Path $filemanagerDir "tree.txt"

    # Archive existing tree.txt before sdlist overwrites it.
    if (Test-Path $treeFile) {
        $archiveName = "tree_" + (Get-Date -Format "yyyyMMdd") + ".txt"
        $archiveFile = Join-Path $filemanagerDir $archiveName
        Copy-Item -Path $treeFile -Destination $archiveFile -Force
        Write-Log "Archived tree.txt -> $archiveName"
    }

    # Track whether we need to reboot UVP6 at the end (it stays stopped
    # from Phase 1 until we explicitly reboot in Phase 4 or on error).
    $needsReboot = $false

    # Any unexpected exception below is caught by this block so the UVP6 is
    # never left stopped (e.g. SFTP server unreachable, disk full, ...).
    try {

        # ============================================================
        # PHASE 1: Stop UVP6, sdlist, sddump (UVP6 stays stopped)
        # ============================================================
        Write-Log ""
        Write-Log "---- PHASE 1: Stop UVP6 + sdlist + sddump ----"
        Write-Log "UVP6 will stay stopped until Phase 4 completes."
        Start-DashboardAction -Key "phase1" -Label "Phase 1 - stop + sdlist + sddump"

        $phase1Success = $false

        # Per-step instrumentation for Invoke-OctOSDownloadAttempt: keeps the
        # dashboard rows (sdlist/sddump timings per attempt) and flips
        # needsReboot the moment the stop sequence is acknowledged.
        # $attempt resolves dynamically to the current loop iteration.
        $onStep = {
            param($Step, $Event, $Detail)
            switch ("$Step/$Event") {
                'stopped/ok'   { $script:needsReboot = $true }
                'sdlist/start' { Start-DashboardAction -Key "sdlist_attempt_$attempt" -Label "sdlist (attempt $attempt)" }
                'sdlist/ok'    { Complete-DashboardAction -Key "sdlist_attempt_$attempt" -Status "OK" }
                'sddump/start' { Start-DashboardAction -Key "sddump_attempt_$attempt" -Label "sddump (attempt $attempt)" }
                'sddump/ok'    { Complete-DashboardAction -Key "sddump_attempt_$attempt" -Status "OK" }
                'attempt/error' {
                    Complete-DashboardAction -Key "phase1_attempt_$attempt" -Status "ERROR" -Details $Detail
                    Complete-DashboardAction -Key "sdlist_attempt_$attempt" -Status "ERROR" -Details "Interrupted or timeout"
                    Complete-DashboardAction -Key "sddump_attempt_$attempt" -Status "ERROR" -Details "Interrupted or timeout"
                }
            }
        }

        $budgetReached = $false
        for ($attempt = 1; $attempt -le $MAX_RETRIES; $attempt++) {
            if ($attempt -gt 1) {
                Write-Log "  Retry $attempt/$MAX_RETRIES after ${RETRY_DELAY}s delay..." "WARN"
                Start-Sleep -Seconds $RETRY_DELAY
            }

            Start-DashboardAction -Key "phase1_attempt_$attempt" -Label "Phase 1 attempt $attempt"
            $octosLog = if ($OCTOS_LOG_EN) { Join-Path $logDir ("octos_output_cleanup_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log") } else { $null }

            # No -RebootAfter: OctOS quits but the UVP6 stays stopped for the
            # verification and format phases.
            $result = Invoke-OctOSDownloadAttempt `
                -OctOSExe $octosExe -WorkDir $OCTOS_DIR -Arguments $octosArgs -OutputLogPath $octosLog `
                -HostIp $HOST_IP -WaitSecs $WAIT_SECS -DataWaitTimeoutSec $DATA_WAIT `
                -SdlistTimeoutSec $SDLIST_TMO -SddumpTimeoutSec $SDDUMP_TMO `
                -SdlistInSessionRetries $SDLIST_SESSION_RETRIES `
                -SdlistRetryDelaySec $SDLIST_RETRY_DELAY `
                -SddumpInSessionRetries $SDDUMP_SESSION_RETRIES `
                -MaxDownloadMinutes $MAX_DOWNLOAD_MINUTES `
                -OnStep $onStep -FailureLabel "PHASE 1 attempt $attempt"

            if ($result.Success) {
                $phase1Success = $true
                Complete-DashboardAction -Key "phase1_attempt_$attempt" -Status "OK"
                break
            }
            if ($result.BudgetReached) {
                $budgetReached = $true
                Complete-DashboardAction -Key "phase1_attempt_$attempt" -Status "WARN" -Details "Time budget reached"
                break
            }
            # The attempt's safety reboot restarts acquisition; if it was
            # confirmed the instrument is no longer stopped.
            if ($result.SafetyRebootOk) { $needsReboot = $false }
        }

        if ($budgetReached) {
            Complete-DashboardAction -Key "phase1" -Status "WARN" -Details "Time budget reached - partial download, no format"
            Write-Log "Download time budget (${MAX_DOWNLOAD_MINUTES} min) reached - downloaded what we could; skipping verify/format this run." "WARN"
            Invoke-RebootAndExit 0 "BUDGET"
        }

        if (-not $phase1Success) {
            Complete-DashboardAction -Key "phase1" -Status "ERROR" -Details "Failed after retries"
            Write-Log "PHASE 1 FAILED after $MAX_RETRIES attempt(s)." "ERROR"
            Invoke-RebootAndExit 1 "ERROR"
        }
        Complete-DashboardAction -Key "phase1" -Status "OK"

        # ============================================================
        # PHASE 2: Verify all files exist locally
        # ============================================================
        Write-Log ""
        Write-Log "---- PHASE 2: Verify local files ----"
        Start-DashboardAction -Key "phase2" -Label "Phase 2 - verify local files"

        if (-not (Test-Path $treeFile)) {
            Complete-DashboardAction -Key "phase2" -Status "ERROR" -Details "tree.txt missing"
            Write-Log "tree.txt not found after sdlist - cannot verify." "ERROR"
            Invoke-RebootAndExit 1
        }

        $treeEntries = @(Get-Content $treeFile | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        Write-Log "SD card contains $($treeEntries.Count) file(s)."

        if ($treeEntries.Count -eq 0) {
            # A truncated or failed listing would look exactly like an empty SD
            # card, so never format on an empty listing.
            Complete-DashboardAction -Key "phase2" -Status "WARN" -Details "tree.txt is empty"
            Write-Log "tree.txt lists 0 files - nothing to verify, and a truncated listing" "WARN"
            Write-Log "would look identical. SD card will NOT be formatted." "WARN"
            Invoke-RebootAndExit 1 "WARN"
        }

        $missingLocal = @()
        foreach ($rel in $treeEntries) {
            $localPath = Join-Path $filemanagerDir $rel
            if (-not (Test-Path $localPath)) {
                $missingLocal += $rel
            }
        }

        if ($missingLocal.Count -gt 0) {
            Complete-DashboardAction -Key "phase2" -Status "ERROR" -Details "$($missingLocal.Count) local files missing"
            Write-Log "*** ABORT: $($missingLocal.Count) file(s) MISSING locally after sddump! ***" "ERROR"
            Write-Log "SD card will NOT be formatted to prevent data loss." "ERROR"
            foreach ($f in $missingLocal | Select-Object -First 50) {
                Write-Log "  MISSING LOCAL: $f" "ERROR"
            }
            if ($missingLocal.Count -gt 50) {
                Write-Log "  ... and $($missingLocal.Count - 50) more." "ERROR"
            }
            Write-Log "ACTION REQUIRED: Investigate sddump failures, then retry." "ERROR"
            Invoke-RebootAndExit 1
        }

        Write-Log "All $($treeEntries.Count) file(s) verified locally."
        Complete-DashboardAction -Key "phase2" -Status "OK" -Details "$($treeEntries.Count) files"

        # ============================================================
        # PHASE 3: Upload to SFTP + verify existence AND size on SFTP
        # ============================================================
        Write-Log ""
        Write-Log "---- PHASE 3: SFTP upload & verify ----"
        Start-DashboardAction -Key "phase3" -Label "Phase 3 - SFTP verify + upload"

        if (-not $SFTP_HOST -or -not $SFTP_USER) {
            Complete-DashboardAction -Key "phase3" -Status "ERROR" -Details "SFTP not configured"
            Write-Log "SFTP not configured - cannot verify." "ERROR"
            Write-Log "SD card will NOT be formatted without SFTP verification." "ERROR"
            Invoke-RebootAndExit 1
        }

        $remoteBase = if ($SFTP_REMOTE) { "/" + $SFTP_REMOTE.Trim('/').Replace('\', '/') } else { "" }

        $sftpSession = $null
        try {
            Write-Log "  Connecting to SFTP ${SFTP_HOST}:${SFTP_PORT} ..."
            $sftpSession = Open-SftpSession -Hostname $SFTP_HOST -User $SFTP_USER -Pass $SFTP_PASS -Port $SFTP_PORT
            Write-Log "  <- SFTP connected."

            # Build a full remote index in one recursive pass (one round-trip
            # per directory instead of one per file), then compare both
            # existence and size for every tree entry.
            Start-DashboardAction -Key "ftp_check" -Label "SFTP inventory + size check"
            $indexRoot = if ($remoteBase) { $remoteBase } else { "/" }
            Write-Log "  Building remote file index (recursive listing of '$indexRoot')..."
            $remoteIndex = Get-SftpFileIndex -Session $sftpSession -RootPath $indexRoot
            Write-Log "  Remote index built: $($remoteIndex.Count) file(s)."

            $missingFtp = @()
            $sizeMismatch = 0
            foreach ($rel in $treeEntries) {
                $remotePath = $remoteBase + "/" + ($rel.Replace('\', '/'))
                $localSize = (Get-Item -LiteralPath (Join-Path $filemanagerDir $rel)).Length
                if (-not $remoteIndex.ContainsKey($remotePath)) {
                    $missingFtp += $rel
                } elseif ($remoteIndex[$remotePath] -ne $localSize) {
                    $sizeMismatch++
                    Write-Log "  SIZE MISMATCH (remote $($remoteIndex[$remotePath]) vs local $localSize): $rel" "WARN"
                    $missingFtp += $rel
                }
            }
            Complete-DashboardAction -Key "ftp_check" -Status "OK" -Details "$($treeEntries.Count) checked, $($missingFtp.Count) to (re)upload, $sizeMismatch size mismatches"

            if ($missingFtp.Count -gt 0) {
                Write-Log "$($missingFtp.Count) file(s) missing or wrong size on SFTP - uploading now..."
                Start-DashboardAction -Key "ftp_upload" -Label "SFTP upload missing files"
                $uploadOk = 0
                $uploadFail = 0
                $uploadCount = 0
                foreach ($rel in $missingFtp) {
                    $localPath  = Join-Path $filemanagerDir $rel
                    $remoteRel  = $rel.Replace('\', '/')
                    $remotePath = "$remoteBase/$remoteRel"
                    if ($remoteRel -match '/') {
                        $parentDir = "$remoteBase/" + ($remoteRel -replace '/[^/]+$', '')
                        Ensure-SftpDirectory -Session $sftpSession -FullRemotePath $parentDir
                    }
                    try {
                        Upload-SftpFile -Session $sftpSession -LocalPath $localPath -RemotePath $remotePath
                        $uploadOk++
                    }
                    catch {
                        $uploadFail++
                        Write-Log "  UPLOAD FAILED: $rel - $($_.Exception.Message)" "ERROR"
                    }
                    $uploadCount++
                    if ($uploadCount % 50 -eq 0) {
                        Write-Log "  SFTP upload progress: $uploadCount / $($missingFtp.Count) ($uploadOk ok, $uploadFail failed)..."
                    }
                }
                Write-Log "SFTP upload: $uploadOk succeeded, $uploadFail failed."
                if ($uploadFail -gt 0) {
                    Complete-DashboardAction -Key "ftp_upload" -Status "ERROR" -Details "$uploadFail failed"
                    Complete-DashboardAction -Key "phase3" -Status "ERROR" -Details "SFTP upload failures"
                    Write-Log "*** ABORT: $uploadFail file(s) could not be uploaded to SFTP ***" "ERROR"
                    Write-Log "SD card will NOT be formatted to prevent data loss." "ERROR"
                    Invoke-RebootAndExit 1
                }
                Complete-DashboardAction -Key "ftp_upload" -Status "OK" -Details "$uploadOk uploaded"

                # Re-verify the uploaded files actually exist on SFTP with the right size.
                Write-Log "Re-verifying $($missingFtp.Count) uploaded file(s) on SFTP..."
                Start-DashboardAction -Key "ftp_reverify" -Label "SFTP re-verify uploaded files"
                $stillMissing = @()
                $verifyCount = 0
                foreach ($rel in $missingFtp) {
                    $remotePath = $remoteBase + "/" + ($rel.Replace('\', '/'))
                    $localSize  = (Get-Item -LiteralPath (Join-Path $filemanagerDir $rel)).Length
                    $remoteSize = Get-SftpRemoteSize -Session $sftpSession -RemotePath $remotePath
                    if ($remoteSize -lt 0 -or $remoteSize -ne $localSize) { $stillMissing += $rel }
                    $verifyCount++
                    if ($verifyCount % 100 -eq 0) {
                        Write-Log "  SFTP re-verify progress: $verifyCount / $($missingFtp.Count)..."
                    }
                }
                if ($stillMissing.Count -gt 0) {
                    Complete-DashboardAction -Key "ftp_reverify" -Status "ERROR" -Details "$($stillMissing.Count) still missing/mismatched"
                    Complete-DashboardAction -Key "phase3" -Status "ERROR" -Details "Files still missing after upload"
                    Write-Log "*** ABORT: $($stillMissing.Count) file(s) still missing or wrong size on SFTP after upload ***" "ERROR"
                    foreach ($f in $stillMissing | Select-Object -First 20) {
                        Write-Log "  STILL MISSING: $f" "ERROR"
                    }
                    Invoke-RebootAndExit 1
                }
                Complete-DashboardAction -Key "ftp_reverify" -Status "OK"
            }

            # Upload all tree listings (tree.txt, tree_YYYYMMDD.txt) - always overwrite with latest.
            Write-Log "  Uploading tree files..."
            $treeFiles = Get-ChildItem -Path $filemanagerDir -Filter 'tree*.txt' -File -ErrorAction SilentlyContinue
            foreach ($tf in $treeFiles) {
                $remotePath = "$remoteBase/$($tf.Name)"
                try {
                    Upload-SftpFile -Session $sftpSession -LocalPath $tf.FullName -RemotePath $remotePath
                    Write-Log "  Uploaded tree file: $($tf.Name)"
                }
                catch {
                    Write-Log "  FAILED tree file: $($tf.Name) - $($_.Exception.Message)" "WARN"
                }
            }

            Write-Log "All $($treeEntries.Count) file(s) verified on SFTP (existence + size)."
            Complete-DashboardAction -Key "phase3" -Status "OK" -Details "$($treeEntries.Count) files"
        }
        finally {
            if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession | Out-Null }
        }

        # ============================================================
        # PHASE 4: All verified - format SD card, then reboot
        # ============================================================
        Write-Log ""
        Write-Log "---- PHASE 4: SD format (all files verified) ----"
        Write-Log "VERIFIED: $($treeEntries.Count) files present locally AND on SFTP."
        Write-Log "Proceeding with sdformat..."
        Start-DashboardAction -Key "phase4" -Label "Phase 4 - sdformat + reboot"

        $success = $false
        for ($attempt = 1; $attempt -le $MAX_RETRIES; $attempt++) {
            if ($attempt -gt 1) {
                Write-Log "  Retry $attempt/$MAX_RETRIES after ${RETRY_DELAY}s delay..." "WARN"
                Start-Sleep -Seconds $RETRY_DELAY
            }

            $session = $null
            try {
                Start-DashboardAction -Key "phase4_attempt_$attempt" -Label "Phase 4 attempt $attempt"
                $octosLog2 = if ($OCTOS_LOG_EN) { Join-Path $logDir ("octos_output_cleanup_format_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log") } else { $null }
                $session = Start-OctOSSession -OctOSExe $octosExe -WorkDir $OCTOS_DIR -Arguments $octosArgs -OutputLogPath $octosLog2
                Write-Log "  OctOS PID: $($session.ProcessId)"

                # UVP6 is still stopped from Phase 1 (it never restarts by
                # itself) - no data check or stop sequence needed here.
                Write-Log "  .. Waiting for OctOS ready ([ME]:)..."
                $ready = Wait-ForMarker -Session $session -MarkerRegex '\[ME\]:' -TimeoutSec 120
                if (-not $ready) { throw "OctOS never became ready." }
                Write-Log "  <- OctOS is ready."
                $session.WriteLine("")

                # sdformat with interactive confirmation.
                Start-Sleep -Seconds $WAIT_SECS
                Start-DashboardAction -Key "sdformat_attempt_$attempt" -Label "sdformat (attempt $attempt)"
                $mark = $session.GetOutputLength()
                $session.WriteLine("sdformat")
                Write-Log "  -> Sent: sdformat"

                Write-Log "  .. Waiting for confirmation prompt..."
                $match = Wait-ForMarkerCapture -Session $session -MarkerRegex 'Enter code (\d+)\s*to proceed' -TimeoutSec 120 -FromOffset $mark
                if (-not $match) { throw "Timeout waiting for sdformat confirmation prompt." }
                $confirmCode = $match[1]
                Write-Log "  <- Confirmation code: $confirmCode"

                Start-Sleep -Seconds $WAIT_SECS
                $mark = $session.GetOutputLength()
                $session.WriteLine($confirmCode)
                Write-Log "  -> Sent confirmation code: $confirmCode"

                Write-Log "  .. Waiting for format to complete (timeout ${SDFORMAT_TMO}s)..."
                $ok = Wait-ForMarker -Session $session -MarkerRegex 'Storage capacity in Mb' -TimeoutSec $SDFORMAT_TMO -FromOffset $mark
                if (-not $ok) { throw "Timeout waiting for sdformat to complete." }
                Write-Log "  <- SD format completed."
                Complete-DashboardAction -Key "sdformat_attempt_$attempt" -Status "OK"

                # Now reboot to resume acquisition.
                Start-Sleep -Seconds $WAIT_SECS
                Start-DashboardAction -Key "reboot_after_format_attempt_$attempt" -Label "reboot after format (attempt $attempt)"
                $mark = $session.GetOutputLength()
                $session.WriteLine("reboot")
                Write-Log "  -> Sent: reboot"
                $ok = Wait-ForMarker -Session $session -MarkerRegex '(\$startack;|HW_CONF,)' -TimeoutSec 180 -FromOffset $mark
                if (-not $ok) { throw "Timeout waiting for reboot confirmation after format." }
                Write-Log "  <- Reboot confirmed - UVP6 resumed."
                Complete-DashboardAction -Key "reboot_after_format_attempt_$attempt" -Status "OK"
                $needsReboot = $false

                Start-Sleep -Seconds $WAIT_SECS
                $session.WriteLine("quit")
                Write-Log "  -> Sent: quit"
                $session.WaitForExit(30000) | Out-Null

                $success = $true
                Complete-DashboardAction -Key "phase4_attempt_$attempt" -Status "OK"
                break
            }
            catch {
                Write-Log "PHASE 4 attempt $attempt FAILED: $_" "ERROR"
                Complete-DashboardAction -Key "phase4_attempt_$attempt" -Status "ERROR" -Details "$_"
                Complete-DashboardAction -Key "sdformat_attempt_$attempt" -Status "ERROR" -Details "Interrupted or timeout"
                Complete-DashboardAction -Key "reboot_after_format_attempt_$attempt" -Status "ERROR" -Details "Interrupted or timeout"
                # Deliberately NO reboot between attempts: the UVP6 must stay
                # stopped so a retry can never format data acquired after the
                # verified listing. The final reboot happens below.
            }
            finally {
                Close-OctOSSession -Session $session
                $session = $null
            }
        }

        if ($success) {
            Complete-DashboardAction -Key "phase4" -Status "OK"

            # ============================================================
            # PHASE 5: Clean local filemanager/ (SD card is now empty)
            # ============================================================
            Write-Log ""
            Write-Log "---- PHASE 5: Clean local filemanager/ ----"
            Start-DashboardAction -Key "phase5" -Label "Phase 5 - clean local filemanager"

            $cleanedCount = 0
            $cleanFailCount = 0
            foreach ($rel in $treeEntries) {
                $localPath = Join-Path $filemanagerDir $rel
                # Skip tree files - they are kept for history/reference.
                if ([System.IO.Path]::GetFileName($localPath) -like 'tree*.txt') { continue }
                if (Test-Path $localPath) {
                    try {
                        Remove-Item -Path $localPath -Force
                        $cleanedCount++
                    } catch {
                        Write-Log "  Failed to delete: $rel - $_" "WARN"
                        $cleanFailCount++
                    }
                }
            }

            # Remove any empty subdirectories left behind.
            Get-ChildItem -Path $filemanagerDir -Directory -Recurse |
                Sort-Object -Property FullName -Descending |
                Where-Object { -not (Get-ChildItem -Path $_.FullName -Recurse -File) } |
                ForEach-Object {
                    try { Remove-Item -Path $_.FullName -Force } catch {}
                }

            Write-Log "Local cleanup: $cleanedCount file(s) deleted, $cleanFailCount failed."
            if ($cleanFailCount -gt 0) {
                Complete-DashboardAction -Key "phase5" -Status "WARN" -Details "$cleanedCount deleted, $cleanFailCount failed"
            } else {
                Complete-DashboardAction -Key "phase5" -Status "OK" -Details "$cleanedCount files deleted"
            }

            Write-Log ""
            Write-Log "SUMMARY: $($treeEntries.Count) files verified, SD card formatted, $cleanedCount local files cleaned."
            Write-Log "Log: $script:LogFile"
            Write-Log "================================================================="
            Write-Log "  UVP6 VERIFY & CLEANUP - End (OK)"
            Write-Log "================================================================="
            Exit-WithDashboard -Code 0 -RunStatus "OK"
        }

        Complete-DashboardAction -Key "phase4" -Status "ERROR" -Details "Failed after retries"
        Write-Log "PHASE 4 FAILED after $MAX_RETRIES attempt(s) - SD card state unknown, rebooting." "ERROR"
        Write-Log "Log: $script:LogFile"
        Invoke-RebootAndExit 1 "ERROR"
    }
    catch {
        # Unexpected exception (network drop, disk full, ...): make sure the
        # UVP6 is not left stopped, then exit with an ERROR dashboard.
        Write-Log "FATAL: unexpected error: $_" "ERROR"
        Write-Log ($_.ScriptStackTrace | Out-String) "ERROR"
        Invoke-RebootAndExit 1 "ERROR"
    }
}
finally {
    Exit-ScriptLock -LockFile $lockFile
}
