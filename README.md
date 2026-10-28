# hyper-v

PowerShell scripts for Hyper-V test VMs. One VM, `Windows 11 Template`, is kept
up to date every night. New test VMs are copied from it whenever they are
needed, for example for AI test runs, optionally with DVMS installed and
licensed.

| Folder | What it does | Start with |
|---|---|---|
| [`VM-NightlyUpdate`](VM-NightlyUpdate/README.txt) | Nightly maintenance of the template, and plain copies of it | `Install.cmd`, `Create-VM.cmd` |
| [`VM-DVMS`](VM-DVMS/README.txt) | A copy of the template with a DVMS build installed and a license bound to the VM | `New-VM-DVMS.cmd` |

Each folder's `README.txt` has the full details, parameters and failure behaviour.

## How it fits together

```text
VM-NightlyUpdate nightly task ──► Windows 11 Template   (A:\HyperV Template, Off, checkpoint "clean")
                                         │
              ┌──────────────────────────┴───────────────────────────┐
              ▼                                                      ▼
   VM-NightlyUpdate\Create-VM.cmd                         VM-DVMS\New-VM-DVMS.cmd
              │                                  + installer from \\rdfileserver\builds\DVMS\<version>
              │                                  + License.lic, keys from A:\src\legacy
              ▼                                                      ▼
   test VM: own disks and computer name, Off      test VM: licensed for its MAC, DVMS installed, Running
```

- **The template** stays Off between runs. Every night a scheduled task
  (`HyperVNightlyUpdate-<VM ID>`, running as SYSTEM) starts it, installs all
  offered Windows updates, runs DISM component cleanup, shuts it down and
  refreshes its `clean` checkpoint. Copies made earlier are not affected.
- **Copies** are independent full copies with a new VM ID, all disks inside
  their own folder (default `A:\VMs\<name>`) and their own Windows computer
  name. Their `clean` checkpoint is the renamed Windows state.
- **DVMS copies** also get a static MAC address and a DVMS license re-signed
  for that address, which is written to `C:\Program Files\DVMS\Licenses`
  before the selected build is installed silently.

## Quick start

1. **Once:** set up nightly maintenance for the template. Run
   `VM-NightlyUpdate\Install.cmd`, approve elevation and enter an administrator
   account from inside the template VM. The credential is saved encrypted under
   `VM-NightlyUpdate\.state` and reused by every other script.
2. **A plain test VM:** run `VM-NightlyUpdate\Create-VM.cmd` and answer the
   prompts (name, destination, computer name). Enter accepts each default.
3. **A DVMS test VM:** put a license at `VM-DVMS\License.lic` (or give another
   path when asked), run `VM-DVMS\New-VM-DVMS.cmd` and choose the version
   (default `main`) and installer.

All launchers elevate themselves and use Windows PowerShell 5.1.

## Requirements

- Windows with Hyper-V, and an administrator account on the host.
- The template VM `Windows 11 Template`, Off, with exactly one `clean`
  checkpoint and the Guest Service Interface integration service enabled.
- Free space on the VM drive for a full copy of the template (about 40 GB), plus
  the installer and about 10 GB for DVMS copies.
- For `VM-DVMS`: access to `\\rdfileserver\builds\DVMS`, `git` on `PATH`, and the
  legacy repository at `A:\src\legacy` (the license keys are read from it with
  `git show`).

## Notes

- The scheduled task runs the scripts straight from `VM-NightlyUpdate` in this
  checkout. Keep the folder in place, and run `Install.cmd` again after moving
  or renaming it. Switching to a branch without these scripts makes the next
  nightly run fail.
- Generated files stay out of git: `VM-NightlyUpdate/.state/` (credentials,
  config, logs), `VM-DVMS/.cache/` (cached installers) and `VM-DVMS/License*.lic`.
- Nothing is deleted when a step fails. VMs, files and logs are left for
  inspection.
