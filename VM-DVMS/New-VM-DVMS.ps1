#Requires -Version 5.1
#Requires -PSEdition Desktop
# Creates a VM from the maintained template, binds a DVMS license to its MAC
# address and installs a DVMS build from the build share silently.
[CmdletBinding()]
param(
    [string]$Name,
    [string]$Destination,
    [string]$ComputerName,
    [string]$Version,
    [string]$Installer,
    [string]$LicensePath,
    [string]$TemplateName = 'Windows 11 Template',
    [string]$CheckpointName = 'clean',
    [string]$BuildRoot = '\\rdfileserver\builds\DVMS',
    [string]$LegacyRepository = 'A:\src\legacy',
    [string]$InstallerArguments = '/i /q /norestart',
    [int]$InstallTimeoutMinutes = 120,
    [switch]$NoPause
)
$ErrorActionPreference='Stop'
$isAdmin=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $command="& '"+$PSCommandPath.Replace("'","''")+"'"
    foreach ($parameter in $PSBoundParameters.Keys) {
        if ($parameter -eq 'NoPause') { continue }
        $value=[string]$PSBoundParameters[$parameter]
        $command+=" -$parameter '"+$value.Replace("'","''")+"'"
    }
    if ($NoPause) { $command+=' -NoPause' }
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    exit $process.ExitCode
}
$guestSetup='C:\DVMSSetup'
$exitCode=1
try {
    Import-Module Hyper-V
    Add-Type -AssemblyName System.Security
    $nightlyUpdate=Join-Path (Split-Path -Parent $PSScriptRoot) 'VM-NightlyUpdate'
    foreach ($file in @('Maintenance-Common.ps1','Credential-Input.ps1','VM-Registration.ps1','Template-Clone.ps1')) { . (Join-Path $nightlyUpdate $file) }
    . (Join-Path $PSScriptRoot 'DVMS-License.ps1')
    . (Join-Path $PSScriptRoot 'DVMS-Build.ps1')

    # Ask everything first so the long copy and install run unattended.
    $template=Get-TemplateVM $TemplateName
    $credential=Get-TemplateGuestCredential -TemplateName $TemplateName -BaseDirectory $nightlyUpdate
    $settings=Read-TemplateCopySettings -Name $Name -Destination $Destination -ComputerName $ComputerName

    if ([string]::IsNullOrWhiteSpace($Version)) {
        Write-Host "Looking for DVMS builds in $BuildRoot..."
        $versions=@(Get-DVMSBuildVersions $BuildRoot | Sort-Object Updated -Descending)
        if (-not $versions.Count) { throw "No DVMS installers were found under $BuildRoot." }
        Write-Host 'Available versions (newest first):'
        foreach ($item in $versions) { Write-Host ("  {0,-30} {1:yyyy-MM-dd HH:mm}" -f $item.Version,$item.Updated) }
        $entered=(Read-Host 'DVMS version [main]').Trim()
        $Version=if ($entered) { $entered } else { 'main' }
    }
    $installers=@(Get-DVMSInstallers -BuildRoot $BuildRoot -Version $Version)
    if (-not $installers.Count) { throw "No DVMS installer was found in $(Join-Path $BuildRoot $Version)." }
    if ($Installer) {
        $selected=$installers | Where-Object Name -EQ $Installer | Select-Object -First 1
        if (-not $selected) { throw "Installer '$Installer' was not found in $(Join-Path $BuildRoot $Version)." }
    } elseif ($installers.Count -eq 1) { $selected=$installers[0] }
    else {
        Write-Host "Installers in ${Version}:"
        for ($index=0; $index -lt $installers.Count; $index++) {
            Write-Host ("  {0}. {1} ({2:N1} GB, {3:yyyy-MM-dd HH:mm})" -f ($index+1),$installers[$index].Name,($installers[$index].Length/1GB),$installers[$index].LastWriteTime)
        }
        $entered=(Read-Host 'Installer [1]').Trim()
        $choice=1
        if ($entered -and -not [int]::TryParse($entered,[ref]$choice)) { throw "Enter a number from 1 to $($installers.Count)." }
        if ($choice -lt 1 -or $choice -gt $installers.Count) { throw "Enter a number from 1 to $($installers.Count)." }
        $selected=$installers[$choice-1]
    }

    if ([string]::IsNullOrWhiteSpace($LicensePath)) {
        $default=Join-Path $PSScriptRoot 'License.lic'
        $entered=(Read-Host "License file [$default]").Trim().Trim('"')
        $LicensePath=if ($entered) { $entered } else { $default }
    }
    if (-not (Test-Path -LiteralPath $LicensePath -PathType Leaf)) { throw "License file not found: $LicensePath" }
    $keys=Get-DVMSLicenseKeys -Repository $LegacyRepository
    $license=Read-DVMSLicense -Path $LicensePath -PublicKey $keys.PublicKey
    if (-not $license.Macs.Count) { throw 'The license has no MAC protection entry to bind to the new VM.' }

    # Copy, guest installer and installed files all land on the VM's drive.
    $templateDisks=@(Get-VMHardDiskDrive -VM $template) + @(Get-VMSnapshot -VM $template | ForEach-Object { Get-VMHardDiskDrive -VMSnapshot $_ })
    $templateBytes=0; $seen=@{}
    foreach ($drive in $templateDisks) {
        $path=$drive.Path
        while ($path -and -not $seen.ContainsKey($path)) { $seen[$path]=$true; $vhd=Get-VHD -Path $path; $templateBytes+=$vhd.FileSize; $path=$vhd.ParentPath }
    }
    $needed=@{}
    $vmDrive=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($settings.Destination))
    $needed[$vmDrive]=$templateBytes+$selected.Length+10GB
    $cacheDirectory=Join-Path (Join-Path $PSScriptRoot '.cache') $Version
    $cacheDrive=[IO.Path]::GetPathRoot($cacheDirectory)
    $cachedFile=Get-Item -LiteralPath (Join-Path $cacheDirectory $selected.Name) -ErrorAction SilentlyContinue
    if (-not ($cachedFile -and $cachedFile.Length -eq $selected.Length -and $cachedFile.LastWriteTimeUtc -eq $selected.LastWriteTimeUtc)) {
        $needed[$cacheDrive]=[long]$needed[$cacheDrive]+$selected.Length
    }
    foreach ($drive in $needed.Keys) {
        $free=(New-Object IO.DriveInfo $drive).AvailableFreeSpace
        if ($free -lt $needed[$drive]) { throw ("Drive {0} has {1:N1} GB free; about {2:N1} GB is needed." -f $drive,($free/1GB),($needed[$drive]/1GB)) }
    }

    Write-Host ''
    Write-Host "New VM:         $($settings.Name)"
    Write-Host "Destination:    $($settings.Destination)"
    Write-Host "Computer name:  $($settings.ComputerName)"
    Write-Host "DVMS installer: $($selected.FullName)"
    Write-Host ("License:        {0} (product {1}, serial {2}, MACs {3})" -f $LicensePath,$license.Product,$license.SerialNumber,($license.Macs -join ', '))
    Write-Host ''

    $cached=Save-DVMSInstaller -Source $selected -CacheDirectory $cacheDirectory
    Write-Host "Copying template to $($settings.Destination), please wait..."
    $copy=Copy-VMTemplate -TemplateName $TemplateName -Name $settings.Name -Destination $settings.Destination -CheckpointName $CheckpointName
    $null=Set-VMCopyComputerName -VMId $copy.Id -ComputerName $settings.ComputerName -Credential $credential -CheckpointName $CheckpointName

    # The rename has started the VM once, so Hyper-V has assigned its MAC address.
    $vm=Get-VM -Id $copy.Id
    $adapters=@(Get-VMNetworkAdapter -VM $vm)
    if (-not $adapters.Count) { throw 'The VM has no network adapter, so the license cannot be bound to a MAC address.' }
    if ($adapters.Count -gt 1) { Write-Warning "The VM has $($adapters.Count) network adapters; the license uses '$($adapters[0].Name)'." }
    $mac=ConvertTo-LicenseMac $adapters[0].MacAddress
    # A dynamic address can change when the VM is moved or imported, which
    # would invalidate the license. Keep the assigned address fixed instead.
    if ($adapters[0].DynamicMacAddressEnabled) { Set-VMNetworkAdapter -VMNetworkAdapter $adapters[0] -StaticMacAddress ($mac -replace '-','') }
    $signed=Set-DVMSLicenseMac -Xml $license.Xml -MacAddress $mac -PrivateKey $keys.PrivateKey -PublicKey $keys.PublicKey
    $hostLicense=Join-Path $settings.Destination 'License.lic'
    [IO.File]::WriteAllText($hostLicense,$signed.Code,(New-Object Text.UTF8Encoding($false)))
    Write-Host "License bound to MAC $mac and verified: $hostLicense"

    Write-Host "Starting '$($vm.Name)'..."
    Start-VM -VM $vm
    $guest=Wait-VMGuest -VMId $vm.Id -Credential $credential -Deadline (Get-Date).AddMinutes(15)
    Invoke-VMGuestCommand -VMId $vm.Id -Credential $credential -Arguments @($signed.Code) -Script {
        param($Code)
        $folder=Join-Path $env:ProgramFiles 'DVMS\Licenses'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $folder 'License.lic'),$Code,(New-Object Text.UTF8Encoding($false)))
    } | Out-Null
    Write-Host 'License copied to C:\Program Files\DVMS\Licenses\License.lic in the VM.'

    # Copy-VMFile goes through the Guest Service Interface integration service.
    $guestService=Get-VMIntegrationService -VM $vm | Where-Object Name -EQ 'Guest Service Interface'
    if ($guestService -and -not $guestService.Enabled) { Enable-VMIntegrationService -VMIntegrationService $guestService }
    $guestInstaller=Join-Path $guestSetup $selected.Name
    Write-Host ("Copying the installer into the VM ({0:N1} GB)..." -f ($selected.Length/1GB))
    for ($attempt=1; ; $attempt++) {
        try { Copy-VMFile -VM $vm -SourcePath $cached -DestinationPath $guestInstaller -CreateFullPath -FileSource Host -Force; break }
        catch {
            # The guest service can take a moment to start after boot.
            if ($attempt -ge 6) { throw }
            Start-Sleep -Seconds 10
        }
    }

    $logPath=Join-Path $guestSetup 'DVMS-install.log'
    $arguments="$InstallerArguments /log `"$logPath`""
    Write-Host "Installing: $($selected.Name) $arguments"
    $started=Get-Date
    $job=Invoke-Command -VMId $vm.Id -Credential $credential -AsJob -ArgumentList $guestInstaller,$arguments -ScriptBlock {
        param($Path,$Arguments)
        (Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru).ExitCode
    }
    try {
        $reported=$started
        while (-not (Wait-Job -Job $job -Timeout 30)) {
            if ((Get-Date) -ge $started.AddMinutes($InstallTimeoutMinutes)) { throw "Installation did not finish within $InstallTimeoutMinutes minutes. The VM was left running for inspection." }
            if ((Get-Date) -ge $reported.AddMinutes(5)) { $reported=Get-Date; Write-Host ("  still installing ({0:N0} min)..." -f ((Get-Date)-$started).TotalMinutes) }
        }
        if ($job.State -ne 'Completed') {
            $reason=$job.ChildJobs[0].JobStateInfo.Reason
            throw "The installer session ended in state $($job.State): $reason"
        }
        $installExit=[int](Receive-Job -Job $job -ErrorAction Stop | Select-Object -Last 1)
    } finally { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    Write-Host ("Installer exited with code {0} after {1:N0} min." -f $installExit,((Get-Date)-$started).TotalMinutes)

    # Bring the installer logs next to the VM before judging the result.
    $hostLogs=Join-Path $settings.Destination 'Install logs'
    New-Item -ItemType Directory -Path $hostLogs -Force | Out-Null
    $session=New-PSSession -VMId $vm.Id -Credential $credential
    try { Copy-Item -FromSession $session -Path (Join-Path $guestSetup '*.log') -Destination $hostLogs -Force }
    catch { Write-Warning "Installer logs could not be copied: $($_.Exception.Message)" }
    finally { Remove-PSSession $session }
    if ($installExit -notin @(0,3010)) { throw "DVMS installation failed with exit code $installExit. Logs: $hostLogs" }
    Invoke-VMGuestCommand -VMId $vm.Id -Credential $credential -Arguments @($guestInstaller) -Script {
        param($Path)
        Remove-Item -LiteralPath $Path -Force
    } | Out-Null
    if ($installExit -eq 3010) {
        Write-Host 'The installer requested a restart; restarting Windows...'
        try {
            Invoke-VMGuestCommand -VMId $vm.Id -Credential $credential -Script { & "$env:SystemRoot\System32\shutdown.exe" /r /t 0 } | Out-Null
        } catch { Write-Verbose 'Restart command disconnected; waiting for a new boot.' }
        $guest=Wait-VMGuest -VMId $vm.Id -Credential $credential -PreviousBoot $guest.Boot -Deadline (Get-Date).AddMinutes(30)
    }

    $installed=Invoke-VMGuestCommand -VMId $vm.Id -Credential $credential -Script {
        $keys=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
        [pscustomobject]@{
            Products=@(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*DVMS*' } |
                ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)" } | Sort-Object -Unique)
            License=Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'DVMS\Licenses\License.lic')
        }
    }
    if (-not $installed.Products.Count) { throw "The installer reported success, but no DVMS product is registered in the VM. Logs: $hostLogs" }
    if (-not $installed.License) { Write-Warning 'C:\Program Files\DVMS\Licenses\License.lic is missing after installation.' }

    Write-Host ''
    Write-Host "DVMS VM ready: $($settings.Name) (computer name $($settings.ComputerName), MAC $mac)." -ForegroundColor Green
    foreach ($product in $installed.Products) { Write-Host "  Installed: $product" }
    Write-Host "  License: C:\Program Files\DVMS\Licenses\License.lic (host copy: $hostLicense)"
    Write-Host "  Installer logs: $hostLogs"
    Write-Host "  The VM is running. Checkpoint '$CheckpointName' is the renamed Windows state before DVMS was installed."
    $exitCode=0
} catch { Write-Host "DVMS VM SETUP FAILED: $($_.Exception.Message)" -ForegroundColor Red }
if (-not $NoPause) {
    Write-Host 'Press any key to continue...' -NoNewline
    $null=$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    Write-Host
}
exit $exitCode
