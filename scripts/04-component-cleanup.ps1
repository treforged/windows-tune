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

.EXAMPLE
    .\04-component-cleanup.ps1

.NOTES
    Typical reclaim is a few GB. On the reference machine: 21.0 -> 14.9 GB.
    Takes several minutes and cannot be safely interrupted mid-run.
#>
[CmdletBinding()]
param([switch]$ResetBase)

$ErrorActionPreference = 'Continue'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated PowerShell (Run as administrator).'
}

function Get-FreeGB { [math]::Round((Get-Volume -DriveLetter C).SizeRemaining / 1GB, 2) }

$before = Get-FreeGB
Write-Host "C: free BEFORE: $before GB" -ForegroundColor Cyan

Write-Host "`n--- ANALYZE ---" -ForegroundColor Yellow
Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore

Write-Host "`n--- CLEANUP$(if ($ResetBase) { ' (/ResetBase)' }) ---" -ForegroundColor Yellow
if ($ResetBase) {
    Write-Warning 'ResetBase: installed Windows updates will no longer be uninstallable.'
    Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
} else {
    Dism.exe /Online /Cleanup-Image /StartComponentCleanup
}

Write-Host "`n--- RE-ANALYZE ---" -ForegroundColor Yellow
Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore

$after = Get-FreeGB
Write-Host "`nC: free AFTER: $after GB  (reclaimed $([math]::Round($after - $before, 2)) GB)" -ForegroundColor Green
