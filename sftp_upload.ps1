<#
.SYNOPSIS
    Upload new UVP6 data files to the SFTP server.

.DESCRIPTION
    Compares tree.txt vs previous_tree.txt in the filemanager folder
    to identify newly downloaded files, then uploads them to the
    configured SFTP server (via Posh-SSH) preserving the directory
    structure.

    Designed to run after download.ps1 (download_and_upload.bat chains both).

    Exit codes:
      0 = everything uploaded
      1 = at least one upload failed OR at least one file listed on the SD
          card is missing locally (inconsistent download - cleanup.ps1 will
          refuse to format until this is resolved)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'common.ps1')

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

if (-not $OCTOS_DIR) { throw "OCTOS_DIR is not set in .env" }
if (-not $SFTP_HOST -or -not $SFTP_USER) {
    throw "SFTP_HOST and SFTP_USER must be set in .env"
}

$logDir = Join-Path $OCTOS_DIR "logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$script:LogFile = Join-Path $logDir ("sftp_upload_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")

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
    Write-Log "  UVP6 SFTP UPLOAD - End (SKIP)"
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

# Filter out blank lines; report files that should exist locally but do not.
$filesToUpload = @()
$missingLocal  = @()
foreach ($rel in $newFiles) {
    $rel = $rel.Trim()
    if (-not $rel) { continue }
    $localPath = Join-Path $filemanagerDir $rel
    if (Test-Path $localPath) {
        $filesToUpload += [PSCustomObject]@{ RelPath = $rel; LocalPath = $localPath }
    } else {
        $missingLocal += $rel
        Write-Log "  File listed on SD but not found locally: $rel" "ERROR"
    }
}

if ($missingLocal.Count -gt 0) {
    Write-Log "$($missingLocal.Count) file(s) listed in tree.txt are missing locally (incomplete download?)." "ERROR"
}

if ($filesToUpload.Count -eq 0 -and $missingLocal.Count -eq 0) {
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
}
finally {
    if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession | Out-Null }
}

Write-Log "Upload complete: $uploadCount succeeded, $errorCount failed, $($missingLocal.Count) missing locally."
Write-Log "Log: $script:LogFile"

if ($errorCount -gt 0 -or $missingLocal.Count -gt 0) {
    Write-Log "================================================================="
    Write-Log "  UVP6 SFTP UPLOAD - End (ERRORS)"
    Write-Log "================================================================="
    exit 1
}

Write-Log "================================================================="
Write-Log "  UVP6 SFTP UPLOAD - End (OK)"
Write-Log "================================================================="
exit 0
