<#
.SYNOPSIS
    Does each revert file still name the values that are actually on this machine?

.DESCRIPTION
    The gate next door proves a revert would restore SOMETHING safe. It cannot
    tell you whether the values it names are the values that were really there.
    01-network-tune-revert.ps1 captures every TCP, NIC and registry value it is
    about to change; if any were captured wrong, that gate is green and the
    revert is still a lie.

    This reads the CURRENT value for each claim a revert makes and reports
    MATCH, DRIFT or UNREADABLE. It NEVER applies a revert and never writes
    anything - proving a revert works by running it is how you find out it does
    not.

    READ THE OUTPUT THE RIGHT WAY ROUND. These tunes have been APPLIED to this
    machine, so a revert naming a DIFFERENT value than the machine holds is the
    healthy case - that is the whole point of it. A claim that already MATCHES
    the machine means the tune is not applied here, or was reverted already.
    Neither is automatically a bug and this script deliberately does not pick a
    winner: only a human knows whether a value changed because the tune did it,
    because the capture was wrong, or because something else moved it.

    What it CAN settle on its own is whether each claim is verifiable at all -
    whether the setting still exists and its current value can be read. A claim
    that cannot be read is a revert that cannot be trusted to do anything, and
    that is the only outcome here that exits 1.
#>
[CmdletBinding()]
param(
    # Where the tune scripts and their *-revert.ps1 files live. Defaults to the
    # repo's scripts\ folder; preflight.ps1 points it at a fixture folder so
    # these checks can be pressed until they go RED.
    [string]$ScriptsDir
)

# Resolve this script's own folder BEFORE anything is derived from it.
# Split-Path THROWS on an empty string, so this is checked before it is called.
$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { throw 'Cannot resolve this script''s own folder. Run it as a file (.\tests\revert-drift.ps1), not by pasting its body into a console.' }
if (-not $ScriptsDir) { $ScriptsDir = Join-Path (Split-Path -Parent $here) 'scripts' }
if (-not (Test-Path -LiteralPath $ScriptsDir -PathType Container)) {
    Write-Host "no such folder [$ScriptsDir] - this script proved nothing" -ForegroundColor Red
    exit 1
}

. (Join-Path $here 'revert-lib.ps1')

# ------------------------------------------------------------------ report ----
$match = 0; $drift = 0; $unread = 0; $claims = 0
foreach ($r in (Get-ChildItem $ScriptsDir -File -Filter '*-revert.ps1' | Sort-Object Name)) {
    Write-Host ''
    Write-Host "=== $($r.Name)" -ForegroundColor Cyan
    $found = Get-RevertClaim $r.FullName
    if ($found.Count -eq 0) {
        Write-Host '  no readable claims - this file restores nothing this script understands' -ForegroundColor Yellow
        continue
    }
    foreach ($c in $found) {
        $claims++
        $now = Read-Current $c
        if ($null -eq $now -or "$now" -eq '') {
            $unread++
            Write-Host ("  UNVERIFIABLE  {0} [{1}] - claims '{2}', and the current value cannot be read at all" -f $c.Class, $c.Target, $c.Claimed) -ForegroundColor Red
        } elseif ("$now".Trim() -ieq "$($c.Claimed)".Trim()) {
            $match++
            Write-Host ("  ALREADY THERE {0} [{1}] = {2} - the machine already holds what this revert would restore" -f $c.Class, $c.Target, $now) -ForegroundColor Yellow
        } else {
            $drift++
            Write-Host ("  differs       {0} [{1}] - revert would restore '{2}', machine has '{3}'" -f $c.Class, $c.Target, $c.Claimed, $now) -ForegroundColor Green
        }
    }
}

Write-Host ''
Write-Host ('{0} claim(s): {1} verifiable ({2} differ from the machine, {3} already at the revert''s value), {4} UNVERIFIABLE' -f $claims, ($match + $drift), $drift, $match, $unread)
if ($claims -eq 0) { Write-Host 'no claims read at all - this script proved nothing' -ForegroundColor Red; exit 1 }
Write-Host 'Nothing here changed a setting, and nothing here decides whether a value is'
Write-Host '"right" - a claim that differs is the healthy case for an applied tune, and one'
Write-Host 'that already matches means the tune is not applied here. Only a human knows why.'
if ($unread) {
    Write-Host ''
    Write-Host "$unread claim(s) CANNOT BE VERIFIED - a revert that cannot read what it would restore cannot be trusted to restore it" -ForegroundColor Red
    exit 1
}
exit 0
