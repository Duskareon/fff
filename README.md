# Gaming PC Optimizer

A single PowerShell script that cleans up, tunes and health-checks a slow Windows 10/11 gaming PC. It is safe to run more than once, and you can undo everything it changes.

## How to use

1. Download this folder to your PC.
2. Double-click **`Run-Optimizer.bat`** and click **Yes** when Windows asks for Administrator rights.
3. Read the **SUMMARY** at the end. It lists the problems the script can't fix by itself.
4. Restart the PC.

To revert every change, double-click **`Undo-Optimizer.bat`**.

## What it does

| Stage | Actions |
|---|---|
| **1. Safety net** | Creates a System Restore point. Saves the original value of every registry setting it changes to `optimizer-data/original-settings.json`. |
| **2. Cleanup** | Clears user and Windows temp files, the Windows Update download cache, error reports, crash dumps and old servicing logs, and empties the Recycle Bin. Reports how much space was freed. |
| **3. Tweaks** | Ultimate Performance power plan (High Performance on laptops), CPU minimum state 100%, PCIe/USB power saving off on AC power, Game Mode on, Hardware-accelerated GPU scheduling on, Xbox Game DVR background recording off, higher CPU/GPU/IO priority for games, Store apps blocked from running in the background, Windows ads and suggestions off, menu/window/taskbar animations off, transparency off, mouse acceleration off. |
| **4. Maintenance** | TRIM on SSDs, defrag on hard drives, DNS flush. With `-DeepRepair` it also runs `DISM /RestoreHealth` and `sfc /scannow`. |
| **5. Diagnostics** | Reports uptime, RAM usage and the top 10 programs by memory, free space and health for each disk, Windows installed on an HDD, GPU driver age, startup programs, Memory Integrity status, and possible CPU thermal throttling. |

## What it does not do

The script does not disable Windows Defender, Windows Update, the firewall, Memory Integrity, or any other security feature. It does not delete your files or uninstall programs, and it does not install anything.

## Options

Run it from an Administrator PowerShell window:

```powershell
.\GamingPCOptimizer.ps1                    # normal run
.\GamingPCOptimizer.ps1 -DeepRepair        # also repair Windows system files (10-30 min)
.\GamingPCOptimizer.ps1 -SkipVisualTweaks  # keep animations, transparency and mouse acceleration
.\GamingPCOptimizer.ps1 -SkipCleanup       # don't delete temp/junk files
.\GamingPCOptimizer.ps1 -SkipTweaks        # only clean up and report
.\GamingPCOptimizer.ps1 -NoRestorePoint    # skip the restore point
.\GamingPCOptimizer.ps1 -Undo              # revert everything
```

Each run writes a log to `optimizer-data/`.

## If games are still slow

Look at the **"Things you should fix yourself"** list. The most common causes are:

- **No restart in days.** Use *Restart*, not *Shut down*.
- **Old GPU driver.** Install the latest driver from NVIDIA, AMD or Intel.
- **Too many startup apps.** Go to Task Manager > Startup apps and disable what you don't need.
- **Disk almost full.** Keep at least 15–20% free.
- **Windows on a hard drive.** An SSD is the biggest upgrade you can make.
- **Overheating.** Clean dust out of the fans and check temperatures with HWMonitor.
- **Monitor running at 60 Hz.** Go to Settings > Display > Advanced display and pick the highest refresh rate.
