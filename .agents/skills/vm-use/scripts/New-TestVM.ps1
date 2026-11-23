#Requires -Version 5.1
# Creates a test VM in one run: checks that it can be created, works out its
# names and (for DVMS) the build, runs the matching creation script, starts
# the VM, signs in on its console and arms parking.
#
#   -Kind Clean|DVMS9|DVMS10   what to create; Clean is the default
#   -TemplateName <template>   default: Windows 11 Template, or the only template
#   -Ticket MS-1234            puts the Jira key into the VM and computer names
#   -Plan                      prints what would be created and changes nothing
#
# Everything else has a default and can be overridden: -Name, -ComputerName,
# -Destination, -Version, -Installer, -LicensePath. -NoStart leaves the VM as
# the creation script leaves it; -NoSignIn starts it without the console sign-in.
# Run through Invoke-Elevated.ps1.
#
# Exit codes: 0 done (or plan printed), 1 nothing usable was created,
# 2 the VM was created but could not be started or signed in to.
[CmdletBinding()]
param(
    [ValidateSet('Clean','DVMS9','DVMS10')][string]$Kind = 'Clean',
    [string]$TemplateName,
    [string]$Ticket,
    [string]$Name,
    [string]$ComputerName,
    [string]$Destination,
    [string]$Version,
    [string]$Installer,
    [string]$LicensePath,
    [string]$BuildRoot = '\\rdfileserver\builds\DVMS',
    [string]$DestinationRoot = 'A:\VMs',
    [switch]$NoStart,
    [switch]$NoSignIn,
    [switch]$Plan
)
$ErrorActionPreference='Stop'
$exitCode=1
try {
    . (Join-Path $PSScriptRoot 'VM-Use.ps1')
    $dvms=$Kind -ne 'Clean'

    # Template: the one named, else Windows 11 Template, else the only one.
    $templates=@(Get-VMUseTemplates)
    if (-not $templates.Count) { throw 'This host has no template VM. Name a VM "... Template" and run VM-NightlyUpdate\Install.cmd for it.' }
    if (-not $TemplateName) {
        if (@($templates | Where-Object Name -EQ 'Windows 11 Template').Count) { $TemplateName='Windows 11 Template' }
        elseif ($templates.Count -eq 1) { $TemplateName=$templates[0].Name }
        else { throw "Say which template to copy with -TemplateName: $(($templates | ForEach-Object Name) -join ', ')." }
    }
    $template=@($templates | Where-Object Name -EQ $TemplateName)[0]
    if (-not $template) { throw "There is no template named '$TemplateName'. Templates: $(($templates | ForEach-Object Name) -join ', ')." }
    if (-not $template.Ready) { throw "Template '$TemplateName' is not ready to copy: $($template.Problems)." }

    if ($Ticket) {
        if ($Ticket -notmatch '^[A-Za-z][A-Za-z0-9]*-\d+$') { throw "'$Ticket' is not a Jira key such as MS-1234." }
        $Ticket=$Ticket.ToUpperInvariant()
    }

    # DVMS: the build, its installer and the license.
    $build=$null
    if ($dvms) {
        . (Join-Path $VMUseRepository 'VM-DVMS\DVMS-Build.ps1')
        if (-not $Version) {
            if ($Kind -eq 'DVMS10') { $Version='main' }
            else {
                $latest=Get-DVMSBuildVersions $BuildRoot | Where-Object Version -Match '^release-v9\.' | Sort-Object Updated -Descending | Select-Object -First 1
                if (-not $latest) { throw "No release-v9.* version with an installer was found under $BuildRoot. Name one with -Version." }
                $Version=$latest.Version
            }
        }
        $installers=@(Get-DVMSInstallers -BuildRoot $BuildRoot -Version $Version)
        if (-not $installers.Count) { throw "Version '$Version' has no DVMS installer under $BuildRoot. A build may still be publishing; look again later." }
        if (-not $Installer) { $Installer=$installers[0].Name }
        elseif (-not @($installers | Where-Object Name -EQ $Installer).Count) { throw "Installer '$Installer' is not in version '$Version'. It has: $(($installers | ForEach-Object Name) -join ', ')." }
        if ($Kind -eq 'DVMS10' -and -not (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $BuildRoot $Version) 'scripts') 'install.cmd') -PathType Leaf)) {
            throw "Version '$Version' has no scripts\install.cmd under $BuildRoot, which DVMS v10 needs. A build may still be publishing; look again later, or ask the user."
        }
        if (-not $LicensePath) { $LicensePath=Join-Path $VMUseRepository 'VM-DVMS\License.lic' }
        if (-not (Test-Path -LiteralPath $LicensePath -PathType Leaf)) { throw "License file not found: $LicensePath. Ask the user for the path of a license file and pass it as -LicensePath." }
        $LicensePath=(Resolve-Path -LiteralPath $LicensePath).ProviderPath
        $build=($Version -replace '^release-','')
    }

    # Names: '<template> Test [<ticket>] [<build>]', and a computer name with the ticket.
    $base=((($TemplateName -replace '\s*\bTemplate\b','').Trim())+' Test').Trim()
    if (-not $Name) { $Name=(@($base,$Ticket,$build) | Where-Object { $_ }) -join ' ' }
    $existing=@(Get-VM | Where-Object Name -EQ $Name)
    if ($existing.Count) { throw "A VM named '$Name' already exists ($($existing[0].State)). Use that VM, or pass another -Name." }
    if (-not $ComputerName) {
        if ($Ticket) {
            $ComputerName=(ConvertTo-GuestComputerName ($TemplateName -replace '\s*\bTemplate\b',''))+'-'+($Ticket -replace '-','')
            if ($ComputerName.Length -gt 15) { $ComputerName=$ComputerName.Substring(0,15).TrimEnd('-') }
        } else { $ComputerName=ConvertTo-GuestComputerName $Name }
    }
    if (-not (Test-GuestComputerName $ComputerName)) { throw "'$ComputerName' is not a valid Windows computer name: up to 15 letters, digits and hyphens. Pass -ComputerName." }
    if (-not $Destination) { $Destination=Join-Path $DestinationRoot $Name }
    if (Test-Path -LiteralPath $Destination) { throw "The folder already exists: $Destination. Pass another -Destination or -Name." }
    $drive=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Destination))
    $freeGB=(New-Object IO.DriveInfo $drive).AvailableFreeSpace/1GB
    # The DVMS scripts check their own, larger need.
    $neededGB=$template.SizeGB+5
    if ($freeGB -lt $neededGB) { throw ("Drive {0} has {1:N0} GB free; a copy of '{2}' needs about {3:N0} GB." -f $drive,$freeGB,$TemplateName,$neededGB) }

    $kindText=switch ($Kind) { 'Clean' { 'clean Windows, nothing else installed' } 'DVMS9' { "DVMS $Version ($Installer)" } 'DVMS10' { "DVMS v10 $Version ($Installer) with microservices and recorder proxy" } }
    $after=if ($NoStart) { 'left as the creation script leaves it' } elseif ($NoSignIn) { 'started, parking armed' } else { 'started, signed in on the console, parking armed' }
    Write-Host $(if ($Plan) { 'PLAN (nothing is created):' } else { 'Creating:' })
    Write-Host "  VM:            $Name"
    Write-Host "  Kind:          $kindText"
    Write-Host "  Template:      $TemplateName (checkpoint '$($template.Checkpoint)', $($template.SizeGB) GB)"
    Write-Host "  Computer name: $ComputerName"
    Write-Host ("  Folder:        {0} ({1:N0} GB free on {2})" -f $Destination,$freeGB,$drive)
    if ($dvms) { Write-Host "  License:       $LicensePath" }
    Write-Host "  Afterwards:    $after"
    if ($Plan) { exit 0 }

    $parameters=@{TemplateName=$TemplateName;Name=$Name;Destination=$Destination;ComputerName=$ComputerName;NoPause=$true}
    $script=Join-Path $VMUseRepository 'VM-NightlyUpdate\Create-VM.ps1'
    if ($dvms) {
        $parameters.Version=$Version; $parameters.Installer=$Installer; $parameters.LicensePath=$LicensePath; $parameters.BuildRoot=$BuildRoot
        $script=if ($Kind -eq 'DVMS10') { Join-Path $VMUseRepository 'VM-DVMS-v10\New-VM-DVMS-v10.ps1' } else { Join-Path $VMUseRepository 'VM-DVMS\New-VM-DVMS.ps1' }
    }
    Write-Host ''
    $global:LASTEXITCODE=0
    & $script @parameters
    if ($LASTEXITCODE -ne 0) { throw "The creation script ended with exit code $LASTEXITCODE; its message is above. Nothing was deleted: look at what it left before trying again." }

    $vm=Get-VMUseVM $Name
    $state=''
    if (-not $NoStart) {
        $exitCode=2
        $vm=Start-VMUseVM -VM $vm
        $credential=Get-VMUseCredential -VM $vm -TemplateName $TemplateName
        $state="Running, parks at $((Get-VMUsePark -VM $vm).ToString('HH:mm')) unless used"
        if (-not $NoSignIn) {
            $user=Connect-VMUseConsole -VM $vm -Credential $credential
            $state="Running, signed in on the console as $user, parks at $((Get-VMUsePark -VM $vm).ToString('HH:mm')) unless used"
        }
    } else { $state=[string](Get-VM -Id $vm.Id).State }
    Write-Host ''
    Write-Host "TEST VM READY: $Name"
    Write-Host "  Kind:          $kindText"
    Write-Host "  Template:      $TemplateName (checkpoint '$($template.Checkpoint)')"
    Write-Host "  Computer name: $ComputerName"
    Write-Host "  Folder:        $Destination"
    Write-Host "  State:         $state"
    $exitCode=0
} catch {
    if ($exitCode -eq 2) { Write-Host "VM CREATED, BUT NOT READY: $($_.Exception.Message)" }
    else { Write-Host "NEW VM FAILED: $($_.Exception.Message)" }
}
exit $exitCode
