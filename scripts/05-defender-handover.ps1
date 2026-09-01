<#
.SYNOPSIS
    Diagnose (and where possible repair) a machine left with NO real-time
    antivirus after a third-party AV is removed or switched off.

.DESCRIPTION
    When a third-party antivirus installs, it registers with the Windows
    Security Center and Windows stands Defender down. If that AV is later
    disabled rather than fully uninstalled, the registration can persist and the
    machine ends up in the worst possible state: the third-party scanner is off
    and Defender has not taken over. Nothing warns you loudly.

    This script reports the true state and repairs what CAN be repaired from a
    script. Two things deliberately cannot be:

      * TAMPER PROTECTION. When it is on, Windows reverts programmatic changes
        to Defender's services and settings - by design, because that is exactly
        what malware attempts. It is only switchable in the Windows Security UI.
        A script that claims to have re-enabled Defender past Tamper Protection
        is lying to you.
      * The Security Center registration itself, which is owned by the other
        vendor's WSC agent and re-evaluated at boot.

    THE SHORTCUT MOST PEOPLE MISS: Tamper Protection blocks SCRIPTS from
    enabling Defender. It does NOT block Windows from promoting Defender by
    itself once no third-party AV holds the Security Center registration. So
    fully UNINSTALLING the other product (see 06) usually beats every repair
    here - it needs no Tamper Protection toggle and frequently no reboot. Reach
    for -Repair only when you intend to keep the other AV installed.

    So: -Diagnose tells you the truth, -Repair does the safe subset, and both
    tell you plainly when a reboot or a manual UI step is the only way forward.

.PARAMETER Repair
    Clear Defender's disable keys and set its services to automatic.

.PARAMETER AddDevExclusions
    Once Defender is genuinely protecting, exclude common developer
    interpreters and paths. Real-time scanning of every python/node/git spawn is
    a large and frequently-missed cause of slow shells and build times.

.EXAMPLE
    .\05-defender-handover.ps1 -Diagnose
.EXAMPLE
    .\05-defender-handover.ps1 -Repair -AddDevExclusions
#>
[CmdletBinding()]
param(
    [switch]$Diagnose,
    [switch]$Repair,
    [switch]$AddDevExclusions
)

$ErrorActionPreference = 'Continue'
if (-not $Diagnose -and -not $Repair) { $Diagnose = $true }

# -Diagnose only reads (Security Center, services, two registry keys,
# Get-MpComputerStatus) and works from a normal prompt. Only -Repair writes,
# so only -Repair needs administrator rights - checked up front so nothing is
# half-done when it refuses.
if ($Repair -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated PowerShell (Run as administrator) to use -Repair. -Diagnose works without it.'
}

# ------------------------------------------------------------------ diagnose
Write-Host '=== REGISTERED AV PRODUCTS (Security Center) ===' -ForegroundColor Cyan
$products = Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue
$products | Sort-Object displayName -Unique |
    Format-Table displayName, productState, pathToSignedProductExe -AutoSize -Wrap

Write-Host '=== SERVICES ===' -ForegroundColor Cyan
Get-Service WinDefend, WdNisSvc, wscsvc, SecurityHealthService -ErrorAction SilentlyContinue |
    Format-Table Name, Status, StartType -AutoSize

$tamper = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -ErrorAction SilentlyContinue).TamperProtection
$tamperOn = ($tamper -eq 1 -or $tamper -eq 5)
Write-Host "Tamper Protection: $(if ($tamperOn) { 'ON  <-- blocks scripted repair' } else { 'off' })" -ForegroundColor $(if ($tamperOn) { 'Yellow' } else { 'Gray' })

$sig = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Signature Updates' -ErrorAction SilentlyContinue
if ($sig.SignaturesLastUpdated) {
    $when = [datetime]::FromFileTime([BitConverter]::ToInt64($sig.SignaturesLastUpdated, 0))
    $age  = [math]::Round(((Get-Date) - $when).TotalDays)
    Write-Host "Signatures: $($sig.AVSignatureVersion), last updated $($when.ToString('yyyy-MM-dd')) ($age days ago)" -ForegroundColor $(if ($age -gt 7) { 'Yellow' } else { 'Gray' })
}

$status = Get-MpComputerStatus -ErrorAction SilentlyContinue
Write-Host ''
if ($null -eq $status) {
    # No reading is not the same as OFF. Say so rather than shout UNPROTECTED
    # on a machine where the Defender platform is simply absent or unreadable.
    Write-Host 'REAL-TIME PROTECTION: UNKNOWN - Get-MpComputerStatus returned nothing' -ForegroundColor Yellow
    Write-Host '(Defender platform missing, disabled by policy, or not readable here). No claim either way.' -ForegroundColor Yellow
} elseif ($status.RealTimeProtectionEnabled) {
    Write-Host 'REAL-TIME PROTECTION: ON' -ForegroundColor Green
} else {
    Write-Host 'REAL-TIME PROTECTION: OFF - this machine is UNPROTECTED' -ForegroundColor Red
    $others = $products | Where-Object { $_.displayName -notmatch 'Windows Defender' }
    if ($others) {
        Write-Host ("Still registered: {0}. Windows will not promote Defender while another" -f (($others.displayName | Sort-Object -Unique) -join ', ')) -ForegroundColor Red
        Write-Host 'product holds the registration. Fully UNINSTALL it, or reboot so Windows' -ForegroundColor Red
        Write-Host 're-evaluates, then run this again.' -ForegroundColor Red
    }
}

if (-not $Repair) { return }

# -------------------------------------------------------------------- repair
Write-Host "`n=== REPAIR ===" -ForegroundColor Yellow
if ($tamperOn) {
    Write-Host 'Tamper Protection is ON. Changes below will very likely be reverted.' -ForegroundColor Yellow
    Write-Host 'Turn it off first: Windows Security > Virus & threat protection >' -ForegroundColor Yellow
    Write-Host 'Manage settings > Tamper Protection. It cannot be scripted, by design.' -ForegroundColor Yellow
}

foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows Defender',
                 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender',
                 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection')) {
    if (Test-Path $k) {
        foreach ($n in @('DisableAntiSpyware', 'DisableAntiVirus', 'DisableRealtimeMonitoring',
                         'DisableOnAccessProtection', 'DisableBehaviorMonitoring')) {
            if ($null -ne (Get-ItemProperty $k -Name $n -ErrorAction SilentlyContinue).$n) {
                Remove-ItemProperty $k -Name $n -Force -ErrorAction SilentlyContinue
                Write-Host "  cleared $n"
            }
        }
    }
}

foreach ($svc in @('wscsvc', 'WinDefend', 'WdNisSvc', 'SecurityHealthService')) {
    & sc.exe config $svc start= auto | Out-Null
    & sc.exe start  $svc *>$null
}
Start-Sleep -Seconds 6

$status = Get-MpComputerStatus -ErrorAction SilentlyContinue
if ($status.RealTimeProtectionEnabled) {
    Write-Host 'Defender is now protecting.' -ForegroundColor Green
    try { Update-MpSignature -ErrorAction Stop; Write-Host '  signatures updated' } catch { Write-Warning "  signature update failed: $($_.Exception.Message)" }

    if ($AddDevExclusions) {
        # Add-MpPreference does not always throw when the write is discarded -
        # notably while Defender is still settling after a handover, when it
        # reports success and stores nothing. Every value is therefore read back
        # and confirmed rather than reported from the call.
        # Measured note: on the reference machine these exclusions made no
        # difference to shell spawn time once the competing scanner was gone.
        # Keep them only if they show up in a measurement on YOUR machine.
        $wantProc = @('python.exe','pythonw.exe','node.exe','powershell.exe','pwsh.exe','git.exe','bash.exe','ollama.exe','msbuild.exe','cargo.exe','go.exe')
        $wantPath = @("$env:USERPROFILE\.claude", "$env:USERPROFILE\.ollama", "$env:USERPROFILE\.cargo",
                      "$env:USERPROFILE\go", "$env:LOCALAPPDATA\Programs\Ollama") | Where-Object { Test-Path $_ }

        foreach ($p in $wantProc) { try { Add-MpPreference -ExclusionProcess $p -ErrorAction Stop } catch {} }
        foreach ($p in $wantPath) { try { Add-MpPreference -ExclusionPath   $p -ErrorAction Stop } catch {} }

        $now     = Get-MpPreference
        $gotProc = @($wantProc | Where-Object { $now.ExclusionProcess -contains $_ })
        $gotPath = @($wantPath | Where-Object { $now.ExclusionPath    -contains $_ })
        Write-Host "  processes: $($gotProc.Count)/$($wantProc.Count) stored"
        Write-Host "  paths:     $($gotPath.Count)/$($wantPath.Count) stored"

        if ($gotProc.Count -eq 0 -and $wantProc.Count -gt 0) {
            Write-Host ''
            Write-Host '  NONE of the exclusions were stored - the add calls reported success' -ForegroundColor Yellow
            Write-Host '  and nothing was written. Usually Defender has not finished settling.' -ForegroundColor Yellow
            Write-Host "  Wait for AMRunningMode 'Normal' and re-run, add them via Windows" -ForegroundColor Yellow
            Write-Host '  Security > Exclusions, or skip them: removing a competing scanner is' -ForegroundColor Yellow
            Write-Host '  the real win and exclusions may buy nothing measurable.' -ForegroundColor Yellow
        }
    }
} else {
    Write-Host 'Defender STILL not protecting.' -ForegroundColor Red
    Write-Host 'Order that works: turn Tamper Protection off in the UI -> fully uninstall the' -ForegroundColor Red
    Write-Host 'other AV -> reboot -> re-run this with -Repair -AddDevExclusions.' -ForegroundColor Red
    Write-Host 'Until then, re-enable your previous AV rather than sitting unprotected.' -ForegroundColor Red
}
