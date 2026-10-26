<#
.SYNOPSIS
    Download windows-tune from GitHub into a local folder. Runs nothing.

.DESCRIPTION
    Downloads one PINNED release zip from github.com over HTTPS (or uses a
    zip you already have), checks its SHA256 against the value written in
    this file, and refuses to unpack it if they differ. It then unpacks it to
    %ProgramFiles%\windows-tune, unblocks the files so Windows does not refuse
    to run them, and tells you how to start. It does not execute any
    downloaded file.

    The default folder needs administrator rights, so run this from an
    ELEVATED PowerShell. That is the point: the menu runs its scripts as
    administrator, and a folder only administrators can write is the one a
    normal program cannot plant a script in. The menu refuses to elevate from
    any other folder (audit 2c24feed lead 1).

    Any *-revert.ps1 or *.log files already in the target folder are left
    alone: those are your own revert files from earlier runs.

.PARAMETER Path
    Where to install. Default: %ProgramFiles%\windows-tune (needs admin).
    A folder you can write without admin works, but the menu then runs only
    its read-only options from there.

.PARAMETER FromZip
    Use this local zip instead of downloading (offline install, or the test).

.PARAMETER Sha256
    Expected SHA256 of the zip. A download is always checked against the
    pinned value below. A -FromZip zip is checked against this value, or,
    when it is not given, against the pinned release hash - an unchecked
    zip is never unpacked.

.PARAMETER Launch
    Open the windows-tune menu after installing. Off by default.

.EXAMPLE
    Invoke-WebRequest https://raw.githubusercontent.com/treforged/windows-tune/main/install.ps1 -OutFile install.ps1
    notepad .\install.ps1
    powershell -ExecutionPolicy Bypass -File .\install.ps1
    Download it, read it, then run it from an ELEVATED PowerShell. There is deliberately no one-line
    "pipe the download into PowerShell" form - see NOTICE.md.

.EXAMPLE
    .\install.ps1 -FromZip .\windows-tune.zip -Path $env:LOCALAPPDATA\windows-tune-test
#>
[CmdletBinding()]
param(
    [string]$Path = (Join-Path $env:ProgramFiles 'windows-tune'),
    [string]$FromZip,
    [string]$Sha256,
    [switch]$Launch
)

$ErrorActionPreference = 'Stop'

# The release this installer downloads, and the SHA256 of that exact zip.
# Both change together, in one commit, when a new release is cut. The hash is
# what makes a swapped or corrupted download fail instead of install.
$ReleaseTag    = 'v1.1.0'
$ReleaseSha256 = 'd149d12dc6b604b92325cb181e69144279363e740b2cb9159bd23338df06af65'
$ReleaseUrl    = "https://github.com/treforged/windows-tune/releases/download/$ReleaseTag/windows-tune-$ReleaseTag.zip"

function Assert-ZipHash([string]$ZipPath, [string]$Expected) {
    if ($Expected -notmatch '^[0-9a-fA-F]{64}$') { throw "No valid SHA256 to check the zip against: [$Expected]. Refusing to install." }
    $actual = (Get-FileHash -Algorithm SHA256 -Path $ZipPath).Hash
    if ($actual -ne $Expected.ToUpperInvariant()) {
        throw "SHA256 mismatch. Expected $($Expected.ToUpperInvariant()), got $actual. The zip was not unpacked."
    }
    Write-Host "SHA256 verified: $actual" -ForegroundColor Green
}
$tempZip = $null
$tempFolder = $null

try {
    # The default folder is admin-only by design. Without admin the copy would fail half way, so say it first.
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin -and -not $PSBoundParameters.ContainsKey('Path')) {
        throw "The default folder $Path needs administrator rights. Run this from an ELEVATED PowerShell. (-Path <folder> installs a copy that runs only the read-only options.) Nothing was installed."
    }
    # Elevated, stage under Program Files, not %TEMP%. %TEMP% is writable by every program running as
    # you, so a file could be swapped there between the hash check and the copy into the admin-only
    # folder. Folders made under Program Files inherit its admin-only ACL.
    $stageRoot = if ($isAdmin) { $env:ProgramFiles } else { $env:TEMP }
    if ($FromZip) {
        if (-not (Test-Path $FromZip)) { throw "Zip not found: $FromZip" }
        # Hash and unpack a private copy, so the zip that is checked is the zip that is unpacked.
        $tempZip = Join-Path $stageRoot ('windows-tune-' + [Guid]::NewGuid().ToString() + '.zip')
        Copy-Item -LiteralPath (Resolve-Path $FromZip).Path -Destination $tempZip
        $zipPath = $tempZip
        # Never unpack and Unblock-File an unchecked zip: with no -Sha256, the zip must be
        # the pinned release itself (audit 2c24feed lead 3).
        if ($Sha256) { Assert-ZipHash $zipPath $Sha256 } else { Assert-ZipHash $zipPath $ReleaseSha256 }
    } else {
        # Fail before any network call when this copy carries no pin.
        if ($ReleaseSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "This copy of install.ps1 has no release hash pinned. Use the copy on the main branch, or -FromZip." }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $tempZip = Join-Path $stageRoot ('windows-tune-' + [Guid]::NewGuid().ToString() + '.zip')
        Write-Host "Downloading windows-tune $ReleaseTag from github.com ..." -ForegroundColor Cyan
        Invoke-WebRequest -UseBasicParsing $ReleaseUrl -OutFile $tempZip
        Assert-ZipHash $tempZip $ReleaseSha256
        $zipPath = $tempZip
    }

    $tempFolder = Join-Path $stageRoot ('windows-tune-' + [Guid]::NewGuid().ToString())
    Expand-Archive -Force -Path $zipPath -DestinationPath $tempFolder
    $top = @(Get-ChildItem -Path $tempFolder -Directory)
    if ($top.Count -ne 1) { throw "Expected one folder inside the zip, found $($top.Count)." }
    $source = $top[0].FullName

    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null }

    # Copy everything from the zip. The zip never contains revert files or logs
    # (they are gitignored), so nothing of the user's is touched.
    Get-ChildItem -Path $source -Recurse | ForEach-Object {
        $dest = Join-Path $Path $_.FullName.Substring($source.Length).TrimStart('\')
        if ($_.PSIsContainer) {
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }
        } elseif ($_.Name -like '*-revert.ps1' -or $_.Name -like '*.log') {
            # never ship or overwrite these
        } else {
            Copy-Item -Path $_.FullName -Destination $dest -Force
        }
    }

    Get-ChildItem -Path $Path -Recurse -File | Unblock-File

    Write-Host "Installed to: $Path" -ForegroundColor Green
    Write-Host 'Read NOTICE.md before running anything.' -ForegroundColor Yellow
    Write-Host 'Double-click Run-WindowsTune.cmd, or run .\windows-tune.ps1 from an elevated PowerShell.' -ForegroundColor Cyan

    if ($Launch) {
        Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Path 'windows-tune.ps1')`""
    }
} catch {
    Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if ($tempFolder -and (Test-Path $tempFolder)) { Remove-Item -Recurse -Force $tempFolder }
    if ($tempZip -and (Test-Path $tempZip)) { Remove-Item -Force $tempZip }
}
exit 0
