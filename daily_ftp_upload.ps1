<#
.SYNOPSIS
    Upload new UVP6 data files to SFTP server.

.DESCRIPTION
    Compares tree.txt vs previous_tree.txt in the filemanager folder
    to identify newly downloaded files, then uploads them to the
    configured SFTP server (via Posh-SSH) preserving the directory structure.

    Designed to run after daily_download.ps1.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Load-EnvFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Configuration file not found: $Path"
    }

    $cfg = @{}
    Get-Content -Path $Path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#')) { return }
        if ($line -match '^([^=]+)=(.*)$') {
            $cfg[$matches[1].Trim()] = $matches[2].Trim()
        }
    }

    return $cfg
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    }
}

$script:_sftpDirsCreated = @{}

function Open-SftpSession {
    param(
        [string]$Hostname,
        [string]$User,
        [string]$Pass,
        [int]$Port
    )
    if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
        throw "Posh-SSH module not found. Run: Install-Module -Name Posh-SSH -Scope CurrentUser"
    }
    Import-Module Posh-SSH -ErrorAction Stop
    $secPass = ConvertTo-SecureString $Pass -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($User, $secPass)
    return New-SFTPSession -ComputerName $Hostname -Credential $cred -Port $Port -AcceptKey -Force
}

function Ensure-SftpDirectory {
    param($Session, [string]$FullRemotePath)
    if ($script:_sftpDirsCreated.ContainsKey($FullRemotePath)) { return }
    $sftpClient = $Session.Session
    $segments = $FullRemotePath.TrimStart('/') -split '/' | Where-Object { $_ }
    $current = ""
    foreach ($seg in $segments) {
        $current = "$current/$seg"
        if (-not $script:_sftpDirsCreated.ContainsKey($current)) {
            if (-not ($sftpClient.Exists($current))) {
                try {
                    $sftpClient.CreateDirectory($current)
                } catch {
                    # Some servers return generic Failure for already-existing dirs.
                    # Re-check via the same client; only throw if truly absent.
                    if (-not ($sftpClient.Exists($current))) {
                        throw "Failed to create SFTP directory '$current': $_"
                    }
                }
            }
            $script:_sftpDirsCreated[$current] = $true
        }
    }
    $script:_sftpDirsCreated[$FullRemotePath] = $true
}

function Upload-SftpFile {
    param($Session, [string]$LocalPath, [string]$RemotePath)
    $fs = [System.IO.File]::OpenRead($LocalPath)
    try {
        $Session.Session.UploadFile($fs, $RemotePath)
    } finally {
        $fs.Close()
    }
}

# ---------------------------
# Main
# ---------------------------

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile = Join-Path $scriptDir ".env"
$cfg = Load-EnvFile -Path $envFile

$OCTOS_DIR    = $cfg["OCTOS_DIR"]
$SFTP_HOST    = $cfg["SFTP_HOST"]
$SFTP_USER    = $cfg["SFTP_USER"]
$SFTP_PASS    = $cfg["SFTP_PASSWORD"]
$SFTP_REMOTE  = $cfg["SFTP_REMOTE_DIR"]
$SFTP_PORT    = if ($cfg["SFTP_PORT"]) { [int]$cfg["SFTP_PORT"] } else { 22 }

if (-not $SFTP_HOST -or -not $SFTP_USER) {
    throw "SFTP_HOST and SFTP_USER must be set in .env"
}

$logDir = Join-Path $OCTOS_DIR "logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$script:LogFile = Join-Path $logDir ("ftp_upload_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")

Write-Log "================================================================="
Write-Log "  UVP6 SFTP UPLOAD - Start"
Write-Log "================================================================="
Write-Log "SFTP: sftp://${SFTP_HOST}:${SFTP_PORT}  User=$SFTP_USER"

$filemanagerDir = Join-Path $OCTOS_DIR "filemanager"
$treeFile       = Join-Path $filemanagerDir "tree.txt"
$prevTreeFile   = Join-Path $filemanagerDir "previous_tree.txt"

# ---- Determine which files are new ----
$newTree = Get-Content $treeFile -ErrorAction SilentlyContinue
$oldTree = Get-Content $prevTreeFile -ErrorAction SilentlyContinue

if (-not $newTree) {
    Write-Log "No tree.txt found - nothing to upload." "WARN"
    Write-Log "================================================================="
    Write-Log "  UVP6 FTP UPLOAD - End (SKIP)"
    Write-Log "================================================================="
    exit 0
}

if ($oldTree) {
    $oldSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$oldTree, [StringComparer]::OrdinalIgnoreCase)
    $newFiles = @($newTree | Where-Object { -not $oldSet.Contains($_) })
} else {
    Write-Log "No previous_tree.txt - all files in tree.txt are considered new."
    $newFiles = @($newTree)
}

# Filter out blank lines and files that don't exist locally.
$filesToUpload = @()
foreach ($rel in $newFiles) {
    $rel = $rel.Trim()
    if (-not $rel) { continue }
    $localPath = Join-Path $filemanagerDir $rel
    if (Test-Path $localPath) {
        $filesToUpload += [PSCustomObject]@{ RelPath = $rel; LocalPath = $localPath }
    } else {
        Write-Log "  File not found locally, skipping: $rel" "WARN"
    }
}

if ($filesToUpload.Count -eq 0) {
    Write-Log "No new files to upload."
    Write-Log "================================================================="
    Write-Log "  UVP6 SFTP UPLOAD - End (OK)"
    Write-Log "================================================================="
    exit 0
}

Write-Log "$($filesToUpload.Count) new file(s) to upload."

# ---- Open SFTP session and upload files ----
$remoteBase = if ($SFTP_REMOTE) { "/" + $SFTP_REMOTE.Trim('/').Replace('\', '/') } else { "" }

$uploadCount = 0
$errorCount  = 0

$sftpSession = $null
try {
    $sftpSession = Open-SftpSession -Hostname $SFTP_HOST -User $SFTP_USER -Pass $SFTP_PASS -Port $SFTP_PORT
    Write-Log "  SFTP connected."

    # --- DIAGNOSTICS (remove after confirming remote layout) ---
    $sftpClient = $sftpSession.Session
    $diagPaths = @(
        '/uvp6',
        '/uvp6/ANERIS_TEST_PIPELINE_AUTO_FROM_VLFR',
        '/uvp6/ANERIS_TEST_PIPELINE_AUTO_FROM_VLFR/2026'
    )
    foreach ($dp in $diagPaths) {
        $dpExists = $sftpClient.Exists($dp)
        Write-Log "  [DIAG] Exists('$dp') = $dpExists"
        if ($dpExists) {
            try {
                $dpItems = @($sftpClient.ListDirectory($dp))
                Write-Log "  [DIAG]   ListDirectory OK - $($dpItems.Count) entries"
            } catch {
                Write-Log "  [DIAG]   ListDirectory FAILED: $_"
            }
        } else {
            try {
                $sftpClient.CreateDirectory($dp)
                Write-Log "  [DIAG]   CreateDirectory('$dp') -> OK"
            } catch {
                Write-Log "  [DIAG]   CreateDirectory('$dp') -> FAILED: $_"
                Write-Log "  [DIAG]   Exists after fail: $($sftpClient.Exists($dp))"
            }
        }
    }
    # --- END DIAGNOSTICS ---

    foreach ($f in $filesToUpload) {
        $remoteRel  = $f.RelPath.Replace('\', '/')
        $remotePath = "$remoteBase/$remoteRel"
        if ($remoteRel -match '/') {
            $parentDir = "$remoteBase/" + ($remoteRel -replace '/[^/]+$', '')
            Ensure-SftpDirectory -Session $sftpSession -FullRemotePath $parentDir
        }
        try {
            Upload-SftpFile -Session $sftpSession -LocalPath $f.LocalPath -RemotePath $remotePath
            $uploadCount++
            Write-Log "  Uploaded: $remoteRel"
        }
        catch {
            $errorCount++
            Write-Log "  FAILED: $remoteRel - $($_.Exception.Message)" "ERROR"
        }
    }

    # Upload all tree files (tree.txt, previous_tree.txt, tree_YYYYMMDD.txt).
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
}
finally {
    if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession | Out-Null }
}

Write-Log "Upload complete: $uploadCount succeeded, $errorCount failed."
Write-Log "Log: $script:LogFile"

if ($errorCount -gt 0) {
    Write-Log "================================================================="
    Write-Log "  UVP6 SFTP UPLOAD - End (ERRORS)"
    Write-Log "================================================================="
    exit 1
}

Write-Log "================================================================="
Write-Log "  UVP6 SFTP UPLOAD - End (OK)"
Write-Log "================================================================="
exit 0
