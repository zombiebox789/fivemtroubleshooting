#Requires -Version 5.1
<#
.SYNOPSIS
    FiveM Troubleshooter v2.2

.DESCRIPTION
    Menu-driven FiveM troubleshooting and diagnostics utility.
    Built as a PowerShell backend that can later be wrapped into a GUI.

.NOTES
    Recommended to run as Administrator.
#>

#region Config
$Script:ToolName       = "FiveM Troubleshooter"
$Script:Version        = "2.2.0"
$Script:CompanyName    = "Insomnia Studios"
$Script:SessionId      = Get-Date -Format "yyyyMMdd_HHmmss"
$Script:StartTime      = Get-Date

$Script:RepoVersionUrl = "https://raw.githubusercontent.com/zombiebox789/fivemtroubleshooting/main/version.txt"
$Script:RepoScriptUrl  = "https://raw.githubusercontent.com/zombiebox789/fivemtroubleshooting/main/FiveM-Troubleshooting.ps1"

$Script:BaseFolder     = Join-Path $env:ProgramData "FiveM-Troubleshooter"
$Script:LogFolder      = Join-Path $Script:BaseFolder "Logs"
$Script:ExportFolder   = Join-Path $Script:BaseFolder "Exports"
$Script:TempFolder     = Join-Path $Script:BaseFolder "Temp"
$Script:LogFile        = Join-Path $Script:LogFolder "FiveM-Troubleshooter_$($Script:SessionId).log"

$Script:History        = New-Object System.Collections.Generic.List[object]
$Script:Results        = New-Object System.Collections.Generic.List[object]
$Script:RestartNeeded  = $false

$Script:Paths = @{
    FiveMRoot            = Join-Path $env:LocalAppData "FiveM"
    FiveMApp             = Join-Path $env:LocalAppData "FiveM\FiveM.app"
    FiveMApplicationData = Join-Path $env:LocalAppData "FiveM\FiveM Application Data"
    FiveMData            = Join-Path $env:LocalAppData "FiveM\FiveM Application Data\data"
    FiveMCrashes         = Join-Path $env:LocalAppData "FiveM\FiveM Application Data\Crashes"
    ServerCachePriv      = Join-Path $env:LocalAppData "FiveM\FiveM Application Data\data\server-cache-priv"
    ServerCache          = Join-Path $env:LocalAppData "FiveM\FiveM Application Data\data\server-cache"
    NuiStorage           = Join-Path $env:LocalAppData "FiveM\FiveM Application Data\data\nui-storage"
    Temp                 = $env:TEMP
    Desktop              = [Environment]::GetFolderPath("Desktop")
}
#endregion Config

#region Bootstrap
function Initialize-Environment {
    foreach ($folder in @($Script:BaseFolder, $Script:LogFolder, $Script:ExportFolder, $Script:TempFolder)) {
        if (-not (Test-Path $folder)) {
            New-Item -Path $folder -ItemType Directory -Force | Out-Null
        }
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("INFO","WARN","ERROR","SUCCESS","ACTION")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        "INFO"    { Write-Host $entry -ForegroundColor Cyan }
        "WARN"    { Write-Host $entry -ForegroundColor Yellow }
        "ERROR"   { Write-Host $entry -ForegroundColor Red }
        "SUCCESS" { Write-Host $entry -ForegroundColor Green }
        "ACTION"  { Write-Host $entry -ForegroundColor Magenta }
    }

    Add-Content -Path $Script:LogFile -Value $entry

    $Script:History.Add([PSCustomObject]@{
        Time    = $timestamp
        Level   = $Level
        Message = $Message
    })
}

function Add-Result {
    param(
        [string]$Step,
        [ValidateSet("SUCCESS","WARN","ERROR","INFO")]
        [string]$Status,
        [string]$Details
    )

    $Script:Results.Add([PSCustomObject]@{
        Time    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Step    = $Step
        Status  = $Status
        Details = $Details
    })
}

function Show-Banner {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host " $($Script:ToolName) v$($Script:Version)" -ForegroundColor White
    Write-Host " $($Script:CompanyName)" -ForegroundColor Gray
    Write-Host " Session: $($Script:SessionId)" -ForegroundColor Gray
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host
}

function Pause-Console {
    Write-Host
    Read-Host "Press Enter to continue"
}

function Read-YesNo {
    param(
        [string]$Prompt = "Continue? (Y/N)",
        [bool]$DefaultYes = $true
    )

    $suffix = if ($DefaultYes) { "[Y/N]" } else { "[N/Y]" }

    while ($true) {
        $inputValue = Read-Host "$Prompt $suffix"

        if ([string]::IsNullOrWhiteSpace($inputValue)) {
            return $DefaultYes
        }

        switch ($inputValue.Trim().ToUpper()) {
            "Y" { return $true }
            "N" { return $false }
            default { Write-Host "Please enter Y or N." -ForegroundColor Yellow }
        }
    }
}
#endregion Bootstrap

#region Elevation
function Test-Admin {
    try {
        $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        Write-Log "Failed to determine admin status: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Start-Elevated {
    if (Test-Admin) {
        Write-Log "Running as Administrator." "SUCCESS"
        return
    }

    Write-Log "Not running as Administrator. Relaunching elevated..." "WARN"

    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$PSCommandPath`""
        exit
    }
    catch {
        Write-Log "Elevation failed or was canceled." "ERROR"
        throw
    }
}
#endregion Elevation

#region Safe Execution
function Invoke-Safely {
    param(
        [Parameter(Mandatory)][string]$ActionName,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    Write-Log "Starting: $ActionName" "ACTION"
    try {
        & $ScriptBlock
        Write-Log "Completed: $ActionName" "SUCCESS"
        Add-Result -Step $ActionName -Status "SUCCESS" -Details "Completed successfully"
        return $true
    }
    catch {
        $msg = $_.Exception.Message
        Write-Log "Failed: $ActionName - $msg" "ERROR"
        Add-Result -Step $ActionName -Status "ERROR" -Details $msg
        return $false
    }
}
#endregion Safe Execution

#region Helpers
function Format-BytesToGB {
    param([double]$Bytes)
    return [math]::Round($Bytes / 1GB, 2)
}

function Get-ActiveAdapters {
    try {
        Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq "Up" -and $_.HardwareInterface -eq $true }
    }
    catch {
        Write-Log "Failed to enumerate network adapters: $($_.Exception.Message)" "ERROR"
        @()
    }
}

function Remove-ChildItemsSafely {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Log "Path not found: $Path" "WARN"
        return
    }

    Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Log "Skipped locked item: $($_.FullName)" "WARN"
        }
    }
}

function Get-CommonGTAPaths {
    @(
        "C:\Program Files\Rockstar Games\Grand Theft Auto V\GTA5.exe",
        "C:\Program Files (x86)\Steam\steamapps\common\Grand Theft Auto V\GTA5.exe",
        "D:\SteamLibrary\steamapps\common\Grand Theft Auto V\GTA5.exe",
        "E:\SteamLibrary\steamapps\common\Grand Theft Auto V\GTA5.exe",
        "F:\SteamLibrary\steamapps\common\Grand Theft Auto V\GTA5.exe"
    )
}

function Get-GTAInstallPath {
    $common = Get-CommonGTAPaths
    foreach ($path in $common) {
        if (Test-Path $path) {
            return $path
        }
    }

    try {
        $uninstallKeys = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )

        $match = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match "Grand Theft Auto V" } |
            Select-Object -First 1

        if ($match -and $match.InstallLocation) {
            $candidate = Join-Path $match.InstallLocation "GTA5.exe"
            if (Test-Path $candidate) {
                return $candidate
            }
        }
    }
    catch {
        Write-Log "GTA detection via registry failed: $($_.Exception.Message)" "WARN"
    }

    return $null
}
#endregion Helpers

#region Detection / Diagnostics
function Test-FiveMInstalled {
    $exists = (Test-Path $Script:Paths.FiveMApp) -or (Test-Path $Script:Paths.FiveMApplicationData)
    if ($exists) {
        Write-Log "FiveM installation detected." "SUCCESS"
    }
    else {
        Write-Log "FiveM installation not detected in LocalAppData." "WARN"
    }
    return $exists
}

function Get-FiveMExecutablePath {
    $exe = Join-Path $Script:Paths.FiveMApp "FiveM.exe"
    if (Test-Path $exe) { return $exe }
    return $null
}

function Get-FiveMVersion {
    $exe = Get-FiveMExecutablePath
    if ($exe -and (Test-Path $exe)) {
        try {
            return (Get-Item $exe).VersionInfo.FileVersion
        }
        catch {
            return $null
        }
    }
    return $null
}

function Get-FreeDiskSpace {
    try {
        $systemDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        [PSCustomObject]@{
            Drive       = $systemDrive.DeviceID
            FreeGB      = Format-BytesToGB $systemDrive.FreeSpace
            TotalGB     = Format-BytesToGB $systemDrive.Size
            PercentFree = [math]::Round(($systemDrive.FreeSpace / $systemDrive.Size) * 100, 2)
        }
    }
    catch {
        Write-Log "Unable to get disk information: $($_.Exception.Message)" "ERROR"
        $null
    }
}

function Test-StorageHealth {
    $disk = Get-FreeDiskSpace
    if (-not $disk) { return }

    Write-Log "System drive $($disk.Drive): $($disk.FreeGB) GB free / $($disk.TotalGB) GB total ($($disk.PercentFree)% free)" "INFO"

    if ($disk.FreeGB -lt 15) {
        Write-Log "Low disk space detected." "WARN"
        Add-Result -Step "Disk Space Check" -Status "WARN" -Details "Low free space on system drive"
    }
    else {
        Write-Log "Disk space looks healthy." "SUCCESS"
        Add-Result -Step "Disk Space Check" -Status "SUCCESS" -Details "Healthy free space"
    }
}

function Test-InternetConnectivity {
    $targets = @("1.1.1.1", "8.8.8.8", "google.com")
    $results = @()

    foreach ($target in $targets) {
        $ok = $false
        try {
            $ok = Test-Connection -ComputerName $target -Count 1 -Quiet -ErrorAction Stop
        }
        catch {
            $ok = $false
        }

        $results += [PSCustomObject]@{
            Target    = $target
            Reachable = $ok
        }

        if ($ok) {
            Write-Log "Connectivity OK: $target" "SUCCESS"
        }
        else {
            Write-Log "Connectivity failed: $target" "WARN"
        }
    }

    return $results
}

function Get-WindowsUpdateStatus {
    try {
        $auKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Install"
        if (Test-Path $auKey) {
            $props = Get-ItemProperty -Path $auKey -ErrorAction Stop
            return [PSCustomObject]@{
                LastSuccessTime = $props.LastSuccessTime
                ResultCode      = $props.ResultCode
            }
        }
    }
    catch {
        Write-Log "Could not read Windows Update status: $($_.Exception.Message)" "WARN"
    }
    return $null
}

function Get-GPUInfo {
    try {
        Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion
    }
    catch {
        Write-Log "Failed to get GPU info: $($_.Exception.Message)" "WARN"
        @()
    }
}

function Test-FiveMCrashPresence {
    if (Test-Path $Script:Paths.FiveMCrashes) {
        try {
            $count = (Get-ChildItem -Path $Script:Paths.FiveMCrashes -Force -ErrorAction SilentlyContinue | Measure-Object).Count
            Write-Log "Crash folder item count: $count" "INFO"
            return $count
        }
        catch {
            Write-Log "Could not inspect crash folder: $($_.Exception.Message)" "WARN"
        }
    }
    return 0
}

function Get-SystemDiagnostics {
    Write-Log "Collecting system diagnostics..." "ACTION"

    $os          = Get-CimInstance Win32_OperatingSystem
    $cpu         = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cs          = Get-CimInstance Win32_ComputerSystem
    $disk        = Get-FreeDiskSpace
    $gpu         = Get-GPUInfo
    $dns         = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $wu          = Get-WindowsUpdateStatus
    $fivemVer    = Get-FiveMVersion
    $gtaPath     = Get-GTAInstallPath
    $fivemExe    = Get-FiveMExecutablePath

    $diag = [PSCustomObject]@{
        ComputerName     = $env:COMPUTERNAME
        UserName         = $env:USERNAME
        OS               = $os.Caption
        OSVersion        = $os.Version
        BuildNumber      = $os.BuildNumber
        LastBoot         = $os.LastBootUpTime
        CPU              = $cpu.Name
        RAM_GB           = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
        GPU              = ($gpu.Name -join "; ")
        GPUDriverVersion = ($gpu.DriverVersion -join "; ")
        SystemDriveFree  = if ($disk) { $disk.FreeGB } else { $null }
        SystemDriveTotal = if ($disk) { $disk.TotalGB } else { $null }
        FiveMInstalled   = Test-FiveMInstalled
        FiveMVersion     = $fivemVer
        FiveMExe         = $fivemExe
        FiveMPath        = $Script:Paths.FiveMApplicationData
        GTAPath          = $gtaPath
        DNS              = ($dns | ForEach-Object { "$($_.InterfaceAlias): $($_.ServerAddresses -join ', ')" }) -join " | "
        WinUpdateLastOK  = if ($wu) { $wu.LastSuccessTime } else { $null }
        WinUpdateCode    = if ($wu) { $wu.ResultCode } else { $null }
        CrashFolderCount = Test-FiveMCrashPresence
    }

    $diag | Format-List | Out-String | ForEach-Object {
        if ($_.Trim()) { Write-Log $_.TrimEnd() "INFO" }
    }

    return $diag
}

function Invoke-DiagnosticsOnly {
    Show-Banner
    Write-Host "Diagnostics Only..." -ForegroundColor Green
    Write-Host

    Invoke-Safely -ActionName "Collect System Diagnostics" -ScriptBlock { Get-SystemDiagnostics | Out-Null } | Out-Null
    Invoke-Safely -ActionName "Check Storage Health" -ScriptBlock { Test-StorageHealth } | Out-Null
    Invoke-Safely -ActionName "Test Connectivity" -ScriptBlock { Test-InternetConnectivity | Out-Null } | Out-Null
    Invoke-Safely -ActionName "Check Crash Folder" -ScriptBlock { Test-FiveMCrashPresence | Out-Null } | Out-Null

    Show-ResultsTable
    Pause-Console
}

function Invoke-SafeModeScan {
    Show-Banner
    Write-Host "Safe Mode / Read-Only Scan..." -ForegroundColor Green
    Write-Host

    Write-Log "Running read-only checks. No changes will be made." "INFO"
    Get-SystemDiagnostics | Out-Null
    Test-StorageHealth
    Test-InternetConnectivity | Out-Null
    Test-FiveMCrashPresence | Out-Null

    Pause-Console
}

function Show-ActionHistory {
    Write-Host
    Write-Host "==================== Action History ====================" -ForegroundColor Cyan
    foreach ($item in $Script:History) {
        Write-Host "[$($item.Time)] [$($item.Level)] $($item.Message)"
    }
}

function Show-ResultsTable {
    Write-Host
    Write-Host "==================== Results Summary ===================" -ForegroundColor Cyan
    if ($Script:Results.Count -eq 0) {
        Write-Host "No actions recorded yet." -ForegroundColor Yellow
        return
    }

    $Script:Results | Format-Table Time, Step, Status, Details -AutoSize
}
#endregion Detection / Diagnostics

#region Process Handling
function Stop-GameProcesses {
    $targets = @(
        "FiveM",
        "FiveM_b2189_GTAProcess",
        "FiveM_b2372_GTAProcess",
        "FiveM_b2545_GTAProcess",
        "FiveM_b2612_GTAProcess",
        "FiveM_b2699_GTAProcess",
        "FiveM_b2802_GTAProcess",
        "FiveM_b2944_GTAProcess",
        "FiveM_b3095_GTAProcess",
        "GTA5",
        "PlayGTAV",
        "GTAVLauncher",
        "RockstarService"
    )

    $stoppedAny = $false

    foreach ($name in $targets) {
        $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
        foreach ($proc in $procs) {
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                Write-Log "Stopped process: $($proc.ProcessName) (PID $($proc.Id))" "SUCCESS"
                $stoppedAny = $true
            }
            catch {
                Write-Log "Failed to stop process $($proc.ProcessName): $($_.Exception.Message)" "WARN"
            }
        }
    }

    if (-not $stoppedAny) {
        Write-Log "No FiveM/GTA-related running processes found." "INFO"
    }
}
#endregion Process Handling

#region Repair Actions
function Clear-FiveMCache {
    Write-Log "Clearing FiveM cache folders..." "ACTION"

    $cacheTargets = @(
        $Script:Paths.ServerCachePriv,
        $Script:Paths.ServerCache
    )

    foreach ($target in $cacheTargets) {
        if (Test-Path $target) {
            Remove-ChildItemsSafely -Path $target
            Write-Log "Cleared cache folder: $target" "SUCCESS"
        }
        else {
            Write-Log "Cache folder not found: $target" "WARN"
        }
    }

    Write-Log "FiveM cache cleanup complete." "SUCCESS"
}

function Clear-FiveMCrashLogs {
    Write-Log "Clearing FiveM crash logs..." "ACTION"

    if (Test-Path $Script:Paths.FiveMCrashes) {
        Remove-ChildItemsSafely -Path $Script:Paths.FiveMCrashes
        Write-Log "Crash log cleanup complete." "SUCCESS"
    }
    else {
        Write-Log "Crash folder not found: $($Script:Paths.FiveMCrashes)" "WARN"
    }
}

function Clear-TempFiles {
    Write-Log "Clearing temp files..." "ACTION"

    if (Test-Path $Script:Paths.Temp) {
        Remove-ChildItemsSafely -Path $Script:Paths.Temp
        Write-Log "Temp cleanup complete." "SUCCESS"
    }
    else {
        Write-Log "Temp folder not found: $($Script:Paths.Temp)" "WARN"
    }
}

function Reset-NetworkStack {
    Write-Log "Flushing DNS..." "ACTION"
    ipconfig /flushdns | Out-Null

    Write-Log "Resetting Winsock..." "ACTION"
    netsh winsock reset | Out-Null

    Write-Log "Resetting IP stack..." "ACTION"
    netsh int ip reset | Out-Null

    $Script:RestartNeeded = $true
    Write-Log "Network reset complete. Restart is recommended." "SUCCESS"
}

function Set-CloudflareDNS {
    $adapters = Get-ActiveAdapters
    if (-not $adapters -or $adapters.Count -eq 0) {
        throw "No active network adapters found."
    }

    foreach ($adapter in $adapters) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.IfIndex -ServerAddresses @("1.1.1.1","1.0.0.1") -ErrorAction Stop
            Write-Log "Cloudflare DNS applied to adapter: $($adapter.Name)" "SUCCESS"
        }
        catch {
            Write-Log "Failed to set Cloudflare DNS on $($adapter.Name): $($_.Exception.Message)" "ERROR"
        }
    }
}

function Open-FiveMFiles {
    $folders = @(
        $Script:Paths.FiveMApplicationData,
        $Script:Paths.FiveMCrashes,
        $Script:Paths.ServerCachePriv
    )

    foreach ($folder in $folders) {
        if (Test-Path $folder) {
            Start-Process explorer.exe $folder
            Write-Log "Opened: $folder" "SUCCESS"
        }
        else {
            Write-Log "Folder not found: $folder" "WARN"
        }
    }
}
#endregion Repair Actions

#region Restart
function Invoke-RestartPrompt {
    if (-not $Script:RestartNeeded) {
        return
    }

    Write-Host
    Write-Host "A restart is recommended to fully apply network reset changes." -ForegroundColor Yellow

    $restart = Read-YesNo -Prompt "Restart computer now?" -DefaultYes:$false
    if ($restart) {
        Write-Log "User chose to restart system." "WARN"
        Restart-Computer -Force
    }
    else {
        Write-Log "User chose not to restart right now." "INFO"
    }
}
#endregion Restart

#region Self Update
function Test-ForUpdates {
    Write-Log "Checking for script updates..." "ACTION"
    try {
        $latest = (Invoke-WebRequest -Uri $Script:RepoVersionUrl -UseBasicParsing -ErrorAction Stop).Content.Trim()
        Write-Log "Current version: $($Script:Version) | Latest version: $latest" "INFO"

        if ($latest -and $latest -ne $Script:Version) {
            Write-Log "Update available." "WARN"
            return $latest
        }

        Write-Log "You are on the latest version." "SUCCESS"
        return $null
    }
    catch {
        Write-Log "Update check failed: $($_.Exception.Message)" "WARN"
        return $null
    }
}

function Update-ScriptFromGitHub {
    $latest = Test-ForUpdates
    if (-not $latest) { return }

    try {
        $tempScript = Join-Path $Script:TempFolder "FiveM-Troubleshooting_v$latest.ps1"
        Invoke-WebRequest -Uri $Script:RepoScriptUrl -OutFile $tempScript -UseBasicParsing -ErrorAction Stop
        Write-Log "Downloaded latest script to: $tempScript" "SUCCESS"
        Write-Log "You can replace the current local script with this downloaded copy." "INFO"
    }
    catch {
        Write-Log "Failed to download latest script: $($_.Exception.Message)" "ERROR"
    }
}
#endregion Self Update

#region Export
function New-SupportSummaryText {
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [psobject]$Diagnostics
    )

    $lines = @()
    $lines += "FiveM Troubleshooter Support Summary"
    $lines += "Version: $($Script:Version)"
    $lines += "Session ID: $($Script:SessionId)"
    $lines += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += ""
    $lines += "System"
    $lines += "------"
    $lines += "Computer Name: $($Diagnostics.ComputerName)"
    $lines += "User Name: $($Diagnostics.UserName)"
    $lines += "OS: $($Diagnostics.OS)"
    $lines += "OS Version: $($Diagnostics.OSVersion)"
    $lines += "CPU: $($Diagnostics.CPU)"
    $lines += "RAM (GB): $($Diagnostics.RAM_GB)"
    $lines += "GPU: $($Diagnostics.GPU)"
    $lines += ""
    $lines += "Game Detection"
    $lines += "-------------"
    $lines += "FiveM Installed: $($Diagnostics.FiveMInstalled)"
    $lines += "FiveM Version: $($Diagnostics.FiveMVersion)"
    $lines += "FiveM EXE: $($Diagnostics.FiveMExe)"
    $lines += "FiveM Path: $($Diagnostics.FiveMPath)"
    $lines += "GTA Path: $($Diagnostics.GTAPath)"
    $lines += "Crash Folder Count: $($Diagnostics.CrashFolderCount)"
    $lines += ""
    $lines += "Storage / Network"
    $lines += "-----------------"
    $lines += "System Drive Free (GB): $($Diagnostics.SystemDriveFree)"
    $lines += "System Drive Total (GB): $($Diagnostics.SystemDriveTotal)"
    $lines += "DNS: $($Diagnostics.DNS)"
    $lines += "Restart Recommended: $($Script:RestartNeeded)"
    $lines += ""
    $lines += "Windows Update"
    $lines += "--------------"
    $lines += "Last Success Time: $($Diagnostics.WinUpdateLastOK)"
    $lines += "Result Code: $($Diagnostics.WinUpdateCode)"
    $lines += ""
    $lines += "Action Results"
    $lines += "--------------"

    if ($Script:Results.Count -eq 0) {
        $lines += "No actions were recorded."
    }
    else {
        foreach ($result in $Script:Results) {
            $lines += "$($result.Time) | $($result.Step) | $($result.Status) | $($result.Details)"
        }
    }

    Set-Content -Path $OutputPath -Value $lines -Encoding UTF8
}

function Export-DiagnosticsBundle {
    Write-Log "Creating support package..." "ACTION"

    $bundleRoot = Join-Path $Script:ExportFolder "FiveM_Support_$($Script:SessionId)"
    New-Item -Path $bundleRoot -ItemType Directory -Force | Out-Null

    $diag = Get-SystemDiagnostics
    $diag | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bundleRoot "system_diagnostics.json")
    $Script:History | Export-Csv -NoTypeInformation -Path (Join-Path $bundleRoot "action_history.csv")
    $Script:Results | Export-Csv -NoTypeInformation -Path (Join-Path $bundleRoot "results_summary.csv")
    Copy-Item -Path $Script:LogFile -Destination (Join-Path $bundleRoot "session.log") -Force

    New-SupportSummaryText -OutputPath (Join-Path $bundleRoot "support-summary.txt") -Diagnostics $diag

    try {
        ipconfig /all > (Join-Path $bundleRoot "ipconfig.txt")
        systeminfo > (Join-Path $bundleRoot "systeminfo.txt")
        Get-Process | Sort-Object ProcessName | Select-Object ProcessName, Id, CPU | Out-File (Join-Path $bundleRoot "processes.txt")
    }
    catch {
        Write-Log "One or more extra exports failed: $($_.Exception.Message)" "WARN"
    }

    Write-Log "Support package created: $bundleRoot" "SUCCESS"
    Start-Process explorer.exe $bundleRoot
}
#endregion Export

#region Menu
function Show-MainMenu {
    do {
        Show-Banner

        Write-Host "--- Fixes ---" -ForegroundColor Cyan
        Write-Host "1. Close FiveM / GTA"
        Write-Host "2. Clear FiveM Cache"
        Write-Host "3. Clear Crash Logs"
        Write-Host "4. Reset Internet Settings"
        Write-Host "5. Set DNS to Cloudflare"
        Write-Host "6. Clear Temp Files"
        Write-Host "7. Open FiveM Files"
        Write-Host

        Write-Host "--- Information / Support ---" -ForegroundColor Cyan
        Write-Host "8. Run Diagnostics"
        Write-Host "9. Export Support Package"
        Write-Host "10. View Results Summary"
        Write-Host "11. View Action History"
        Write-Host

        Write-Host "--- Updates ---" -ForegroundColor Cyan
        Write-Host "12. Check for Updates"
        Write-Host "13. Download Latest Version"
        Write-Host

        Write-Host "0. Exit"
        Write-Host

        $choice = Read-Host "Select an option"

        switch ($choice) {
            "1"  { Invoke-Safely -ActionName "Close FiveM / GTA" -ScriptBlock { Stop-GameProcesses } | Out-Null; Pause-Console }
            "2"  { Invoke-Safely -ActionName "Clear FiveM Cache" -ScriptBlock { Clear-FiveMCache } | Out-Null; Pause-Console }
            "3"  { Invoke-Safely -ActionName "Clear Crash Logs" -ScriptBlock { Clear-FiveMCrashLogs } | Out-Null; Pause-Console }
            "4"  { Invoke-Safely -ActionName "Reset Internet Settings" -ScriptBlock { Reset-NetworkStack } | Out-Null; Invoke-RestartPrompt; Pause-Console }
            "5"  { Invoke-Safely -ActionName "Set DNS to Cloudflare" -ScriptBlock { Set-CloudflareDNS } | Out-Null; Pause-Console }
            "6"  { Invoke-Safely -ActionName "Clear Temp Files" -ScriptBlock { Clear-TempFiles } | Out-Null; Pause-Console }
            "7"  { Invoke-Safely -ActionName "Open FiveM Files" -ScriptBlock { Open-FiveMFiles } | Out-Null; Pause-Console }
            "8"  { Invoke-DiagnosticsOnly }
            "9"  { Invoke-Safely -ActionName "Export Support Package" -ScriptBlock { Export-DiagnosticsBundle } | Out-Null; Pause-Console }
            "10" { Show-ResultsTable; Pause-Console }
            "11" { Show-ActionHistory; Pause-Console }
            "12" { Test-ForUpdates | Out-Null; Pause-Console }
            "13" { Update-ScriptFromGitHub; Pause-Console }
            "0"  {
                Write-Log "Exiting tool." "INFO"
                break
            }
            default {
                Write-Log "Invalid selection." "WARN"
                Start-Sleep -Seconds 1
            }
        }
    } while ($true)
}
#endregion Menu

#region Main
try {
    Initialize-Environment
    Write-Log "Starting $($Script:ToolName) v$($Script:Version)" "INFO"
    Start-Elevated
    Show-MainMenu
}
catch {
    Write-Log "Fatal error: $($_.Exception.Message)" "ERROR"
    Pause-Console
}
finally {
    Write-Log "Session ended." "INFO"
}
#endregion Main
