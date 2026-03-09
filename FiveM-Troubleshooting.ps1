#Requires -Version 5.1
<#
.SYNOPSIS
    FiveM Troubleshooter v2.5

.DESCRIPTION
    Menu-driven FiveM troubleshooting and diagnostics utility.
    Designed to keep a lighter system footprint.

.NOTES
    Recommended to run as Administrator.
#>

#region Config
$Script:ToolName       = "FiveM Troubleshooter"
$Script:Version        = "2.5.0"
$Script:CompanyName    = "Insomnia Studios"
$Script:SessionId      = Get-Date -Format "yyyyMMdd_HHmmss"
$Script:StartTime      = Get-Date

$Script:RepoVersionUrl = "https://raw.githubusercontent.com/zombiebox789/fivemtroubleshooting/main/version.txt"
$Script:RepoScriptUrl  = "https://raw.githubusercontent.com/zombiebox789/fivemtroubleshooting/main/FiveM-Troubleshooting.ps1"

$Script:BaseFolder     = Join-Path $env:TEMP "FiveM-Troubleshooter"
$Script:LogFolder      = $Script:BaseFolder
$Script:TempFolder     = $Script:BaseFolder
$Script:ExportFolder   = [Environment]::GetFolderPath("Desktop")
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
    if (-not (Test-Path $Script:BaseFolder)) {
        New-Item -Path $Script:BaseFolder -ItemType Directory -Force | Out-Null
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

    $logDir = Split-Path -Path $Script:LogFile -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
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
        "C:\Program Files (x86)\Rockstar Games\Grand Theft Auto V\GTA5.exe",
        "C:\Rockstar Games\Grand Theft Auto V\GTA5.exe",
        "C:\Program Files (x86)\Steam\steamapps\common\Grand Theft Auto V\GTA5.exe",
        "C:\Steam\steamapps\common\Grand Theft Auto V\GTA5.exe",
        "C:\Program Files\Epic Games\GTAV\GTA5.exe",
        "D:\SteamLibrary\steamapps\common\Grand Theft Auto V\GTA5.exe",
        "E:\SteamLibrary\steamapps\common\Grand Theft Auto V\GTA5.exe",
        "F:\SteamLibrary\steamapps\common\Grand Theft Auto V\GTA5.exe"
    )
}

function Get-SteamLibraryRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    $defaultRoots = @(
        "C:\Program Files (x86)\Steam",
        "C:\Steam"
    )

    $registrySources = @(
        @{ Path = "HKCU:\Software\Valve\Steam";                    Name = "SteamPath"   },
        @{ Path = "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam";        Name = "InstallPath" },
        @{ Path = "HKLM:\SOFTWARE\Valve\Steam";                    Name = "InstallPath" }
    )

    foreach ($entry in $registrySources) {
        try {
            $value = (Get-ItemProperty -Path $entry.Path -Name $entry.Name -ErrorAction Stop).$($entry.Name)
            if ($value -and (Test-Path $value)) {
                $roots.Add($value)
            }
        }
        catch {
            # Steam may not be installed from this source.
        }
    }

    foreach ($root in $defaultRoots) {
        if (Test-Path $root) {
            $roots.Add($root)
        }
    }

    $libraryRoots = New-Object System.Collections.Generic.List[string]

    foreach ($root in ($roots | Sort-Object -Unique)) {
        $libraryRoots.Add($root)

        $vdfPath = Join-Path $root "steamapps\libraryfolders.vdf"
        if (-not (Test-Path $vdfPath)) {
            continue
        }

        try {
            $vdf = Get-Content -Path $vdfPath -Raw -ErrorAction Stop
            $matches = [regex]::Matches($vdf, '"path"\s+"([^"]+)"')
            foreach ($match in $matches) {
                $libraryPath = $match.Groups[1].Value -replace '\\\\', '\'
                if ($libraryPath -and (Test-Path $libraryPath)) {
                    $libraryRoots.Add($libraryPath)
                }
            }
        }
        catch {
            Write-Log "Unable to parse Steam library folders: $($_.Exception.Message)" "WARN"
        }
    }

    return $libraryRoots | Sort-Object -Unique
}

function Get-GTAPathFromSteam {
    foreach ($libraryRoot in Get-SteamLibraryRoots) {
        $candidate = Join-Path $libraryRoot "steamapps\common\Grand Theft Auto V\GTA5.exe"
        if (Test-Path $candidate) {
            return $candidate
        }
    }
    return $null
}

function Get-GTAPathFromEpic {
    $manifestRoot = Join-Path $env:ProgramData "Epic\EpicGamesLauncher\Data\Manifests"
    if (-not (Test-Path $manifestRoot)) {
        return $null
    }

    try {
        $items = Get-ChildItem -Path $manifestRoot -Filter "*.item" -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            try {
                $manifest = Get-Content -Path $item.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $label = "$($manifest.DisplayName) $($manifest.AppName)"

                if ($label -notmatch "Grand Theft Auto V|GTA V|GTAV") {
                    continue
                }

                if ($manifest.InstallLocation) {
                    $candidate = Join-Path $manifest.InstallLocation "GTA5.exe"
                    if (Test-Path $candidate) {
                        return $candidate
                    }
                }
            }
            catch {
                Write-Log "Skipping unreadable Epic manifest: $($item.Name)" "WARN"
            }
        }
    }
    catch {
        Write-Log "Epic manifest scan failed: $($_.Exception.Message)" "WARN"
    }

    return $null
}

function Get-GTAPathFromRockstar {
    $launcherDat = Join-Path $env:ProgramData "Rockstar Games\Launcher\LauncherInstalled.dat"
    if (Test-Path $launcherDat) {
        try {
            $data = Get-Content -Path $launcherDat -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($game in @($data.games)) {
                $gameLabel = "$($game.title) $($game.name)"
                if ($gameLabel -notmatch "Grand Theft Auto V|GTA V|GTAV") {
                    continue
                }

                $installFolder = $game.installFolder
                if (-not $installFolder) {
                    $installFolder = $game.installPath
                }

                if ($installFolder) {
                    $candidate = Join-Path $installFolder "GTA5.exe"
                    if (Test-Path $candidate) {
                        return $candidate
                    }
                }
            }
        }
        catch {
            Write-Log "Rockstar launcher data scan failed: $($_.Exception.Message)" "WARN"
        }
    }

    try {
        $rockstarKey = "HKLM:\SOFTWARE\WOW6432Node\Rockstar Games\Grand Theft Auto V"
        if (Test-Path $rockstarKey) {
            $installFolder = (Get-ItemProperty -Path $rockstarKey -ErrorAction Stop).InstallFolder
            if ($installFolder) {
                $candidate = Join-Path $installFolder "GTA5.exe"
                if (Test-Path $candidate) {
                    return $candidate
                }
            }
        }
    }
    catch {
        Write-Log "Rockstar registry scan failed: $($_.Exception.Message)" "WARN"
    }

    return $null
}

function Get-GTAInstallPath {
    foreach ($path in Get-CommonGTAPaths) {
        if (Test-Path $path) {
            return $path
        }
    }

    $steamPath = Get-GTAPathFromSteam
    if ($steamPath) { return $steamPath }

    $epicPath = Get-GTAPathFromEpic
    if ($epicPath) { return $epicPath }

    $rockstarPath = Get-GTAPathFromRockstar
    if ($rockstarPath) { return $rockstarPath }

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

function Resolve-FiveMInstallInfo {
    $candidates = New-Object System.Collections.Generic.List[object]

    $candidates.Add([PSCustomObject]@{
        Source      = "LocalAppData default"
        ExePath     = Join-Path $Script:Paths.FiveMApp "FiveM.exe"
        AppDataPath = $Script:Paths.FiveMApplicationData
    })

    $candidates.Add([PSCustomObject]@{
        Source      = "LocalAppData root fallback"
        ExePath     = Join-Path $Script:Paths.FiveMRoot "FiveM.exe"
        AppDataPath = $Script:Paths.FiveMApplicationData
    })

    $programFilesCandidates = @(
        "$env:ProgramFiles\FiveM\FiveM.exe",
        "${env:ProgramFiles(x86)}\FiveM\FiveM.exe"
    )

    foreach ($exe in $programFilesCandidates) {
        if (-not [string]::IsNullOrWhiteSpace($exe)) {
            $appDataCandidate = Join-Path (Split-Path $exe -Parent) "FiveM Application Data"
            $candidates.Add([PSCustomObject]@{
                Source      = "Program Files fallback"
                ExePath     = $exe
                AppDataPath = $appDataCandidate
            })
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate.ExePath) {
            return [PSCustomObject]@{
                Installed       = $true
                Source          = $candidate.Source
                ExePath         = $candidate.ExePath
                AppDataPath     = $candidate.AppDataPath
                InstallRootPath = Split-Path $candidate.ExePath -Parent
            }
        }
    }

    try {
        $uninstallKeys = @(
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )

        $entry = Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName -and $_.DisplayName -match "FiveM|CitizenFX"
            } |
            Select-Object -First 1

        if ($entry) {
            $possibleExe = @()
            if ($entry.DisplayIcon) {
                $iconPath = $entry.DisplayIcon -replace '",\d+$', '' -replace '^"', ''
                if ($iconPath) { $possibleExe += $iconPath }
            }

            if ($entry.InstallLocation) {
                $possibleExe += (Join-Path $entry.InstallLocation "FiveM.exe")
                $possibleExe += (Join-Path $entry.InstallLocation "FiveM.app\FiveM.exe")
            }

            foreach ($exe in ($possibleExe | Where-Object { $_ } | Select-Object -Unique)) {
                if (Test-Path $exe) {
                    $appDataPath = Join-Path (Split-Path $exe -Parent) "FiveM Application Data"
                    return [PSCustomObject]@{
                        Installed       = $true
                        Source          = "Uninstall registry"
                        ExePath         = $exe
                        AppDataPath     = $appDataPath
                        InstallRootPath = Split-Path $exe -Parent
                    }
                }
            }
        }
    }
    catch {
        Write-Log "FiveM detection via uninstall registry failed: $($_.Exception.Message)" "WARN"
    }

    try {
        $proc = Get-Process -Name "FiveM" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) {
            $exe = $proc.Path
            if (-not $exe) {
                $exe = $proc.MainModule.FileName
            }

            if ($exe -and (Test-Path $exe)) {
                $appDataPath = Join-Path (Split-Path $exe -Parent) "FiveM Application Data"
                return [PSCustomObject]@{
                    Installed       = $true
                    Source          = "Running process"
                    ExePath         = $exe
                    AppDataPath     = $appDataPath
                    InstallRootPath = Split-Path $exe -Parent
                }
            }
        }
    }
    catch {
        Write-Log "FiveM process-based detection failed: $($_.Exception.Message)" "WARN"
    }

    return [PSCustomObject]@{
        Installed       = $false
        Source          = "Not found"
        ExePath         = $null
        AppDataPath     = $null
        InstallRootPath = $null
    }
}
#endregion Helpers

#region Detection / Diagnostics
function Test-FiveMInstalled {
    $info = Resolve-FiveMInstallInfo
    if ($info.Installed) {
        Write-Log "FiveM installation detected via source: $($info.Source)" "SUCCESS"
    }
    else {
        Write-Log "FiveM installation not detected." "WARN"
    }
    return [bool]$info.Installed
}

function Get-FiveMExecutablePath {
    $info = Resolve-FiveMInstallInfo
    return $info.ExePath
}

function Get-FiveMInstallSource {
    $info = Resolve-FiveMInstallInfo
    return $info.Source
}

function Get-FiveMAppDataPath {
    $info = Resolve-FiveMInstallInfo
    if ($info.AppDataPath -and (Test-Path $info.AppDataPath)) {
        return $info.AppDataPath
    }

    if (Test-Path $Script:Paths.FiveMApplicationData) {
        return $Script:Paths.FiveMApplicationData
    }

    return $null
}

function Get-FiveMEffectivePaths {
    $appDataPath = Get-FiveMAppDataPath
    if (-not $appDataPath) {
        $appDataPath = $Script:Paths.FiveMApplicationData
    }

    $dataPath = Join-Path $appDataPath "data"

    return @{
        FiveMApplicationData = $appDataPath
        FiveMData            = $dataPath
        FiveMCrashes         = Join-Path $appDataPath "Crashes"
        ServerCachePriv      = Join-Path $dataPath "server-cache-priv"
        ServerCache          = Join-Path $dataPath "server-cache"
        NuiStorage           = Join-Path $dataPath "nui-storage"
    }
}

function Get-FiveMVersion {
    param(
        [string]$ExePath
    )

    $exe = $ExePath
    if (-not $exe) {
        $exe = Get-FiveMExecutablePath
    }

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
    }

    $passed = ($results | Where-Object { $_.Reachable }).Count
    Write-Log "Connectivity test complete. Passed $passed of $($results.Count) targets." "INFO"
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
    $paths = Get-FiveMEffectivePaths
    if (Test-Path $paths.FiveMCrashes) {
        try {
            $count = (Get-ChildItem -Path $paths.FiveMCrashes -Force -ErrorAction SilentlyContinue | Measure-Object).Count
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
    $fivemInfo   = Resolve-FiveMInstallInfo
    $gtaPath     = Get-GTAInstallPath
    $fivemExe    = $fivemInfo.ExePath
    $fivemVer    = Get-FiveMVersion -ExePath $fivemExe
    $fivemSource = $fivemInfo.Source
    $fivemData   = Get-FiveMAppDataPath
    $crashCount  = Test-FiveMCrashPresence
    $fivemFound  = [bool]$fivemInfo.Installed

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
        FiveMInstalled   = $fivemFound
        FiveMSource      = $fivemSource
        FiveMVersion     = $fivemVer
        FiveMExe         = $fivemExe
        FiveMPath        = $fivemData
        GTAPath          = $gtaPath
        DNS              = ($dns | ForEach-Object { "$($_.InterfaceAlias): $($_.ServerAddresses -join ', ')" }) -join " | "
        WinUpdateLastOK  = if ($wu) { $wu.LastSuccessTime } else { $null }
        WinUpdateCode    = if ($wu) { $wu.ResultCode } else { $null }
        CrashFolderCount = $crashCount
    }

    Write-Log "Diagnostics collected. FiveM installed: $fivemFound ($fivemSource) | GTA found: $([bool]$gtaPath) | Crash items: $crashCount" "INFO"

    if ($disk) {
        Write-Log "Disk free space: $($disk.FreeGB) GB on $($disk.Drive)" "INFO"
    }

    return $diag
}

function Show-ActionHistory {
    Write-Host
    Write-Host "==================== Action History ====================" -ForegroundColor Cyan
    foreach ($item in $Script:History) {
        Write-Host "[$($item.Time)] [$($item.Level)] $($item.Message)"
    }
}
#endregion Detection / Diagnostics

#region Process Handling
function Stop-GameProcesses {
    $targets = @(
        "FiveM",
        "GTA5",
        "PlayGTAV",
        "GTAVLauncher"
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
    $paths = Get-FiveMEffectivePaths

    $cacheTargets = @(
        $paths.ServerCachePriv,
        $paths.ServerCache
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
    $paths = Get-FiveMEffectivePaths

    if (Test-Path $paths.FiveMCrashes) {
        Remove-ChildItemsSafely -Path $paths.FiveMCrashes
        Write-Log "Crash log cleanup complete." "SUCCESS"
    }
    else {
        Write-Log "Crash folder not found: $($paths.FiveMCrashes)" "WARN"
    }
}

function Clear-FiveMLocalFiles {
    Write-Log "Clearing additional FiveM local files..." "ACTION"
    $paths = Get-FiveMEffectivePaths

    $targets = @(
        $paths.NuiStorage
    )

    $clearedAny = $false

    foreach ($target in $targets) {
        if (Test-Path $target) {
            Remove-ChildItemsSafely -Path $target
            Write-Log "Cleared FiveM local folder: $target" "SUCCESS"
            $clearedAny = $true
        }
        else {
            Write-Log "FiveM local folder not found: $target" "WARN"
        }
    }

    if (-not $clearedAny) {
        Write-Log "No additional FiveM local files were found to clear." "INFO"
    }
    else {
        Write-Log "Additional FiveM local file cleanup complete." "SUCCESS"
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
    $paths = Get-FiveMEffectivePaths
    $folders = @(
        $paths.FiveMApplicationData,
        $paths.FiveMCrashes,
        $paths.ServerCachePriv
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
        if (-not (Test-Path $Script:TempFolder)) {
            New-Item -Path $Script:TempFolder -ItemType Directory -Force | Out-Null
        }

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
    $lines += "FiveM Detection Source: $($Diagnostics.FiveMSource)"
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

    $bundleRoot = Join-Path $Script:TempFolder "FiveM_Support_$($Script:SessionId)"
    $zipPath    = Join-Path $Script:ExportFolder "FiveM_Support_$($Script:SessionId).zip"

    if (Test-Path $bundleRoot) {
        Remove-Item -Path $bundleRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $zipPath) {
        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
    }

    New-Item -Path $bundleRoot -ItemType Directory -Force | Out-Null

    $diag = Get-SystemDiagnostics
    $diag | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bundleRoot "system_diagnostics.json")
    $Script:History | Export-Csv -NoTypeInformation -Path (Join-Path $bundleRoot "action_history.csv")
    $Script:Results | Export-Csv -NoTypeInformation -Path (Join-Path $bundleRoot "results_summary.csv")
    Copy-Item -Path $Script:LogFile -Destination (Join-Path $bundleRoot "session.log") -Force -ErrorAction SilentlyContinue

    New-SupportSummaryText -OutputPath (Join-Path $bundleRoot "support-summary.txt") -Diagnostics $diag

    try {
        ipconfig /all > (Join-Path $bundleRoot "ipconfig.txt")
        systeminfo > (Join-Path $bundleRoot "systeminfo.txt")
        Get-Process | Sort-Object ProcessName | Select-Object ProcessName, Id, CPU |
            Out-File (Join-Path $bundleRoot "processes.txt")
    }
    catch {
        Write-Log "One or more extra exports failed: $($_.Exception.Message)" "WARN"
    }

    try {
        Compress-Archive -Path (Join-Path $bundleRoot '*') -DestinationPath $zipPath -Force
        Write-Log "Support package ZIP created: $zipPath" "SUCCESS"
    }
    catch {
        Write-Log "Failed to create ZIP package: $($_.Exception.Message)" "ERROR"
        throw
    }
    finally {
        Remove-Item -Path $bundleRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
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
        Write-Host "6. Clear FiveM Local Files"
        Write-Host "7. Open FiveM Files"
        Write-Host

        Write-Host "--- Information / Support ---" -ForegroundColor Cyan
        Write-Host "8. Export Support Package"
        Write-Host "9. View Action History"
        Write-Host

        Write-Host "--- Updates ---" -ForegroundColor Cyan
        Write-Host "10. Check for Updates"
        Write-Host "11. Download Latest Version"
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
            "6"  { Invoke-Safely -ActionName "Clear FiveM Local Files" -ScriptBlock { Clear-FiveMLocalFiles } | Out-Null; Pause-Console }
            "7"  { Invoke-Safely -ActionName "Open FiveM Files" -ScriptBlock { Open-FiveMFiles } | Out-Null; Pause-Console }
            "8"  { Invoke-Safely -ActionName "Export Support Package" -ScriptBlock { Export-DiagnosticsBundle } | Out-Null; Pause-Console }
            "9"  { Show-ActionHistory; Pause-Console }
            "10" { Test-ForUpdates | Out-Null; Pause-Console }
            "11" { Update-ScriptFromGitHub; Pause-Console }
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
