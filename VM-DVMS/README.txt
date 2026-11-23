DVMS test VM from a maintained template

Run New-VM-DVMS.cmd and approve administrator elevation. It creates a new VM from
a template kept up to date by ..\VM-NightlyUpdate, binds a DVMS license to the
new VM's MAC address and installs a DVMS build silently.

All questions come first, so the slow steps then run unattended:
  Template to copy [1]:           (numbered list of the VMs with "Template" in the
                                   name, as in ..\VM-NightlyUpdate\Create-VM.cmd;
                                   type a number or a name. Enter picks Windows 11
                                   Template, or the only template)
  New VM name [Windows 11 Test]:  (the template name with "Template" replaced by
                                   "Test"; the next two defaults follow it)
  Destination [A:\VMs\<chosen name>]:
  Windows computer name [WIN11-Test]:
  DVMS version [<number of main>]: (numbered list of version folders on the share;
                                   type a number or a version name)
  Installer [1]:                  (only when the version has several installers)
  License file [<this folder>\License.lic]:
Press Enter to accept each default.

Versions are folders under \\rdfileserver\builds\DVMS that contain installers
named either way:
  <version>_DVMS[_<brand>]_x64_<Full|Limited>.exe
  Mirasys-VMS-<Complete|Update>-<version>.exe   (release builds)
Unbranded installers are listed first, full (Full, Complete) before limited
(Limited, Update). So 1 is normally <version>_DVMS_x64_Full.exe, or
Mirasys-VMS-Complete-<version>.exe when a release has no unbranded _DVMS_ build.

WHAT IT DOES
1. Checks that the template VM exists and has saved guest credentials (from
   VM-NightlyUpdate\Install.cmd), the build share, the license and free space.
2. Decodes the license and verifies its signature. The key pair is read with
   git show HEAD:<path> from the legacy repository (default A:\src\legacy):
     Mirasys/Tools/DVMSLicense/LicenseDecoder/PublicKey.xml
     Mirasys/Tools/DVMSLicense/LicenseEncoder/PrivateKey.xml
3. Copies the installer to .cache\<version>\ on the host. A cached copy with the
   same size and time is reused; older builds of that version are replaced.
4. Copies the template and sets the Windows computer name, exactly as
   ..\VM-NightlyUpdate\Create-VM.cmd does. Before that first boot it attaches
   a dynamically expanding disk for recordings,
   <destination>\Virtual Hard Disks\Storage.vhdx (-StorageSizeGB, default 200),
   and during the boot formats it as NTFS drive D: labelled Storage. The DVD
   drive moves to the next free letter. The copy's clean checkpoint is the
   renamed Windows state with D: ready, before DVMS is installed.
5. Reads the network adapter's MAC address and makes it static, so moving or
   importing the VM cannot change it and invalidate the license.
6. Replaces the license's first MAC entry with the VM's MAC (other entries are
   kept), re-signs it like LicenseEncoder, verifies the result, and saves a copy
   as <destination>\License.lic.
7. Starts the VM and writes the license to C:\Program Files\DVMS\Licenses\License.lic.
8. Puts the installer on a disk of its own, <destination>\Install media.vhdx,
   attaches that to the running VM, mounts it in Windows as the folder
   C:\DVMSSetup\Media and runs the installer from there:
     <installer> /i /q /norestart /log "C:\DVMSSetup\DVMS-install.log"
   /norestart lets the script restart Windows itself when the installer returns
   3010. Override the switches with -InstallerArguments; /log is always added.
   The installer is not copied into Windows, which would take longer and leave
   the VM's disk larger by its size for good.
9. Copies the installer logs to "<destination>\Install logs", detaches and
   deletes the install media disk, confirms a DVMS product is registered, D: is
   present and the license file is still there. The VM is left running.

PARAMETERS (all optional; supplying one skips its question)
  -Name, -Destination, -ComputerName, -Version, -Installer (file name),
  -LicensePath, -TemplateName, -CheckpointName, -BuildRoot, -LegacyRepository,
  -InstallerArguments, -InstallTimeoutMinutes (default 120),
  -StorageSizeGB (default 200), -NoPause
Without -CheckpointName the checkpoint copied is the one the template's nightly
task refreshes, as in ..\VM-NightlyUpdate\Create-VM.cmd.
Example:
  .\New-VM-DVMS.ps1 -Name 'DVMS main' -ComputerName 'DVMS-MAIN' -Version main -LicensePath D:\License.lic

REQUIREMENTS
- Windows PowerShell 5.1 (the .cmd uses it): the license format needs
  BinaryFormatter and SignedXml from .NET Framework.
- The template must be off, with exactly one checkpoint of the name its
  nightly task refreshes (clean by default), and installed with
  ..\VM-NightlyUpdate\Install.cmd so that its guest credential is saved.
- git on PATH and the legacy repository checked out.
- Free space on the VM drive for a full template copy plus the installer and
  10 GB, and on the cache drive for the installer. The storage disk starts
  small and grows on the VM drive as recordings are written, up to its size.

VMS APPLICATION ACCOUNT FOR TEST VMS
Run Set-VMSCredential.cmd once and enter the account that the VMS applications
of a fresh installation are signed in to with (the installer's default
administrator). One account serves every test VM. It is saved to
.state\vms-app-credential.json with the password encrypted (machine DPAPI) in a
folder only SYSTEM and administrators can read, like the templates' guest
credentials. Agents read it with Get-VMUseAppCredential of the vm-use skill to
sign in to Spotter, System Manager and the other applications in a test VM.
Set-VMSCredential.cmd -Show prints the saved user name, never the password.
Run it again to change the account.

FAILURES
Nothing is deleted on failure. The VM, its files, the host license copy and any
installer logs are kept for inspection, and the VM is left as it is. After a
failed installation the install media disk is still attached and mounted.

License*.lic files, .cache and .state are excluded from git.
