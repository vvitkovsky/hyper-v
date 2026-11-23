#Requires -Version 5.1
<#
.SYNOPSIS
Runs a PowerShell script as administrator in Windows PowerShell 5.1 and returns
its output and exit code to the caller.

.DESCRIPTION
Hyper-V cmdlets and this repository's VM scripts need an administrator. The
scripts elevate themselves, but into a separate window whose output the caller
cannot read. This wrapper keeps the output:

- In an elevated session it runs the script directly.
- Otherwise it starts it elevated, which shows one UAC prompt that the user
  must approve, and repeats what the script prints while it runs.

Either way every line is also appended to a log file, whose path is the first
line printed. The script runs with -NonInteractive, so a question it would ask
(a missing parameter) fails at once instead of waiting for an answer. -NoPause
is added for scripts that declare it.

.PARAMETER Parameters
Parameters for the script as a hashtable. $true passes a switch, numbers and
arrays are passed as such, everything else as a literal string.

.EXAMPLE
.\Invoke-Elevated.ps1 -ScriptPath ..\..\..\..\VM-NightlyUpdate\Create-VM.ps1 -Parameters @{
    TemplateName='Windows 11 Template'; Name='Windows 11 Test'
    Destination='A:\VMs\Windows 11 Test'; ComputerName='WIN11-Test' }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ScriptPath,
    [hashtable]$Parameters = @{},
    [string]$LogPath
)
$ErrorActionPreference='Stop'

function ConvertTo-ArgumentLiteral($Value) {
    if ($null -eq $Value) { throw 'Parameter values must not be $null.' }
    if ($Value -is [bool] -or $Value -is [switch]) { if ([bool]$Value) { return '$true' } else { return '$false' } }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return ([IConvertible]$Value).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [array]) { return '@('+((@($Value) | ForEach-Object { ConvertTo-ArgumentLiteral $_ }) -join ',')+')' }
    "'"+[Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent([string]$Value)+"'"
}

$script=(Resolve-Path -LiteralPath $ScriptPath).ProviderPath
if ([IO.Path]::GetExtension($script) -ne '.ps1') { throw "Not a PowerShell script: $script" }
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($script,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw "The script has syntax errors: $($parseErrors[0].Message)" }
$declared=@()
if ($ast.ParamBlock) { $declared=@($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
$common=@('WhatIf','Confirm','Verbose','Debug','ErrorAction','WarningAction','InformationAction')
$arguments=@{}
foreach ($key in $Parameters.Keys) {
    if ($key -notin $declared -and $key -notin $common) { throw "$(Split-Path -Leaf $script) has no parameter -$key. It has: $(($declared | ForEach-Object { "-$_" }) -join ', ')" }
    $arguments[[string]$key]=$Parameters[$key]
}
if ($declared -contains 'NoPause' -and -not $arguments.ContainsKey('NoPause')) { $arguments['NoPause']=$true }
$argumentText=(@($arguments.Keys | Sort-Object | ForEach-Object { "-${_}:$(ConvertTo-ArgumentLiteral $arguments[$_])" }) -join ' ')

if (-not $LogPath) {
    $name=[IO.Path]::GetFileNameWithoutExtension($script)
    $LogPath=Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'vm-use') ("{0}-{1:yyyyMMdd-HHmmss}.log" -f $name,(Get-Date))
}
$LogPath=[IO.Path]::GetFullPath($LogPath)
New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null
[IO.File]::WriteAllText($LogPath,'')

# Runs in Windows PowerShell 5.1. Every output stream goes to the log line by
# line, so the log can be followed while the script is still running. Lines are
# written with [Console]::Out: with redirected output Windows PowerShell would
# repeat anything sent through Write-Host as CLIXML on the error stream.
$inner=@"
`$ProgressPreference='SilentlyContinue'
`$log=$(ConvertTo-ArgumentLiteral $LogPath)
`$encoding=New-Object Text.UTF8Encoding(`$false)
`$global:LASTEXITCODE=0
`$code=1
try {
    & $(ConvertTo-ArgumentLiteral $script) $argumentText *>&1 | ForEach-Object {
        if (`$_ -is [Management.Automation.WarningRecord]) { 'WARNING: '+`$_.Message } else { `$_ }
    } | Out-String -Stream -Width 250 | ForEach-Object {
        [IO.File]::AppendAllText(`$log,`$_+"``r``n",`$encoding)
        [Console]::Out.WriteLine(`$_)
    }
    `$code=[int]`$LASTEXITCODE
} catch {
    `$message='FAILED: '+`$_.Exception.Message
    [IO.File]::AppendAllText(`$log,`$message+"``r``n",`$encoding)
    [Console]::Out.WriteLine(`$message)
    `$code=1
}
exit `$code
"@
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
$powershell="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$processArguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
$isAdmin=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Output "Log: $LogPath"
if ($isAdmin) {
    # The script's own output all arrives on the output stream. On the error
    # stream Windows PowerShell adds progress records of its jobs as CLIXML,
    # which is dropped here; anything else on that stream is passed on.
    $ErrorActionPreference='Continue'
    $clixml=$false
    & $powershell @processArguments 2>&1 | ForEach-Object {
        if ($_ -isnot [Management.Automation.ErrorRecord]) { return $_ }
        $text=[string]$_.Exception.Message
        if ($text -like '#< CLIXML*') { $clixml=$true }
        if (-not $clixml) { $text }
    }
    exit $LASTEXITCODE
}

Write-Output 'This session is not elevated: waiting for the user to approve the UAC prompt...'
try { $process=Start-Process -FilePath $powershell -Verb RunAs -PassThru -ArgumentList $processArguments }
catch {
    Write-Output "NOT STARTED: elevation was declined or timed out, so nothing ran. $($_.Exception.Message)"
    exit 1223
}
# Repeat the log here while the elevated window runs.
$stream=[IO.FileStream]::new($LogPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
$reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8)
$pending=''
try {
    do {
        $finished=$process.WaitForExit(1000)
        $pending+=$reader.ReadToEnd()
        $lines=$pending -split "`r?`n"
        $pending=$lines[-1]
        if ($lines.Count -gt 1) { $lines[0..($lines.Count-2)] | Write-Output }
    } until ($finished)
    $pending+=$reader.ReadToEnd()
    if ($pending) { $pending -split "`r?`n" | Where-Object { $_ } | Write-Output }
} finally { $reader.Dispose() }
exit $process.ExitCode
