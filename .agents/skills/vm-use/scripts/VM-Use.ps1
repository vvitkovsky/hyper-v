#Requires -Version 5.1
# Functions for scripts that work with a test VM. Dot-source this file in a
# script that is run through Invoke-Elevated.ps1: Hyper-V and the templates'
# saved state need an administrator and Windows PowerShell 5.1.
#
# It also loads this repository's own helpers from VM-NightlyUpdate, among them
# Invoke-VMGuestCommand (a guest command with a timeout) and Wait-VMGuest.
Import-Module Hyper-V
Add-Type -AssemblyName System.Security
# <repository>\.agents\skills\vm-use\scripts
$VMUseRepository=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$VMUseNightlyUpdate=Join-Path $VMUseRepository 'VM-NightlyUpdate'
foreach ($file in @('Maintenance-Common.ps1','Credential-Input.ps1','VM-Registration.ps1','Template-Clone.ps1')) { . (Join-Path $VMUseNightlyUpdate $file) }

function Get-VMUseVM {
    # The one VM with this exact name. Keep the object and address the VM by
    # its Id afterwards, so a second VM with the same name cannot be picked up.
    param([Parameter(Mandatory=$true)][string]$Name)
    $found=@(Get-VM | Where-Object Name -EQ $Name)
    if ($found.Count -ne 1) { throw "Expected exactly one VM named '$Name'; found $($found.Count)." }
    $found[0]
}

function Get-VMUseDiskBytes {
    # Bytes on the host of every disk file of a VM, checkpoints included.
    param([Parameter(Mandatory=$true)]$VM)
    $drives=@(Get-VMHardDiskDrive -VM $VM) + @(Get-VMSnapshot -VM $VM | ForEach-Object { Get-VMHardDiskDrive -VMSnapshot $_ })
    $bytes=[long]0; $seen=@{}
    foreach ($drive in $drives) {
        $path=$drive.Path
        while ($path -and -not $seen.ContainsKey($path)) {
            $seen[$path]=$true
            $vhd=Get-VHD -Path $path -ErrorAction SilentlyContinue
            if (-not $vhd) { break }
            $bytes+=$vhd.FileSize; $path=$vhd.ParentPath
        }
    }
    $bytes
}

function Get-VMUseTemplates {
    # The templates, as the creation scripts list them: every VM with
    # "Template" in its name, and every VM with nightly updates installed. For
    # each, whether it passes the checks those scripts make before copying.
    $installations=@(Get-VMUpdateInstallations -BaseDirectory $VMUseNightlyUpdate)
    foreach ($candidate in @(Get-TemplateCandidates -Installations $installations)) {
        $vm=$candidate.VM; $installation=$candidate.Installation
        $checkpoint=if ($installation) { $installation.Checkpoint } else { 'clean' }
        $credentialPath=if ($installation) { Join-Path $installation.Root 'guest-credential.json' } else { $null }
        $problems=@()
        if (-not $vm) { $problems+='the VM no longer exists' }
        else {
            if ($vm.State -ne 'Off') { $problems+="it is $($vm.State) and must be Off" }
            $count=@(Get-VMSnapshot -VM $vm | Where-Object Name -EQ $checkpoint).Count
            if ($count -ne 1) { $problems+="it has $count '$checkpoint' checkpoints and needs exactly one" }
            if (@(Get-VM | Where-Object Name -EQ $vm.Name).Count -ne 1) { $problems+='another VM has the same name' }
        }
        if (-not $installation) { $problems+='VM-NightlyUpdate\Install.cmd was not run for it, so it has no saved guest credential' }
        elseif (-not (Test-Path -LiteralPath $credentialPath)) { $problems+='no guest credential is saved' }
        [pscustomobject]@{
            # The scripts find a template by its current name.
            Name=$candidate.Name
            Id=$candidate.Id
            Installed=[bool]$installation
            Checkpoint=$checkpoint
            NightlyUpdate=$(if ($installation) { $installation.Time } else { $null })
            State=$(if ($vm) { [string]$vm.State } else { 'missing' })
            SizeGB=$(if ($vm) { [math]::Round((Get-VMUseDiskBytes $vm)/1GB,1) } else { $null })
            Ready=(-not $problems.Count)
            Problems=($problems -join '; ')
            CredentialPath=$credentialPath
        }
    }
}

function Get-VMUseCredential {
    # The guest administrator credential for a running test VM. Copies keep the
    # Windows account of their template, so this is the credential saved for a
    # template by Install.cmd. Without -TemplateName every installed template's
    # credential is tried. A user name saved as COMPUTER\user is also tried as
    # plain user, because the copy has its own computer name.
    # A credential the guest rejects is tried once only.
    param([Parameter(Mandatory=$true)]$VM,[string]$TemplateName,[int]$TimeoutMinutes=10)
    $vm=Get-VM -Id $VM.Id
    if ($vm.State -ne 'Running') { throw "VM '$($vm.Name)' is $($vm.State); start it before asking for its credential." }
    $templates=@(Get-VMUseTemplates | Where-Object { $_.CredentialPath -and (Test-Path -LiteralPath $_.CredentialPath) })
    if ($TemplateName) {
        $templates=@($templates | Where-Object Name -EQ $TemplateName)
        if (-not $templates.Count) { throw "No saved guest credential for template '$TemplateName'. Run VM-NightlyUpdate\Install.cmd for it." }
    } elseif (-not $templates.Count) { throw 'No template has a saved guest credential. Run VM-NightlyUpdate\Install.cmd for a template first.' }
    $candidates=@(foreach ($template in @($templates | Sort-Object @{Expression={$_.Name -ne 'Windows 11 Template'}},Name)) {
        $saved=Read-SavedVMGuestCredential -Path $template.CredentialPath
        [pscustomobject]@{Credential=$saved;Template=$template.Name;Rejected=$false}
        if ($saved.UserName -match '^[^\\]+\\(.+)$') {
            [pscustomobject]@{Credential=[Management.Automation.PSCredential]::new($Matches[1],$saved.Password);Template=$template.Name;Rejected=$false}
        }
    })
    # Windows is reachable shortly after the heartbeat service reports in.
    $deadline=(Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-VM -Id $vm.Id).Heartbeat -notlike 'Ok*' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
    $lastError=''
    do {
        foreach ($candidate in @($candidates | Where-Object { -not $_.Rejected })) {
            try {
                Invoke-VMGuestCommand -VMId $vm.Id -Credential $candidate.Credential -Script { $env:COMPUTERNAME } | Out-Null
                return $candidate.Credential
            } catch {
                $lastError=$_.Exception.Message
                if ($lastError -match 'credential') { $candidate.Rejected=$true }
            }
        }
        if (-not @($candidates | Where-Object { -not $_.Rejected }).Count) { break }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    $tried=(@($candidates | ForEach-Object { "$($_.Credential.UserName) (from $($_.Template))" }) -join ', ')
    throw "No saved template credential works for '$($vm.Name)'. Tried: $tried. Last error: $lastError"
}

function Stop-VMUseGuest {
    # Shuts Windows down from inside and waits for Off. A locked guest rejects
    # Hyper-V's own shutdown request, and a forced power-off risks its disks.
    param([Parameter(Mandatory=$true)]$VM,[Parameter(Mandatory=$true)][Management.Automation.PSCredential]$Credential,[int]$TimeoutMinutes=15)
    try {
        Invoke-VMGuestCommand -VMId $VM.Id -Credential $Credential -Script { & "$env:SystemRoot\System32\shutdown.exe" /s /t 0 } | Out-Null
    } catch { Write-Verbose 'Shutdown command disconnected; waiting for Windows to turn off.' }
    $deadline=(Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-VM -Id $VM.Id).State -ne 'Off') {
        if ((Get-Date) -ge $deadline) { throw "Windows in '$($VM.Name)' did not shut down within $TimeoutMinutes minutes." }
        Start-Sleep -Seconds 5
    }
}
