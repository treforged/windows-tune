<#
.SYNOPSIS
    Report the true WinSxS component-store size and reclaim superseded packages.

.DESCRIPTION
    C:\Windows looks enormous to any recursive size scan because WinSxS is built
    from hardlinks - the same bytes are counted once per link. DISM reports the
    real figure. This script analyses the store, runs the cleanup, and analyses
    again so the before/after is measured rather than asserted.

    /ResetBase is OFF by default and gated behind -ResetBase. It reclaims more
    but PERMANENTLY removes the ability to uninstall already-installed Windows
    updates, which is a rollback path worth keeping on a machine you rely on.

.PARAMETER ResetBase
    Also pass /ResetBase. Understand the tradeoff above before using it.

.PARAMETER Force
    Run the cleanup even when DISM reports there is nothing to reclaim.

.EXAMPLE
    .\04-component-cleanup.ps1

.NOTES
    Typical reclaim is a few GB. On the reference machine: 21.0 -> 14.9 GB.
    Takes several minutes and cannot be safely interrupted mid-run.
#>
[CmdletBinding()]
param([switch]$ResetBase, [switch]$Force)

$ErrorActionPreference = 'Continue'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated PowerShell (Run as administrator).'
}

function Get-FreeGB { [math]::Round((Get-Volume -DriveLetter C).SizeRemaining / 1GB, 2) }

$before = Get-FreeGB
Write-Host "C: free BEFORE: $before GB" -ForegroundColor Cyan

# Read DISM's own verdict out of its text so the OUTCOME can be checked, not just
# the action. Returns $null for a field it cannot find - an unparseable answer is
# reported as unknown, never silently treated as success.
function Get-StoreFacts {
    param([object[]]$DismOutput)
    $text = $DismOutput -join "`n"
    $pk  = [regex]::Match($text, 'Number of Reclaimable Packages\s*:\s*(\d+)')
    $rec = [regex]::Match($text, 'Component Store Cleanup Recommended\s*:\s*(\w+)')
    [pscustomobject]@{
        Packages    = if ($pk.Success)  { [int]$pk.Groups[1].Value } else { $null }
        Recommended = if ($rec.Success) { $rec.Groups[1].Value }    else { $null }
    }
}

# A cleanup on a CORRUPT component store is at best pointless: DISM will still
# print "The operation completed successfully" and reclaim nothing, which is
# exactly what this machine did on 2026-09-02 before the corruption surfaced
# through an unrelated feature install. Ask about health FIRST and say so.
function Get-StoreHealth {
    param([object[]]$DismOutput)
    $text = $DismOutput -join "`n"
    if ($text -match '(?i)no component store corruption detected') { return 'Healthy' }
    if ($text -match '(?i)component store corruption was repaired')  { return 'Healthy' }
    if ($text -match '(?i)the component store is repairable')        { return 'Repairable' }
    if ($text -match '(?i)component store (has been |is )?corrupt')  { return 'Corrupt' }
    # Unreadable is UNKNOWN, never "healthy". A non-English Windows lands here,
    # and so does a DISM that failed before it printed a verdict.
    return 'Unknown'
}

Write-Host "`n--- HEALTH ---" -ForegroundColor Yellow
$healthOut = & Dism.exe /Online /Cleanup-Image /CheckHealth 2>&1
$healthOut | Write-Host
$health = Get-StoreHealth $healthOut
if ($health -eq 'Repairable' -or $health -eq 'Corrupt') {
    Write-Host ''
    Write-Host 'STOPPING: this PC''s component store is damaged.' -ForegroundColor Red
    Write-Host '  A cleanup cannot help a damaged store, and DISM will still report' -ForegroundColor Yellow
    Write-Host '  success while reclaiming nothing. Nothing was changed.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Repair it first, from an elevated PowerShell:' -ForegroundColor Cyan
    Write-Host '    DISM /Online /Cleanup-Image /RestoreHealth' -ForegroundColor Cyan
    Write-Host '  That needs an internet connection (it pulls replacement files from' -ForegroundColor DarkGray
    Write-Host '  Windows Update), takes a while, and is the supported fix. Then run' -ForegroundColor DarkGray
    Write-Host '  this option again.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  A damaged store also blocks adding or removing Windows features and' -ForegroundColor DarkGray
    Write-Host '  can make Windows updates fail in ways that look like something else.' -ForegroundColor DarkGray
    return
}
if ($health -eq 'Unknown') {
    Write-Host ''
    Write-Host '  Could not read a health verdict from DISM, so this continues without' -ForegroundColor Yellow
    Write-Host '  one rather than assuming the store is healthy.' -ForegroundColor Yellow
}

Write-Host "`n--- ANALYZE ---" -ForegroundColor Yellow
$analysis = & Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore 2>&1
$analysis | Write-Host

# DISM already knows whether there is anything to reclaim. Ask it before
# spending several uninterruptible minutes reclaiming nothing. An unparseable
# answer is not a "No": if the line is missing, the cleanup still runs.
$recommendation = ($analysis | Select-String 'Component Store Cleanup Recommended' | Select-Object -First 1)
if ($recommendation -and ("$recommendation" -match ':\s*No\s*$') -and -not $Force) {
    Write-Host "`nalready at target - nothing to change" -ForegroundColor Green
    Write-Host '  DISM reports no cleanup recommended; no packages were removed.' -ForegroundColor DarkGray
    Write-Host '  Run with -Force to clean up anyway.' -ForegroundColor DarkGray
    return
}

Write-Host "`n--- CLEANUP$(if ($ResetBase) { ' (/ResetBase)' }) ---" -ForegroundColor Yellow
if ($ResetBase) {
    Write-Warning 'ResetBase: installed Windows updates will no longer be uninstallable.'
    Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
} else {
    Dism.exe /Online /Cleanup-Image /StartComponentCleanup
}

Write-Host "`n--- RE-ANALYZE ---" -ForegroundColor Yellow
$reanalysis = & Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore 2>&1
$reanalysis | Write-Host

$after     = Get-FreeGB
$reclaimed = [math]::Round($after - $before, 2)
Write-Host "`nC: free AFTER: $after GB  (reclaimed $reclaimed GB)" -ForegroundColor Green

# DISM says 'The operation completed successfully' even when it removed nothing.
# Compare its OWN before and after verdict rather than letting that stand as the
# last word (seen 2026-09-02: 2 reclaimable packages before AND after, 0.03 GB).
$pre  = Get-StoreFacts $analysis
$post = Get-StoreFacts $reanalysis
if ($null -eq $pre.Packages -or $null -eq $post.Packages) {
    Write-Host "`nCould not read DISM's reclaimable-package count, so whether this" -ForegroundColor Yellow
    Write-Host '  freed anything is UNKNOWN - do not read the success line as proof.' -ForegroundColor Yellow
} elseif ($post.Packages -ge $pre.Packages -and $reclaimed -le 0.05) {
    Write-Host "`nnothing was actually freed" -ForegroundColor Yellow
    Write-Host "  DISM still reports $($post.Packages) reclaimable package(s) and" -ForegroundColor Yellow
    Write-Host "  'Cleanup Recommended : $($post.Recommended)' - the same as before the run." -ForegroundColor Yellow
    Write-Host '  Those packages usually need a RESTART before they can be removed.' -ForegroundColor Yellow
    Write-Host '  DISM reported success; that describes the operation, not the outcome.' -ForegroundColor Yellow
} else {
    Write-Host "`nreclaimable packages: $($pre.Packages) -> $($post.Packages)" -ForegroundColor Green
}
