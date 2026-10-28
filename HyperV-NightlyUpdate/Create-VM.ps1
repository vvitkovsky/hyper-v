#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string]$Name,
    [ValidateNotNullOrEmpty()][string]$Destination,
    [string]$ComputerName,
    [string]$TemplateName = 'Windows 11 Template',
    [string]$CheckpointName = 'clean',
    [switch]$KeepComputerName,
    [switch]$NoPause
)
$ErrorActionPreference='Stop'
$isAdmin=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $command="& '"+$PSCommandPath.Replace("'","''")+"'"
    foreach ($parameter in @('Name','Destination','ComputerName','TemplateName','CheckpointName')) {
        if ($parameter -in @('Name','Destination','ComputerName') -and -not $PSBoundParameters.ContainsKey($parameter)) { continue }
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
    if (-not $PSBoundParameters.ContainsKey('Name')) {
        $enteredName=(Read-Host 'New VM name [Windows 11 Test]').Trim()
        $Name=if ([string]::IsNullOrWhiteSpace($enteredName)) { 'Windows 11 Test' } else { $enteredName }
    }
    if (-not $PSBoundParameters.ContainsKey('Destination')) {
        if ([string]::IsNullOrWhiteSpace($Name) -or $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $Name.EndsWith('.') -or $Name.EndsWith(' ') -or $Name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw 'This VM name cannot be used as a folder name. Choose another name or supply -Destination explicitly.'
        }
        $defaultDestination=Join-Path 'A:\VMs' $Name
        $enteredDestination=(Read-Host "Destination [$defaultDestination]").Trim()
        $Destination=if ([string]::IsNullOrWhiteSpace($enteredDestination)) { $defaultDestination } else { $enteredDestination }
    }
    $credential=$null
    if (-not $KeepComputerName) {
        if (-not $PSBoundParameters.ContainsKey('ComputerName')) {
            $defaultComputerName=ConvertTo-GuestComputerName $Name
            $enteredComputerName=(Read-Host "Windows computer name [$defaultComputerName]").Trim()
            $ComputerName=if ([string]::IsNullOrWhiteSpace($enteredComputerName)) { $defaultComputerName } else { $enteredComputerName }
        }
        if (-not (Test-GuestComputerName $ComputerName)) { throw "'$ComputerName' is not a valid Windows computer name: use up to 15 letters, digits and hyphens." }
        # Renaming signs in to the copy with the template's saved maintenance credential.
        $registration=Get-VMUpdateRegistration -VMName $TemplateName -BaseDirectory $PSScriptRoot
        $credentialPath=Join-Path $registration.Root 'guest-credential.json'
        if (-not (Test-Path -LiteralPath $credentialPath)) {
            throw "No saved guest credentials for '$TemplateName'. Run Install.cmd for the template, or use -KeepComputerName."
        }
        $credential=Read-SavedVMGuestCredential -Path $credentialPath
    }
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
