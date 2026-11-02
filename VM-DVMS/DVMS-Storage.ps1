#Requires -Version 5.1
# The recorder stores video on D:. DVMS copies get a dynamically expanding
# disk for it, attached before the copy's clean checkpoint is refreshed and
# formatted during that boot, so the checkpoint includes a ready D: drive.

function Add-DVMSStorageDisk {
    # Attaches an empty disk to a VM that is off; returns its size in bytes.
    param([Parameter(Mandatory=$true)][guid]$VMId,[Parameter(Mandatory=$true)][string]$Destination,[Parameter(Mandatory=$true)][int]$SizeGB)
    $vm=Get-VM -Id $VMId
    $path=Join-Path (Join-Path $Destination 'Virtual Hard Disks') 'Storage.vhdx'
    if (Test-Path -LiteralPath $path) { throw "Storage disk already exists: $path" }
    $vhd=New-VHD -Path $path -SizeBytes ([long]$SizeGB*1GB) -Dynamic
    Add-VMHardDiskDrive -VM $vm -ControllerType SCSI -Path $path
    Write-Host ("Storage disk attached: {0} ({1} GB, dynamically expanding)." -f $path,$SizeGB)
    $vhd.Size
}

# Runs in the guest with the disk size as its argument (Set-VMCopyComputerName -GuestSetup).
$script:DVMSStorageGuestSetup={
    param([long]$SizeBytes)
    $ErrorActionPreference='Stop'
    $disks=@(Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' -and $_.Size -eq $SizeBytes })
    if ($disks.Count -ne 1) { throw "Expected one empty $($SizeBytes/1GB) GB disk for D:, found $($disks.Count)." }
    # The template's DVD drive usually holds D:; give it the next free letter.
    $holder=Get-CimInstance Win32_Volume -Filter "DriveLetter='D:'"
    if ($holder) {
        if ($holder.DriveType -ne 5) { throw "D: is already used by $($holder.Name) ($($holder.Label)), not a DVD drive." }
        $used=@(Get-CimInstance Win32_Volume | Where-Object DriveLetter | ForEach-Object { $_.DriveLetter[0] })
        $free=[char[]](69..90) | Where-Object { $used -notcontains $_ } | Select-Object -First 1
        Set-CimInstance -InputObject $holder -Property @{DriveLetter=$(if ($free) { "${free}:" } else { $null })}
    }
    $number=$disks[0].Number
    if ($disks[0].IsOffline) { Set-Disk -Number $number -IsOffline $false }
    if ($disks[0].IsReadOnly) { Set-Disk -Number $number -IsReadOnly $false }
    Initialize-Disk -Number $number -PartitionStyle GPT
    $partition=New-Partition -DiskNumber $number -UseMaximumSize -DriveLetter D
    Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel 'Storage' -Confirm:$false | Out-Null
    'D:'
}
