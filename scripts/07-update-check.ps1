# 07-update-check.ps1 - checks GitHub for a newer windows-tune release and OFFERS it.
#
# What it does:
#   1. Reads the installed version from VERSION beside the scripts.
#   2. Asks the public GitHub API for the latest release (read-only, no token).
#   3. Says UP TO DATE, NEWER, or UNKNOWN. A failed read is UNKNOWN, never up to date.
#   4. With -Download and your yes, fetches the zip, checks its SHA256 against the
#      digest GitHub publishes for that asset, and stops. It does NOT install.
#
# What it does NOT do: install anything, run anything from the download, or change
# the machine. Updating is a separate, deliberate step: run install.ps1 -FromZip.
#
# Trust limit (say it, do not hide it): the digest comes from the same GitHub
# release as the zip. That proves the file is the one GitHub published, not that
# GitHub or the maintainer account is trustworthy. The pinned hash in install.ps1
# on main is the only independent check, and it is only as good as main.

param(
    [switch]$Download
)

$ErrorActionPreference = 'Stop'

$root = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) } else { throw 'Run this from the windows-tune folder. The script path could not be resolved.' }

$Repo = 'treforged/windows-tune'

# Pure: no network, no disk. Returns a verdict object.
function Get-UpdateVerdict {
    param(
        [string]$Installed,
        $Latest
    )
    $unknown = [pscustomobject]@{ Status = 'Unknown'; Installed = $Installed; Latest = $null; Digest = $null; Url = $null }
    if (-not $Installed -or $Installed -notmatch '^v\d+\.\d+\.\d+$') { return $unknown }
    if (-not $Latest -or -not $Latest.tag_name) { return $unknown }
    $tag = [string]$Latest.tag_name
    if ($tag -notmatch '^v\d+\.\d+\.\d+$') { return $unknown }
    $asset = @($Latest.assets | Where-Object { $_.name -eq "windows-tune-$tag.zip" })
    if ($asset.Count -ne 1) { return $unknown }
    $digest = [string]$asset[0].digest
    if ($digest -notmatch '^sha256:[0-9a-fA-F]{64}$') { return $unknown }
    # the download must come from this repo's own release page, never from anywhere the API names
    $url = [string]$asset[0].browser_download_url
    if ($url -notlike "https://github.com/treforged/windows-tune/releases/download/$tag/*") { return $unknown }

    $iv = [version]$Installed.TrimStart('v')
    $lv = [version]$tag.TrimStart('v')
    $status = if ($lv -gt $iv) { 'Newer' } else { 'UpToDate' }
    [pscustomobject]@{
        Status    = $status
        Installed = $Installed
        Latest    = $tag
        Digest    = $digest.Substring(7).ToLowerInvariant()
        Url       = $url
    }
}

$versionFile = Join-Path $root 'VERSION'
$installed = if (Test-Path -LiteralPath $versionFile) { (Get-Content -LiteralPath $versionFile -Raw).Trim() } else { $null }

$latest = $null
try {
    $latest = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'Accept' = 'application/vnd.github+json' } -TimeoutSec 15
} catch {
    Write-Host "Could not reach GitHub: $($_.Exception.Message)" -ForegroundColor Yellow
}

$v = Get-UpdateVerdict -Installed $installed -Latest $latest
switch ($v.Status) {
    'UpToDate' { Write-Host "windows-tune $($v.Installed) is the latest release ($($v.Latest))." -ForegroundColor Green }
    'Newer'    { Write-Host "A newer release is available: $($v.Latest) (you have $($v.Installed))." -ForegroundColor Cyan }
    default    { Write-Host "Update status UNKNOWN. Nothing was checked, so this is not a claim you are up to date." -ForegroundColor Yellow }
}

if ($Download -and $v.Status -eq 'Newer') {
    $zip = Join-Path $env:TEMP "windows-tune-$($v.Latest).zip"
    Invoke-WebRequest -UseBasicParsing -Uri $v.Url -OutFile $zip -TimeoutSec 120
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
    if ($actual -ne $v.Digest) {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        throw "SHA256 mismatch: expected $($v.Digest), got $actual. The download was deleted and nothing was installed."
    }
    Write-Host "Downloaded and verified: $zip" -ForegroundColor Green
    Write-Host "Nothing is installed yet. To update, run install.ps1 -FromZip with this file." -ForegroundColor Cyan
}
