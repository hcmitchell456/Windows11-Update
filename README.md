<!-- File: README.md -->
# Windows 10 → Windows 11 In-Place Upgrade (PDQ-Friendly)

This repo contains two PowerShell scripts designed for a **quiet, controlled Windows 11 in-place upgrade** using **extracted ISO media** (not mounted ISO) and a **separate reboot gate** step.

## What’s Included

- **Step 1**: `Win11-InPlaceUpgrade-Step1.ps1`  
  Performs compatibility checks, copies Windows 11 setup media locally, then launches `setup.exe` with quiet upgrade arguments.

- **Step 2**: `Win11-InPlaceUpgrade-Step2-RebootGate.ps1`  
  Schedules a reboot prompt **only** when upgrade signals exist (staging folder, setup running, or already Win11). This avoids unnecessary reboots.

## Requirements

- Windows 10 devices that meet Windows 11 baseline requirements:
  - TPM present + ready
  - Secure Boot enabled
  - UEFI firmware
  - 64-bit CPU
  - ≥ 4 GB RAM
  - ≥ 64 GB free disk space on C: (configurable)
- Extracted Windows 11 ISO media hosted on a machine reachable by targets (UNC admin share required)
- Administrator rights on targets
- Targets must be able to access the host path:
  - Example: `\\MSP-GQ-MIS\C$\Users\administrator...\Win11ISO\setup.exe`

## Logging

Both steps write logs to:

- `C:\ProgramData\PDQ\Logs\`

Examples:
- `Win11_Upgrade_YYYYMMDD_HHMMSS.log`
- `Win11_RebootGate_YYYYMMDD_HHMMSS.log`

## Step 1 Details (Upgrade Launch)

### What it does
1. Confirms the OS is not already Windows 11
2. Confirms setup is not already running
3. Runs compatibility checks:
   - TPM, Secure Boot, UEFI, CPU 64-bit, RAM, free disk space
4. Verifies `setup.exe` exists on the host media folder (via UNC path)
5. Optionally copies the media locally (default: `C:\Temp\Win11`)
6. Starts the upgrade:
   - `/auto upgrade /quiet /noreboot /dynamicupdate enable /eula accept /telemetry disable`

### Exit Codes
- `0`  = started successfully OR already Windows 11 OR setup already running
- `10` = not compatible (pre-check failed)
- `20` = installer not found / copy failed
- `30` = setup returned failure

## Step 2 Details (Reboot Gate)

### What it does
Schedules a reboot prompt when any of these signals are true:
- The machine is already Windows 11
- Setup processes are running (`setup`, `setuphost`, `setupprep`)
- Staging folder exists (`C:\$WINDOWS.~BT` or `C:\$WINDOWS.~WS`)
- Pending reboot indicators are present **only if staging exists**

> Note: Windows sometimes stages and exits setup processes. In that case, `Staged=True` is the key signal.

## Usage

### Option A: PDQ Deploy (Recommended)
Create a PDQ package with two PowerShell steps:

1. **PowerShell Step**: `Win11-InPlaceUpgrade-Step1.ps1`
2. **PowerShell Step**: `Win11-InPlaceUpgrade-Step2-RebootGate.ps1`

**PDQ Success Codes Recommendation**
- Step 1: success code = `0` (so failures are visible)
- Step 2: always exits `0` by design

### Option B: Run Manually (Admin PowerShell)

Run Step 1:
```powershell
.\Win11-InPlaceUpgrade-Step1.ps1 `
  -PDQHost "MSP-GQ-MIS" `
  -PDQMediaFolder "C:\Users\administrator.MCKENZIESP\Downloads\Win11ISO" `
  -UseLocalCopy `
  -LocalSource "C:\Temp\Win11" `
  -MinFreeGB 64
