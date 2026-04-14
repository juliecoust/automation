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

function New-Step {
    param(
        [string]$Name,
        [string]$Command,
        [string]$WaitFor = "",
        [int]$TimeoutSec = 30
    )

    return [PSCustomObject]@{
        Name = $Name
        Command = $Command
        WaitFor = $WaitFor
        TimeoutSec = $TimeoutSec
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
        if ($Session.GetOutput() -match $MarkerRegex) {
            return $true
        }

        if ($Session.HasExited) {
            return $false
        }

        Start-Sleep -Milliseconds 400
    }

    return $false
}

function Invoke-OctOSSession {
    param(
        [string]$OctOSExe,
        [string]$WorkDir,
        [string]$Arguments,
        [object[]]$Steps,
        [int]$SessionTimeoutSec,
        [int]$DelayBetweenCommandsSec,
        [int]$DataWaitTimeoutSec = 15
    )

    $result = [PSCustomObject]@{
        Success = $false
        Output = ""
        Errors = New-Object System.Collections.Generic.List[string]
    }

    $session = $null

    try {
        # Dedicated log file for raw OctOS output.
        $octosLogDir = Split-Path $script:LogFile -Parent
        $script:OctosOutputLog = Join-Path $octosLogDir ("octos_output_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
        Write-Log "OctOS output log: $($script:OctosOutputLog)"

        $commandLine = "`"$OctOSExe`" $Arguments"
        $session = New-Object ConPtySession
        Write-Log "Launching OctOS via ConPTY: $commandLine"
        $session.Start($OctOSExe, $commandLine, $WorkDir, $script:OctosOutputLog)
        Write-Log "  OctOS PID: $($session.ProcessId)"

        # Wait for OctOS to be ready (look for [ME]: prompt).
        Write-Log "  .. Waiting for OctOS to be ready (looking for '[ME]:')..."
        $ready = Wait-ForMarker -Session $session -MarkerRegex '\[ME\]:' -TimeoutSec 120
        if (-not $ready) {
            $msg = "OctOS never became ready (no [ME]: prompt within 120s)."
            $result.Errors.Add($msg)
            Write-Log $msg "ERROR"
            return $result
        }
        Write-Log "  <- OctOS is ready."

        # Send Enter to clear any startup prompt.
        $session.WriteLine("")
        Write-Log "  -> Sent: [Enter]"

        # ---- Check for data lines; reboot if UVP6 is not sending data ----
        Write-Log "  .. Waiting ${DataWaitTimeoutSec}s for data lines (LPM_DATA/BLACK_DATA)..."
        $hasData = Wait-ForMarker -Session $session -MarkerRegex '(LPM_DATA|BLACK_DATA),' -TimeoutSec $DataWaitTimeoutSec
        if (-not $hasData) {
            Write-Log "  <- No data lines received. Sending reboot to wake UVP6..." "WARN"
            $session.WriteLine("reboot")
            Write-Log "  -> Sent: reboot"
            Write-Log "  .. Waiting for `$startack;..."
            $ok = Wait-ForMarker -Session $session -MarkerRegex '\$startack;' -TimeoutSec 180
            if (-not $ok) {
                $msg = "Timeout waiting for `$startack; after pre-reboot."
                $result.Errors.Add($msg)
                Write-Log $msg "ERROR"
                return $result
            }
            Write-Log "  <- Received `$startack;"

            Write-Log "  .. Waiting for data lines after reboot..."
            $hasData2 = Wait-ForMarker -Session $session -MarkerRegex '(LPM_DATA|BLACK_DATA),' -TimeoutSec 60
            if (-not $hasData2) {
                $msg = "UVP6 still not sending data after reboot."
                $result.Errors.Add($msg)
                Write-Log $msg "ERROR"
                return $result
            }
            Write-Log "  <- Data lines confirmed after reboot."
        } else {
            Write-Log "  <- Data lines detected, UVP6 is active."
        }

        $firstStopSentAt = $null

        foreach ($step in $Steps) {
            if ($session.HasExited) {
                $msg = "OctOS exited before step '$($step.Name)'."
                $result.Errors.Add($msg)
                Write-Log $msg "ERROR"
                break
            }

            Start-Sleep -Seconds $DelayBetweenCommandsSec
            $session.WriteLine($step.Command)
            Write-Log "  -> Sent ($($step.Name)): $($step.Command)"

            if ($step.Command -eq '$stop;') {
                if (-not $firstStopSentAt) {
                    $firstStopSentAt = Get-Date
                } else {
                    $deltaSec = ((Get-Date) - $firstStopSentAt).TotalSeconds
                    if ($deltaSec -gt 30) {
                        $msg = "Second stop sent too late (${deltaSec:N1}s after first, max 30s)."
                        $result.Errors.Add($msg)
                        Write-Log $msg "ERROR"
                        break
                    }
                }
            }

            if ($step.WaitFor) {
                Write-Log "  .. Waiting marker for '$($step.Name)': $($step.WaitFor) (timeout $($step.TimeoutSec)s)"
                $ok = Wait-ForMarker -Session $session -MarkerRegex $step.WaitFor -TimeoutSec $step.TimeoutSec
                if ($ok) {
                    Write-Log "  <- Marker received for '$($step.Name)': $($step.WaitFor)"
                } else {
                    $msg = "Marker timeout for '$($step.Name)': $($step.WaitFor)"
                    $result.Errors.Add($msg)
                    Write-Log $msg "ERROR"
                    break
                }
            }
        }

        # Give OctOS a moment to finish after last command.
        if (-not $session.HasExited) {
            Start-Sleep -Milliseconds 500
        }

        if (-not $session.WaitForExit($SessionTimeoutSec * 1000)) {
            $msg = "Session timeout after $SessionTimeoutSec s."
            $result.Errors.Add($msg)
            Write-Log $msg "ERROR"
            $session.Kill()
        }

        Start-Sleep -Milliseconds 400

        $stdout = $session.GetOutput()
        Write-Log "Full OctOS output saved to: $($script:OctosOutputLog)"
        Write-Log "OctOS finished (exit code: $($session.ExitCode))"

        $result.Output = $stdout
        if ($session.ExitCode -eq 0 -and $result.Errors.Count -eq 0) {
            $result.Success = $true
        } else {
            if ($session.ExitCode -ne 0) {
                $result.Errors.Add("OctOS exit code: $($session.ExitCode)")
            }
            $result.Success = $false
        }

        return $result
    }
    finally {
        if ($session) {
            # ---- Safety reboot: ensure UVP6 resumes acquisition even on error ----
            if (-not $session.HasExited -and $result.Errors.Count -gt 0) {
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
            if (-not $session.HasExited) { $session.Kill() }
            $session.Dispose()
        }
    }
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
$SDLIST_TMO = if ($cfg["SDLIST_TIMEOUT"]) { [int]$cfg["SDLIST_TIMEOUT"] } else { 600 }
$SDDUMP_TMO = if ($cfg["SDDUMP_TIMEOUT"]) { [int]$cfg["SDDUMP_TIMEOUT"] } else { 3600 }
$DATA_WAIT = if ($cfg["DATA_WAIT_TIMEOUT"]) { [int]$cfg["DATA_WAIT_TIMEOUT"] } else { 15 }
$TEST_TREE_FILE = $cfg["TEST_TREE_FILE"]

$octosExe = Join-Path $OCTOS_DIR "bin\OctOS.exe"
if (-not (Test-Path $octosExe)) {
    throw "OctOS.exe not found: $octosExe"
}

$logDir = Join-Path $OCTOS_DIR "logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$script:LogFile = Join-Path $logDir ("download_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")

Write-Log "================================================================="
Write-Log "  UVP6 DAILY DOWNLOAD - Start"
Write-Log "================================================================="
Write-Log "Configuration: COM$COM_PORT | Host=$HOST_IP | Baud=$BAUDRATE"

$octosArgs = "$COM_PORT"
if ($BAUDRATE) { $octosArgs += " $BAUDRATE" }

$sddumpCommand = if ($TEST_TREE_FILE) {
    "sddump $TEST_TREE_FILE"
} else {
    # For quick tests you can set TEST_TREE_FILE in .env.
    "sddump tree.txt"
}

# Rename existing tree file before sdlist creates a new one.
$treeFile = Join-Path $OCTOS_DIR "filemanager\tree.txt"
$prevTreeFile = Join-Path $OCTOS_DIR "filemanager\previous_tree.txt"
if (Test-Path $treeFile) {
    if (Test-Path $prevTreeFile) { Remove-Item $prevTreeFile -Force }
    Rename-Item -Path $treeFile -NewName "previous_tree.txt"
    Write-Log "Renamed tree.txt -> previous_tree.txt"
}

$steps = @(
    (New-Step -Name "stop_1" -Command '$stop;' -TimeoutSec 30)
    (New-Step -Name "stop_2" -Command '$stop;' -TimeoutSec 30)
    (New-Step -Name "stop_3" -Command '$stop;' -WaitFor '\$stopack;' -TimeoutSec 30)
    (New-Step -Name "sdlist" -Command "sdlist $HOST_IP" -WaitFor '\[SDLIST\].*EXIT' -TimeoutSec $SDLIST_TMO)
    (New-Step -Name "sddump" -Command $sddumpCommand -WaitFor '\[SDDUMP\].*EXIT' -TimeoutSec $SDDUMP_TMO)
    (New-Step -Name "reboot" -Command 'reboot' -WaitFor '\$startack;' -TimeoutSec 180)
    (New-Step -Name "quit" -Command 'quit')
)

$sessionTimeout = [Math]::Max($SDDUMP_TMO + 300, 900)
$run = Invoke-OctOSSession `
    -OctOSExe $octosExe `
    -WorkDir $OCTOS_DIR `
    -Arguments $octosArgs `
    -Steps $steps `
    -SessionTimeoutSec $sessionTimeout `
    -DelayBetweenCommandsSec $WAIT_SECS `
    -DataWaitTimeoutSec $DATA_WAIT

if ($run.Success) {
    Write-Log "All steps completed successfully."

    # ---- Copy only new files to Desktop\data ----
    $filemanagerDir = Join-Path $OCTOS_DIR "filemanager"
    $destDir = Join-Path ([Environment]::GetFolderPath("Desktop")) "data"

    $newTree = Get-Content $treeFile -ErrorAction SilentlyContinue
    $oldTree = Get-Content $prevTreeFile -ErrorAction SilentlyContinue

    if ($newTree) {
        if ($oldTree) {
            $oldSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$oldTree, [StringComparer]::OrdinalIgnoreCase)
            $newFiles = $newTree | Where-Object { -not $oldSet.Contains($_) }
        } else {
            $newFiles = $newTree
        }

        if ($newFiles) {
            $copyCount = 0
            foreach ($relPath in $newFiles) {
                $relPath = $relPath.Trim()
                if (-not $relPath) { continue }
                $src = Join-Path $filemanagerDir $relPath
                $dst = Join-Path $destDir $relPath
                if (Test-Path $src) {
                    $dstFolder = Split-Path $dst -Parent
                    if (-not (Test-Path $dstFolder)) {
                        New-Item -ItemType Directory -Path $dstFolder -Force | Out-Null
                    }
                    Copy-Item -Path $src -Destination $dst -Force
                    $copyCount++
                }
            }
            Write-Log "Copied $copyCount new file(s) to $destDir"
        } else {
            Write-Log "No new files to copy."
        }
    } else {
        Write-Log "No tree.txt found, skipping file copy." "WARN"
    }

    Write-Log "Log: $script:LogFile"
    Write-Log "================================================================="
    Write-Log "  UVP6 DAILY DOWNLOAD - End (OK)"
    Write-Log "================================================================="
    exit 0
}

$errorText = if ($run.Errors.Count -gt 0) { $run.Errors -join " | " } else { "Unknown error" }
Write-Log "Run failed: $errorText" "ERROR"
Write-Log "Log: $script:LogFile"
Write-Log "================================================================="
Write-Log "  UVP6 DAILY DOWNLOAD - End (ERROR)"
Write-Log "================================================================="
exit 1
