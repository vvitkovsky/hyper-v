#Requires -Version 5.1
# Asks once for the VMS application account that test VMs are signed in to
# with (the installer's default administrator) and saves it encrypted on this
# host. Agents read it with Get-VMUseAppCredential of the vm-use skill.
# Run it yourself: it asks for the password in a prompt.
[CmdletBinding()]
param(
    # Shows which user name is saved, never the password, and changes nothing.
    [switch]$Show,
    [switch]$NoPause
)
$ErrorActionPreference='Stop'
$isAdmin=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $command="& '"+$PSCommandPath.Replace("'","''")+"'"
    if ($Show) { $command+=' -Show' }
    if ($NoPause) { $command+=' -NoPause' }
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    exit $process.ExitCode
}
$exitCode=1
try {
    Add-Type -AssemblyName System.Security
    . (Join-Path $PSScriptRoot 'DVMS-Credential.ps1')
    $path=Get-DVMSAppCredentialPath
    if ($Show) {
        if (Test-Path -LiteralPath $path) { Write-Host "Saved VMS application account: '$((Read-DVMSAppCredential).UserName)' ($path)" }
        else { Write-Host "No VMS application account is saved yet ($path)." }
    } else {
        Write-Host 'VMS application account for test VMs: the default administrator of a fresh installation.'
        Write-Host 'It is used to sign in to Spotter, System Manager and the other VMS applications in test VMs.'
        $credential=Get-Credential -Message 'VMS application account for test VMs'
        if (-not $credential) { throw 'Cancelled; nothing was saved.' }
        $null=Save-DVMSAppCredential -Credential $credential -Path $path
        Write-Host "Saved the account '$($credential.UserName)', encrypted, to $path." -ForegroundColor Green
        Write-Host 'Only administrators and SYSTEM can read it. Run this again to change it.'
    }
    $exitCode=0
} catch { Write-Host "NOT SAVED: $($_.Exception.Message)" -ForegroundColor Red }
if (-not $NoPause) {
    Write-Host 'Press any key to continue...' -NoNewline
    $null=$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    Write-Host
}
exit $exitCode
