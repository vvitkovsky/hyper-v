# Creating a VM with the underlying scripts

Read this when `New-TestVM.ps1` does not cover what is wanted, or to understand
a failure of the script it ran. `New-TestVM.ps1` calls these scripts with the
parameters described here.

| Kind | Script | Leaves the VM |
|---|---|---|
| Clean | `VM-NightlyUpdate\Create-VM.ps1` | Off |
| DVMS v9 | `VM-DVMS\New-VM-DVMS.ps1` | Running |
| DVMS v10 | `VM-DVMS-v10\New-VM-DVMS-v10.ps1` | Running |

Run them through `Invoke-Elevated.ps1`, never directly and never through the
`.cmd` launchers: they elevate into a separate window, where their output is
lost and their questions wait for a person. Under the wrapper a question fails
the run, so pass **every** parameter listed as required. The folder READMEs
(`VM-NightlyUpdate\README.txt`, `VM-DVMS\README.txt`, `VM-DVMS-v10\README.txt`)
describe each step and every parameter.

## Parameters all three take

- **`TemplateName`** (required): the exact name of a template from the
  overview that is ready to copy.
- **`Name`** (required): must not be used by another VM. Convention: the
  template name with `Template` replaced by `Test`, then the Jira ticket key
  when the work is for a ticket, then the build for DVMS, for example
  `Windows 11 Test MS-10361 v9.10`.
- **`Destination`** (required): `A:\VMs\<Name>` unless the user names another
  place. An absolute local path that does not exist yet.
- **`ComputerName`** (required): at most 15 letters, digits and hyphens, not
  only digits, no hyphen first or last, and different from VMs that will run
  at the same time. Convention: `Windows 11` becomes `WIN11`,
  `Windows Server 2025` becomes `WS2025`, then the ticket key without its
  hyphen (`WIN11-MS10361`).
- **`CheckpointName`** (optional): the checkpoint copied is the one the
  template's nightly task refreshes, normally `clean`.
- **Free space:** the destination drive needs the template's size from the
  overview, plus for DVMS the installer and 10 GB, and for DVMS v10 about
  15 GB plus twice the microservice installers. The DVMS scripts check this
  themselves; `Create-VM.ps1` does not.

Create one VM at a time from a template: copying holds the template's
maintenance lock.

## Clean VM

```powershell
.\.agents\skills\vm-use\scripts\Invoke-Elevated.ps1 -ScriptPath .\VM-NightlyUpdate\Create-VM.ps1 -Parameters @{
    TemplateName = 'Windows Server 2025 Template'
    Name         = 'Windows Server 2025 Test'
    Destination  = 'A:\VMs\Windows Server 2025 Test'
    ComputerName = 'WS2025-Test'
}
```

Success is exit code 0 and a last line starting `VM created with its own
disks`. A failure prints `COPY FAILED: <reason>` and exits 1.

## DVMS: the build and the license

These checks need no elevation:

```powershell
. .\VM-DVMS\DVMS-Build.ps1
$root = '\\rdfileserver\builds\DVMS'
Get-DVMSBuildVersions $root | Sort-Object Updated -Descending       # versions that have an installer
(Get-DVMSInstallers -BuildRoot $root -Version 'release-v9.10').Name # installers, the default choice first
Test-Path "$root\main\scripts\install.cmd"                          # required for DVMS v10
Test-Path .\VM-DVMS\License.lic
```

- **`Version`** (required): a folder name under the build share. For v9 the
  newest `release-v9.*` folder unless the user names one; for v10 `main`
  unless the user names another version that has `scripts\install.cmd`.
- **`Installer`** (required): a file name from `Get-DVMSInstallers`. Take the
  first, the unbranded full installer (`<version>_DVMS_x64_Full.exe` or
  `Mirasys-VMS-Complete-<version>.exe`), unless the user asks for a branded or
  a limited one.
- A build is published file by file. When a version's files are only minutes
  old and the full installer or `scripts\install.cmd` is missing, wait and
  look again. If it stays missing, tell the user; do not substitute another
  version or script.
- **`LicensePath`** (required): `VM-DVMS\License.lic` when it exists.
  Otherwise ask the user for the path of a license file and wait; do not
  search for one, and do not create or edit one. The scripts re-sign a copy
  for the new VM; the original is not changed. Never print a license's
  content or copy it into a repository.
- The license keys are read with `git show` from the legacy repository,
  `A:\src\legacy` by default (`LegacyRepository`); `git` must be on `PATH`.
- Optional: `StorageSizeGB` (default 200, dynamically expanding),
  `InstallTimeoutMinutes`, `InstallerArguments`, `BuildRoot`.

## DVMS v9

```powershell
.\.agents\skills\vm-use\scripts\Invoke-Elevated.ps1 -ScriptPath .\VM-DVMS\New-VM-DVMS.ps1 -Parameters @{
    TemplateName = 'Windows 11 Template'
    Name         = 'Windows 11 Test v9.10'
    Destination  = 'A:\VMs\Windows 11 Test v9.10'
    ComputerName = 'WIN11-Test-v9'
    Version      = 'release-v9.10'
    Installer    = 'Mirasys-VMS-Complete-release-v9.10.exe'
    LicensePath  = 'A:\src\hyper-v\VM-DVMS\License.lic'
}
```

Success is exit code 0 and `DVMS VM ready: <name> (computer name ..., MAC ...)`
followed by the installed products. A failure prints
`DVMS VM SETUP FAILED: <reason>` and exits 1.

## DVMS v10

The same call with `.\VM-DVMS-v10\New-VM-DVMS-v10.ps1`, `Version = 'main'` and
`Installer = 'main_DVMS_x64_Full.exe'`. Extra optional parameters:
`ServicesTimeoutMinutes`, `RecorderProxyInstaller` (a full path),
`NoRecorderProxy`.

Do not use `VM-DVMS\New-VM-DVMS.ps1` for a v10 build: DVMS would be installed
without the microservices it needs.

Success is exit code 0 and `DVMS v10 VM ready: ...`. Read the lines after it:
`Services not running: ...` is a warning the user must hear about, not a
failure of the run.

## After a run

- Trust the exit code and the final lines, not the absence of errors.
- For DVMS the VM's folder also holds `License.lic` (the copy bound to this
  VM) and `Install logs` (`Services` and `RecorderProxy` subfolders for v10).
  After a failed installation it also holds `Install media.vhdx`, the disk
  with the installers, still attached to the VM and mounted as
  `C:\DVMSSetup\Media`.
- **Nothing is deleted when a run fails.** The VM, its folder and the logs
  stay for inspection, and the VM is left as it was (possibly running). Read
  the reason and the logs, and tell the user what is left behind. A second run
  with the same name or folder is rejected, so either use new ones or delete
  the leftover first, with the user's agreement.
- These scripts do not start a clean VM, sign in or arm parking; see
  [use.md](use.md).
