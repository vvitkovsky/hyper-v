---
name: vm-use
description: Create, use, park and delete Hyper-V test VMs with this repository's scripts - a clean copy of any maintained template (Windows 11 or Windows Server), or a copy with DVMS v9 or DVMS v10 installed and licensed. Use when asked to create or prepare a test VM, to run something inside one, to reset it to its clean checkpoint, to park or resume it, or to remove it.
---

# Test VMs

A test VM is always created as a full, independent copy of a **template**. A
template is any VM with `Template` in its name, for example
`Windows 11 Template` or `Windows Server 2025 Template`; it stays Off and
`VM-NightlyUpdate` keeps it updated every night.

| Kind | What the VM has |
|---|---|
| `Clean` | Windows with its own computer name and nothing else installed. |
| `DVMS9` | As clean, plus a `D:` storage disk, a license bound to the VM's MAC address and a DVMS v9 build installed. |
| `DVMS10` | As `DVMS9` with a v10 build, plus its microservices and the recorder proxy. |

Create exactly the kind that was asked for, and nothing more. The default is a
clean VM: DVMS goes in only when the user asks for a VM with DVMS (VMS) in it.
A request to prepare, create or set up a VM is finished when the VM exists:
report it and stop. Installing anything in a VM, or running an installer there
(DVMS, one of its components, a build from a ticket), needs the user's request
for that installation, even when the task is about such an installer; "check",
"look at" or "review" is not one. When the task seems to need it, say what you
would install and run, how long it takes and what it changes, and wait.

Every copy has a checkpoint named like the template's (normally `clean`):
Windows with the new computer name, and for DVMS copies the empty `D:` drive,
**before** DVMS is installed.

All paths below are relative to the repository root; run the commands from there.

## Run everything through Invoke-Elevated.ps1

Hyper-V and the templates' saved state need an administrator and Windows
PowerShell 5.1. Use the wrapper for every script that touches a VM:

```powershell
.\.agents\skills\vm-use\scripts\Invoke-Elevated.ps1 -ScriptPath <script.ps1> -Parameters @{ Name='...'; Switch=$true }
```

- In an elevated session it runs the script directly. Otherwise it starts it
  elevated, which shows **one UAC prompt per call**. Tell the user a prompt is
  coming before each call, and put the work of one step into one script so
  there is one prompt, not several.
- It prints what the script prints, as it happens, and returns the script's
  exit code. The first line is the path of a log file with the same text.
- Exit code 1223 with `NOT STARTED` means the prompt was declined or timed out
  and nothing ran. Ask the user; do not retry in a loop.
- The script runs non-interactively: a question it would ask fails the run at
  once. An unknown parameter name is rejected before anything starts.
- Give paths inside `-Parameters` as absolute paths: the elevated script does
  not start in your working directory.
- If your commands run in a sandbox, run the wrapper outside it, asking for
  that approval if needed: a sandboxed process cannot raise the UAC prompt or
  reach Hyper-V.
- Creating a VM takes minutes, with DVMS longer. Start the wrapper as a
  background command when your shell tool has a time limit, never start a
  second copy of a run that is still going, and read the log file for progress.

## Create a VM

One call checks that the VM can be created, creates it, starts it, signs in on
its console and arms parking:

```powershell
.\.agents\skills\vm-use\scripts\Invoke-Elevated.ps1 -ScriptPath .\.agents\skills\vm-use\scripts\New-TestVM.ps1 -Parameters @{
    Kind         = 'Clean'                          # Clean (default), DVMS9 or DVMS10
    TemplateName = 'Windows Server 2025 Template'   # default: Windows 11 Template
    Ticket       = 'MS-10361'                       # optional: the Jira ticket the VM is for
}
```

- **It works out the rest** and prints it before starting: the VM name (the
  template name with `Template` replaced by `Test`, then the ticket, then the
  DVMS build: `Windows Server 2025 Test MS-10361`,
  `Windows 11 Test MS-10361 v9.10`), the computer name (`WS2025-MS10361`), the
  folder (`A:\VMs\<name>`), and for DVMS the build (the newest `release-v9.*`
  for `DVMS9`, `main` for `DVMS10`), its full installer and the license
  (`VM-DVMS\License.lic`).
- **`Plan=$true`** prints those values and changes nothing. Use it to tell the
  user what will be created when the request leaves something open.
- **Overrides:** `Name`, `ComputerName`, `Destination`, `Version`,
  `Installer`, `LicensePath`. `NoSignIn=$true` starts the VM without the
  console sign-in; `NoStart=$true` leaves it as the creation script does (a
  clean VM Off, a DVMS VM running, no parking armed).
- **It refuses,** before creating anything, when the template is not ready to
  copy, the name or folder exists, the drive lacks space, the build has no
  installer (or, for `DVMS10`, no `scripts\install.cmd`) or the license file
  is missing. Report what it says. For a missing license, ask the user for the
  path of a license file and pass it as `LicensePath`; do not search for one.
  A build that is only minutes old may still be publishing: look again later
  instead of choosing another version.
- **Result:** exit code 0 and `TEST VM READY: <name>` with its state and the
  user signed in on the console. Report those lines, and for DVMS the
  installed products, the MAC address and any `Services not running` warning
  printed above them.
- **Failures:** `NEW VM FAILED: <reason>` with exit code 1 means no usable VM;
  if a creation script had started, its own message is above and nothing it
  made was deleted, so tell the user what is left.
  `VM CREATED, BUT NOT READY: <reason>` with exit code 2 means the VM exists
  but could not be started or signed in to.
- If the console shows Windows' privacy settings page after sign-in, leave it
  for the user and never answer it (see [references/use.md](references/use.md)).

Create one VM at a time from a template. For anything this call does not
cover, or to understand a creation script's failure, read
[references/create.md](references/create.md).

## Other tasks

Read the reference completely before the task:

- **See what exists** (templates and whether each is ready, other VMs with
  their state and folder, free space). Read-only; `New-TestVM.ps1` makes these
  checks itself, so this is for answering the user or choosing a VM:

  ```powershell
  .\.agents\skills\vm-use\scripts\Invoke-Elevated.ps1 -ScriptPath .\.agents\skills\vm-use\scripts\Show-VMs.ps1
  ```

- **Work in a VM** (commands, files, the console, signing in to the VMS
  applications, parking, shutting down): [references/use.md](references/use.md)
- **Restore a checkpoint or delete a VM:**
  [references/reset-delete.md](references/reset-delete.md)

## Rules

- Templates are never started, changed, restored or deleted by an agent, and
  no VM is created from one while its nightly update is running.
- Creating a VM and installing anything in one each need a request for it.
  Deleting a VM, and restoring a checkpoint, each need the user's explicit go
  for that VM.
- Do not touch VMs the task is not about. Other people's work may be running
  in them.
- Credentials, license content and guest passwords never go into chat, logs,
  commands or repositories.
- When a script refuses or fails, report its message. The scripts' checks are
  deliberate; do not bypass them with direct Hyper-V commands.
