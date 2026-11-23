# Resetting and deleting a VM

Both throw work away and neither can be undone. Each needs the user's explicit
go for that VM.

## Reset to the checkpoint

Restoring throws away everything done in the VM since the checkpoint. **For a
DVMS VM that includes DVMS itself**, the microservices and the license file in
the VM, because the checkpoint was taken before they were installed. The
license copy in the VM's folder on the host stays valid: the MAC address is
static.

Restore only when the user asks for a clean machine. When a task needs one and
the user has not asked, say what the restore will discard and wait. Bring logs
and results back to the host first.

In a script run through `Invoke-Elevated.ps1`, with the helpers loaded as in
[use.md](use.md):

```powershell
$checkpoints = @(Get-VMSnapshot -VM $vm | Where-Object Name -EQ 'clean')
if ($checkpoints.Count -ne 1) { throw "Expected one 'clean' checkpoint, found $($checkpoints.Count)." }
Restore-VMSnapshot -VMSnapshot $checkpoints[0] -Confirm:$false
$vm = Start-VMUseVM -VM $vm
```

Never delete, rename or replace a VM's checkpoint. Create another checkpoint,
for example one with DVMS installed, only when the user asks for it.

## Delete a VM

Deleting removes the VM, its checkpoints, any saved state and its whole
folder, with the license copy and the install logs.

1. Dry run, which changes nothing and prints the VM, its folder and size:

   ```powershell
   .\.agents\skills\vm-use\scripts\Invoke-Elevated.ps1 -ScriptPath .\.agents\skills\vm-use\scripts\Remove-TestVM.ps1 -Parameters @{ Name='Windows 11 Test'; WhatIf=$true }
   ```

2. Show the user that output and ask whether to delete. A request to delete
   "the test VM" names one VM; it is not permission to delete others.
3. After a clear yes, run the same command without `WhatIf`. Success is exit
   code 0 and `Deleted VM ...`; a failure prints `DELETE FAILED: <reason>`.

The script refuses templates, a VM whose folder is not laid out as these
scripts make it, and a folder that another VM also uses. Do not work around a
refusal with `Remove-VM` or `Remove-Item`; tell the user what it said.
