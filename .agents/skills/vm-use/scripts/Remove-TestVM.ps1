#Requires -Version 5.1
# Deletes a test VM that was created by this repository's scripts: turns it
# off, removes it from Hyper-V with its checkpoints and deletes its folder,
# including the license copy and install logs kept there. Not reversible.
# -WhatIf shows what would be deleted and changes nothing.
# Run through Invoke-Elevated.ps1.
[CmdletBinding(SupportsShouldProcess=$true)]
param([Parameter(Mandatory=$true)][string]$Name)
$ErrorActionPreference='Stop'
$exitCode=1
try {
    . (Join-Path $PSScriptRoot 'VM-Use.ps1')
    $vm=Get-VMUseVM $Name
    if (@(Get-VMUpdateInstallations -BaseDirectory $VMUseNightlyUpdate | Where-Object VMId -EQ $vm.Id).Count) { throw "'$Name' is a template with nightly updates; this script never deletes templates." }
    if ($vm.Name -like '*Template*') { throw "'$Name' has ""Template"" in its name, so it is a template; this script never deletes templates." }

    # The creation scripts give each VM a folder of its own.
    $folder=[IO.Path]::GetFullPath($vm.ConfigurationLocation).TrimEnd('\')
    if ($folder.Length -le 3) { throw "The VM's folder is a drive root: $folder" }
    if (-not (Test-Path -LiteralPath (Join-Path $folder ("Virtual Machines\{0}.vmcx" -f $vm.Id)))) { throw "'$folder' is not laid out as a VM folder made by these scripts, so it is not deleted." }
    if ((Get-Item -LiteralPath $folder -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "The VM's folder is a reparse point: $folder" }
    function Test-InFolder([string]$Path) {
        if (-not $Path) { return $false }
        $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
        $full -eq $folder -or $full.StartsWith($folder+'\',[StringComparison]::OrdinalIgnoreCase)
    }
    function Get-VMFiles($Machine) {
        # Configuration folders and every disk file, with parents and checkpoints.
        $Machine.ConfigurationLocation; $Machine.SnapshotFileLocation; $Machine.SmartPagingFilePath
        $seen=@{}
        foreach ($drive in @(Get-VMHardDiskDrive -VM $Machine) + @(Get-VMSnapshot -VM $Machine | ForEach-Object { Get-VMHardDiskDrive -VMSnapshot $_ })) {
            $path=$drive.Path
            while ($path -and -not $seen.ContainsKey($path)) {
                $seen[$path]=$true; $path
                $vhd=Get-VHD -Path $path -ErrorAction SilentlyContinue
                $path=if ($vhd) { $vhd.ParentPath } else { $null }
            }
        }
    }
    foreach ($other in Get-VM | Where-Object Id -NE $vm.Id) {
        $shared=@(Get-VMFiles $other | Where-Object { Test-InFolder $_ })
        if ($shared.Count) { throw "VM '$($other.Name)' also uses files in ${folder}: $($shared[0])" }
    }
    $outside=@(Get-VMFiles $vm | Where-Object { $_ -and -not (Test-InFolder $_) } | Sort-Object -Unique)

    $bytes=[long](Get-ChildItem -LiteralPath $folder -Recurse -File -Force | Measure-Object Length -Sum).Sum
    # ForEach-Object <property name> returns nothing under -WhatIf, hence the script blocks.
    Write-Host "VM:          $($vm.Name) ($($vm.Id)), $($vm.State)"
    Write-Host "Checkpoints: $((@(Get-VMSnapshot -VM $vm | ForEach-Object { $_.Name }) -join ', '))"
    Write-Host ("Folder:      {0} ({1:N1} GB)" -f $folder,($bytes/1GB))
    Write-Host "Contains:    $((@(Get-ChildItem -LiteralPath $folder -Force | ForEach-Object { $_.Name }) -join ', '))"
    foreach ($path in $outside) { Write-Host "Kept, outside the folder: $path" }

    if ($PSCmdlet.ShouldProcess("$($vm.Name) and $folder",'Delete the VM and its folder')) {
        if ($vm.State -ne 'Off') { Stop-VM -VM $vm -TurnOff -Force }
        Remove-VM -VM $vm -Force
        if (Get-VM -Id $vm.Id -ErrorAction SilentlyContinue) { throw 'Hyper-V still lists the VM.' }
        # Hyper-V can hold the disks for a while after removing checkpoints.
        $deadline=(Get-Date).AddMinutes(10)
        while ($true) {
            try { Remove-Item -LiteralPath $folder -Recurse -Force; break }
            catch {
                if ((Get-Date) -ge $deadline) { throw "The VM was removed from Hyper-V, but its folder could not be deleted: $($_.Exception.Message)" }
                Start-Sleep -Seconds 15
            }
        }
        if (Test-Path -LiteralPath $folder) { throw "The VM was removed from Hyper-V, but its folder still exists: $folder" }
        Write-Host "Deleted VM '$Name' and $folder."
    } else { Write-Host 'Nothing was deleted (-WhatIf).' }
    $exitCode=0
} catch { Write-Host "DELETE FAILED: $($_.Exception.Message)" }
exit $exitCode
