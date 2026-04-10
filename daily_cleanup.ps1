<#
.SYNOPSIS
    Daily UVP6 SD card format (cleanup) via OctOS.

.DESCRIPTION
    Runs one OctOS session with strict sequential commands:
    1) $stop; (x3, wait for $stopack;)
    2) sdformat (wait for [SDFORMAT]: EXIT)
    3) reboot (wait for $startack;)
    4) quit

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

public class ConPtySession : IDisposable
{
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
    Thread _readerThread;
    volatile bool _stopReading;
    string _outputLogPath;
    bool _disposed;

    public ConPtySession() { OutputBuffer = new StringBuilder(); }

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
            OutputBuffer.Append(chunk);

            if (_outputLogPath != null)
            {
                string ts = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
                // Split into lines for readable log.
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

function Strip-Ansi {
    param([string]$Text)
    # Remove ANSI/VT100 escape sequences (CSI, OSC, simple escapes).
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
        $clean = Strip-Ansi $Session.OutputBuffer.ToString()
        if ($clean -match $MarkerRegex) {
            return $true
        }

        if ($Session.HasExited) {
            return $false
        }

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
        $clean = Strip-Ansi $Session.OutputBuffer.ToString()
        if ($clean -match $MarkerRegex) {
            return $Matches
        }

        if ($Session.HasExited) {
            return $null
        }

        Start-Sleep -Milliseconds 400
    }

    return $null
}

# ---------------------------
# Main
# ---------------------------

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile = Join-Path $scriptDir ".env"
$cfg = Load-EnvFile -Path $envFile

$OCTOS_DIR = $cfg["OCTOS_DIR"]
$COM_PORT = $cfg["COM_PORT"]
$HOST_IP = $cfg["HOST_IP"]
$BAUDRATE = $cfg["BAUDRATE"]
$WAIT_SECS = if ($cfg["WAIT_BETWEEN_COMMANDS"]) { [int]$cfg["WAIT_BETWEEN_COMMANDS"] } else { 3 }
$SDFORMAT_TMO = if ($cfg["SDFORMAT_TIMEOUT"]) { [int]$cfg["SDFORMAT_TIMEOUT"] } else { 3600 }

$octosExe = Join-Path $OCTOS_DIR "bin\OctOS.exe"
if (-not (Test-Path $octosExe)) {
    throw "OctOS.exe not found: $octosExe"
}

$logDir = Join-Path $OCTOS_DIR "logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$script:LogFile = Join-Path $logDir ("cleanup_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")

Write-Log "================================================================="
Write-Log "  UVP6 DAILY CLEANUP (SD FORMAT) - Start"
Write-Log "================================================================="
Write-Log "Configuration: COM$COM_PORT | Host=$HOST_IP | Baud=$BAUDRATE"

$octosArgs = "$COM_PORT"
if ($BAUDRATE) { $octosArgs += " $BAUDRATE" }

$sessionTimeout = [Math]::Max($SDFORMAT_TMO + 300, 900)
$session = $null
$success = $false

try {
    # Dedicated log file for raw OctOS output.
    $script:OctosOutputLog = Join-Path $logDir ("octos_output_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
    Write-Log "OctOS output log: $($script:OctosOutputLog)"

    $commandLine = "`"$octosExe`" $octosArgs"
    $session = New-Object ConPtySession
    Write-Log "Launching OctOS via ConPTY: $commandLine"
    $session.Start($octosExe, $commandLine, $OCTOS_DIR, $script:OctosOutputLog)
    Write-Log "  OctOS PID: $($session.ProcessId)"

    # Wait for OctOS to be ready.
    Write-Log "  .. Waiting for OctOS to be ready (looking for '[ME]:')..."
    $ready = Wait-ForMarker -Session $session -MarkerRegex '\[ME\]:' -TimeoutSec 120
    if (-not $ready) {
        throw "OctOS never became ready (no [ME]: prompt within 120s)."
    }
    Write-Log "  <- OctOS is ready."

    $session.WriteLine("")
    Write-Log "  -> Sent: [Enter]"

    # ---- Check for data lines; reboot if UVP6 is not sending data ----
    $DATA_WAIT = if ($cfg["DATA_WAIT_TIMEOUT"]) { [int]$cfg["DATA_WAIT_TIMEOUT"] } else { 15 }
    Write-Log "  .. Waiting ${DATA_WAIT}s for data lines (LPM_DATA/BLACK_DATA)..."
    $hasData = Wait-ForMarker -Session $session -MarkerRegex '(LPM_DATA|BLACK_DATA),' -TimeoutSec $DATA_WAIT
    if (-not $hasData) {
        Write-Log "  <- No data lines received. Sending reboot to wake UVP6..." "WARN"
        $session.WriteLine("reboot")
        Write-Log "  -> Sent: reboot"
        Write-Log "  .. Waiting for `$startack;..."
        $ok = Wait-ForMarker -Session $session -MarkerRegex '\$startack;' -TimeoutSec 180
        if (-not $ok) { throw "Timeout waiting for `$startack; after pre-reboot." }
        Write-Log "  <- Received `$startack;"

        Write-Log "  .. Waiting for data lines after reboot..."
        $hasData2 = Wait-ForMarker -Session $session -MarkerRegex '(LPM_DATA|BLACK_DATA),' -TimeoutSec 60
        if (-not $hasData2) {
            throw "UVP6 still not sending data after reboot."
        }
        Write-Log "  <- Data lines confirmed after reboot."
    } else {
        Write-Log "  <- Data lines detected, UVP6 is active."
    }

    # ---- Step 1-3: $stop; (x3) ----
    $firstStopSentAt = $null
    foreach ($i in 1..3) {
        Start-Sleep -Seconds $WAIT_SECS
        $session.WriteLine('$stop;')
        Write-Log "  -> Sent (stop_$i): `$stop;"
        if ($i -eq 1) { $firstStopSentAt = Get-Date }
        if ($i -eq 3) {
            Write-Log "  .. Waiting for `$stopack;..."
            $ok = Wait-ForMarker -Session $session -MarkerRegex '\$stopack;' -TimeoutSec 30
            if (-not $ok) { throw "Timeout waiting for `$stopack;" }
            Write-Log "  <- Received `$stopack;"
        }
    }

    # ---- Step 4: sdformat (interactive confirmation) ----
    Start-Sleep -Seconds $WAIT_SECS
    $session.WriteLine("sdformat")
    Write-Log "  -> Sent: sdformat"

    # Wait for the confirmation prompt: "Enter code XXXX to proceed"
    Write-Log "  .. Waiting for sdformat confirmation prompt..."
    $match = Wait-ForMarkerCapture -Session $session -MarkerRegex 'Enter code (\d+)\s*to proceed' -TimeoutSec 120
    if (-not $match) {
        throw "Timeout waiting for sdformat confirmation prompt."
    }
    $confirmCode = $match[1]
    Write-Log "  <- Confirmation prompt received (code: $confirmCode)"

    # Send the confirmation code
    Start-Sleep -Seconds $WAIT_SECS
    $session.WriteLine($confirmCode)
    Write-Log "  -> Sent confirmation code: $confirmCode"

    # Wait for format to complete — match the capacity report that follows "Done !"
    Write-Log "  .. Waiting for format to complete (timeout ${SDFORMAT_TMO}s)..."
    $ok = Wait-ForMarker -Session $session -MarkerRegex 'Storage capacity in Mb' -TimeoutSec $SDFORMAT_TMO
    if (-not $ok) {
        throw "Timeout waiting for sdformat to complete."
    }
    Write-Log "  <- SD format completed successfully."

    # ---- Step 5: reboot ----
    Start-Sleep -Seconds $WAIT_SECS
    $session.WriteLine("reboot")
    Write-Log "  -> Sent: reboot"
    Write-Log "  .. Waiting for `$startack;..."
    $ok = Wait-ForMarker -Session $session -MarkerRegex '\$startack;' -TimeoutSec 180
    if (-not $ok) { throw "Timeout waiting for `$startack; after reboot." }
    Write-Log "  <- Received `$startack;"

    # ---- Step 6: quit ----
    Start-Sleep -Seconds $WAIT_SECS
    $session.WriteLine("quit")
    Write-Log "  -> Sent: quit"

    # Wait for OctOS to exit.
    if (-not $session.WaitForExit($sessionTimeout * 1000)) {
        Write-Log "Session timeout after $sessionTimeout s." "ERROR"
        $session.Kill()
        throw "Session timeout."
    }

    Write-Log "OctOS finished (exit code: $($session.ExitCode))"
    if ($session.ExitCode -ne 0) {
        throw "OctOS exit code: $($session.ExitCode)"
    }

    $success = $true
}
catch {
    Write-Log "Run failed: $_" "ERROR"

    # ---- Safety reboot: ensure UVP6 resumes acquisition even on error ----
    if ($session -and -not $session.HasExited) {
        try {
            Write-Log "  -> Sending safety reboot to resume UVP6 acquisition..."
            $session.WriteLine("reboot")
            Write-Log "  -> Sent: reboot"
            $ok = Wait-ForMarker -Session $session -MarkerRegex '\$startack;' -TimeoutSec 180
            if ($ok) {
                Write-Log "  <- Safety reboot successful (`$startack; received)."
            } else {
                Write-Log "  <- Safety reboot: no `$startack; within 180s." "WARN"
            }
        }
        catch {
            Write-Log "  <- Safety reboot failed: $_" "WARN"
        }
    }
}
finally {
    if ($session) {
        if (-not $session.HasExited) { $session.Kill() }
        $session.Dispose()
    }
}

if ($success) {
    Write-Log "All steps completed successfully."
    Write-Log "Log: $script:LogFile"
    Write-Log "================================================================="
    Write-Log "  UVP6 DAILY CLEANUP (SD FORMAT) - End (OK)"
    Write-Log "================================================================="
    exit 0
}

Write-Log "Log: $script:LogFile"
Write-Log "================================================================="
Write-Log "  UVP6 DAILY CLEANUP (SD FORMAT) - End (ERROR)"
Write-Log "================================================================="
exit 1
