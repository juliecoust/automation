<#
.SYNOPSIS
    UVP6 download via OctOS (schedule-agnostic; run it as often as needed).

.DESCRIPTION
    Runs one OctOS session with strict sequential commands:
    1) $stop; (x3, wait for $stopack;)
    2) sdlist <HOST_IP> (wait for [SDLIST]: EXIT)
    3) sddump tree.txt (wait for [SDDUMP]: EXIT)
    4) reboot (wait for $startack; or HW_CONF)
    5) quit

    Each step runs only if the previous one succeeds. On failure the script
    always tries to reboot the UVP6 so acquisition resumes (the instrument
    never restarts acquisition by itself after a $stop;).

    Run sftp_upload.ps1 afterwards to push the newly downloaded files
    (download_and_upload.bat chains both).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'common.ps1')

# ---------------------------
# Main
# ---------------------------

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile   = Join-Path $scriptDir ".env"
$cfg       = Load-EnvFile -Path $envFile

$OCTOS_DIR    = $cfg["OCTOS_DIR"]
$COM_PORT     = $cfg["COM_PORT"]
$UVP_IP       = $cfg["UVP_IP"]
$HOST_IP      = $cfg["HOST_IP"]
$BAUDRATE     = $cfg["BAUDRATE"]
$OCTOS_PORT   = $cfg["OCTOS_PORT"]
$WAIT_SECS    = if ($cfg["WAIT_BETWEEN_COMMANDS"]) { [int]$cfg["WAIT_BETWEEN_COMMANDS"] } else { 3 }
$SDLIST_TMO   = if ($cfg["SDLIST_TIMEOUT"])  { [int]$cfg["SDLIST_TIMEOUT"] }  else { 600 }
$SDDUMP_TMO   = if ($cfg["SDDUMP_TIMEOUT"])  { [int]$cfg["SDDUMP_TIMEOUT"] }  else { 3600 }
$DATA_WAIT    = if ($cfg["DATA_WAIT_TIMEOUT"]) { [int]$cfg["DATA_WAIT_TIMEOUT"] } else { 15 }
$MAX_RETRIES  = if ($cfg["MAX_RETRIES"])  { [int]$cfg["MAX_RETRIES"] }  else { 3 }
$RETRY_DELAY  = if ($cfg["RETRY_DELAY"])  { [int]$cfg["RETRY_DELAY"] }  else { 10 }
$SDLIST_SESSION_RETRIES = if ($cfg["SDLIST_SESSION_RETRIES"]) { [int]$cfg["SDLIST_SESSION_RETRIES"] } else { 10 }
$SDLIST_RETRY_DELAY     = if ($cfg["SDLIST_RETRY_DELAY"]) { [int]$cfg["SDLIST_RETRY_DELAY"] } else { 10 }
$MAX_DOWNLOAD_MINUTES   = if ($cfg["MAX_DOWNLOAD_MINUTES"]) { [int]$cfg["MAX_DOWNLOAD_MINUTES"] } else { 28 }
$SDDUMP_SESSION_RETRIES = if ($cfg["SDDUMP_SESSION_RETRIES"]) { [int]$cfg["SDDUMP_SESSION_RETRIES"] } else { 5 }
$OCTOS_LOG_EN = $cfg["OCTOS_OUTPUT_LOG"] -eq 'true'

if (-not $OCTOS_DIR) { throw "OCTOS_DIR is not set in .env" }
$octosExe = Join-Path $OCTOS_DIR "bin\OctOS.exe"
if (-not (Test-Path $octosExe)) { throw "OctOS.exe not found: $octosExe" }

$logDir = Join-Path $OCTOS_DIR "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$script:LogFile = Join-Path $logDir ("download_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")

Write-Log "================================================================="
Write-Log "  UVP6 DOWNLOAD - Start"
Write-Log "================================================================="
Write-Log "Configuration: COM$COM_PORT | Host=$HOST_IP"

# Only one script may drive OctOS / the COM port at a time.
$lockFile = Join-Path $scriptDir "octos.lock"
if (-not (Enter-ScriptLock -LockFile $lockFile)) {
    Write-Log "Another automation script is already running (lock: $lockFile). Exiting." "ERROR"
    exit 1
}

try {
    # OctOS.exe launch args, positional order: COM HOST_IP UVP_IP BAUDRATE PORT
    # (HOST_IP = this computer, UVP_IP = the instrument - confirmed by OctOS's
    #  own "Host IP (this computer)=... / UVP6 IP=..." startup banner).
    $octosArgs = "$COM_PORT"
    if ($HOST_IP)    { $octosArgs += " $HOST_IP" }
    if ($UVP_IP)     { $octosArgs += " $UVP_IP" }
    if ($BAUDRATE)   { $octosArgs += " $BAUDRATE" }
    if ($OCTOS_PORT) { $octosArgs += " $OCTOS_PORT" }

    # Rotate tree files before sdlist writes a new one.
    # previous_tree.txt is the baseline sftp_upload.ps1 diffs against.
    $filemanagerDir = Join-Path $OCTOS_DIR "filemanager"
    $treeFile       = Join-Path $filemanagerDir "tree.txt"
    $prevTreeFile   = Join-Path $filemanagerDir "previous_tree.txt"
    if (Test-Path $treeFile) {
        $archiveName = "tree_" + (Get-Date -Format "yyyyMMdd") + ".txt"
        $archiveFile = Join-Path $filemanagerDir $archiveName
        Copy-Item -Path $treeFile -Destination $archiveFile -Force
        Write-Log "Archived tree.txt -> $archiveName"
        if (Test-Path $prevTreeFile) { Remove-Item $prevTreeFile -Force }
        Rename-Item -Path $treeFile -NewName "previous_tree.txt"
        Write-Log "Renamed tree.txt -> previous_tree.txt"
    }

    $success = $false
    $lastRebootOk = $false
    $budgetReached = $false

    for ($attempt = 1; $attempt -le $MAX_RETRIES; $attempt++) {
        if ($attempt -gt 1) {
            Write-Log "Retry $attempt/$MAX_RETRIES after ${RETRY_DELAY}s..." "WARN"
            Start-Sleep -Seconds $RETRY_DELAY
        }

        $octosLog = if ($OCTOS_LOG_EN) {
            Join-Path $logDir ("octos_output_download_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
        } else { $null }

        $result = Invoke-OctOSDownloadAttempt `
            -OctOSExe $octosExe -WorkDir $OCTOS_DIR -Arguments $octosArgs -OutputLogPath $octosLog `
            -HostIp $HOST_IP -WaitSecs $WAIT_SECS -DataWaitTimeoutSec $DATA_WAIT `
            -SdlistTimeoutSec $SDLIST_TMO -SddumpTimeoutSec $SDDUMP_TMO `
            -SdlistInSessionRetries $SDLIST_SESSION_RETRIES `
            -SdlistRetryDelaySec $SDLIST_RETRY_DELAY `
            -SddumpInSessionRetries $SDDUMP_SESSION_RETRIES `
            -MaxDownloadMinutes $MAX_DOWNLOAD_MINUTES `
            -RebootAfter -FailureLabel "Attempt $attempt"

        if ($result.Success) {
            $success = $true
            break
        }
        if ($result.BudgetReached) {
            $budgetReached = $true
            break
        }
        $lastRebootOk = $result.SafetyRebootOk
    }

    if ($budgetReached) {
        Write-Log "Download time budget (${MAX_DOWNLOAD_MINUTES} min) reached - stopped cleanly, UVP6 rebooted. Progress saved; will continue next run."
        Write-Log "================================================================="
        Write-Log "  UVP6 DOWNLOAD - End (BUDGET)"
        Write-Log "================================================================="
        exit 0
    }

    if (-not $success) {
        if (-not $lastRebootOk) {
            # The in-session safety reboot was not confirmed: try once more with
            # a fresh session so the instrument is not left stopped.
            Write-Log "Safety reboot was not confirmed - trying a standalone reboot session..." "WARN"
            $rbLog = if ($OCTOS_LOG_EN) { Join-Path $logDir ("octos_output_download_reboot_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log") } else { $null }
            $lastRebootOk = Invoke-StandaloneReboot -OctOSExe $octosExe -WorkDir $OCTOS_DIR -Arguments $octosArgs -OutputLogPath $rbLog -WaitSecs $WAIT_SECS
            if (-not $lastRebootOk) {
                Write-Log "UVP6 reboot could NOT be confirmed - the instrument may be stopped. Manual check required." "ERROR"
            }
        }
        Write-Log "Download failed after $MAX_RETRIES attempt(s)." "ERROR"
        Write-Log "================================================================="
        Write-Log "  UVP6 DOWNLOAD - End (ERROR)"
        Write-Log "================================================================="
        exit 1
    }

    Write-Log "Download completed successfully."
    Write-Log "================================================================="
    Write-Log "  UVP6 DOWNLOAD - End (OK)"
    Write-Log "================================================================="
    exit 0
}
finally {
    Exit-ScriptLock -LockFile $lockFile
}
