#Requires -Version 5.1
# Build share layout: <BuildRoot>\<version>\<version>_DVMS[_<brand>]_x64_<Full|Limited>.exe
$script:DVMSInstallerFilter='*_DVMS_*x64_*.exe'

function Get-DVMSBuildVersions([string]$BuildRoot) {
    if (-not (Test-Path -LiteralPath $BuildRoot)) { throw "Build share is not reachable: $BuildRoot" }
    foreach ($folder in Get-ChildItem -LiteralPath $BuildRoot -Directory -ErrorAction Stop) {
        $installers=@(Get-ChildItem -LiteralPath $folder.FullName -Filter $script:DVMSInstallerFilter -File -ErrorAction SilentlyContinue)
        if ($installers.Count) {
            [pscustomobject]@{Version=$folder.Name;Updated=($installers | Measure-Object LastWriteTime -Maximum).Maximum}
        }
    }
}

function Get-DVMSInstallers([string]$BuildRoot,[string]$Version) {
    # Plain (unbranded) installers first, Full before Limited.
    $folder=Join-Path $BuildRoot $Version
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "Version folder not found: $folder" }
    @(Get-ChildItem -LiteralPath $folder -Filter $script:DVMSInstallerFilter -File -ErrorAction Stop) |
        Sort-Object @{Expression={$_.Name -notmatch '_DVMS_x64_'}},@{Expression={$_.Name -notmatch '_Full\.exe$'}},Name
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
