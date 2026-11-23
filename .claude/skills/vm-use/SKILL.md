---
name: vm-use
description: Create, use and delete Hyper-V test VMs with this repository's scripts - a clean copy of any maintained template (Windows 11 or Windows Server), or a copy with DVMS v9 or DVMS v10 installed and licensed. Use when asked to create or prepare a test VM, to run something inside one, to reset it to its clean checkpoint, or to remove it.
---

# Test VMs

Test VMs are full, independent copies of a **template**: a VM that
`VM-NightlyUpdate` keeps updated every night and that stays Off. Any installed
template can be copied, for example `Windows 11 Template` or
`Windows Server 2025 Template`.

| Wanted | Script | Result |
|---|---|---|
| Clean VM | `VM-NightlyUpdate\Create-VM.ps1` | Windows with its own computer name. Left **Off**. |
| DVMS v9 | `VM-DVMS\New-VM-DVMS.ps1` | As clean, plus a `D:` storage disk, a license bound to the VM's MAC address and the DVMS build installed. Left **Running**. |
| DVMS v10 | `VM-DVMS-v10\New-VM-DVMS-v10.ps1` | As v9, plus the microservices from the build's `scripts\install.cmd` and the recorder proxy. Left **Running**. |

Every copy has a checkpoint named like the template's (normally `clean`):
Windows with the new computer name, and for DVMS copies the empty `D:` drive,
**before** DVMS is installed.

The folder READMEs (`README.md`, `VM-NightlyUpdate\README.txt`,
`VM-DVMS\README.txt`, `VM-DVMS-v10\README.txt`) describe each step and every
parameter. Read the one for the script you run when something here is not enough.

All paths below are relative to the repository root; run the commands from there.

## Run everything through Invoke-Elevated.ps1

Hyper-V cmdlets, the creation scripts and the templates' saved state need an
administrator and Windows PowerShell 5.1. Use the wrapper for every script that
touches Hyper-V:

```powershell
.\.claude\skills\vm-use\scripts\Invoke-Elevated.ps1 -ScriptPath <script.ps1> -Parameters @{ Name='...'; Switch=$true }
```

- In an elevated session it runs the script directly. Otherwise it starts it
  elevated, which shows **one UAC prompt per call**. Tell the user a prompt is
  coming before each call, and put the work of one step into one script so
  there is one prompt, not several.
- It prints what the script prints, as it happens, and returns the script's
  exit code. The first line is the path of a log file with the same text.
- Exit code 1223 with `NOT STARTED` means the prompt was declined or timed out
  and nothing ran. Ask the user; do not retry in a loop.
- The script runs non-interactively: a question it would ask fails the run
  immediately. So pass **every** parameter that has a prompt (listed per script
  below). `-NoPause` is added for you.
- An unknown parameter name is rejected before anything starts.
- Give paths inside `-Parameters` (destination, license, files) as absolute
  paths: the elevated script does not start in your working directory.

Do not run the creation scripts or the `.cmd` launchers directly: they elevate
into a separate window, where their output is lost and their questions wait
for a person.

Creation runs for a long time: a clean copy takes several minutes, the DVMS
variants much longer (the scripts allow the installer up to 120 minutes). Start
the wrapper as a background command when your shell tool has a time limit,
never start a second copy of a run that is still going, and read the log file
for progress.

## 1. Look first

```powershell
.\.claude\skills\vm-use\scripts\Invoke-Elevated.ps1 -ScriptPath .\.claude\skills\vm-use\scripts\Show-VMs.ps1
```

This read-only overview lists the templates (name, state, checkpoint, size,
whether each is ready to copy), every other VM with its folder and
checkpoints, and free disk space and host memory.

A template is ready when it is Off, has exactly one checkpoint with the listed
name and has a saved guest credential. When it is not ready, tell the user why
and stop. Never start, stop, change or restore a template yourself, and do not
create VMs while its nightly update is running (the overview shows the time).

## 2. Decide the parameters

Take from the user's request what it gives, choose the rest as below, and tell
the user the template, name, folder and (for DVMS) build you are going to use
before starting. Ask only when the request leaves a real choice open, for
example which of several templates or DVMS versions.

- **Template** (`-TemplateName`): the exact name from the overview. Use the one
  the request implies ("a Windows Server VM"). When it implies none, use
  `Windows 11 Template`, the scripts' own default.
- **Name** (`-Name`): must not be used by another VM. The scripts' convention
  is the template name with `Template` replaced by `Test`, for example
  `Windows Server 2025 Test`. Add what distinguishes this VM, for example
  `Windows 11 Test DVMS v9.10`.
- **Destination** (`-Destination`): `A:\VMs\<Name>` unless the user names
  another place. It must be an absolute local path that does not exist yet.
- **Computer name** (`-ComputerName`): at most 15 letters, digits and hyphens,
  not only digits, no hyphen first or last, and different from VMs that will
  run at the same time. The
  scripts' convention: `Windows 11` becomes `WIN11`, `Windows Server 2025`
  becomes `WS2025`, other characters become hyphens (`WIN11-Test`).
- **Free space**: the destination drive needs the template's size from the
  overview, plus for DVMS the installer and 10 GB, and for DVMS v10 about
  15 GB plus twice the microservice installers. The DVMS scripts check this
  themselves; `Create-VM.ps1` does not, so compare the numbers yourself.
- **Host memory**: every variant starts the copy at least once.

Create one VM at a time from a template: copying holds the template's
maintenance lock.

## 3. Create

### Clean VM

```powershell
.\.claude\skills\vm-use\scripts\Invoke-Elevated.ps1 -ScriptPath .\VM-NightlyUpdate\Create-VM.ps1 -Parameters @{
    TemplateName = 'Windows Server 2025 Template'
    Name         = 'Windows Server 2025 Test'
    Destination  = 'A:\VMs\Windows Server 2025 Test'
    ComputerName = 'WS2025-Test'
}
```

All four parameters are required here (each has a prompt). The checkpoint
copied is the one the template's nightly task refreshes; `-CheckpointName`
overrides it.

Success is exit code 0 and a last line starting `VM created with its own
disks`. A failure prints `COPY FAILED: <reason>` and exits 1.

### DVMS: find the build and the license first

These checks need no elevation:

```powershell
. .\VM-DVMS\DVMS-Build.ps1
$root = '\\rdfileserver\builds\DVMS'
Get-DVMSBuildVersions $root | Sort-Object Updated -Descending       # versions that have an installer
(Get-DVMSInstallers -BuildRoot $root -Version 'release-v9.10').Name # installers, the default choice first
Test-Path "$root\main\scripts\install.cmd"                          # required for DVMS v10
Test-Path .\VM-DVMS\License.lic
```

- **Version** (`-Version`): a folder name under the build share. For **v9**
  use the newest `release-v9.*` folder (for example `release-v9.10`) unless
  the user names one. For **v10** use `main` unless the user names another
  version that has `scripts\install.cmd`.
- **Installer** (`-Installer`): a file name from `Get-DVMSInstallers`. Take the
  first, which is the unbranded full installer (`<version>_DVMS_x64_Full.exe`
  or `Mirasys-VMS-Complete-<version>.exe`), unless the user asks for a branded
  or a limited one. Always pass it: a version with several installers
  otherwise asks.
- A build is published file by file. When a version's files are only minutes
  old and the full installer or `scripts\install.cmd` is missing, wait and
  look again before concluding that it is absent. If it stays missing, tell
  the user; do not substitute another version or script.
- **License** (`-LicensePath`): `VM-DVMS\License.lic` when it exists.
  Otherwise ask the user for the path of a license file and wait; do not
  search for one, and do not create or edit one. Always pass the path. The
  scripts re-sign a copy for the new VM; the original is not changed. Never
  print a license's content or copy it into a repository.
- The license keys are read with `git show` from the legacy repository,
  `A:\src\legacy` by default (`-LegacyRepository`); `git` must be on `PATH`.

### DVMS v9

```powershell
.\.claude\skills\vm-use\scripts\Invoke-Elevated.ps1 -ScriptPath .\VM-DVMS\New-VM-DVMS.ps1 -Parameters @{
    TemplateName = 'Windows 11 Template'
    Name         = 'Windows 11 Test DVMS v9.10'
    Destination  = 'A:\VMs\Windows 11 Test DVMS v9.10'
    ComputerName = 'DVMS-V910'
    Version      = 'release-v9.10'
    Installer    = 'Mirasys-VMS-Complete-release-v9.10.exe'
    LicensePath  = 'A:\src\hyper-v\VM-DVMS\License.lic'
}
```

Required (each has a prompt): `TemplateName`, `Name`, `Destination`,
`ComputerName`, `Version`, `Installer`, `LicensePath`. As with `Create-VM.ps1`,
the checkpoint copied is the one the template's nightly task refreshes.
Optional: `CheckpointName`, `StorageSizeGB`
(default 200, dynamically expanding), `InstallTimeoutMinutes`,
`InstallerArguments`, `BuildRoot`, `LegacyRepository`.

Success is exit code 0 and `DVMS VM ready: <name> (computer name ..., MAC ...)`
followed by the installed products. A failure prints
`DVMS VM SETUP FAILED: <reason>` and exits 1.

### DVMS v10

Same parameters, with `VM-DVMS-v10\New-VM-DVMS-v10.ps1` and a version that has
`scripts\install.cmd`:

```powershell
.\.claude\skills\vm-use\scripts\Invoke-Elevated.ps1 -ScriptPath .\VM-DVMS-v10\New-VM-DVMS-v10.ps1 -Parameters @{
    TemplateName = 'Windows 11 Template'
    Name         = 'Windows 11 Test DVMS main'
    Destination  = 'A:\VMs\Windows 11 Test DVMS main'
    ComputerName = 'DVMS-MAIN'
    Version      = 'main'
    Installer    = 'main_DVMS_x64_Full.exe'
    LicensePath  = 'A:\src\hyper-v\VM-DVMS\License.lic'
}
```

Extra optional parameters: `ServicesTimeoutMinutes`, `RecorderProxyInstaller`
(a full path), `NoRecorderProxy`.

Do not use `VM-DVMS\New-VM-DVMS.ps1` for a v10 build: DVMS would be installed
without the microservices it needs.

Success is exit code 0 and `DVMS v10 VM ready: ...`. Read the lines after it:
`Services not running: ...` is a warning the user must hear about, not a
failure of the run.

## 4. Check and report

- Trust the exit code and the final lines, not the absence of errors.
- Report the VM name, computer name, folder, template and checkpoint, the
  state it was left in, and for DVMS the installed products, the MAC address
  and any warnings.
- For DVMS the folder also holds `License.lic` (the copy bound to this VM) and
  `Install logs` (`Services` and `RecorderProxy` subfolders for v10).
- **Nothing is deleted when a run fails.** The VM, its folder and the logs
  stay for inspection, and the VM is left as it was (possibly running). Read
  the reason and the logs, and tell the user what is left behind. A second run
  with the same name or folder is rejected, so either use new ones or delete
  the leftover first, with the user's agreement.

## Use a VM

Work inside a VM goes through PowerShell Direct, which needs no network. Write
a script, outside the repository, that loads the helpers by this checkout's
absolute path, and run it through the wrapper:

```powershell
$ErrorActionPreference = 'Stop'
. 'A:\src\hyper-v\.claude\skills\vm-use\scripts\VM-Use.ps1'
$vm = Get-VMUseVM 'Windows 11 Test'                 # exactly one VM with this name
if ($vm.State -eq 'Off') { Start-VM -VM $vm }
$cred = Get-VMUseCredential -VM $vm                 # waits for Windows, then signs in

Invoke-Command -VMId $vm.Id -Credential $cred -ScriptBlock { Get-Service 'VMS*' }

$session = New-PSSession -VMId $vm.Id -Credential $cred
Copy-Item -ToSession $session -Path 'C:\Temp\build\*' -Destination 'C:\Temp\' -Recurse
Copy-Item -FromSession $session -Path 'C:\ProgramData\<app>\Logs\*' -Destination 'C:\Temp\vm-logs' -Recurse
Remove-PSSession $session
```

- `VM-Use.ps1` also loads the repository's own helpers, among them
  `Invoke-VMGuestCommand` (a guest command with a timeout, 60 seconds by
  default) and `Wait-VMGuest` (waits for a new boot after a restart).
- `Get-VMUseCredential` returns the guest administrator account. Copies keep
  the account of their template, so it uses the credential saved for the
  templates; `-TemplateName` limits it to one template. If it reports that no
  saved credential works, tell the user and stop: do not ask for a password in
  chat and do not guess accounts. Never print the credential.
- Address the VM by `$vm.Id` after resolving it, never by name again.
- With `$ErrorActionPreference = 'Stop'` a failing step ends the script and
  the wrapper returns exit code 1.
- Do not assume the VM can reach network shares. Copy what it needs from the
  host. For large files, `Copy-VMFile -VM $vm -SourcePath <host file>
  -DestinationPath <guest path> -CreateFullPath -FileSource Host` is faster
  than a session copy.
- Shut down with `Stop-VMUseGuest -VM $vm -Credential $cred` (it asks Windows
  to shut down and waits for Off). Do not turn a VM off forcibly.
- Leave the VM in the state the user expects and say which state that is.
  Bring logs and results back to the host, outside the repositories, before a
  restore or a delete.

### Reset to the checkpoint

Restoring throws away everything done in the VM since the checkpoint. **For a
DVMS VM that includes DVMS itself**, the microservices and the license file in
the VM, because the checkpoint was taken before they were installed. The
license copy in the VM's folder on the host stays valid: the MAC address is
static.

Restore only when the user asks for a clean machine. When a task needs one and
the user has not asked, say what the restore will discard and wait.

```powershell
$checkpoints = @(Get-VMSnapshot -VM $vm | Where-Object Name -EQ 'clean')
if ($checkpoints.Count -ne 1) { throw "Expected one 'clean' checkpoint, found $($checkpoints.Count)." }
Restore-VMSnapshot -VMSnapshot $checkpoints[0] -Confirm:$false
if ((Get-VM -Id $vm.Id).State -eq 'Off') { Start-VM -VM $vm }
```

Never delete, rename or replace a VM's checkpoint. Create another checkpoint,
for example one with DVMS installed, only when the user asks for it.

## Delete a VM

Deleting removes the VM, its checkpoints and its whole folder, with the
license copy and the install logs. It cannot be undone.

1. Dry run, which changes nothing and prints the VM, its folder and size:

   ```powershell
   .\.claude\skills\vm-use\scripts\Invoke-Elevated.ps1 -ScriptPath .\.claude\skills\vm-use\scripts\Remove-TestVM.ps1 -Parameters @{ Name='Windows 11 Test'; WhatIf=$true }
   ```

2. Show the user that output and ask whether to delete. A request to delete
   "the test VM" names one VM; it is not permission to delete others.
3. After a clear yes, run the same command without `WhatIf`. Success is exit
   code 0 and `Deleted VM ...`; a failure prints `DELETE FAILED: <reason>`.

The script refuses templates, a VM whose folder is not laid out as these
scripts make it, and a folder that another VM also uses. Do not work around a
refusal with `Remove-VM` or `Remove-Item`; tell the user what it said.

## Rules

- Templates are never started, changed, restored or deleted by an agent.
- Creating a VM needs a request for it. Deleting one, and restoring a
  checkpoint, each need the user's explicit go for that VM.
- Do not touch VMs the task is not about. Other people's work may be running
  in them.
- Credentials, license content and guest passwords never go into chat, logs,
  commands or repositories.
- When a script refuses or fails, report its message. The scripts' checks are
  deliberate; do not bypass them with direct Hyper-V commands.
