@echo off
setlocal DisableDelayedExpansion
rem Prompts for the VM name, destination, computer name, DVMS version (default main),
rem installer and license file (default License.lic next to this script, else ..\VM-DVMS\License.lic).
rem Windows PowerShell 5.1 is required: the license format uses BinaryFormatter.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-VM-DVMS-v10.ps1" %*
exit /b %errorlevel%
