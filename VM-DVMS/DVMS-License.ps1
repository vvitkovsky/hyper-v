#Requires -Version 5.1
# Mirasys DVMS license files: base64( gzip( BinaryFormatter( UTF-16 XML string ) ) ),
# with an enveloped XML-DSig signature (C14N, RSA-SHA1, Reference URI="").
# Matches Mirasys/Common/Utils/License/CompressionExtensions.cs and
# Mirasys/Tools/DVMSLicense/LicenseEncoder/EncodeLicense.cs (SignAndPackLicense).
# BinaryFormatter and SignedXml need Windows PowerShell 5.1 (.NET Framework).
$script:DsigNamespace='http://www.w3.org/2000/09/xmldsig#'

function Get-DVMSLicenseKeys {
    # Reads the signing key pair from the legacy repository's committed history,
    # so local edits or another checked-out branch's working tree do not matter.
    param(
        [Parameter(Mandatory=$true)][string]$Repository,
        [string]$Revision='HEAD'
    )
    if (-not (Test-Path -LiteralPath (Join-Path $Repository '.git'))) { throw "Legacy repository not found: $Repository" }
    $read={
        param($Path)
        $text=& git -C $Repository show "${Revision}:$Path" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git show ${Revision}:$Path failed in ${Repository}: $text" }
        ($text -join "`n")
    }
    [pscustomobject]@{
        PublicKey=& $read 'Mirasys/Tools/DVMSLicense/LicenseDecoder/PublicKey.xml'
        PrivateKey=& $read 'Mirasys/Tools/DVMSLicense/LicenseEncoder/PrivateKey.xml'
    }
}

function ConvertFrom-DVMSLicenseCode([string]$Code) {
    $compressed=[Convert]::FromBase64String($Code.Trim())
    $stream=New-Object IO.MemoryStream(,$compressed)
    $gzip=New-Object IO.Compression.GZipStream($stream,[IO.Compression.CompressionMode]::Decompress)
    $raw=New-Object IO.MemoryStream
    try { $gzip.CopyTo($raw) } finally { $gzip.Dispose() }
    $raw.Position=0
    $value=(New-Object Runtime.Serialization.Formatters.Binary.BinaryFormatter).Deserialize($raw)
    if ($value -isnot [string]) { throw "License payload is $($value.GetType().FullName), not a string." }
    $value
}

function ConvertTo-DVMSLicenseCode([string]$Xml) {
    $serialized=New-Object IO.MemoryStream
    (New-Object Runtime.Serialization.Formatters.Binary.BinaryFormatter).Serialize($serialized,$Xml)
    $output=New-Object IO.MemoryStream
    $gzip=New-Object IO.Compression.GZipStream($output,[IO.Compression.CompressionMode]::Compress,$true)
    $bytes=$serialized.ToArray()
    try { $gzip.Write($bytes,0,$bytes.Length) } finally { $gzip.Dispose() }
    [Convert]::ToBase64String($output.ToArray())
}

function Test-DVMSLicenseSignature([string]$Xml,[string]$PublicKey) {
    $document=New-Object Xml.XmlDocument
    $document.PreserveWhitespace=$false
    $document.LoadXml($Xml)
    $signature=$document.GetElementsByTagName('Signature',$script:DsigNamespace)
    if ($signature.Count -ne 1) { return $false }
    $rsa=New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.FromXmlString($PublicKey)
        $signed=New-Object Security.Cryptography.Xml.SignedXml($document)
        $signed.LoadXml([Xml.XmlElement]$signature[0])
        $signed.CheckSignature($rsa)
    } finally { $rsa.Dispose() }
}

function Read-DVMSLicense {
    # Decodes and verifies a license file; returns its XML and a short summary.
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$PublicKey)
    $xml=ConvertFrom-DVMSLicenseCode ([IO.File]::ReadAllText($Path))
    if (-not (Test-DVMSLicenseSignature $xml $PublicKey)) { throw "License signature is not valid: $Path" }
    $document=New-Object Xml.XmlDocument
    $document.LoadXml($xml)
    [pscustomobject]@{
        Xml=$xml
        Product=[string]$document.License.Product
        SerialNumber=[string]$document.License.SerialNumber
        Version=[string]$document.License.Version
        Macs=@($document.SelectNodes('/License/Protection[@Type="MAC"]') | ForEach-Object { $_.InnerText })
    }
}

function ConvertTo-LicenseMac([string]$MacAddress) {
    # Hyper-V reports 00155D66E30C; licenses use 00-15-5D-66-E3-0C.
    $hex=($MacAddress -replace '[-_:;,.~| ]','').ToUpperInvariant()
    if ($hex -notmatch '^[0-9A-F]{12}$' -or $hex -eq '000000000000') { throw "Not a usable MAC address: '$MacAddress'" }
    ($hex -split '(..)' | Where-Object { $_ }) -join '-'
}

function Set-DVMSLicenseMac {
    # Replaces the first MAC protection entry, re-signs exactly like
    # EncodeLicense.SignAndPackLicense, and verifies the packed result.
    param(
        [Parameter(Mandatory=$true)][string]$Xml,
        [Parameter(Mandatory=$true)][string]$MacAddress,
        [Parameter(Mandatory=$true)][string]$PrivateKey,
        [Parameter(Mandatory=$true)][string]$PublicKey
    )
    $mac=ConvertTo-LicenseMac $MacAddress
    $document=New-Object Xml.XmlDocument
    $document.LoadXml($Xml)
    $nodes=@($document.SelectNodes('/License/Protection[@Type="MAC"]'))
    if ($nodes.Count -eq 0) { throw 'The license has no MAC protection entry to replace.' }
    foreach ($old in @($document.GetElementsByTagName('Signature',$script:DsigNamespace))) { [void]$old.ParentNode.RemoveChild($old) }
    $nodes[0].InnerText=$mac
    $rsa=New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.FromXmlString($PrivateKey)
        $signed=New-Object Security.Cryptography.Xml.SignedXml($document)
        $signed.SigningKey=$rsa
        $signed.SignedInfo.CanonicalizationMethod=[Security.Cryptography.Xml.SignedXml]::XmlDsigCanonicalizationUrl
        $reference=New-Object Security.Cryptography.Xml.Reference('')
        $reference.AddTransform((New-Object Security.Cryptography.Xml.XmlDsigEnvelopedSignatureTransform($false)))
        $signed.AddReference($reference)
        $signed.ComputeSignature()
        [void]$document.DocumentElement.AppendChild($signed.GetXml())
    } finally { $rsa.Dispose() }
    # Writing through a StringWriter keeps the original utf-16 XML declaration.
    $writer=New-Object IO.StringWriter
    $xmlWriter=[Xml.XmlWriter]::Create($writer)
    try { $document.WriteTo($xmlWriter); $xmlWriter.Flush() } finally { $xmlWriter.Dispose() }
    $code=ConvertTo-DVMSLicenseCode $writer.ToString()
    $check=ConvertFrom-DVMSLicenseCode $code
    if (-not (Test-DVMSLicenseSignature $check $PublicKey)) { throw 'The re-signed license did not verify against the public key.' }
    $checkDocument=New-Object Xml.XmlDocument
    $checkDocument.LoadXml($check)
    if ($checkDocument.SelectNodes('/License/Protection[@Type="MAC"]')[0].InnerText -ne $mac) { throw 'The re-signed license does not contain the new MAC address.' }
    [pscustomobject]@{Code=$code;Mac=$mac}
}
