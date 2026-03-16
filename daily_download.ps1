<#
.SYNOPSIS
    Daily download of new UVP6 data via OctOS.

.DESCRIPTION
    This script automates the manual data retrieval procedure:
      1. Stop the acquisition ($stop;)
      2. Update the file listing (sdlist → tree.txt)
      3. Compare tree.txt with files already downloaded locally
      4. Download only new files (sddump)
      5. Reboot the UVP6 (reboot)

    All configuration is read from the .env file located next to this script.
    A timestamped log is created in the logs/ subfolder on each run.

.NOTES
    Schedule with Windows Task Scheduler for daily execution.
    Command: powershell -ExecutionPolicy Bypass -File "C:\...\daily_download.ps1"
#>

# ============================================================
#  Utility functions
# ============================================================

function Load-EnvFile {
    <# Loads a .env file (KEY=VALUE) into a hashtable #>
    param([string]$Path)
    $config = @{}
    if (-not (Test-Path $Path)) {
        throw "Configuration file not found: $Path"
    }
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            if ($line -match '^([^=]+)=(.*)$') {
                $config[$matches[1].Trim()] = $matches[2].Trim()
            }
        }
    }
    return $config
}

function Write-Log {
    <# Writes a timestamped message to both the console and the log file #>
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    }
}

function Append-HistoryCSV {
    <# Appends a row to the CSV history file for daily tracking #>
    param(
        [string]$CsvPath,
        [string]$Status,         # OK | PARTIAL | ERROR | NO_NEW_DATA
        [int]$TotalRemote    = 0,
        [int]$NewDetected    = 0,
        [int]$Downloaded     = 0,
        [int]$Failed         = 0,
        [int]$NewAcquisitions= 0,
        [string]$ErrorMsg    = "",
        [string]$LogFile     = ""
    )

    $needsHeader = -not (Test-Path $CsvPath)

    $row = [PSCustomObject]@{
        Date             = Get-Date -Format "yyyy-MM-dd"
        Time             = Get-Date -Format "HH:mm:ss"
        Status           = $Status
        SD_Files         = $TotalRemote
        New              = $NewDetected
        Downloaded       = $Downloaded
        Failed           = $Failed
        New_Acquisitions = $NewAcquisitions
        Error            = $ErrorMsg
        Log              = $LogFile
    }

    if ($needsHeader) {
        $row | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Append
    } else {
        $row | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Append
    }
}

function Update-StatusFile {
    <# Updates a quick-glance status.txt file #>
    param(
        [string]$StatusPath,
        [string]$Status,
        [int]$TotalRemote    = 0,
        [int]$NewDetected    = 0,
        [int]$Downloaded     = 0,
        [int]$Failed         = 0,
        [int]$NewAcquisitions= 0,
        [string]$NextRun     = "",
        [string]$ErrorMsg    = "",
        [string]$LogFile     = ""
    )

    $statusIcon = switch ($Status) {
        "OK"          { "[OK]" }
        "NO_NEW_DATA" { "[OK]" }
        "PARTIAL"     { "[!!]" }
        "ERROR"       { "[XX]" }
        default       { "[??]" }
    }

    $content = @"
========================================
  UVP6 — DOWNLOAD STATUS
========================================
Last run       : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Status         : $statusIcon $Status

SD files       : $TotalRemote
New            : $NewDetected
Downloaded     : $Downloaded
Failed         : $Failed
Acquisitions   : $NewAcquisitions new

Last log       : $LogFile
"@

    if ($ErrorMsg) {
        $content += "`nError          : $ErrorMsg"
    }

    $content += "`n========================================`n"

    Set-Content -Path $StatusPath -Value $content -Encoding UTF8
}

function Send-EmailNotification {
    <# Sends an email notification if SMTP config is provided #>
    param(
        [hashtable]$Config,
        [string]$Subject,
        [string]$Body,
        [string]$Status
    )

    $server = $Config["SMTP_SERVER"]
    $to     = $Config["EMAIL_TO"]
    if (-not $server -or -not $to) { return }  # Not configured → skip

    # If "email only on error" and no error, don't send
    $onlyOnError = $Config["EMAIL_ONLY_ON_ERROR"]
    if ($onlyOnError -eq "true" -and $Status -in @("OK", "NO_NEW_DATA")) { return }

    try {
        $from = $Config["EMAIL_FROM"]
        $port = [int]$Config["SMTP_PORT"]
        $user = $Config["SMTP_USER"]
        $pass = $Config["SMTP_PASSWORD"]

        $smtpParams = @{
            From       = $from
            To         = $to
            Subject    = $Subject
            Body       = $Body
            SmtpServer = $server
            Port       = $port
        }

        if ($user -and $pass) {
            $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential($user, $secPass)
            $smtpParams["Credential"] = $cred
            $smtpParams["UseSsl"]     = $true
        }

        Send-MailMessage @smtpParams
        Write-Log "Notification email sent to $to"
    }
    catch {
        Write-Log "Failed to send email: $_" "WARN"
    }
}

function Generate-HTMLDashboard {
    <# Generates a mini HTML dashboard from the CSV history #>
    param(
        [string]$CsvPath,
        [string]$HtmlPath,
        [int]$MaxRows = 60
    )

    if (-not (Test-Path $CsvPath)) { return }

    $data = Import-Csv -Path $CsvPath -Encoding UTF8 | Select-Object -Last $MaxRows

    # Build HTML table rows
    $tableRows = ""
    foreach ($row in ($data | Sort-Object { $_.'Date' + ' ' + $_.'Time' } -Descending)) {
        $statusClass = switch ($row.Status) {
            "OK"          { "ok" }
            "NO_NEW_DATA" { "ok" }
            "PARTIAL"     { "warn" }
            "ERROR"       { "error" }
            default       { "" }
        }
        $tableRows += @"
        <tr class=""$statusClass"">
            <td>$($row.Date)</td>
            <td>$($row.Time)</td>
            <td class=""status"">$($row.Status)</td>
            <td>$($row.SD_Files)</td>
            <td>$($row.New)</td>
            <td>$($row.Downloaded)</td>
            <td>$($row.Failed)</td>
            <td>$($row.New_Acquisitions)</td>
            <td class=""error-msg"">$($row.Error)</td>
        </tr>`n
"@
    }

    # Compute stats for the last 7 days
    $last7 = $data | Select-Object -Last 7
    $totalDownloaded7d = ($last7 | Measure-Object -Property Downloaded -Sum).Sum
    $totalFailed7d     = ($last7 | Measure-Object -Property Failed -Sum).Sum
    $totalNewAcq7d     = ($last7 | Measure-Object -Property New_Acquisitions -Sum).Sum
    $errorDays7d       = ($last7 | Where-Object { $_.Status -in @("ERROR","PARTIAL") }).Count

    $html = @"
<!DOCTYPE html>
<html lang=""en"">
<head>
    <meta charset=""UTF-8"">
    <meta http-equiv=""refresh"" content=""300"">
    <title>UVP6 — Download Monitoring</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Segoe UI', Arial, sans-serif; background: #f0f2f5; color: #333; padding: 20px; }
        h1 { text-align: center; color: #2c3e50; margin-bottom: 10px; }
        .subtitle { text-align: center; color: #7f8c8d; margin-bottom: 25px; font-size: 0.9em; }
        .cards { display: flex; gap: 15px; justify-content: center; flex-wrap: wrap; margin-bottom: 25px; }
        .card { background: #fff; border-radius: 10px; padding: 18px 25px; min-width: 160px;
                text-align: center; box-shadow: 0 2px 8px rgba(0,0,0,0.08); }
        .card .value { font-size: 2em; font-weight: bold; color: #2c3e50; }
        .card .label { font-size: 0.85em; color: #95a5a6; margin-top: 4px; }
        .card.alert .value { color: #e74c3c; }
        table { width: 100%; border-collapse: collapse; background: #fff; border-radius: 10px;
                overflow: hidden; box-shadow: 0 2px 8px rgba(0,0,0,0.08); }
        th { background: #2c3e50; color: #fff; padding: 10px; font-size: 0.85em; text-align: left; }
        td { padding: 8px 10px; font-size: 0.85em; border-bottom: 1px solid #ecf0f1; }
        tr:hover { background: #f7f9fc; }
        tr.ok .status { color: #27ae60; font-weight: bold; }
        tr.warn .status { color: #f39c12; font-weight: bold; }
        tr.error { background: #fdf0f0; }
        tr.error .status { color: #e74c3c; font-weight: bold; }
        .error-msg { color: #e74c3c; font-size: 0.8em; max-width: 250px; word-break: break-word; }
        footer { text-align: center; margin-top: 20px; color: #bdc3c7; font-size: 0.8em; }
    </style>
</head>
<body>
    <h1>UVP6 — Download Monitoring</h1>
    <p class=""subtitle"">Updated: $(Get-Date -Format "yyyy-MM-dd HH:mm") — Auto-refresh every 5 min</p>

    <div class=""cards"">
        <div class=""card""><div class=""value"">$totalDownloaded7d</div><div class=""label"">Files (7d)</div></div>
        <div class=""card""><div class=""value"">$totalNewAcq7d</div><div class=""label"">Acquisitions (7d)</div></div>
        <div class=""card $(if($totalFailed7d -gt 0){'alert'})""><div class=""value"">$totalFailed7d</div><div class=""label"">Failed (7d)</div></div>
        <div class=""card $(if($errorDays7d -gt 0){'alert'})""><div class=""value"">$errorDays7d</div><div class=""label"">Error days (7d)</div></div>
    </div>

    <table>
        <thead>
            <tr>
                <th>Date</th><th>Time</th><th>Status</th><th>SD Files</th>
                <th>New</th><th>Downloaded</th><th>Failed</th>
                <th>Acquisitions</th><th>Error</th>
            </tr>
        </thead>
        <tbody>
$tableRows
        </tbody>
    </table>
    <footer>Generated by daily_download.ps1</footer>
</body>
</html>
"@

    Set-Content -Path $HtmlPath -Value $html -Encoding UTF8
    Write-Log "HTML dashboard updated: $HtmlPath"
}

function Test-ComPortAvailable {
    <# Validates that a COM port is accessible before use #>
    param(
        [string]$PortNumber,      # e.g. "3" for COM3
        [int]$Baudrate,
        [int]$TimeoutMs = 1000
    )
    
    $portName = "COM$PortNumber"
    Write-Log "Validating COM port: $portName (baudrate: $Baudrate)..."
    
    try {
        $serial = New-Object System.IO.Ports.SerialPort
        $serial.PortName = $portName
        $serial.BaudRate = $Baudrate
        $serial.Parity = "None"
        $serial.DataBits = 8
        $serial.StopBits = "One"
        $serial.ReadTimeout = $TimeoutMs
        $serial.WriteTimeout = $TimeoutMs
        
        $serial.Open()
        $isOpen = $serial.IsOpen
        
        if ($isOpen) {
            Write-Log "✓ COM port $portName is accessible" "INFO"
        }
        
        $serial.Close()
        return $isOpen
    }
    catch {
        Write-Log "✗ COM port $portName validation failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Cleanup-OldLogs {
    <# Deletes log files older than $RetentionDays days #>
    param([string]$LogDir, [int]$RetentionDays = 90)
    if ($RetentionDays -le 0 -or -not (Test-Path $LogDir)) { return }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -Path $LogDir -Filter "download_*.log" | Where-Object { $_.LastWriteTime -lt $cutoff } | ForEach-Object {
        Write-Log "Deleting old log: $($_.Name)"
        Remove-Item $_.FullName -Force
    }
}

function Send-OctOSCommands {
    <#
    .SYNOPSIS
        Launches OctOS.exe and sends a sequence of commands via stdin.
    .DESCRIPTION
        Creates a temporary file containing the commands (one per line),
        then redirects this file to OctOS.exe's standard input.
        Waits for the process to finish or timeout.
    .NOTES
        If OctOS.exe does not accept stdin (uses Console API),
        see the "Alternative" section at the end of this script
        for a direct serial port approach (Python/pyserial).
    #>
    param(
        [string]$OctOSExe,
        [string]$WorkDir,
        [string]$Arguments,
        [string[]]$Commands,
        [int]$TimeoutSeconds = 300,
        [int]$DelayBetweenCmds = 3
    )

    # Create temporary command file
    $cmdFile = Join-Path $env:TEMP "octos_cmds_$((Get-Date).Ticks).txt"
    $Commands | Set-Content -Path $cmdFile -Encoding ASCII
    Write-Log "Command file: $cmdFile"
    Write-Log "Commands: $($Commands -join ' → ')"

    try {
        # Configure the process
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $OctOSExe
        $psi.Arguments = $Arguments
        $psi.WorkingDirectory = $WorkDir
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi

        # Capture output asynchronously to avoid deadlocks
        $outBuilder = New-Object System.Text.StringBuilder
        $errBuilder = New-Object System.Text.StringBuilder

        $outEvent = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action {
            if ($EventArgs.Data) { $Event.MessageData.AppendLine($EventArgs.Data) | Out-Null }
        } -MessageData $outBuilder

        $errEvent = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action {
            if ($EventArgs.Data) { $Event.MessageData.AppendLine($EventArgs.Data) | Out-Null }
        } -MessageData $errBuilder

        Write-Log "Launching OctOS.exe $Arguments ..."
        $process.Start() | Out-Null
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()

        # Send commands one by one with delay
        foreach ($cmd in $Commands) {
            Start-Sleep -Seconds $DelayBetweenCmds
            $process.StandardInput.WriteLine($cmd)
            Write-Log "  → Sent: $cmd"
        }
        $process.StandardInput.Close()

        # Wait for process to finish
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Write-Log "TIMEOUT: OctOS did not finish after $TimeoutSeconds s" "WARN"
            $process.Kill()
            return $false
        }

        # Retrieve outputs
        Start-Sleep -Milliseconds 500  # Give events time to finish
        Unregister-Event -SourceIdentifier $outEvent.Name
        Unregister-Event -SourceIdentifier $errEvent.Name

        $stdout = $outBuilder.ToString()
        $stderr = $errBuilder.ToString()

        if ($stdout.Trim()) {
            Write-Log "OctOS output:`n$stdout"
        }
        if ($stderr.Trim()) {
            Write-Log "OctOS errors:`n$stderr" "WARN"
        }

        Write-Log "OctOS finished (exit code: $($process.ExitCode))"
        return $true
    }
    catch {
        Write-Log "ERROR launching OctOS: $_" "ERROR"
        return $false
    }
    finally {
        Remove-Item -Path $cmdFile -ErrorAction SilentlyContinue
        if ($process -and -not $process.HasExited) {
            $process.Kill()
        }
    }
}

# ============================================================
#  Main script
# ============================================================

# --- Load configuration ---
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile = Join-Path $scriptDir ".env"
$cfg = Load-EnvFile -Path $envFile

$OCTOS_DIR   = $cfg["OCTOS_DIR"]
$COM_PORT    = $cfg["COM_PORT"]
$HOST_IP     = $cfg["HOST_IP"]
$UVP6_IP     = $cfg["UVP6_IP"]
$BAUDRATE    = $cfg["BAUDRATE"]
$WAIT_SECS   = [int]$cfg["WAIT_BETWEEN_COMMANDS"]
$SDLIST_TMO  = [int]$cfg["SDLIST_TIMEOUT"]
$SDDUMP_TMO  = [int]$cfg["SDDUMP_TIMEOUT"]

$octosExe      = Join-Path $OCTOS_DIR "bin\OctOS.exe"
$filemanagerDir = Join-Path $OCTOS_DIR "filemanager"
$treeFile       = Join-Path $filemanagerDir "tree.txt"
$newFilesPath   = Join-Path $filemanagerDir "new_files.txt"

# Validation
if (-not (Test-Path $octosExe)) {
    throw "OctOS.exe not found: $octosExe — Check OCTOS_DIR in .env"
}

# --- Initialize logging and monitoring ---
$logDir = Join-Path $OCTOS_DIR "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$script:LogFile = Join-Path $logDir ("download_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
$historyCsv   = Join-Path $logDir "download_history.csv"
$statusFile   = Join-Path $OCTOS_DIR "status.txt"
$dashboardHtml = Join-Path $logDir "dashboard.html"
$logRetention  = if ($cfg["LOG_RETENTION_DAYS"]) { [int]$cfg["LOG_RETENTION_DAYS"] } else { 90 }

# Rotate old logs
Cleanup-OldLogs -LogDir $logDir -RetentionDays $logRetention

Write-Log "================================================================="
Write-Log "  UVP6 DAILY DOWNLOAD — Start"
Write-Log "================================================================="
Write-Log "Configuration : COM$COM_PORT | Host=$HOST_IP | UVP6=$UVP6_IP | Baud=$BAUDRATE"

# Arguments OctOS.exe
$octosArgs = "$COM_PORT $HOST_IP $UVP6_IP"
if ($BAUDRATE) { $octosArgs += " $BAUDRATE" }

# Validate COM port accessibility
Write-Log "Validating COM port $COM_PORT accessibility..."
if (-not (Test-ComPortAvailable -PortNumber $COM_PORT -Baudrate $BAUDRATE)) {
    Write-Log "ERROR: COM port COM$COM_PORT is not accessible. Check connections and .env settings." "ERROR"
    $errorMsg = "COM port validation failed for COM$COM_PORT"
    Append-HistoryCSV -CsvPath $historyCsvPath -Status "FAILED" -TotalRemote 0 -NewDetected 0 -Downloaded 0 -Failed 0 -NewAcquisitions 0 -ErrorMsg $errorMsg -LogFile $logFile
    Update-StatusFile -StatusPath $statusFile -Status "ERROR" -Message "COM port validation failed"
    if ($cfg["SMTP_SERVER"]) {
        Send-EmailNotification -Config $cfg -Subject "UVP6 Download - COM Port Error" -Body "COM port COM$COM_PORT validation failed. Check hardware connections." -Status "ERROR"
    }
    exit 1
}

# ============================================================
#  PHASE 1: Stop acquisition + update tree.txt
# ============================================================

Write-Log "----- PHASE 1: Stop acquisition + sdlist -----"

# Back up current tree.txt (for comparison in case of failure)
if (Test-Path $treeFile) {
    $treeBackup = Join-Path $filemanagerDir "tree_backup.txt"
    Copy-Item -Path $treeFile -Destination $treeBackup -Force
    Write-Log "Backed up tree.txt → tree_backup.txt"
}

$phase1Commands = @(
    '$stop;',       # Stop acquisition (1st send)
    '$stop;',       # Stop acquisition (2nd send, for safety)
    'sdlist',       # Update and download tree.txt
    'quit'          # Quit OctOS
)

$phase1OK = Send-OctOSCommands `
    -OctOSExe $octosExe `
    -WorkDir $OCTOS_DIR `
    -Arguments $octosArgs `
    -Commands $phase1Commands `
    -TimeoutSeconds $SDLIST_TMO `
    -DelayBetweenCmds $WAIT_SECS

if (-not $phase1OK) {
    Write-Log "ERROR: Phase 1 (stop + sdlist) failed." "ERROR"
    Write-Log "Attempting safety reboot..."
    Send-OctOSCommands -OctOSExe $octosExe -WorkDir $OCTOS_DIR `
        -Arguments $octosArgs -Commands @('reboot', 'quit') `
        -TimeoutSeconds 120 -DelayBetweenCmds $WAIT_SECS

    # --- Monitoring: record failure ---
    Append-HistoryCSV -CsvPath $historyCsv -Status "ERROR" -ErrorMsg "Phase 1 failed (stop+sdlist)" -LogFile $script:LogFile
    Update-StatusFile -StatusPath $statusFile -Status "ERROR" -ErrorMsg "Phase 1 failed (stop+sdlist)" -LogFile $script:LogFile
    Generate-HTMLDashboard -CsvPath $historyCsv -HtmlPath $dashboardHtml
    Send-EmailNotification -Config $cfg -Subject "[UVP6] ERROR daily download" `
        -Body "Phase 1 (stop + sdlist) failed.`nSee log: $($script:LogFile)" -Status "ERROR"
    exit 1
}

# Short pause to ensure tree.txt is fully written to disk
Start-Sleep -Seconds 5

# ============================================================
#  PHASE 2: Compare tree.txt vs local files
# ============================================================

Write-Log "----- PHASE 2: Comparing remote/local files -----"

if (-not (Test-Path $treeFile)) {
    Write-Log "ERROR: tree.txt not found ($treeFile). sdlist may have failed." "ERROR"

    # Restore backup if available
    if (Test-Path $treeBackup) {
        Copy-Item -Path $treeBackup -Destination $treeFile -Force
        Write-Log "tree_backup.txt restored."
    }

    # Reboot UVP6 for safety
    Send-OctOSCommands -OctOSExe $octosExe -WorkDir $OCTOS_DIR `
        -Arguments $octosArgs -Commands @('reboot', 'quit') `
        -TimeoutSeconds 120 -DelayBetweenCmds $WAIT_SECS

    # --- Monitoring: record failure ---
    Append-HistoryCSV -CsvPath $historyCsv -Status "ERROR" -ErrorMsg "tree.txt not found after sdlist" -LogFile $script:LogFile
    Update-StatusFile -StatusPath $statusFile -Status "ERROR" -ErrorMsg "tree.txt not found after sdlist" -LogFile $script:LogFile
    Generate-HTMLDashboard -CsvPath $historyCsv -HtmlPath $dashboardHtml
    Send-EmailNotification -Config $cfg -Subject "[UVP6] ERROR — tree.txt missing" `
        -Body "tree.txt not found after sdlist.`nSee log: $($script:LogFile)" -Status "ERROR"
    exit 1
}

# Read the file listing from the SD card
$remoteFiles = Get-Content $treeFile -Encoding UTF8 | Where-Object { $_.Trim() -ne '' }
$totalRemote = $remoteFiles.Count
Write-Log "Files on SD card (tree.txt): $totalRemote"

# Compare: for each remote file, check if it exists locally
$newFiles = [System.Collections.Generic.List[string]]::new()

foreach ($relPath in $remoteFiles) {
    # tree.txt uses / — convert to \ for Windows
    $localPath = Join-Path $filemanagerDir ($relPath.Replace('/', '\'))
    if (-not (Test-Path $localPath)) {
        $newFiles.Add($relPath)
    }
}

Write-Log "Files already downloaded: $($totalRemote - $newFiles.Count)"
Write-Log "New files to download: $($newFiles.Count)"

# List new acquisitions (folders identified by _data.txt)
$newAcquisitions = $newFiles | Where-Object { $_ -like '*_data.txt' -and $_ -notlike 'AUTOCHECK*' }
if ($newAcquisitions.Count -gt 0) {
    Write-Log "New acquisitions detected ($($newAcquisitions.Count)):"
    foreach ($acq in $newAcquisitions) {
        $acqFolder = Split-Path $acq -Parent
        Write-Log "  • $acqFolder"
    }
}

# Nothing new? Reboot and exit.
if ($newFiles.Count -eq 0) {
    Write-Log "No new files. Rebooting UVP6..."
    Send-OctOSCommands -OctOSExe $octosExe -WorkDir $OCTOS_DIR `
        -Arguments $octosArgs -Commands @('reboot', 'quit') `
        -TimeoutSeconds 120 -DelayBetweenCmds $WAIT_SECS
    Write-Log "Done — no new data."

    # --- Monitoring: nothing new ---
    Append-HistoryCSV -CsvPath $historyCsv -Status "NO_NEW_DATA" -TotalRemote $totalRemote -LogFile $script:LogFile
    Update-StatusFile -StatusPath $statusFile -Status "NO_NEW_DATA" -TotalRemote $totalRemote -LogFile $script:LogFile
    Generate-HTMLDashboard -CsvPath $historyCsv -HtmlPath $dashboardHtml
    Send-EmailNotification -Config $cfg -Subject "[UVP6] No new data" `
        -Body "No new files detected ($totalRemote on SD card)." -Status "NO_NEW_DATA"
    exit 0
}

# Write the list of new files for sddump
$newFiles | Set-Content -Path $newFilesPath -Encoding ASCII
Write-Log "New files list written: $newFilesPath"

# ============================================================
#  PHASE 3: Download + reboot
# ============================================================

Write-Log "----- PHASE 3: Downloading $($newFiles.Count) files -----"

$phase3Commands = @(
    'sddump new_files.txt',    # Download only new files
    'reboot',                   # Reboot UVP6 (resumes acquisition)
    'quit'                      # Quit OctOS
)

$phase3OK = Send-OctOSCommands `
    -OctOSExe $octosExe `
    -WorkDir $OCTOS_DIR `
    -Arguments $octosArgs `
    -Commands $phase3Commands `
    -TimeoutSeconds $SDDUMP_TMO `
    -DelayBetweenCmds $WAIT_SECS

if ($phase3OK) {
    Write-Log "Download completed successfully."
} else {
    Write-Log "WARNING: Download may have encountered errors." "WARN"
    Write-Log "Check files in $filemanagerDir" "WARN"
}

# Clean up temporary file
Remove-Item -Path $newFilesPath -ErrorAction SilentlyContinue

# ============================================================
#  Final summary
# ============================================================

# Check how many files were actually downloaded
$downloadedCount = 0
foreach ($relPath in $newFiles) {
    $localPath = Join-Path $filemanagerDir ($relPath.Replace('/', '\'))
    if (Test-Path $localPath) {
        $downloadedCount++
    }
}

# Determine final status
$failedCount = $newFiles.Count - $downloadedCount
$finalStatus = if ($downloadedCount -eq $newFiles.Count) { "OK" }
               elseif ($downloadedCount -gt 0) { "PARTIAL" }
               else { "ERROR" }
$newAcqCount = if ($newAcquisitions) { $newAcquisitions.Count } else { 0 }
$errorDetail = if ($failedCount -gt 0) { "$failedCount files not downloaded" } else { "" }

Write-Log "================================================================="
Write-Log "  SUMMARY"
Write-Log "  Files on SD card        : $totalRemote"
Write-Log "  New detected            : $($newFiles.Count)"
Write-Log "  Successfully downloaded : $downloadedCount"
if ($failedCount -gt 0) {
    Write-Log "  Missing files           : $failedCount" "WARN"
}
Write-Log "  Status                  : $finalStatus"
Write-Log "  Log: $($script:LogFile)"
Write-Log "================================================================="
Write-Log "  UVP6 DAILY DOWNLOAD — End"
Write-Log "================================================================="

# --- Monitoring: record result ---
Append-HistoryCSV -CsvPath $historyCsv -Status $finalStatus `
    -TotalRemote $totalRemote -NewDetected $newFiles.Count `
    -Downloaded $downloadedCount -Failed $failedCount `
    -NewAcquisitions $newAcqCount -ErrorMsg $errorDetail -LogFile $script:LogFile

Update-StatusFile -StatusPath $statusFile -Status $finalStatus `
    -TotalRemote $totalRemote -NewDetected $newFiles.Count `
    -Downloaded $downloadedCount -Failed $failedCount `
    -NewAcquisitions $newAcqCount -ErrorMsg $errorDetail -LogFile $script:LogFile

Generate-HTMLDashboard -CsvPath $historyCsv -HtmlPath $dashboardHtml

# Email notification
$emailSubject = switch ($finalStatus) {
    "OK"      { "[UVP6] OK — $downloadedCount files downloaded ($newAcqCount acq.)" }
    "PARTIAL" { "[UVP6] WARNING — $downloadedCount/$($newFiles.Count) files downloaded" }
    "ERROR"   { "[UVP6] ERROR — No files downloaded" }
}
$emailBody = @"
UVP6 download summary for $(Get-Date -Format "yyyy-MM-dd HH:mm")

Status           : $finalStatus
SD files         : $totalRemote
New              : $($newFiles.Count)
Downloaded       : $downloadedCount
Failed           : $failedCount
Acquisitions     : $newAcqCount

Log: $($script:LogFile)
Dashboard: $dashboardHtml
"@
Send-EmailNotification -Config $cfg -Subject $emailSubject -Body $emailBody -Status $finalStatus

exit 0

# ============================================================
#  ALTERNATIVE: Direct serial communication (if stdin doesn't work)
# ============================================================
<#
If OctOS.exe does not accept commands via stdin (uses Windows Console API),
you can send commands directly over the serial port using Python:

    pip install pyserial

Then replace the Send-OctOSCommands function with a Python call:

    python -c "
    import serial, time
    ser = serial.Serial('COM$COM_PORT', $BAUDRATE, timeout=5)
    for cmd in ['`$stop;', '`$stop;']:
        ser.write((cmd + '\r\n').encode())
        time.sleep(2)
    ser.close()
    "

For sdlist/sddump, you would still need OctOS since those commands
manage the Ethernet (UDP) connection in addition to the serial port.

In that case, use a tool like 'expect' (via Cygwin) or
AutoHotkey to drive the interactive OctOS.exe interface.
#>
