@echo off
setlocal DisableDelayedExpansion
rem Prompts default to Windows 11 Test, A:\VMs\<chosen name> and a computer name
rem derived from the VM name, such as WIN11-Test; Enter accepts each.
set "TEMPLATE_NAME=Windows 11 Template"
set "CHECKPOINT_NAME=clean"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Create-VM.ps1" -TemplateName "%TEMPLATE_NAME%" -CheckpointName "%CHECKPOINT_NAME%" %*
exit /b %errorlevel%
