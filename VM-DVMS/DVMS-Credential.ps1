#Requires -Version 5.1
# The VMS application account that test VMs are signed in to with: the
# installer's default administrator. One account serves every test VM. It is
# stored like the templates' guest credentials: the password encrypted with
# machine DPAPI, in a folder only SYSTEM and administrators can read.
# Requires System.Security (Add-Type -AssemblyName System.Security).

function Get-DVMSAppCredentialPath {
    Join-Path (Join-Path $PSScriptRoot '.state') 'vms-app-credential.json'
}

function Save-DVMSAppCredential {
    param([Parameter(Mandatory=$true)][Management.Automation.PSCredential]$Credential,[string]$Path = (Get-DVMSAppCredentialPath))
    if ([string]::IsNullOrWhiteSpace($Credential.UserName)) { throw 'The user name must not be empty.' }
    if ($Credential.Password.Length -eq 0) { throw 'The password must not be empty.' }
    $folder=Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sidText in @('S-1-5-18','S-1-5-32-544')) {
        $sid=[Security.Principal.SecurityIdentifier]::new($sidText)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit, ObjectInherit','None','Allow'))
    }
    Set-Acl -LiteralPath $folder -AclObject $acl
    $bytes=[Text.Encoding]::Unicode.GetBytes($Credential.GetNetworkCredential().Password)
    try {
        $encrypted=[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
        [ordered]@{ UserName=$Credential.UserName; Password=[Convert]::ToBase64String($encrypted) } |
            ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8
    } finally { [Array]::Clear($bytes,0,$bytes.Length) }
    $Path
}

function Read-DVMSAppCredential {
    param([string]$Path = (Get-DVMSAppCredentialPath))
    if (-not (Test-Path -LiteralPath $Path)) { throw "No VMS application credential is saved. Ask the user to run VM-DVMS\Set-VMSCredential.cmd once." }
    $saved=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $bytes=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($saved.Password),$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
    try {
        $secure=New-Object Security.SecureString
        foreach ($character in [Text.Encoding]::Unicode.GetString($bytes).ToCharArray()) { $secure.AppendChar($character) }
        $secure.MakeReadOnly()
        [Management.Automation.PSCredential]::new([string]$saved.UserName,$secure)
    } finally { [Array]::Clear($bytes,0,$bytes.Length) }
}
