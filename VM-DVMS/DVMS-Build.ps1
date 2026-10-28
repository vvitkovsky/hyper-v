#Requires -Version 5.1
# Build share layout, <BuildRoot>\<version>\ holding either or both of:
#   <version>_DVMS[_<brand>]_x64_<Full|Limited>.exe
#   Mirasys-VMS-<Complete|Update>-<version>.exe   (release builds; Complete = Full, Update = Limited)
$script:DVMSInstallerFilters=@('*_DVMS_*x64_*.exe','Mirasys-VMS-*.exe')

function Get-DVMSInstallerFiles([string]$Folder,[switch]$IgnoreErrors) {
    $action=if ($IgnoreErrors) { 'SilentlyContinue' } else { 'Stop' }
    @(foreach ($filter in $script:DVMSInstallerFilters) { Get-ChildItem -LiteralPath $Folder -Filter $filter -File -ErrorAction $action })
}

function Get-DVMSBuildVersions([string]$BuildRoot) {
    if (-not (Test-Path -LiteralPath $BuildRoot)) { throw "Build share is not reachable: $BuildRoot" }
    foreach ($folder in Get-ChildItem -LiteralPath $BuildRoot -Directory -ErrorAction Stop) {
        $installers=Get-DVMSInstallerFiles $folder.FullName -IgnoreErrors
        if ($installers.Count) {
            [pscustomobject]@{Version=$folder.Name;Updated=($installers | Measure-Object LastWriteTime -Maximum).Maximum}
        }
    }
}

function Get-DVMSInstallers([string]$BuildRoot,[string]$Version) {
    # Unbranded installers first, then full (Full/Complete) before limited (Limited/Update).
    $folder=Join-Path $BuildRoot $Version
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "Version folder not found: $folder" }
    Get-DVMSInstallerFiles $folder | Sort-Object FullName -Unique |
        Sort-Object @{Expression={$_.Name -notmatch '(_DVMS_x64_|^Mirasys-VMS-)'}},@{Expression={$_.Name -notmatch '(_Full\.exe$|^Mirasys-VMS-Complete-)'}},Name
}

function Save-DVMSInstaller {
    # Keeps one host-local copy per version; Copy-VMFile reads host-local files.
    param([Parameter(Mandatory=$true)][IO.FileInfo]$Source,[Parameter(Mandatory=$true)][string]$CacheDirectory)
    New-Item -ItemType Directory -Path $CacheDirectory -Force | Out-Null
    $target=Join-Path $CacheDirectory $Source.Name
    $cached=Get-Item -LiteralPath $target -ErrorAction SilentlyContinue
    if ($cached -and $cached.Length -eq $Source.Length -and $cached.LastWriteTimeUtc -eq $Source.LastWriteTimeUtc) {
        Write-Host "Using cached installer: $target"
        return $target
    }
    # Older builds of this version are replaced, not accumulated.
    Get-ChildItem -LiteralPath $CacheDirectory -File | Where-Object Name -ne $Source.Name | Remove-Item -Force
    Write-Host ("Copying {0} ({1:N1} GB) to {2}..." -f $Source.Name,($Source.Length/1GB),$CacheDirectory)
    $partial="$target.partial"
    Copy-Item -LiteralPath $Source.FullName -Destination $partial -Force
    (Get-Item -LiteralPath $partial).LastWriteTimeUtc=$Source.LastWriteTimeUtc
    Move-Item -LiteralPath $partial -Destination $target -Force
    $target
}
