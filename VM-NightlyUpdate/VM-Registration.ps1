#Requires -Version 5.1
function Get-VMUpdateRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$VMName,
        [Parameter(Mandatory=$true)][string]$BaseDirectory,
        [switch]$InstalledOnly
    )
    $base=[IO.Path]::GetFullPath($BaseDirectory)
    $stateBase=Join-Path $base '.state'
    if ($InstalledOnly) {
        $roots=New-Object 'System.Collections.Generic.List[string]'
        if (Test-Path -LiteralPath $stateBase) {
            foreach ($directory in Get-ChildItem -LiteralPath $stateBase -Directory -Force) {
                $parsedId=[guid]::Empty
                if ([guid]::TryParse($directory.Name,[ref]$parsedId)) { $roots.Add($directory.FullName) }
            }
        }
        # Compatibility for removing an earlier ProgramData installation.
        $oldBase=Join-Path $env:ProgramData 'HyperVNightlyUpdate'
        if (Test-Path -LiteralPath $oldBase) {
            foreach ($directory in Get-ChildItem -LiteralPath $oldBase -Directory -Force) {
                $parsedId=[guid]::Empty
                if ([guid]::TryParse($directory.Name,[ref]$parsedId)) { $roots.Add($directory.FullName) }
            }
        }
        $roots.Add((Join-Path $env:ProgramData 'HyperVNightlyUpdate-Windows11'))
        $found=@(
            foreach ($root in $roots) {
                $path=Join-Path $root 'config.json'
                if (-not (Test-Path -LiteralPath $path)) { continue }
                $saved=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                if ($saved.VMName -ne $VMName) { continue }
                $id=([guid]$saved.VMId).ToString('D')
                $taskName="HyperVNightlyUpdate-$id"
                $scriptDirectory=$root
                if ($root -eq (Join-Path $env:ProgramData 'HyperVNightlyUpdate-Windows11')) {
                    $taskName='Hyper-V - Windows 11 nightly updates'
                }
                if ($saved.PSObject.Properties['ScriptDirectory']) { $scriptDirectory=[string]$saved.ScriptDirectory }
                if ($saved.PSObject.Properties['TaskName'] -and $saved.TaskName -in @("HyperVNightlyUpdate-$id",'Hyper-V - Windows 11 nightly updates')) {
                    $taskName=[string]$saved.TaskName
                }
                [pscustomobject]@{VM=[pscustomobject]@{Name=$saved.VMName;Id=[guid]$id};Root=$root;ScriptDirectory=$scriptDirectory;TaskName=$taskName}
            }
        )
        $localFound=@($found | Where-Object { $_.Root.StartsWith(($stateBase.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) })
        if ($localFound.Count -gt 0) { $found=$localFound }
        if ($found.Count -gt 1) { throw "Multiple installations match '$VMName'; resolve the duplicate installations before uninstalling." }
        if ($found.Count -eq 1) { return $found[0] }
        return $null
    }
    $matches=@(Get-VM | Where-Object {$_.Name -eq $VMName})
    if ($matches.Count -ne 1) { throw "Expected exactly one VM named '$VMName'; found $($matches.Count)." }
    $vm=$matches[0]
    $id=([guid]$vm.Id).ToString('D')
    $root=Join-Path $stateBase $id
    $taskName="HyperVNightlyUpdate-$id"
    $localConfig=Join-Path $root 'config.json'
    if (Test-Path -LiteralPath $localConfig) {
        $saved=Get-Content -LiteralPath $localConfig -Raw | ConvertFrom-Json
        if ([guid]$saved.VMId -ne [guid]$id) { throw 'Local state belongs to a different VM.' }
        if ($saved.PSObject.Properties['TaskName'] -and $saved.TaskName -eq 'Hyper-V - Windows 11 nightly updates') { $taskName=$saved.TaskName }
    } else {
        $legacyConfig=Join-Path $env:ProgramData 'HyperVNightlyUpdate-Windows11\config.json'
        if (Test-Path -LiteralPath $legacyConfig) {
            $legacy=Get-Content -LiteralPath $legacyConfig -Raw | ConvertFrom-Json
            if ([string]$legacy.VMId -eq $id) { $taskName='Hyper-V - Windows 11 nightly updates' }
        }
    }
    [pscustomobject]@{VM=$vm;Root=$root;ScriptDirectory=$base;TaskName=$taskName}
}

function Assert-VMUpdateRemovalPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][guid]$VMId,
        [Parameter(Mandatory=$true)][string]$BaseDirectory
    )
    $target=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    $local=[IO.Path]::GetFullPath((Join-Path (Join-Path $BaseDirectory '.state') $VMId.ToString('D'))).TrimEnd('\')
    $old=[IO.Path]::GetFullPath((Join-Path (Join-Path $env:ProgramData 'HyperVNightlyUpdate') $VMId.ToString('D'))).TrimEnd('\')
    $legacy=[IO.Path]::GetFullPath((Join-Path $env:ProgramData 'HyperVNightlyUpdate-Windows11')).TrimEnd('\')
    if ($target -notin @($local,$old,$legacy)) { throw "Refusing to remove a directory outside the selected VM's generated state: $target" }
    if (-not (Test-Path -LiteralPath $target)) { return }
    $parent=Split-Path -Path $target -Parent
    if ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Generated-state parent is a reparse point.' }
    $pending=New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($target)
    while ($pending.Count -gt 0) {
        $directory=$pending.Pop()
        if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing removal of a reparse point: $directory" }
        foreach ($child in Get-ChildItem -LiteralPath $directory -Force) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing removal of a reparse point: $($child.FullName)" }
            if ($child.PSIsContainer) { $pending.Push($child.FullName) }
        }
    }
    $configPath=Join-Path $target 'config.json'
    if (Test-Path -LiteralPath $configPath) {
        $config=Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        if ([guid]$config.VMId -ne $VMId) { throw 'Generated state belongs to another VM; refusing removal.' }
    } elseif ($target -eq $legacy) { throw 'Legacy installation has no VM identity; refusing removal.' }
}
