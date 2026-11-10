#Requires -Version 5.1
[CmdletBinding()]
param(
    # Values left empty are asked for after elevation.
    [string]$VMName,
    [string]$ScheduledTime,
    [string]$CheckpointName,
    [Alias('UserName')][string]$VMUserName,
    [Alias('Password')][object]$VMPassword,
    [Alias('Credential')][Management.Automation.PSCredential]$VMCredential,
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
$isAdmin = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ($PSBoundParameters.ContainsKey('VMUserName') -or $PSBoundParameters.ContainsKey('VMPassword') -or $PSBoundParameters.ContainsKey('VMCredential')) {
        throw 'When supplying parameters, open PowerShell as administrator and run Install.ps1 there. Credentials are not forwarded through UAC command-line arguments.'
    }
    $command = "& '"+$PSCommandPath.Replace("'","''")+"'"
    foreach ($name in @('VMName','ScheduledTime','CheckpointName')) {
        if ($PSBoundParameters.ContainsKey($name)) { $command += " -$name '"+([string]$PSBoundParameters[$name]).Replace("'","''")+"'" }
    }
    if ($NoPause) { $command += ' -NoPause' }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    exit $process.ExitCode
}
$vmMutex = $null
$stateLocks = New-Object 'System.Collections.Generic.List[System.IO.FileStream]'
$exitCode = 1
try {
    . (Join-Path $PSScriptRoot 'Credential-Input.ps1')
    . (Join-Path $PSScriptRoot 'VM-Registration.ps1')
    . (Join-Path $PSScriptRoot 'Maintenance-Common.ps1')
    Import-Module Hyper-V
    Add-Type -AssemblyName System.Security
    $installations = @(Get-VMUpdateInstallations -BaseDirectory $PSScriptRoot)
    if ([string]::IsNullOrWhiteSpace($VMName)) {
        $vms = @(Get-VM | Sort-Object Name)
        if (-not $vms.Count) { throw 'No Hyper-V VMs were found on this host.' }
        Write-Host 'Hyper-V VMs:'
        $VMName = Read-VMUpdateChoice -Prompt 'VM to update nightly' -Default 'Windows 11 Template' -Items @(foreach ($candidate in $vms) {
            $installed = @($installations | Where-Object VMId -EQ $candidate.Id)
            $detail = if ($installed.Count) { "updated nightly at $($installed[0].Time), checkpoint $($installed[0].Checkpoint)" } else { '' }
            [pscustomobject]@{ Name=$candidate.Name; Detail=$detail }
        })
    }
    $registration = Get-VMUpdateRegistration -VMName $VMName -BaseDirectory $PSScriptRoot
    # A reinstall offers the VM's current time and checkpoint as defaults.
    $current = @($installations | Where-Object VMId -EQ $registration.VM.Id)
    if ([string]::IsNullOrWhiteSpace($ScheduledTime)) {
        $default = if ($current.Count -and $current[0].Time) { $current[0].Time } else { '00:00' }
        $entered = (Read-Host "Daily time, 24-hour HH:mm host time [$default]").Trim()
        $ScheduledTime = if ($entered) { $entered } else { $default }
    }
    if ($ScheduledTime -notmatch '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$') { throw "'$ScheduledTime' is not a 24-hour HH:mm time, for example 00:00 or 02:30." }
    if ([string]::IsNullOrWhiteSpace($CheckpointName)) {
        $default = if ($current.Count) { $current[0].Checkpoint } else { 'clean' }
        $entered = (Read-Host "Checkpoint to refresh [$default]").Trim()
        $CheckpointName = if ($entered) { $entered } else { $default }
    }
    $sameTime = @($installations | Where-Object { $_.VMId -ne $registration.VM.Id -and $_.Time -eq $ScheduledTime } | ForEach-Object VMName)
    if ($sameTime.Count) { Write-Warning "$($sameTime -join ', ') is also updated at $ScheduledTime. The VMs will then run at the same time and need host memory together." }
    $vmMutex = Enter-VMUpdateMutex -VMId $registration.VM.Id
    # Re-read persisted registration while holding the per-VM lifecycle lock.
    $registration = Get-VMUpdateRegistration -VMName $VMName -BaseDirectory $PSScriptRoot
    $vm = $registration.VM
    if ($vm.CheckpointType -eq 'Disabled') { throw "Enable checkpoints for '$VMName' in Hyper-V Manager first." }
    $clean = @(Get-VMSnapshot -VM $vm | Where-Object Name -EQ $CheckpointName)
    if ($clean.Count -gt 1) { throw "More than one checkpoint is named '$CheckpointName'. Give them unique names first." }
    $taskName = $registration.TaskName
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing -and $existing.State -eq 'Running') { throw 'Maintenance is running. Wait for it to finish before reinstalling.' }
    $root = $registration.Root
    if (Test-Path -LiteralPath $root) {
        if ((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Installation directory is a reparse point.' }
    }
    Write-Host "This installs daily maintenance for '$VMName' at $ScheduledTime host local time."
    Write-Host 'After updating, DISM /ResetBase removes superseded components and update uninstall files.'
    Write-Host 'Installed updates cannot be uninstalled after cleanup. Future updates can still be installed.'
    # Reuse an existing encrypted credential when reconfiguring the same VM.
    $priorRoot = $null
    if ($existing) {
        $priorArguments = [string]$existing.Actions[0].Arguments
        $rootMatch = [regex]::Match($priorArguments,'(?i)(?:^|\s)-Root\s+"([^"]+)"')
        if ($rootMatch.Success) { $priorRoot=$rootMatch.Groups[1].Value }
        elseif ($existing.Actions[0].WorkingDirectory) { $priorRoot=[string]$existing.Actions[0].WorkingDirectory }
    }
    # File locks also protect a manual run of the preceding script version,
    # which does not yet use the per-VM mutex. Lock before modifying any state.
    $lockedRoots = @()
    foreach ($candidate in @($priorRoot,$root)) {
        if (-not $candidate -or -not (Test-Path -LiteralPath $candidate)) { continue }
        $resolved = [IO.Path]::GetFullPath($candidate).TrimEnd('\')
        if ($resolved -in $lockedRoots) { continue }
        $stateLocks.Add([IO.File]::Open((Join-Path $resolved 'run.lock'),'OpenOrCreate','ReadWrite','None'))
        $lockedRoots += $resolved
    }
    $credentialSource = $null
    foreach ($candidate in @($root,$priorRoot)) {
        if (-not $candidate) { continue }
        $candidateConfig = Join-Path $candidate 'config.json'
        $candidateCredential = Join-Path $candidate 'guest-credential.json'
        if ((Test-Path -LiteralPath $candidateConfig) -and (Test-Path -LiteralPath $candidateCredential)) {
            $savedConfig=Get-Content -LiteralPath $candidateConfig -Raw | ConvertFrom-Json
            if ([guid]$savedConfig.VMId -eq [guid]$vm.Id) { $credentialSource=$candidateCredential; break }
        }
    }
    $guest = $null
    $savedCredentialText = $null
    if (-not $VMUserName -and $null -eq $VMPassword -and -not $VMCredential -and $credentialSource) {
        $savedCredentialText=Get-Content -LiteralPath $credentialSource -Raw
        Write-Host 'Reusing the encrypted credentials already saved for this VM.'
    } else {
        $guest = Resolve-VMGuestCredential -VMUserName $VMUserName -VMPassword $VMPassword -VMCredential $VMCredential -Prompt -VMName $VMName
        Write-Host 'Using the supplied VM administrator credentials (Windows password, not a Hello PIN).'
    }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    # Machine DPAPI enables the SYSTEM task to decrypt. ACL limits access to
    # local administrators and SYSTEM; no plaintext password is written to disk.
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sidText in @('S-1-5-18','S-1-5-32-544')) {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit, ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $root -AclObject $acl
    if ([IO.Path]::GetFullPath($root).TrimEnd('\') -notin $lockedRoots) {
        $stateLocks.Add([IO.File]::Open((Join-Path $root 'run.lock'),'OpenOrCreate','ReadWrite','None'))
    }
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing -and $existing.State -eq 'Running') { throw 'Maintenance started during setup. Wait for it to finish before reinstalling.' }
    if ($savedCredentialText) {
        [IO.File]::WriteAllText((Join-Path $root 'guest-credential.json'),$savedCredentialText,[Text.Encoding]::UTF8)
    } else {
        $bytes = [Text.Encoding]::Unicode.GetBytes($guest.GetNetworkCredential().Password)
        try {
            $encrypted = [Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
            [ordered]@{ UserName=$guest.UserName; Password=[Convert]::ToBase64String($encrypted) } |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'guest-credential.json') -Encoding UTF8
        } finally { [Array]::Clear($bytes,0,$bytes.Length) }
    }
    [ordered]@{ VMName=$vm.Name; VMId=$vm.Id.ToString(); TaskName=$taskName; ScriptDirectory=$PSScriptRoot; Checkpoint=$CheckpointName; Schedule="$ScheduledTime daily" } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'config.json') -Encoding UTF8
    $script = Join-Path $PSScriptRoot 'Nightly-Update.ps1'
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`" -Root `"$root`"" -WorkingDirectory $PSScriptRoot
    $trigger = New-ScheduledTaskTrigger -Daily -At $ScheduledTime
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    # Do not catch up in daytime after a missed night. Hardware/power policy
    # must support wake timers. StartWhenAvailable intentionally remains false.
    $settings = New-ScheduledTaskSettingsSet -WakeToRun -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 5)
    Register-ScheduledTask -TaskName $taskName -Description "Maintain '$VMName' daily at ${ScheduledTime}: install offered Windows updates including feature upgrades, drivers, and optional updates, reboot, clean superseded components with DISM ResetBase, shut down, then replace checkpoint '$CheckpointName'. Skip a VM already in use. Log failures and preserve the old checkpoint." -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    $installed = Get-ScheduledTask -TaskName $taskName
    if ($installed.State -eq 'Disabled') { throw 'Scheduled task was installed but is disabled.' }
    Write-Host ''
    Write-Host 'INSTALLED. No maintenance run has been started now.' -ForegroundColor Green
    Write-Host "Task: $taskName"
    Write-Host "Checkpoint: $CheckpointName"
    Write-Host "Scripts: $PSScriptRoot (keep this folder in place)"
    Write-Host "Next run: $((Get-ScheduledTaskInfo -TaskName $taskName).NextRunTime)"
    Write-Host "Logs: $root\Logs\latest.json"
    Write-Host 'Guest credentials will be checked at the first run; setup does not start the VM.'
    Write-Host 'The host must be on or able to wake, plugged into AC, and the guest must reach its update service.'
    Write-Host 'If the guest password changes, run this installer again.'
    $exitCode = 0
} catch {
    Write-Host "SETUP FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
} finally {
    try {
        foreach ($stateLock in $stateLocks) { $stateLock.Dispose() }
    } finally {
        if ($vmMutex) { Exit-VMUpdateMutex $vmMutex }
    }
}
if (-not $NoPause) {
    Write-Host 'Press any key to continue...' -NoNewline
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    Write-Host
}
exit $exitCode
