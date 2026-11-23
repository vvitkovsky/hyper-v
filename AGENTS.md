# hyper-v

PowerShell scripts for Hyper-V test VMs: nightly-updated template VMs and
copies of them, optionally with DVMS installed. [README.md](README.md) maps
the folders; each folder's `README.txt` describes its scripts in full.

## Agent skills

Task-specific skills are stored under `.agents/skills/`, one folder per skill
with a `SKILL.md`. This list is their index. When a task matches a skill, or
the user names one (`vm-use`, `/vm-use`, `$vm-use`), read its `SKILL.md`
completely and follow it before doing anything else.

- [`vm-use`](.agents/skills/vm-use/SKILL.md): create a test VM (clean, DVMS
  v9 or DVMS v10) from any installed template, work inside one, reset it to
  its checkpoint, or delete it. Use it for every such request instead of
  calling the scripts or Hyper-V directly.

A new skill needs its folder under `.agents/skills/` and one line here;
nothing is copied anywhere else.

## Working on the scripts

- The scripts run under Windows PowerShell 5.1 and need an administrator.
  They elevate themselves into a separate window, so do not start them just
  to try something: use `.agents/skills/vm-use/scripts/Invoke-Elevated.ps1`,
  which keeps their output, and say first that a UAC prompt may appear.
- The nightly task runs `VM-NightlyUpdate` straight from this checkout. A
  change there, or switching to a branch without those scripts, takes effect
  at the next nightly run.
- Never start, change, restore or delete a template VM, and leave VMs a task
  is not about alone.
- When behaviour changes, update the folder's `README.txt`, `README.md` and
  the `vm-use` skill in the same change, and add a dated entry to
  `VM-NightlyUpdate/Validation.txt` saying what was checked and what was not.
- Generated files stay out of git: `VM-NightlyUpdate/.state/`, the `.cache/`
  folders and `License*.lic`.
