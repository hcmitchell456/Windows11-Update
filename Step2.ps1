# File: Win11-InPlaceUpgrade-Step2-RebootGate.ps1
<#
Step 2: Upgrade-aware reboot prompt (PDQ-friendly)

Schedules a reboot (with message) only when there is evidence the upgrade is:
- Completed (Windows 11), OR
- In progress (setup processes), OR
- Staged (C:\$WINDOWS.~BT or C:\$WINDOWS.~WS)

Pending reboot is checked ONLY if staging exists (reduces false prompts from Windows Updates).

Exit codes:
  0 = No error (reboot scheduled OR intentionally skipped)

Logs:
  C:\ProgramData\PDQ\Logs\Win11_RebootGate_*.log
#>

[CmdletBinding()]
param(
    [int]$MinutesUntilRestart = 60,
    [string]$Message = "Windows 11 upgrade is ready to continue. Your PC will restart in 60 minutes. Please save your work. You may restart sooner if convenient."
)

$TimeoutSeconds = $MinutesUntilRestart * 60

# --- Logging ---
$LogDir  = "C:\ProgramData\PDQ\Logs"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir ("Win11_RebootGate_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

function Write-Log {
    param([string]$Message, [ValidateSet("INFO","WARN","ERROR")] [string]$Level="INFO")
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    $line | Tee-Object -FilePath $LogFile -Append
}

function Test-PendingReboot {
    $pending = $false

    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
        $pending = $true
    }
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
        $pending = $true
    }
    try {
        $p = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue
        if ($p.PendingFileRenameOperations) { $pending = $true }
    } catch {}

    return $pending
}

Write-Log "==== Windows 11 Reboot Gate Starting (Step 2) ===="

# --- Signals ---
$osCaption = ""
try { $osCaption = (Get-CimInstance Win32_OperatingSystem).Caption } catch {}

$IsWin11 = ($osCaption -match "Windows 11")

$SetupRunning = $false
try { $SetupRunning = [bool](Get-Process setup, setuphost, setupprep -ErrorAction SilentlyContinue) } catch {}

$Staged = (Test-Path 'C:\$WINDOWS.~BT') -or (Test-Path 'C:\$WINDOWS.~WS')

# Only treat pending reboot as relevant if staging exists
$PendingReboot = $false
if ($Staged) { $PendingReboot = Test-PendingReboot }

Write-Log "Signals: OS='$osCaption' Win11=$IsWin11 SetupRunning=$SetupRunning Staged=$Staged PendingReboot=$PendingReboot"

# --- Decide ---
if ($IsWin11 -or $SetupRunning -or $Staged -or ($Staged -and $PendingReboot)) {
    Write-Log "Reboot conditions met. Scheduling reboot prompt in $MinutesUntilRestart minutes."
    shutdown.exe /r /t $TimeoutSeconds /c $Message
    Write-Host "Reboot scheduled in $MinutesUntilRestart minutes. Signals: Win11=$IsWin11 SetupRunning=$SetupRunning Staged=$Staged PendingReboot=$PendingReboot"
    exit 0
}

Write-Log "No upgrade signals detected. Skipping reboot prompt."
Write-Host "No upgrade signals detected (Win11=$IsWin11 SetupRunning=$SetupRunning Staged=$Staged PendingReboot=$PendingReboot). Skipping reboot prompt."
exit 0
