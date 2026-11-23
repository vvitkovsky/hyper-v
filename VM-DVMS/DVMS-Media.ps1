#Requires -Version 5.1
# Installers reach the VM on a small disk of their own, attached while they are
# needed and mounted in Windows as a folder. Copying them into Windows instead
# takes longer and leaves the VM's disk permanently larger by their size.
# Needs Template-Clone.ps1 (Invoke-VMGuestCommand) for the guest steps.
$script:DVMSMediaLabel='DVMSMedia'

function New-DVMSMediaDisk {
    # Builds the disk on the host. Files are objects with Source (a host file)
    # and Target (its path on the disk); Folders are empty folders to create.
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][object[]]$Files,[string[]]$Folders=@())
    if (Test-Path -LiteralPath $Path) { throw "Install media disk already exists: $Path" }
    $bytes=[long]0
    foreach ($file in $Files) { $bytes+=(Get-Item -LiteralPath $file.Source).Length }
    # Room for NTFS itself and its per-file overhead.
    $size=[long]([math]::Ceiling(($bytes*1.03+256MB)/1MB))*1MB
    $null=New-VHD -Path $Path -SizeBytes $size -Dynamic
    $mount=Join-Path (Split-Path -Parent $Path) ('media-'+[guid]::NewGuid().ToString('N'))
    $attached=$false; $partition=$null; $mounted=$false
    try {
        $disk=Mount-VHD -Path $Path -NoDriveLetter -Passthru | Get-Disk
        $attached=$true
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT
        $partition=New-Partition -DiskNumber $disk.Number -UseMaximumSize
        $null=Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel $script:DVMSMediaLabel -Confirm:$false
        New-Item -ItemType Directory -Path $mount | Out-Null
        Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AccessPath $mount
        $mounted=$true
        foreach ($folder in $Folders) { New-Item -ItemType Directory -Path (Join-Path $mount $folder) -Force | Out-Null }
        foreach ($file in $Files) {
            $target=Join-Path $mount $file.Target
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath $file.Source -Destination $target -Force
        }
    } finally {
        if ($mounted) { Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AccessPath $mount }
        if ($attached) { Dismount-VHD -Path $Path }
        if (Test-Path -LiteralPath $mount) { Remove-Item -LiteralPath $mount -Force }
    }
    $Path
}

function Mount-DVMSMediaDisk {
    # Attaches the disk to the running VM and mounts it as GuestPath, a folder
    # that must not exist yet or be empty. Returns GuestPath.
    param(
        [Parameter(Mandatory=$true)]$VM,
        [Parameter(Mandatory=$true)][Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$GuestPath
    )
    Add-VMHardDiskDrive -VM $VM -ControllerType SCSI -Path $Path
    Invoke-VMGuestCommand -VMId $VM.Id -Credential $Credential -Arguments @($script:DVMSMediaLabel,$GuestPath) -TimeoutSeconds 180 -Script {
        param($Label,$MountPath)
        $ErrorActionPreference='Stop'
        # A disk added to a running Windows can take a moment to appear, and
        # some Windows editions leave it offline.
        $volume=$null
        $deadline=(Get-Date).AddSeconds(120)
        do {
            Get-Disk | Where-Object IsOffline | ForEach-Object { try { Set-Disk -Number $_.Number -IsOffline $false } catch { } }
            $volume=Get-Volume | Where-Object FileSystemLabel -EQ $Label | Select-Object -First 1
            if ($volume) { break }
            Start-Sleep -Seconds 2
        } while ((Get-Date) -lt $deadline)
        if (-not $volume) { throw "The install media disk '$Label' did not appear in Windows." }
        $partition=$volume | Get-Partition
        New-Item -ItemType Directory -Path $MountPath -Force | Out-Null
        $accessPath=$MountPath.TrimEnd('\')+'\'
        if ($partition.AccessPaths -notcontains $accessPath) {
            if (@(Get-ChildItem -LiteralPath $MountPath -Force).Count) { throw "$MountPath is not empty, so the install media cannot be mounted there." }
            Add-PartitionAccessPath -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -AccessPath $MountPath
        }
    } | Out-Null
    $GuestPath
}

function Dismount-DVMSMediaDisk {
    # Unmounts the folder in Windows, detaches the disk and deletes it.
    param(
        [Parameter(Mandatory=$true)]$VM,
        [Parameter(Mandatory=$true)][Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$GuestPath
    )
    Invoke-VMGuestCommand -VMId $VM.Id -Credential $Credential -Arguments @($script:DVMSMediaLabel,$GuestPath) -Script {
        param($Label,$MountPath)
        $ErrorActionPreference='Stop'
        $volume=Get-Volume | Where-Object FileSystemLabel -EQ $Label | Select-Object -First 1
        if ($volume) {
            $partition=$volume | Get-Partition
            $accessPath=$MountPath.TrimEnd('\')+'\'
            if ($partition.AccessPaths -contains $accessPath) { Remove-PartitionAccessPath -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -AccessPath $MountPath }
        }
        # The folder is an empty directory again once the disk is unmounted.
        if ((Test-Path -LiteralPath $MountPath) -and -not @(Get-ChildItem -LiteralPath $MountPath -Force).Count) { Remove-Item -LiteralPath $MountPath -Force }
    } | Out-Null
    $full=[IO.Path]::GetFullPath($Path)
    Get-VMHardDiskDrive -VM $VM | Where-Object { [IO.Path]::GetFullPath($_.Path) -eq $full } | Remove-VMHardDiskDrive
    Remove-Item -LiteralPath $Path -Force
}
