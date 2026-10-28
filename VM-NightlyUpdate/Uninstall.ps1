#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [ValidateNotNullOrEmpty()][string]$VMName = 'Windows 11 Template',
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
$isAdmin = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ($PSBoundParameters.Count -gt 0) { throw 'When supplying parameters, open PowerShell as administrator and run Uninstall.ps1 there.' }
    $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit $process.ExitCode
}
$lock = $null
$vmMutex = $null
$exitCode = 1
try {
    . (Join-Path $PSScriptRoot 'VM-Registration.ps1')
    . (Join-Path $PSScriptRoot 'Maintenance-Common.ps1')
    $registration = Get-VMUpdateRegistration -VMName $VMName -BaseDirectory $PSScriptRoot -InstalledOnly
    if (-not $registration) {
        Write-Host "No installed nightly update configuration was found for '$VMName'."
        if (-not $NoPause -and -not $WhatIfPreference) {
            Write-Host 'Press any key to continue...' -NoNewline
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            Write-Host
        }
        exit 0
    }
    $root = $registration.Root
    $taskName = $registration.TaskName
    $vmMutex = Enter-VMUpdateMutex -VMId $registration.VM.Id
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq 'Running') {
        throw 'Maintenance is running. Wait for it to finish before uninstalling; the update will not be interrupted.'
    }
    Assert-VMUpdateRemovalPath -Root $root -VMId $registration.VM.Id -BaseDirectory $PSScriptRoot
    # Verify task ownership before deleting a task merely sharing our name.
    if ($task) {
        $expectedScript = Join-Path $registration.ScriptDirectory 'Nightly-Update.ps1'
        if (@($task.Actions | Where-Object {
            $_.Arguments -and $_.Arguments.IndexOf(('"' + $expectedScript + '"'),[StringComparison]::OrdinalIgnoreCase) -ge 0
        }).Count -ne 1) { throw 'Scheduled task does not reference this installation; refusing removal.' }
    }
    if ($PSCmdlet.ShouldProcess("$VMName ($($registration.VM.Id))",'Remove its nightly update task, saved credentials, and generated host logs/state')) {
        if (Test-Path -LiteralPath $root) {
            # The same lock is used by manual and scheduled maintenance runs.
            $lock = [IO.File]::Open((Join-Path $root 'run.lock'),'OpenOrCreate','ReadWrite','None')
        }
        if ($task) {
            Disable-ScheduledTask -TaskName $taskName | Out-Null
            # Do not race a run which started after the first state check.
            if ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
                Enable-ScheduledTask -TaskName $taskName | Out-Null
                throw 'Maintenance started during uninstall. Wait for it to finish and retry.'
            }
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
        if ($lock) { $lock.Dispose(); $lock=$null }
        if (Test-Path -LiteralPath $root) {
            # Recheck the resolved target immediately before recursive removal.
            Assert-VMUpdateRemovalPath -Root $root -VMId $registration.VM.Id -BaseDirectory $PSScriptRoot
            Remove-Item -LiteralPath ([IO.Path]::GetFullPath($root)) -Recurse -Force
        }
        Write-Host "Uninstalled nightly updates for '$VMName'. VM and checkpoints were preserved." -ForegroundColor Green
        Write-Host 'No VM was started or stopped. Files left by an earlier failed guest worker are not touched inside the VM.'
    }
    $exitCode = 0
} catch {
    Write-Host "UNINSTALL FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
} finally {
    try { if ($lock) { $lock.Dispose() } }
    finally { if ($vmMutex) { Exit-VMUpdateMutex $vmMutex } }
}
if (-not $NoPause -and -not $WhatIfPreference) {
    Write-Host 'Press any key to continue...' -NoNewline
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    Write-Host
}
exit $exitCode
