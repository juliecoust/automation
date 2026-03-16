<#
.SYNOPSIS
    Detect available COM ports (real and virtual) and optionally test connectivity.

.DESCRIPTION
    Lists all COM ports on the system (including virtual/emulated ones).
    Can optionally test each port to see if the UVP6 instrument responds.
    Helps identify which COM port to use in the .env configuration.

.EXAMPLE
    PS> .\detect_comport.ps1
    Lists all available COM ports.

    PS> .\detect_comport.ps1 -Test
    Lists and tests each port with basic commands.

    PS> .\detect_comport.ps1 -Baudrate 115200
    Tests ports at a specific baudrate (default is 115200).
#>

param(
    [switch]$Test,                           # Test each port for UVP6 response
    [int]$Baudrate = 115200,                 # Serial baudrate to test
    [int]$TimeoutMs = 2000                   # Timeout for each test (ms)
)

function Get-AvailableComPorts {
    <# Lists all COM ports on the system #>
    $ports = [System.IO.Ports.SerialPort]::GetPortNames()
    
    if ($ports.Count -eq 0) {
        Write-Host "No COM ports detected." -ForegroundColor Yellow
        return @()
    }
    
    Write-Host "`nAvailable COM ports:" -ForegroundColor Green
    $ports | ForEach-Object { Write-Host "  $_" }
    
    return $ports
}

function Test-ComPort {
    <# Attempts to detect UVP6 on a specific COM port #>
    param(
        [string]$Port,
        [int]$Baudrate,
        [int]$TimeoutMs
    )
    
    Write-Host "  Testing $Port... " -NoNewline -ForegroundColor Cyan
    
    try {
        $serial = New-Object System.IO.Ports.SerialPort
        $serial.PortName = $Port
        $serial.BaudRate = $Baudrate
        $serial.Parity = "None"
        $serial.DataBits = 8
        $serial.StopBits = "One"
        $serial.ReadTimeout = $TimeoutMs
        $serial.WriteTimeout = $TimeoutMs
        
        $serial.Open()
        
        # Send a simple command to check if UVP6 responds
        # Try: $help; or $PU:alive;
        $serial.WriteLine('$help;')
        
        # Try to read response
        $response = ""
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        
        while ($timer.ElapsedMilliseconds -lt $TimeoutMs) {
            try {
                if ($serial.BytesToRead -gt 0) {
                    $response += $serial.ReadExisting()
                    break
                }
            }
            catch { }
            Start-Sleep -Milliseconds 50
        }
        
        $serial.Close()
        
        if ($response -match "help|command|ERROR|OK|\$") {
            Write-Host "✓ ACTIVE (UVP6 detected)" -ForegroundColor Green
            return @{ Port = $Port; Status = "Active"; Response = $response.Substring(0, [Math]::Min(50, $response.Length)) }
        } else {
            Write-Host "~ No response" -ForegroundColor Yellow
            return @{ Port = $Port; Status = "Silent"; Response = "" }
        }
    }
    catch {
        $errMsg = $_.Exception.Message
        if ($errMsg -match "not exist|in use|access denied") {
            Write-Host "✗ Error: $errMsg" -ForegroundColor Red
        } else {
            Write-Host "✗ Timeout/No response" -ForegroundColor Yellow
        }
        return @{ Port = $Port; Status = "Failed"; Response = $_.Exception.Message }
    }
}

# ============================================================
#  Main
# ============================================================

Write-Host "`n=================================================="
Write-Host "  UVP6 COM Port Detection Utility"
Write-Host "=================================================="

# Get list of ports
$ports = Get-AvailableComPorts

if ($ports.Count -eq 0) {
    exit 1
}

if ($Test) {
    Write-Host "`nTesting ports (baudrate: $Baudrate, timeout: ${TimeoutMs}ms)..." -ForegroundColor Cyan
    
    $results = @()
    foreach ($port in $ports) {
        $result = Test-ComPort -Port $port -Baudrate $Baudrate -TimeoutMs $TimeoutMs
        $results += $result
    }
    
    Write-Host "`n--- Results ---" -ForegroundColor Green
    $results | ForEach-Object {
        $icon = switch ($_.Status) {
            "Active" { "✓" }
            "Silent" { "~" }
            "Failed" { "✗" }
            default { "?" }
        }
        Write-Host "  $icon $($_.Port) : $($_.Status)"
    }
    
    $active = $results | Where-Object { $_.Status -eq "Active" }
    if ($active) {
        Write-Host "`nMost likely UVP6 port:" -ForegroundColor Green
        Write-Host "  $($active.Port)" -ForegroundColor Yellow
        Write-Host "`nAdd this to .env:  COM_PORT=$($active.Port -replace 'COM', '')" -ForegroundColor Cyan
    }
} else {
    Write-Host "`nFor more details, run with -Test flag to probe each port:" -ForegroundColor Cyan
    Write-Host "  .\detect_comport.ps1 -Test" -ForegroundColor Yellow
    Write-Host "`nOr specify a custom baudrate:" -ForegroundColor Cyan
    Write-Host "  .\detect_comport.ps1 -Test -Baudrate 9600" -ForegroundColor Yellow
}

Write-Host "`n==================================================`n"
