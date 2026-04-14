<#
.SYNOPSIS
    Upload new UVP6 data files to FTP server.

.DESCRIPTION
    Compares tree.txt vs previous_tree.txt in the filemanager folder
    to identify newly downloaded files, then uploads them to the
    configured FTP server preserving the directory structure.

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

function Ensure-FtpDirectory {
    param(
        [string]$FtpBaseUri,
        [System.Net.NetworkCredential]$Credential,
        [string]$RelativePath
    )

    # Split path into segments and create each level.
    $segments = $RelativePath -split '[/\\]' | Where-Object { $_ }
    $current = ""
    foreach ($seg in $segments) {
        $current = if ($current) { "$current/$seg" } else { $seg }
        $dirUri = "$FtpBaseUri/$current/"
        try {
            $req = [System.Net.FtpWebRequest]::Create($dirUri)
            $req.Method = [System.Net.WebRequestMethods+Ftp]::MakeDirectory
            $req.Credentials = $Credential
            $req.UseBinary = $true
            $req.UsePassive = $true
            $req.EnableSsl = $false
            $resp = $req.GetResponse()
            $resp.Close()
        }
        catch [System.Net.WebException] {
            # 550 = directory already exists — that's fine.
            $ftpResp = $_.Exception.Response
            if ($ftpResp -and $ftpResp.StatusCode -eq [System.Net.FtpStatusCode]::ActionNotTakenFileUnavailable) {
                continue
            }
            # Other errors: log warning but don't stop (upload will fail if truly broken).
            Write-Log "  FTP mkdir warning for '$current': $($_.Exception.Message)" "WARN"
        }
    }
}

function Upload-FtpFile {
    param(
        [string]$FtpBaseUri,
        [System.Net.NetworkCredential]$Credential,
        [string]$LocalPath,
        [string]$RemoteRelPath
    )

    # Normalise to forward slashes for FTP.
    $remotePath = $RemoteRelPath -replace '\\', '/'
    $fileUri = "$FtpBaseUri/$remotePath"

    $req = [System.Net.FtpWebRequest]::Create($fileUri)
    $req.Method = [System.Net.WebRequestMethods+Ftp]::UploadFile
    $req.Credentials = $Credential
    $req.UseBinary = $true
    $req.UsePassive = $true
    $req.EnableSsl = $false

    $fileBytes = [System.IO.File]::ReadAllBytes($LocalPath)
    $req.ContentLength = $fileBytes.Length

    $stream = $req.GetRequestStream()
    try {
        $stream.Write($fileBytes, 0, $fileBytes.Length)
    }
    finally {
        $stream.Close()
    }

    $resp = $req.GetResponse()
    $resp.Close()
}

# ---------------------------
# Main
# ---------------------------

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile = Join-Path $scriptDir ".env"
$cfg = Load-EnvFile -Path $envFile

$OCTOS_DIR   = $cfg["OCTOS_DIR"]
$FTP_HOST    = $cfg["FTP_HOST"]
$FTP_USER    = $cfg["FTP_USER"]
$FTP_PASS    = $cfg["FTP_PASSWORD"]
$FTP_REMOTE  = $cfg["FTP_REMOTE_DIR"]

if (-not $FTP_HOST -or -not $FTP_USER) {
    throw "FTP_HOST and FTP_USER must be set in .env"
}

$logDir = Join-Path $OCTOS_DIR "logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$script:LogFile = Join-Path $logDir ("ftp_upload_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")

Write-Log "================================================================="
Write-Log "  UVP6 FTP UPLOAD - Start"
Write-Log "================================================================="
Write-Log "FTP: ftp://$FTP_HOST  User=$FTP_USER"

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
    Write-Log "  UVP6 FTP UPLOAD - End (OK)"
    Write-Log "================================================================="
    exit 0
}

Write-Log "$($filesToUpload.Count) new file(s) to upload."

# ---- Build FTP base URI ----
$ftpBase = "ftp://$FTP_HOST"
if ($FTP_REMOTE) {
    $ftpBase = "$ftpBase/$($FTP_REMOTE.TrimStart('/'))"
}
$ftpBase = $ftpBase.TrimEnd('/')

$cred = New-Object System.Net.NetworkCredential($FTP_USER, $FTP_PASS)

# ---- Upload files ----
$uploadCount = 0
$errorCount  = 0

foreach ($f in $filesToUpload) {
    $remoteRel = $f.RelPath -replace '\\', '/'

    # Ensure parent directory exists on FTP server.
    $parentDir = ($remoteRel -replace '\\', '/') -replace '/[^/]+$', ''
    if ($parentDir) {
        Ensure-FtpDirectory -FtpBaseUri $ftpBase -Credential $cred -RelativePath $parentDir
    }

    try {
        Upload-FtpFile -FtpBaseUri $ftpBase -Credential $cred `
                       -LocalPath $f.LocalPath -RemoteRelPath $remoteRel
        $uploadCount++
        Write-Log "  Uploaded: $remoteRel"
    }
    catch {
        $errorCount++
        Write-Log "  FAILED: $remoteRel - $($_.Exception.Message)" "ERROR"
    }
}

Write-Log "Upload complete: $uploadCount succeeded, $errorCount failed."
Write-Log "Log: $script:LogFile"

if ($errorCount -gt 0) {
    Write-Log "================================================================="
    Write-Log "  UVP6 FTP UPLOAD - End (ERRORS)"
    Write-Log "================================================================="
    exit 1
}

Write-Log "================================================================="
Write-Log "  UVP6 FTP UPLOAD - End (OK)"
Write-Log "================================================================="
exit 0
