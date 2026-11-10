#Requires -Version 5.1
function Copy-VMTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$TemplateName,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter(Mandatory=$true)][string]$Destination,
        [ValidateNotNullOrEmpty()][string]$CheckpointName = 'clean'
    )
    $ErrorActionPreference='Stop'
    $mutex=$null; $copy=$null; $created=$false
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Supply a nonempty VM name.' }
    if ($Destination -notmatch '^[A-Za-z]:\\') { throw 'Destination must be an absolute local folder, for example A:\VMs\Test.' }
    $target=[IO.Path]::GetFullPath($Destination).TrimEnd('\')
    if ($target.Length -le 3) { throw 'Choose a dedicated folder, not a drive root.' }
    function Assert-InDestination([string]$Path) {
        $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
        if ($full -ne $target -and -not $full.StartsWith($target+'\',[StringComparison]::OrdinalIgnoreCase)) {
            throw "Copied VM still references files outside its destination: $full"
        }
    }
    try {
        $matches=@(Get-VM | Where-Object Name -EQ $TemplateName)
        if ($matches.Count -ne 1) { throw "Expected exactly one template VM named '$TemplateName'." }
        $template=$matches[0]
        $mutex=Enter-VMUpdateMutex -VMId $template.Id
        $template=Get-VM -Id $template.Id
        if ($template.State -ne 'Off') { throw 'Shut down the template and wait for maintenance to finish before copying.' }
        if (@(Get-VM | Where-Object Name -EQ $Name).Count) { throw "A VM named '$Name' already exists." }
        $checkpoints=@(Get-VMSnapshot -VM $template)
        if (@($checkpoints | Where-Object Name -EQ $CheckpointName).Count -ne 1) { throw "Template must contain exactly one '$CheckpointName' checkpoint." }
        $source=[IO.Path]::GetFullPath($template.ConfigurationLocation).TrimEnd('\')
        if ($target -eq $source -or $target.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase) -or $source.StartsWith($target+'\',[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Copy destination must be separate from the template folder.'
        }
        if (Test-Path -LiteralPath $target) { throw "Destination already exists; choose a new folder: $target" }
        $ancestor=$target
        while ($ancestor) {
            if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Destination contains a reparse point.' }
            $ancestor=[IO.Path]::GetDirectoryName($ancestor)
        }
        $config=Join-Path $source ("Virtual Machines\{0}.vmcx" -f $template.Id)
        if (-not (Test-Path -LiteralPath $config)) { $config=Join-Path $source ($template.Id.ToString()+'.vmcx') }
        if (-not (Test-Path -LiteralPath $config)) { throw 'Template VM configuration file could not be located.' }
        $arguments=@{Path=$config;Copy=$true;GenerateNewId=$true;VirtualMachinePath=$target;
            VhdDestinationPath=(Join-Path $target 'Virtual Hard Disks');SnapshotFilePath=$target;SmartPagingFilePath=$target;ErrorAction='Stop'}
        # Reserve our new folder first: Compare-VM can create destination
        # directories while preparing its compatibility report.
        New-Item -ItemType Directory -Path $target -ErrorAction Stop | Out-Null
        $created=$true
        $report=Compare-VM @arguments
        if (@($report.Incompatibilities).Count) { throw ('Import compatibility check failed: '+(($report.Incompatibilities | ForEach-Object Message) -join '; ')) }
        $copy=Import-VM -CompatibilityReport $report -ErrorAction Stop
        if (-not $copy -or $copy.Id -eq $template.Id) { throw 'Import did not create an independent VM identity.' }
        Rename-VM -VM $copy -NewName $Name -ErrorAction Stop
        Set-VM -VM $copy -AutomaticStartAction Nothing -AutomaticCheckpointsEnabled $false -ErrorAction Stop
        $copy=Get-VM -Id $copy.Id
        if ($copy.State -ne 'Off') { throw 'Imported VM is unexpectedly running.' }
        Assert-InDestination $copy.ConfigurationLocation
        $copiedSnapshots=@(Get-VMSnapshot -VM $copy)
        if ($copiedSnapshots.Count -ne $checkpoints.Count -or @($copiedSnapshots | Where-Object Name -EQ $CheckpointName).Count -ne 1) { throw 'Imported checkpoint tree does not match the template.' }
        $drives=@(Get-VMHardDiskDrive -VM $copy)
        foreach ($snapshot in $copiedSnapshots) { $drives+=@(Get-VMHardDiskDrive -VMSnapshot $snapshot) }
        if (-not $drives.Count) { throw 'Imported VM has no virtual disks.' }
        $seen=@{}
        foreach ($drive in $drives) {
            $path=$drive.Path
            while ($path -and -not $seen.ContainsKey($path)) {
                Assert-InDestination $path
                if (-not (Test-VHD -Path $path -ErrorAction Stop)) { throw "Copied disk failed validation: $path" }
                $seen[$path]=$true
                $path=(Get-VHD -Path $path -ErrorAction Stop).ParentPath
            }
        }
        [pscustomobject]@{Name=$copy.Name;Id=$copy.Id;Path=$target;Checkpoint=$CheckpointName;State=$copy.State}
    } catch {
        if ($created) { Write-Warning "Copy did not finish validation. Files retained at '$target' for inspection; no files were deleted. Imported VM ID: $($copy.Id)" }
        throw
    } finally { if ($mutex) { Exit-VMUpdateMutex $mutex } }
}

function ConvertTo-GuestComputerName([string]$VMName) {
    # 'Windows 11 Test 2' becomes 'WIN11-Test-2' and 'Windows Server 2025 Test'
    # becomes 'WS2025-Test'; Windows allows 15 characters.
    $candidate=((($VMName -replace '^\s*Windows\s*Server\s*(\d+)','WS$1') -replace '^\s*Windows\s*(\d+)','WIN$1') -replace '[^A-Za-z0-9]+','-').Trim('-')
    if ($candidate.Length -gt 15) { $candidate=$candidate.Substring(0,15).TrimEnd('-') }
    $candidate
}

function Test-GuestComputerName([string]$ComputerName) {
    # Letters, digits and inner hyphens; not purely numeric.
    $ComputerName -match '^(?![0-9]+$)(?!-)[A-Za-z0-9-]{1,15}(?<!-)$'
}

function Get-TemplateVM([string]$TemplateName) {
    $found=@(Get-VM | Where-Object Name -EQ $TemplateName)
    if ($found.Count -eq 0) { throw "Template VM '$TemplateName' was not found. Create and install it with VM-NightlyUpdate first." }
    if ($found.Count -gt 1) { throw "More than one VM is named '$TemplateName'; rename the extra VM first." }
    $found[0]
}

function Get-TemplateGuestCredential {
    # Needs VM-Registration.ps1, Credential-Input.ps1 and System.Security loaded.
    param([Parameter(Mandatory=$true)][string]$TemplateName,[Parameter(Mandatory=$true)][string]$BaseDirectory)
    $registration=Get-VMUpdateRegistration -VMName $TemplateName -BaseDirectory $BaseDirectory
    $path=Join-Path $registration.Root 'guest-credential.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "No saved guest credentials for '$TemplateName'. Run Install.cmd for the template." }
    Read-SavedVMGuestCredential -Path $path
}

function Read-TemplateCopySettings {
    # Values left empty are prompted for; Enter accepts each default.
    param([string]$Name,[string]$Destination,[string]$ComputerName,[switch]$KeepComputerName,[string]$DefaultName='Windows 11 Test')
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $entered=(Read-Host "New VM name [$DefaultName]").Trim()
        $Name=if ([string]::IsNullOrWhiteSpace($entered)) { $DefaultName } else { $entered }
    }
    if ([string]::IsNullOrWhiteSpace($Destination)) {
        if ($Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $Name.EndsWith('.') -or $Name.EndsWith(' ') -or $Name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw 'This VM name cannot be used as a folder name. Choose another name or supply -Destination explicitly.'
        }
        $default=Join-Path 'A:\VMs' $Name
        $entered=(Read-Host "Destination [$default]").Trim()
        $Destination=if ([string]::IsNullOrWhiteSpace($entered)) { $default } else { $entered }
    }
    if (-not $KeepComputerName) {
        if ([string]::IsNullOrWhiteSpace($ComputerName)) {
            $default=ConvertTo-GuestComputerName $Name
            $entered=(Read-Host "Windows computer name [$default]").Trim()
            $ComputerName=if ([string]::IsNullOrWhiteSpace($entered)) { $default } else { $entered }
        }
        if (-not (Test-GuestComputerName $ComputerName)) { throw "'$ComputerName' is not a valid Windows computer name: use up to 15 letters, digits and hyphens." }
    }
    [pscustomobject]@{Name=$Name;Destination=$Destination;ComputerName=$(if ($KeepComputerName) { $null } else { $ComputerName })}
}

function Invoke-VMGuestCommand {
    param(
        [Parameter(Mandatory=$true)][guid]$VMId,
        [Parameter(Mandatory=$true)][Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory=$true)][scriptblock]$Script,
        [object[]]$Arguments=@(),
        [int]$TimeoutSeconds=60
    )
    # PowerShell Direct can stall during boot; bound every call.
    $job=Invoke-Command -VMId $VMId -Credential $Credential -ScriptBlock $Script -ArgumentList $Arguments -AsJob
    try {
        if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) { throw "Guest command timed out after $TimeoutSeconds seconds." }
        Receive-Job -Job $job -ErrorAction Stop
        if ($job.State -ne 'Completed') { throw "Guest command ended in state $($job.State)." }
    } finally { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
}

function Wait-VMGuest {
    # Returns the guest's computer name and boot time once it differs from PreviousBoot.
    param(
        [Parameter(Mandatory=$true)][guid]$VMId,
        [Parameter(Mandatory=$true)][Management.Automation.PSCredential]$Credential,
        [string]$PreviousBoot='',
        [Parameter(Mandatory=$true)][datetime]$Deadline
    )
    $lastFailure=''
    do {
        try {
            $guest=Invoke-VMGuestCommand -VMId $VMId -Credential $Credential -Script {
                [pscustomobject]@{Name=$env:COMPUTERNAME;Boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')}
            }
            if ($guest -and $guest.Boot -ne $PreviousBoot) { return $guest }
        } catch {
            if ($_.Exception.Message -ne $lastFailure) { $lastFailure=$_.Exception.Message; Write-Verbose "Guest not ready: $lastFailure" }
        }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $Deadline)
    throw "Windows did not become reachable through PowerShell Direct by $($Deadline.ToString('HH:mm:ss'))."
}

function Set-VMCopyComputerName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][guid]$VMId,
        [Parameter(Mandatory=$true)][string]$ComputerName,
        [Parameter(Mandatory=$true)][Management.Automation.PSCredential]$Credential,
        [ValidateNotNullOrEmpty()][string]$CheckpointName = 'clean',
        [int]$TimeoutMinutes = 20,
        # Optional extra guest step, run before the checkpoint is refreshed so
        # the checkpoint includes its result.
        [scriptblock]$GuestSetup,
        [object[]]$GuestSetupArguments = @()
    )
    $ErrorActionPreference='Stop'
    if (-not (Test-GuestComputerName $ComputerName)) { throw "'$ComputerName' is not a valid Windows computer name: use up to 15 letters, digits and hyphens." }
    $deadline=(Get-Date).AddMinutes($TimeoutMinutes)
    function Invoke-CopyGuest([Management.Automation.PSCredential]$Login,[scriptblock]$Script,[object[]]$Arguments=@()) {
        Invoke-VMGuestCommand -VMId $VMId -Credential $Login -Script $Script -Arguments $Arguments
    }
    function Wait-CopyGuest([Management.Automation.PSCredential]$Login,[string]$PreviousBoot='') {
        Wait-VMGuest -VMId $VMId -Credential $Login -PreviousBoot $PreviousBoot -Deadline $deadline
    }
    $vm=Get-VM -Id $VMId
    if ($vm.State -ne 'Off') { throw 'The copied VM must be off before its computer name is changed.' }
    $original=@(Get-VMSnapshot -VM $vm | Where-Object Name -EQ $CheckpointName)
    if ($original.Count -ne 1) { throw "The copied VM must contain exactly one '$CheckpointName' checkpoint." }
    Write-Host "Starting '$($vm.Name)' to set its Windows computer name to $ComputerName..."
    Start-VM -VM $vm
    $guest=Wait-CopyGuest $Credential
    if ($guest.Name -ne $ComputerName) {
        $previousName=$guest.Name
        Invoke-CopyGuest $Credential {
            param($NewName)
            Rename-Computer -NewName $NewName -Force -WarningAction SilentlyContinue
        } @($ComputerName) | Out-Null
        # The new name takes effect after a restart. The restart can drop the
        # connection before it replies; a new boot timestamp confirms it.
        try {
            Invoke-CopyGuest $Credential {
                & "$env:SystemRoot\System32\shutdown.exe" /r /t 0
                if ($LASTEXITCODE -ne 0) { throw "Restart request failed: $LASTEXITCODE" }
            } | Out-Null
        } catch { Write-Verbose 'Restart command disconnected or failed; waiting for a confirmed new boot.' }
        # A local account qualified with the old computer name must use the new one.
        $login=$Credential
        if ($Credential.UserName -match '^([^\\]+)\\(.+)$' -and $Matches[1] -eq $previousName) {
            $login=[Management.Automation.PSCredential]::new("$ComputerName\$($Matches[2])",$Credential.Password)
        }
        $guest=Wait-CopyGuest $login $guest.Boot
        if ($guest.Name -ne $ComputerName) { throw "Windows reports computer name '$($guest.Name)' after restart; expected '$ComputerName'." }
    } else { $login=$Credential }
    if ($GuestSetup) { Invoke-VMGuestCommand -VMId $VMId -Credential $login -Script $GuestSetup -Arguments $GuestSetupArguments -TimeoutSeconds 600 | Out-Null }
    Write-Host 'Computer name set. Shutting down Windows to refresh the checkpoint...'
    try {
        Invoke-CopyGuest $login {
            & "$env:SystemRoot\System32\shutdown.exe" /s /t 0
            if ($LASTEXITCODE -ne 0) { throw "Shutdown request failed: $LASTEXITCODE" }
        } | Out-Null
    } catch { Write-Verbose 'Shutdown command disconnected or failed; waiting for Windows to turn off.' }
    $shutdownDeadline=(Get-Date).AddMinutes(15)
    do {
        $vm=Get-VM -Id $VMId
        if ($vm.State -eq 'Off') { break }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $shutdownDeadline)
    if ($vm.State -ne 'Off') { throw 'Windows did not shut down within 15 minutes; the checkpoint was not refreshed.' }
    # Reverting to the copied checkpoint would restore the template's computer
    # name. The copy is new, so the renamed state replaces it with no other loss.
    $candidateName=$CheckpointName+'.renamed-'+[guid]::NewGuid().ToString('N')
    Checkpoint-VM -VM $vm -SnapshotName $candidateName | Out-Null
    $vm=Get-VM -Id $VMId
    $created=@(Get-VMSnapshot -VM $vm | Where-Object Name -EQ $candidateName)
    if ($created.Count -ne 1) { throw "Renamed checkpoint could not be verified; '$CheckpointName' still has the template's computer name." }
    $original[0] | Remove-VMSnapshot -Confirm:$false
    $created[0] | Rename-VMSnapshot -NewName $CheckpointName
    $vm=Get-VM -Id $VMId
    if (-not (Get-VMSnapshot -VM $vm | Where-Object { $_.Id -eq $created[0].Id -and $_.Name -eq $CheckpointName })) {
        throw "Checkpoint '$CheckpointName' could not be verified after the rename."
    }
    $ComputerName
}
