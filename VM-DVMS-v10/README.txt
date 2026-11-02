DVMS v10 test VM (main branch) from the maintained template

Run New-VM-DVMS-v10.cmd and approve administrator elevation. It does everything
..\VM-DVMS\New-VM-DVMS.cmd does, but before the DVMS installer runs it installs
the microservices that v10 builds need (NATS, Consul, PostgreSQL, MongoDB,
OpenFGA, IAM, SSO, reverse proxy, observability and the VMS services) with the
build's own install script:
  \\rdfileserver\builds\DVMS\<version>\scripts\install.cmd

All questions come first, so the slow steps then run unattended:
  New VM name [Windows 11 Test]:
  Destination [A:\VMs\<chosen name>]:
  Windows computer name [WIN11-Test]:
  DVMS version [main]:            (only versions that have scripts\install.cmd are listed)
  Installer [1]:                  (only when the version has several installers)
  License file [<this folder>\License.lic]:
Press Enter to accept each default. When there is no License.lic in this folder,
the default is ..\VM-DVMS\License.lic.

WHAT IT DOES
1. Steps 1-7 of ..\VM-DVMS\README.txt: checks, license decode, installer cache,
   template copy and rename with the D: storage disk, static MAC, license
   re-signed for it and written to C:\Program Files\DVMS\Licenses\License.lic
   in the VM. The DVMS installer is
   cached in ..\VM-DVMS\.cache\<version>\, shared with New-VM-DVMS.cmd.
2. Before the VM is created, reads install.cmd on the host and resolves every
   share path it copies from (set MSI_SOURCE=\\rdfileserver\...,
   set EXE_SOURCE=...). A *_SOURCE value that is not a share path stops the run.
   The VM cannot reach
   the share, so each file is cached on the host under
   .cache\services\<server>\<share>\<path> (reused while size and time match)
   and copied into the VM under C:\DVMSSetup\Services\Sources\<server>\<share>\<path>.
3. Copies install.cmd into C:\DVMSSetup\Services with each \\<server>\ prefix
   rewritten to C:\DVMSSetup\Services\Sources\<server>\ (nothing else changes;
   the host copy is .cache\scripts\<version>\install.cmd), and runs it there:
     cmd /d /c .\install.cmd > install-services.log 2>&1
   Each MSI writes <msi>.install.log next to it.
4. Copies those logs to "<destination>\Install logs\Services", removes the
   copied installers from the VM and restarts Windows when the log contains
   "Restart the computer to complete the installation" (install.cmd still exits
   0 then). If install.cmd stops printing that line, the run warns before the VM
   is created.
5. Steps 8-9 of ..\VM-DVMS\README.txt: runs the DVMS installer, copies its logs
   to "<destination>\Install logs" and restarts Windows when it returns 3010.
6. Confirms a DVMS product is registered, D: is present, every MSI_CHECK file
   from install.cmd exists and the license file is still there, and warns about VMS* Windows
   services that are not running. The VM is left running.

The microservice order, MSI properties and keys all come from install.cmd on the
share, so changes to it on main are picked up without changing this script. A
share path outside a set line stops the run before the VM is created.

PARAMETERS (all optional; supplying one skips its question)
  -Name, -Destination, -ComputerName, -Version, -Installer (file name),
  -LicensePath, -TemplateName, -CheckpointName, -BuildRoot, -LegacyRepository,
  -InstallerArguments, -InstallTimeoutMinutes (default 120),
  -ServicesTimeoutMinutes (default 60), -StorageSizeGB (default 200), -NoPause
Example:
  .\New-VM-DVMS-v10.ps1 -Name 'DVMS v10' -ComputerName 'DVMS-V10' -Version main -LicensePath D:\License.lic

REQUIREMENTS
- Everything ..\VM-DVMS\README.txt lists; this script uses its DVMS-License.ps1
  and DVMS-Build.ps1.
- About 2.7 GB more free space on the cache drive for the microservice
  installers, and twice that plus 5 GB more on the VM drive.

FAILURES
Nothing is deleted on failure. The VM, its files, the host license copy, the
installers copied into the VM and any logs are kept for inspection, and the VM
is left as it is.

License*.lic files and .cache are excluded from git.
