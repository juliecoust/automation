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
     11) Clean local filemanager/ folder (SD card is now empty)
     12) If any check fails - reboot without formatting (no data loss)

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
using System.Text.RegularExpressions;

public class ConPtySession : IDisposable
{
    static readonly Regex AnsiRegex = new Regex(@"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[^\[\]][a-zA-Z]", RegexOptions.Compiled);
    static string StripAnsi(string s) { return AnsiRegex.Replace(s, ""); }
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

function Format-Duration {
    param([double]$Seconds)
    $ts = [TimeSpan]::FromSeconds([Math]::Round($Seconds))
    return "{0:D2}h{1:D2}m{2:D2}s" -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds
}

function Escape-Html {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Initialize-Dashboard {
    param([string]$LogDirectory)

    $runStamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:RunStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:RunStart = Get-Date
    $script:DashboardActions = New-Object System.Collections.Generic.List[object]
    $script:DashboardActive = @{}
    $script:DashboardJsonFile = Join-Path $LogDirectory ("weekly_cleanup_dashboard_" + $runStamp + ".json")
    $script:DashboardHtmlFile = Join-Path $LogDirectory ("weekly_cleanup_dashboard_" + $runStamp + ".html")
    $script:DashboardHistoryFile = Join-Path $LogDirectory "weekly_cleanup_history.json"

    # Load existing history entries.
    $script:DashboardHistory = New-Object System.Collections.Generic.List[object]
    if (Test-Path $script:DashboardHistoryFile) {
        try {
            $loaded = Get-Content $script:DashboardHistoryFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($entry in $loaded) {
                $script:DashboardHistory.Add($entry)
            }
        } catch { <# ignore corrupt history #> }
    }
}

function Start-DashboardAction {
    param(
        [string]$Key,
        [string]$Label
    )

    $script:DashboardActive[$Key] = @{
        Label = $Label
        Start = Get-Date
    }
}

function Complete-DashboardAction {
    param(
        [string]$Key,
        [ValidateSet("OK", "WARN", "ERROR")]
        [string]$Status,
        [string]$Details = ""
    )

    if (-not $script:DashboardActive.ContainsKey($Key)) { return }

    $start = $script:DashboardActive[$Key].Start
    $end = Get-Date
    $durationSec = [Math]::Round((New-TimeSpan -Start $start -End $end).TotalSeconds, 1)
    $durationFmt = Format-Duration $durationSec

    $script:DashboardActions.Add([pscustomobject]@{
        Label = $script:DashboardActive[$Key].Label
        Start = $start.ToString("yyyy-MM-dd HH:mm:ss")
        End = $end.ToString("yyyy-MM-dd HH:mm:ss")
        DurationSec = $durationSec
        Duration = $durationFmt
        Status = $Status
        Details = $Details
    })

    $script:DashboardActive.Remove($Key) | Out-Null
    Write-DashboardFiles
}

function Write-DashboardFiles {
    if (-not $script:DashboardActions) { return }

    $script:DashboardActions | ConvertTo-Json -Depth 5 | Set-Content -Path $script:DashboardJsonFile -Encoding UTF8

    $rows = foreach ($a in $script:DashboardActions) {
        $css = if ($a.Status -eq "OK") { "ok" } elseif ($a.Status -eq "WARN") { "warn" } else { "err" }
        "<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td class='{4}'>{5}</td><td>{6}</td></tr>" -f `
            (Escape-Html $a.Label), (Escape-Html $a.Start), (Escape-Html $a.End), (Escape-Html $a.Duration), $css, (Escape-Html $a.Status), (Escape-Html $a.Details)
    }
    $rowsHtml = ($rows -join [Environment]::NewLine)
    $totalSec = if ($script:RunStopwatch) { $script:RunStopwatch.Elapsed.TotalSeconds } else { 0 }
    $totalFmt = Format-Duration $totalSec

    # History table
    $histRows = foreach ($h in ($script:DashboardHistory | Sort-Object RunStart -Descending)) {
        $css = if ($h.RunStatus -eq "OK") { "ok" } elseif ($h.RunStatus -eq "WARN") { "warn" } else { "err" }
        "<tr><td>{0}</td><td>{1}</td><td>{2}</td><td class='{3}'>{4}</td><td>{5}</td></tr>" -f `
            (Escape-Html $h.RunStart), (Escape-Html $h.TotalDuration), (Escape-Html ([string]$h.FileCount)), $css, (Escape-Html $h.RunStatus), (Escape-Html $h.Note)
    }
    $histHtml = if ($histRows) { $histRows -join [Environment]::NewLine } else { "<tr><td colspan='5'>No past runs yet.</td></tr>" }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>UVP6 Weekly Cleanup Dashboard</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; background: #f4f6f8; color: #1f2937; }
.card { background: #fff; border-radius: 10px; padding: 16px; box-shadow: 0 1px 4px rgba(0,0,0,0.08); margin-bottom: 16px; }
h3 { margin: 0 0 10px 0; font-size: 15px; color: #374151; }
table { width: 100%; border-collapse: collapse; background: #fff; }
th, td { border-bottom: 1px solid #e5e7eb; text-align: left; padding: 8px; font-size: 13px; }
th { background: #f9fafb; }
.ok { color: #0f766e; font-weight: 700; }
.warn { color: #b45309; font-weight: 700; }
.err { color: #b91c1c; font-weight: 700; }
</style>
</head>
<body>
  <div class="card">
    <h2>UVP6 Weekly Cleanup Dashboard</h2>
    <div><strong>Total elapsed:</strong> $totalFmt</div>
    <div><strong>Log file:</strong> $(Escape-Html $script:LogFile)</div>
    <div><strong>Generated:</strong> $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</div>
  </div>
  <div class="card">
    <h3>Current run</h3>
    <table>
      <thead>
        <tr>
          <th>Action</th><th>Start</th><th>End</th><th>Duration</th><th>Status</th><th>Details</th>
        </tr>
      </thead>
      <tbody>
        $rowsHtml
      </tbody>
    </table>
  </div>
  <div class="card">
    <h3>Past runs</h3>
    <table>
      <thead>
        <tr>
          <th>Run start</th><th>Total duration</th><th>Files</th><th>Status</th><th>Note</th>
        </tr>
      </thead>
      <tbody>
        $histHtml
      </tbody>
    </table>
  </div>
</body>
</html>
"@
    [System.IO.File]::WriteAllText($script:DashboardHtmlFile, $html, [System.Text.Encoding]::UTF8)
}

function Finalize-Dashboard {
    param([string]$RunStatus)

    foreach ($k in @($script:DashboardActive.Keys)) {
        Complete-DashboardAction -Key $k -Status "WARN" -Details "Action still active at end of run"
    }

    # Compute summary fields for history.
    $totalSec = if ($script:RunStopwatch) { $script:RunStopwatch.Elapsed.TotalSeconds } else { 0 }
    $fileCountAction = $script:DashboardActions | Where-Object { $_.Label -like 'Phase 2*' -and $_.Status -eq 'OK' } | Select-Object -First 1
    $fileCount = if ($fileCountAction -and $fileCountAction.Details -match '(\d+)') { [int]$Matches[1] } else { '' }

    $histEntry = [pscustomobject]@{
        RunStart      = if ($script:RunStart) { $script:RunStart.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        TotalDuration = Format-Duration $totalSec
        FileCount     = $fileCount
        RunStatus     = $RunStatus
        Note          = ""
        DashboardJson = $script:DashboardJsonFile
        DashboardHtml = $script:DashboardHtmlFile
    }
    $script:DashboardHistory.Add($histEntry)

    # Persist history.
    try {
        $script:DashboardHistory | ConvertTo-Json -Depth 5 | Set-Content -Path $script:DashboardHistoryFile -Encoding UTF8
    } catch { <# history write failure is non-fatal #> }

    Write-DashboardFiles

    if ($script:DashboardHtmlFile) { Write-Log "Dashboard: $script:DashboardHtmlFile" }
    if ($script:DashboardJsonFile) { Write-Log "Dashboard JSON: $script:DashboardJsonFile" }
    if ($script:DashboardHistoryFile) { Write-Log "History: $script:DashboardHistoryFile" }
}

function Exit-WithDashboard {
    param(
        [int]$Code,
        [string]$RunStatus
    )
    Finalize-Dashboard -RunStatus $RunStatus
    exit $Code
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

# ---- SFTP helpers (Posh-SSH) ----

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

function Test-SftpFileExists {
    param($Session, [string]$RemotePath)
    return Test-SFTPPath -SFTPSession $Session -Path $RemotePath
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
        Write-Log "  <- No data. Stopping then rebooting..." "WARN"
        $Session.WriteLine('$stop;')
        Write-Log "  -> Sent: `$stop;"
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
        if (-not $ok) { throw "Timeout waiting for reboot confirmation (no `$startack; or HW_CONF)." }
        Write-Log "  <- Reboot confirmed."
        $hasData2 = Wait-ForMarker -Session $Session -MarkerRegex '(LPM_DATA|BLACK_DATA),' -TimeoutSec 60
        if (-not $hasData2) { Write-Log "  <- No data after reboot (UVP6 may be in scheduled mode, waiting for next window)." "WARN" }
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

# ---- SFTP upload helpers ----

$script:_sftpDirsCreated = @{}

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

# ---- Helper: reboot UVP6 before exiting on error ----
# Called when Phases 2/3 fail and UVP6 is still stopped.
# Uses script-scope variables set in Main.
function Invoke-RebootAndExit {
    param([int]$ExitCode)

    if (-not $script:needsReboot) { Exit-WithDashboard -Code $ExitCode -RunStatus "ABORT" }

    Write-Log ""
    Write-Log "Rebooting UVP6 to resume acquisition before exiting..."
    $rbSession = $null
    try {
        $rbLog = if ($script:OCTOS_LOG_EN) { Join-Path $script:logDir ("octos_output_weekly_reboot_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log") } else { $null }
        $rbSession = Start-OctOSSession -OctOSExe $script:octosExe -WorkDir $script:OCTOS_DIR -Arguments $script:octosArgs -OutputLogPath $rbLog
        $ready = Wait-ForMarker -Session $rbSession -MarkerRegex '\[ME\]:' -TimeoutSec 120
        if ($ready) {
            $rbSession.WriteLine("")
            Start-Sleep -Seconds $script:WAIT_SECS
            $rbSession.WriteLine('$stop;')
            Start-Sleep -Seconds 2
            $rbSession.WriteLine('$stop;')
            Start-Sleep -Seconds 2
            $rbSession.WriteLine('$stop;')
            $stopOk = Wait-ForMarker -Session $rbSession -MarkerRegex '\$stopack;' -TimeoutSec 30
            if ($stopOk) { Write-Log "  <- Received `$stopack;" }
            else         { Write-Log "  <- No `$stopack; (may already be stopped)" "WARN" }
            Start-Sleep -Seconds $script:WAIT_SECS
            $rbSession.WriteLine("reboot")
            Write-Log "  -> Sent: reboot"
            $ok = Wait-ForMarker -Session $rbSession -MarkerRegex '(\$startack;|HW_CONF,)' -TimeoutSec 180
            if ($ok) { Write-Log "  <- UVP6 rebooted successfully." }
            else     { Write-Log "  <- No reboot confirmation within 180s." "WARN" }
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
    Exit-WithDashboard -Code $ExitCode -RunStatus "ABORT"
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
$MAX_RETRIES  = if ($cfg["MAX_RETRIES"])      { [int]$cfg["MAX_RETRIES"] }      else { 3 }
$RETRY_DELAY  = if ($cfg["RETRY_DELAY"])      { [int]$cfg["RETRY_DELAY"] }      else { 10 }
$OCTOS_LOG_EN = $cfg["OCTOS_OUTPUT_LOG"] -eq 'true'
$SFTP_HOST    = $cfg["SFTP_HOST"]
$SFTP_USER    = $cfg["SFTP_USER"]
$SFTP_PASS    = $cfg["SFTP_PASSWORD"]
$SFTP_REMOTE  = $cfg["SFTP_REMOTE_DIR"]
$SFTP_PORT    = if ($cfg["SFTP_PORT"]) { [int]$cfg["SFTP_PORT"] } else { 22 }

$octosExe = Join-Path $OCTOS_DIR "bin\OctOS.exe"
if (-not (Test-Path $octosExe)) { throw "OctOS.exe not found: $octosExe" }

$logDir = Join-Path $OCTOS_DIR "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$script:LogFile = Join-Path $logDir ("weekly_cleanup_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
Initialize-Dashboard -LogDirectory $logDir

Write-Log "================================================================="
Write-Log "  UVP6 WEEKLY VERIFY & CLEANUP - Start"
Write-Log "================================================================="
Write-Log "Configuration: COM$COM_PORT | Host=$HOST_IP | SFTP=$SFTP_HOST"
Write-Log "Dashboard will be generated at: $script:DashboardHtmlFile"

$octosArgs = "$COM_PORT"
if ($BAUDRATE) { $octosArgs += " $BAUDRATE" }

$filemanagerDir = Join-Path $OCTOS_DIR "filemanager"
$treeFile = Join-Path $filemanagerDir "tree.txt"

# Archive existing tree.txt before sdlist overwrites it.
if (Test-Path $treeFile) {
    $archiveName = "tree_" + (Get-Date -Format "yyyyMMdd") + ".txt"
    $archiveFile = Join-Path $filemanagerDir $archiveName
    Copy-Item -Path $treeFile -Destination $archiveFile -Force
    Write-Log "Archived tree.txt -> $archiveName"
}

# Track whether we need to reboot UVP6 at the end (it stays stopped
# from Phase 1 until we explicitly reboot in Phase 4 or on error).
$needsReboot = $false

# ============================================================
# PHASE 1: Stop UVP6, sdlist, sddump (UVP6 stays stopped)
# ============================================================
Write-Log ""
Write-Log "---- PHASE 1: Stop UVP6 + sdlist + sddump ----"
Write-Log "UVP6 will stay stopped until Phase 4 completes."
Start-DashboardAction -Key "phase1" -Label "Phase 1 - stop + sdlist + sddump"

$phase1Success = $false
for ($attempt = 1; $attempt -le $MAX_RETRIES; $attempt++) {
    if ($attempt -gt 1) {
        Write-Log "  Retry $attempt/$MAX_RETRIES after ${RETRY_DELAY}s delay..." "WARN"
        Start-Sleep -Seconds $RETRY_DELAY
    }

    $session = $null
    try {
        Start-DashboardAction -Key "phase1_attempt_$attempt" -Label "Phase 1 attempt $attempt"
        $octosLog = if ($OCTOS_LOG_EN) { Join-Path $logDir ("octos_output_weekly_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log") } else { $null }
        if ($octosLog) { Write-Log "OctOS output log: $octosLog" }

        $session = Start-OctOSSession -OctOSExe $octosExe -WorkDir $OCTOS_DIR -Arguments $octosArgs -OutputLogPath $octosLog
        Write-Log "  OctOS PID: $($session.ProcessId)"

        Initialize-OctOSSession -Session $session -DataWaitTimeoutSec $DATA_WAIT
        Send-StopSequence -Session $session -DelaySec $WAIT_SECS
        $needsReboot = $true

        # sdlist - get current SD card contents.
        Start-Sleep -Seconds $WAIT_SECS
        Start-DashboardAction -Key "sdlist_attempt_$attempt" -Label "sdlist (attempt $attempt)"
        $session.WriteLine("sdlist $HOST_IP")
        Write-Log "  -> Sent: sdlist $HOST_IP"
        Write-Log "  .. Waiting for [SDLIST] EXIT (timeout ${SDLIST_TMO}s)..."
        $ok = Wait-ForMarker -Session $session -MarkerRegex '\[SDLIST\].*EXIT' -TimeoutSec $SDLIST_TMO
        if (-not $ok) { throw "Timeout waiting for sdlist to complete." }
        # [SDLIST]: EXIT appears on both success AND error — check for the error case explicitly.
        $sdlistOut = Strip-Ansi $session.GetOutput()
        if ($sdlistOut -match 'Command sdlist returned an error') {
            throw "sdlist exited with error (tree.txt transfer failed or other sdlist error)."
        }
        Write-Log "  <- sdlist completed."
        Complete-DashboardAction -Key "sdlist_attempt_$attempt" -Status "OK"

        # sddump - download any files not yet on disk.
        Start-Sleep -Seconds $WAIT_SECS
        Start-DashboardAction -Key "sddump_attempt_$attempt" -Label "sddump (attempt $attempt)"
        $session.WriteLine("sddump tree.txt")
        Write-Log "  -> Sent: sddump tree.txt"
        Write-Log "  .. Waiting for [SDDUMP] EXIT (timeout ${SDDUMP_TMO}s)..."
        $ok = Wait-ForMarker -Session $session -MarkerRegex '\[SDDUMP\].*EXIT' -TimeoutSec $SDDUMP_TMO
        if (-not $ok) { throw "Timeout waiting for sddump to complete." }
        # [SDDUMP]: EXIT appears on both success AND error — check for the error case explicitly.
        $sddumpOut = Strip-Ansi $session.GetOutput()
        if ($sddumpOut -match 'Command sddump returned an error') {
            throw "sddump exited with error."
        }
        Write-Log "  <- sddump completed."
        Complete-DashboardAction -Key "sddump_attempt_$attempt" -Status "OK"

        # Quit OctOS WITHOUT rebooting - UVP6 stays stopped.
        Start-Sleep -Seconds $WAIT_SECS
        $session.WriteLine("quit")
        Write-Log "  -> Sent: quit (UVP6 stays stopped)"
        $session.WaitForExit(30000) | Out-Null

        $phase1Success = $true
        Complete-DashboardAction -Key "phase1_attempt_$attempt" -Status "OK"
        break
    }
    catch {
        Write-Log "PHASE 1 attempt $attempt FAILED: $_" "ERROR"
        Complete-DashboardAction -Key "phase1_attempt_$attempt" -Status "ERROR" -Details "$_"
        Complete-DashboardAction -Key "sdlist_attempt_$attempt" -Status "ERROR" -Details "Interrupted or timeout"
        Complete-DashboardAction -Key "sddump_attempt_$attempt" -Status "ERROR" -Details "Interrupted or timeout"
        if ($attempt -lt $MAX_RETRIES) {
            # Reboot UVP6 so next attempt starts from a clean state.
            Send-SafetyReboot -Session $session
            $needsReboot = $false
        } else {
            # Final attempt failed — reboot and exit.
            Send-SafetyReboot -Session $session
            $needsReboot = $false
        }
    }
    finally {
        Close-OctOSSession -Session $session
        $session = $null
    }
}

if (-not $phase1Success) {
    Complete-DashboardAction -Key "phase1" -Status "ERROR" -Details "Failed after retries"
    Write-Log "PHASE 1 FAILED after $MAX_RETRIES attempt(s)." "ERROR"
    Write-Log "================================================================="
    Write-Log "  UVP6 WEEKLY VERIFY & CLEANUP - End (ERROR in Phase 1)"
    Write-Log "================================================================="
    Exit-WithDashboard -Code 1 -RunStatus "ERROR"
}
Complete-DashboardAction -Key "phase1" -Status "OK"

# ============================================================
# PHASE 2: Verify all files exist locally
# ============================================================
Write-Log ""
Write-Log "---- PHASE 2: Verify local files ----"
Start-DashboardAction -Key "phase2" -Label "Phase 2 - verify local files"

if (-not (Test-Path $treeFile)) {
    Complete-DashboardAction -Key "phase2" -Status "ERROR" -Details "tree.txt missing"
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
    Complete-DashboardAction -Key "phase2" -Status "ERROR" -Details "$($missingLocal.Count) local files missing"
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
Complete-DashboardAction -Key "phase2" -Status "OK" -Details "$($treeEntries.Count) files"

# ============================================================
# PHASE 3: Upload to SFTP + verify all files exist on SFTP
# ============================================================
Write-Log ""
Write-Log "---- PHASE 3: SFTP upload & verify ----"
Start-DashboardAction -Key "phase3" -Label "Phase 3 - SFTP verify + upload"

if (-not $SFTP_HOST -or -not $SFTP_USER) {
    Complete-DashboardAction -Key "phase3" -Status "ERROR" -Details "SFTP not configured"
    Write-Log "SFTP not configured - cannot verify." "ERROR"
    Write-Log "SD card will NOT be formatted without SFTP verification." "ERROR"
    Invoke-RebootAndExit 1
}

$remoteBase = if ($SFTP_REMOTE) { "/" + $SFTP_REMOTE.Trim('/').Replace('\', '/') } else { "" }

$sftpSession = $null
try {
    Write-Log "  Connecting to SFTP ${SFTP_HOST}:${SFTP_PORT} ..."
    $sftpSession = Open-SftpSession -Hostname $SFTP_HOST -User $SFTP_USER -Pass $SFTP_PASS -Port $SFTP_PORT
    Write-Log "  <- SFTP connected."

    # Check which files are missing on SFTP and upload them.
    Start-DashboardAction -Key "ftp_check" -Label "SFTP existence check"
    $missingFtp = @()
    $checkedCount = 0
    foreach ($rel in $treeEntries) {
        $remotePath = $remoteBase + "/" + ($rel.Replace('\', '/'))
        $exists = Test-SftpFileExists -Session $sftpSession -RemotePath $remotePath
        if (-not $exists) { $missingFtp += $rel }
        $checkedCount++
        if ($checkedCount % 500 -eq 0) {
            Write-Log "  SFTP check progress: $checkedCount / $($treeEntries.Count)..."
        }
    }
    Complete-DashboardAction -Key "ftp_check" -Status "OK" -Details "$checkedCount checked, $($missingFtp.Count) missing"

    if ($missingFtp.Count -gt 0) {
        Write-Log "$($missingFtp.Count) file(s) missing on SFTP - uploading now..."
        Start-DashboardAction -Key "ftp_upload" -Label "SFTP upload missing files"
        $uploadOk = 0
        $uploadFail = 0
        $uploadCount = 0
        foreach ($rel in $missingFtp) {
            $localPath  = Join-Path $filemanagerDir $rel
            $remoteRel  = $rel.Replace('\', '/')
            $remotePath = "$remoteBase/$remoteRel"
            if ($remoteRel -match '/') {
                $parentDir = "$remoteBase/" + ($remoteRel -replace '/[^/]+$', '')
                Ensure-SftpDirectory -Session $sftpSession -FullRemotePath $parentDir
            }
            try {
                Upload-SftpFile -Session $sftpSession -LocalPath $localPath -RemotePath $remotePath
                $uploadOk++
            }
            catch {
                $uploadFail++
                Write-Log "  UPLOAD FAILED: $rel - $($_.Exception.Message)" "ERROR"
            }
            $uploadCount++
            if ($uploadCount % 50 -eq 0) {
                Write-Log "  SFTP upload progress: $uploadCount / $($missingFtp.Count) ($uploadOk ok, $uploadFail failed)..."
            }
        }
        Write-Log "SFTP upload: $uploadOk succeeded, $uploadFail failed."
        if ($uploadFail -gt 0) {
            Complete-DashboardAction -Key "ftp_upload" -Status "ERROR" -Details "$uploadFail failed"
        } else {
            Complete-DashboardAction -Key "ftp_upload" -Status "OK" -Details "$uploadOk uploaded"
        }

        if ($uploadFail -gt 0) {
            Complete-DashboardAction -Key "phase3" -Status "ERROR" -Details "SFTP upload failures"
            Write-Log "*** ABORT: $uploadFail file(s) could not be uploaded to SFTP ***" "ERROR"
            Write-Log "SD card will NOT be formatted to prevent data loss." "ERROR"
            Invoke-RebootAndExit 1
        }

        # Re-verify the uploaded files actually exist on SFTP.
        Write-Log "Re-verifying $($missingFtp.Count) uploaded files on SFTP..."
        Start-DashboardAction -Key "ftp_reverify" -Label "SFTP re-verify uploaded files"
        $stillMissing = @()
        $verifyCount = 0
        foreach ($rel in $missingFtp) {
            $remotePath = $remoteBase + "/" + ($rel.Replace('\', '/'))
            $exists = Test-SftpFileExists -Session $sftpSession -RemotePath $remotePath
            if (-not $exists) { $stillMissing += $rel }
            $verifyCount++
            if ($verifyCount % 100 -eq 0) {
                Write-Log "  SFTP re-verify progress: $verifyCount / $($missingFtp.Count)..."
            }
        }
        if ($stillMissing.Count -gt 0) {
            Complete-DashboardAction -Key "ftp_reverify" -Status "ERROR" -Details "$($stillMissing.Count) still missing"
            Complete-DashboardAction -Key "phase3" -Status "ERROR" -Details "Files still missing after upload"
            Write-Log "*** ABORT: $($stillMissing.Count) file(s) still missing on SFTP after upload ***" "ERROR"
            foreach ($f in $stillMissing | Select-Object -First 20) {
                Write-Log "  STILL MISSING: $f" "ERROR"
            }
            Invoke-RebootAndExit 1
        }
        Complete-DashboardAction -Key "ftp_reverify" -Status "OK"
    }

    # Upload all tree files (tree.txt, tree_YYYYMMDD.txt) - always overwrite with latest.
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

    Write-Log "All $($treeEntries.Count) file(s) verified on SFTP."
    Complete-DashboardAction -Key "phase3" -Status "OK" -Details "$($treeEntries.Count) files"
}
finally {
    if ($sftpSession) { Remove-SFTPSession -SFTPSession $sftpSession | Out-Null }
}

# ============================================================
# PHASE 4: All verified - format SD card, then reboot
# ============================================================
Write-Log ""
Write-Log "---- PHASE 4: SD format (all files verified) ----"
Write-Log "VERIFIED: $($treeEntries.Count) files present locally AND on FTP."
Write-Log "Proceeding with sdformat..."
Start-DashboardAction -Key "phase4" -Label "Phase 4 - sdformat + reboot"

$success = $false
for ($attempt = 1; $attempt -le $MAX_RETRIES; $attempt++) {
    if ($attempt -gt 1) {
        Write-Log "  Retry $attempt/$MAX_RETRIES after ${RETRY_DELAY}s delay..." "WARN"
        Start-Sleep -Seconds $RETRY_DELAY
    }

    $session = $null
    try {
        Start-DashboardAction -Key "phase4_attempt_$attempt" -Label "Phase 4 attempt $attempt"
        $octosLog2 = if ($OCTOS_LOG_EN) { Join-Path $logDir ("octos_output_weekly_format_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log") } else { $null }
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
        Start-DashboardAction -Key "sdformat_attempt_$attempt" -Label "sdformat (attempt $attempt)"
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
        Complete-DashboardAction -Key "sdformat_attempt_$attempt" -Status "OK"

        # Now reboot to resume acquisition.
        Start-Sleep -Seconds $WAIT_SECS
        Start-DashboardAction -Key "reboot_after_format_attempt_$attempt" -Label "reboot after format (attempt $attempt)"
        $session.WriteLine("reboot")
        Write-Log "  -> Sent: reboot"
        $ok = Wait-ForMarker -Session $session -MarkerRegex '(\$startack;|HW_CONF,)' -TimeoutSec 180
        if (-not $ok) { throw "Timeout waiting for reboot confirmation after format." }
        Write-Log "  <- Reboot confirmed - UVP6 resumed."
        Complete-DashboardAction -Key "reboot_after_format_attempt_$attempt" -Status "OK"
        $needsReboot = $false

        Start-Sleep -Seconds $WAIT_SECS
        $session.WriteLine("quit")
        Write-Log "  -> Sent: quit"
        $session.WaitForExit(30000) | Out-Null

        $success = $true
        Complete-DashboardAction -Key "phase4_attempt_$attempt" -Status "OK"
        break
    }
    catch {
        Write-Log "PHASE 4 attempt $attempt FAILED: $_" "ERROR"
        Complete-DashboardAction -Key "phase4_attempt_$attempt" -Status "ERROR" -Details "$_"
        Complete-DashboardAction -Key "sdformat_attempt_$attempt" -Status "ERROR" -Details "Interrupted or timeout"
        Complete-DashboardAction -Key "reboot_after_format_attempt_$attempt" -Status "ERROR" -Details "Interrupted or timeout"
        if ($attempt -lt $MAX_RETRIES) {
            # Reboot UVP6 before retrying so sdformat starts clean.
            Send-SafetyReboot -Session $session
            $needsReboot = $false
        } else {
            Send-SafetyReboot -Session $session
            $needsReboot = $false
        }
    }
    finally {
        Close-OctOSSession -Session $session
    }
}

if ($success) {
    Complete-DashboardAction -Key "phase4" -Status "OK"

    # ============================================================
    # PHASE 5: Clean local filemanager/ (SD card is now empty)
    # ============================================================
    Write-Log ""
    Write-Log "---- PHASE 5: Clean local filemanager/ ----"
    Start-DashboardAction -Key "phase5" -Label "Phase 5 - clean local filemanager"

    $cleanedCount = 0
    $cleanFailCount = 0
    foreach ($rel in $treeEntries) {
        $localPath = Join-Path $filemanagerDir $rel
        # Skip tree files - they are kept for history/reference.
        if ([System.IO.Path]::GetFileName($localPath) -like 'tree*.txt') { continue }
        if (Test-Path $localPath) {
            try {
                Remove-Item -Path $localPath -Force
                $cleanedCount++
            } catch {
                Write-Log "  Failed to delete: $rel - $_" "WARN"
                $cleanFailCount++
            }
        }
    }

    # Remove any empty subdirectories left behind.
    Get-ChildItem -Path $filemanagerDir -Directory -Recurse |
        Sort-Object -Property FullName -Descending |
        Where-Object { -not (Get-ChildItem -Path $_.FullName -Recurse -File) } |
        ForEach-Object {
            try { Remove-Item -Path $_.FullName -Force } catch {}
        }

    Write-Log "Local cleanup: $cleanedCount file(s) deleted, $cleanFailCount failed."
    if ($cleanFailCount -gt 0) {
        Complete-DashboardAction -Key "phase5" -Status "WARN" -Details "$cleanedCount deleted, $cleanFailCount failed"
    } else {
        Complete-DashboardAction -Key "phase5" -Status "OK" -Details "$cleanedCount files deleted"
    }

    Write-Log ""
    Write-Log "SUMMARY: $($treeEntries.Count) files verified, SD card formatted, $cleanedCount local files cleaned."
    Write-Log "Log: $script:LogFile"
    Write-Log "================================================================="
    Write-Log "  UVP6 WEEKLY VERIFY & CLEANUP - End (OK)"
    Write-Log "================================================================="
    Exit-WithDashboard -Code 0 -RunStatus "OK"
}

Complete-DashboardAction -Key "phase4" -Status "ERROR" -Details "Failed after retries"
Write-Log "Log: $script:LogFile"
Write-Log "================================================================="
Write-Log "  UVP6 WEEKLY VERIFY & CLEANUP - End (ERROR in Phase 4)"
Write-Log "================================================================="
Exit-WithDashboard -Code 1 -RunStatus "ERROR"
