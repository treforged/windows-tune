<#
.SYNOPSIS
    Fully uninstall a third-party antivirus and hand real-time protection back
    to Windows Defender - usually with no reboot and no Tamper Protection toggle.

.DESCRIPTION
    The reliable way out of "my third-party AV is off but Defender never took
    over" is not to fight Defender. It is to remove whatever still holds the
    Windows Security Center registration.

    Why this works when scripted repair does not:

      Tamper Protection blocks SCRIPTS from enabling Defender or writing its
      settings. It does NOT block Windows from promoting Defender on its own
      once no other product is registered. Uninstall the other AV and Windows
      does the handover itself, past Tamper Protection, because it is Windows
      doing it rather than a script.

    Measured on the reference machine: Defender went from fully disabled
    (DisableAntiSpyware=1, WinDefend Stopped) to AMRunningMode Normal with
    real-time protection on, seconds after the uninstall, with no reboot.

    A useful side effect: shell and build times. A competing scanner inspecting
    every interpreter spawn is a large hidden tax. PowerShell startup here went
    from 598 ms to ~120 ms - from removing the scanner, not from exclusions.

.PARAMETER Name
    Substring matched against installed product display names, e.g. 'Surfshark',
    'Avast', 'McAfee'. Matching products are listed and confirmed before removal.

.PARAMETER ProductCode
    Exact MSI product code, e.g. '{572A24C0-...}'. Skips the name search.

.PARAMETER Force
    Skip the confirmation prompt. Intended for unattended runs.

.EXAMPLE
    .\06-remove-third-party-av.ps1 -Name Surfshark
.EXAMPLE
    .\06-remove-third-party-av.ps1 -ProductCode '{572A24C0-7AC6-44EB-B9FE-8B01BEE37687}' -Force

.NOTES
    Only handles MSI-based products. Vendors shipping a custom uninstaller (or
    an "AV remover" tool) need theirs; this script will say so rather than guess.
    Check whether you actually use the product first - on the reference machine
    the bundled VPN had moved 0 bytes, which is what made removal the easy call.
#>
[CmdletBinding()]
param(
    [string]$Name,
    [string]$ProductCode,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated PowerShell (Run as administrator).'
}
if (-not $Name -and -not $ProductCode) { throw 'Pass -Name or -ProductCode.' }

Write-Host '=== REGISTERED AV PRODUCTS (before) ===' -ForegroundColor Cyan
Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue |
    Sort-Object displayName -Unique | Format-Table displayName, productState -AutoSize

# ------------------------------------------------------------- find the product
if (-not $ProductCode) {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $found = Get-ItemProperty $keys -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -match [regex]::Escape($Name) } |
             Select-Object DisplayName, DisplayVersion, UninstallString, PSChildName -Unique

    if (-not $found) { Write-Host "No installed product matching '$Name'." -ForegroundColor Yellow; return }

    Write-Host "`nMatched:" -ForegroundColor Cyan
    $found | Format-Table DisplayName, DisplayVersion, PSChildName -AutoSize

    $msi = $found | Where-Object { $_.PSChildName -match '^\{[0-9A-Fa-f\-]{36}\}$' } | Select-Object -First 1
    if (-not $msi) {
        Write-Host 'No MSI product code found - this product ships its own uninstaller.' -ForegroundColor Yellow
        Write-Host 'Uninstall it from Settings > Apps, then run 05-defender-handover.ps1.' -ForegroundColor Yellow
        return
    }
    $ProductCode = $msi.PSChildName
    $label = $msi.DisplayName
} else {
    $label = $ProductCode
}

if (-not $Force) {
    $answer = Read-Host "`nUninstall '$label' ? This removes the whole product, VPN and extras included. [y/N]"
    if ($answer -notmatch '^y') { Write-Host 'Aborted.'; return }
}

# Close the vendor's tray apps so the MSI does not stall on a live UI.
if ($Name) {
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match [regex]::Escape($Name) } |
        ForEach-Object { Write-Host "  stopping $($_.Name)"; Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
}

Write-Host "`n--- UNINSTALLING $ProductCode ---" -ForegroundColor Yellow
$log = Join-Path $env:TEMP "av-uninstall-$($ProductCode -replace '[{}]','').log"
$p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @('/x', $ProductCode, '/qn', '/norestart', '/l*v', "`"$log`"")

switch ($p.ExitCode) {
    0     { Write-Host 'Uninstalled.' -ForegroundColor Green }
    3010  { Write-Host 'Uninstalled - a reboot is queued to finish cleanup.' -ForegroundColor Green }
    1605  { Write-Host 'Product was already absent.' -ForegroundColor Yellow }
    default {
        Write-Host "msiexec exit $($p.ExitCode) - see $log" -ForegroundColor Red
        Write-Host 'Not continuing; protection state unchanged.' -ForegroundColor Red
        return
    }
}

Start-Sleep -Seconds 8

# --------------------------------------------------- wait for Windows to hand over
Write-Host "`n--- WAITING FOR DEFENDER HANDOVER (up to 90 s) ---" -ForegroundColor Yellow
& sc.exe config WinDefend start= auto | Out-Null
& sc.exe start  WinDefend *>$null
for ($i = 0; $i -lt 18; $i++) {
    if ((Get-MpComputerStatus -ErrorAction SilentlyContinue).RealTimeProtectionEnabled) { break }
    Start-Sleep -Seconds 5
}

$st = Get-MpComputerStatus -ErrorAction SilentlyContinue
Write-Host ''
if ($st.RealTimeProtectionEnabled) {
    Write-Host 'DEFENDER IS PROTECTING - no reboot needed.' -ForegroundColor Green
    try { Update-MpSignature -ErrorAction Stop; Write-Host '  signatures updated' }
    catch { Write-Host "  signature update reported: $($_.Exception.Message)" -ForegroundColor DarkYellow
            Write-Host '  (0x80070652 means another install was running; check the version below)' -ForegroundColor DarkGray }
} else {
    Write-Host 'Defender has not taken over yet.' -ForegroundColor Yellow
    Write-Host 'Nothing is competing for the registration now, and Windows re-evaluates at' -ForegroundColor Yellow
    Write-Host 'boot. REBOOT, then run 05-defender-handover.ps1 -Diagnose.' -ForegroundColor Yellow
    Write-Host 'THIS PC HAS NO REAL-TIME ANTIVIRUS UNTIL THEN.' -ForegroundColor Red
}

Write-Host "`n=== FINAL ===" -ForegroundColor Cyan
Get-Service WinDefend -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType -AutoSize
$st | Select-Object AMRunningMode, RealTimeProtectionEnabled, AntivirusEnabled, BehaviorMonitorEnabled,
                    AntivirusSignatureVersion, AntivirusSignatureLastUpdated | Format-List
Write-Host 'A stale entry for the removed product may linger in Security Center until reboot.' -ForegroundColor DarkGray
Write-Host 'Harmless: AMRunningMode "Normal" means Defender owns protection.' -ForegroundColor DarkGray
