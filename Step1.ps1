# File: Win11-InPlaceUpgrade-Step1.ps1
<#
Win10 -> Win11 In-Place Upgrade (PDQ-friendly) - ISO extracted media

What it does:
- Pre-checks Windows 11 requirements (TPM, Secure Boot, UEFI, 64-bit CPU, RAM, disk free)
- Logs to: C:\ProgramData\PDQ\Logs\
- Copies extracted ISO media locally from a PDQ host via UNC admin share
- Runs setup.exe only if compatible

Exit codes:
  0  = Upgrade started successfully OR already Windows 11 OR setup already running
  10 = Not compatible (pre-check failed)
  20 = Installer not found / copy failed
  30 = Setup returned failure

Notes:
- Requires admin rights on the target.
- Targets must be able to reach the PDQ host admin share (e.g., \\HOST\C$).
#>

[CmdletBinding()]
param(
    [string]$PDQHost = "MSP-GQ-MIS",

    # Folder ON THE PDQ HOST that contains setup.exe (EXTRACTED ISO / MEDIA FOLDER)
    [string]$PDQMediaFolder = "C:\Users\administrator.MCKENZIESP\Downloads\Win11ISO",

    [switch]$UseLocalCopy = $true,
    [string]$LocalSource  = "C:\Temp\Win11",
    [int]$MinFreeGB       = 64,

    # Default: quiet, no reboot (we gate reboot separately)
    [string]$SetupArgs    = "/auto upgrade /quiet /noreboot /dynamicupdate enable /eula accept /telemetry disable"
)

# ====== LOGGING ======
$LogDir  = "C:\ProgramData\PDQ\Logs"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir ("Win11_Upgrade_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")] [string]$Level="INFO"
    )
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    $line | Tee-Object -FilePath $LogFile -Append
}

Write-Log "==== Windows 11 Upgrade Script Starting (Step 1) ===="
Write-Log "PDQHost: $PDQHost"
Write-Log "PDQMediaFolder (on host): $PDQMediaFolder"
Write-Log "UseLocalCopy: $UseLocalCopy"
Write-Log "LocalSource: $LocalSource"
Write-Log "MinFreeGB: $MinFreeGB"
Write-Log "SetupArgs: $SetupArgs"

# ====== BUILD UNC SOURCE PATH SAFELY ======
# Convert "C:\Some\Path" -> "\\HOST\C$\Some\Path"
if ($PDQMediaFolder -notmatch "^[A-Za-z]:\\") {
    Write-Log "PDQMediaFolder does not look like a local drive path: $PDQMediaFolder" "ERROR"
    exit 20
}
$driveLetter   = $PDQMediaFolder.Substring(0,1)
$restPath      = $PDQMediaFolder.Substring(3)   # after "C:\"
$NetworkSource = "\\$PDQHost\${driveLetter}$\${restPath}"
Write-Log "NetworkSource (UNC): $NetworkSource"

# ====== QUICK GUARD: Already Windows 11? ======
try {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Log ("Detected OS: {0} (Build {1})" -f $os.Caption, $os.BuildNumber)
    if ($os.Caption -match "Windows 11") {
        Write-Log "Machine already appears to be Windows 11. Exiting success."
        exit 0
    }
} catch {
    Write-Log "Unable to query OS info: $($_.Exception.Message)" "WARN"
}

# ====== QUICK GUARD: Setup already running? ======
try {
    $running = Get-Process setup, setuphost, setupprep -ErrorAction SilentlyContinue
    if ($running) {
        Write-Log "Windows Setup appears to already be running. Exiting success to avoid collision." "WARN"
        exit 0
    }
} catch {
    Write-Log "Unable to query setup processes: $($_.Exception.Message)" "WARN"
}

# ====== COMPAT CHECK ======
$reasons = New-Object System.Collections.Generic.List[string]

# TPM
try {
    $tpm = Get-Tpm
    Write-Log ("TPM: Present={0}, Ready={1}, Enabled={2}, Activated={3}" -f $tpm.TpmPresent, $tpm.TpmReady, $tpm.TpmEnabled, $tpm.TpmActivated)
    if (-not $tpm.TpmPresent) { $reasons.Add("TPM not present") }
    elseif (-not $tpm.TpmReady) { $reasons.Add("TPM not ready") }
} catch {
    Write-Log "TPM check failed: $($_.Exception.Message)" "ERROR"
    $reasons.Add("TPM check failed")
}

# Secure Boot
try {
    $sb = Confirm-SecureBootUEFI
    Write-Log ("SecureBoot: {0}" -f $sb)
    if (-not $sb) { $reasons.Add("Secure Boot disabled") }
} catch {
    Write-Log "Secure Boot check failed (likely Legacy BIOS / not UEFI): $($_.Exception.Message)" "WARN"
    $reasons.Add("Secure Boot check failed (likely not UEFI)")
}

# UEFI
try {
    $fw = (Get-ComputerInfo).BiosFirmwareType
    Write-Log ("Firmware: {0}" -f $fw)
    if ($fw -ne "UEFI") { $reasons.Add("Not UEFI firmware ($fw)") }
} catch {
    Write-Log "UEFI check failed: $($_.Exception.Message)" "WARN"
    $reasons.Add("UEFI check failed")
}

# CPU 64-bit
try {
    $cpu = Get-CimInstance Win32_Processor
    Write-Log ("CPU: {0} | AddressWidth={1}" -f $cpu.Name, $cpu.AddressWidth)
    if ($cpu.AddressWidth -ne 64) { $reasons.Add("CPU not 64-bit") }
} catch {
    Write-Log "CPU check failed: $($_.Exception.Message)" "WARN"
    $reasons.Add("CPU check failed")
}

# RAM >= 4GB
try {
    $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 0)
    Write-Log ("RAM: {0} GB" -f $ramGB)
    if ($ramGB -lt 4) { $reasons.Add("RAM < 4GB ($ramGB GB)") }
} catch {
    Write-Log "RAM check failed: $($_.Exception.Message)" "WARN"
    $reasons.Add("RAM check failed")
}

# Free space on C:
try {
    $disk   = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $freeGB = [math]::Round($disk.FreeSpace / 1GB, 0)
    Write-Log ("Disk C: Free: {0} GB" -f $freeGB)
    if ($freeGB -lt $MinFreeGB) { $reasons.Add("Free space on C: < $MinFreeGB GB ($freeGB GB free)") }
} catch {
    Write-Log "Disk check failed: $($_.Exception.Message)" "WARN"
    $reasons.Add("Disk check failed")
}

if ($reasons.Count -gt 0) {
    Write-Log ("NOT COMPATIBLE: " + ($reasons -join "; ")) "ERROR"
    Write-Log "Exiting with code 10 (pre-check failed)."
    exit 10
}

Write-Log "Compatibility checks PASSED."

# ====== LOCATE SETUP.EXE (SOURCE) ======
$sourceSetupExe = Join-Path $NetworkSource "setup.exe"
Write-Log "Expecting source setup.exe at: $sourceSetupExe"

if (-not (Test-Path $sourceSetupExe)) {
    Write-Log "Source setup.exe not found/reachable at: $sourceSetupExe" "ERROR"
    Write-Log "Usually: permissions to \\$PDQHost\${driveLetter}$ OR wrong folder. Verify setup.exe exists on host." "ERROR"
    exit 20
}

# ====== COPY MEDIA LOCALLY ======
$setupExe = $sourceSetupExe

if ($UseLocalCopy) {
    try {
        if (Test-Path $LocalSource) {
            Write-Log "Cleaning existing LocalSource folder: $LocalSource"
            Remove-Item $LocalSource -Recurse -Force -ErrorAction Stop
        }
        New-Item -ItemType Directory -Path $LocalSource -Force | Out-Null

        Write-Log "Copying ISO media locally with Robocopy..."
        $rcArgs = @(
            "`"$NetworkSource`"",
            "`"$LocalSource`"",
            "/MIR",
            "/R:2",
            "/W:2",
            "/NP",
            "/NFL",
            "/NDL"
        )
        $robocopy = Start-Process -FilePath "robocopy.exe" -ArgumentList $rcArgs -Wait -PassThru
        Write-Log ("Robocopy exit code: {0}" -f $robocopy.ExitCode)

        if ($robocopy.ExitCode -ge 8) {
            Write-Log "Robocopy reported a failure copying media." "ERROR"
            exit 20
        }

        $setupExe = Join-Path $LocalSource "setup.exe"
    } catch {
        Write-Log "Copy to local failed: $($_.Exception.Message)" "ERROR"
        exit 20
    }
}

if (-not (Test-Path $setupExe)) {
    Write-Log "setup.exe not found at: $setupExe" "ERROR"
    exit 20
}

Write-Log "Using setup.exe at: $setupExe"

# ====== RUN UPGRADE ======
try {
    Write-Log "Launching Windows 11 in-place upgrade (setup.exe)..."
    $p = Start-Process -FilePath $setupExe -ArgumentList $SetupArgs -Wait -PassThru
    Write-Log ("Setup process exit code: {0}" -f $p.ExitCode)

    if ($p.ExitCode -eq 0) {
        Write-Log "Setup completed/started successfully. (A reboot will still be needed.)"
        Write-Log "Panther logs (if created): C:\`$WINDOWS.~BT\Sources\Panther\"
        Write-Log "Fallback Panther logs: C:\Windows\Panther\"
        exit 0
    }
    elseif ($p.ExitCode -eq 183) {
        Write-Log "Setup returned 183 (Cannot create a file when that file already exists). Upgrade likely did not begin." "ERROR"
        Write-Log "Next check: C:\Windows\Panther\setupact.log and setuperr.log" "ERROR"
        exit 30
    }
    else {
        Write-Log "Setup returned non-zero exit code: $($p.ExitCode). Check logs for detail." "ERROR"
        Write-Log "Panther logs (if created): C:\`$WINDOWS.~BT\Sources\Panther\"
        Write-Log "Fallback Panther logs: C:\Windows\Panther\"
        exit 30
    }
} catch {
    Write-Log "Failed to launch setup.exe: $($_.Exception.Message)" "ERROR"
    exit 30
}
