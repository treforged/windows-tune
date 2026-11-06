<#
.SYNOPSIS
    Recommended changes for THIS PC. Reads the machine, changes nothing.

.DESCRIPTION
    Runs privacy\privacy-audit.ps1 (read-only), and for every setting that is not at the recommended value
    lists the change that would fix it: what it does, the risk, the undo and where the claim is documented.
    Only the changes marked SAFE are pre-ticked in the click-install window. Nothing is applied here.
    To apply one, use its menu key (windows-tune.ps1) or tick it in the click-install window and confirm.

    Every telemetry item names its source. "Checked" means the claim was read on Microsoft Learn on
    2026-11-06; "not found" means Microsoft's pages do not say it and it is shown as an opinion, unticked.

.PARAMETER Json
    Print the recommendations as JSON (the click-install window reads this).

.PARAMETER AuditFile
    Read audit lines from this text file instead of running the audit (a test).
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [string]$AuditFile
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { throw 'Cannot resolve this script''s own folder. Run it as a file (.\11-recommended.ps1).' }
$root = Split-Path -Parent $here

# One row per change a person can make. Triggers are the audit's own check names.
# Safe = pre-ticked. A row is Safe only when: Microsoft documents it, it is reversible with a read-back,
# and it cannot break a sign-in, an update or the network.
$CATALOGUE = @(
    @{ Id = 'telemetry-ads'; Key = 'T'; Safe = $true; AbsentCounts = $true
       Title = 'Turn off Windows ad and diagnostic settings'
       Triggers = @('Telemetry policy', 'Advertising ID', 'Tailored experiences', 'Activity feed publish')
       What = 'Sets the diagnostic data policy to the lowest level this Windows edition allows, turns off the advertising ID and tailored experiences, and stops this PC publishing your activity history.'
       Risk = 'Low. On Enterprise or Education with the policy at 0, Microsoft says update failure information is not sent.'
       Undo = 'menu R (telemetry-tune-revert.ps1) restores every value it recorded; nothing is changed without that record.'
       Source = 'Microsoft Learn: Manage connections from Windows operating system components to Microsoft services (sections Advertising ID, Activity History, Feedback and diagnostics) and Configure Windows diagnostic data in your organization. Checked 2026-11-06. The tailored experiences registry value is named in the second page only as a setting.' }
    @{ Id = 'language-list'; Key = 'L'; Safe = $true; AbsentCounts = $true
       Title = 'Hide your language list from websites'
       Triggers = @('Language list hidden')
       What = 'Stops websites reading your full list of display languages, which is a fingerprinting input.'
       Risk = 'Very low. A site may pick its default language instead of your second choice.'
       Undo = 'menu R (privacy-tune-revert.ps1).'
       Source = 'Windows setting "Let websites show me locally relevant content by accessing my language list" (Settings > Privacy & security > General). Not spelled out on the Microsoft Learn pages checked.' }
    @{ Id = 'telemetry-services'; Key = 'Y'; Safe = $false
       Title = 'Disable the DiagTrack and dmwappushservice services'
       Triggers = @('DiagTrack start type', 'dmwappushservice start type')
       What = 'Stops and disables the Connected User Experiences and Telemetry service and the WAP push service.'
       Risk = 'Medium-low. Not a Microsoft instruction, and a feature update may switch them back on. Some Windows and Store features report through these services.'
       Undo = 'menu R (telemetry-tune-revert.ps1) restores the start type it recorded.'
       Source = 'NOT FOUND on the Microsoft Learn pages checked (2026-11-06). Common practice, not documented guidance, so it is not pre-ticked.' }
    @{ Id = 'browser-cookies'; Key = 'B'; Safe = $false
       Title = 'Block third-party cookies in Chrome and Edge'
       Triggers = @('Chrome 3p cookies blocked', 'Chrome ad topics off', 'Edge 3p cookies blocked')
       What = 'Sets browser policy to block third-party cookies and the Privacy Sandbox ad APIs.'
       Risk = 'Medium. Chrome and Edge show "Managed by your organization", and some sign-in or embedded-content sites that rely on third-party cookies stop working.'
       Undo = 'privacy\browser-privacy.ps1 -Undo (removes only the values it wrote).'
       Source = 'Chrome and Edge enterprise policy documentation (BlockThirdPartyCookies). Not a Windows telemetry item.' }
    @{ Id = 'dns-doh'; Key = 'D'; Safe = $false
       Title = 'Encrypt DNS lookups (DNS over HTTPS to Cloudflare)'
       Triggers = @('DoH auto-upgrade 1.1.1.1')
       What = 'Turns on DoH auto-upgrade for the Cloudflare resolvers 1.1.1.1 and 1.0.0.1, so lookups to them are encrypted.'
       Risk = 'Medium. It helps only if your adapter already uses those resolvers, and it trusts Cloudflare with the lookups instead of your ISP. It checks three names after the change and reverts itself if any fails.'
       Undo = 'menu R (dns-encrypt-revert.ps1).'
       Source = 'Windows DoH client settings (Get-DnsClientDohServerAddress). Not a telemetry item.' }
)

function ConvertFrom-AuditLine {
    # One audit line -> @{ What; State } where State is ok, DRIFT or UNREADABLE; $null for any other line.
    param([string]$Line)
    if ($Line -match '^\s+(ok|DRIFT|UNREADABLE)\s+(.+?)(?:\s+=\s+|\s+-\s+).*$') { return @{ State = $Matches[1]; What = $Matches[2].Trim() } }
    return $null
}

function Get-Recommendations {
    # Pure. $AuditLines is the audit's text output. A change is recommended when ANY of its triggers is
    # DRIFT (or UNREADABLE, for rows marked AbsentCounts). Returns one object per change, in catalogue order.
    # An audit that read nothing returns $null (not an empty list): no readings is not "nothing to do".
    param([string[]]$AuditLines)
    $state = @{}
    foreach ($l in $AuditLines) { $r = ConvertFrom-AuditLine $l; if ($r) { $state[$r.What] = $r.State } }
    if ($state.Count -eq 0) { return $null }
    $out = @()
    foreach ($c in $CATALOGUE) {
        # A registry value that does not exist yet means Windows is on its default (data sent): that counts for
        # AbsentCounts rows. For the browser and DNS rows an unreadable value usually means the product is not
        # installed, so only a real DRIFT counts there.
        $bad = @($c.Triggers | Where-Object { $state.ContainsKey($_) -and ($state[$_] -eq 'DRIFT' -or ($c.AbsentCounts -and $state[$_] -eq 'UNREADABLE')) })
        if ($bad.Count -eq 0) { continue }
        $out += [pscustomobject]@{
            Id = $c.Id; Key = $c.Key; PreTicked = [bool]$c.Safe; Title = $c.Title; What = $c.What
            Risk = $c.Risk; Undo = $c.Undo; Source = $c.Source; Because = ($bad -join '; ')
        }
    }
    return , $out
}

if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced by a test: functions only

if ($AuditFile) {
    $lines = @(Get-Content -LiteralPath $AuditFile)
} else {
    $audit = Join-Path $root 'privacy\privacy-audit.ps1'
    if (-not (Test-Path -LiteralPath $audit)) { Write-Host "privacy-audit.ps1 is missing: $audit" -ForegroundColor Red; exit 2 }
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lines = @(& $ps -NoProfile -ExecutionPolicy Bypass -File $audit 2>&1 | ForEach-Object { "$_" })
}
$recs = Get-Recommendations $lines
if ($null -eq $recs) { Write-Host 'The privacy audit read nothing, so no recommendation can be made. This is not a claim your PC is fine.' -ForegroundColor Red; exit 2 }
$recs = @($recs)

if ($Json) { ConvertTo-Json -InputObject @($recs) -Depth 4; exit 0 }

Write-Host 'Recommended for this PC (read-only: nothing below has been applied)' -ForegroundColor Cyan
if ($recs.Count -eq 0) { Write-Host '  Nothing to recommend: every setting the audit checks is already where it should be.' -ForegroundColor Green; exit 0 }
foreach ($r in $recs) {
    Write-Host ("`n  [{0}] menu {1}: {2}" -f $(if ($r.PreTicked) { 'x' } else { ' ' }), $r.Key, $r.Title) -ForegroundColor $(if ($r.PreTicked) { 'Green' } else { 'Yellow' })
    Write-Host "      Why:    $($r.Because) is not at the recommended value"
    Write-Host "      Does:   $($r.What)"
    Write-Host "      Risk:   $($r.Risk)"
    Write-Host "      Undo:   $($r.Undo)"
    Write-Host "      Source: $($r.Source)" -ForegroundColor DarkGray
}
Write-Host "`n[x] = SAFE, pre-ticked in the click-install window. [ ] = your call. Apply by its menu key, or tick it in the window and confirm." -ForegroundColor Cyan
exit 0
