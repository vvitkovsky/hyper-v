@echo off
setlocal DisableDelayedExpansion
rem Asks for the template (those installed with Install.cmd), the VM name, the
rem destination and the computer name; Enter accepts each default. Parameters
rem such as -TemplateName "Windows Server 2025 Template" are forwarded.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Create-VM.ps1" %*
exit /b %errorlevel%
