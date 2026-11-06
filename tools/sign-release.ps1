<#
.SYNOPSIS
    Sign a release zip: writes <zip>.sig (base64 RSA/SHA-256 signature) and checks it against the public key.

.DESCRIPTION
    Run by the maintainer on the PC that holds the key made by new-signing-key.ps1. Upload the .sig to the
    same GitHub release as the zip, named windows-tune-vX.Y.Z.zip.sig. The installed copies verify it against
    the public key shipped in scripts\update-pubkey.xml before Install mode installs anything.

.PARAMETER Zip
    The release zip to sign.

.PARAMETER KeyDir
    Where new-signing-key.ps1 stored the private key. Default: %USERPROFILE%\.windows-tune-signing
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Zip,
    [string]$KeyDir = (Join-Path $env:USERPROFILE '.windows-tune-signing')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$keyFile = Join-Path $KeyDir 'private.dpapi'
if (-not (Test-Path -LiteralPath $Zip -PathType Leaf)) { throw "Zip not found: $Zip" }
if (-not (Test-Path -LiteralPath $keyFile -PathType Leaf)) { throw "No private key at $keyFile. Run tools\new-signing-key.ps1 first." }

$bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Zip).Path)
$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
try {
    $priv = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($keyFile), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser))
    $rsa.FromXmlString($priv); $priv = $null
    $sig = $rsa.SignData($bytes, 'SHA256')
    $ok = $rsa.VerifyData($bytes, 'SHA256', $sig)
} finally { $rsa.Dispose() }
if (-not $ok) { throw 'The signature did not verify against its own key. Nothing was written.' }
$out = "$Zip.sig"
[IO.File]::WriteAllText($out, [Convert]::ToBase64String($sig), [Text.Encoding]::ASCII)
Write-Host "Signed: $out ($($sig.Length) bytes). Upload it to the same release as the zip." -ForegroundColor Green
exit 0
