<#
.SYNOPSIS
    Download windows-tune from GitHub into a local folder. Runs nothing.

.DESCRIPTION
    Downloads the repository as a zip from github.com over HTTPS (or uses a
    zip you already have), unpacks it to a folder under your own profile,
    unblocks the files so Windows does not refuse to run them, and tells you
    how to start. It does not execute any downloaded file and needs no
    administrator rights.

    Any *-revert.ps1 or *.log files already in the target folder are left
    alone: those are your own revert files from earlier runs.

.PARAMETER Path
    Where to install. Default: %LOCALAPPDATA%\windows-tune.

.PARAMETER FromZip
    Use this local zip instead of downloading (offline install, or the test).

.PARAMETER Launch
    Open the windows-tune menu after installing. Off by default.

.EXAMPLE
    Invoke-WebRequest https://raw.githubusercontent.com/treforged/windows-tune/main/install.ps1 -OutFile install.ps1
    notepad .\install.ps1
    powershell -ExecutionPolicy Bypass -File .\install.ps1
    Download it, read it, then run it. There is deliberately no one-line
    "pipe the download into PowerShell" form - see NOTICE.md.

.EXAMPLE
    .\install.ps1 -FromZip .\windows-tune.zip -Path C:\tools\windows-tune
#>
[CmdletBinding()]
param(
    [string]$Path = (Join-Path $env:LOCALAPPDATA 'windows-tune'),
    [string]$FromZip,
    [switch]$Launch
)

$ErrorActionPreference = 'Stop'
$tempZip = $null
$tempFolder = $null

try {
    if ($FromZip) {
        if (-not (Test-Path $FromZip)) { throw "Zip not found: $FromZip" }
        $zipPath = (Resolve-Path $FromZip).Path
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $tempZip = Join-Path $env:TEMP ('windows-tune-' + [Guid]::NewGuid().ToString() + '.zip')
        Write-Host 'Downloading github.com/treforged/windows-tune ...' -ForegroundColor Cyan
        Invoke-WebRequest -UseBasicParsing 'https://github.com/treforged/windows-tune/archive/refs/heads/main.zip' -OutFile $tempZip
        $zipPath = $tempZip
    }

    $tempFolder = Join-Path $env:TEMP ('windows-tune-' + [Guid]::NewGuid().ToString())
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
