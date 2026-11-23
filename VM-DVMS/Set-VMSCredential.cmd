@echo off
setlocal DisableDelayedExpansion
rem Asks once for the VMS application account that test VMs are signed in to with
rem (the installer's default administrator) and saves it encrypted on this host.
rem -Show prints the saved user name, never the password.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-VMSCredential.ps1" %*
exit /b %errorlevel%
