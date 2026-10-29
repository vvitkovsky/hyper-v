#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$Root,
    [ValidateNotNullOrEmpty()][string]$VMName,
    [Alias('UserName')][string]$VMUserName,
    [Alias('Password')][object]$VMPassword,
    [Alias('Credential')][Management.Automation.PSCredential]$VMCredential,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$ScriptDirectory = $PSScriptRoot
# Resolve the directory in the script body, rather than relying on a parameter
# default evaluated during powershell.exe -File startup under Task Scheduler.
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($Root) -and $MyInvocation.MyCommand.Path) {
    $Root = [IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
}
if ([string]::IsNullOrWhiteSpace($Root)) { throw 'Installation directory could not be resolved. Supply -Root explicitly.' }
Import-Module Hyper-V
Add-Type -AssemblyName System.Security
if ($PSBoundParameters.ContainsKey('VMName')) {
    . (Join-Path $PSScriptRoot 'VM-Registration.ps1')
    $registration = Get-VMUpdateRegistration -VMName $VMName -BaseDirectory $ScriptDirectory
    if (-not $PSBoundParameters.ContainsKey('Root')) { $Root = $registration.Root }
}
. (Join-Path $ScriptDirectory 'Credential-Input.ps1')
. (Join-Path $ScriptDirectory 'Maintenance-Common.ps1')
# Credential parameters are never written to the runtime log.
$overrideCredential = Resolve-VMGuestCredential -VMUserName $VMUserName -VMPassword $VMPassword -VMCredential $VMCredential
$config = Get-Content -LiteralPath (Join-Path $Root 'config.json') -Raw | ConvertFrom-Json
if ($PSBoundParameters.ContainsKey('VMName') -and [guid]$config.VMId -ne [guid]$registration.VM.Id) {
    throw 'The selected VM does not match this installation. Use the matching installation or omit -Root.'
}
$logs = Join-Path $Root 'Logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
$log = Join-Path $logs (Get-Date -Format 'yyyy-MM-dd_HHmmss-fff')
$outcome = [ordered]@{ Started=(Get-Date).ToString('o'); VM=$config.VMName; State='Running'; Message=''; Passes=@() }
$lock = $null
$vmMutex = $null
$exitCode = 1
$vm = $null
$startedVM = $false
function Save-Outcome([string]$Path) {
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $outcome | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}
function Write-Log([string]$Message) {
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $Message"
    Add-Content -LiteralPath "$log.log" -Value $line -Encoding UTF8
    $outcome['Progress'] = $Message
    $outcome['Updated'] = (Get-Date).ToString('o')
    # A rejected competing run must not replace the active run's progress.
    if ($lock) { Save-Outcome (Join-Path $logs 'latest.json') }
    Write-Host $line
}
function Invoke-Guest {
    param([scriptblock]$Script, [object[]]$Arguments=@(), [int]$Timeout=60)
    $job = Invoke-Command -VMId $vm.Id -Credential $credential -ScriptBlock $Script -ArgumentList $Arguments -AsJob
    try {
        $finished = Wait-Job -Job $job -Timeout $Timeout
        if (-not $finished) { throw "Guest command timed out after $Timeout seconds." }
        Receive-Job -Job $job -ErrorAction Stop
        if ($job.State -ne 'Completed') { throw "Guest command ended in state $($job.State)." }
    } finally { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
}
function Wait-Guest([string]$PreviousBoot='', [int]$TimeoutMinutes=15) {
    $until = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastFailure = ''
    Write-Log 'Waiting for Windows and PowerShell Direct to become ready.'
    do {
        try {
            $boot = Invoke-Guest -Script {
                $identity = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
                if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                    throw 'Guest credentials must belong to an administrator.'
                }
                (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
            } -Timeout 30
            if ($boot -and $boot -ne $PreviousBoot) { return [string]$boot }
        } catch {
            $failure = $_.Exception.Message
            if ($failure -ne $lastFailure) { Write-Log "Guest not ready: $failure"; $lastFailure=$failure }
        }
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $until -and (Get-Date) -lt $deadline)
    throw 'Windows did not become reachable with administrator credentials within the boot timeout.'
}
function Wait-GuestRestart([string]$PreviousBoot) {
    # Returns the new boot time if Windows restarted, or $null if it kept
    # running. An unreachable guest is treated as a restart in progress.
    Write-Log 'Update pass failed; checking whether Windows restarted.'
    $until = (Get-Date).AddMinutes(3)
    $extended = $false
    do {
        try {
            $current = Invoke-Guest -Timeout 30 -Script {
                (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
            }
            if ($current -and $current -ne $PreviousBoot) { return [string]$current }
        } catch {
            # Boots that apply updates can take much longer.
            if (-not $extended) { $until = (Get-Date).AddMinutes(60); $extended = $true }
        }
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $until -and (Get-Date) -lt $deadline)
    $null
}
function Stop-GuestAfterFailure {
    # A running VM is skipped by later runs, so ask Windows to shut down and
    # let the next night retry. Never force power off or stop a live worker.
    try {
        if ((Get-VM -Id $vm.Id).State -ne 'Running') { return }
        $workerState = Invoke-Guest -Timeout 30 -Script {
            $task = Get-ScheduledTask -TaskName 'HyperVNightlyUpdate-Worker' -ErrorAction SilentlyContinue
            if ($task) { [string]$task.State } else { 'None' }
        }
        if ($workerState -in @('Running','Queued')) { Write-Log 'Guest update worker is still running; VM left running.'; return }
        Write-Log 'Requesting clean guest shutdown so the next nightly run can retry.'
        try {
            Invoke-Guest -Script {
                & "$env:SystemRoot\System32\shutdown.exe" /s /t 0
                if ($LASTEXITCODE -ne 0) { throw "Shutdown request failed: $LASTEXITCODE" }
            } | Out-Null
        } catch { Write-Log 'Shutdown command disconnected or failed; waiting for Windows to turn off.' }
        $until = (Get-Date).AddMinutes(15)
        while ((Get-VM -Id $vm.Id).State -ne 'Off' -and (Get-Date) -lt $until) { Start-Sleep -Seconds 5 }
        if ((Get-VM -Id $vm.Id).State -eq 'Off') { Write-Log 'VM is off.' }
        else { Write-Log 'Windows did not shut down within 15 minutes; VM left running.' }
    } catch { Write-Log "VM left running: $($_.Exception.Message)" }
}
try {
    $vmMutex = Enter-VMUpdateMutex -VMId ([guid]$config.VMId)
    $lock = [IO.File]::Open((Join-Path $Root 'run.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    # Setup may have finished between the initial read and lock acquisition.
    $currentConfig = Get-Content -LiteralPath (Join-Path $Root 'config.json') -Raw | ConvertFrom-Json
    if ([guid]$currentConfig.VMId -ne [guid]$config.VMId) { throw 'VM identity changed while starting maintenance.' }
    $config = $currentConfig
    # Older state files without this setting retain the original default.
    $checkpointName = 'clean'
    if ($config.PSObject.Properties['Checkpoint']) { $checkpointName = [string]$config.Checkpoint }
    if ([string]::IsNullOrWhiteSpace($checkpointName)) { throw 'Configured checkpoint name is empty. Run setup again.' }
    $outcome['Checkpoint'] = $checkpointName
    $deadline = (Get-Date).AddHours(4)
    $vm = Get-VM -Id ([guid]$config.VMId)
    if ($vm.Name -ne $config.VMName) { throw 'VM name changed; run setup again to confirm the target.' }
    if ($CheckOnly) {
        $outcome.State = 'Checked'
        $outcome.Message = "Startup and VM identity check passed. VM is $($vm.State). No maintenance was started."
        $exitCode = 0
    } elseif ($vm.State -ne 'Off') {
        $outcome.State = 'Skipped'
        $outcome.Message = "VM is $($vm.State); only an Off VM is maintained."
        $exitCode = 0
    } else {
        $oldClean = @(Get-VMSnapshot -VM $vm | Where-Object Name -EQ $checkpointName)
        if ($oldClean.Count -gt 1) { throw "Multiple checkpoints named '$checkpointName' exist. Resolve their names before running." }
        if ($vm.CheckpointType -eq 'Disabled') { throw 'Checkpoints are disabled for this VM.' }
        if ($overrideCredential) { $credential = $overrideCredential }
        else { $credential = Read-SavedVMGuestCredential -Path (Join-Path $Root 'guest-credential.json') }
        Write-Log "Starting $($vm.Name)."
        for ($attempt=1; $attempt -le 6; $attempt++) {
            try { Start-VM -VM $vm | Out-Null; $startedVM = $true; break }
            catch {
                # Retry only the observed Hyper-V resource-allocation failure.
                # Never reduce guest RAM or stop other VMs/applications.
                if ($_ -notmatch '0x800705AA' -or $attempt -eq 6 -or
                    (Get-VM -Id $vm.Id).State -ne 'Off') { throw }
                Write-Log "Host resources unavailable (0x800705AA); startup attempt $attempt/6 failed. Retrying in five minutes."
                Start-Sleep -Seconds 300
            }
        }
        $boot = Wait-Guest
        Write-Log 'Connected to the guest with administrator credentials.'
        $worker = Get-Content -LiteralPath (Join-Path $ScriptDirectory 'Guest-Update.ps1') -Raw
        $ready = $false
        $cleanupComplete = $false
        $mode = 'Update'
        $reboots = 0
        for ($pass=1; $pass -le 12; $pass++) {
            if ((Get-Date) -ge $deadline) { throw 'Four-hour maintenance limit reached.' }
            $runId = [guid]::NewGuid().ToString('N')
            $passMode = $mode
            $mode = 'Update'
            Write-Log "Starting $passMode pass $pass."
            try {
                Invoke-Guest -Arguments @($worker,$runId,$passMode) -Script {
                    param($WorkerText,$RunId,$Mode)
                    $ErrorActionPreference = 'Stop'
                    $taskName = 'HyperVNightlyUpdate-Worker'
                    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                    if ($existing -and $existing.State -eq 'Running') { throw 'A previous guest worker is still running.' }
                    $folder = Join-Path $env:ProgramData 'HyperVNightlyUpdate'
                    if (Test-Path -LiteralPath $folder) {
                        if ((Get-Item -LiteralPath $folder).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                            throw 'Guest working directory is a reparse point.'
                        }
                    }
                    New-Item -ItemType Directory -Path $folder -Force | Out-Null
                    $acl = New-Object Security.AccessControl.DirectorySecurity
                    $acl.SetAccessRuleProtection($true,$false)
                    foreach ($sidText in @('S-1-5-18','S-1-5-32-544')) {
                        $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
                        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit, ObjectInherit','None','Allow')
                        $acl.AddAccessRule($rule)
                    }
                    Set-Acl -LiteralPath $folder -AclObject $acl
                    $path = Join-Path $folder 'Guest-Update.ps1'
                    [IO.File]::WriteAllText($path,$WorkerText,[Text.Encoding]::UTF8)
                    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$path`" -RunId $RunId -Mode $Mode"
                    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
                    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 5) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
                    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
                    Start-ScheduledTask -TaskName $taskName
                } | Out-Null
                $status = $null
                $lastWorkerMessage = ''
                $lastPollFailure = ''
                $workerStartDeadline = (Get-Date).AddMinutes(2)
                $incompleteObservations = 0
                do {
                    Start-Sleep -Seconds 15
                    try {
                        $probe = Invoke-Guest -Arguments @($runId) -Timeout 30 -Script {
                            param($ExpectedRun)
                            $path = Join-Path $env:ProgramData 'HyperVNightlyUpdate\status.json'
                            $record = $null
                            if (Test-Path -LiteralPath $path) { $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
                            $task = Get-ScheduledTask -TaskName 'HyperVNightlyUpdate-Worker'
                            $info = Get-ScheduledTaskInfo -TaskName 'HyperVNightlyUpdate-Worker'
                            [pscustomobject]@{ TaskState=[string]$task.State; Result=$info.LastTaskResult;
                                Record=$(if ($record -and $record.RunId -eq $ExpectedRun) { $record } else { $null }) }
                        }
                    } catch {
                        # Only transport/status-read failures are retryable here.
                        if ($_.Exception.Message -ne $lastPollFailure) {
                            $lastPollFailure = $_.Exception.Message
                            Write-Log "Cannot read guest worker status yet: $lastPollFailure"
                        }
                        continue
                    }
                    if ($probe.Record -and $probe.Record.Message -ne $lastWorkerMessage) {
                        Write-Log $probe.Record.Message
                        $lastWorkerMessage = $probe.Record.Message
                    }
                    if ($probe.TaskState -in @('Running','Queued')) {
                        $incompleteObservations = 0
                        continue
                    }
                    if ($probe.TaskState -ne 'Ready') { throw "Guest worker is $($probe.TaskState). Task result: $($probe.Result)" }
                    if ($probe.Record -and $probe.Record.State -ne 'Running') {
                        if ($probe.Record.State -ne 'Failed' -and $probe.Result -ne 0) {
                            throw "Guest worker exited unsuccessfully. Task result: $($probe.Result)"
                        }
                        $status = $probe.Record
                        break
                    }
                    if ($probe.Result -notin @(0,267009,267011)) {
                        throw "Guest worker failed to start or exited unexpectedly. Task result: $($probe.Result)"
                    }
                    if ($probe.Record) {
                        # Status and Task Scheduler are separate reads. Confirm an
                        # incomplete exit twice to allow a normal completion race.
                        if (++$incompleteObservations -ge 2) {
                            throw "Guest worker exited without a final status. Task result: $($probe.Result)"
                        }
                    } elseif ((Get-Date) -ge $workerStartDeadline) {
                        throw 'Guest worker did not publish a status within two minutes.'
                    }
                } while ((Get-Date) -lt $deadline)
                if (-not $status) { throw 'Update worker timed out or became unreachable; previous checkpoint preserved.' }
                $outcome.Passes += $status
                Write-Log "$($status.State): $($status.Message)"
                foreach ($title in $status.Applied) { Write-Log "Install operation succeeded (reboot/final scan may still be required): $title" }
                if ($status.State -eq 'Failed') { throw $status.Message }
            } catch {
                # Servicing can restart Windows by itself during a pass, e.g. a
                # second restart after a cumulative update. Repeat the pass
                # after such a restart; any other failure stands.
                $failure = $_
                $restartedBoot = Wait-GuestRestart -PreviousBoot $boot
                if (-not $restartedBoot) { throw $failure }
                if (++$reboots -gt 6) { throw 'Six-restart limit reached; previous checkpoint preserved.' }
                Write-Log "Windows restarted itself during the pass ($($failure.Exception.Message)); repeating the pass."
                $boot = $restartedBoot
                $mode = $passMode
                continue
            }
            if ($status.State -eq 'UpToDate') {
                if ($cleanupComplete) { $ready=$true; break }
                $mode = 'Cleanup'
                continue
            }
            if ($status.State -in @('Cleaned','CleanupNeedsReboot')) {
                if ($passMode -ne 'Cleanup') { throw 'Cleanup completion reported by an update pass.' }
                $cleanupComplete = $true
                if ($status.State -eq 'Cleaned') { continue }
            } elseif ($status.State -in @('Installed','NeedsReboot')) {
                # Updates appearing after cleanup must be followed by another
                # cleanup once all updates and pending restarts are finished.
                $cleanupComplete = $false
            }
            if ($status.State -in @('NeedsReboot','CleanupNeedsReboot')) {
                if (++$reboots -gt 6) { throw 'Six-restart limit reached; previous checkpoint preserved.' }
                Write-Log 'Requesting Windows restart.'
                # Restart can disconnect PowerShell Direct before its reply.
                # A changed boot timestamp below is the required confirmation.
                try {
                    Invoke-Guest -Script {
                        & "$env:SystemRoot\System32\shutdown.exe" /r /t 0
                        if ($LASTEXITCODE -ne 0) { throw "Restart request failed: $LASTEXITCODE" }
                    } | Out-Null
                } catch { Write-Log 'Restart command disconnected or failed; waiting for a confirmed new boot.' }
                # Feature upgrades can spend substantially longer applying
                # changes during reboot. The overall deadline still applies.
                $boot = Wait-Guest -PreviousBoot $boot -TimeoutMinutes 60
            } elseif ($status.State -ne 'Installed') { throw "Unexpected worker state: $($status.State)" }
        }
        if (-not $ready) { throw 'Twelve-pass limit reached; previous checkpoint preserved.' }
        Invoke-Guest -Script {
            Unregister-ScheduledTask -TaskName 'HyperVNightlyUpdate-Worker' -Confirm:$false
        } | Out-Null
        Write-Log 'Updates and component cleanup complete. Requesting clean guest shutdown.'
        # Hyper-V's integration shutdown can reject a locked guest (0x800704F7).
        # Ask Windows itself to shut down; /t 0 does not imply forced app closure.
        try {
            Invoke-Guest -Script {
                & "$env:SystemRoot\System32\shutdown.exe" /s /t 0
                if ($LASTEXITCODE -ne 0) { throw "Shutdown request failed: $LASTEXITCODE" }
            } | Out-Null
        } catch { Write-Log 'Shutdown command disconnected or failed; waiting for Windows to turn off.' }
        $shutdownDeadline = (Get-Date).AddMinutes(15)
        do {
            $vm = Get-VM -Id $vm.Id
            if ($vm.State -eq 'Off') { break }
            Start-Sleep -Seconds 5
        } while ((Get-Date) -lt $shutdownDeadline)
        $vm = Get-VM -Id $vm.Id
        if ($vm.State -ne 'Off') { throw 'Windows did not shut down within 15 minutes; refusing to create the checkpoint.' }
        # Take the replacement before touching the previous configured checkpoint.
        $candidateName = $checkpointName + '.candidate-' + [guid]::NewGuid().ToString('N')
        Checkpoint-VM -VM $vm -SnapshotName $candidateName | Out-Null
        # Re-read the registered VM after checkpoint creation; the earlier VM
        # object can retain a stale checkpoint view immediately after import.
        $vm = Get-VM -Id $vm.Id
        $created = @(Get-VMSnapshot -VM $vm | Where-Object Name -EQ $candidateName)
        if ($created.Count -ne 1) { throw 'New checkpoint could not be verified; previous checkpoint preserved.' }
        $newClean = $created[0]
        $verified = $newClean
        $previousName = $checkpointName + '.previous-' + [guid]::NewGuid().ToString('N')
        if ($oldClean.Count -eq 1) { $oldClean[0] | Rename-VMSnapshot -NewName $previousName }
        try {
            $verified | Rename-VMSnapshot -NewName $checkpointName
            if (-not (Get-VMSnapshot -VM $vm | Where-Object { $_.Id -eq $newClean.Id -and $_.Name -eq $checkpointName })) {
                throw 'Replacement checkpoint could not be verified.'
            }
        } catch {
            $promotionError = $_
            # The rename may have succeeded even if its verification failed.
            # Vacate the target name and confirm by ID before restoring it.
            try {
                $newClean | Rename-VMSnapshot -NewName $candidateName -ErrorAction Stop
                $rolledBack = Get-VMSnapshot -VM $vm | Where-Object Id -EQ $newClean.Id
                if (-not $rolledBack -or $rolledBack.Name -ne $candidateName) {
                    throw 'Candidate rollback could not be verified.'
                }
                if ($oldClean.Count -eq 1) { $oldClean[0] | Rename-VMSnapshot -NewName $checkpointName -ErrorAction Stop }
            } catch {
                Write-Log "Checkpoint rollback incomplete; both checkpoints retained under their current names: $($_.Exception.Message)"
            }
            throw $promotionError
        }
        if ($oldClean.Count -eq 1) { $oldClean[0] | Remove-VMSnapshot -Confirm:$false }
        $outcome['CheckpointRefreshed'] = $true
        Write-Log "Checkpoint '$checkpointName' refreshed. Template is ready for copying."
        $outcome.State = 'Succeeded'
        $outcome.Message = "Windows updated, component store cleaned, VM shut down, and checkpoint '$checkpointName' refreshed."
        $exitCode = 0
    }
} catch {
    $outcome.State = 'Failed'
    $outcome.Message = $_.Exception.Message
    Write-Log "FAILED: $($outcome.Message)"
    # Update failures preserve the old checkpoint. Only a VM this run started
    # is shut down, and only cleanly from inside Windows.
    if ($startedVM) { Stop-GuestAfterFailure }
} finally {
    try {
        $outcome['Finished'] = (Get-Date).ToString('o')
        Write-Log "$($outcome.State): $($outcome.Message)"
        Save-Outcome "$log.json"
    } finally {
        try { if ($lock) { $lock.Dispose() } }
        finally { if ($vmMutex) { Exit-VMUpdateMutex $vmMutex } }
    }
}
exit $exitCode
