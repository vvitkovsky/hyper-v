#Requires -Version 5.1
function Resolve-VMGuestCredential {
    [CmdletBinding()]
    param(
        [string]$VMUserName,
        [object]$VMPassword,
        [Management.Automation.PSCredential]$VMCredential,
        [string]$VMName = 'Windows 11',
        [switch]$Prompt
    )
    if ($VMCredential) {
        if ($VMUserName -or $null -ne $VMPassword) { throw 'Use -VMCredential OR -VMUserName/-VMPassword.' }
        if ($VMCredential.Password.Length -eq 0) { throw 'The VM password must not be empty.' }
        return $VMCredential
    }
    if ($null -ne $VMPassword -and [string]::IsNullOrWhiteSpace($VMUserName)) {
        throw '-VMPassword requires -VMUserName.'
    }
    if (-not [string]::IsNullOrWhiteSpace($VMUserName)) {
        if ($null -eq $VMPassword) {
            if (-not $Prompt) { throw '-VMUserName requires -VMPassword for an unattended run.' }
            $VMPassword = Read-Host "Password for VM user $VMUserName" -AsSecureString
        }
        if ($VMPassword -is [Security.SecureString]) { $password = $VMPassword }
        elseif ($VMPassword -is [string]) {
            if ($VMPassword.Length -eq 0) { throw 'The VM password must not be empty.' }
            $password = ConvertTo-SecureString -String $VMPassword -AsPlainText -Force
        } else { throw '-VMPassword must be a string or SecureString.' }
        if ($password.Length -eq 0) { throw 'The VM password must not be empty.' }
        return [Management.Automation.PSCredential]::new($VMUserName,$password)
    }
    if ($Prompt) {
        $result = Get-Credential -Message "Administrator credentials for the '$VMName' virtual machine"
        if (-not $result -or $result.Password.Length -eq 0) { throw 'Credentials were cancelled or password is empty.' }
        return $result
    }
    return $null
}

function Read-SavedVMGuestCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    # Written by Install.ps1 with machine DPAPI; requires System.Security.
    $saved = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
        [Convert]::FromBase64String($saved.Password), $null,
        [Security.Cryptography.DataProtectionScope]::LocalMachine)
    try {
        $secure = New-Object Security.SecureString
        foreach ($character in [Text.Encoding]::Unicode.GetString($bytes).ToCharArray()) { $secure.AppendChar($character) }
        $secure.MakeReadOnly()
        return [Management.Automation.PSCredential]::new([string]$saved.UserName, $secure)
    } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}
