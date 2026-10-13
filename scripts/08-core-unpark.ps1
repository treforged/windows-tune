<#
.SYNOPSIS
    Keep every CPU core unparked (minimum cores = 100%) on the ACTIVE power plan.

.DESCRIPTION
    Windows parks idle cores to save power. On some machines parking adds
    latency and stutter under load. The setting that controls it is
    "Processor performance core parking min cores" (CPMINCORES). It is HIDDEN
    from powercfg's normal listing, but it exists and it can be set by GUID.
    100 means every core stays unparked. This script sets 100 on AC AND on
    battery (DC) for the active plan and leaves every other setting alone.

    It reads the values back from the REGISTRY, not from powercfg, because the
    hidden setting does not appear in powercfg's output. Registry values are
    not localized, so this read does not depend on the Windows language.

.PARAMETER Minimum
    Minimum unparked cores as a percentage. Default 100 (all cores).

.EXAMPLE
    .\08-core-unpark.ps1

.NOTES
    Writes 08-core-unpark-revert.ps1 with the previous AC and DC values, and only
    when something would change. A side that had no stored value cannot be
    restored exactly, so the revert says so instead of guessing.
    Costs power: unparked cores stay awake when idle. That is the trade.
#>
[CmdletBinding()]
param([ValidateRange(0, 100)][int]$Minimum = 100)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated PowerShell (Run as administrator).'
}

$SUB_PROCESSOR = '54533251-82be-4824-96c1-47b60b740d00'
$CPMINCORES    = '0cc5b647-c1df-4637-891a-dec35c318583'

$active = ((powercfg /getactivescheme) -replace '.*GUID:\s*([a-f0-9\-]+).*', '$1').Trim()
$name   = ((powercfg /getactivescheme) -replace '.*\((.+)\).*', '$1').Trim()
Write-Host "Active plan: $name" -ForegroundColor Cyan

# Read one side (AC or DC) of the setting from the registry. Returns $null when
# the plan has no stored value for it, which is NOT the same as 0.
function Get-CoreValue {
    param([string]$Side)
    $key = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$active\$SUB_PROCESSOR\$CPMINCORES"
    $prop = "$($Side)SettingIndex"
    $item = Get-ItemProperty -Path $key -Name $prop -ErrorAction SilentlyContinue
    if ($null -eq $item -or $null -eq $item.$prop) { return $null }
    [int]$item.$prop
}

$acBefore = Get-CoreValue 'AC'
$dcBefore = Get-CoreValue 'DC'
Write-Host "Minimum unparked cores BEFORE: AC=$(if ($null -eq $acBefore) { 'not stored' } else { "$acBefore%" })  DC=$(if ($null -eq $dcBefore) { 'not stored' } else { "$dcBefore%" })"

if ($acBefore -eq $Minimum -and $dcBefore -eq $Minimum) {
    Write-Host "already at target - nothing to change" -ForegroundColor Green
    Write-Host "  every core is already unparked on AC and battery; no revert file written." -ForegroundColor DarkGray
    return
}

$revert = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '08-core-unpark-revert.ps1'
$revertLines = @(
    '# Auto-generated revert. Run ELEVATED.',
    "# Captured $(Get-Date -Format s)"
)
if ($null -ne $acBefore) {
    $revertLines += "powercfg /setacvalueindex $active $SUB_PROCESSOR $CPMINCORES $acBefore"
} else {
    $revertLines += '# AC had no stored value before this script ran, so it cannot be restored exactly.'
}
if ($null -ne $dcBefore) {
    $revertLines += "powercfg /setdcvalueindex $active $SUB_PROCESSOR $CPMINCORES $dcBefore"
} else {
    $revertLines += '# DC had no stored value before this script ran, so it cannot be restored exactly.'
}
$revertLines += "powercfg /setactive $active"
Set-Content -Path $revert -Encoding UTF8 -Value $revertLines
Write-Host "Revert written: $revert" -ForegroundColor Cyan

powercfg /setacvalueindex $active $SUB_PROCESSOR $CPMINCORES $Minimum
powercfg /setdcvalueindex $active $SUB_PROCESSOR $CPMINCORES $Minimum
powercfg /setactive $active

# Read back off the machine. "It ran" and "it changed" are different claims.
$acAfter = Get-CoreValue 'AC'
$dcAfter = Get-CoreValue 'DC'
Write-Host "Minimum unparked cores AFTER:  AC=$(if ($null -eq $acAfter) { 'unreadable' } else { "$acAfter%" })  DC=$(if ($null -eq $dcAfter) { 'unreadable' } else { "$dcAfter%" })"
if ($acAfter -eq $Minimum -and $dcAfter -eq $Minimum) {
    Write-Host "  verified: read back from the registry, not reported by this script." -ForegroundColor Green
} else {
    Write-Host "  NOT CONFIRMED: wanted $Minimum% on both sides. Nothing was rolled back; the revert file is still valid." -ForegroundColor Red
}
