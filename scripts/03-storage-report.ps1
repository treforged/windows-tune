<#
.SYNOPSIS
    Find what is eating the disk, and which games you have not played.

.DESCRIPTION
    Two reports:
      1. Largest folders per drive, plus the user profile broken down.
      2. Every installed Steam game with its size on disk and REAL last-played
         date, parsed from Steam's own appmanifest_*.acf files across all
         libraries. Epic and Xbox/Game Pass titles are listed by size with
         last-modified as a rough proxy - neither launcher exposes last-played.

    Read-only. Deletes nothing and uninstalls nothing.

.PARAMETER Drives
    Drive roots to scan. Defaults to every fixed NTFS volume with a letter.

.PARAMETER Top
    How many folders to list per drive. Default 20.

.EXAMPLE
    .\03-storage-report.ps1
.EXAMPLE
    .\03-storage-report.ps1 -Drives C:\,D:\ -Top 30 | Tee-Object storage.txt

.NOTES
    WinSxS caveat: C:\Windows contains hardlinked component-store files, so a
    naive recursive sum over-reports it, often by 100 GB or more. Use
    04-component-cleanup.ps1 for the real component store figure.
#>
[CmdletBinding()]
param(
    [string[]]$Drives,
    [int]$Top = 20
)

function Get-FolderGB([string]$Path) {
    # -ErrorAction Ignore, not SilentlyContinue: directory junctions and reparse
    # points (C:\Documents and Settings, and friends) raise a provider-level
    # Win32Exception that SilentlyContinue still prints.
    $sum = 0L
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction Ignore |
                Measure-Object Length -Sum).Sum
    } catch { $sum = 0L }
    if (-not $sum) { $sum = 0L }
    [math]::Round($sum / 1GB, 2)
}

if (-not $Drives) {
    $Drives = (Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } |
               ForEach-Object { "$($_.DriveLetter):\" })
}

Write-Host '=== FREE SPACE ===' -ForegroundColor Cyan
Get-Volume | Where-Object DriveLetter | Format-Table DriveLetter, FileSystemType,
    @{ n = 'FreeGB';  e = { [math]::Round($_.SizeRemaining / 1GB) } },
    @{ n = 'TotalGB'; e = { [math]::Round($_.Size / 1GB) } },
    @{ n = 'Free%';   e = { if ($_.Size) { [math]::Round(100 * $_.SizeRemaining / $_.Size, 1) } } } -AutoSize

foreach ($d in $Drives) {
    Write-Host "`n=== $d LARGEST FOLDERS ===" -ForegroundColor Cyan
    Get-ChildItem $d -Directory -Force -ErrorAction SilentlyContinue |
        ForEach-Object { [PSCustomObject]@{ GB = Get-FolderGB $_.FullName; Path = $_.FullName } } |
        Sort-Object GB -Descending | Select-Object -First $Top | Format-Table -AutoSize
}

Write-Host "`n=== USER PROFILE ===" -ForegroundColor Cyan
Get-ChildItem $env:USERPROFILE -Directory -Force -ErrorAction SilentlyContinue |
    ForEach-Object { [PSCustomObject]@{ GB = Get-FolderGB $_.FullName; Name = $_.Name } } |
    Sort-Object GB -Descending | Select-Object -First 15 | Format-Table -AutoSize

# --------------------------------------------------------------- Steam titles
Write-Host "`n=== STEAM GAMES BY LAST PLAYED (oldest first) ===" -ForegroundColor Cyan

$libs = @()
$default = Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps'
if (Test-Path $default) { $libs += $default }

$vdf = Join-Path $default 'libraryfolders.vdf'
if (Test-Path $vdf) {
    Get-Content $vdf | Select-String '"path"' | ForEach-Object {
        $p = ($_ -split '"')[3] -replace '\\\\', '\'
        $sp = Join-Path $p 'steamapps'
        if ((Test-Path $sp) -and ($libs -notcontains $sp)) { $libs += $sp }
    }
}

if (-not $libs) {
    Write-Host '  (no Steam libraries found)' -ForegroundColor DarkGray
} else {
    $rows = foreach ($lib in $libs) {
        Get-ChildItem $lib -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue | ForEach-Object {
            $c = Get-Content $_.FullName -Raw
            $lp = if ($c -match '"LastPlayed"\s+"(\d+)"') { [int64]$Matches[1] } else { 0 }
            [PSCustomObject]@{
                Game       = if ($c -match '"name"\s+"([^"]+)"') { $Matches[1] } else { $_.Name }
                GB         = if ($c -match '"SizeOnDisk"\s+"(\d+)"') { [math]::Round([int64]$Matches[1] / 1GB, 1) } else { 0 }
                LastPlayed = if ($lp) { ([DateTimeOffset]::FromUnixTimeSeconds($lp)).LocalDateTime.ToString('yyyy-MM-dd') } else { 'never' }
                DaysAgo    = if ($lp) { [math]::Round(((Get-Date) - ([DateTimeOffset]::FromUnixTimeSeconds($lp)).LocalDateTime).TotalDays) } else { 99999 }
            }
        }
    }
    $rows | Sort-Object DaysAgo -Descending | Format-Table Game, GB, LastPlayed, DaysAgo -AutoSize
    Write-Host ("  Total Steam: {0} GB across {1} titles" -f [math]::Round(($rows | Measure-Object GB -Sum).Sum, 1), $rows.Count)
}

# --------------------------------------------- Epic / Xbox (size + mtime only)
foreach ($store in @(
    @{ Label = 'EPIC';  Paths = @('C:\Program Files\Epic Games') + ($Drives | ForEach-Object { Join-Path $_ 'Epic Games' }) },
    @{ Label = 'XBOX';  Paths = ($Drives | ForEach-Object { Join-Path $_ 'XboxGames' }) }
)) {
    foreach ($root in ($store.Paths | Where-Object { Test-Path $_ })) {
        Write-Host "`n=== $($store.Label): $root (last-MODIFIED, not last-played) ===" -ForegroundColor Cyan
        Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { [PSCustomObject]@{ GB = Get-FolderGB $_.FullName; Name = $_.Name; Modified = $_.LastWriteTime.ToString('yyyy-MM-dd') } } |
            Sort-Object GB -Descending | Format-Table -AutoSize
    }
}
