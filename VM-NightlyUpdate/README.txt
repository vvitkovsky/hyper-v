Nightly Hyper-V Windows updates - run from this folder

QUICK SETUP
1. Extract the package to the permanent local folder you want to use.
2. Run Install.cmd and approve administrator elevation.
3. Answer its questions; Enter accepts each default:
     Hyper-V VMs:
       1. Windows 11 Template              updated nightly at 00:00, checkpoint clean
       2. Windows Server 2025 Template
     VM to update nightly [1]:
     Daily time, 24-hour HH:mm host time [00:00]:
     Checkpoint to refresh [clean]:
4. Enter a VM administrator account and password if no saved credential exists.

Run Install.cmd once per VM to update several VMs; each gets its own task,
credential and .state folder. The VM list shows every Hyper-V VM on the host
(type its number or its exact name) and marks the ones already updated from
this folder. Enter picks Windows 11 Template when it exists; otherwise a
number is required. The time is in the HOST's local time zone, for example
00:00 or 02:30. For a VM that is already installed, the time and checkpoint
default to its current ones, so Enter keeps them. VMs given the same time are
updated together and need host memory together; setup warns about that.
The checkpoint is the exact checkpoint name to refresh after successful
maintenance. It defaults to clean. Changing it selects a different
checkpoint; checkpoints with other names, including the previously selected
name, are preserved.

The task runs Nightly-Update.ps1 directly from THIS installer folder. No host
scripts are copied to ProgramData. Keep this folder at its installed location;
re-run installation after moving it. Updating these source scripts updates the
next run directly. Install only registers/reconfigures the task; it does not
start, stop, restore, or update the VM immediately.

UPDATING THESE SCRIPTS
Wait for any existing maintenance run to finish, then replace the package files
in your permanent folder and retain the .state directory. Run Install.cmd
again for each VM and press Enter to keep its time and checkpoint; saved guest
credentials are reused. Include Maintenance-Common.ps1 with the other scripts.
Source-folder permissions remain unchanged for the requested testing setup.

DEDICATED TEMPLATE AND CREATING MORE VMS
The dedicated VM is named Windows 11 Template. Its permanent files live at:
  A:\HyperV Template\
Only Hyper-V's normal Virtual Machines, Virtual Hard Disks and Snapshots
subfolders are needed. The VM stays registered and off between nightly runs.
Automatic host-start and automatic checkpoints are disabled on this template.

Nightly maintenance updates the template, performs cleanup, shuts down and
refreshes clean (or the configured checkpoint). It does not export anything.
Working VMs are independent and are not updated by the template's task.
Changes to the template affect copies created afterward, not existing copies.

To create a VM, run Create-VM.cmd. It prompts for the template, name,
destination and Windows computer name:
  Templates (VMs updated nightly from this folder):
    1. Windows 11 Template              checkpoint clean
    2. Windows Server 2025 Template     checkpoint clean
  Template to copy [1]:
  New VM name [Windows 11 Test]:
  Destination [A:\VMs\<chosen name>]:
  Windows computer name [WIN11-Test]:
Press Enter to accept each default, or type your own value. The templates are
the VMs installed with Install.cmd from this folder; type a number or the exact
name. Enter picks Windows 11 Template (or the only template); a template that
is not off is marked, because it cannot be copied until it is shut down. The
checkpoint copied is the one the template's nightly task refreshes.
The default VM name is the template name with "Template" replaced by "Test",
for example Windows Server 2025 Test. The default path uses the name you chose.
Names used as folders must be valid Windows folder names. The default computer
name is derived from the VM name: a leading "Windows Server 2025" becomes
WS2025 and "Windows 11" becomes WIN11, other characters become hyphens, and the
result is cut to 15 characters. Pick distinct computer names for VMs that run
together.
To supply all values directly and skip the prompts:
  .\Create-VM.ps1 -TemplateName 'Windows 11 Template' -Name 'Windows 11 Test' -Destination 'A:\VMs\Windows 11 Test' -ComputerName 'WIN11-Test'
Optional parameters: -TemplateName, -Name, -Destination, -ComputerName,
-KeepComputerName, -CheckpointName, -NoPause. Create-VM.cmd forwards them to
PowerShell. Supplying -TemplateName, -Name, -Destination or -ComputerName skips
its prompt; -TemplateName with -KeepComputerName also works for a VM without
nightly updates. The prompts appear after administrator elevation.
The script elevates automatically and leaves the created VM off, ready to start.

The copy uses Import-VM -Copy -GenerateNewId directly from the stopped template.
It includes the checkpoint tree and copies all disks into the destination.
It checks compatibility, checkpoint presence and disk chains, and rejects any
remaining dependency on disks outside the new VM folder. The Windows user is
retained.

Setting the computer name starts the copy, signs in through PowerShell Direct
with the template's saved maintenance credential, runs Rename-Computer,
restarts, confirms the new name, and shuts Windows down. It then replaces the
copy's clean checkpoint with the renamed state, so reverting to clean keeps the
new name. This adds a few minutes and needs enough free host memory to start
the copy. The template must have been installed with Install.cmd so that its
credential exists. With -KeepComputerName the copy is not started and keeps the
template's computer name, as before. If renaming fails, the VM and its files
remain as they are for inspection.

Choose a new, separate local destination folder; existing destinations and VM
names are rejected. Copying shares the template's maintenance lock, so it cannot
run during updates or another copy. The template must be off. Allow enough free
space for a full independent copy. Failed copies retain their files/VM for
inspection and report failure rather than deleting potentially useful data.

Older Export-Checkpoint.ps1 is no longer used and can be removed from existing
script installations. This package does not include it. Do not register or use
the old managed export tree as an additional source after migration.
COMMAND-LINE OVERRIDES
Supplying -VMName, -ScheduledTime or -CheckpointName skips its question.
Install.cmd forwards them, and other options such as -NoPause, to PowerShell:
Install.cmd -VMName "Windows 11 Template" -ScheduledTime 01:30 -CheckpointName baseline
.\Install.ps1 -VMName 'Windows 11 Template' -ScheduledTime '01:30' -CheckpointName 'baseline'

VM name, time and checkpoint can be passed through automatic elevation. If you pass
credentials as parameters, use PowerShell as administrator:
.\Install.ps1 -VMName 'Windows 11 Template' -ScheduledTime '01:30' -VMUserName 'WIN11-PC\Victor' -VMPassword 'YOUR-VM-PASSWORD' -NoPause

Use an administrator account FROM INSIDE that VM, with its Windows password,
not a Windows Hello PIN. Replace the example guest computer/account name.

For masked input instead of a literal password in command history:
$vmPassword = Read-Host 'VM password' -AsSecureString
.\Install.ps1 -VMName 'Windows 11 Template' -ScheduledTime '01:30' -VMUserName 'WIN11-PC\Victor' -VMPassword $vmPassword -NoPause

Or pass a PowerShell credential object:
.\Install.ps1 -VMName 'Windows 11 Template' -ScheduledTime '01:30' -VMCredential (Get-Credential) -NoPause

Install.ps1 asks for the VM, time and checkpoint when called without those
parameters. No environment-variable fallback is used. If only -VMUserName is supplied, setup
asks for its password with masked input. -NoPause skips the closing
'Press any key to continue...' prompt. Aliases -UserName, -Password, and
-Credential are accepted. Literal passwords may enter command history/process
command lines; masked input keeps the password itself out of command text.

CREDENTIALS, STATE, AND EXISTING INSTALLATIONS
Credentials are entered ONCE, then encrypted with Windows machine DPAPI. The
nightly SYSTEM task reuses them without prompting. Re-run setup with new
credentials if the guest username/password changes. Setup can reuse credentials
already saved for the same VM when changing its time or source folder.

Each VM has its own protected generated-data directory beside these scripts:
<this folder>\.state\<VM-GUID>\
  config.json                 VM ID, source folder, schedule, checkpoint, task name
  guest-credential.json       encrypted VM credential
  Logs\latest.json           current progress or final result
  Logs\<timestamp>.log/json  run history

The data directory is accessible to SYSTEM and local Administrators. Source
scripts remain in the installer folder. Local host administrators can access
the encrypted credential. The task runs as SYSTEM and stores no host password.
Runtime logs and scheduled command arguments do not contain supplied passwords.

Reinstall updates the same per-VM task, so changing the source folder or time
does not create a duplicate. Earlier ProgramData installations are recognized
through the existing task and their saved VM ID. Their credentials can be
reused, and the task is redirected to this folder. The previous ProgramData
copy is retained as an unused backup; new runs use this folder's .state data.

Task name: HyperVNightlyUpdate-<VM-GUID>. Very early Windows 11 installations
retain their existing 'Hyper-V - Windows 11 nightly updates' task name.
Setup prints the exact task name, next run time, source folder, and log path.
Re-run installation after renaming a VM to confirm its new display name.

RUN NOW / CHECK (PowerShell as administrator, from this folder)
.\Nightly-Update.ps1 -VMName 'Windows 11 Template'

Check startup and VM identity without starting/stopping the VM or updating it:
.\Nightly-Update.ps1 -VMName 'Windows 11 Template' -CheckOnly

The VM must already have been configured with Install.ps1 from this folder.
Normal runs use the saved credential. An in-memory credential override applies
only to that run and does not replace the saved credential:
.\Nightly-Update.ps1 -VMName 'Windows 11 Template' -VMUserName 'WIN11-PC\Victor' -VMPassword $vmPassword

Scheduled commands pass the .state directory explicitly using -Root and never
prompt for credentials. Scheduled runs have no visible window; use latest.json
or the timestamped log to follow progress. You can also start the task using
Windows Task Scheduler. If -VMName and -Root are both given, their VM IDs must
match. Source scripts always come from the runner's own folder.

UNINSTALL (PowerShell as administrator, from this folder)
.\Uninstall.ps1 -VMName 'Windows 11 Template' -NoPause

Preview without changing anything:
.\Uninstall.ps1 -VMName 'Windows 11 Template' -WhatIf

Uninstall.cmd is the double-click option. It lists the VMs updated from this
folder and asks which one to remove (a number or the exact name; there is no
default). -VMName skips the question and also finds an older ProgramData
installation. Parameters are forwarded; -WhatIf needs an elevated console.
Uninstall removes the selected task and that VM's
generated .state directory (credentials, configuration, and logs). It preserves
the source script folder, VM, virtual disks, checkpoints, and other VM state.
It needs no guest password and works after the VM has been deleted.

Uninstall never starts, stops, or connects to a VM, and refuses to interrupt
running host maintenance or a manual run holding its lock. Wait until the run
finishes, then retry. A guest worker left by an earlier failure is not stopped
or deleted. Previous ProgramData backups are separate from the current local
state; the uninstaller also supports removing those older installations when
no matching local state remains.

Installation, removal, and maintenance share a host-wide lock keyed by VM ID,
including across source-folder moves. Setup also checks file locks in the old
and new data locations so a manual run of the previous version blocks migration.
Locks are released before the closing keypress prompt.

MAINTENANCE BEHAVIOR
- Start only a fully Off VM. Running, paused, or saved VMs are skipped.
  If Hyper-V cannot allocate host resources (0x800705AA), retry startup up to
  six times at five-minute intervals (25 minutes total waiting). Other startup
  failures stop immediately. Ensure enough host RAM is available for the VM's
  configured startup memory; retries cannot fix a persistent shortage.
- Update its CURRENT state. Never automatically restore a checkpoint. Existing changes
  in the VM become part of the refreshed checkpoint.
- Pin its unique VM ID; do not silently switch to a new VM with the same name.
- Stage a small worker inside the guest's ProgramData and run it locally as
  SYSTEM. Host source scripts stay in this folder. Follow the guest's existing
  update source/policies; do not override WSUS.
- Select all applicable, non-hidden updates offered through the guest's
  configured Windows Update source: quality updates, feature/version upgrades,
  drivers, and optional updates (including optional previews). The search has
  no Software-only, non-optional, or Upgrades-classification exclusion.
  Explicitly include both Installation and OptionalInstallation deployment
  actions. Omitting DeploymentAction silently excludes some feature offers,
  even when BrowseOnly is false.
  Existing update policies and availability still apply; this does not force
  an upgrade that the update service has not offered. Store apps are separate.
- Install in quiet mode without source prompts, including updates that can
  prompt but support unattended installation. If quiet installation is not
  supported, record the failure and preserve the previous checkpoint.
- Accept license terms for eligible updates, download/install, reboot, and scan
  again as needed. Limits: 6 reboots, 12 passes, roughly 4 hours plus bounded
  boot/shutdown operations. Hard host task limit: 5 hours.
  Initial boot allows 15 minutes. Reboots allow up to 60 minutes for feature
  upgrades, still bounded by the overall four-hour maintenance deadline.
- Before reporting a required reboot, call Windows Update's Commit(0) locally
  in the guest so staged feature upgrades can complete during restart. Reuse
  the installer and update collection that performed installation. When a new
  worker finds an already pending reboot, recover the update collection from
  a local RebootRequired scan covering both deployment actions. A CBS/DISM-only
  reboot with no matching WUA updates does not need a WUA commit. Record
  commit intent and success against the guest boot timestamp to avoid repeating
  our call before a reboot. The specific 0x80240004 initialization rejection
  is recorded as NotInitialized and can be retried with an initialized object.
  Other uncertain commit failures stop maintenance and preserve the checkpoint;
  inspect the error and restart Windows manually before retrying. The marker
  resets logically on the next boot. Logs name the failed phase and distinguish
  a successful install operation from completion after restart.
- A known guest-worker failure ends the run promptly with its task result.
  Temporary status-read failures are retried; an idle worker with no current
  status has a two-minute startup allowance. Incomplete completion records are
  checked twice to allow a status/task-state read race.
- Windows can restart itself during a pass (servicing often needs a second
  restart after a cumulative update, which terminates the worker). After any
  failed pass, wait up to 3 minutes for a new boot time, or up to 60 minutes
  once the guest is unreachable. If Windows restarted, repeat the pass; this
  counts against the 6-reboot limit. Otherwise the failure stands.
- After updates and reboots, run supported Windows component cleanup:
  DISM.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase /NoRestart
  Existing updates cannot be uninstalled afterward. Future updates still work.
- Reboot if cleanup requests it, then scan again. Further updates are followed
  by another cleanup before accepting the checkpoint.
- After successful cleanup and final scan with no pending Windows Update/CBS
  reboot, request shutdown inside Windows using shutdown /s /t 0. Wait up to
  15 minutes for Off. This handles locked guests that reject Hyper-V integration
  shutdown requests. Never force power off or save state.
- Create/verify a replacement checkpoint while Off, rename the old selected
  checkpoint temporarily, give the new checkpoint the configured name, then delete the old one through
  Hyper-V. Other checkpoints remain. Failures preserve the old checkpoint; it
  may be named <checkpoint-name>.previous-<unique ID> after a late checkpoint error.
  Rollback vacates the replacement's target name and confirms its identity before
  restoring the previous name. If rollback cannot be confirmed, both checkpoints
  are retained under their current names for inspection.
- After a failure, a VM this run started is shut down with shutdown /s /t 0
  inside Windows, because later runs skip a VM that is not Off. It is left
  running if the guest worker is still running, the guest is unreachable, or
  Windows does not turn off within 15 minutes. Logs stay on the host and in the
  guest's ProgramData\HyperVNightlyUpdate. No automatic checkpoint restoration
  is performed.
- Finish after refreshing the checkpoint. No nightly export is created.
- Request waking the host from sleep. Wake timers and firmware/power support
  must work. Keep the host on AC power. A powered-off host cannot be started.
- A missed nightly run is not caught up during the following daytime.
- No user must remain logged in. The guest needs access to its update service.
- Cleanup frees guest Windows space; host VHDX compaction is a separate step.

VALIDATION
See Validation.txt for current syntax, simulated update/install workflows,
recovery, cross-process locking, and regression checks. Earlier versions
completed a live Windows 11 maintenance run and a source-folder SYSTEM launch
check. The October 22 diagnostic confirmed that the previous search missed
the guest's Windows 11 26H2 OptionalInstallation offer. On October 26 the
corrected commit path completed that staged upgrade: the restarted guest
reported 26H2 build 26300.9711, no pending reboot, and no offers remaining in
the local scan. That recovery left the VM running and checkpoints unchanged;
it did not repeat the full cleanup/shutdown/checkpoint maintenance cycle.

REFERENCES
https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/powershell-direct
https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/checkpoints
https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder
https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdatesearcher-search
https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdateinstaller2-put_forcequiet
https://learn.microsoft.com/en-us/windows/win32/api/wuapi/ne-wuapi-deploymentaction
https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdateinstaller4-commit
https://learn.microsoft.com/en-us/powershell/module/hyper-v/import-vm
https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/deploy/export-and-import-virtual-machines
