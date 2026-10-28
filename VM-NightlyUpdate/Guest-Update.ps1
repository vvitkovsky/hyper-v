# Runs locally inside the guest as SYSTEM, never inside a remoting session.
#Requires -Version 5.1
param(
    [Parameter(Mandatory=$true)][string]$RunId,
    [ValidateSet('Update','Cleanup')][string]$Mode = 'Update'
)
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:ProgramData 'HyperVNightlyUpdate'
$statusPath = Join-Path $root 'status.json'
$applied = New-Object 'System.Collections.Generic.List[string]'
$script:phase = 'Starting'
function Save-Status([string]$State, [string]$Message) {
    $record = [ordered]@{ RunId=$RunId; State=$State; Message=$Message;
        Time=(Get-Date).ToString('o'); Phase=$script:phase; Applied=@($applied.ToArray()) }
    $temporary = "$statusPath.tmp"
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $statusPath -Force
}
function Test-Reboot {
    return ((New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))
}
function Request-Reboot([string]$State, [string]$Message, $CommitInstaller=$null) {
    $script:phase = 'Preparing reboot'
    # Feature updates must be committed before the host restarts Windows.
    # Commit is permitted only once per boot. Persist intent first so a crash
    # or lost response cannot cause a second, potentially destructive call.
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    $commitPath = Join-Path $root 'reboot-commit.json'
    $previous = if (Test-Path -LiteralPath $commitPath) {
        Get-Content -LiteralPath $commitPath -Raw | ConvertFrom-Json
    } else { $null }
    if ($previous -and $previous.Boot -eq $boot) {
        if ($previous.State -notin @('Committed','NotInitialized')) {
            throw 'An earlier update commit has an uncertain result. Restart Windows manually before retrying maintenance.'
        }
    }
    if (-not $previous -or $previous.Boot -ne $boot -or $previous.State -eq 'NotInitialized') {
        if ($null -eq $CommitInstaller) {
            # A new worker must recover the staged update objects from WUA's
            # local metadata. Do not filter IsInstalled: either value can be
            # reported for an update awaiting completion during reboot.
            $commitSession = New-Object -ComObject Microsoft.Update.Session
            $commitSession.ClientApplicationID = 'HyperVNightlyUpdate'
            $pendingSearcher = $commitSession.CreateUpdateSearcher()
            $pendingSearcher.Online = $false
            $pending = $pendingSearcher.Search("(RebootRequired=1 and DeploymentAction='Installation') or (RebootRequired=1 and DeploymentAction='OptionalInstallation')")
            if ($pending.ResultCode -ne 2) { throw "Pending-reboot scan was not fully successful: $($pending.ResultCode)" }
            if ($pending.Updates.Count -eq 0) {
                # CBS/DISM may need a reboot without any WUA update to commit.
                Save-Status $State ($Message + ' No Windows Update objects require commit.')
                return
            }
            $CommitInstaller = $commitSession.CreateUpdateInstaller()
            $CommitInstaller.Updates = $pending.Updates
        }
        if ($null -eq $CommitInstaller.Updates -or $CommitInstaller.Updates.Count -eq 0) {
            throw 'Cannot commit Windows updates without an assigned update collection.'
        }
        if ($CommitInstaller.IsBusy) { throw 'Another Windows Update installation is active; cannot prepare a restart.' }
        $script:phase = 'Committing updates before reboot'
        Save-Status 'Running' "Committing $($CommitInstaller.Updates.Count) staged update(s) before restart."
        $marker = @{ Boot=$boot; State='Started' }
        $marker | ConvertTo-Json | Set-Content -LiteralPath $commitPath -Encoding UTF8
        try { $CommitInstaller.Commit(0) }
        catch {
            $cause = $_.Exception
            while ($cause.InnerException) { $cause = $cause.InnerException }
            $hresult = '0x{0:X8}' -f $cause.HResult
            # This specific error rejects an uninitialized object before a
            # commit begins. Other failures remain uncertain and are not retried.
            if ($hresult -eq '0x80240004') { $marker.State = 'NotInitialized' }
            $marker['HResult'] = $hresult
            $marker | ConvertTo-Json | Set-Content -LiteralPath $commitPath -Encoding UTF8
            throw "Windows Update commit failed ($hresult): $($cause.Message)"
        }
        $marker.State = 'Committed'
        $marker | ConvertTo-Json | Set-Content -LiteralPath $commitPath -Encoding UTF8
    }
    Save-Status $State ($Message + ' Windows Update commit completed; ready to restart.')
}
try {
    Save-Status 'Running' "Starting $Mode pass."
    if (Test-Reboot) { Request-Reboot 'NeedsReboot' 'A restart is already pending.'; exit 0 }
    if ($Mode -eq 'Cleanup') {
        $script:phase = 'Component cleanup'
        # User opted out of uninstalling installed updates. Let Windows remove
        # superseded components; never delete WinSxS or update caches by hand.
        Save-Status 'Running' 'Removing superseded Windows components and update uninstall files.'
        $cleanupLog = Join-Path $root 'dism-cleanup.log'
        $cleanup = Start-Process -FilePath "$env:SystemRoot\System32\dism.exe" -ArgumentList @(
            '/Online', '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase',
            '/NoRestart', "/LogPath:`"$cleanupLog`""
        ) -Wait -PassThru -WindowStyle Hidden
        if ($cleanup.ExitCode -notin @(0,3010)) {
            throw "DISM component cleanup failed: exit code $($cleanup.ExitCode). See $cleanupLog"
        }
        if ($cleanup.ExitCode -eq 3010 -or (Test-Reboot)) {
            Request-Reboot 'CleanupNeedsReboot' 'Component cleanup succeeded; restart required before the final scan.'
        } else {
            Save-Status 'Cleaned' 'Component cleanup succeeded; installed updates can no longer be uninstalled.'
        }
        exit 0
    }
    $session = New-Object -ComObject Microsoft.Update.Session
    $script:phase = 'Scanning updates'
    $session.ClientApplicationID = 'HyperVNightlyUpdate'
    $searcher = $session.CreateUpdateSearcher()
    $searcher.Online = $true
    # Include all applicable offered updates: software, feature upgrades,
    # drivers, and optional updates. Continue to respect hidden updates.
    # Omitting DeploymentAction implicitly restricts the scan to Installation.
    # OptionalInstallation is separate from BrowseOnly and includes feature offers.
    $found = $searcher.Search("(IsInstalled=0 and IsHidden=0 and DeploymentAction='Installation') or (IsInstalled=0 and IsHidden=0 and DeploymentAction='OptionalInstallation')")
    if ($found.ResultCode -ne 2) { throw "Update scan was not fully successful: $($found.ResultCode)" }
    $updates = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($update in $found.Updates) {
        if (-not $update.EulaAccepted) { $update.AcceptEula() }
        [void]$updates.Add($update)
    }
    if ($updates.Count -eq 0) {
        if (Test-Reboot) { Request-Reboot 'NeedsReboot' 'Restart required after scan.' }
        else { Save-Status 'UpToDate' 'No applicable non-hidden Installation or OptionalInstallation offers remain.' }
        exit 0
    }
    Save-Status 'Running' "Downloading $($updates.Count) updates."
    $script:phase = 'Downloading updates'
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $updates
    $download = $downloader.Download()
    if ($download.ResultCode -ne 2) { throw "Download failed or was partial: $($download.ResultCode)" }
    # Install individually to support updates requiring exclusive installation.
    foreach ($update in $updates) {
        if (-not $update.IsDownloaded) { throw "Not downloaded: $($update.Title)" }
        $one = New-Object -ComObject Microsoft.Update.UpdateColl
        [void]$one.Add($update)
        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $one
        $installer.AllowSourcePrompts = $false
        # Some updates can prompt but support quiet mode. Try that mode rather
        # than excluding them; unsupported quiet installs fail normally.
        $installer.ForceQuiet = $true
        if ($installer.IsBusy) { throw 'Another Windows Update installation is active. Try again next night.' }
        Save-Status 'Running' "Installing: $($update.Title)"
        $script:phase = "Installing: $($update.Title)"
        $result = $installer.Install()
        if ($result.ResultCode -ne 2 -or $result.GetUpdateResult(0).ResultCode -ne 2) {
            throw "Installation failed: $($update.Title); result=$($result.ResultCode); HRESULT=$($result.HResult)"
        }
        $applied.Add($update.Title)
        if ($result.RebootRequired -or (Test-Reboot)) {
            Request-Reboot 'NeedsReboot' 'Restart required after staging updates.' -CommitInstaller $installer
            exit 0
        }
    }
    Save-Status 'Installed' 'Installation succeeded; another scan is required.'
    exit 0
} catch {
    Save-Status 'Failed' ($script:phase + ': ' + $_.Exception.Message)
    exit 1
}

