# hyper-v

PowerShell scripts for Hyper-V test VMs. Template VMs, such as
`Windows 11 Template` and `Windows Server 2025 Template`, are kept up to date
every night. New test VMs are copied from any of them whenever they are
needed, for example for AI test runs, optionally with DVMS installed and
licensed.

| Folder | What it does | Start with |
|---|---|---|
| [`VM-NightlyUpdate`](VM-NightlyUpdate/README.txt) | Nightly maintenance of the templates, and plain copies of them | `Install.cmd`, `Create-VM.cmd` |
| [`VM-DVMS`](VM-DVMS/README.txt) | A copy of a template with a DVMS build installed and a license bound to the VM | `New-VM-DVMS.cmd` |
| [`VM-DVMS-v10`](VM-DVMS-v10/README.txt) | As `VM-DVMS`, for v10 (main) builds, plus the microservices from the build's `scripts\install.cmd` | `New-VM-DVMS-v10.cmd` |

Each folder's `README.txt` has the full details, parameters and failure behaviour.

## How it fits together

```text
VM-NightlyUpdate nightly tasks ─► a template VM   (Windows 11 Template, Windows Server 2025 Template, ...:
                                         │         each Off, with its own task and "clean" checkpoint)
              ┌──────────────────────────┴───────────────────────────┐
              ▼                                                      ▼
   VM-NightlyUpdate\Create-VM.cmd                         VM-DVMS\New-VM-DVMS.cmd
              │                                  + installer from \\rdfileserver\builds\DVMS\<version>
              │                                  + License.lic, keys from A:\src\legacy
              ▼                                                      ▼
   test VM: own disks and computer name, Off      test VM: licensed for its MAC, DVMS installed, Running
```

- **A template** is a VM with `Template` in its name, kept only to be copied;
  there can be several, for example one for Windows 11 and one for Windows
  Server. `Install.cmd` sets up its nightly maintenance and saves the guest
  credential the creation scripts need, so a template is ready to copy once
  that has been run for it. Each stays Off
  between runs and has its own scheduled task (`HyperVNightlyUpdate-<VM ID>`,
  running as SYSTEM), time and checkpoint. Every night the task starts the
  template, installs all offered Windows updates, runs DISM component
  cleanup, shuts it down and refreshes its checkpoint (`clean` by default).
  Copies made earlier are not affected.
- **Copies** are independent full copies with a new VM ID, all disks inside
  their own folder (default `A:\VMs\<name>`) and their own Windows computer
  name. Their `clean` checkpoint is the renamed Windows state.
  Every creation script asks which template to copy (Enter picks
  `Windows 11 Template`); `-TemplateName` skips the question.
- **DVMS copies** also get a static MAC address and a DVMS license re-signed
  for that address, which is written to `C:\Program Files\DVMS\Licenses`
  before the selected build is installed silently, and a second, dynamically
  expanding disk formatted as `D:` (`Storage`) for recordings. The installer
  reaches the VM on an install media disk that is attached for the
  installation and removed afterwards, so it is never copied into Windows.
- **DVMS v10 copies** (`VM-DVMS-v10`) also run the build's
  `scripts\install.cmd` in the VM before the DVMS installer, with the
  microservice installers it needs on the same install media disk, because
  the VM cannot reach the build share. After the DVMS installer they install
  the recorder proxy service from `VmsRecorderProxyService` on the same share.

## Quick start

1. **Once per template:** set up nightly maintenance. Run
   `VM-NightlyUpdate\Install.cmd`, approve elevation, choose the template from
   the VM list (Enter picks Windows 11 Template), the time and the checkpoint,
   and enter an administrator account from inside the template VM. Run it
   again for each further template, such as a Windows Server one. Each
   template's credential is saved encrypted under `VM-NightlyUpdate\.state`
   and reused by every other script.
2. **A plain test VM:** run `VM-NightlyUpdate\Create-VM.cmd` and answer the
   prompts (template, name, destination, computer name). Enter accepts each default.
3. **A DVMS test VM:** put a license at `VM-DVMS\License.lic` (or give another
   path when asked), run `VM-DVMS\New-VM-DVMS.cmd` and choose the version
   (default `main`) and installer, after the same template and name questions.
4. **A DVMS v10 test VM with microservices:** run
   `VM-DVMS-v10\New-VM-DVMS-v10.cmd`. It asks the same questions and uses
   `VM-DVMS\License.lic` unless `VM-DVMS-v10\License.lic` exists.

All launchers elevate themselves and use Windows PowerShell 5.1.

AI agents create, use and delete these VMs with the `vm-use` skill in
[`.agents/skills/vm-use`](.agents/skills/vm-use/SKILL.md), which runs the same
scripts without their questions. [`AGENTS.md`](AGENTS.md), which `CLAUDE.md`
imports, lists the skills for every agent working in this repository.

The skill also parks a test VM that has not been used for 10 minutes: a
one-time scheduled task (`VMUsePark-<VM ID>`, running as SYSTEM) saves its
state, which frees the host's memory, and the next use resumes it.
`.agents/skills/vm-use/scripts/Park-TestVM.ps1` parks a VM by hand or cancels
pending parking.

## Requirements

- Windows with Hyper-V, and an administrator account on the host.
- At least one template VM, for example `Windows 11 Template`: Off, with
  exactly one checkpoint of the name chosen in `Install.cmd` (`clean` by
  default).
- Free space on the VM drive for a full copy of the template (about 65 GB for
  `Windows 11 Template` and 33 GB for `Windows Server 2025 Template`), plus
  the installer and about 10 GB for DVMS copies, and for DVMS v10 copies about
  15 GB plus twice the microservice installers (about 2.6 GB for main).
- For `VM-DVMS` and `VM-DVMS-v10`: access to `\\rdfileserver\builds`, `git` on `PATH`, and the
  legacy repository at `A:\src\legacy` (the license keys are read from it with
  `git show`).

## Notes

- The scheduled task runs the scripts straight from `VM-NightlyUpdate` in this
  checkout. Keep the folder in place, and run `Install.cmd` again after moving
  or renaming it. Switching to a branch without these scripts makes the next
  nightly run fail.
- Generated files stay out of git: `VM-NightlyUpdate/.state/` (credentials,
  config, logs), `VM-DVMS/.cache/` and `VM-DVMS-v10/.cache/` (cached
  installers) and `License*.lic` in both DVMS folders.
- Nothing is deleted when a step fails. VMs, files and logs are left for
  inspection.
