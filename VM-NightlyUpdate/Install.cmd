@echo off
setlocal DisableDelayedExpansion

rem Asks for the VM, the daily time and the checkpoint; Enter accepts each default.
rem To skip a question, pass its value, for example:
rem   Install.cmd -VMName "Windows Server 2025 Template" -ScheduledTime 01:30 -CheckpointName clean
rem Other options such as -NoPause are forwarded too.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
exit /b %errorlevel%
