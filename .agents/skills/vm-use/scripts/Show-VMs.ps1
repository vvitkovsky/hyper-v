#Requires -Version 5.1
# Read-only overview for planning a new VM: the templates that can be copied,
# every other VM on this host and the free space. Changes nothing.
# Run through Invoke-Elevated.ps1.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'VM-Use.ps1')

$templates=@(Get-VMUseTemplates)
Write-Host 'TEMPLATES (VMs with "Template" in the name, or with nightly updates; pass the name as -TemplateName)'
if (-not $templates.Count) { Write-Host '  none: name a VM "... Template" and run VM-NightlyUpdate\Install.cmd for it first.' }
foreach ($template in $templates) {
    $nightly=if ($template.Installed) { "nightly update $($template.NightlyUpdate)" } else { 'no nightly update' }
    Write-Host ("  {0}" -f $template.Name)
    Write-Host ("      state {0}, checkpoint '{1}', {2}, {3} GB on disk" -f $template.State,$template.Checkpoint,$nightly,$template.SizeGB)
    if ($template.Ready) { Write-Host '      ready to copy' }
    else { Write-Host "      NOT READY: $($template.Problems)" }
}

Write-Host ''
Write-Host 'OTHER VMS'
$others=@(Get-VM | Where-Object { $_.Id -notin @($templates | ForEach-Object Id) } | Sort-Object Name)
if (-not $others.Count) { Write-Host '  none' }
foreach ($vm in $others) {
    $checkpoints=(@(Get-VMSnapshot -VM $vm | ForEach-Object Name) -join ', ')
    $macs=(@(Get-VMNetworkAdapter -VM $vm | ForEach-Object { "$($_.MacAddress)$(if (-not $_.DynamicMacAddressEnabled) { ' static' })" }) -join ', ')
    $state=[string]$vm.State
    if ($state -eq 'Saved') { $state='Saved (parked)' }
    $due=Get-VMUsePark -VM $vm
    if ($due) { $state+=", parks at $($due.ToString('HH:mm')) unless used" }
    Write-Host ("  {0}" -f $vm.Name)
    Write-Host ("      state {0}, checkpoints: {1}, {2} GB on disk, MAC {3}" -f $state,$(if ($checkpoints) { $checkpoints } else { 'none' }),[math]::Round((Get-VMUseDiskBytes $vm)/1GB,1),$macs)
    Write-Host ("      folder {0}, id {1}" -f $vm.ConfigurationLocation,$vm.Id)
}

Write-Host ''
Write-Host 'FREE SPACE'
foreach ($drive in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
    Write-Host ("  {0} {1:N1} GB free of {2:N1} GB" -f $drive.Name,($drive.AvailableFreeSpace/1GB),($drive.TotalSize/1GB))
}
$memory=Get-CimInstance Win32_OperatingSystem
Write-Host ("  Host memory: {0:N1} GB free of {1:N1} GB" -f ($memory.FreePhysicalMemory/1MB),($memory.TotalVisibleMemorySize/1MB))
exit 0
