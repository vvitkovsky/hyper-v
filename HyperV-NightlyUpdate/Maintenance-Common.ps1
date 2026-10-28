#Requires -Version 5.1
function Enter-VMUpdateMutex {
    param([Parameter(Mandatory=$true)][guid]$VMId)
    # A VM keeps the same lock across source-folder moves and Windows sessions.
    $security = New-Object Security.AccessControl.MutexSecurity
    foreach ($sid in @(
        [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'),
        [Security.Principal.WindowsIdentity]::GetCurrent().User
    )) {
        $security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new($sid,'FullControl','Allow'))
    }
    $created = $false
    $name = "Global\HyperVNightlyUpdate-" + $VMId.ToString('D')
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $mutex = [Threading.MutexAcl]::Create($false,$name,[ref]$created,$security)
    } else {
        $mutex = [Threading.Mutex]::new($false,$name,[ref]$created,$security)
    }
    try {
        try { $acquired = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Another maintenance, install, or uninstall operation owns this VM. Wait for it to finish.' }
        return $mutex
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-VMUpdateMutex {
    param([Threading.Mutex]$Mutex)
    if ($Mutex) {
        try { $Mutex.ReleaseMutex() }
        finally { $Mutex.Dispose() }
    }
}
