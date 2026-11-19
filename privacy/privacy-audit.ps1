# privacy-audit.ps1 - READ-ONLY. Re-measures a recommended privacy posture
# (the values privacy-tune.ps1 and browser-privacy.ps1 set, plus telemetry and ad settings) and exits non-zero when any has drifted. No admin. Writes nothing.
# Windows feature updates are known to switch telemetry and ad settings back on,
# so a one-day audit protects one day. Run this after any update.
#
# Exit 0 all expected, 1 drift found, 2 nothing could be read (an instrument
# failure must never look like a clean machine).

$ErrorActionPreference = 'SilentlyContinue'

function Read-Reg([string]$Path, [string]$Name) { (Get-ItemProperty -Path $Path -Name $Name -EA SilentlyContinue).$Name }

# Microsoft: "Diagnostic data off" (0) is honoured only on Enterprise, Education and Server. Elsewhere 1
# (Required) is the lowest level, so 0 or 1 both count as as low as this edition goes.
$edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID -EA SilentlyContinue).EditionID
$telemetryWant = if ("$edition" -match '^(Enterprise|Education|Server)') { '0' } else { '0|1' }

$CHECKS = @(
    @{ What = 'Telemetry policy';            Want = $telemetryWant;        Get = { Read-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' } }
    @{ What = 'Advertising ID';              Want = '0';        Get = { Read-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' } }
    @{ What = 'Tailored experiences';        Want = '0';        Get = { Read-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' } }
    @{ What = 'Activity feed publish';       Want = '0';        Get = { Read-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' } }
    @{ What = 'Language list hidden';        Want = '1';        Get = { Read-Reg 'HKCU:\Control Panel\International\User Profile' 'HttpAcceptLanguageOptOut' } }
    @{ What = 'Location consent';            Want = 'Deny';     Get = { Read-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' } }
    @{ What = 'DiagTrack start type';        Want = 'Disabled'; Get = { "$((Get-Service DiagTrack -EA SilentlyContinue).StartType)" } }
    @{ What = 'dmwappushservice start type'; Want = 'Disabled'; Get = { "$((Get-Service dmwappushservice -EA SilentlyContinue).StartType)" } }
    @{ What = 'Chrome 3p cookies blocked';   Want = '1';        Get = { Read-Reg 'HKCU:\Software\Policies\Google\Chrome' 'BlockThirdPartyCookies' } }
    @{ What = 'Chrome ad topics off';        Want = '0';        Get = { Read-Reg 'HKCU:\Software\Policies\Google\Chrome' 'PrivacySandboxAdTopicsEnabled' } }
    @{ What = 'Edge 3p cookies blocked';     Want = '1';        Get = { Read-Reg 'HKCU:\Software\Policies\Microsoft\Edge' 'BlockThirdPartyCookies' } }
    @{ What = 'DoH auto-upgrade 1.1.1.1';    Want = 'True';     Get = { "$((Get-DnsClientDohServerAddress -ServerAddress 1.1.1.1 -EA SilentlyContinue).AutoUpgrade)" } }
)

$read = 0; $drift = 0
foreach ($c in $CHECKS) {
    $now = "$(& $c.Get)"
    if ($now -eq '') { $drift++; Write-Host ("  UNREADABLE {0} - expected {1}, value absent" -f $c.What, $c.Want) -ForegroundColor Red; continue }
    $read++
    if ($now -match "^($($c.Want))$") { Write-Host ("  ok         {0} = {1}" -f $c.What, $now) }
    else { $drift++; Write-Host ("  DRIFT      {0} = {1}, expected {2}" -f $c.What, $now, $c.Want) -ForegroundColor Yellow }
}
# Information only, never DRIFT and never a recommendation (Sam ruling 11-19, ask fcee8b7c): Defender can
# upload files to Microsoft for analysis. Less upload means weaker protection against new malware, so this
# audit shows the setting and the trade-off and leaves the choice to the person. Values: Microsoft Learn,
# Set-MpPreference (SubmitSamplesConsent, MAPSReporting).
function Format-DefenderSampleInfo($Consent, $Maps) {
    $c = @{ '0' = 'always prompt'; '1' = 'send safe samples automatically'; '2' = 'never send'; '3' = 'send all samples automatically' }["$Consent"]
    $m = @{ '0' = 'cloud protection off'; '1' = 'basic'; '2' = 'advanced' }["$Maps"]
    if (-not $c -or -not $m) { return '  info       Defender file upload: could not be read (Defender off, or another antivirus is in charge)' }
    return ("  info       Defender file upload: samples = {0}, cloud reporting = {1}. Less upload sends fewer of your files to Microsoft but weakens protection against new malware. Change it only on purpose: Windows Security > Virus & threat protection settings." -f $c, $m)
}
$mp = Get-MpPreference -EA SilentlyContinue
Write-Host (Format-DefenderSampleInfo $mp.SubmitSamplesConsent $mp.MAPSReporting)

Write-Host "$($CHECKS.Count) checks, $read readable, $drift not as expected."
if ($read -eq 0) { exit 2 }
if ($drift) { exit 1 }
exit 0
