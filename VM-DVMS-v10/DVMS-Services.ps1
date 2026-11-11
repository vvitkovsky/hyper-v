#Requires -Version 5.1
# Microservices of DVMS v10 builds, installed by <BuildRoot>\<version>\scripts\install.cmd.
# install.cmd copies every MSI/EXE from a UNC path with lines such as
#   set MSI_SOURCE=\\rdfileserver\builds\DVMS\VMSNatsService\main\%MSI_NAME%
# The VM cannot reach the share, so the host copies those files into the VM under
# a local mirror (\\server\share\path -> <mirror>\server\share\path) and runs a
# copy of install.cmd with its UNC paths rewritten to that mirror.
$script:DVMSUncPattern='\\\\([^\\\s"%]+)\\'
# install.cmd echoes this when an MSI returned 3010; its exit code stays 0.
$script:DVMSRestartMarker='Restart the computer to complete the installation'
# Latin-1 maps every byte to one character, so the copy differs from the
# original only in the rewritten paths, whatever the host's code page.
$script:DVMSScriptEncoding=[Text.Encoding]::GetEncoding(28591)

function Get-DVMSServicesScriptPath([string]$BuildRoot,[string]$Version) {
    Join-Path (Join-Path (Join-Path $BuildRoot $Version) 'scripts') 'install.cmd'
}

function ConvertTo-DVMSMirrorPath([string]$UncPath,[string]$Root) {
    Join-Path $Root $UncPath.Substring(2)
}

function Read-DVMSServicesScript {
    # Follows the script's set lines in order to resolve %VAR% in UNC sources.
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Microservice install script not found: $Path" }
    $text=[IO.File]::ReadAllText($Path,$script:DVMSScriptEncoding)
    $variables=@{}
    $sources=New-Object Collections.Generic.List[string]
    $checks=New-Object Collections.Generic.List[string]
    $number=0
    foreach ($line in $text -split '\r?\n') {
        $number++
        if ($line -match '^\s*(rem\b|::)') { continue }
        if ($line -match '^\s*set\s+(?:"(?<name>[^=]+)=(?<value>.*)"|(?<name>[^=\s"]+)=(?<value>.*?))\s*$') {
            $name=$Matches.name
            $value=[regex]::Replace($Matches.value,'%(\w+)%',{
                param($match)
                $known=$variables[$match.Groups[1].Value]
                if ($null -ne $known) { $known } else { $match.Value }
            })
            $variables[$name]=$value
            $sharePath=$value.Trim('"')
            if ($sharePath.StartsWith('\\')) {
                if ($sharePath.Contains('%')) { throw "install.cmd line ${number}: cannot resolve the source path $value" }
                if (-not $sources.Contains($sharePath)) { $sources.Add($sharePath) }
            } elseif ($name -like '*_SOURCE') {
                throw "install.cmd line ${number}: $name is not a share path, so it cannot be copied into the VM: $value"
            }
            if ($name -eq 'MSI_CHECK' -and $value) { $checks.Add($value) }
        } elseif ($line -match '\\\\') {
            throw "install.cmd line ${number} uses a share path outside a set line, which cannot be redirected: $($line.Trim())"
        }
    }
    if (-not $sources.Count) { throw "No share paths were found in $Path." }
    # Folders such as set BUILD_SHARE=\\server\share only build other paths or
    # are tested with if exist, so the mirror needs them but nothing is copied.
    $files=New-Object Collections.Generic.List[object]
    $folders=New-Object Collections.Generic.List[string]
    foreach ($source in $sources) {
        $item=Get-Item -LiteralPath $source -ErrorAction SilentlyContinue
        if (-not $item) { throw "install.cmd refers to a path that is not on the share: $source" }
        if ($item.PSIsContainer) { $folders.Add($source.TrimEnd('\')) } else { $files.Add($item) }
    }
    [pscustomobject]@{
        Path=$Path;Text=$text;Files=$files.ToArray();Folders=$folders.ToArray();Checks=$checks.ToArray()
        RestartMarker=$script:DVMSRestartMarker
        SignalsRestart=$text.Contains($script:DVMSRestartMarker)
    }
}

function ConvertTo-DVMSLocalServicesScript([string]$Text,[string]$MirrorRoot) {
    [regex]::Replace($Text,$script:DVMSUncPattern,{
        param($match)
        "$MirrorRoot\$($match.Groups[1].Value)\"
    })
}

function Save-DVMSLocalServicesScript([string]$Text,[string]$MirrorRoot,[string]$Path) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path,(ConvertTo-DVMSLocalServicesScript $Text $MirrorRoot),$script:DVMSScriptEncoding)
}

function Save-DVMSServiceFile {
    # Mirrors one share file into the host cache; unchanged files are reused.
    param([Parameter(Mandatory=$true)][IO.FileInfo]$Source,[Parameter(Mandatory=$true)][string]$CacheRoot)
    $target=ConvertTo-DVMSMirrorPath $Source.FullName $CacheRoot
    if (Test-DVMSServiceFileCached $Source $CacheRoot) { return $target }
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Write-Host ("  copying {0} ({1:N0} MB)..." -f $Source.FullName,($Source.Length/1MB))
    $partial="$target.partial"
    Copy-Item -LiteralPath $Source.FullName -Destination $partial -Force
    (Get-Item -LiteralPath $partial).LastWriteTimeUtc=$Source.LastWriteTimeUtc
    Move-Item -LiteralPath $partial -Destination $target -Force
    $target
}

function Test-DVMSServiceFileCached([IO.FileInfo]$Source,[string]$CacheRoot) {
    $cached=Get-Item -LiteralPath (ConvertTo-DVMSMirrorPath $Source.FullName $CacheRoot) -ErrorAction SilentlyContinue
    [bool]($cached -and $cached.Length -eq $Source.Length -and $cached.LastWriteTimeUtc -eq $Source.LastWriteTimeUtc)
}

function Get-DVMSRecorderProxyInstaller {
    # <Root>\<branch>\*.exe|*.msi: the folder named after the DVMS version, or
    # else the folder with the newest installer; then its newest installer.
    param([Parameter(Mandatory=$true)][string]$Root,[string]$Version)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "Recorder proxy builds not found: $Root" }
    $found=@(Get-ChildItem -LiteralPath $Root -Directory | ForEach-Object {
        Get-ChildItem -LiteralPath $_.FullName -File | Where-Object Extension -In @('.exe','.msi')
    } | Sort-Object LastWriteTimeUtc -Descending)
    if (-not $found.Count) { throw "No recorder proxy installer (.exe or .msi) was found in a folder under $Root." }
    $matching=@($found | Where-Object { $_.Directory.Name -eq $Version })
    if ($matching.Count) { $matching[0] } else { $found[0] }
}

function Get-DVMSRecorderProxyCommand([string]$GuestPath,[string]$LogPath) {
    # Silent install in the VM. .exe builds are WiX bundles, whose /log also
    # writes each package's log beside it; an .msi goes through msiexec.
    if ([IO.Path]::GetExtension($GuestPath) -eq '.msi') {
        [pscustomobject]@{FilePath='msiexec.exe';Arguments="/i `"$GuestPath`" /qn /norestart /l*v `"$LogPath`""}
    } else {
        [pscustomobject]@{FilePath=$GuestPath;Arguments="/install /quiet /norestart /log `"$LogPath`""}
    }
}
