@echo off
setlocal DisableDelayedExpansion

rem Edit these settings. Use a 24-hour time in HH:mm format.
set "VM_NAME=Windows 11 Template"
set "SCHEDULED_TIME=00:00"
set "CHECKPOINT_NAME=clean"

rem Pass settings directly. Additional options such as -NoPause are forwarded.
rem For one-off VM/time/checkpoint values, call Install.ps1 directly instead.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" -VMName "%VM_NAME%" -ScheduledTime "%SCHEDULED_TIME%" -CheckpointName "%CHECKPOINT_NAME%" %*
exit /b %errorlevel%
