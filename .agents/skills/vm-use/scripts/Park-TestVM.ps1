#Requires -Version 5.1
# Parks a test VM that is not in use: saves its state to disk, which frees the
# host's memory. Starting the VM again (Start-VMUseVM) resumes it where it was.
#
#   -Name <vm>                    park it now
#   -Name <vm> -AfterMinutes 10   park it when it has gone unused for 10 minutes
#   -Name <vm> -Cancel            cancel pending parking; the VM keeps running
#   -ShutDown                     shut Windows down instead of saving the state
#
# Run through Invoke-Elevated.ps1. -VMId and -Scheduled are used by the
# scheduled task that Register-VMUsePark creates.
[CmdletBinding()]
param(
    [string]$Name,
    [guid]$VMId,
    [ValidateRange(0,1440)][int]$AfterMinutes = 0,
    [switch]$ShutDown,
    [switch]$Cancel,
    [switch]$Scheduled
)
$ErrorActionPreference='Stop'
$exitCode=1
$log=$null
function Write-Park([string]$Message) {
    Write-Host $Message
    # The scheduled task has no window; its history is kept beside the VM.
    if ($log) { try { Add-Content -LiteralPath $log -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date),$Message) } catch { } }
}
try {
    . (Join-Path $PSScriptRoot 'VM-Use.ps1')
    if ($VMId -and $VMId -ne [guid]::Empty) {
        $vm=Get-VM -Id $VMId -ErrorAction SilentlyContinue
        if (-not $vm) {
            # The VM was deleted while its parking was pending.
            $null=Unregister-VMUsePark -VM ([pscustomobject]@{Id=$VMId})
            Write-Host "VM $VMId no longer exists; nothing to park."
            exit 0
        }
    } elseif ($Name) { $vm=Get-VMUseVM $Name }
    else { throw 'Supply -Name.' }
    if ($vm.Name -like '*Template*') { throw "'$($vm.Name)' is a template; templates are never parked." }
    if ($Scheduled) { $log=Join-Path $vm.ConfigurationLocation 'Park.log' }

    if ($Cancel) {
        if (Unregister-VMUsePark -VM $vm) { Write-Park "Parking of '$($vm.Name)' was cancelled; it stays $($vm.State)." }
        else { Write-Park "No parking was pending for '$($vm.Name)'; it is $($vm.State)." }
    } elseif ($AfterMinutes -gt 0 -and -not $Scheduled) {
        $due=Register-VMUsePark -VM $vm -AfterMinutes $AfterMinutes -ShutDown:$ShutDown
        Write-Park ("'{0}' will be parked at {1:HH:mm} unless it is used before then." -f $vm.Name,$due)
    } elseif (-not (Enter-VMUseLock $vm)) {
        # A script is working in the VM right now.
        if (-not $Scheduled) { throw "'$($vm.Name)' is in use by another script; it was not parked." }
        $again=if ($AfterMinutes -gt 0) { $AfterMinutes } else { 10 }
        $due=Register-VMUsePark -VM $vm -AfterMinutes $again -ShutDown:$ShutDown
        Write-Park ("'{0}' is in use; parking postponed to {1:HH:mm}." -f $vm.Name,$due)
    } else {
        $state=[string]$vm.State
        if ($state -notin @('Running','Paused')) { Write-Park "'$($vm.Name)' is $state; nothing to park." }
        elseif ($ShutDown) {
            if ($state -eq 'Paused') { Resume-VM -VM $vm }
            $credential=Get-VMUseCredential -VM (Get-VM -Id $vm.Id)
            Stop-VMUseGuest -VM $vm -Credential $credential
            Write-Park "'$($vm.Name)' was shut down."
        } else {
            Save-VM -VM $vm
            if ((Get-VM -Id $vm.Id).State -ne 'Saved') { throw "'$($vm.Name)' is $((Get-VM -Id $vm.Id).State) after saving its state." }
            Write-Park "'$($vm.Name)' was parked: its state is saved. Start-VMUseVM resumes it."
        }
        # The one-time task has done its work; without -Scheduled this cancels a pending one.
        try { $null=Unregister-VMUsePark -VM $vm } catch { Write-Park "The parking task could not be removed: $($_.Exception.Message)" }
    }
    $exitCode=0
} catch { Write-Park "PARK FAILED: $($_.Exception.Message)" }
exit $exitCode
