<#
.SYNOPSIS
    Gaming PC Optimizer - cleans up, tunes and health-checks a Windows 10/11 gaming PC.

.DESCRIPTION
    Runs in five stages:
      1. Safety     - creates a System Restore point and backs up every registry value it touches.
      2. Cleanup    - clears temp files, Windows Update download cache, crash dumps and error reports.
      3. Tweaks     - power plan, Game Mode, GPU scheduling, Game DVR off, input/visual latency tweaks.
      4. Maintenance- SSD TRIM / HDD defrag, DNS flush, optional SFC + DISM repair.
      5. Diagnostics- reports what is still slowing the PC down (startup apps, RAM hogs, low disk,
                      old GPU driver, long uptime, disk health) so you can fix it.

    Nothing here disables Windows Defender, Windows Update or other security features.
    Every tweak can be reverted with -Undo.

.PARAMETER Undo
    Restore all registry values and the power plan saved by a previous run.

.PARAMETER DeepRepair
    Also run 'sfc /scannow' and 'DISM /RestoreHealth' (takes 10-30 minutes).

.PARAMETER SkipCleanup
    Skip the junk-file cleanup stage.

.PARAMETER SkipTweaks
    Skip the performance tweaks stage (only clean up and report).

.PARAMETER SkipVisualTweaks
    Keep Windows animations, transparency and mouse acceleration as they are.

.PARAMETER NoRestorePoint
    Don't create a System Restore point.

.EXAMPLE
    .\GamingPCOptimizer.ps1
.EXAMPLE
    .\GamingPCOptimizer.ps1 -DeepRepair
.EXAMPLE
    .\GamingPCOptimizer.ps1 -Undo
#>
[CmdletBinding()]
param(
    [switch]$Undo,
    [switch]$DeepRepair,
    [switch]$SkipCleanup,
    [switch]$SkipTweaks,
    [switch]$SkipVisualTweaks,
    [switch]$NoRestorePoint
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Self-elevate to Administrator
# ---------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Requesting Administrator rights...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($key in $PSBoundParameters.Keys) { $argList += "-$key" }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    } catch {
        Write-Host 'Administrator rights are required. Right-click the script and choose "Run as administrator".' -ForegroundColor Red
        Read-Host 'Press Enter to exit'
    }
    exit
}

# ---------------------------------------------------------------------------
# Paths, logging and state
# ---------------------------------------------------------------------------
$ScriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$DataDir    = Join-Path $ScriptDir 'optimizer-data'
$BackupFile = Join-Path $DataDir 'original-settings.json'
$Stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile    = Join-Path $DataDir "optimizer-$Stamp.log"
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null

$script:Findings = New-Object System.Collections.Generic.List[string]
$script:Changes  = 0

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'OK', 'WARN', 'ERR', 'STEP')][string]$Level = 'INFO')
    $colors = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERR = 'Red'; STEP = 'Cyan' }
    if ($Level -eq 'STEP') {
        Write-Host ''
        Write-Host "=== $Message ===" -ForegroundColor $colors[$Level]
    } else {
        Write-Host "  [$Level] $Message" -ForegroundColor $colors[$Level]
    }
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'HH:mm:ss') [$Level] $Message"
}

function Add-Finding {
    param([string]$Text)
    $script:Findings.Add($Text)
    Write-Log $Text 'WARN'
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

# ---------------------------------------------------------------------------
# Backup store (registry values + power plan) so everything can be undone
# ---------------------------------------------------------------------------
$script:Backup = @{ PowerScheme = $null; Registry = @() }
if (Test-Path $BackupFile) {
    try {
        $loaded = Get-Content $BackupFile -Raw | ConvertFrom-Json
        $script:Backup.PowerScheme = $loaded.PowerScheme
        $script:Backup.Registry = @($loaded.Registry)
    } catch {
        Write-Host "Backup file is unreadable: $BackupFile" -ForegroundColor Red
    }
}

function Save-Backup {
    $script:Backup | ConvertTo-Json -Depth 5 | Set-Content -Path $BackupFile -Encoding UTF8
}

function Set-RegValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord', 'String')][string]$Type = 'DWord',
        [string]$Description
    )
    try {
        # Record the ORIGINAL value only once, so repeated runs never overwrite the true original.
        $already = $script:Backup.Registry | Where-Object { $_.Path -eq $Path -and $_.Name -eq $Name }
        if (-not $already) {
            $entry = [ordered]@{ Path = $Path; Name = $Name; Existed = $false; Value = $null; Type = $Type }
            if (Test-Path $Path) {
                $key = Get-Item -Path $Path
                if ($key.GetValueNames() -contains $Name) {
                    $entry.Existed = $true
                    $entry.Value = $key.GetValue($Name)
                    $entry.Type = $key.GetValueKind($Name).ToString()
                }
            }
            $script:Backup.Registry += [pscustomobject]$entry
            Save-Backup
        }

        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue)
        if ($null -ne $current -and "$($current.$Name)" -eq "$Value") {
            Write-Log "$Description (already set)" 'OK'
            return
        }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        $script:Changes++
        Write-Log $Description 'OK'
    } catch {
        Write-Log "Failed: $Description - $($_.Exception.Message)" 'ERR'
    }
}

# ---------------------------------------------------------------------------
# UNDO MODE
# ---------------------------------------------------------------------------
if ($Undo) {
    Write-Log 'Undoing Gaming PC Optimizer changes' 'STEP'
    if (-not (Test-Path $BackupFile)) {
        Write-Log "No backup found at $BackupFile - nothing to undo." 'WARN'
        Read-Host 'Press Enter to exit'
        exit
    }
    foreach ($e in $script:Backup.Registry) {
        try {
            if ($e.Existed) {
                if (-not (Test-Path $e.Path)) { New-Item -Path $e.Path -Force | Out-Null }
                New-ItemProperty -Path $e.Path -Name $e.Name -Value $e.Value -PropertyType $e.Type -Force | Out-Null
                Write-Log "Restored $($e.Path)\$($e.Name) = $($e.Value)" 'OK'
            } elseif (Test-Path $e.Path) {
                Remove-ItemProperty -Path $e.Path -Name $e.Name -ErrorAction SilentlyContinue
                Write-Log "Removed $($e.Path)\$($e.Name) (did not exist before)" 'OK'
            }
        } catch {
            Write-Log "Could not restore $($e.Path)\$($e.Name): $($_.Exception.Message)" 'ERR'
        }
    }
    if ($script:Backup.PowerScheme) {
        powercfg /setactive $script:Backup.PowerScheme | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Log "Restored power plan $($script:Backup.PowerScheme)" 'OK' }
        else { Write-Log 'Could not restore the previous power plan.' 'ERR' }
    }
    Rename-Item -Path $BackupFile -NewName "original-settings.restored-$Stamp.json"
    Write-Host ''
    Write-Host 'Undo complete. Restart your PC to apply everything.' -ForegroundColor Green
    Read-Host 'Press Enter to exit'
    exit
}

# ---------------------------------------------------------------------------
# Header + system info
# ---------------------------------------------------------------------------
Clear-Host
Write-Host '=================================================' -ForegroundColor Cyan
Write-Host '              GAMING PC OPTIMIZER                ' -ForegroundColor Cyan
Write-Host '=================================================' -ForegroundColor Cyan

$os   = Get-CimInstance Win32_OperatingSystem
$cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
$gpus = @(Get-CimInstance Win32_VideoController)
$ramGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$isLaptop = $null -ne (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)

Write-Log "OS:  $($os.Caption) (build $($os.BuildNumber))"
Write-Log "CPU: $($cpu.Name.Trim())"
foreach ($g in $gpus) { Write-Log "GPU: $($g.Name)" }
Write-Log "RAM: $ramGB GB"
Write-Log "Log: $LogFile"

# ---------------------------------------------------------------------------
# STAGE 1 - Safety net
# ---------------------------------------------------------------------------
Write-Log 'Stage 1/5 - Safety net' 'STEP'
if (-not $NoRestorePoint) {
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        # Windows normally allows only one restore point per 24h; lift that for this run.
        $srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        New-ItemProperty -Path $srKey -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force | Out-Null
        Checkpoint-Computer -Description "Gaming PC Optimizer $Stamp" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Remove-ItemProperty -Path $srKey -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue
        Write-Log 'System Restore point created.' 'OK'
    } catch {
        Write-Log "Could not create a restore point ($($_.Exception.Message)). Registry backup will still be made." 'WARN'
    }
} else {
    Write-Log 'Restore point skipped (-NoRestorePoint).'
}
Write-Log "Registry backup file: $BackupFile" 'OK'

# ---------------------------------------------------------------------------
# STAGE 2 - Cleanup
# ---------------------------------------------------------------------------
Write-Log 'Stage 2/5 - Junk file cleanup' 'STEP'
if (-not $SkipCleanup) {
    function Clear-Folder {
        param([string]$Path, [string]$Label)
        if (-not (Test-Path $Path)) { return 0 }
        $before = (Get-ChildItem -Path $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                   Measure-Object -Property Length -Sum).Sum
        if (-not $before) { $before = 0 }
        Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $after = (Get-ChildItem -Path $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                  Measure-Object -Property Length -Sum).Sum
        if (-not $after) { $after = 0 }
        $freed = [math]::Max(0, $before - $after)
        Write-Log ("{0}: freed {1}" -f $Label, (Format-Size $freed)) 'OK'
        return $freed
    }

    $totalFreed = 0
    $totalFreed += Clear-Folder $env:TEMP 'User temp files'
    $totalFreed += Clear-Folder "$env:SystemRoot\Temp" 'Windows temp files'
    $totalFreed += Clear-Folder "$env:ProgramData\Microsoft\Windows\WER\ReportArchive" 'Error reports (archive)'
    $totalFreed += Clear-Folder "$env:ProgramData\Microsoft\Windows\WER\ReportQueue" 'Error reports (queue)'
    $totalFreed += Clear-Folder "$env:LOCALAPPDATA\CrashDumps" 'Application crash dumps'
    $totalFreed += Clear-Folder "$env:SystemRoot\Logs\CBS" 'Old servicing logs'

    # Windows Update download cache (re-downloaded only if needed)
    Write-Log 'Stopping Windows Update services to clear the download cache...'
    $wuServices = 'wuauserv', 'bits'
    $wuServices | ForEach-Object { Stop-Service -Name $_ -Force -ErrorAction SilentlyContinue }
    $totalFreed += Clear-Folder "$env:SystemRoot\SoftwareDistribution\Download" 'Windows Update cache'
    $wuServices | ForEach-Object { Start-Service -Name $_ -ErrorAction SilentlyContinue }

    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Write-Log 'Recycle Bin emptied.' 'OK'
    } catch {
        Write-Log 'Recycle Bin already empty.' 'OK'
    }

    Write-Log ("Total space freed: {0}" -f (Format-Size $totalFreed)) 'OK'
} else {
    Write-Log 'Cleanup skipped (-SkipCleanup).'
}

# ---------------------------------------------------------------------------
# STAGE 3 - Performance tweaks
# ---------------------------------------------------------------------------
Write-Log 'Stage 3/5 - Gaming performance tweaks' 'STEP'
if (-not $SkipTweaks) {

    # --- Power plan -------------------------------------------------------
    $activeOutput = powercfg /getactivescheme
    $activeGuid = [regex]::Match($activeOutput, '[0-9a-fA-F-]{36}').Value
    if (-not $script:Backup.PowerScheme -and $activeGuid) {
        $script:Backup.PowerScheme = $activeGuid
        Save-Backup
    }

    $highPerf = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    $targetGuid = $null
    if ($isLaptop) {
        Write-Log 'Laptop detected - using High Performance (Ultimate drains the battery fast).'
        $targetGuid = $highPerf
    } else {
        $schemes = powercfg /list
        $ultimateLine = $schemes | Where-Object { $_ -match 'Ultimate Performance' } | Select-Object -First 1
        if ($ultimateLine) {
            $targetGuid = [regex]::Match($ultimateLine, '[0-9a-fA-F-]{36}').Value
        } else {
            $dup = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null
            $targetGuid = [regex]::Match("$dup", '[0-9a-fA-F-]{36}').Value
        }
        if (-not $targetGuid) { $targetGuid = $highPerf }
    }
    powercfg /setactive $targetGuid 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0 -and $targetGuid -ne $highPerf) {
        powercfg /setactive $highPerf 2>$null | Out-Null
    }
    if ($LASTEXITCODE -eq 0) {
        $script:Changes++
        $name = [regex]::Match((powercfg /getactivescheme), '\((.+)\)').Groups[1].Value
        Write-Log "Power plan set to: $name" 'OK'
        # Never let the CPU park/throttle and never sleep the PCIe link (GPU) while plugged in.
        powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100 2>$null | Out-Null
        powercfg /setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0 2>$null | Out-Null
        powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>$null | Out-Null  # USB selective suspend off
        powercfg /setactive SCHEME_CURRENT 2>$null | Out-Null
        Write-Log 'CPU min state 100%, PCIe power saving off, USB selective suspend off (on AC power).' 'OK'
    } else {
        Write-Log 'Could not change the power plan (it may be locked by your PC maker or group policy).' 'WARN'
    }

    # --- Windows gaming features -----------------------------------------
    Set-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1 -Description 'Game Mode enabled'
    Set-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1 -Description 'Game Mode allowed automatically'
    Set-RegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0 -Description 'Xbox Game DVR background recording disabled'
    Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 -Description 'Background app capture disabled'
    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2 -Description 'Hardware-accelerated GPU scheduling enabled (needs reboot, supported GPUs only)'

    # --- CPU/GPU scheduling priority for games ---------------------------
    $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Set-RegValue $mm 'SystemResponsiveness' 10 -Description 'Less CPU reserved for background tasks (SystemResponsiveness=10)'
    Set-RegValue "$mm\Tasks\Games" 'GPU Priority' 8 -Description 'Games: high GPU priority'
    Set-RegValue "$mm\Tasks\Games" 'Priority' 6 -Description 'Games: high CPU priority'
    Set-RegValue "$mm\Tasks\Games" 'Scheduling Category' 'High' -Type String -Description 'Games: high scheduling category'
    Set-RegValue "$mm\Tasks\Games" 'SFIO Priority' 'High' -Type String -Description 'Games: high disk I/O priority'

    # --- Background noise --------------------------------------------------
    Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1 -Description 'Store apps blocked from running in the background'
    Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 0 -Description 'Start menu suggestions disabled'
    Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0 -Description 'Silent install of promoted apps disabled'
    Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0 -Description 'Settings suggestions disabled'

    # --- Visual / input latency --------------------------------------------
    if (-not $SkipVisualTweaks) {
        Set-RegValue 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '0' -Type String -Description 'Menus open instantly'
        Set-RegValue 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' -Type String -Description 'Window minimize/maximize animation off'
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0 -Description 'Taskbar animations off'
        Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0 -Description 'Transparency effects off'
        Set-RegValue 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' -Type String -Description 'Mouse acceleration (Enhance pointer precision) off'
        Set-RegValue 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' -Type String -Description 'Mouse threshold 1 = 0'
        Set-RegValue 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' -Type String -Description 'Mouse threshold 2 = 0'
    } else {
        Write-Log 'Visual/mouse tweaks skipped (-SkipVisualTweaks).'
    }
} else {
    Write-Log 'Tweaks skipped (-SkipTweaks).'
}

# ---------------------------------------------------------------------------
# STAGE 4 - Maintenance
# ---------------------------------------------------------------------------
Write-Log 'Stage 4/5 - Disk and system maintenance' 'STEP'

# SSD TRIM / HDD defrag on every fixed drive
$physical = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
foreach ($vol in Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystem -eq 'NTFS' }) {
    $letter = $vol.DriveLetter
    $media = 'Unknown'
    try {
        $diskNum = (Get-Partition -DriveLetter $letter -ErrorAction Stop).DiskNumber
        $pd = $physical | Where-Object { $_.DeviceId -eq "$diskNum" } | Select-Object -First 1
        if ($pd) { $media = "$($pd.MediaType)" }
    } catch { }
    try {
        if ($media -eq 'HDD') {
            Write-Log "Drive ${letter}: (HDD) - defragmenting, this can take a while..."
            Optimize-Volume -DriveLetter $letter -Defrag -ErrorAction Stop
            Write-Log "Drive ${letter}: defragmented." 'OK'
        } else {
            Optimize-Volume -DriveLetter $letter -ReTrim -ErrorAction Stop
            Write-Log "Drive ${letter}: ($media) TRIM completed." 'OK'
        }
    } catch {
        Write-Log "Drive ${letter}: optimize skipped ($($_.Exception.Message))" 'WARN'
    }
}

ipconfig /flushdns | Out-Null
Write-Log 'DNS cache flushed.' 'OK'

if ($DeepRepair) {
    Write-Log 'Running DISM /RestoreHealth (can take 10-20 min)...'
    DISM /Online /Cleanup-Image /RestoreHealth | Out-Host
    Write-Log 'Running DISM component store cleanup...'
    DISM /Online /Cleanup-Image /StartComponentCleanup | Out-Host
    Write-Log 'Running System File Checker (sfc /scannow)...'
    sfc /scannow | Out-Host
    Write-Log 'Deep repair finished.' 'OK'
} else {
    Write-Log 'Tip: run with -DeepRepair to also scan/repair corrupted Windows files.'
}

# ---------------------------------------------------------------------------
# STAGE 5 - Diagnostics: what else is slowing the PC down
# ---------------------------------------------------------------------------
Write-Log 'Stage 5/5 - Diagnostics' 'STEP'

# Uptime
$uptime = (Get-Date) - $os.LastBootUpTime
Write-Log ("Uptime: {0} days {1} hours" -f $uptime.Days, $uptime.Hours)
if ($uptime.TotalDays -ge 3) {
    Add-Finding "PC has not been restarted in $($uptime.Days) days. 'Shut down' does not fully reset Windows (Fast Startup) - use Restart."
}

# RAM
$os = Get-CimInstance Win32_OperatingSystem
$usedPct = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100)
Write-Log "RAM in use right now: $usedPct%"
if ($ramGB -lt 15) { Add-Finding "Only $ramGB GB RAM. 16 GB is the practical minimum for modern games." }
if ($usedPct -ge 75) { Add-Finding "RAM is $usedPct% used before gaming. Close the programs listed below." }

Write-Log 'Top 10 programs by memory use:'
Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 10 | ForEach-Object {
    Write-Log ("   {0,-32} {1,10}" -f $_.ProcessName, (Format-Size $_.WorkingSet64))
}

# Disk space + health
foreach ($vol in Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size -gt 0 }) {
    $freePct = [math]::Round($vol.SizeRemaining / $vol.Size * 100)
    Write-Log ("Drive {0}: {1} free of {2} ({3}%)" -f $vol.DriveLetter, (Format-Size $vol.SizeRemaining), (Format-Size $vol.Size), $freePct)
    if ($freePct -lt 15) { Add-Finding "Drive $($vol.DriveLetter): is only $freePct% free. Keep at least 15-20% free or it slows down." }
}
foreach ($pd in $physical) {
    Write-Log "Disk: $($pd.FriendlyName) [$($pd.MediaType)] health: $($pd.HealthStatus)"
    if ($pd.HealthStatus -ne 'Healthy') { Add-Finding "Disk '$($pd.FriendlyName)' reports health '$($pd.HealthStatus)'. Back up your files and check it." }
    if ($pd.MediaType -eq 'HDD') {
        $sysDisk = (Get-Partition -DriveLetter $env:SystemDrive[0] -ErrorAction SilentlyContinue).DiskNumber
        if ("$sysDisk" -eq "$($pd.DeviceId)") {
            Add-Finding 'Windows is installed on a hard drive (HDD). Moving to an SSD is the single biggest speed upgrade.'
        }
    }
}

# GPU driver age
foreach ($g in $gpus) {
    if ($g.DriverDate) {
        $age = ((Get-Date) - $g.DriverDate).Days
        Write-Log "GPU driver: $($g.Name) v$($g.DriverVersion) ($age days old)"
        if ($age -gt 180 -and $g.Name -match 'NVIDIA|AMD|Radeon|Intel\(R\) Arc') {
            Add-Finding "GPU driver for $($g.Name) is $age days old. Update it from the NVIDIA / AMD / Intel website."
        }
    }
}

# Startup programs
$startup = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue)
Write-Log "Programs that launch at startup: $($startup.Count)"
foreach ($s in $startup) { Write-Log "   $($s.Name)  ->  $($s.Location)" }
if ($startup.Count -gt 8) {
    Add-Finding "$($startup.Count) programs start with Windows. Disable the ones you don't need: Task Manager > Startup apps."
}

# Memory Integrity (VBS/HVCI) - report only, it's a security feature
try {
    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
    if ($dg.SecurityServicesRunning -contains 2) {
        Write-Log 'Memory Integrity (Core Isolation) is ON. It is a security feature that can cost a few % FPS.' 'INFO'
        Write-Log 'This script leaves it on. You can review it in Windows Security > Device security > Core isolation.' 'INFO'
    }
} catch { }

# Overheating hint: CPU throttling shows up as low current clock vs max
if ($cpu.CurrentClockSpeed -and $cpu.MaxClockSpeed -and $cpu.CurrentClockSpeed -lt ($cpu.MaxClockSpeed * 0.5)) {
    Add-Finding "CPU is running at $($cpu.CurrentClockSpeed) MHz of $($cpu.MaxClockSpeed) MHz. If games stutter, check temperatures (dust, fans, thermal paste)."
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=================================================' -ForegroundColor Cyan
Write-Host '                    SUMMARY                      ' -ForegroundColor Cyan
Write-Host '=================================================' -ForegroundColor Cyan
Write-Log "Settings changed this run: $script:Changes" 'OK'
if ($script:Findings.Count -gt 0) {
    Write-Host ''
    Write-Host 'Things you should fix yourself:' -ForegroundColor Yellow
    $i = 1
    foreach ($f in $script:Findings) { Write-Host "  $i. $f" -ForegroundColor Yellow; $i++ }
} else {
    Write-Host 'No other problems found.' -ForegroundColor Green
}
Write-Host ''
Write-Host "Full log:      $LogFile"
Write-Host "Undo anytime:  run Undo-Optimizer.bat (or this script with -Undo)"
Write-Host ''

$answer = Read-Host 'A restart is needed for all changes to apply. Restart now? (y/N)'
if ($answer -match '^[Yy]') {
    Restart-Computer -Force
}
