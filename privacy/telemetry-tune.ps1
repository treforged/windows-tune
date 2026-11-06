# telemetry-tune.ps1 - turn off the Windows diagnostic and ad settings that audit (privacy-audit.ps1) checks.
# Run ELEVATED (two values are machine policy under HKLM). Writes telemetry-tune-state.json and
# telemetry-tune-revert.ps1 next to itself BEFORE it changes anything, then reads each value back.
#
#   (no switch)     the four registry settings below
#   -ServicesOnly   instead, stop and disable DiagTrack and dmwappushservice (optional, see below)
#   -DryRun         print what would change and change nothing (no admin needed)
#   -Undo           put back what the state file recorded, and remove the policy values this script added
#
# What each setting does, and where it is documented (checked 2026-11-06 against Microsoft Learn,
# "Manage connections from Windows operating system components to Microsoft services" and
# "Configure Windows diagnostic data in your organization"):
#   AllowTelemetry policy   Microsoft documents 0 = "Diagnostic data off (Security)", but says it is only
#                           available on Windows Server, Enterprise and Education. On Home and Pro the
#                           lowest level is 1 = Required, so this script writes 1 there, not 0. Microsoft
#                           also says that with 0, update failure information is not sent.
#   Advertising ID          HKCU AdvertisingInfo Enabled = 0 is the setting behind Settings > Privacy >
#                           General "Let apps use advertising ID". Documented in the first page above.
#   Activity feed publish   HKLM Policies\Microsoft\Windows\System PublishUserActivities = 0. Documented in
#                           the first page above ("Activity History").
#   Tailored experiences    HKCU Privacy TailoredExperiencesWithDiagnosticDataEnabled = 0 is the setting
#                           behind Settings > Privacy > Diagnostics & feedback > Tailored experiences.
#                           Named in the diagnostic data page; the registry value is not spelled out there.
#   DiagTrack, dmwappush    NOT found on either Microsoft page. Disabling the services is common practice,
#                           not a Microsoft instruction, and Windows may start them again after a feature
#                           update. That is why they are a separate, optional step.
#
# The two HKLM policy values are only ever written when they do not exist yet, so -Undo can only delete
# what this script added. A policy somebody else set is refused, never overwritten.

param(
    [switch]$Undo,
    [switch]$DryRun,
    [switch]$ServicesOnly
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { throw 'Cannot resolve this script''s own folder. Run it as a file (.\telemetry-tune.ps1).' }

$statePath  = Join-Path $here 'telemetry-tune-state.json'
$revertPath = Join-Path $here 'telemetry-tune-revert.ps1'

$ITEMS = @(
    @{ Id = 'telemetry-policy'; Kind = 'Policy'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry' }
    @{ Id = 'activity-feed';    Kind = 'Policy'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';         Name = 'PublishUserActivities'; Target = 0 }
    @{ Id = 'advertising-id';   Kind = 'Value';  Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Target = 0 }
    @{ Id = 'tailored';         Kind = 'Value';  Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy';  Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Target = 0 }
    @{ Id = 'svc-diagtrack';    Kind = 'Service'; Name = 'DiagTrack' }
    @{ Id = 'svc-dmwappush';    Kind = 'Service'; Name = 'dmwappushservice' }
)

function Get-TelemetryTarget {
    # 0 only where Microsoft says 0 is honoured (Enterprise, Education, Server); 1 (Required) everywhere else.
    param([string]$EditionId)
    if ($EditionId -match '^(Enterprise|Education|Server)') { return 0 }
    return 1
}

function Get-TelemetryPlan {
    # Pure. $Current maps item Id -> current value ($null when absent; the start type text for a service).
    # Returns one row per item: Action is Set, AtTarget, Refuse (a policy somebody else set) or Skip (no such service).
    param([hashtable]$Current, [string]$EditionId, [bool]$ServicesOnly = $false)
    $rows = @()
    foreach ($it in $ITEMS) {
        $isSvc = $it.Kind -eq 'Service'
        if ($isSvc -ne $ServicesOnly) { continue }
        $cur = $Current[$it.Id]
        $target = if ($it.Id -eq 'telemetry-policy') { Get-TelemetryTarget $EditionId } elseif ($isSvc) { 'Disabled' } else { $it.Target }
        if ($isSvc) {
            $action = if ($null -eq $cur) { 'Skip' } elseif ("$cur" -eq 'Disabled') { 'AtTarget' } else { 'Set' }
        } elseif ($null -ne $cur -and "$cur" -eq "$target") {
            $action = 'AtTarget'
        } elseif ($it.Kind -eq 'Policy' -and "$cur" -match '^\d+$' -and [int]$cur -lt [int]$target) {
            $action = 'AtTarget'   # already stricter than the target (e.g. 0 where Pro would get 1): leave it
        } elseif ($it.Kind -eq 'Policy' -and $null -ne $cur) {
            $action = 'Refuse'
        } else {
            $action = 'Set'
        }
        $rows += [pscustomobject]@{ Id = $it.Id; Kind = $it.Kind; Path = $it.Path; Name = $it.Name; Current = $cur; Target = $target; Action = $action }
    }
    return $rows
}

function Read-Current {
    $cur = @{}
    foreach ($it in $ITEMS) {
        if ($it.Kind -eq 'Service') {
            $s = Get-Service -Name $it.Name -ErrorAction SilentlyContinue
            $cur[$it.Id] = if ($s) { "$($s.StartType)" } else { $null }
        } else {
            $cur[$it.Id] = (Get-ItemProperty -Path $it.Path -Name $it.Name -ErrorAction SilentlyContinue).($it.Name)
        }
    }
    return $cur
}

if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced by a test: functions only

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $DryRun -and -not $isAdmin) { throw 'Run this from an elevated PowerShell (Run as administrator). -DryRun works without it.' }

# ---- Undo ------------------------------------------------------------------
if ($Undo) {
    if (-not (Test-Path -LiteralPath $statePath)) { Write-Host 'already at target - nothing to change' -ForegroundColor Green; Write-Host "  no state file: $statePath" -ForegroundColor DarkGray; exit 0 }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $bad = 0
    foreach ($e in @($state.Applied)) {
        $it = $ITEMS | Where-Object { $_.Id -eq $e.Id }
        if (-not $it) { Write-Host "SKIPPED unknown item $($e.Id)" -ForegroundColor Yellow; continue }
        if ($it.Kind -eq 'Service') {
            Set-Service -Name $it.Name -StartupType $e.Before
            if ($e.Before -ne 'Disabled' -and $e.WasRunning) { Start-Service -Name $it.Name -ErrorAction SilentlyContinue }
            $now = "$((Get-Service -Name $it.Name).StartType)"
            if ($now -ne $e.Before) { $bad++; Write-Host "FAILED $($it.Name) is $now, expected $($e.Before)" -ForegroundColor Red } else { Write-Host "$($it.Name) start type back to $now" }
        } elseif ($it.Kind -eq 'Policy') {
            Remove-ItemProperty -Path $it.Path -Name $it.Name -ErrorAction SilentlyContinue
            if ($null -ne (Get-ItemProperty -Path $it.Path -Name $it.Name -ErrorAction SilentlyContinue).($it.Name)) { $bad++; Write-Host "FAILED $($it.Name) is still set" -ForegroundColor Red } else { Write-Host "$($it.Name) policy removed" }
        } else {
            $before = if ($null -eq $e.Before) { 1 } else { [int]$e.Before }   # absent behaves as on
            Set-ItemProperty -Path $it.Path -Name $it.Name -Value $before -Type DWord
            $now = (Get-ItemProperty -Path $it.Path -Name $it.Name).($it.Name)
            if ($now -ne $before) { $bad++; Write-Host "FAILED $($it.Name) reads $now, expected $before" -ForegroundColor Red } else { Write-Host "$($it.Name) back to $now" }
        }
    }
    if ($bad) { exit 1 }
    Remove-Item -LiteralPath $statePath, $revertPath -ErrorAction SilentlyContinue
    Write-Host 'Undone. Restart is not needed.' -ForegroundColor Green
    exit 0
}

# ---- Apply -----------------------------------------------------------------
$edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID -ErrorAction SilentlyContinue).EditionID
$plan = @(Get-TelemetryPlan -Current (Read-Current) -EditionId "$edition" -ServicesOnly ([bool]$ServicesOnly))
Write-Host "Windows edition: $edition" -ForegroundColor Cyan
foreach ($r in $plan) {
    $label = if ($r.Kind -eq 'Service') { "service $($r.Name)" } else { "$($r.Name)" }
    switch ($r.Action) {
        'AtTarget' { Write-Host ("  ok       {0} already {1}" -f $label, $r.Target) -ForegroundColor Green }
        'Skip'     { Write-Host ("  skipped  {0}: not present on this PC" -f $label) -ForegroundColor DarkGray }
        'Refuse'   { Write-Host ("  REFUSED  {0}: a policy value of {1} already exists and was not set by this script" -f $label, $r.Current) -ForegroundColor Red }
        'Set'      { Write-Host ("  {0} {1}: {2} -> {3}" -f $(if ($DryRun) { 'WOULD   ' } else { 'setting ' }), $label, $(if ($null -eq $r.Current) { 'absent' } else { $r.Current }), $r.Target) -ForegroundColor Yellow }
    }
}
$todo = @($plan | Where-Object { $_.Action -eq 'Set' })
if ($todo.Count -eq 0) { Write-Host 'already at target - nothing to change' -ForegroundColor Green; exit $(if (@($plan | Where-Object { $_.Action -eq 'Refuse' }).Count) { 1 } else { 0 }) }
if ($DryRun) { Write-Host "DRY RUN - $($todo.Count) change(s) would be made, nothing was changed." -ForegroundColor Cyan; exit 0 }

# record BEFORE writing
$applied = @(); if (Test-Path -LiteralPath $statePath) { $applied = @((Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).Applied) }
foreach ($r in $todo) {
    $wasRunning = $false
    if ($r.Kind -eq 'Service') { $wasRunning = ((Get-Service -Name $r.Name).Status -eq 'Running') }
    if (-not ($applied | Where-Object { $_.Id -eq $r.Id })) { $applied += [pscustomobject]@{ Id = $r.Id; Before = $r.Current; WasRunning = $wasRunning } }
}
([pscustomobject]@{ Captured = (Get-Date -Format s); Applied = $applied } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $statePath -Encoding UTF8
@('# Auto-generated revert for telemetry-tune.ps1. Run ELEVATED.',
  "# Captured $(Get-Date -Format s). Restores what the state file recorded.",
  "& (Join-Path `$PSScriptRoot 'telemetry-tune.ps1') -Undo") | Set-Content -LiteralPath $revertPath -Encoding ASCII
Write-Host "Revert written: $revertPath" -ForegroundColor Cyan

$bad = 0
foreach ($r in $todo) {
    if ($r.Kind -eq 'Service') {
        Stop-Service -Name $r.Name -Force -ErrorAction SilentlyContinue
        Set-Service -Name $r.Name -StartupType Disabled
        $now = "$((Get-Service -Name $r.Name).StartType)"
    } else {
        if (-not (Test-Path $r.Path)) { New-Item -Path $r.Path -Force | Out-Null }
        Set-ItemProperty -Path $r.Path -Name $r.Name -Value $r.Target -Type DWord
        $now = (Get-ItemProperty -Path $r.Path -Name $r.Name).($r.Name)
    }
    if ("$now" -ne "$($r.Target)") { $bad++; Write-Host "FAILED $($r.Name) reads $now after the write, expected $($r.Target)" -ForegroundColor Red }
    else { Write-Host "$($r.Name) = $now (read back)" -ForegroundColor Green }
}
if ($bad) { exit 1 }
Write-Host 'Done. UNDO: menu R, or .\telemetry-tune.ps1 -Undo (elevated).' -ForegroundColor Green
exit 0
