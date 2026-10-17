# privacy-tune.ps1 - reduce what websites and Windows can read about this user.
# Per-user (HKCU) only. No admin. Writes privacy-tune-revert.ps1 next to itself
# with the values that were there BEFORE, so the revert is a capture, not a guess.
#
# Measured before writing this (2026-10-04): on the author's PC Windows telemetry, advertising
# ID, tailored experiences, activity feed, DiagTrack and dmwappushservice were
# ALREADY off. The one per-user tracking surface still open was the language
# list: HttpAcceptLanguageOptOut = 0 lets every website read the full list of
# display languages, which is a fingerprinting input. This script closes it.
#
# Browser cookies and Privacy Sandbox are NOT here - see browser-privacy.ps1.
# They are new policy values, so undoing them is a DELETE, and the revert gate
# (tests/preflight.ps1) correctly refuses deletes in a *-revert.ps1.

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { throw 'Cannot resolve this script''s own folder. Run it as a file (.\privacy-tune.ps1), not by pasting its body into a console.' }

$key  = 'HKCU:\Control Panel\International\User Profile'
$name = 'HttpAcceptLanguageOptOut'

$before = (Get-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue).$name
if ($null -eq $before) { $before = 0 }   # absent behaves as 0 (opted in)

$revert = Join-Path $here 'privacy-tune-revert.ps1'
@(
    '# Auto-generated revert for privacy-tune.ps1. Per-user, no admin needed.'
    "# Captured $(Get-Date -Format s)"
    "Set-ItemProperty '$key' -Name $name -Value $before -Type DWord"
    "Write-Host 'Language list is readable by websites again ($name = $before).'"
) | Set-Content -Path $revert -Encoding ASCII

Set-ItemProperty -Path $key -Name $name -Value 1 -Type DWord
$after = (Get-ItemProperty -Path $key -Name $name).$name
if ($after -ne 1) { Write-Host "FAILED: $name reads $after after the write." -ForegroundColor Red; exit 1 }
Write-Host "$name : $before -> $after (websites can no longer read the language list)" -ForegroundColor Green
Write-Host "UNDO: .\privacy-tune-revert.ps1"
