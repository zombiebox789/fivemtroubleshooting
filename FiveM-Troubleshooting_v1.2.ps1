<# 
FiveM Troubleshooting - Menu Tool
Save as: FiveM-Troubleshooting.ps1

Recommended run (Admin):
powershell -ExecutionPolicy Bypass -File "C:\Path\FiveM-Troubleshooting.ps1"
#>

$ErrorActionPreference = "Stop"

#region Helpers

function Test-IsAdmin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Pause-Console {
    Write-Host ""
    Read-Host "Press ENTER to return to the menu..." | Out-Null
}

function Wait-BeforeExit {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "Script finished. Press ENTER to close..." -ForegroundColor Gray
    Write-Host "============================================================" -ForegroundColor DarkGray
    Read-Host | Out-Null
}

function Write-Title {
    param([string]$Text)
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   $Text" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Get-FiveMBasePath {
    $default = Join-Path $env:LOCALAPPDATA "FiveM\FiveM.app"
    if (Test-Path $default) { return $default }

    # Quick fallbacks (common roots)
    $candidates = @(
        "C:\FiveM\FiveM.app",
        "D:\FiveM\FiveM.app",
        "E:\FiveM\FiveM.app"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }

    # Return default even if missing so we can show a helpful message
    return $default
}

function Remove-ContentsSafe {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$MissingMessage = "Please let support know this folder location does not exist."
    )

    if (-not (Test-Path $Path)) {
        Write-Host "[!] Not Found: $Path" -ForegroundColor Yellow
        Write-Host "    $MissingMessage" -ForegroundColor Yellow
        return
    }

    Write-Host "[*] Deleting contents of: $Path" -ForegroundColor Green

    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Host "[!] Failed to delete: $($_.FullName)" -ForegroundColor Yellow
            Write-Host "    $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }

    Write-Host "[+] Done." -ForegroundColor Green
}

function Convert-CimDateSafe {
    param(
        [AllowNull()][AllowEmptyString()][string]$CimDate
    )
    if ([string]::IsNullOrWhiteSpace($CimDate)) { return "Unknown" }
    try {
        return [Management.ManagementDateTimeConverter]::ToDateTime($CimDate)
    } catch {
        return "Unknown"
    }
}

function Get-GpuInfoFromRegistry {
    <#
      Returns objects with:
        - Name  (HardwareInformation.AdapterString)
        - VramGB (from HardwareInformation.qwMemorySize)
      This is typically more accurate than Win32_VideoController.AdapterRAM on modern GPUs.
    #>
    $results = @()

    try {
        $videoRoot = "HKLM:\SYSTEM\CurrentControlSet\Control\Video"
        if (-not (Test-Path $videoRoot)) { return @() }

        foreach ($guidKey in (Get-ChildItem $videoRoot -ErrorAction SilentlyContinue)) {
            $p = Join-Path $guidKey.PSPath "0000"
            if (-not (Test-Path $p)) { continue }

            $props = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
            $name = $props."HardwareInformation.AdapterString"
            $memBytes = $props."HardwareInformation.qwMemorySize"

            if (-not $name -and -not $memBytes) { continue }

            $vramGB = "Unknown"
            if ($memBytes -and ($memBytes -is [ValueType] -or $memBytes -is [string])) {
                try { $vramGB = [Math]::Round(([double]$memBytes / 1GB), 0) } catch { $vramGB = "Unknown" }
            }

            $results += [PSCustomObject]@{
                Name   = $name
                VramGB = $vramGB
                Path   = $p
            }
        }
    } catch {
        return @()
    }

    # De-dup by Name+VramGB
    $results | Where-Object { $_.Name -or $_.VramGB -ne "Unknown" } |
        Group-Object Name, VramGB | ForEach-Object { $_.Group | Select-Object -First 1 }
}

function Get-GpuVramForName {
    param(
        [Parameter(Mandatory=$true)][string]$GpuName
    )

    $regGpus = Get-GpuInfoFromRegistry
    if (-not $regGpus -or $regGpus.Count -eq 0) { return "Unknown" }

    # Best match: exact, then contains (either direction)
    $exact = $regGpus | Where-Object { $_.Name -and ($_.Name -eq $GpuName) } | Select-Object -First 1
    if ($exact) { return $exact.VramGB }

    $contains1 = $regGpus | Where-Object { $_.Name -and ($_.Name -like "*$GpuName*") } | Select-Object -First 1
    if ($contains1) { return $contains1.VramGB }

    $contains2 = $regGpus | Where-Object { $_.Name -and ($GpuName -like "*$($_.Name)*") } | Select-Object -First 1
    if ($contains2) { return $contains2.VramGB }

    # Fallback: first VRAM we have
    $any = $regGpus | Where-Object { $_.VramGB -ne "Unknown" } | Select-Object -First 1
    if ($any) { return $any.VramGB }

    return "Unknown"
}

#endregion Helpers

#region Logging

function Get-LogFolder {
    Join-Path $env:USERPROFILE "Desktop\FiveM-Troubleshooting-Logs"
}

function Start-Logging {
    $logDir = Get-LogFolder
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

    $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logPath = Join-Path $logDir "FiveM_Troubleshooting_$stamp.txt"

    try {
        Start-Transcript -Path $logPath -Append | Out-Null
        Write-Host "[+] Logging to: $logPath" -ForegroundColor Green
    } catch {
        Write-Host "[!] Could not start transcript logging: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Stop-Logging {
    try { Stop-Transcript | Out-Null } catch {}
}

function Get-LatestLogFile {
    $logDir = Get-LogFolder
    if (-not (Test-Path $logDir)) { return $null }

    Get-ChildItem -Path $logDir -Filter "*.txt" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

#endregion Logging

#region Reports

function New-PCSpecsReport {
    param(
        [Parameter(Mandatory=$true)][string]$OutputPath
    )

    Write-Host "[*] Collecting PC specs..." -ForegroundColor Cyan

    $os   = Get-CimInstance Win32_OperatingSystem
    $cs   = Get-CimInstance Win32_ComputerSystem
    $cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS
    $gpus = Get-CimInstance Win32_VideoController
    $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"
    $nics  = Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true }

    $ramGB = [Math]::Round(($cs.TotalPhysicalMemory / 1GB), 2)

    $installDate = Convert-CimDateSafe -CimDate $os.InstallDate
    $lastBoot    = Convert-CimDateSafe -CimDate $os.LastBootUpTime
    $biosDate    = Convert-CimDateSafe -CimDate $bios.ReleaseDate

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("PC Specs Report")
    $lines.Add("Generated: $(Get-Date)")
    $lines.Add("------------------------------------------------------------")
    $lines.Add("Computer Name: $($env:COMPUTERNAME)")
    $lines.Add("User: $($env:USERNAME)")
    $lines.Add("")
    $lines.Add("OS: $($os.Caption)  (Build $($os.BuildNumber))")
    $lines.Add("Version: $($os.Version)")
    $lines.Add("Install Date: $installDate")
    $lines.Add("Last Boot: $lastBoot")
    $lines.Add("")
    $lines.Add("Motherboard/Model: $($cs.Manufacturer) $($cs.Model)")
    $lines.Add("BIOS: $($bios.Manufacturer) $($bios.SMBIOSBIOSVersion)  (Released $biosDate)")
    $lines.Add("")
    $lines.Add("CPU: $($cpu.Name)")
    $lines.Add("Cores/Threads: $($cpu.NumberOfCores)/$($cpu.NumberOfLogicalProcessors)")
    $lines.Add("RAM (GB): $ramGB")
    $lines.Add("")
    $lines.Add("GPU(s):")

    foreach ($g in $gpus) {
        $vram = Get-GpuVramForName -GpuName $g.Name
        $lines.Add("  - $($g.Name) (VRAM: $vram GB)")
    }

    $lines.Add("")
    $lines.Add("Storage (Fixed Disks):")
    foreach ($d in $disks) {
        $sizeGB = if ($d.Size) { [Math]::Round(($d.Size/1GB), 2) } else { "Unknown" }
        $freeGB = if ($d.FreeSpace) { [Math]::Round(($d.FreeSpace/1GB), 2) } else { "Unknown" }
        $lines.Add("  - $($d.DeviceID)  Label: $($d.VolumeName)  Free: $freeGB GB / $sizeGB GB  FileSystem: $($d.FileSystem)")
    }

    $lines.Add("")
    $lines.Add("Network (IP-enabled adapters):")
    foreach ($n in $nics) {
        $ips = ($n.IPAddress -join ", ")
        $lines.Add("  - $($n.Description)")
        $lines.Add("    IP: $ips")
    }

    $lines.Add("")
    $lines.Add("------------------------------------------------------------")
    $lines.Add("Notes:")
    $lines.Add("- Mention where FiveM/GTA is installed (C:, D:, etc.)")
    $lines.Add("- Attach this file + the log ZIP to the Discord ticket.")

    $lines | Out-File -LiteralPath $OutputPath -Encoding UTF8 -Force
    Write-Host "[+] Specs saved to: $OutputPath" -ForegroundColor Green
}

#endregion Reports

#region Actions

function Run-SFC {
    Write-Title "System File Checker (SFC)"
    Write-Host "[*] Running: sfc /scannow" -ForegroundColor Green
    Write-Host "    This can take a while. Don’t close the window." -ForegroundColor Gray
    sfc /scannow
    Write-Host "[+] SFC completed." -ForegroundColor Green
    Pause-Console
}

function Run-DISMRestoreHealth {
    Write-Title "DISM RestoreHealth"
    Write-Host "[*] Running: DISM /Online /Cleanup-Image /RestoreHealth" -ForegroundColor Green
    Write-Host "    This can take a while." -ForegroundColor Gray
    DISM /Online /Cleanup-Image /RestoreHealth
    Write-Host "[+] DISM completed." -ForegroundColor Green
    Pause-Console
}

function Run-CHKDSK {
    Write-Title "CHKDSK (Disk Check)"
    Write-Host "Choose a drive to check (example: C: or D:)" -ForegroundColor Gray
    $drive = Read-Host "Drive letter (like C:)"

    if ([string]::IsNullOrWhiteSpace($drive)) { return }

    # Normalize
    $drive = $drive.Trim().TrimEnd("\")
    if ($drive.Length -eq 1) { $drive = "${drive}:" }  # FIX: avoid $drive: parsing bug

    # Validate
    if ($drive -notmatch '^[A-Za-z]:$') {
        Write-Host "[!] Invalid drive format. Use C: or D:" -ForegroundColor Yellow
        Pause-Console
        return
    }

    Write-Host ""
    Write-Host "1) Online scan (no reboot): chkdsk $drive /scan" -ForegroundColor Cyan
    Write-Host "2) Full repair (may require reboot): chkdsk $drive /r /f" -ForegroundColor Cyan
    $mode = Read-Host "Pick 1 or 2"

    if ($mode -eq "1") {
        Write-Host "[*] Running: chkdsk $drive /scan" -ForegroundColor Green
        chkdsk $drive /scan
        Write-Host "[+] CHKDSK /scan completed." -ForegroundColor Green
    }
    elseif ($mode -eq "2") {
        Write-Host "[*] Running: chkdsk $drive /r /f" -ForegroundColor Green
        Write-Host "    If it says the drive is in use, type Y to schedule at reboot." -ForegroundColor Gray
        chkdsk $drive /r /f
        Write-Host "[+] CHKDSK command finished (may be scheduled)." -ForegroundColor Green
    }
    else {
        Write-Host "[!] Invalid selection." -ForegroundColor Yellow
    }

    Pause-Console
}

function Clear-FiveMCacheAndCrashes {
    Write-Title "Clear FiveM Cache + Crash Logs"

    $fiveM = Get-FiveMBasePath
    Write-Host "[*] FiveM base path: $fiveM" -ForegroundColor Gray
    Write-Host ""

    $dataPath        = Join-Path $fiveM "data"
    $serverCachePriv = Join-Path $dataPath "server-cache-priv"
    $serverCache     = Join-Path $dataPath "server-cache"
    $nuiCache        = Join-Path $dataPath "nui-storage"
    $crashesPath     = Join-Path $fiveM "crashes"

    Write-Host "Deleting cache folders..." -ForegroundColor Cyan
    Remove-ContentsSafe -Path $serverCachePriv -MissingMessage "Please let support know this folder location does not exist."
    Remove-ContentsSafe -Path $serverCache     -MissingMessage "Please let support know this folder location does not exist."
    Remove-ContentsSafe -Path $nuiCache        -MissingMessage "Please let support know this folder location does not exist."

    Write-Host ""
    Write-Host "Deleting crash logs..." -ForegroundColor Cyan
    Remove-ContentsSafe -Path $crashesPath -MissingMessage "Please let support know this folder location does not exist."

    Write-Host ""
    Write-Host "[+] Cleanup complete." -ForegroundColor Green
    Pause-Console
}

function Open-FiveMFolder {
    Write-Title "Open FiveM Folder"
    $fiveM = Get-FiveMBasePath

    if (Test-Path $fiveM) {
        Write-Host "[*] Opening: $fiveM" -ForegroundColor Green
        Start-Process explorer.exe $fiveM
    } else {
        Write-Host "[!] Not Found: $fiveM" -ForegroundColor Yellow
        Write-Host "    Please let support know this folder location does not exist." -ForegroundColor Yellow
    }

    Pause-Console
}

function Show-Checklist {
    Write-Title "Quick Checklist"
    Write-Host "- Clear Cache / Clear Crash Logs (Option 4)" -ForegroundColor Gray
    Write-Host "- Check if FiveM is most current version" -ForegroundColor Gray
    Write-Host "- Check GTA 5 is up to date and verify game files" -ForegroundColor Gray
    Write-Host "- Check Hard Drive and Storage Space (C: should be in the Blue)" -ForegroundColor Gray
    Write-Host "- FiveM / GTA operate best on main drive" -ForegroundColor Gray
    Write-Host "- Windows Update + GPU Driver Update" -ForegroundColor Gray
    Write-Host "- Try switching CFX (Beta/Release/Latest) + enable NUI in-process GPU if available" -ForegroundColor Gray
    Pause-Console
}

function Export-PCSpecsToDesktop {
    Write-Title "Export PC Specs Report"
    $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $outPath = Join-Path $env:USERPROFILE "Desktop\FiveM-PC-Specs-$stamp.txt"
    New-PCSpecsReport -OutputPath $outPath
    Start-Process explorer.exe "/select,`"$outPath`""
    Pause-Console
}

function Export-LogsForDiscord {
    Write-Title "Export Logs ZIP for Discord Ticket (+ PC Specs)"

    $logDir = Get-LogFolder
    $latest = Get-LatestLogFile

    if (-not $latest) {
        Write-Host "[!] No log files found in: $logDir" -ForegroundColor Yellow
        Pause-Console
        return
    }

    $fiveM = Get-FiveMBasePath
    $crashesPath = Join-Path $fiveM "crashes"

    $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $zipPath = Join-Path $env:USERPROFILE "Desktop\FiveM-Logs-$stamp.zip"

    # Temp staging folder
    $tempRoot = Join-Path $env:TEMP "FiveM-Export-$stamp"
    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    try {
        Write-Host "[*] Staging latest tool log..." -ForegroundColor Cyan
        Copy-Item -LiteralPath $latest.FullName -Destination (Join-Path $tempRoot $latest.Name) -Force

        $specPath = Join-Path $tempRoot "PC_Specs.txt"
        New-PCSpecsReport -OutputPath $specPath

        if (Test-Path $crashesPath) {
            Write-Host "[*] Staging FiveM crash files (last 7 days)..." -ForegroundColor Cyan
            $destCrashes = Join-Path $tempRoot "FiveM_Crashes"
            New-Item -ItemType Directory -Path $destCrashes | Out-Null

            $cutoff = (Get-Date).AddDays(-7)
            Get-ChildItem -Path $crashesPath -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $cutoff } |
                ForEach-Object {
                    $rel = $_.FullName.Substring($crashesPath.Length).TrimStart("\")
                    $target = Join-Path $destCrashes $rel
                    $targetDir = Split-Path $target -Parent
                    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
                    Copy-Item -LiteralPath $_.FullName -Destination $target -Force -ErrorAction SilentlyContinue
                }
        } else {
            Write-Host "[!] FiveM crashes folder not found (skipping)." -ForegroundColor Yellow
        }

        if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        Write-Host "[*] Creating ZIP: $zipPath" -ForegroundColor Green
        Compress-Archive -Path (Join-Path $tempRoot "*") -DestinationPath $zipPath -Force

        Write-Host "[+] Export complete!" -ForegroundColor Green
        Write-Host "    Upload this ZIP to your Discord ticket." -ForegroundColor Gray

        Start-Process explorer.exe "/select,`"$zipPath`""
    }
    catch {
        Write-Host "[X] Export failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }

    Pause-Console
}

#endregion Actions

#region Menu

function Show-Menu {
    Write-Title "FiveM Troubleshooting (Menu)"

    if (Test-IsAdmin) {
        Write-Host "Status: Running as Administrator" -ForegroundColor Green
    } else {
        Write-Host "Status: NOT running as Administrator (some fixes may fail)" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "1) Run SFC /scannow" -ForegroundColor Cyan
    Write-Host "2) Run DISM /RestoreHealth" -ForegroundColor Cyan
    Write-Host "3) Run CHKDSK (scan or /r /f)" -ForegroundColor Cyan
    Write-Host "4) Clear FiveM Cache + Crash Logs" -ForegroundColor Cyan
    Write-Host "5) Open FiveM Application Data folder" -ForegroundColor Cyan
    Write-Host "6) Show Quick Checklist" -ForegroundColor Cyan
    Write-Host "7) Export logs ZIP for Discord ticket (+ PC specs inside)" -ForegroundColor Cyan
    Write-Host "8) Export PC specs report (TXT) to Desktop" -ForegroundColor Cyan
    Write-Host "0) Exit" -ForegroundColor Cyan
    Write-Host ""
}

#endregion Menu

#region Main

try {
    Start-Logging

    while ($true) {
        Show-Menu
        $choice = Read-Host "Choose an option (0-8)"

        switch ($choice) {
            "1" { Run-SFC }
            "2" { Run-DISMRestoreHealth }
            "3" { Run-CHKDSK }
            "4" { Clear-FiveMCacheAndCrashes }
            "5" { Open-FiveMFolder }
            "6" { Show-Checklist }
            "7" { Export-LogsForDiscord }
            "8" { Export-PCSpecsToDesktop }
            "0" { break }
            default {
                Write-Host "[!] Invalid selection. Choose 0-8." -ForegroundColor Yellow
                Pause-Console
            }
        }
    }
}
catch {
    Write-Host ""
    Write-Host "[X] Script crashed with an error:" -ForegroundColor Red
    Write-Host "    $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "More details:" -ForegroundColor Yellow
    Write-Host ($_ | Out-String)
    Pause-Console
}
finally {
    try { Stop-Transcript } catch {}
    Wait-BeforeExit
}

#endregion Main
