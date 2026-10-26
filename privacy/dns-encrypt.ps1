# dns-encrypt.ps1 - send this PC's DNS lookups to Cloudflare over HTTPS (DoH)
# instead of plain port 53, so the ISP cannot read or log which sites are looked up.
# Run ELEVATED. Takes no arguments. Writes dns-encrypt-revert.ps1 and
# dns-encrypt.log beside itself.
#
# Windows ships 1.1.1.1 / 1.0.0.1 in its DoH table with AutoUpgrade = False.
# Use this script when your adapter already uses those two resolvers.
# This script flips AutoUpgrade to True and leaves the resolver itself unchanged.
# It does NOT add ad/tracker blocking - a blocking resolver can break sites, and
# that is a separate decision.
#
# SAFETY: after the change it resolves three names. If ANY fails, it runs the
# captured revert at once and exits 1, so a broken DoH path cannot leave the
# machine without DNS.

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { throw 'Cannot resolve this script''s own folder. Run it as a file (.\dns-encrypt.ps1), not by pasting its body into a console.' }
$log    = Join-Path $here 'dns-encrypt.log'
$revert = Join-Path $here 'dns-encrypt-revert.ps1'
Start-Transcript -Path $log -Append | Out-Null

$SERVERS = @('1.1.1.1', '1.0.0.1')
$NAMES   = @('example.com', 'wikipedia.org', 'github.com')

function Test-Resolve {
    $ok = 0
    foreach ($n in $NAMES) { try { Resolve-DnsName $n -Type A -ErrorAction Stop | Out-Null; $ok++ } catch { Write-Host "  resolve FAILED: $n" } }
    return $ok
}

function Measure-Port53 {
    # Count plain-DNS packets while resolving fresh names. pktmon ships with
    # Windows 10/11 and needs admin. Returns -1 when it cannot measure, never 0.
    $etl = Join-Path $env:TEMP 'wt-dns53.etl'
    try {
        pktmon filter remove | Out-Null
        pktmon filter add WtDns53 -p 53 | Out-Null
        pktmon start --capture --file-name $etl | Out-Null
        Clear-DnsClientCache
        foreach ($n in $NAMES) { Resolve-DnsName $n -Type A -EA SilentlyContinue | Out-Null }
        Start-Sleep -Seconds 2
        pktmon stop | Out-Null
        $txt = Join-Path $env:TEMP 'wt-dns53.txt'
        pktmon etl2txt $etl --out $txt | Out-Null
        $hits = @(Select-String -Path $txt -Pattern '\.53[: ]' -EA SilentlyContinue).Count
        return $hits
    } catch { return -1 }
    finally { pktmon filter remove | Out-Null }
}

# capture
$before = @{}
foreach ($s in $SERVERS) {
    $d = Get-DnsClientDohServerAddress -ServerAddress $s
    $before[$s] = $d
    Write-Host "before $s AutoUpgrade=$($d.AutoUpgrade) AllowFallbackToUdp=$($d.AllowFallbackToUdp)"
}
$lines = @(
    '# Auto-generated revert for dns-encrypt.ps1. Run ELEVATED to restore.'
    "# Captured $(Get-Date -Format s)"
)
foreach ($s in $SERVERS) {
    $lines += "Set-DnsClientDohServerAddress -ServerAddress $s -AutoUpgrade `$$($before[$s].AutoUpgrade.ToString().ToLower()) -AllowFallbackToUdp `$$($before[$s].AllowFallbackToUdp.ToString().ToLower())"
}
$lines += "Write-Host 'DNS for 1.1.1.1 / 1.0.0.1 is back to its captured DoH setting.'"
$lines | Set-Content -Path $revert -Encoding ASCII

$plainBefore = Measure-Port53
Write-Host "port-53 packets while resolving $($NAMES.Count) names, BEFORE: $plainBefore"

# apply
foreach ($s in $SERVERS) {
    Set-DnsClientDohServerAddress -ServerAddress $s -AutoUpgrade $true -AllowFallbackToUdp $before[$s].AllowFallbackToUdp | Out-Null
}
Clear-DnsClientCache
Start-Sleep -Seconds 2

$ok = Test-Resolve
if ($ok -ne $NAMES.Count) {
    Write-Host "ROLLED BACK: only $ok of $($NAMES.Count) names resolved over DoH." -ForegroundColor Red
    # Roll back from the captured lines in memory, never by running the file back off disk: between
    # the write and this line another program could have changed it, and this session is elevated.
    & ([scriptblock]::Create($lines -join "`n"))
    Clear-DnsClientCache
    Stop-Transcript | Out-Null
    exit 1
}
$plainAfter = Measure-Port53
foreach ($s in $SERVERS) { $d = Get-DnsClientDohServerAddress -ServerAddress $s; Write-Host "after  $s AutoUpgrade=$($d.AutoUpgrade) AllowFallbackToUdp=$($d.AllowFallbackToUdp)" }
Write-Host "resolved $ok of $($NAMES.Count) names after the change"
Write-Host "port-53 packets while resolving $($NAMES.Count) names, AFTER:  $plainAfter"
if ($plainAfter -gt 0) { Write-Host 'NOTE: plain DNS still seen. Windows may need the per-adapter DNS encryption setting as well.' -ForegroundColor Yellow }
Write-Host 'UNDO: run .\dns-encrypt-revert.ps1 elevated.' -ForegroundColor Green
Stop-Transcript | Out-Null
