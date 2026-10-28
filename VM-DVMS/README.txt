DVMS test VM from the maintained template

Run New-VM-DVMS.cmd and approve administrator elevation. It creates a new VM from
the Windows 11 Template kept up to date by ..\VM-NightlyUpdate, binds a DVMS
license to the new VM's MAC address and installs a DVMS build silently.

All questions come first, so the slow steps then run unattended:
  New VM name [Windows 11 Test]:
  Destination [A:\VMs\<chosen name>]:
  Windows computer name [WIN11-Test]:
  DVMS version [main]:            (the list shows version folders on the share)
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
   ..\VM-NightlyUpdate\Create-VM.cmd does. The copy's clean checkpoint is
   the renamed Windows state before DVMS is installed.
5. Reads the network adapter's MAC address and makes it static, so moving or
   importing the VM cannot change it and invalidate the license.
6. Replaces the license's first MAC entry with the VM's MAC (other entries are
   kept), re-signs it like LicenseEncoder, verifies the result, and saves a copy
   as <destination>\License.lic.
7. Starts the VM and writes the license to C:\Program Files\DVMS\Licenses\License.lic.
8. Copies the installer to C:\DVMSSetup with Copy-VMFile and runs it:
     <installer> /i /q /norestart /log "C:\DVMSSetup\DVMS-install.log"
   /norestart lets the script restart Windows itself when the installer returns
   3010. Override the switches with -InstallerArguments; /log is always added.
9. Copies the installer logs to "<destination>\Install logs", removes the
   installer from the VM, confirms a DVMS product is registered and the license
   file is still present. The VM is left running.

PARAMETERS (all optional; supplying one skips its question)
  -Name, -Destination, -ComputerName, -Version, -Installer (file name),
  -LicensePath, -TemplateName, -CheckpointName, -BuildRoot, -LegacyRepository,
  -InstallerArguments, -InstallTimeoutMinutes (default 120), -NoPause
Example:
  .\New-VM-DVMS.ps1 -Name 'DVMS main' -ComputerName 'DVMS-MAIN' -Version main -LicensePath D:\License.lic

REQUIREMENTS
- Windows PowerShell 5.1 (the .cmd uses it): the license format needs
  BinaryFormatter and SignedXml from .NET Framework.
- The template must be off, with exactly one clean checkpoint.
- git on PATH and the legacy repository checked out.
- Free space on the VM drive for a full template copy plus the installer and
  10 GB, and on the cache drive for the installer.

FAILURES
Nothing is deleted on failure. The VM, its files, the host license copy and any
installer logs are kept for inspection, and the VM is left as it is.

License*.lic files and .cache are excluded from git.
