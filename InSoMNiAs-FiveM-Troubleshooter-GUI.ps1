#Requires -Version 5.1
<#
.SYNOPSIS
    FiveM Troubleshooter v3.0.3

.DESCRIPTION
    Menu-driven FiveM troubleshooting and diagnostics utility.
    Designed to keep a lighter system footprint.

.NOTES
    Run at your own risk. Always back up important data before making changes to your system.
#>

#region Config
$Script:ToolName       = "FiveM Troubleshooter"
$Script:Version        = "3.0.3"
$Script:CompanyName    = "Insomnia's Tech Tools"
$Script:SessionId      = Get-Date -Format "yyyyMMdd_HHmmss"
$Script:StartTime      = Get-Date

$Script:BaseFolder     = Join-Path $env:TEMP "FiveM-Troubleshooter"
$Script:LogFolder      = $Script:BaseFolder
$Script:TempFolder     = $Script:BaseFolder
$Script:ExportFolder   = [Environment]::GetFolderPath("Desktop")
$Script:LogFile        = Join-Path $Script:LogFolder "FiveM-Troubleshooter_$($Script:SessionId).log"

$Script:History        = New-Object System.Collections.Generic.List[object]
$Script:Results        = New-Object System.Collections.Generic.List[object]
$Script:RestartNeeded  = $false
$Script:LastActionResult = $null
$Script:ExitRequested  = $false

$Script:Paths = @{
    FiveMRoot            = Join-Path $env:LocalAppData "FiveM"
    FiveMApp             = Join-Path $env:LocalAppData "FiveM\FiveM.app"
    FiveMApplicationData = Join-Path $env:LocalAppData "FiveM\FiveM.app"
    FiveMData            = Join-Path $env:LocalAppData "FiveM\FiveM.app\data"
    FiveMCrashes         = Join-Path $env:LocalAppData "FiveM\FiveM.app\crashes"
    ServerCachePriv      = Join-Path $env:LocalAppData "FiveM\FiveM.app\data\server-cache-priv"
    ServerCache          = Join-Path $env:LocalAppData "FiveM\FiveM.app\data\server-cache"
    NuiStorage           = Join-Path $env:LocalAppData "FiveM\FiveM.app\data\nui-storage"
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

    $result = [PSCustomObject]@{
        Time    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Step    = $Step
        Status  = $Status
        Details = $Details
    }

    $Script:Results.Add($result)
    $Script:LastActionResult = $result
}

function Get-StatusColor {
    param([string]$Status)

    switch ($Status) {
        "SUCCESS" { return "Green" }
        "WARN"    { return "Yellow" }
        "ERROR"   { return "Red" }
        default   { return "Cyan" }
    }
}

function Write-SectionTitle {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ("[{0}]" -f $Title) -ForegroundColor Cyan
}

function Show-Banner {
    Clear-Host
    $line = "============================================================"
    $adminState = if (Test-Admin) { "Admin" } else { "Standard" }
    $fivemInfo = Resolve-FiveMInstallInfo
    $fivemState = if ($fivemInfo.Installed) { "Found ($($fivemInfo.Source))" } else { "Not Found" }
    $restartState = if ($Script:RestartNeeded) { "Restart Pending" } else { "No Restart Pending" }

    Write-Host $line -ForegroundColor DarkCyan
    Write-Host " $($Script:ToolName) v$($Script:Version)" -ForegroundColor White
    Write-Host " $($Script:CompanyName)" -ForegroundColor Gray
    Write-Host " Session: $($Script:SessionId)" -ForegroundColor Gray
    Write-Host " Status: $adminState | FiveM: $fivemState" -ForegroundColor Gray
    Write-Host " System: $restartState | Time: $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Gray
    Write-Host $line -ForegroundColor DarkCyan

    if ($Script:LastActionResult) {
        $statusColor = Get-StatusColor -Status $Script:LastActionResult.Status
        Write-Host " Last Action: $($Script:LastActionResult.Step)" -ForegroundColor White
        Write-Host " Result: $($Script:LastActionResult.Status) - $($Script:LastActionResult.Details)" -ForegroundColor $statusColor
        Write-Host $line -ForegroundColor DarkGray
    }

    Write-Host
}

function Wait-ForInput {
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

function Remove-SessionArtifacts {
    if (-not (Test-Path $Script:BaseFolder)) {
        return
    }

    try {
        Remove-Item -Path $Script:BaseFolder -Recurse -Force -ErrorAction Stop
    }
    catch {
        Write-Host "Cleanup skipped for temporary folder: $($_.Exception.Message)" -ForegroundColor Yellow
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
            $pathMatches = [regex]::Matches($vdf, '"path"\s+"([^"]+)"')
            foreach ($match in $pathMatches) {
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

function Get-LatestFileFromPaths {
    param(
        [Parameter(Mandatory)][string[]]$SearchPaths,
        [Parameter(Mandatory)][string[]]$Patterns
    )

    $latest = $null

    foreach ($path in $SearchPaths) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path)) {
            continue
        }

        foreach ($pattern in $Patterns) {
            $candidate = Get-ChildItem -Path $path -Filter $pattern -File -Recurse -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1

            if (-not $candidate) {
                continue
            }

            if (-not $latest -or $candidate.LastWriteTime -gt $latest.LastWriteTime) {
                $latest = $candidate
            }
        }
    }

    return $latest
}

function Add-LatestCrashArtifactsToBundle {
    param(
        [Parameter(Mandatory)][string]$BundlePath
    )

    $fivemPaths = Get-FiveMEffectivePaths
    $fivemInfo = Resolve-FiveMInstallInfo
    $localFiveMRoot = Join-Path $env:LocalAppData "FiveM"

    $searchRoots = @(
        $fivemPaths.FiveMApplicationData,
        $fivemPaths.FiveMCrashes,
        (Join-Path $fivemPaths.FiveMApplicationData "logs"),
        $Script:Paths.FiveMApplicationData,
        $Script:Paths.FiveMCrashes,
        $localFiveMRoot,
        $fivemInfo.InstallRootPath,
        (Join-Path $fivemInfo.InstallRootPath "logs"),
        (Join-Path $fivemInfo.InstallRootPath "crashes")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    $latestDump = Get-LatestFileFromPaths -SearchPaths $searchRoots -Patterns @("*.dmp","*.mdmp","*.hdmp")
    if ($latestDump) {
        $dumpName = "latest-crash-dump$($latestDump.Extension)"
        Copy-Item -Path $latestDump.FullName -Destination (Join-Path $BundlePath $dumpName) -Force -ErrorAction SilentlyContinue
        Write-Log "Included latest crash dump: $($latestDump.FullName)" "SUCCESS"
    }
    else {
        Write-Log "No crash dump file was found to include." "WARN"
    }

    $latestLog = Get-LatestFileFromPaths -SearchPaths $searchRoots -Patterns @("CitizenFX*.log","citizenfx*.log","*.log","*.txt")
    if ($latestLog) {
        $logName = "latest-log-file$($latestLog.Extension)"
        Copy-Item -Path $latestLog.FullName -Destination (Join-Path $BundlePath $logName) -Force -ErrorAction SilentlyContinue
        Write-Log "Included latest log file: $($latestLog.FullName)" "SUCCESS"
    }
    else {
        Write-Log "No log file was found to include." "WARN"
    }
}

function Invoke-ExternalCommandChecked {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$Description
    )

    & $Command @Arguments | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$Description failed with exit code $exitCode."
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
    $candidates = @(
        $info.AppDataPath,
        $info.InstallRootPath,
        $Script:Paths.FiveMApplicationData,
        $Script:Paths.FiveMApp,
        $Script:Paths.FiveMRoot
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($candidate in $candidates) {
        if (-not (Test-Path $candidate)) {
            continue
        }

        if ((Test-Path (Join-Path $candidate "data")) -or
            (Test-Path (Join-Path $candidate "crashes")) -or
            (Test-Path (Join-Path $candidate "Crashes")) -or
            (Test-Path (Join-Path $candidate "FiveM.app\data"))) {
            return $candidate
        }
    }

    return $null
}

function Get-FiveMEffectivePaths {
    $appDataPath = Get-FiveMAppDataPath
    if (-not $appDataPath) {
        $appDataPath = if (Test-Path $Script:Paths.FiveMApp) { $Script:Paths.FiveMApp } else { $Script:Paths.FiveMApplicationData }
    }

    $dataCandidates = @(
        (Join-Path $appDataPath "data"),
        (Join-Path $appDataPath "FiveM.app\data")
    )

    $dataPath = ($dataCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1)
    if (-not $dataPath) {
        $dataPath = Join-Path $appDataPath "data"
    }

    $crashCandidates = @(
        (Join-Path $appDataPath "crashes"),
        (Join-Path $appDataPath "Crashes"),
        (Join-Path $dataPath "crashes"),
        (Join-Path $appDataPath "FiveM.app\crashes"),
        (Join-Path $appDataPath "FiveM.app\Crashes")
    )

    $crashesPath = ($crashCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1)
    if (-not $crashesPath) {
        $crashesPath = Join-Path $appDataPath "Crashes"
    }

    return @{
        FiveMApplicationData = $appDataPath
        FiveMData            = $dataPath
        FiveMCrashes         = $crashesPath
        Cache                = Join-Path $dataPath "cache"
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
        $paths.Cache,
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
    Invoke-ExternalCommandChecked -Command "ipconfig.exe" -Arguments @("/flushdns") -Description "DNS flush"
    Write-Log "DNS flush complete." "SUCCESS"

    Write-Log "Resetting Winsock..." "ACTION"
    Invoke-ExternalCommandChecked -Command "netsh.exe" -Arguments @("winsock","reset") -Description "Winsock reset"
    Write-Log "Winsock reset complete." "SUCCESS"

    Write-Log "Resetting IP stack..." "ACTION"
    Invoke-ExternalCommandChecked -Command "netsh.exe" -Arguments @("int","ip","reset") -Description "IP stack reset"
    Write-Log "IP stack reset complete." "SUCCESS"

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

function Connect-WeThePeopleRP {
    Write-Log "Launching FiveM connection via Explorer: We The People RP" "ACTION"
    Start-Process explorer.exe "fivem://connect/151.244.225.160:30120"
    Write-Log "Connection request sent to We The People RP." "SUCCESS"
}

function New-WTPRPDesktopShortcut {
    $shortcutName = "WTPRP FiveM Launcher.lnk"
    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $shortcutPath = Join-Path $desktopPath $shortcutName

    $assetRoot = Join-Path $env:LocalAppData "FiveM-Troubleshooter\assets"
    $iconPath = Join-Path $assetRoot "wtprp_icon_full.ico"
    $iconUrl = "https://raw.githubusercontent.com/zombiebox789/fivemtroubleshooting/refs/heads/main/wtprp_icon_full.ico"
    $connectUri = "fivem://connect/151.244.225.160:30120"

    if (-not (Test-Path $assetRoot)) {
        New-Item -Path $assetRoot -ItemType Directory -Force | Out-Null
    }

    try {
        Invoke-WebRequest -Uri $iconUrl -OutFile $iconPath -UseBasicParsing -ErrorAction Stop
    }
    catch {
        throw "Failed to download shortcut icon: $($_.Exception.Message)"
    }

    try {
        $wsh = New-Object -ComObject WScript.Shell
        $shortcut = $wsh.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = "$env:WINDIR\explorer.exe"
        $shortcut.Arguments = $connectUri
        $shortcut.WorkingDirectory = $desktopPath
        $shortcut.IconLocation = $iconPath
        $shortcut.Description = "WTPRP FiveM auto-connect launcher"
        $shortcut.Save()
    }
    catch {
        throw "Failed to create desktop shortcut: $($_.Exception.Message)"
    }

    Write-Log "Desktop shortcut created: $shortcutPath" "SUCCESS"
}

function Open-CommunityLink {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url
    )

    Write-Log "Opening link: $Name" "ACTION"
    Start-Process explorer.exe $Url
    Write-Log "Opened link: $Name" "SUCCESS"
}

function Open-WTPRPDiscord {
    Open-CommunityLink -Name "Discord" -Url "https://discord.gg/pD2nFu3d"
}

function Open-WTPRPRules {
    Open-CommunityLink -Name "Rules" -Url "https://docs.google.com/document/d/16PYoLOgpm99zyC5XthGnVfzhPb8DtqEMP3cykPsx8B8"
}

function Open-WTPRPVIP {
    Open-CommunityLink -Name "VIP" -Url "https://we-the-people-rp.tebex.io/#hero"
}

function Open-WTPRPCancelVIP {
    Open-CommunityLink -Name "Cancel VIP" -Url "https://portal.tebex.io/dashboard"
}
#endregion Repair Actions

#region Advanced
function Invoke-DISMRepairs {
    Write-Log "Running DISM CheckHealth..." "ACTION"
    Invoke-ExternalCommandChecked -Command "DISM.exe" -Arguments @("/Online","/Cleanup-Image","/CheckHealth") -Description "DISM CheckHealth"

    Write-Log "Running DISM ScanHealth..." "ACTION"
    Invoke-ExternalCommandChecked -Command "DISM.exe" -Arguments @("/Online","/Cleanup-Image","/ScanHealth") -Description "DISM ScanHealth"

    Write-Log "Running DISM RestoreHealth..." "ACTION"
    Invoke-ExternalCommandChecked -Command "DISM.exe" -Arguments @("/Online","/Cleanup-Image","/RestoreHealth") -Description "DISM RestoreHealth"

    Write-Log "DISM repairs completed." "SUCCESS"
}

function Invoke-SystemFileCheck {
    Write-Log "Running SFC /scannow..." "ACTION"
    Invoke-ExternalCommandChecked -Command "sfc.exe" -Arguments @("/scannow") -Description "SFC scan"
    Write-Log "SFC scan completed." "SUCCESS"
}

function Invoke-CheckDiskAllDrives {
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Za-z]:\\$' } | Sort-Object Name
    if (-not $drives -or $drives.Count -eq 0) {
        throw "No filesystem drives were found for CHKDSK."
    }

    foreach ($drive in $drives) {
        $driveLetter = "$($drive.Name):"
        Write-Log "Running CHKDSK scan on $driveLetter..." "ACTION"
        & chkdsk.exe $driveLetter "/scan" | Out-Null
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-Log "CHKDSK completed on $driveLetter." "SUCCESS"
        }
        else {
            Write-Log "CHKDSK returned exit code $exitCode on $driveLetter." "WARN"
        }
    }
}

function Invoke-RepairVCRuntimes {
    Write-Log "Repairing Microsoft Visual C++ Runtimes..." "ACTION"

    $vcTempRoot = Join-Path $Script:TempFolder "vcpp-repair"
    if (-not (Test-Path $vcTempRoot)) {
        New-Item -Path $vcTempRoot -ItemType Directory -Force | Out-Null
    }

    $packages = @(
        @{
            Name = "Microsoft Visual C++ x64"
            Url  = "https://aka.ms/vs/17/release/vc_redist.x64.exe"
            File = Join-Path $vcTempRoot "vc_redist.x64.exe"
        },
        @{
            Name = "Microsoft Visual C++ x86"
            Url  = "https://aka.ms/vs/17/release/vc_redist.x86.exe"
            File = Join-Path $vcTempRoot "vc_redist.x86.exe"
        }
    )

    foreach ($pkg in $packages) {
        Write-Log "Downloading $($pkg.Name) installer..." "ACTION"
        Invoke-WebRequest -Uri $pkg.Url -OutFile $pkg.File -UseBasicParsing -ErrorAction Stop
        Write-Log "Downloaded $($pkg.Name)." "SUCCESS"

        Write-Log "Running repair for $($pkg.Name)..." "ACTION"
        $proc = Start-Process -FilePath $pkg.File -ArgumentList "/repair","/quiet","/norestart" -PassThru -Wait -ErrorAction Stop
        if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
            throw "$($pkg.Name) repair failed with exit code $($proc.ExitCode)."
        }

        if ($proc.ExitCode -eq 3010) {
            $Script:RestartNeeded = $true
            Write-Log "$($pkg.Name) repaired. Restart is recommended." "WARN"
        }
        else {
            Write-Log "$($pkg.Name) repaired successfully." "SUCCESS"
        }
    }

    Remove-Item -Path $vcTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Microsoft Visual C++ Runtime repair complete." "SUCCESS"
}
#endregion Advanced

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

    Add-LatestCrashArtifactsToBundle -BundlePath $bundleRoot

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
function Show-AdvancedMenu {
    do {
        Show-Banner

        Write-SectionTitle -Title "Advanced Repairs"
        Write-Host " 1) DISM Repairs"
        Write-Host " 2) SFC /scannow"
        Write-Host " 3) CHKDSK on all drives"
        Write-Host " 4) Repair Microsoft Visual C++ Runtimes"
        Write-Host
        Write-Host " 0) Back"
        Write-Host

        $choice = Read-Host "Select an option [0-4]"
        switch ($choice) {
            "1" { Invoke-Safely -ActionName "DISM Repairs" -ScriptBlock { Invoke-DISMRepairs } | Out-Null; Wait-ForInput }
            "2" { Invoke-Safely -ActionName "SFC /scannow" -ScriptBlock { Invoke-SystemFileCheck } | Out-Null; Wait-ForInput }
            "3" { Invoke-Safely -ActionName "CHKDSK on all drives" -ScriptBlock { Invoke-CheckDiskAllDrives } | Out-Null; Wait-ForInput }
            "4" { Invoke-Safely -ActionName "Repair Microsoft Visual C++ Runtimes" -ScriptBlock { Invoke-RepairVCRuntimes } | Out-Null; Wait-ForInput }
            "0" { return }
            default {
                Write-Log "Invalid selection." "WARN"
                Start-Sleep -Seconds 1
            }
        }
    } while ($true)
}

function Show-MainMenu {
    do {
        Show-Banner

        Write-SectionTitle -Title "Fixes"
        Write-Host " 1) Close FiveM / GTA"
        Write-Host " 2) Clear FiveM Cache"
        Write-Host " 3) Clear Crash Logs"
        Write-Host " 4) Reset Internet Settings"
        Write-Host " 5) Set DNS to Cloudflare"
        Write-Host " 6) Clear FiveM Local Files"
        Write-Host

        Write-SectionTitle -Title "Information / Support"
        Write-Host " 7) Create WTPRP desktop shortcut (auto connect)"
        Write-Host " 8) Export Support Package"
        Write-Host " 9) Advanced Repairs"
        Write-Host "10) Connect to ""We The People RP"""
        Write-Host

        Write-SectionTitle -Title "Links"
        Write-Host "11) Open Discord"
        Write-Host "12) Open Rules"
        Write-Host "13) Open VIP Store"
        Write-Host "14) Manage VIP Subscription"
        Write-Host

        Write-SectionTitle -Title "Session"
        Write-Host " 0) Exit"
        Write-Host

        $choice = Read-Host "Select an option [0-14]"

        switch ($choice) {
            "1"  { Invoke-Safely -ActionName "Close FiveM / GTA" -ScriptBlock { Stop-GameProcesses } | Out-Null; Wait-ForInput }
            "2"  { Invoke-Safely -ActionName "Clear FiveM Cache" -ScriptBlock { Clear-FiveMCache } | Out-Null; Wait-ForInput }
            "3"  { Invoke-Safely -ActionName "Clear Crash Logs" -ScriptBlock { Clear-FiveMCrashLogs } | Out-Null; Wait-ForInput }
            "4"  { Invoke-Safely -ActionName "Reset Internet Settings" -ScriptBlock { Reset-NetworkStack } | Out-Null; Invoke-RestartPrompt; Wait-ForInput }
            "5"  { Invoke-Safely -ActionName "Set DNS to Cloudflare" -ScriptBlock { Set-CloudflareDNS } | Out-Null; Wait-ForInput }
            "6"  { Invoke-Safely -ActionName "Clear FiveM Local Files" -ScriptBlock { Clear-FiveMLocalFiles } | Out-Null; Wait-ForInput }
            "7"  { Invoke-Safely -ActionName "Create WTPRP desktop shortcut (auto connect)" -ScriptBlock { New-WTPRPDesktopShortcut } | Out-Null; Wait-ForInput }
            "8"  { Invoke-Safely -ActionName "Export Support Package" -ScriptBlock { Export-DiagnosticsBundle } | Out-Null; Wait-ForInput }
            "9"  { Show-AdvancedMenu }
            "10" { Invoke-Safely -ActionName "Connect to We The People RP" -ScriptBlock { Connect-WeThePeopleRP } | Out-Null; Wait-ForInput }
            "11" { Invoke-Safely -ActionName "Open Discord Link" -ScriptBlock { Open-WTPRPDiscord } | Out-Null; Wait-ForInput }
            "12" { Invoke-Safely -ActionName "Open Rules Link" -ScriptBlock { Open-WTPRPRules } | Out-Null; Wait-ForInput }
            "13" { Invoke-Safely -ActionName "Open VIP Link" -ScriptBlock { Open-WTPRPVIP } | Out-Null; Wait-ForInput }
            "14" { Invoke-Safely -ActionName "Manage VIP Subscription" -ScriptBlock { Open-WTPRPCancelVIP } | Out-Null; Wait-ForInput }
            "0"  {
                Write-Log "Exiting tool." "INFO"
                $Script:ExitRequested = $true
                return
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
    Wait-ForInput
}
finally {
    Write-Log "Session ended." "INFO"
    Remove-SessionArtifacts
}
#endregion Main

if ($Script:ExitRequested) {
    exit
}

