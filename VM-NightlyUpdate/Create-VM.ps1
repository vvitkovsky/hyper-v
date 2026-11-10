#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string]$Name,
    [ValidateNotNullOrEmpty()][string]$Destination,
    [string]$ComputerName,
    # Left empty, the template is chosen from those installed with Install.cmd,
    # and the checkpoint is the one its nightly task refreshes.
    [string]$TemplateName,
    [string]$CheckpointName,
    [switch]$KeepComputerName,
    [switch]$NoPause
)
$ErrorActionPreference='Stop'
$isAdmin=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $command="& '"+$PSCommandPath.Replace("'","''")+"'"
    foreach ($parameter in @('Name','Destination','ComputerName','TemplateName','CheckpointName')) {
        if (-not $PSBoundParameters.ContainsKey($parameter)) { continue }
        $value=[string](Get-Variable -Name $parameter -ValueOnly)
        $command+=" -$parameter '"+$value.Replace("'","''")+"'"
    }
    if ($KeepComputerName) { $command+=' -KeepComputerName' }
    if ($NoPause) { $command+=' -NoPause' }
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    exit $process.ExitCode
}
$exitCode=1
try {
    Import-Module Hyper-V
    Add-Type -AssemblyName System.Security
    . (Join-Path $PSScriptRoot 'Maintenance-Common.ps1')
    . (Join-Path $PSScriptRoot 'Credential-Input.ps1')
    . (Join-Path $PSScriptRoot 'VM-Registration.ps1')
    . (Join-Path $PSScriptRoot 'Template-Clone.ps1')
    if ($KeepComputerName -and $PSBoundParameters.ContainsKey('ComputerName')) { throw 'Use -ComputerName OR -KeepComputerName.' }
    $installations=@(Get-VMUpdateInstallations -BaseDirectory $PSScriptRoot | Sort-Object VMName)
    if ([string]::IsNullOrWhiteSpace($TemplateName)) {
        if (-not $installations.Count) { throw 'No template has nightly updates installed from this folder. Run Install.cmd for the template first, or supply -TemplateName.' }
        $default=if (@($installations | Where-Object VMName -EQ 'Windows 11 Template').Count) { 'Windows 11 Template' } elseif ($installations.Count -eq 1) { $installations[0].VMName } else { $null }
        Write-Host 'Templates (VMs updated nightly from this folder):'
        $TemplateName=Read-VMUpdateChoice -Prompt 'Template to copy' -Default $default -Items @($installations | ForEach-Object {
            $state=(Get-VM -Id $_.VMId -ErrorAction SilentlyContinue).State
            $detail="checkpoint $($_.Checkpoint)"
            if (-not $state) { $detail+=', VM not found' } elseif ($state -ne 'Off') { $detail+=", $state - shut it down before copying" }
            [pscustomobject]@{ Name=$_.VMName; Detail=$detail }
        })
    }
    $template=Get-TemplateVM $TemplateName
    if ([string]::IsNullOrWhiteSpace($CheckpointName)) {
        $installed=@($installations | Where-Object VMId -EQ $template.Id)
        $CheckpointName=if ($installed.Count) { $installed[0].Checkpoint } else { 'clean' }
    }
    # 'Windows Server 2025 Template' suggests 'Windows Server 2025 Test'.
    $defaultName=($TemplateName -replace '\s*\bTemplate$','').Trim()+' Test'
    $settings=Read-TemplateCopySettings -Name $Name -Destination $Destination -ComputerName $ComputerName -KeepComputerName:$KeepComputerName -DefaultName $defaultName
    $Name=$settings.Name; $Destination=$settings.Destination; $ComputerName=$settings.ComputerName
    $credential=$null
    # Renaming signs in to the copy with the template's saved maintenance credential.
    if (-not $KeepComputerName) { $credential=Get-TemplateGuestCredential -TemplateName $TemplateName -BaseDirectory $PSScriptRoot }
    Write-Host "New VM: $Name"
    if ($credential) { Write-Host "Windows computer name: $ComputerName" }
    Write-Host "Preparing VM, destination: $Destination, please wait..."
    $copy=Copy-VMTemplate -TemplateName $TemplateName -Name $Name -Destination $Destination -CheckpointName $CheckpointName
    if ($credential) {
        try { $copy | Add-Member -NotePropertyName ComputerName -NotePropertyValue (Set-VMCopyComputerName -VMId $copy.Id -ComputerName $ComputerName -Credential $credential -CheckpointName $CheckpointName) }
        catch { throw "VM '$Name' was created, but its Windows computer name was not changed; the VM was left as it is for inspection. $($_.Exception.Message)" }
    }
    $copy | Format-List
    if ($credential) { Write-Host "VM created with its own disks, Windows computer name $ComputerName and checkpoint '$CheckpointName'. It is shut down and ready to start." }
    else { Write-Host 'VM created with its own disks and checkpoint. It keeps the template''s Windows computer name. It is shut down and ready to start.' }
    $exitCode=0
} catch { Write-Host "COPY FAILED: $($_.Exception.Message)" -ForegroundColor Red }
if (-not $NoPause) {
    Write-Host 'Press any key to continue...' -NoNewline
    $null=$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    Write-Host
}
exit $exitCode
