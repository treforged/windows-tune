<#
.SYNOPSIS
    Create the release-signing key pair on the maintainer's PC. Prints ONLY the public key and its fingerprint.

.DESCRIPTION
    Run once, by the person who cuts releases, on their own PC. It:
      - makes an RSA 3072-bit key pair in memory,
      - protects the PRIVATE key with Windows DPAPI (this user, this PC) and stores it in -KeyDir,
        which must NOT be inside any git working tree,
      - restricts that folder to the current user,
      - prints the PUBLIC key (XML) and its fingerprint, and nothing from the private key,
      - with -WritePublicKeyTo, also writes the public key to that file (scripts\update-pubkey.xml).
    It never overwrites an existing key and it never reads a credential or any other file.

    Back up the private key file yourself (DPAPI ties it to this user on this PC: a reinstall loses it).
    If it is lost, no new release can be signed for installs that already carry the old public key.

.PARAMETER KeyDir
    Where the private key goes. Default: %USERPROFILE%\.windows-tune-signing

.PARAMETER WritePublicKeyTo
    Also write the public key XML here (ASCII).
#>
[CmdletBinding()]
param(
    [string]$KeyDir = (Join-Path $env:USERPROFILE '.windows-tune-signing'),
    [string]$WritePublicKeyTo
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

function Test-InsideGitTree([string]$Path) {
    $p = [IO.Path]::GetFullPath($Path)
    while ($p) {
        if (Test-Path -LiteralPath (Join-Path $p '.git')) { return $true }
        $parent = Split-Path -Parent $p
        if (-not $parent -or $parent -eq $p) { break }
        $p = $parent
    }
    return $false
}
function Get-KeyFingerprint([string]$PublicKeyXml) {
    $r = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    try {
        $r.FromXmlString($PublicKeyXml)
        $q = $r.ExportParameters($false)
        $sha = [Security.Cryptography.SHA256]::Create()
        return (($sha.ComputeHash([byte[]]($q.Modulus + $q.Exponent)) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $r.Dispose() }
}

if (Test-InsideGitTree $KeyDir) { throw "REFUSED: $KeyDir is inside a git working tree. The private key must live outside every repo." }
$keyFile = Join-Path $KeyDir 'private.dpapi'
if (Test-Path -LiteralPath $keyFile) { throw "REFUSED: a key already exists at $keyFile. It is never overwritten." }

$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(3072)
$rsa.PersistKeyInCsp = $false
try {
    $privXml = $rsa.ToXmlString($true)
    $pubXml  = $rsa.ToXmlString($false)
    New-Item -ItemType Directory -Path $KeyDir -Force | Out-Null
    $blob = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($privXml), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllBytes($keyFile, $blob)
    $privXml = $null
    & icacls.exe $KeyDir /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "WARNING: could not restrict $KeyDir to the current user; DPAPI still protects the file." -ForegroundColor Yellow }
} finally { $rsa.Dispose() }

if ($WritePublicKeyTo) { [IO.File]::WriteAllText($WritePublicKeyTo, $pubXml, [Text.Encoding]::ASCII) }
Write-Host 'PUBLIC KEY (safe to publish):' -ForegroundColor Cyan
Write-Host $pubXml
Write-Host "FINGERPRINT (SHA-256 of modulus + exponent): $(Get-KeyFingerprint $pubXml)" -ForegroundColor Cyan
Write-Host "Private key stored (DPAPI, this user only): $keyFile" -ForegroundColor Green
Write-Host 'Back it up yourself. It is not in any repo and cannot be recovered if lost.' -ForegroundColor Yellow
exit 0
