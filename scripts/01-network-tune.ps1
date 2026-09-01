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

    Tier A changes apply live with no link drop. Tier B are NIC driver
    properties, staged with -NoRestart so they cost nothing until the adapter is
    bounced (-BounceAdapter) or the machine next reboots.

.PARAMETER AdapterName
    Adapter to tune. Defaults to the physical adapter owning the default route.

.PARAMETER BounceAdapter
    Apply the staged NIC properties immediately (~5 s offline).

.PARAMETER SetDns
    Also set DNS to Cloudflare. Off by default: DNS is a personal choice and it
    does not change in-game ping, only name-resolution latency.

.EXAMPLE
    .\01-network-tune.ps1
.EXAMPLE
    .\01-network-tune.ps1 -BounceAdapter -SetDns

.NOTES
    Writes <script>-revert.ps1 capturing the CURRENT values before changing
    anything. Touches no firewall, antivirus, service or policy setting.
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

# Resolve the adapter that actually carries traffic, rather than guessing a name.
if (-not $AdapterName) {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
             Sort-Object RouteMetric | Select-Object -First 1
    if (-not $route) { throw 'No default route found - is this machine online?' }
    $AdapterName = (Get-NetAdapter -InterfaceIndex $route.ifIndex).Name
}
$nic = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
Write-Host "Adapter: $($nic.Name) - $($nic.InterfaceDescription) @ $($nic.LinkSpeed)" -ForegroundColor Cyan

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$revert = Join-Path $here '01-network-tune-revert.ps1'

# ---------------------------------------------------------------- revert file
$g = netsh int tcp show global
function Get-TcpGlobal([string]$label) { (($g | Select-String $label) -replace '.*:\s*', '').Trim() }

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

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Auto-generated revert. Run ELEVATED to restore prior values.')
$lines.Add("# Captured $(Get-Date -Format s) for adapter '$AdapterName'")
$lines.Add("netsh int tcp set global autotuninglevel=$(Get-TcpGlobal 'Receive Window Auto-Tuning Level')")
$lines.Add("netsh int tcp set global rss=$(Get-TcpGlobal 'Receive-Side Scaling State')")
$lines.Add("netsh int tcp set global rsc=$(Get-TcpGlobal 'Receive Segment Coalescing State')")
foreach ($s in $staged) {
    $cur = Get-NetAdapterAdvancedProperty -Name $AdapterName -DisplayName $s.Name -ErrorAction SilentlyContinue
    if ($cur) { $lines.Add("Set-NetAdapterAdvancedProperty -Name '$AdapterName' -DisplayName '$($s.Name)' -DisplayValue '$($cur.DisplayValue)' -NoRestart") }
}
$pm = Get-NetAdapterPowerManagement -Name $AdapterName -ErrorAction SilentlyContinue
if ($pm) { $lines.Add("`$p = Get-NetAdapterPowerManagement -Name '$AdapterName'; `$p.AllowComputerToTurnOffDevice = '$($pm.AllowComputerToTurnOffDevice)'; Set-NetAdapterPowerManagement -InputObject `$p") }
$mmKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$lines.Add("Set-ItemProperty '$mmKey' -Name NetworkThrottlingIndex -Value $((Get-ItemProperty $mmKey).NetworkThrottlingIndex) -Type DWord")
if ($SetDns) {
    $dns = (Get-DnsClientServerAddress -InterfaceAlias $AdapterName -AddressFamily IPv4).ServerAddresses
    $lines.Add("Set-DnsClientServerAddress -InterfaceAlias '$AdapterName' -ServerAddresses $(($dns | ForEach-Object { "'$_'" }) -join ',')")
}
$lines.Add("Restart-NetAdapter -Name '$AdapterName'")
Set-Content -Path $revert -Value $lines -Encoding UTF8
Write-Host "Revert written: $revert" -ForegroundColor Cyan

# ------------------------------------------------- Tier A: live, no link drop
Write-Host "`n--- Tier A (live) ---" -ForegroundColor Yellow
netsh int tcp set global autotuninglevel=normal | Out-Null; Write-Host '  autotuning = normal   <- the throughput fix'
netsh int tcp set global rss=enabled            | Out-Null; Write-Host '  rss = enabled'
netsh int tcp set global rsc=enabled            | Out-Null; Write-Host '  rsc = enabled'

# Default 10 throttles non-multimedia traffic to ~10 packets/ms.
Set-ItemProperty $mmKey -Name NetworkThrottlingIndex -Value 0xFFFFFFFF -Type DWord
Write-Host '  NetworkThrottlingIndex = disabled'

if ($pm) {
    $pm.AllowComputerToTurnOffDevice = 'Disabled'
    Set-NetAdapterPowerManagement -InputObject $pm
    Write-Host '  NIC power-down = Disabled'
}

if ($SetDns) {
    Set-DnsClientServerAddress -InterfaceAlias $AdapterName -ServerAddresses ('1.1.1.1','1.0.0.1')
    Clear-DnsClientCache
    Write-Host '  DNS = 1.1.1.1 / 1.0.0.1'
}

# ------------------------------------------------ Tier B: staged NIC settings
Write-Host "`n--- Tier B (staged) ---" -ForegroundColor Yellow
foreach ($s in $staged) {
    try {
        Set-NetAdapterAdvancedProperty -Name $AdapterName -DisplayName $s.Name -DisplayValue $s.Value -NoRestart -ErrorAction Stop
        Write-Host "  staged $($s.Name) = $($s.Value)"
    } catch {
        Write-Host "  n/a     $($s.Name)" -ForegroundColor DarkGray
    }
}
# Interrupt Moderation is intentionally NOT re-enabled. Disabling it genuinely
# helps latency and is the one tweak these optimizer scripts get right.

if ($BounceAdapter) {
    Write-Host "`nBouncing adapter (~5 s offline)..." -ForegroundColor Yellow
    Restart-NetAdapter -Name $AdapterName
    Start-Sleep -Seconds 8
} else {
    Write-Host "`nTier B pending. Apply with -BounceAdapter, or at next reboot." -ForegroundColor Cyan
}

Write-Host "`n=== AFTER ===" -ForegroundColor Green
netsh int tcp show global
Get-NetAdapter -Name $AdapterName | Format-Table Name, Status, LinkSpeed -AutoSize
