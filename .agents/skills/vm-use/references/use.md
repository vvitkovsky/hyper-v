# Working in a VM

Work inside a VM goes through PowerShell Direct, which needs no network. Write
a script, outside the repository, that loads the helpers by this checkout's
absolute path, and run it through `Invoke-Elevated.ps1`:

```powershell
$ErrorActionPreference = 'Stop'
. 'A:\src\hyper-v\.agents\skills\vm-use\scripts\VM-Use.ps1'
$vm = Get-VMUseVM 'Windows 11 Test'                 # exactly one VM with this name
$vm = Start-VMUseVM -VM $vm                         # starts or resumes it, arms parking
$cred = Get-VMUseCredential -VM $vm                 # waits for Windows, then signs in

Invoke-Command -VMId $vm.Id -Credential $cred -ScriptBlock { Get-Service 'VMS*' }

$session = New-PSSession -VMId $vm.Id -Credential $cred
Copy-Item -ToSession $session -Path 'C:\Temp\build\*' -Destination 'C:\Temp\' -Recurse
Copy-Item -FromSession $session -Path 'C:\ProgramData\<app>\Logs\*' -Destination 'C:\Temp\vm-logs' -Recurse
Remove-PSSession $session
```

- Begin every script with `Start-VMUseVM`, whatever state the VM is in. It
  starts the VM from Off, resumes it when it is parked or paused, marks it as
  in use for as long as the script runs, and arms the parking countdown.
- Address the VM by `$vm.Id` after resolving it, never by name again.
- With `$ErrorActionPreference = 'Stop'` a failing step ends the script and
  the wrapper returns exit code 1.
- `VM-Use.ps1` also loads the repository's own helpers, among them
  `Invoke-VMGuestCommand` (a guest command with a timeout, 60 seconds by
  default) and `Wait-VMGuest` (waits for a new boot after a restart).
- `Get-VMUseCredential` returns the guest administrator account. Copies keep
  the account of their template, so it uses the credential saved for the
  templates; `-TemplateName` limits it to one template. If it reports that no
  saved credential works, tell the user and stop: do not ask for a password in
  chat and do not guess accounts. Never print the credential.
- Do not assume the VM can reach network shares. Copy what it needs from the
  host. For large files, `Copy-VMFile -VM $vm -SourcePath <host file>
  -DestinationPath <guest path> -CreateFullPath -FileSource Host` is faster
  than a session copy.
- Shut down with `Stop-VMUseGuest -VM $vm -Credential $cred` (it asks Windows
  to shut down and waits for Off). Do not turn a VM off forcibly.
- Bring logs and results back to the host, outside the repositories, before a
  restore or a delete.

## The console

PowerShell Direct does not sign anybody in on the VM's screen. For work that
needs the desktop (a program with a window, a screenshot, a recording, or
someone watching in Hyper-V's basic session), sign in on the console first:

```powershell
$user = Connect-VMUseConsole -VM $vm -Credential $cred
```

It selects the credential's account on the sign-in screen, types the password
on the VM's virtual keyboard and returns the signed-in user; when someone is
already signed in it returns at once. `New-TestVM.ps1` does this for a VM it
creates.

If the account has never signed in on the template's console, Windows shows
its privacy settings page first: leave it for the user, never answer it, and
tell them the template needs its one-time console sign-in (see
`VM-NightlyUpdate\README.txt`).

## Signing in to VMS applications

The VMS applications in a DVMS VM (Spotter, System Manager, the web clients)
have their own accounts, separate from Windows. One test account serves every
test VM: the default administrator of a fresh installation, which the user
saved once on this host.

```powershell
$app = Get-VMUseAppCredential          # the VMS account; $cred stays the Windows one
```

- Use it inside the script only: `$app.UserName` and
  `$app.GetNetworkCredential().Password`, passed as arguments to a guest
  command or typed on the console. Never print it, put it in a command line
  or a log, or write it to a file.
- To fill in a sign-in window on the console, type with the virtual keyboard
  after signing in there with `Connect-VMUseConsole`:

  ```powershell
  Send-VMUseKey -VM $vm -KeyCode 0x52 -Hold 0x5B     # Win+R opens the Run box
  Send-VMUseText -VM $vm -Text '"C:\Program Files\<app folder>\<app>.exe"'
  Send-VMUseKey -VM $vm -KeyCode 13                  # Enter
  # ... once the application's sign-in window has the focus:
  Send-VMUseText -VM $vm -Text $app.UserName
  Send-VMUseKey -VM $vm -KeyCode 9                   # Tab
  Send-VMUseText -VM $vm -Text $app.GetNetworkCredential().Password
  Send-VMUseKey -VM $vm -KeyCode 13
  ```

  The keyboard types into whatever has the focus, so check where that is
  first (a guest command listing the foreground window, or a screenshot), and
  wait for each window before typing into it. Take the application's path
  from the VM; it differs between v9 (`C:\Program Files\DVMS`) and v10
  (`C:\Program Files\Mirasys VMS`).
- If `Get-VMUseAppCredential` says no credential is saved, tell the user to
  run `VM-DVMS\Set-VMSCredential.cmd` once, and stop. Do not ask for the
  password in chat and do not try default passwords.
- If the applications reject the account, report that and stop; the saved
  account may not match this build. Do not create or change accounts in the
  VMS unless the user asks for it.
- Signing in to an installed application is use, not installation, but what
  you do in it after signing in still follows the user's request.

## Parking

A running VM holds host memory. A test VM that nobody uses is therefore
**parked**: its state is saved to disk, the memory is freed, and the next
`Start-VMUseVM` resumes it exactly where it was, with its programs still
running. Parking needs no agent session: a one-time scheduled task per VM
(`VMUsePark-<VM ID>`, running as SYSTEM) does it.

- `Start-VMUseVM` arms the countdown: the VM is parked 10 minutes later
  (`-ParkAfterMinutes`). While a script that called `Start-VMUseVM` is still
  running when that time comes, parking is postponed by the same interval, so
  a long installation is never interrupted.
- So a VM is parked at most 10 minutes after the last script that used it
  ended. For a full 10 minutes from the end of your work, finish the script
  with `Register-VMUsePark -VM $vm`, which restarts the countdown.
- `Park-TestVM.ps1` parks a VM at once, schedules parking (`AfterMinutes`) or
  cancels it (`Cancel=$true`); `ShutDown=$true` shuts Windows down instead of
  saving the state, for when the user wants the VM off:

  ```powershell
  .\.agents\skills\vm-use\scripts\Invoke-Elevated.ps1 -ScriptPath .\.agents\skills\vm-use\scripts\Park-TestVM.ps1 -Parameters @{ Name='Windows 11 Test'; AfterMinutes=10 }
  ```

- When the user wants a VM kept running, for example for manual testing, use
  `Start-VMUseVM -VM $vm -NoPark` or cancel the parking, and say so. Do not
  re-arm it for that VM until the user says the VM is no longer needed.
- Leave the VM running when your work in it is done, with parking armed, and
  tell the user its state, when it will be parked and that using it again
  resumes it. The overview shows `Saved (parked)` and pending parking times; a
  scheduled parking writes a line to `Park.log` in the VM's folder.
- A parked VM has a saved state. Restoring a checkpoint and deleting the VM
  both discard it. Templates are never parked.
