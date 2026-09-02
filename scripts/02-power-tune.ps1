<#
.SYNOPSIS
    Fix the "minimum processor state = 100%" tweak that hurts modern CPUs.

.DESCRIPTION
    Third-party "gaming" power plans routinely pin Minimum processor state at
    100%, on the theory that a CPU which never downclocks is a faster CPU. On
    any modern boost-driven part (AMD Zen 2+, Intel Turbo) the opposite is true:
    peak boost clocks are granted out of thermal and power headroom, and pinning
    the floor at 100% spends that headroom idling. It raises idle temperature and
    package power and can LOWER sustained boost.

    AMD's own guidance for Ryzen is a 0% floor with a 100% ceiling. This script
    sets exactly that on the ACTIVE power plan and leaves the ceiling alone.

.PARAMETER Floor
    Minimum processor state percentage. Default 0.

.EXAMPLE
    .\02-power-tune.ps1

.NOTES
    Writes 02-power-tune-revert.ps1 with the previous value.
    Changes no other power setting, and creates no new plan.
#>
[CmdletBinding()]
param([ValidateRange(0, 100)][int]$Floor = 0)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated PowerShell (Run as administrator).'
}

$SUB_PROCESSOR   = '54533251-82be-4824-96c1-47b60b740d00'
$PROCTHROTTLEMIN = '893dee8e-2bef-41e0-89c6-b55d0929964c'

$active = ((powercfg /getactivescheme) -replace '.*GUID:\s*([a-f0-9\-]+).*', '$1').Trim()
$name   = ((powercfg /getactivescheme) -replace '.*\((.+)\).*', '$1').Trim()
Write-Host "Active plan: $name" -ForegroundColor Cyan

# powercfg output is LOCALIZED. Without this guard a non-English Windows fell
# through to [Convert]::ToInt32('') and died with "Index was out of range", which
# names nothing a user can act on. Proven by tests\preflight.ps1 stage 13.
function Get-MinState {
    $line = @((powercfg /query $active $SUB_PROCESSOR $PROCTHROTTLEMIN) |
              Select-String 'Current AC Power Setting Index' | Select-Object -First 1)
    if (-not $line -or -not $line[0]) {
        throw ("Could not read the current minimum processor state from powercfg. " +
               "These scripts read the ENGLISH labels of Windows command output, so " +
               "they need an English-language Windows. Nothing has been changed.")
    }
    $hex = ("$($line[0])" -replace '.*:\s*', '').Trim()
    [Convert]::ToInt32($hex, 16)
}

$before = Get-MinState
Write-Host "Minimum processor state BEFORE: $before%"

if ($before -eq $Floor) {
    Write-Host "already at target - nothing to change" -ForegroundColor Green
    Write-Host "  minimum processor state is already $Floor%; no revert file written." -ForegroundColor DarkGray
    return
}

$revert = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '02-power-tune-revert.ps1'
Set-Content -Path $revert -Encoding UTF8 -Value @(
    '# Auto-generated revert. Run ELEVATED.',
    "# Captured $(Get-Date -Format s)",
    "powercfg /setacvalueindex $active $SUB_PROCESSOR $PROCTHROTTLEMIN $before",
    "powercfg /setdcvalueindex $active $SUB_PROCESSOR $PROCTHROTTLEMIN $before",
    "powercfg /setactive $active"
)
Write-Host "Revert written: $revert" -ForegroundColor Cyan

powercfg /setacvalueindex $active $SUB_PROCESSOR $PROCTHROTTLEMIN $Floor
powercfg /setdcvalueindex $active $SUB_PROCESSOR $PROCTHROTTLEMIN $Floor
powercfg /setactive $active

Write-Host "Minimum processor state AFTER:  $(Get-MinState)%" -ForegroundColor Green
