#Requires -Version 5.1
#Requires -PSEdition Desktop
# Creates a VM from the maintained template, binds a DVMS license to its MAC
# address, installs the microservices of a DVMS v10 build with its
# scripts\install.cmd and then the DVMS build itself, silently.
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
    [int]$ServicesTimeoutMinutes = 60,
    [ValidateRange(1,65536)][int]$StorageSizeGB = 200,
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
$guestServices=Join-Path $guestSetup 'Services'
$guestMirror=Join-Path $guestServices 'Sources'
$exitCode=1
try {
    Import-Module Hyper-V
    Add-Type -AssemblyName System.Security
    $repository=Split-Path -Parent $PSScriptRoot
    $nightlyUpdate=Join-Path $repository 'VM-NightlyUpdate'
    $dvms=Join-Path $repository 'VM-DVMS'
    foreach ($file in @('Maintenance-Common.ps1','Credential-Input.ps1','VM-Registration.ps1','Template-Clone.ps1')) { . (Join-Path $nightlyUpdate $file) }
    . (Join-Path $dvms 'DVMS-License.ps1')
    . (Join-Path $dvms 'DVMS-Build.ps1')
    . (Join-Path $dvms 'DVMS-Storage.ps1')
    . (Join-Path $PSScriptRoot 'DVMS-Services.ps1')

    function Wait-GuestInstall {
        # Waits for a long-running PowerShell Direct job and returns its output.
        param($Job,[datetime]$Started,[int]$TimeoutMinutes,[string]$Activity)
        try {
            $reported=$Started
            while (-not (Wait-Job -Job $Job -Timeout 30)) {
                if ((Get-Date) -ge $Started.AddMinutes($TimeoutMinutes)) { throw "$Activity did not finish within $TimeoutMinutes minutes. The VM was left running for inspection." }
                if ((Get-Date) -ge $reported.AddMinutes(5)) { $reported=Get-Date; Write-Host ("  still installing ({0:N0} min)..." -f ((Get-Date)-$Started).TotalMinutes) }
            }
            if ($Job.State -ne 'Completed') {
                $reason=$Job.ChildJobs[0].JobStateInfo.Reason
                throw "$Activity session ended in state $($Job.State): $reason"
            }
            Receive-Job -Job $Job -ErrorAction Stop | Select-Object -Last 1
        } finally { Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue }
    }
    function Copy-GuestLogs([string]$GuestFolder,[string]$HostFolder) {
        New-Item -ItemType Directory -Path $HostFolder -Force | Out-Null
        $session=New-PSSession -VMId $vm.Id -Credential $credential
        try { Copy-Item -FromSession $session -Path (Join-Path $GuestFolder '*.log') -Destination $HostFolder -Force }
        catch { Write-Warning "Logs in $GuestFolder could not be copied: $($_.Exception.Message)" }
        finally { Remove-PSSession $session }
    }
    function Copy-ToGuest([string]$Source,[string]$Target) {
        for ($attempt=1; ; $attempt++) {
            try { Copy-VMFile -VM $vm -SourcePath $Source -DestinationPath $Target -CreateFullPath -FileSource Host -Force; break }
            catch {
                # The guest service can take a moment to start after boot.
                if ($attempt -ge 6) { throw }
                Start-Sleep -Seconds 10
            }
        }
    }
    function Restart-Guest {
        try {
            Invoke-VMGuestCommand -VMId $vm.Id -Credential $credential -Script { & "$env:SystemRoot\System32\shutdown.exe" /r /t 0 } | Out-Null
        } catch { Write-Verbose 'Restart command disconnected; waiting for a new boot.' }
        Wait-VMGuest -VMId $vm.Id -Credential $credential -PreviousBoot $guest.Boot -Deadline (Get-Date).AddMinutes(30)
    }

    # Ask everything first so the long copy and install run unattended.
    $template=Get-TemplateVM $TemplateName
    $credential=Get-TemplateGuestCredential -TemplateName $TemplateName -BaseDirectory $nightlyUpdate
    $settings=Read-TemplateCopySettings -Name $Name -Destination $Destination -ComputerName $ComputerName

    if ([string]::IsNullOrWhiteSpace($Version)) {
        Write-Host "Looking for DVMS builds with microservice scripts in $BuildRoot..."
        $versions=@(Get-DVMSBuildVersions $BuildRoot | Where-Object { Test-Path -LiteralPath (Get-DVMSServicesScriptPath $BuildRoot $_.Version) -PathType Leaf } | Sort-Object Updated -Descending)
        if (-not $versions.Count) { throw "No DVMS version under $BuildRoot has both an installer and scripts\install.cmd." }
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
    $services=Read-DVMSServicesScript -Path (Get-DVMSServicesScriptPath $BuildRoot $Version)
    if (-not $services.SignalsRestart) { Write-Warning "install.cmd no longer prints '$($services.RestartMarker)', so a restart it needs would not be noticed." }

    if ([string]::IsNullOrWhiteSpace($LicensePath)) {
        # The license used for VM-DVMS works here too.
        $default=Join-Path $PSScriptRoot 'License.lic'
        $shared=Join-Path $dvms 'License.lic'
        if (-not (Test-Path -LiteralPath $default) -and (Test-Path -LiteralPath $shared)) { $default=$shared }
        $entered=(Read-Host "License file [$default]").Trim().Trim('"')
        $LicensePath=if ($entered) { $entered } else { $default }
    }
    if (-not (Test-Path -LiteralPath $LicensePath -PathType Leaf)) { throw "License file not found: $LicensePath" }
    $keys=Get-DVMSLicenseKeys -Repository $LegacyRepository
    $license=Read-DVMSLicense -Path $LicensePath -PublicKey $keys.PublicKey
    if (-not $license.Macs.Count) { throw 'The license has no MAC protection entry to bind to the new VM.' }

    # Copy, guest installers and installed files all land on the VM's drive.
    $templateDisks=@(Get-VMHardDiskDrive -VM $template) + @(Get-VMSnapshot -VM $template | ForEach-Object { Get-VMHardDiskDrive -VMSnapshot $_ })
    $templateBytes=0; $seen=@{}
    foreach ($drive in $templateDisks) {
        $path=$drive.Path
        while ($path -and -not $seen.ContainsKey($path)) { $seen[$path]=$true; $vhd=Get-VHD -Path $path; $templateBytes+=$vhd.FileSize; $path=$vhd.ParentPath }
    }
    $servicesBytes=[long]($services.Files | Measure-Object Length -Sum).Sum
    $needed=@{}
    $vmDrive=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($settings.Destination))
    # install.cmd copies each file once more in the VM before installing it.
    $needed[$vmDrive]=$templateBytes+$selected.Length+2*$servicesBytes+15GB
    # The installer cache is shared with VM-DVMS, so either script can reuse it.
    $cacheDirectory=Join-Path (Join-Path $dvms '.cache') $Version
    $servicesCache=Join-Path (Join-Path $PSScriptRoot '.cache') 'services'
    $cacheDrive=[IO.Path]::GetPathRoot($cacheDirectory)
    $servicesCacheDrive=[IO.Path]::GetPathRoot($servicesCache)
    $cachedFile=Get-Item -LiteralPath (Join-Path $cacheDirectory $selected.Name) -ErrorAction SilentlyContinue
    if (-not ($cachedFile -and $cachedFile.Length -eq $selected.Length -and $cachedFile.LastWriteTimeUtc -eq $selected.LastWriteTimeUtc)) {
        $needed[$cacheDrive]=[long]$needed[$cacheDrive]+$selected.Length
    }
    foreach ($file in $services.Files) {
        if (-not (Test-DVMSServiceFileCached $file $servicesCache)) { $needed[$servicesCacheDrive]=[long]$needed[$servicesCacheDrive]+$file.Length }
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
    Write-Host "Storage disk:   D:, $StorageSizeGB GB, dynamically expanding"
    Write-Host ("Microservices:  {0} ({1} files, {2:N1} GB)" -f $services.Path,$services.Files.Count,($servicesBytes/1GB))
    Write-Host ("License:        {0} (product {1}, serial {2}, MACs {3})" -f $LicensePath,$license.Product,$license.SerialNumber,($license.Macs -join ', '))
    Write-Host ''

    $cached=Save-DVMSInstaller -Source $selected -CacheDirectory $cacheDirectory
    Write-Host "Updating cached microservice installers in $servicesCache..."
    $cachedServices=@(foreach ($file in $services.Files) {
        [pscustomobject]@{Host=Save-DVMSServiceFile -Source $file -CacheRoot $servicesCache;Guest=ConvertTo-DVMSMirrorPath $file.FullName $guestMirror}
    })
    $localScript=Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot '.cache') 'scripts') $Version) 'install.cmd'
    Save-DVMSLocalServicesScript -Text $services.Text -MirrorRoot $guestMirror -Path $localScript

    Write-Host "Copying template to $($settings.Destination), please wait..."
    $copy=Copy-VMTemplate -TemplateName $TemplateName -Name $settings.Name -Destination $settings.Destination -CheckpointName $CheckpointName
    $storageBytes=Add-DVMSStorageDisk -VMId $copy.Id -Destination $settings.Destination -SizeGB $StorageSizeGB
    $null=Set-VMCopyComputerName -VMId $copy.Id -ComputerName $settings.ComputerName -Credential $credential -CheckpointName $CheckpointName -GuestSetup $DVMSStorageGuestSetup -GuestSetupArguments @($storageBytes)

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
    $hostLogs=Join-Path $settings.Destination 'Install logs'

    # The microservices go in first, so DVMS is installed on top of them.
    Write-Host ("Copying {0} microservice installers into the VM ({1:N1} GB)..." -f $cachedServices.Count,($servicesBytes/1GB))
    foreach ($file in $cachedServices) { Copy-ToGuest $file.Host $file.Guest }
    Copy-ToGuest $localScript (Join-Path $guestServices 'install.cmd')
    Write-Host "Installing microservices: $guestServices\install.cmd"
    $started=Get-Date
    $job=Invoke-Command -VMId $vm.Id -Credential $credential -AsJob -ArgumentList $guestServices,$services.RestartMarker -ScriptBlock {
        param($Folder,$RestartMarker)
        # install.cmd downloads into and logs to the current directory. .\ keeps
        # it working when NoDefaultCurrentDirectoryInExePath is set.
        Set-Location -LiteralPath $Folder
        & "$env:SystemRoot\System32\cmd.exe" /d /c '.\install.cmd > install-services.log 2>&1'
        # A bare exit /b gives 0 here whatever ERRORLEVEL was; install.cmd uses
        # it only on success and exit /b 1 on every failure.
        [pscustomobject]@{
            ExitCode=$LASTEXITCODE
            Restart=[bool](Select-String -LiteralPath (Join-Path $Folder 'install-services.log') -Pattern $RestartMarker -SimpleMatch -Quiet)
        }
    }
    $servicesResult=Wait-GuestInstall -Job $job -Started $started -TimeoutMinutes $ServicesTimeoutMinutes -Activity 'Microservice installation'
    Write-Host ("install.cmd exited with code {0} after {1:N0} min." -f $servicesResult.ExitCode,((Get-Date)-$started).TotalMinutes)
    $hostServiceLogs=Join-Path $hostLogs 'Services'
    Copy-GuestLogs $guestServices $hostServiceLogs
    if ($servicesResult.ExitCode -ne 0) { throw "Microservice installation failed with exit code $($servicesResult.ExitCode). See install-services.log in $hostServiceLogs" }
    Invoke-VMGuestCommand -VMId $vm.Id -Credential $credential -Arguments @($guestServices,$guestMirror) -Script {
        param($Folder,$Mirror)
        Remove-Item -LiteralPath $Mirror -Recurse -Force
        Remove-Item -LiteralPath (Join-Path $Folder 'install.cmd') -Force
    } | Out-Null
    if ($servicesResult.Restart) {
        Write-Host 'install.cmd reported that a restart is needed; restarting Windows...'
        $guest=Restart-Guest
    }

    $guestInstaller=Join-Path $guestSetup $selected.Name
    Write-Host ("Copying the installer into the VM ({0:N1} GB)..." -f ($selected.Length/1GB))
    Copy-ToGuest $cached $guestInstaller

    $logPath=Join-Path $guestSetup 'DVMS-install.log'
    $arguments="$InstallerArguments /log `"$logPath`""
    Write-Host "Installing: $($selected.Name) $arguments"
    $started=Get-Date
    $job=Invoke-Command -VMId $vm.Id -Credential $credential -AsJob -ArgumentList $guestInstaller,$arguments -ScriptBlock {
        param($Path,$Arguments)
        (Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru).ExitCode
    }
    $installExit=[int](Wait-GuestInstall -Job $job -Started $started -TimeoutMinutes $InstallTimeoutMinutes -Activity 'DVMS installation')
    Write-Host ("Installer exited with code {0} after {1:N0} min." -f $installExit,((Get-Date)-$started).TotalMinutes)

    # Bring the installer logs next to the VM before judging the result.
    Copy-GuestLogs $guestSetup $hostLogs
    if ($installExit -notin @(0,3010)) { throw "DVMS installation failed with exit code $installExit. Logs: $hostLogs" }
    Invoke-VMGuestCommand -VMId $vm.Id -Credential $credential -Arguments @($guestInstaller) -Script {
        param($Path)
        Remove-Item -LiteralPath $Path -Force
    } | Out-Null
    if ($installExit -eq 3010) {
        Write-Host 'The installer requested a restart; restarting Windows...'
        $guest=Restart-Guest
    }

    $installed=Invoke-VMGuestCommand -VMId $vm.Id -Credential $credential -Arguments @(,$services.Checks) -Script {
        param($Checks)
        $keys=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
        [pscustomobject]@{
            Products=@(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*DVMS*' } |
                ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)" } | Sort-Object -Unique)
            License=Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'DVMS\Licenses\License.lic')
            Storage=[bool](Get-Volume -DriveLetter D -ErrorAction SilentlyContinue | Where-Object FileSystemLabel -EQ 'Storage')
            MissingServices=@($Checks | Where-Object { -not (Test-Path -LiteralPath $_) })
            Services=@(Get-Service -Name 'VMS*' -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { [pscustomobject]@{Name=$_.Name;Status=[string]$_.Status} })
        }
    }
    if (-not $installed.Products.Count) { throw "The installer reported success, but no DVMS product is registered in the VM. Logs: $hostLogs" }
    if (-not $installed.Storage) { throw 'The Storage volume D: is missing in the VM.' }
    if ($installed.MissingServices.Count) { throw "install.cmd reported success, but these files are missing: $($installed.MissingServices -join ', '). Logs: $hostServiceLogs" }
    if (-not $installed.License) { Write-Warning 'C:\Program Files\DVMS\Licenses\License.lic is missing after installation.' }
    $stopped=@($installed.Services | Where-Object Status -NE 'Running')
    if ($stopped.Count) { Write-Warning ("Services not running: {0}" -f (($stopped | ForEach-Object { "$($_.Name) ($($_.Status))" }) -join ', ')) }

    Write-Host ''
    Write-Host "DVMS v10 VM ready: $($settings.Name) (computer name $($settings.ComputerName), MAC $mac)." -ForegroundColor Green
    foreach ($product in $installed.Products) { Write-Host "  Installed: $product" }
    Write-Host ("  Microservices: {0} packages installed from {1}; {2} of {3} VMS* services running." -f $services.Files.Count,$services.Path,($installed.Services.Count-$stopped.Count),$installed.Services.Count)
    Write-Host "  License: C:\Program Files\DVMS\Licenses\License.lic (host copy: $hostLicense)"
    Write-Host "  Storage: D: ($StorageSizeGB GB, Virtual Hard Disks\Storage.vhdx)"
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
