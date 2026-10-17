# browser-privacy.ps1 - block third-party cookies and Privacy Sandbox ad APIs in
# Chrome (the default browser) and Edge, through per-user browser POLICY.
# Per-user (HKCU) values, but RUN ELEVATED: Windows lets only an admin write
# under HKCU\Software\Policies (measured 2026-10-04: New-Item was denied). Chrome and Edge show "Managed by your
# organization" while any of these is set; that banner is the policy, not malware.
#
# Measured before writing this (2026-10-04, one PC): Chrome Default profile had
# cookie_controls_mode = 0, which ALLOWS third-party cookies - the main
# cross-site tracking mechanism. Brave already blocks them by default.
#
# Why a policy and not the Preferences file: Chrome signs its settings (Secure
# Preferences HMAC) and silently resets a hand-edited value.
#
# UNDO is a delete of the values this script created, and the revert gate
# refuses deletes in a *-revert.ps1 by design. So the undo is printed here, and
# this script refuses to run over a policy value that already existed - that
# way the delete can only ever remove what this script added.
#
#   UNDO (per-user, one line):
#   .\browser-privacy.ps1 -Undo

param([switch]$Undo)
$ErrorActionPreference = 'Stop'

$POLICIES = [ordered]@{
    'HKCU:\Software\Policies\Google\Chrome' = [ordered]@{
        BlockThirdPartyCookies             = 1
        PrivacySandboxAdTopicsEnabled      = 0
        PrivacySandboxSiteEnabledAdsEnabled = 0
        PrivacySandboxAdMeasurementEnabled = 0
        PrivacySandboxPromptEnabled        = 0
    }
    'HKCU:\Software\Policies\Microsoft\Edge' = [ordered]@{
        BlockThirdPartyCookies = 1
    }
}
$MARK = 'TreForgedBrowserPrivacy'   # marks the values as ours, so -Undo touches nothing else

if ($Undo) {
    foreach ($k in $POLICIES.Keys) {
        if (-not (Test-Path $k)) { continue }
        if ((Get-ItemProperty $k -Name $MARK -EA SilentlyContinue).$MARK -ne 1) {
            Write-Host "SKIPPED $k - not written by this script, left alone." -ForegroundColor Yellow; continue
        }
        foreach ($n in @($POLICIES[$k].Keys) + $MARK) { Remove-ItemProperty $k -Name $n -EA SilentlyContinue }
        Write-Host "Removed this script's policy values from $k" -ForegroundColor Cyan
    }
    Write-Host 'Restart Chrome and Edge (or open chrome://policy and press Reload policies).'
    exit 0
}

# refuse to overwrite a policy somebody else set
foreach ($k in $POLICIES.Keys) {
    if (-not (Test-Path $k)) { continue }
    if ((Get-ItemProperty $k -Name $MARK -EA SilentlyContinue).$MARK -eq 1) { continue }
    foreach ($n in $POLICIES[$k].Keys) {
        if ($null -ne (Get-ItemProperty $k -Name $n -EA SilentlyContinue).$n) {
            Write-Host "REFUSED: $k\$n already exists and was not set by this script." -ForegroundColor Red; exit 1
        }
    }
}

$bad = 0
foreach ($k in $POLICIES.Keys) {
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    foreach ($n in $POLICIES[$k].Keys) {
        Set-ItemProperty $k -Name $n -Value $POLICIES[$k][$n] -Type DWord
        $got = (Get-ItemProperty $k -Name $n).$n
        if ($got -ne $POLICIES[$k][$n]) { $bad++; Write-Host "FAILED $k\$n reads $got" -ForegroundColor Red }
        else { Write-Host "$k\$n = $got" }
    }
    Set-ItemProperty $k -Name $MARK -Value 1 -Type DWord
}
if ($bad) { exit 1 }
Write-Host 'Done. Restart Chrome and Edge to apply. UNDO: .\browser-privacy.ps1 -Undo' -ForegroundColor Green
