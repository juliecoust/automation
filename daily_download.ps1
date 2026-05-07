<#
.SYNOPSIS
    Simple daily UVP6 download via OctOS.

.DESCRIPTION
    Runs one OctOS session with strict sequential commands:
    1) $stop; (wait for $stopack;)
    2) $stop; (wait for $stopack;)
    3) sdlist <HOST_IP> (wait for [SDLIST]: EXIT)
    4) sddump or sddump <TEST_TREE_FILE> (wait for [SDDUMP]: EXIT)
    5) reboot (wait for $startack;)
    6) quit

    Each step runs only if the previous one succeeds.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---- ConPTY (Pseudo Console) Session Helper ----
# OctOS uses ReadConsole (Windows Console API), not stdin pipes.
# We must give it a real pseudo-terminal via CreatePseudoConsole.
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

public class ConPtySession : IDisposable
{
    static readonly Regex AnsiRegex = new Regex(@"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[^\[\]][a-zA-Z]", RegexOptions.Compiled);
    static string StripAnsi(string s) { return AnsiRegex.Replace(s, ""); }
    // ---- P/Invoke declarations ----

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

    // ---- Instance state ----

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

        // Background reader thread.
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
                // Split into lines for readable log.
                string[] lines = chunk.Split(new[] { '\n' }, StringSplitOptions.None);
                foreach (string ln in lines)
                {
                    string clean = StripAnsi(ln.TrimEnd('\r'));
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

    public void WriteLine(string text)
    {
        // ConPTY input pipe requires \r\n to submit a line.
        WriteToPty(text + "\r\n");
    }

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

    public void Kill()
    {
        TerminateProcess(_hProcess, 1);
    }

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

function Wait-ForMarker {
    param(
        [ConPtySession]$Session,
        [string]$MarkerRegex,
        [int]$TimeoutSec
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if ($Session.GetOutput() -match $MarkerRegex) { return $true }
        if ($Session.HasExited) { return $false }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

# ---- OctOS session helpers (same pattern as weekly_cleanup.ps1) ----

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
    Write-Log "  .. Waiting for OctOS ready ([ME]:)..."
    $ready = Wait-ForMarker -Session $Session -MarkerRegex '\[ME\]:' -TimeoutSec 120
    if (-not $ready) { throw "OctOS never became ready (no [ME]: within 120s)." }
    Write-Log "  <- OctOS is ready."

    $Session.WriteLine("")
    Write-Log "  -> Sent: [Enter]"

    Write-Log "  .. Waiting ${DataWaitTimeoutSec}s for data lines (LPM_DATA/BLACK_DATA)..."
    $hasData = Wait-ForMarker -Session $Session -MarkerRegex '(LPM_DATA|BLACK_DATA),' -TimeoutSec $DataWaitTimeoutSec
    if (-not $hasData) {
        Write-Log "  <- No data. Stopping then rebooting..." "WARN"
        $Session.WriteLine('$stop;')
        Start-Sleep -Seconds 2
        $Session.WriteLine('$stop;')
        Start-Sleep -Seconds 2
        $Session.WriteLine('$stop;')
        $stopOk = Wait-ForMarker -Session $Session -MarkerRegex '\$stopack;' -TimeoutSec 30
        if ($stopOk) { Write-Log "  <- Received `$stopack;" }
        else         { Write-Log "  <- No `$stopack; (UVP6 may already be idle)" "WARN" }
        Start-Sleep -Seconds 2
        $Session.WriteLine("reboot")
        Write-Log "  -> Sent: reboot"
        $ok = Wait-ForMarker -Session $Session -MarkerRegex '(\$startack;|HW_CONF,)' -TimeoutSec 180
        if (-not $ok) { throw "Timeout waiting for reboot confirmation." }
        Write-Log "  <- Reboot confirmed."
        $hasData2 = Wait-ForMarker -Session $Session -MarkerRegex '(LPM_DATA|BLACK_DATA),' -TimeoutSec 60
        if (-not $hasData2) { Write-Log "  <- No data after reboot (scheduled mode, waiting for next window)." "WARN" }
        else { Write-Log "  <- Data confirmed after reboot." }
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
            Write-Log "  -> Sending stop before safety reboot..."
            $Session.WriteLine('$stop;')
            Start-Sleep -Seconds 2
            $Session.WriteLine('$stop;')
            Start-Sleep -Seconds 2
            $Session.WriteLine('$stop;')
            $stopOk = Wait-ForMarker -Session $Session -MarkerRegex '\$stopack;' -TimeoutSec 30
            if ($stopOk) { Write-Log "  <- Received `$stopack;" }
            else         { Write-Log "  <- No `$stopack; (may already be stopped)" "WARN" }
            Start-Sleep -Seconds 2
            Write-Log "  -> Sending safety reboot..."
            $Session.WriteLine("reboot")
            $ok = Wait-ForMarker -Session $Session -MarkerRegex '(\$startack;|HW_CONF,)' -TimeoutSec 180
            if ($ok) { Write-Log "  <- Safety reboot OK." }
            else     { Write-Log "  <- Safety reboot: no confirmation within 180s." "WARN" }
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

# ---------------------------
# Main
# ---------------------------

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile   = Join-Path $scriptDir ".env"
$cfg       = Load-EnvFile -Path $envFile

$OCTOS_DIR    = $cfg["OCTOS_DIR"]
$COM_PORT     = $cfg["COM_PORT"]
$HOST_IP      = $cfg["HOST_IP"]
$BAUDRATE     = $cfg["BAUDRATE"]
$WAIT_SECS    = if ($cfg["WAIT_BETWEEN_COMMANDS"]) { [int]$cfg["WAIT_BETWEEN_COMMANDS"] } else { 3 }
$SDLIST_TMO   = if ($cfg["SDLIST_TIMEOUT"])  { [int]$cfg["SDLIST_TIMEOUT"] }  else { 600 }
$SDDUMP_TMO   = if ($cfg["SDDUMP_TIMEOUT"])  { [int]$cfg["SDDUMP_TIMEOUT"] }  else { 3600 }
$DATA_WAIT    = if ($cfg["DATA_WAIT_TIMEOUT"]) { [int]$cfg["DATA_WAIT_TIMEOUT"] } else { 15 }
$MAX_RETRIES  = if ($cfg["MAX_RETRIES"])  { [int]$cfg["MAX_RETRIES"] }  else { 3 }
$RETRY_DELAY  = if ($cfg["RETRY_DELAY"])  { [int]$cfg["RETRY_DELAY"] }  else { 10 }
$OCTOS_LOG_EN = $cfg["OCTOS_OUTPUT_LOG"] -eq 'true'

$octosExe = Join-Path $OCTOS_DIR "bin\OctOS.exe"
if (-not (Test-Path $octosExe)) { throw "OctOS.exe not found: $octosExe" }

$logDir = Join-Path $OCTOS_DIR "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$script:LogFile = Join-Path $logDir ("download_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")

Write-Log "================================================================="
Write-Log "  UVP6 DAILY DOWNLOAD - Start"
Write-Log "================================================================="
Write-Log "Configuration: COM$COM_PORT | Host=$HOST_IP"

$octosArgs = "$COM_PORT"
if ($BAUDRATE) { $octosArgs += " $BAUDRATE" }

# Rotate tree files before sdlist writes a new one.
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

for ($attempt = 1; $attempt -le $MAX_RETRIES; $attempt++) {
    if ($attempt -gt 1) {
        Write-Log "Retry $attempt/$MAX_RETRIES after ${RETRY_DELAY}s..." "WARN"
        Start-Sleep -Seconds $RETRY_DELAY
    }

    $session = $null
    try {
        $octosLog = if ($OCTOS_LOG_EN) {
            Join-Path $logDir ("octos_output_download_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
        } else { $null }
        if ($octosLog) { Write-Log "OctOS output log: $octosLog" }

        $session = Start-OctOSSession -OctOSExe $octosExe -WorkDir $OCTOS_DIR -Arguments $octosArgs -OutputLogPath $octosLog
        Write-Log "  OctOS PID: $($session.ProcessId)"

        Initialize-OctOSSession -Session $session -DataWaitTimeoutSec $DATA_WAIT
        Send-StopSequence -Session $session -DelaySec $WAIT_SECS

        # sdlist â€” build fresh SD card file listing
        Start-Sleep -Seconds $WAIT_SECS
        $session.WriteLine("sdlist $HOST_IP")
        Write-Log "  -> Sent: sdlist $HOST_IP"
        Write-Log "  .. Waiting for [SDLIST] EXIT (timeout ${SDLIST_TMO}s)..."
        $ok = Wait-ForMarker -Session $session -MarkerRegex '\[SDLIST\].*EXIT' -TimeoutSec $SDLIST_TMO
        if (-not $ok) { throw "Timeout waiting for sdlist to complete." }
        # [SDLIST]: EXIT appears on both success AND error — check for the error case explicitly.
        if ($session.GetOutput() -match 'Command sdlist returned an error') {
            throw "sdlist exited with error (tree.txt transfer failed or other sdlist error)."
        }
        Write-Log "  <- sdlist completed."

        # sddump â€” download files not yet on disk
        Start-Sleep -Seconds $WAIT_SECS
        $session.WriteLine("sddump tree.txt")
        Write-Log "  -> Sent: sddump tree.txt"
        Write-Log "  .. Waiting for [SDDUMP] EXIT (timeout ${SDDUMP_TMO}s)..."
        $ok = Wait-ForMarker -Session $session -MarkerRegex '\[SDDUMP\].*EXIT' -TimeoutSec $SDDUMP_TMO
        if (-not $ok) { throw "Timeout waiting for sddump to complete." }
        # [SDDUMP]: EXIT appears on both success AND error — check for the error case explicitly.
        if ($session.GetOutput() -match 'Command sddump returned an error') {
            throw "sddump exited with error."
        }
        Write-Log "  <- sddump completed."

        # reboot â€” resume UVP6 acquisition
        Start-Sleep -Seconds $WAIT_SECS
        $session.WriteLine("reboot")
        Write-Log "  -> Sent: reboot"
        Write-Log "  .. Waiting for reboot confirmation..."
        $ok = Wait-ForMarker -Session $session -MarkerRegex '(\$startack;|HW_CONF,)' -TimeoutSec 180
        if (-not $ok) { throw "Timeout waiting for reboot confirmation." }
        Write-Log "  <- UVP6 rebooted and resuming acquisition."

        Start-Sleep -Seconds $WAIT_SECS
        $session.WriteLine("quit")
        Write-Log "  -> Sent: quit"
        $session.WaitForExit(30000) | Out-Null

        $success = $true
        break
    }
    catch {
        Write-Log "Attempt $attempt FAILED: $_" "ERROR"
        if ($attempt -lt $MAX_RETRIES) {
            Send-SafetyReboot -Session $session
        } else {
            Send-SafetyReboot -Session $session
        }
    }
    finally {
        Close-OctOSSession -Session $session
        $session = $null
    }
}

if (-not $success) {
    Write-Log "Download failed after $MAX_RETRIES attempt(s)." "ERROR"
    Write-Log "================================================================="
    Write-Log "  UVP6 DAILY DOWNLOAD - End (ERROR)"
    Write-Log "================================================================="
    exit 1
}

Write-Log "Download completed successfully."
Write-Log "================================================================="
Write-Log "  UVP6 DAILY DOWNLOAD - End (OK)"
Write-Log "================================================================="
exit 0
