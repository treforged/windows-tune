<#
.SYNOPSIS
    Undo the network "optimizations" that gaming tweak scripts get wrong.

.DESCRIPTION
    Most Windows "gaming optimizer" tools disable TCP receive-window auto-tuning,
    Receive-Side Scaling and Receive Segment Coalescing, and switch off NIC
    hardware offloads. Every one of those costs throughput and none of them help
    latency. The single worst is auto-tuning: with it disabled the TCP receive
    window is pinned at 64 KB, so one stream is capped at (64 KB / RTT). At a
    22 ms round-trip that is about 23 Mbit/s no matter how fast the line is.

    Measured on the machine this was written for: 17 Mbit/s -> 336 Mbit/s.

    Every targeted value is READ before anything is written. On a machine that
    is already tuned the script says so and stops: no revert file, no writes,
    and no adapter bounce. Only the settings that actually differ are changed,
    and the adapter is bounced only if a NIC driver property really changed.

    Tier A changes apply live with no link drop. Tier B are NIC driver
    properties, staged with -NoRestart so they cost nothing until the adapter is
    bounced (-BounceAdapter) or the machine next reboots.

.PARAMETER AdapterName
    Adapter to tune. Defaults to the physical adapter owning the default route.

.PARAMETER BounceAdapter
    Apply the staged NIC properties immediately (~5 s offline). Ignored when no
    NIC property needed changing.

.PARAMETER SetDns
    Also set DNS to Cloudflare. Off by default: DNS is a personal choice and it
    does not change in-game ping, only name-resolution latency.

.EXAMPLE
    .\01-network-tune.ps1
.EXAMPLE
    .\01-network-tune.ps1 -BounceAdapter -SetDns

.NOTES
    Writes <script>-revert.ps1 capturing the CURRENT values before changing
    anything - and only when there is something to change. Touches no firewall,
    antivirus, service or policy setting.
#>
[CmdletBinding()]
param(
    [string]$AdapterName,
    [switch]$BounceAdapter,
    [switch]$SetDns
)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated PowerShell (Run as administrator).'
}

# ------------------------------------------------------------------ targets
$staged = @(
    @{ Name = 'Green Ethernet';               Value = 'Disabled' }
    @{ Name = 'Power Saving Mode';            Value = 'Disabled' }
    @{ Name = 'Gigabit Lite';                 Value = 'Disabled' }
    @{ Name = 'Flow Control';                 Value = 'Disabled' }
    @{ Name = 'IPv4 Checksum Offload';        Value = 'Rx & Tx Enabled' }
    @{ Name = 'TCP Checksum Offload (IPv4)';  Value = 'Rx & Tx Enabled' }
    @{ Name = 'TCP Checksum Offload (IPv6)';  Value = 'Rx & Tx Enabled' }
    @{ Name = 'UDP Checksum Offload (IPv4)';  Value = 'Rx & Tx Enabled' }
    @{ Name = 'UDP Checksum Offload (IPv6)';  Value = 'Rx & Tx Enabled' }
    @{ Name = 'Large Send Offload v2 (IPv4)'; Value = 'Enabled' }
    @{ Name = 'Large Send Offload v2 (IPv6)'; Value = 'Enabled' }
)
$mmKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'

<#
.SYNOPSIS
    Compare a snapshot of the current network state against the targets.

.DESCRIPTION
    Pure: reads nothing from the machine and writes nothing. It exists as its
    own function so tests\preflight.ps1 can press it with synthetic states from
    an unelevated prompt, where the rest of this script refuses to run.

    Returns one object per setting that differs, with Item, From and To - and an
    EMPTY array when the machine is already at target. A setting the adapter does
    not support is not a difference.
#>
function Get-PendingNetworkChanges {
    param(
        [hashtable]$Current,
        [object[]]$Staged
    )

    function Format-Value([object]$v) {
        if ($null -eq $v) { return '' }
        return ([string]$v).Trim()
    }
    function Test-SameValue([object]$a, [object]$b) {
        return [string]::Equals((Format-Value $a), (Format-Value $b), [StringComparison]::OrdinalIgnoreCase)
    }

    $list = [System.Collections.Generic.List[object]]::new()

    # netsh reports these as words. An unreadable value is a difference, not a
    # match: never treat "could not read it" as "it is already correct".
    foreach ($t in @(
        @{ Item = 'TCP autotuning';  Value = $Current.AutoTuning; To = 'normal' }
        @{ Item = 'RSS';             Value = $Current.Rss;        To = 'enabled' }
        @{ Item = 'RSC';             Value = $Current.Rsc;        To = 'enabled' }
    )) {
        if (-not (Test-SameValue $t.Value $t.To)) {
            $from = Format-Value $t.Value
            if ($from -eq '') { $from = 'unknown' }
            $list.Add([pscustomobject]@{ Item = $t.Item; From = $from; To = $t.To })
        }
    }

    # A DWORD of 0xFFFFFFFF comes back from Get-ItemProperty as Int32 -1, so it
    # must be masked to unsigned before comparing. Casting -1 to [uint32]
    # directly THROWS, and it throws on precisely the already-tuned machine.
    $target = [uint32]4294967295
    $cur = $Current.ThrottlingIndex
    if ($null -eq $cur) {
        $list.Add([pscustomobject]@{ Item = 'NetworkThrottlingIndex'; From = 'not set'; To = $target })
    } else {
        $masked = $null
        try { $masked = [uint32]([int64]$cur -band 0xFFFFFFFFL) } catch { $masked = $null }
        if ($null -eq $masked) {
            $list.Add([pscustomobject]@{ Item = 'NetworkThrottlingIndex'; From = 'unreadable'; To = $target })
        } elseif ($masked -ne $target) {
            $list.Add([pscustomobject]@{ Item = 'NetworkThrottlingIndex'; From = $masked; To = $target })
        }
    }

    # $null means the adapter does not expose power management - not a change.
    if ($null -ne $Current.NicPowerDown -and -not (Test-SameValue $Current.NicPowerDown 'Disabled')) {
        $list.Add([pscustomobject]@{ Item = 'NIC power-down'; From = (Format-Value $Current.NicPowerDown); To = 'Disabled' })
    }

    # A staged property absent from the snapshot is one this NIC does not have.
    foreach ($s in $Staged) {
        if (-not $Current.Advanced -or -not $Current.Advanced.ContainsKey($s.Name)) { continue }
        $have = $Current.Advanced[$s.Name]
        if (-not (Test-SameValue $have $s.Value)) {
            $list.Add([pscustomobject]@{ Item = $s.Name; From = (Format-Value $have); To = $s.Value })
        }
    }

    # No leading comma: the callers wrap this in @(), which is what makes a
    # single result a one-element array. Returning ,$array instead hands the
    # caller ONE object that happens to be an array, and @() around that is a
    # 1-element array forever - so "nothing to change" could never be reached.
    return $list.ToArray()
}

# Resolve the adapter that actually carries traffic, rather than guessing a name.
if (-not $AdapterName) {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
             Sort-Object RouteMetric | Select-Object -First 1
    if (-not $route) { throw 'No default route found - is this machine online?' }
    $AdapterName = (Get-NetAdapter -InterfaceIndex $route.ifIndex).Name
}
$nic = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
Write-Host "Adapter: $($nic.Name) - $($nic.InterfaceDescription) @ $($nic.LinkSpeed)" -ForegroundColor Cyan

# --------------------------------------------------------- read what is there
$g = netsh int tcp show global
# netsh output is LOCALIZED. On a non-English Windows these labels do not match,
# and the old one-liner then called .Trim() on an empty match and died with
# "[System.Object[]] does not contain a method named 'Trim'" - a message that
# tells the user nothing. Say what is actually wrong instead. Proven by
# tests\preflight.ps1 stage 13 against synthetic German netsh output.
function Get-TcpGlobal([string]$label) {
    $line = @($g | Select-String $label | Select-Object -First 1)
    if (-not $line -or -not $line[0]) {
        throw ("Could not find '$label' in 'netsh int tcp show global'. These scripts " +
               "read the ENGLISH labels of Windows command output, so they need an " +
               "English-language Windows. Nothing has been changed.")
    }
    ("$($line[0])" -replace '.*:\s*', '').Trim()
}

$pm = Get-NetAdapterPowerManagement -Name $AdapterName -ErrorAction SilentlyContinue
$advanced = @{}
foreach ($s in $staged) {
    $cur = Get-NetAdapterAdvancedProperty -Name $AdapterName -DisplayName $s.Name -ErrorAction SilentlyContinue
    if ($cur) { $advanced[$s.Name] = $cur.DisplayValue }
}
$nicPowerDown = $null
if ($pm) { $nicPowerDown = $pm.AllowComputerToTurnOffDevice }
$current = @{
    AutoTuning      = Get-TcpGlobal 'Receive Window Auto-Tuning Level'
    Rss             = Get-TcpGlobal 'Receive-Side Scaling State'
    Rsc             = Get-TcpGlobal 'Receive Segment Coalescing State'
    ThrottlingIndex = (Get-ItemProperty $mmKey -ErrorAction SilentlyContinue).NetworkThrottlingIndex
    NicPowerDown    = $nicPowerDown
    Advanced        = $advanced
}

$pending = @(Get-PendingNetworkChanges -Current $current -Staged $staged)

# DNS is an explicit request, not part of the tune, so it is compared here.
$dnsPending = $false
if ($SetDns) {
    $wantDns = @('1.1.1.1', '1.0.0.1')
    $haveDns = @((Get-DnsClientServerAddress -InterfaceAlias $AdapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
    if (($haveDns -join ',') -ne ($wantDns -join ',')) { $dnsPending = $true }
}

if ($pending.Count -eq 0 -and -not $dnsPending) {
    Write-Host "`nalready at target - nothing to change" -ForegroundColor Green
    Write-Host "  autotuning $($current.AutoTuning), rss $($current.Rss), rsc $($current.Rsc), NetworkThrottlingIndex disabled"
    Write-Host "  $($advanced.Count) NIC properties checked, all at target; adapter not bounced, no revert file written." -ForegroundColor DarkGray
    exit 0
}

Write-Host "`n--- WILL CHANGE ($($pending.Count) setting$(if ($pending.Count -ne 1) { 's' })) ---" -ForegroundColor Yellow
$pending | Format-Table Item, From, To -AutoSize
if ($dnsPending) { Write-Host '  DNS -> 1.1.1.1 / 1.0.0.1' }

# ---------------------------------------------------------------- revert file
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$revert = Join-Path $here '01-network-tune-revert.ps1'

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Auto-generated revert. Run ELEVATED to restore prior values.')
$lines.Add("# Captured $(Get-Date -Format s) for adapter '$AdapterName'")
$lines.Add("netsh int tcp set global autotuninglevel=$($current.AutoTuning)")
$lines.Add("netsh int tcp set global rss=$($current.Rss)")
$lines.Add("netsh int tcp set global rsc=$($current.Rsc)")
foreach ($s in $staged) {
    if ($advanced.ContainsKey($s.Name)) {
        $lines.Add("Set-NetAdapterAdvancedProperty -Name '$AdapterName' -DisplayName '$($s.Name)' -DisplayValue '$($advanced[$s.Name])' -NoRestart")
    }
}
if ($pm) { $lines.Add("`$p = Get-NetAdapterPowerManagement -Name '$AdapterName'; `$p.AllowComputerToTurnOffDevice = '$($pm.AllowComputerToTurnOffDevice)'; Set-NetAdapterPowerManagement -InputObject `$p") }
$lines.Add("Set-ItemProperty '$mmKey' -Name NetworkThrottlingIndex -Value $($current.ThrottlingIndex) -Type DWord")
if ($SetDns) {
    $dns = (Get-DnsClientServerAddress -InterfaceAlias $AdapterName -AddressFamily IPv4).ServerAddresses
    $lines.Add("Set-DnsClientServerAddress -InterfaceAlias '$AdapterName' -ServerAddresses $(($dns | ForEach-Object { "'$_'" }) -join ',')")
}
$lines.Add("Restart-NetAdapter -Name '$AdapterName'")
Set-Content -Path $revert -Value $lines -Encoding UTF8
Write-Host "Revert written: $revert" -ForegroundColor Cyan

# Only what actually differs is written. Everything else is already correct.
$pendingItems = @($pending | ForEach-Object { $_.Item })

# ------------------------------------------------- Tier A: live, no link drop
Write-Host "`n--- Tier A (live) ---" -ForegroundColor Yellow
if ($pendingItems -contains 'TCP autotuning') { netsh int tcp set global autotuninglevel=normal | Out-Null; Write-Host '  autotuning = normal   <- the throughput fix' }
if ($pendingItems -contains 'RSS')            { netsh int tcp set global rss=enabled | Out-Null; Write-Host '  rss = enabled' }
if ($pendingItems -contains 'RSC')            { netsh int tcp set global rsc=enabled | Out-Null; Write-Host '  rsc = enabled' }

# Default 10 throttles non-multimedia traffic to ~10 packets/ms.
if ($pendingItems -contains 'NetworkThrottlingIndex') {
    Set-ItemProperty $mmKey -Name NetworkThrottlingIndex -Value 0xFFFFFFFF -Type DWord
    Write-Host '  NetworkThrottlingIndex = disabled'
}

if ($pendingItems -contains 'NIC power-down') {
    $pm.AllowComputerToTurnOffDevice = 'Disabled'
    Set-NetAdapterPowerManagement -InputObject $pm
    Write-Host '  NIC power-down = Disabled'
}

if ($dnsPending) {
    Set-DnsClientServerAddress -InterfaceAlias $AdapterName -ServerAddresses ('1.1.1.1','1.0.0.1')
    Clear-DnsClientCache
    Write-Host '  DNS = 1.1.1.1 / 1.0.0.1'
}

# ------------------------------------------------ Tier B: staged NIC settings
$stagedPending = @($staged | Where-Object { $pendingItems -contains $_.Name })
Write-Host "`n--- Tier B (staged) ---" -ForegroundColor Yellow
if ($stagedPending.Count -eq 0) {
    Write-Host '  every NIC property is already at target - nothing staged' -ForegroundColor Green
}
foreach ($s in $stagedPending) {
    try {
        Set-NetAdapterAdvancedProperty -Name $AdapterName -DisplayName $s.Name -DisplayValue $s.Value -NoRestart -ErrorAction Stop
        Write-Host "  staged $($s.Name) = $($s.Value)"
    } catch {
        Write-Host "  n/a     $($s.Name)" -ForegroundColor DarkGray
    }
}
# Interrupt Moderation is intentionally NOT re-enabled. Disabling it genuinely
# helps latency and is the one tweak these optimizer scripts get right.

# A bounce costs ~5 s offline, so it is never spent on nothing.
if ($stagedPending.Count -eq 0) {
    Write-Host "`nNo NIC property changed - adapter not bounced." -ForegroundColor Green
} elseif ($BounceAdapter) {
    Write-Host "`nBouncing adapter (~5 s offline)..." -ForegroundColor Yellow
    Restart-NetAdapter -Name $AdapterName
    Start-Sleep -Seconds 8
} else {
    Write-Host "`nTier B pending. Apply with -BounceAdapter, or at next reboot." -ForegroundColor Cyan
}

Write-Host "`n=== AFTER ===" -ForegroundColor Green
netsh int tcp show global
Get-NetAdapter -Name $AdapterName | Format-Table Name, Status, LinkSpeed -AutoSize

# READ THE VALUES BACK OFF THE MACHINE. Printing the after-state is not the same
# as checking it: every command above can report success and change nothing, and
# a settings write that silently did not take looks exactly like one that did.
# Tier B is exempt on purpose - it is STAGED until the adapter bounces, so it is
# expected not to be live yet and saying otherwise would be a false alarm.
Write-Host "`n=== VERIFY (read back from the system, not from this script) ===" -ForegroundColor Green
# Unreadable and not-applied are DIFFERENT answers and are counted separately.
# Saying "this change did not take" when the truth is "this value could not be
# read" is the same class of lie as reporting success without looking - it just
# points the other way, and it would send someone chasing a change that was fine.
$notApplied = New-Object System.Collections.Generic.List[string]
$unreadable = New-Object System.Collections.Generic.List[string]
function Confirm-Applied {
    param([string]$What, [string]$Expected, [string]$Actual)
    if ($null -eq $Actual -or "$Actual" -eq '') {
        Write-Host ("  UNREADABLE  {0} - wanted '{1}', could not read the current value" -f $What, $Expected) -ForegroundColor Yellow
        $script:unreadable.Add($What)
    } elseif ("$Actual".Trim() -ieq "$Expected".Trim()) {
        Write-Host ("  ok          {0} = {1}" -f $What, $Actual) -ForegroundColor Green
    } else {
        Write-Host ("  NOT APPLIED {0} - wanted '{1}', machine has '{2}'" -f $What, $Expected, $Actual) -ForegroundColor Red
        $script:notApplied.Add($What)
    }
}

$after = netsh int tcp show global
function After-Tcp([string]$label) {
    foreach ($line in @($after)) {
        $i = $line.IndexOf(':')
        if ($i -lt 1) { continue }
        if ($line.Substring(0, $i).Trim() -ieq $label) { return $line.Substring($i + 1).Trim() }
    }
    return $null
}
Confirm-Applied 'autotuninglevel' 'normal'  (After-Tcp 'Receive Window Auto-Tuning Level')
Confirm-Applied 'rss'             'enabled' (After-Tcp 'Receive-Side Scaling State')
Confirm-Applied 'rsc'             'enabled' (After-Tcp 'Receive Segment Coalescing State')

$ntiNow = (Get-ItemProperty -LiteralPath $mmKey -Name NetworkThrottlingIndex -ErrorAction SilentlyContinue).NetworkThrottlingIndex
Confirm-Applied 'NetworkThrottlingIndex' '4294967295' ([string][uint32]$ntiNow)

$dnsNow = @((Get-DnsClientServerAddress -InterfaceAlias $AdapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
Confirm-Applied 'DNS' '1.1.1.1, 1.0.0.1' ($dnsNow -join ', ')

$pmNow = (Get-NetAdapterPowerManagement -Name $AdapterName -ErrorAction SilentlyContinue).AllowComputerToTurnOffDevice
Confirm-Applied 'AllowComputerToTurnOffDevice' 'Disabled' ([string]$pmNow)

Write-Host ''
if ($notApplied.Count) {
    Write-Host ("$($notApplied.Count) change(s) did NOT take: " + ($notApplied -join '; ')) -ForegroundColor Red
    Write-Host '  The commands above reported no error, so this is what a silent failure' -ForegroundColor Yellow
    Write-Host '  looks like. Nothing was rolled back; the revert file is still valid.' -ForegroundColor Yellow
}
if ($unreadable.Count) {
    Write-Host ("$($unreadable.Count) value(s) could not be READ back: " + ($unreadable -join '; ')) -ForegroundColor Yellow
    Write-Host '  That is not the same as "did not apply" - it means this check could not' -ForegroundColor Yellow
    Write-Host '  tell either way, and it will not guess.' -ForegroundColor Yellow
}
if (-not $notApplied.Count -and -not $unreadable.Count) {
    Write-Host 'Every Tier A change was read back off the machine and matches.' -ForegroundColor Green
    Write-Host '(Tier B stays staged until the adapter bounces, so it is not checked here.)' -ForegroundColor DarkGray
}
