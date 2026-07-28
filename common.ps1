<#
.SYNOPSIS
    Shared helpers for the UVP6 automation scripts.

.DESCRIPTION
    Dot-source this file from the entry-point scripts:

        . (Join-Path $PSScriptRoot 'common.ps1')

    Provides:
      - ConPtySession       : pseudo-console wrapper to drive OctOS.exe
                              (OctOS reads input via the Windows Console API,
                              not stdin pipes, so it needs a real ConPTY)
      - Load-EnvFile        : .env parser
      - Write-Log           : console + file logger (uses $script:LogFile)
      - Wait-ForMarker(Capture) : poll OctOS output for a regex marker.
                              IMPORTANT: pass -FromOffset (captured with
                              $session.GetOutputLength() just BEFORE sending a
                              command) so that only output produced AFTER the
                              command can match. Matching the whole buffer can
                              hit acknowledgements left over from earlier
                              commands (e.g. a HW_CONF from a recovery reboot)
                              and report success for a command that never
                              completed.
      - OctOS session helpers (start / init / stop sequence / safety reboot /
                              standalone reboot / close)
      - Invoke-OctOSDownloadAttempt : one full download attempt (fresh session,
                              stop, sdlist, sddump, optional reboot, safety
                              reboot on failure) shared by download.ps1 and
                              cleanup.ps1 Phase 1
      - SFTP helpers (Posh-SSH) including a recursive remote file index used
                              for fast existence + size verification
      - Enter/Exit-ScriptLock : cross-script lock so two OctOS sessions never
                              fight over the same COM port
#>

Set-StrictMode -Version Latest

# ---- ConPTY (Pseudo Console) session helper ----
if (-not ([System.Management.Automation.PSTypeName]'ConPtySession').Type) {
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

    // Current length of the output buffer. Capture this just BEFORE sending a
    // command, then pass it to GetOutputFrom / Wait-ForMarker so only output
    // produced after the command is inspected.
    public int GetOutputLength()
    {
        lock (_bufferLock) { return OutputBuffer.Length; }
    }

    public string GetOutputFrom(int offset)
    {
        lock (_bufferLock)
        {
            if (offset < 0) offset = 0;
            if (offset >= OutputBuffer.Length) return "";
            return OutputBuffer.ToString(offset, OutputBuffer.Length - offset);
        }
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
}

# ---------------------------
# Generic helpers
# ---------------------------

function Load-EnvFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Configuration file not found: $Path (copy .env.empty to .env and fill it in)"
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

function Strip-Ansi {
    param([string]$Text)
    # Remove ANSI/VT100 escape sequences (CSI, OSC, simple escapes).
    return $Text -replace '\x1b\[[0-9;]*[a-zA-Z]', '' -replace '\x1b\][^\x07]*\x07', '' -replace '\x1b[^\[\]][a-zA-Z]', ''
}

# ---------------------------
# Cross-script lock (one OctOS session at a time on the COM port)
# ---------------------------

function Enter-ScriptLock {
    param([string]$LockFile)

    if (Test-Path $LockFile) {
        $lockPid = Get-Content $LockFile -ErrorAction SilentlyContinue | Select-Object -First 1
        $proc = $null
        if ($lockPid -match '^\d+$') {
            $proc = Get-Process -Id ([int]$lockPid) -ErrorAction SilentlyContinue
        }
        if ($proc -and $proc.ProcessName -match 'powershell|pwsh') {
            return $false
        }
        # Stale lock (owning process is gone) - take over.
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    }
    Set-Content -Path $LockFile -Value $PID -Encoding ASCII
    return $true
}

function Exit-ScriptLock {
    param([string]$LockFile)
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}

# ---------------------------
# Output polling
# ---------------------------

# Scan at most this many chars of recent output per poll (keeps the regex cost
# bounded on very long sessions such as multi-hour sddump runs).
$script:MaxMarkerScanChars = 4MB

function Wait-ForMarker {
    param(
        [ConPtySession]$Session,
        [string]$MarkerRegex,
        [int]$TimeoutSec,
        [int]$FromOffset = 0
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $len = $Session.GetOutputLength()
        $start = $FromOffset
        if (($len - $start) -gt $script:MaxMarkerScanChars) { $start = $len - $script:MaxMarkerScanChars }
        $clean = Strip-Ansi ($Session.GetOutputFrom($start))
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
        [int]$TimeoutSec,
        [int]$FromOffset = 0
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $len = $Session.GetOutputLength()
        $start = $FromOffset
        if (($len - $start) -gt $script:MaxMarkerScanChars) { $start = $len - $script:MaxMarkerScanChars }
        $clean = Strip-Ansi ($Session.GetOutputFrom($start))
        if ($clean -match $MarkerRegex) { return $Matches }
        if ($Session.HasExited) { return $null }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

# ---------------------------
# OctOS session helpers
# ---------------------------

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
        Write-Log "  <- No data. Sending stop..." "WARN"
        $mark = $Session.GetOutputLength()
        $Session.WriteLine('$stop;')
        Start-Sleep -Seconds 2
        $Session.WriteLine('$stop;')
        Start-Sleep -Seconds 2
        $Session.WriteLine('$stop;')
        $stopOk = Wait-ForMarker -Session $Session -MarkerRegex '\$stopack;' -TimeoutSec 30 -FromOffset $mark
        if ($stopOk) {
            Write-Log "  <- Received `$stopack; - UVP6 stopped cleanly, no reboot needed."
        } else {
            Write-Log "  <- No `$stopack; - rebooting to recover..." "WARN"
            Start-Sleep -Seconds 2
            $mark = $Session.GetOutputLength()
            $Session.WriteLine("reboot")
            Write-Log "  -> Sent: reboot"
            $ok = Wait-ForMarker -Session $Session -MarkerRegex '(\$startack;|HW_CONF,)' -TimeoutSec 180 -FromOffset $mark
            if (-not $ok) { throw "Timeout waiting for reboot confirmation (no `$startack; or HW_CONF)." }
            Write-Log "  <- Reboot confirmed."
            $hasData2 = Wait-ForMarker -Session $Session -MarkerRegex '(LPM_DATA|BLACK_DATA),' -TimeoutSec 60 -FromOffset $mark
            if (-not $hasData2) { Write-Log "  <- No data after reboot (scheduled mode, waiting for next window)." "WARN" }
            else { Write-Log "  <- Data confirmed after reboot." }
        }
    } else {
        Write-Log "  <- Data lines detected."
    }
}

function Send-StopSequence {
    param(
        [ConPtySession]$Session,
        [int]$DelaySec
    )
    $mark = $Session.GetOutputLength()
    foreach ($i in 1..3) {
        Start-Sleep -Seconds $DelaySec
        $Session.WriteLine('$stop;')
        Write-Log "  -> Sent (stop_$i): `$stop;"
        if ($i -eq 3) {
            Write-Log "  .. Waiting for `$stopack;..."
            $ok = Wait-ForMarker -Session $Session -MarkerRegex '\$stopack;' -TimeoutSec 30 -FromOffset $mark
            if (-not $ok) { throw "Timeout waiting for `$stopack;" }
            Write-Log "  <- Received `$stopack;"
        }
    }
}

# Attempts to stop then reboot the UVP6 on the CURRENT session so acquisition
# resumes after a failed run. Returns $true only when the reboot is confirmed.
function Send-SafetyReboot {
    param([ConPtySession]$Session)

    if (-not $Session -or $Session.HasExited) {
        Write-Log "  Safety reboot skipped: OctOS session is not alive." "WARN"
        return $false
    }
    try {
        Write-Log "  -> Sending stop before safety reboot..."
        $mark = $Session.GetOutputLength()
        $Session.WriteLine('$stop;')
        Start-Sleep -Seconds 2
        $Session.WriteLine('$stop;')
        Start-Sleep -Seconds 2
        $Session.WriteLine('$stop;')
        $stopOk = Wait-ForMarker -Session $Session -MarkerRegex '\$stopack;' -TimeoutSec 30 -FromOffset $mark
        if ($stopOk) { Write-Log "  <- Received `$stopack;" }
        else         { Write-Log "  <- No `$stopack; (may already be stopped)" "WARN" }
        Start-Sleep -Seconds 2
        Write-Log "  -> Sending safety reboot..."
        $mark = $Session.GetOutputLength()
        $Session.WriteLine("reboot")
        $ok = Wait-ForMarker -Session $Session -MarkerRegex '(\$startack;|HW_CONF,)' -TimeoutSec 180 -FromOffset $mark
        if ($ok) { Write-Log "  <- Safety reboot OK." }
        else     { Write-Log "  <- Safety reboot: no confirmation within 180s." "WARN" }
        return $ok
    }
    catch {
        Write-Log "  <- Safety reboot failed: $_" "WARN"
        return $false
    }
}

# Opens a FRESH OctOS session for the sole purpose of stopping and rebooting
# the UVP6 (used as a last resort when the main session is gone but the
# instrument may still be stopped). Returns $true when the reboot is confirmed.
function Invoke-StandaloneReboot {
    param(
        [string]$OctOSExe,
        [string]$WorkDir,
        [string]$Arguments,
        [string]$OutputLogPath,
        [int]$WaitSecs = 3
    )
    $s = $null
    try {
        $s = Start-OctOSSession -OctOSExe $OctOSExe -WorkDir $WorkDir -Arguments $Arguments -OutputLogPath $OutputLogPath
        $ready = Wait-ForMarker -Session $s -MarkerRegex '\[ME\]:' -TimeoutSec 120
        if (-not $ready) {
            Write-Log "  Standalone reboot: OctOS not ready." "WARN"
            return $false
        }
        $s.WriteLine("")
        Start-Sleep -Seconds $WaitSecs
        $mark = $s.GetOutputLength()
        $s.WriteLine('$stop;')
        Start-Sleep -Seconds 2
        $s.WriteLine('$stop;')
        Start-Sleep -Seconds 2
        $s.WriteLine('$stop;')
        $stopOk = Wait-ForMarker -Session $s -MarkerRegex '\$stopack;' -TimeoutSec 30 -FromOffset $mark
        if ($stopOk) { Write-Log "  <- Received `$stopack;" }
        else         { Write-Log "  <- No `$stopack; (may already be stopped)" "WARN" }
        Start-Sleep -Seconds $WaitSecs
        $mark = $s.GetOutputLength()
        $s.WriteLine("reboot")
        Write-Log "  -> Sent: reboot"
        $ok = Wait-ForMarker -Session $s -MarkerRegex '(\$startack;|HW_CONF,)' -TimeoutSec 180 -FromOffset $mark
        if ($ok) { Write-Log "  <- UVP6 rebooted successfully." }
        else     { Write-Log "  <- No reboot confirmation within 180s." "WARN" }
        Start-Sleep -Seconds $WaitSecs
        $s.WriteLine("quit")
        $s.WaitForExit(15000) | Out-Null
        return $ok
    }
    catch {
        Write-Log "  Standalone reboot failed: $_" "WARN"
        return $false
    }
    finally {
        Close-OctOSSession -Session $s
    }
}

function Close-OctOSSession {
    param([ConPtySession]$Session)
    if ($Session) {
        if (-not $Session.HasExited) { $Session.Kill() }
        $Session.Dispose()
    }
}

# Runs ONE complete download attempt on a fresh OctOS session:
#   initialize (data check / stop recovery), stop sequence, sdlist, sddump,
#   then either reboot+quit (-RebootAfter) or quit leaving the UVP6 stopped.
# On any failure the session's safety reboot is attempted before returning.
#
# Returns [pscustomobject] @{ Success; SafetyRebootOk; Error }
#   Success        : $true when every step completed
#   SafetyRebootOk : on failure, whether the safety reboot was confirmed
#   Error          : failure message ($null on success)
#
# Optional -OnStep scriptblock for per-step instrumentation, invoked as
#   & $OnStep <step> <event> [<detail>]
# with steps/events:
#   'stopped'/'ok'      stop sequence acknowledged (instrument is stopped)
#   'sdlist'/'start|ok' sdlist began / completed
#   'sddump'/'start|ok' sddump began / completed
#   'attempt'/'error'   attempt failed (detail = error message), sent BEFORE
#                       the safety reboot so timings stay accurate
# Counts failed file transmissions in a block of OctOS output. Used for the
# per-run transfer-failure statistics logged during sdlist/sddump.
function Count-TransferFailures {
    param([string]$Output)
    if (-not $Output) { return 0 }
    return ([regex]::Matches($Output,
        'file transmission was incomplete|transmission header not received')).Count
}

# Counts data files currently in the local filemanager folder, ignoring the
# tree.txt bookkeeping files. Used to measure download progress vs the SD card.
function Get-FilemanagerFileCount {
    param([string]$FilemanagerDir)
    if (-not (Test-Path $FilemanagerDir)) { return 0 }
    return @(Get-ChildItem -Path $FilemanagerDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike 'tree*.txt' -and $_.Name -ne 'previous_tree.txt' }).Count
}

function Invoke-OctOSDownloadAttempt {
    param(
        [string]$OctOSExe,
        [string]$WorkDir,
        [string]$Arguments,
        [string]$OutputLogPath,
        [string]$HostIp,
        [int]$WaitSecs,
        [int]$DataWaitTimeoutSec,
        [int]$SdlistTimeoutSec,
        [int]$SddumpTimeoutSec,
        [int]$SdlistInSessionRetries = 10,
        [int]$SdlistRetryDelaySec = 10,
        [int]$SddumpInSessionRetries = 5,
        [int]$MaxDownloadMinutes = 28,
        [switch]$RebootAfter,
        [scriptblock]$OnStep,
        [string]$FailureLabel = "Download attempt"
    )

    $session = $null
    try {
        if ($OutputLogPath) { Write-Log "OctOS output log: $OutputLogPath" }

        $session = Start-OctOSSession -OctOSExe $OctOSExe -WorkDir $WorkDir -Arguments $Arguments -OutputLogPath $OutputLogPath
        Write-Log "  OctOS PID: $($session.ProcessId)"

        Initialize-OctOSSession -Session $session -DataWaitTimeoutSec $DataWaitTimeoutSec
        Send-StopSequence -Session $session -DelaySec $WaitSecs
        if ($OnStep) { & $OnStep 'stopped' 'ok' }

        # Wall-clock budget for this download session: once exceeded we stop
        # retrying, reboot (resume acquisition) and return - the instrument is
        # never held stopped much longer than this. 0 = unlimited.
        $downloadDeadline = if ($MaxDownloadMinutes -gt 0) { (Get-Date).AddMinutes($MaxDownloadMinutes) } else { $null }
        $budgetReached = $false
        $sddumpOk = $false

        # sdlist - build fresh SD card file listing.
        # Retries within the same OctOS session WITHOUT rebooting: the tree.txt
        # transfer is a lossy UDP download that frequently needs several attempts
        # to complete (OctOS itself reports "file transmission was incomplete").
        # Rebooting between tries would be wasteful and, in scheduled mode,
        # disruptive - so we simply re-send sdlist on the same live session.
        Start-Sleep -Seconds $WaitSecs
        if ($OnStep) { & $OnStep 'sdlist' 'start' }
        $sdlistOk = $false
        $sdlistTotalAttempts = $SdlistInSessionRetries + 1
        $sdlistFailedTransfers = 0
        for ($sdlistTry = 1; $sdlistTry -le $sdlistTotalAttempts; $sdlistTry++) {
            if ($sdlistTry -gt 1) {
                if ($downloadDeadline -and (Get-Date) -gt $downloadDeadline) {
                    Write-Log "  Time budget (${MaxDownloadMinutes} min) reached during sdlist - stopping retries." "WARN"
                    $budgetReached = $true
                    break
                }
                Write-Log "  sdlist tree.txt transfer failed - retrying within session ($sdlistTry/$sdlistTotalAttempts) after ${SdlistRetryDelaySec}s..." "WARN"
                # A longer pause than the usual inter-command delay: each sdlist
                # re-powers the Processing Unit, and firing them too close can hit
                # "PU is powered, but the READY signal wasn't set". Let the PU settle.
                Start-Sleep -Seconds $SdlistRetryDelaySec
            }
            $mark = $session.GetOutputLength()
            $session.WriteLine("sdlist $HostIp")
            Write-Log "  -> Sent: sdlist $HostIp"
            Write-Log "  .. Waiting for [SDLIST] EXIT (timeout ${SdlistTimeoutSec}s)..."
            $ok = Wait-ForMarker -Session $session -MarkerRegex '\[SDLIST\].*EXIT' -TimeoutSec $SdlistTimeoutSec -FromOffset $mark
            if (-not $ok) { throw "Timeout waiting for sdlist to complete." }
            $sdlistOut = $session.GetOutputFrom($mark)
            $sdlistFailedTransfers += (Count-TransferFailures $sdlistOut)
            # [SDLIST]: EXIT appears on both success AND error - check the error case explicitly.
            if ($sdlistOut -match 'Command sdlist returned an error') {
                Write-Log "  <- sdlist exited with error (tree.txt transfer incomplete)." "WARN"
            } else {
                $sdlistOk = $true
                break
            }
        }
        if (-not $sdlistOk) {
            if ($budgetReached) {
                Write-Log "  sdlist did not complete within the ${MaxDownloadMinutes}-min budget - no listing this run." "WARN"
            } else {
                throw "sdlist still failing after $sdlistTotalAttempts in-session attempt(s) ($sdlistFailedTransfers failed transmission(s))."
            }
        } else {
            $sdlistFailPct = [math]::Round(100.0 * $sdlistFailedTransfers / ($sdlistFailedTransfers + 1), 0)
            Write-Log "  <- sdlist completed on attempt $sdlistTry/$sdlistTotalAttempts - $sdlistFailedTransfers failed transmission(s) before success (~$sdlistFailPct% failure rate)."
            if ($OnStep) { & $OnStep 'sdlist' 'ok' }
        }

        # sddump - download files not yet on disk. Only if sdlist produced a
        # listing this run (skipped when the time budget cut sdlist short).
        # Retries within the same OctOS session: when sddump reports failures,
        # re-running it immediately picks up only the remaining files, avoiding
        # the overhead of a full stop/sdlist/reboot cycle for each retry.
        if ($sdlistOk) {
            Start-Sleep -Seconds $WaitSecs
            if ($OnStep) { & $OnStep 'sddump' 'start' }
            $fmDir     = Join-Path $WorkDir 'filemanager'
            $treeFile  = Join-Path $fmDir 'tree.txt'
            $filesBefore = Get-FilemanagerFileCount -FilemanagerDir $fmDir
            $sddumpTotalAttempts = $SddumpInSessionRetries + 1
            $sddumpFailedTransfers = 0
            for ($sddumpTry = 1; $sddumpTry -le $sddumpTotalAttempts; $sddumpTry++) {
                if ($sddumpTry -gt 1) {
                    if ($downloadDeadline -and (Get-Date) -gt $downloadDeadline) {
                        Write-Log "  Time budget (${MaxDownloadMinutes} min) reached during sddump - stopping retries (partial progress kept)." "WARN"
                        $budgetReached = $true
                        break
                    }
                    Write-Log "  sddump had file failures - retrying within session ($sddumpTry/$sddumpTotalAttempts)..." "WARN"
                    Start-Sleep -Seconds $WaitSecs
                }
                $mark = $session.GetOutputLength()
                $session.WriteLine("sddump tree.txt")
                Write-Log "  -> Sent: sddump tree.txt"
                Write-Log "  .. Waiting for [SDDUMP] EXIT (timeout ${SddumpTimeoutSec}s)..."
                $ok = Wait-ForMarker -Session $session -MarkerRegex '\[SDDUMP\].*EXIT' -TimeoutSec $SddumpTimeoutSec -FromOffset $mark
                if (-not $ok) { throw "Timeout waiting for sddump to complete." }
                $sddumpOut = $session.GetOutputFrom($mark)
                $sddumpFailedTransfers += (Count-TransferFailures $sddumpOut)
                if ($sddumpOut -match 'Command sddump returned an error') {
                    Write-Log "  <- sddump exited with errors (some files failed)." "WARN"
                } else {
                    $sddumpOk = $true
                    break
                }
            }
            if (-not $sddumpOk -and -not $budgetReached) {
                throw "sddump still has failures after $sddumpTotalAttempts in-session attempt(s) ($sddumpFailedTransfers failed transmission(s))."
            }
            # Per-run transfer statistics (also logged on a budget-limited partial run).
            $filesAfter = Get-FilemanagerFileCount -FilemanagerDir $fmDir
            $downloadedThisRun = [math]::Max(0, $filesAfter - $filesBefore)
            $sddumpDenom = $sddumpFailedTransfers + $downloadedThisRun
            $sddumpFailPct = if ($sddumpDenom -gt 0) { [math]::Round(100.0 * $sddumpFailedTransfers / $sddumpDenom, 0) } else { 0 }
            $sddumpVerb = if ($sddumpOk) { "completed" } else { "stopped on budget" }
            Write-Log "  <- sddump $sddumpVerb after $sddumpTry run(s): +$downloadedThisRun file(s) this run, $sddumpFailedTransfers failed transmission(s) (~$sddumpFailPct% failure rate)."
            # Overall backlog progress vs the SD listing (tree.txt = one path per line).
            $totalListed = @(Get-Content $treeFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }).Count
            if ($totalListed -gt 0) {
                $present = [math]::Min($filesAfter, $totalListed)
                $pct = [math]::Round(100.0 * $present / $totalListed, 1)
                Write-Log "  Download progress: $present/$totalListed files on disk ($pct%), $($totalListed - $present) still missing on SD."
            }
            if ($sddumpOk -and $OnStep) { & $OnStep 'sddump' 'ok' }
        }

        if ($RebootAfter) {
            # reboot - resume UVP6 acquisition.
            Start-Sleep -Seconds $WaitSecs
            $mark = $session.GetOutputLength()
            $session.WriteLine("reboot")
            Write-Log "  -> Sent: reboot"
            Write-Log "  .. Waiting for reboot confirmation..."
            $ok = Wait-ForMarker -Session $session -MarkerRegex '(\$startack;|HW_CONF,)' -TimeoutSec 180 -FromOffset $mark
            if (-not $ok) { throw "Timeout waiting for reboot confirmation." }
            Write-Log "  <- UVP6 rebooted and resuming acquisition."
        }

        Start-Sleep -Seconds $WaitSecs
        $session.WriteLine("quit")
        if ($RebootAfter) { Write-Log "  -> Sent: quit" }
        else              { Write-Log "  -> Sent: quit (UVP6 stays stopped)" }
        $session.WaitForExit(30000) | Out-Null

        return [pscustomobject]@{ Success = ($sdlistOk -and $sddumpOk); BudgetReached = $budgetReached; SafetyRebootOk = $false; Error = $null }
    }
    catch {
        $errMsg = "$_"
        Write-Log "$FailureLabel FAILED: $errMsg" "ERROR"
        if ($OnStep) { & $OnStep 'attempt' 'error' $errMsg }
        $rebootOk = Send-SafetyReboot -Session $session
        return [pscustomobject]@{ Success = $false; BudgetReached = $false; SafetyRebootOk = $rebootOk; Error = $errMsg }
    }
    finally {
        Close-OctOSSession -Session $session
    }
}

# ---------------------------
# SFTP helpers (Posh-SSH)
# ---------------------------

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
                    # Some servers return a generic Failure for already-existing
                    # dirs. Re-check via the same client; only throw if truly absent.
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

# Builds a hashtable "remote full path -> file size" by walking the remote
# tree once. One round-trip per DIRECTORY instead of one per FILE, which is
# what makes verifying tens of thousands of files tractable.
function Get-SftpFileIndex {
    param($Session, [string]$RootPath)

    $index = @{}
    $client = $Session.Session
    $root = if ($RootPath) { $RootPath } else { "/" }
    if (-not ($client.Exists($root))) { return $index }

    $stack = New-Object System.Collections.Stack
    $stack.Push($root)
    $dirCount = 0
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($item in $client.ListDirectory($dir)) {
            if ($item.Name -eq '.' -or $item.Name -eq '..') { continue }
            if ($item.IsDirectory) {
                $stack.Push($item.FullName)
            } else {
                $index[$item.FullName] = [long]$item.Length
            }
        }
        $dirCount++
        if (($dirCount % 200) -eq 0) {
            Write-Log "  Remote listing progress: $dirCount directories, $($index.Count) files so far..."
        }
    }
    return $index
}

# Returns the remote file size, or -1 if the file does not exist / cannot be read.
function Get-SftpRemoteSize {
    param($Session, [string]$RemotePath)
    try {
        return [long]$Session.Session.GetAttributes($RemotePath).Size
    } catch {
        return -1
    }
}
