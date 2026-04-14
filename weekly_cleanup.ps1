<#
.SYNOPSIS
    Weekly UVP6 verification and SD card cleanup.

.DESCRIPTION
    SAFETY-FIRST workflow — the SD card is ONLY formatted after
    verifying that every single file has been:
      1. Downloaded to the local filemanager/ folder
      2. Uploaded to the remote FTP server

    If ANY file is missing locally or on FTP, the script ABORTS
    without formatting. No data is ever lost.

    Sequence:
      1) Connect to UVP6 via OctOS
      2) Stop UVP6 acquisition (UVP6 stays stopped until final reboot)
      3) sdlist - get fresh SD card file listing
      4) sddump - download any remaining files
      5) Quit OctOS (UVP6 still stopped - no new data can appear)
      6) Verify every file exists locally
      7) Upload any missing files to FTP
      8) Verify every file exists on FTP
      9) If 100% verified - reconnect and sdformat
     10) Reboot UVP6 (resumes acquisition)
     11) If any check fails - reboot without formatting (no data loss)

    The UVP6 stays stopped from step 2 to step 10, so no new data
    can be captured between the listing and the format.

    Designed to run weekly, after the daily download+upload cycle.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---- ConPTY (Pseudo Console) Session Helper ----
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;

public class ConPtySession : IDisposable
{
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern int CreatePseudoConsole(COORD size, IntPtr hInput, IntPtr hOutput, uint dwFlags, out IntPtr phPC);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern void ClosePseudoConsole(IntPtr hPC);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CreatePipe(out IntPtr hReadPipe, out IntPtr hWritePipe, ref SECURITY_ATTRIBUTES sa, uint nSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr Attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeleteProcThreadAttributeList(IntPtr lpAttributeList);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(
        string lpApplicationName, string lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes,
        bool bInheritHandles, uint dwCreationFlags,
        IntPtr lpEnvironment, string lpCurrentDirectory,
        ref STARTUPINFOEX lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(IntPtr hFile, byte[] lpBuffer, uint nNumberOfBytesToWrite, out uint lpNumberOfBytesWritten, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr hFile, byte[] lpBuffer, uint nNumberOfBytesToRead, out uint lpNumberOfBytesRead, IntPtr lpOverlapped);

    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll")]
    static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll")]
    static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

    [DllImport("kernel32.dll")]
    static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    const int  PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016;
    const uint STILL_ACTIVE = 259;

    [StructLayout(LayoutKind.Sequential)]
    struct COORD { public short X, Y; public COORD(short x, short y) { X = x; Y = y; } }

    [StructLayout(LayoutKind.Sequential)]
    struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public bool bInheritHandle; }

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFO {
        public int cb; public IntPtr lpReserved; public IntPtr lpDesktop; public IntPtr lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2;
        public IntPtr hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    IntPtr _hPC, _inputWriteHandle, _outputReadHandle, _hProcess, _hThread, _attrList;
    public int ProcessId { get; private set; }
    public StringBuilder OutputBuffer { get; private set; }
    readonly object _bufferLock = new object();
    Thread _readerThread;
    volatile bool _stopReading;
    string _outputLogPath;
    bool _disposed;

    public ConPtySession() { OutputBuffer = new StringBuilder(); }

    public string GetOutput()
    {
        lock (_bufferLock) { return OutputBuffer.ToString(); }
    }

    public void Start(string application, string commandLine, string workingDirectory, string outputLogPath)
    {
        _outputLogPath = outputLogPath;

        var sa = new SECURITY_ATTRIBUTES { nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)), bInheritHandle = true };

        IntPtr inputRead, outputWrite;
        if (!CreatePipe(out inputRead, out _inputWriteHandle, ref sa, 0))
            throw new Exception("CreatePipe (input) failed: " + Marshal.GetLastWin32Error());
        if (!CreatePipe(out _outputReadHandle, out outputWrite, ref sa, 0))
            throw new Exception("CreatePipe (output) failed: " + Marshal.GetLastWin32Error());

        var size = new COORD(200, 60);
        int hr = CreatePseudoConsole(size, inputRead, outputWrite, 0, out _hPC);
        if (hr != 0)
            throw new Exception("CreatePseudoConsole failed: 0x" + hr.ToString("X"));

        CloseHandle(inputRead);
        CloseHandle(outputWrite);

        IntPtr attrSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrSize);
        _attrList = Marshal.AllocHGlobal(attrSize);
        if (!InitializeProcThreadAttributeList(_attrList, 1, 0, ref attrSize))
            throw new Exception("InitializeProcThreadAttributeList failed: " + Marshal.GetLastWin32Error());

        if (!UpdateProcThreadAttribute(_attrList, 0,
                (IntPtr)PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, _hPC,
                (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
            throw new Exception("UpdateProcThreadAttribute failed: " + Marshal.GetLastWin32Error());

        var si = new STARTUPINFOEX();
        si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        si.lpAttributeList = _attrList;

        PROCESS_INFORMATION pi;
        if (!CreateProcessW(application, commandLine, IntPtr.Zero, IntPtr.Zero,
                false, EXTENDED_STARTUPINFO_PRESENT, IntPtr.Zero, workingDirectory,
                ref si, out pi))
            throw new Exception("CreateProcess failed: " + Marshal.GetLastWin32Error());

        _hProcess = pi.hProcess;
        _hThread  = pi.hThread;
        ProcessId = pi.dwProcessId;

        _stopReading = false;
        _readerThread = new Thread(ReaderLoop) { IsBackground = true };
        _readerThread.Start();
    }

    void ReaderLoop()
    {
        byte[] buf = new byte[4096];
        while (!_stopReading)
        {
            uint read;
            bool ok = ReadFile(_outputReadHandle, buf, (uint)buf.Length, out read, IntPtr.Zero);
            if (!ok || read == 0) break;

            string chunk = Encoding.UTF8.GetString(buf, 0, (int)read);
            lock (_bufferLock) { OutputBuffer.Append(chunk); }

            if (_outputLogPath != null)
            {
                string ts = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
                string[] lines = chunk.Split(new[] { '\n' }, StringSplitOptions.None);
                foreach (string ln in lines)
                {
                    string clean = ln.TrimEnd('\r');
                    if (clean.Length > 0)
                    {
                        try { File.AppendAllText(_outputLogPath, "[" + ts + "] [STDOUT] " + clean + Environment.NewLine, Encoding.UTF8); }
                        catch { }
                    }
                }
            }
        }
    }

    public void WriteToPty(string text)
    {
        byte[] data = Encoding.UTF8.GetBytes(text);
        uint written;
        if (!WriteFile(_inputWriteHandle, data, (uint)data.Length, out written, IntPtr.Zero))
            throw new Exception("WriteFile to PTY failed: " + Marshal.GetLastWin32Error());
    }

    public void WriteLine(string text) { WriteToPty(text + "\r\n"); }

    public bool HasExited
    {
        get { uint c; GetExitCodeProcess(_hProcess, out c); return c != STILL_ACTIVE; }
    }

    public int ExitCode
    {
        get { uint c; GetExitCodeProcess(_hProcess, out c); return (int)c; }
    }

    public bool WaitForExit(int timeoutMs)
    {
        return WaitForSingleObject(_hProcess, (uint)timeoutMs) == 0;
    }

    public void Kill() { TerminateProcess(_hProcess, 1); }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _stopReading = true;
        if (_inputWriteHandle != IntPtr.Zero)  { CloseHandle(_inputWriteHandle);  _inputWriteHandle  = IntPtr.Zero; }
        if (_outputReadHandle != IntPtr.Zero)   { CloseHandle(_outputReadHandle);  _outputReadHandle  = IntPtr.Zero; }
        if (_readerThread != null) _readerThread.Join(3000);
        if (_hThread  != IntPtr.Zero)  CloseHandle(_hThread);
        if (_hProcess != IntPtr.Zero)  CloseHandle(_hProcess);
        if (_attrList != IntPtr.Zero)  { DeleteProcThreadAttributeList(_attrList); Marshal.FreeHGlobal(_attrList); }
        if (_hPC      != IntPtr.Zero)  ClosePseudoConsole(_hPC);
    }
}
"@

# ---- Shared helpers ----

function Load-EnvFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Configuration file not found: $Path" }
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

function Strip-Ansi {
    param([string]$Text)
    return $Text -replace '\x1b\[[0-9;]*[a-zA-Z]', '' -replace '\x1b\][^\x07]*\x07', '' -replace '\x1b[^\[\]][a-zA-Z]', ''
}

function Wait-ForMarker {
    param(
        [ConPtySession]$Session,
        [string]$MarkerRegex,
        [int]$TimeoutSec
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $clean = Strip-Ansi $Session.GetOutput()
        if ($clean -match $MarkerRegex) { return $true }
        if ($Session.HasExited) { return $false }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Wait-ForMarkerCapture {
    param(
        [ConPtySession]$Session,
        [string]$MarkerRegex,
        [int]$TimeoutSec
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $clean = Strip-Ansi $Session.GetOutput()
        if ($clean -match $MarkerRegex) { return $Matches }
        if ($Session.HasExited) { return $null }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

# ---- FTP helpers ----

function Test-FtpFileExists {
    param(
        [string]$FtpBaseUri,
        [System.Net.NetworkCredential]$Credential,
        [string]$RemoteRelPath
    )
    $remotePath = $RemoteRelPath -replace '\\', '/'
    $fileUri = "$FtpBaseUri/$remotePath"
    try {
        $req = [System.Net.FtpWebRequest]::Create($fileUri)
        $req.Method = [System.Net.WebRequestMethods+Ftp]::GetFileSize
        $req.Credentials = $Credential
        $req.UseBinary = $true
        $req.UsePassive = $true
        $req.EnableSsl = $false
        $resp = $req.GetResponse()
        $resp.Close()
        return $true
    }
    catch [System.Net.WebException] {
        return $false
    }
}

# ---- OctOS Session helpers ----

function Start-OctOSSession {
    param(
        [string]$OctOSExe,
        [string]$WorkDir,
        [string]$Arguments,
        [string]$OutputLogPath
    )
    $commandLine = "`"$OctOSExe`" $Arguments"
    $session = New-Object ConPtySession
    $session.Start($OctOSExe, $commandLine, $WorkDir, $OutputLogPath)
    return $session
}

function Initialize-OctOSSession {
    param(
        [ConPtySession]$Session,
        [int]$DataWaitTimeoutSec
    )

    # Wait for ready.
    Write-Log "  .. Waiting for OctOS ready ([ME]:)..."
    $ready = Wait-ForMarker -Session $Session -MarkerRegex '\[ME\]:' -TimeoutSec 120
    if (-not $ready) { throw "OctOS never became ready (no [ME]: within 120s)." }
    Write-Log "  <- OctOS is ready."

    $Session.WriteLine("")
    Write-Log "  -> Sent: [Enter]"

    # Data check + pre-reboot if needed.
    Write-Log "  .. Waiting ${DataWaitTimeoutSec}s for data lines..."
    $hasData = Wait-ForMarker -Session $Session -MarkerRegex '(LPM_DATA|BLACK_DATA),' -TimeoutSec $DataWaitTimeoutSec
    if (-not $hasData) {
        Write-Log "  <- No data. Sending reboot..." "WARN"
        $Session.WriteLine("reboot")
        Write-Log "  -> Sent: reboot"
        $ok = Wait-ForMarker -Session $Session -MarkerRegex '\$startack;' -TimeoutSec 180
        if (-not $ok) { throw "Timeout waiting for `$startack; after pre-reboot." }
        Write-Log "  <- Received `$startack;"
        $hasData2 = Wait-ForMarker -Session $Session -MarkerRegex '(LPM_DATA|BLACK_DATA),' -TimeoutSec 60
        if (-not $hasData2) { throw "UVP6 still not sending data after reboot." }
        Write-Log "  <- Data confirmed after reboot."
    } else {
        Write-Log "  <- Data lines detected."
    }
}

function Send-StopSequence {
    param(
        [ConPtySession]$Session,
        [int]$DelaySec
    )
    foreach ($i in 1..3) {
        Start-Sleep -Seconds $DelaySec
        $Session.WriteLine('$stop;')
        Write-Log "  -> Sent (stop_$i): `$stop;"
        if ($i -eq 3) {
            Write-Log "  .. Waiting for `$stopack;..."
            $ok = Wait-ForMarker -Session $Session -MarkerRegex '\$stopack;' -TimeoutSec 30
            if (-not $ok) { throw "Timeout waiting for `$stopack;" }
            Write-Log "  <- Received `$stopack;"
        }
    }
}

function Send-SafetyReboot {
    param([ConPtySession]$Session)
    if ($Session -and -not $Session.HasExited) {
        try {
            Write-Log "  -> Sending safety reboot..."
            $Session.WriteLine("reboot")
            $ok = Wait-ForMarker -Session $Session -MarkerRegex '\$startack;' -TimeoutSec 180
            if ($ok) { Write-Log "  <- Safety reboot OK." }
            else     { Write-Log "  <- Safety reboot: no `$startack; within 180s." "WARN" }
        }
        catch { Write-Log "  <- Safety reboot failed: $_" "WARN" }
    }
}

function Close-OctOSSession {
    param([ConPtySession]$Session)
    if ($Session) {
        if (-not $Session.HasExited) { $Session.Kill() }
        $Session.Dispose()
    }
}

# ---- FTP upload helpers (same as daily_ftp_upload.ps1) ----

function Ensure-FtpDirectory {
    param(
        [string]$FtpBaseUri,
        [System.Net.NetworkCredential]$Credential,
        [string]$RelativePath
    )
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
            $ftpResp = $_.Exception.Response
            if ($ftpResp -and $ftpResp.StatusCode -eq [System.Net.FtpStatusCode]::ActionNotTakenFileUnavailable) {
                continue
            }
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
    try { $stream.Write($fileBytes, 0, $fileBytes.Length) }
    finally { $stream.Close() }

    $resp = $req.GetResponse()
    $resp.Close()
}

# ---- Helper: reboot UVP6 before exiting on error ----
# Called when Phases 2/3 fail and UVP6 is still stopped.
# Uses script-scope variables set in Main.
function Invoke-RebootAndExit {
    param([int]$ExitCode)

    if (-not $script:needsReboot) { exit $ExitCode }

    Write-Log ""
    Write-Log "Rebooting UVP6 to resume acquisition before exiting..."
    $rbSession = $null
    try {
        $rbLog = Join-Path $script:logDir ("octos_output_weekly_reboot_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
        $rbSession = Start-OctOSSession -OctOSExe $script:octosExe -WorkDir $script:OCTOS_DIR -Arguments $script:octosArgs -OutputLogPath $rbLog
        $ready = Wait-ForMarker -Session $rbSession -MarkerRegex '\[ME\]:' -TimeoutSec 120
        if ($ready) {
            $rbSession.WriteLine("")
            Start-Sleep -Seconds $script:WAIT_SECS
            $rbSession.WriteLine("reboot")
            Write-Log "  -> Sent: reboot"
            $ok = Wait-ForMarker -Session $rbSession -MarkerRegex '\$startack;' -TimeoutSec 180
            if ($ok) { Write-Log "  <- UVP6 rebooted, acquisition resumed." }
            else     { Write-Log "  <- No `$startack; within 180s." "WARN" }
            Start-Sleep -Seconds $script:WAIT_SECS
            $rbSession.WriteLine("quit")
            $rbSession.WaitForExit(15000) | Out-Null
        } else {
            Write-Log "  OctOS not ready for reboot." "WARN"
        }
    }
    catch {
        Write-Log "  Reboot session failed: $_" "WARN"
    }
    finally {
        Close-OctOSSession -Session $rbSession
    }
    $script:needsReboot = $false

    Write-Log "================================================================="
    Write-Log "  UVP6 WEEKLY VERIFY & CLEANUP - End (ABORT)"
    Write-Log "================================================================="
    exit $ExitCode
}

# ---------------------------
# Main
# ---------------------------

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile = Join-Path $scriptDir ".env"
$cfg = Load-EnvFile -Path $envFile

$OCTOS_DIR    = $cfg["OCTOS_DIR"]
$COM_PORT     = $cfg["COM_PORT"]
$HOST_IP      = $cfg["HOST_IP"]
$BAUDRATE     = $cfg["BAUDRATE"]
$WAIT_SECS    = if ($cfg["WAIT_BETWEEN_COMMANDS"]) { [int]$cfg["WAIT_BETWEEN_COMMANDS"] } else { 3 }
$SDLIST_TMO   = if ($cfg["SDLIST_TIMEOUT"])  { [int]$cfg["SDLIST_TIMEOUT"] }  else { 600 }
$SDDUMP_TMO   = if ($cfg["SDDUMP_TIMEOUT"])  { [int]$cfg["SDDUMP_TIMEOUT"] }  else { 14400 }
$SDFORMAT_TMO = if ($cfg["SDFORMAT_TIMEOUT"]){ [int]$cfg["SDFORMAT_TIMEOUT"]} else { 180 }
$DATA_WAIT    = if ($cfg["DATA_WAIT_TIMEOUT"]){ [int]$cfg["DATA_WAIT_TIMEOUT"]} else { 15 }
$FTP_HOST     = $cfg["FTP_HOST"]
$FTP_USER     = $cfg["FTP_USER"]
$FTP_PASS     = $cfg["FTP_PASSWORD"]
$FTP_REMOTE   = $cfg["FTP_REMOTE_DIR"]

$octosExe = Join-Path $OCTOS_DIR "bin\OctOS.exe"
if (-not (Test-Path $octosExe)) { throw "OctOS.exe not found: $octosExe" }

$logDir = Join-Path $OCTOS_DIR "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$script:LogFile = Join-Path $logDir ("weekly_cleanup_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")

Write-Log "================================================================="
Write-Log "  UVP6 WEEKLY VERIFY & CLEANUP - Start"
Write-Log "================================================================="
Write-Log "Configuration: COM$COM_PORT | Host=$HOST_IP | FTP=$FTP_HOST"

$octosArgs = "$COM_PORT"
if ($BAUDRATE) { $octosArgs += " $BAUDRATE" }

$filemanagerDir = Join-Path $OCTOS_DIR "filemanager"
$treeFile = Join-Path $filemanagerDir "tree.txt"

# Track whether we need to reboot UVP6 at the end (it stays stopped
# from Phase 1 until we explicitly reboot in Phase 4 or on error).
$needsReboot = $false

# ============================================================
# PHASE 1: Stop UVP6, sdlist, sddump (UVP6 stays stopped)
# ============================================================
Write-Log ""
Write-Log "---- PHASE 1: Stop UVP6 + sdlist + sddump ----"
Write-Log "UVP6 will stay stopped until Phase 4 completes."

$session = $null
try {
    $octosLog = Join-Path $logDir ("octos_output_weekly_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
    Write-Log "OctOS output log: $octosLog"

    $session = Start-OctOSSession -OctOSExe $octosExe -WorkDir $OCTOS_DIR -Arguments $octosArgs -OutputLogPath $octosLog
    Write-Log "  OctOS PID: $($session.ProcessId)"

    Initialize-OctOSSession -Session $session -DataWaitTimeoutSec $DATA_WAIT
    Send-StopSequence -Session $session -DelaySec $WAIT_SECS
    $needsReboot = $true

    # sdlist - get current SD card contents.
    Start-Sleep -Seconds $WAIT_SECS
    $session.WriteLine("sdlist $HOST_IP")
    Write-Log "  -> Sent: sdlist $HOST_IP"
    Write-Log "  .. Waiting for [SDLIST] EXIT (timeout ${SDLIST_TMO}s)..."
    $ok = Wait-ForMarker -Session $session -MarkerRegex '\[SDLIST\].*EXIT' -TimeoutSec $SDLIST_TMO
    if (-not $ok) { throw "Timeout waiting for sdlist to complete." }
    Write-Log "  <- sdlist completed."

    # sddump - download any files not yet on disk.
    Start-Sleep -Seconds $WAIT_SECS
    $session.WriteLine("sddump tree.txt")
    Write-Log "  -> Sent: sddump tree.txt"
    Write-Log "  .. Waiting for [SDDUMP] EXIT (timeout ${SDDUMP_TMO}s)..."
    $ok = Wait-ForMarker -Session $session -MarkerRegex '\[SDDUMP\].*EXIT' -TimeoutSec $SDDUMP_TMO
    if (-not $ok) { throw "Timeout waiting for sddump to complete." }
    Write-Log "  <- sddump completed."

    # Quit OctOS WITHOUT rebooting - UVP6 stays stopped.
    Start-Sleep -Seconds $WAIT_SECS
    $session.WriteLine("quit")
    Write-Log "  -> Sent: quit (UVP6 stays stopped)"
    $session.WaitForExit(30000) | Out-Null
}
catch {
    Write-Log "PHASE 1 FAILED: $_" "ERROR"
    Send-SafetyReboot -Session $session
    $needsReboot = $false
    Close-OctOSSession -Session $session
    Write-Log "================================================================="
    Write-Log "  UVP6 WEEKLY VERIFY & CLEANUP - End (ERROR in Phase 1)"
    Write-Log "================================================================="
    exit 1
}
finally {
    Close-OctOSSession -Session $session
    $session = $null
}

# ============================================================
# PHASE 2: Verify all files exist locally
# ============================================================
Write-Log ""
Write-Log "---- PHASE 2: Verify local files ----"

if (-not (Test-Path $treeFile)) {
    Write-Log "tree.txt not found after sdlist - cannot verify." "ERROR"
    # Must reboot before exiting.
    Invoke-RebootAndExit 1
}

$treeEntries = @(Get-Content $treeFile | ForEach-Object { $_.Trim() } | Where-Object { $_ })
Write-Log "SD card contains $($treeEntries.Count) file(s)."

$missingLocal = @()
foreach ($rel in $treeEntries) {
    $localPath = Join-Path $filemanagerDir $rel
    if (-not (Test-Path $localPath)) {
        $missingLocal += $rel
    }
}

if ($missingLocal.Count -gt 0) {
    Write-Log "*** ABORT: $($missingLocal.Count) file(s) MISSING locally after sddump! ***" "ERROR"
    Write-Log "SD card will NOT be formatted to prevent data loss." "ERROR"
    foreach ($f in $missingLocal | Select-Object -First 50) {
        Write-Log "  MISSING LOCAL: $f" "ERROR"
    }
    if ($missingLocal.Count -gt 50) {
        Write-Log "  ... and $($missingLocal.Count - 50) more." "ERROR"
    }
    Write-Log "ACTION REQUIRED: Investigate sddump failures, then retry." "ERROR"
    # Must reboot before exiting.
    Invoke-RebootAndExit 1
}

Write-Log "All $($treeEntries.Count) file(s) verified locally."

# ============================================================
# PHASE 3: Upload to FTP + verify all files exist on FTP
# ============================================================
Write-Log ""
Write-Log "---- PHASE 3: FTP upload & verify ----"

if (-not $FTP_HOST -or -not $FTP_USER) {
    Write-Log "FTP not configured - cannot verify." "ERROR"
    Write-Log "SD card will NOT be formatted without FTP verification." "ERROR"
    Invoke-RebootAndExit 1
}

$ftpBase = "ftp://$FTP_HOST"
if ($FTP_REMOTE) { $ftpBase = "$ftpBase/$($FTP_REMOTE.TrimStart('/'))" }
$ftpBase = $ftpBase.TrimEnd('/')
$cred = New-Object System.Net.NetworkCredential($FTP_USER, $FTP_PASS)

# Check which files are missing on FTP and upload them.
$missingFtp = @()
$checkedCount = 0
foreach ($rel in $treeEntries) {
    $exists = Test-FtpFileExists -FtpBaseUri $ftpBase -Credential $cred -RemoteRelPath $rel
    if (-not $exists) {
        $missingFtp += $rel
    }
    $checkedCount++
    if ($checkedCount % 500 -eq 0) {
        Write-Log "  FTP check progress: $checkedCount / $($treeEntries.Count)..."
    }
}

if ($missingFtp.Count -gt 0) {
    Write-Log "$($missingFtp.Count) file(s) missing on FTP - uploading now..."
    $uploadOk = 0
    $uploadFail = 0
    foreach ($rel in $missingFtp) {
        $localPath = Join-Path $filemanagerDir $rel
        $remoteRel = $rel -replace '\\', '/'
        $parentDir = $remoteRel -replace '/[^/]+$', ''
        if ($parentDir) {
            Ensure-FtpDirectory -FtpBaseUri $ftpBase -Credential $cred -RelativePath $parentDir
        }
        try {
            Upload-FtpFile -FtpBaseUri $ftpBase -Credential $cred `
                           -LocalPath $localPath -RemoteRelPath $remoteRel
            $uploadOk++
        }
        catch {
            $uploadFail++
            Write-Log "  UPLOAD FAILED: $rel - $($_.Exception.Message)" "ERROR"
        }
    }
    Write-Log "FTP upload: $uploadOk succeeded, $uploadFail failed."

    if ($uploadFail -gt 0) {
        Write-Log "*** ABORT: $uploadFail file(s) could not be uploaded to FTP ***" "ERROR"
        Write-Log "SD card will NOT be formatted to prevent data loss." "ERROR"
        Invoke-RebootAndExit 1
    }

    # Re-verify the uploaded files actually exist on FTP.
    Write-Log "Re-verifying uploaded files on FTP..."
    $stillMissing = @()
    foreach ($rel in $missingFtp) {
        $exists = Test-FtpFileExists -FtpBaseUri $ftpBase -Credential $cred -RemoteRelPath $rel
        if (-not $exists) { $stillMissing += $rel }
    }
    if ($stillMissing.Count -gt 0) {
        Write-Log "*** ABORT: $($stillMissing.Count) file(s) still missing on FTP after upload ***" "ERROR"
        foreach ($f in $stillMissing | Select-Object -First 20) {
            Write-Log "  STILL MISSING: $f" "ERROR"
        }
        Invoke-RebootAndExit 1
    }
}

Write-Log "All $($treeEntries.Count) file(s) verified on FTP."

# ============================================================
# PHASE 4: All verified - format SD card, then reboot
# ============================================================
Write-Log ""
Write-Log "---- PHASE 4: SD format (all files verified) ----"
Write-Log "VERIFIED: $($treeEntries.Count) files present locally AND on FTP."
Write-Log "Proceeding with sdformat..."

$session = $null
$success = $false
try {
    $octosLog2 = Join-Path $logDir ("octos_output_weekly_format_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
    $session = Start-OctOSSession -OctOSExe $octosExe -WorkDir $OCTOS_DIR -Arguments $octosArgs -OutputLogPath $octosLog2
    Write-Log "  OctOS PID: $($session.ProcessId)"

    # UVP6 is still stopped from Phase 1 - no need for data check.
    Write-Log "  .. Waiting for OctOS ready ([ME]:)..."
    $ready = Wait-ForMarker -Session $session -MarkerRegex '\[ME\]:' -TimeoutSec 120
    if (-not $ready) { throw "OctOS never became ready." }
    Write-Log "  <- OctOS is ready."
    $session.WriteLine("")

    # sdformat with interactive confirmation.
    Start-Sleep -Seconds $WAIT_SECS
    $session.WriteLine("sdformat")
    Write-Log "  -> Sent: sdformat"

    Write-Log "  .. Waiting for confirmation prompt..."
    $match = Wait-ForMarkerCapture -Session $session -MarkerRegex 'Enter code (\d+)\s*to proceed' -TimeoutSec 120
    if (-not $match) { throw "Timeout waiting for sdformat confirmation prompt." }
    $confirmCode = $match[1]
    Write-Log "  <- Confirmation code: $confirmCode"

    Start-Sleep -Seconds $WAIT_SECS
    $session.WriteLine($confirmCode)
    Write-Log "  -> Sent confirmation code: $confirmCode"

    Write-Log "  .. Waiting for format to complete (timeout ${SDFORMAT_TMO}s)..."
    $ok = Wait-ForMarker -Session $session -MarkerRegex 'Storage capacity in Mb' -TimeoutSec $SDFORMAT_TMO
    if (-not $ok) { throw "Timeout waiting for sdformat to complete." }
    Write-Log "  <- SD format completed."

    # Now reboot to resume acquisition.
    Start-Sleep -Seconds $WAIT_SECS
    $session.WriteLine("reboot")
    Write-Log "  -> Sent: reboot"
    $ok = Wait-ForMarker -Session $session -MarkerRegex '\$startack;' -TimeoutSec 180
    if (-not $ok) { throw "Timeout waiting for `$startack; after format reboot." }
    Write-Log "  <- Received `$startack; - UVP6 acquisition resumed."
    $needsReboot = $false

    Start-Sleep -Seconds $WAIT_SECS
    $session.WriteLine("quit")
    Write-Log "  -> Sent: quit"
    $session.WaitForExit(30000) | Out-Null

    $success = $true
}
catch {
    Write-Log "PHASE 4 FAILED: $_" "ERROR"
    Send-SafetyReboot -Session $session
    $needsReboot = $false
}
finally {
    Close-OctOSSession -Session $session
}

if ($success) {
    Write-Log ""
    Write-Log "SUMMARY: $($treeEntries.Count) files verified, SD card formatted."
    Write-Log "Log: $script:LogFile"
    Write-Log "================================================================="
    Write-Log "  UVP6 WEEKLY VERIFY & CLEANUP - End (OK)"
    Write-Log "================================================================="
    exit 0
}

Write-Log "Log: $script:LogFile"
Write-Log "================================================================="
Write-Log "  UVP6 WEEKLY VERIFY & CLEANUP - End (ERROR in Phase 4)"
Write-Log "================================================================="
exit 1
