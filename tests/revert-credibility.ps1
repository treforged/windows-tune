<#
.SYNOPSIS
    Would each revert restore what was actually there, or just something else?

.DESCRIPTION
    revert-drift.ps1 answers "does the machine hold a different value than this
    revert names". That is necessary and not sufficient: a revert full of wrong
    values also differs from the machine, and looks identical.

    This closes it by bringing in a third reading - what the TUNE itself sets:

        revert says X, the tune sets Y, the machine holds Y   -> CREDIBLE
        revert says X, the tune sets Y, the machine holds X   -> NOT APPLIED
        revert says X, the tune sets X                        -> NO-OP revert
        the machine holds neither X nor Y                     -> DRIFT
        the tune's target cannot be read statically           -> UNKNOWN

    NOTHING IS APPLIED AND NOTHING IS WRITTEN. A revert is never run: proving a
    revert works by running it is how you find out it does not.

    It does not decide who is right when a value drifts, either. A machine
    holding neither value means something moved it, and only a human knows
    whether that was legitimate. DRIFT and NOT APPLIED are reported and exit 0.

    Two things are unambiguous and exit 1:
      - a NO-OP revert, which would restore the tuned value and undo nothing
      - reading no targets at all, which means this script proved nothing

    UNKNOWN is honest rather than a failure. Some targets are computed at
    runtime - 02-power-tune reads the ACTIVE power scheme GUID, and
    01-network-tune takes its adapter as a parameter - so they are matched on
    the parts that ARE static and the rest is said out loud.
#>
[CmdletBinding()]
param(
    # Where the tune scripts and their *-revert.ps1 files live. Defaults to the
    # repo's scripts\ folder; preflight.ps1 points it at a fixture folder so
    # these checks can be pressed until they go RED.
    [string]$ScriptsDir
)

# Resolve this script's own folder BEFORE anything is derived from it.
# Split-Path THROWS on an empty string, so this is checked before it is called.
$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { throw 'Cannot resolve this script''s own folder. Run it as a file (.\tests\revert-credibility.ps1), not by pasting its body into a console.' }
if (-not $ScriptsDir) { $ScriptsDir = Join-Path (Split-Path -Parent $here) 'scripts' }
if (-not (Test-Path -LiteralPath $ScriptsDir -PathType Container)) {
    Write-Host "no such folder [$ScriptsDir] - this script proved nothing" -ForegroundColor Red
    exit 1
}

. (Join-Path $here 'revert-lib.ps1')

# ------------------------------------------------------- the tune's targets ----
# What does the SOURCE script set? Read through the AST, so the strings a script
# BUILDS for its revert file are not mistaken for commands it runs. That
# distinction is the whole reason this is parsed rather than grepped:
# 01-network-tune.ps1 contains the text "netsh int tcp set global
# autotuninglevel=" twice - once as a command it runs, once inside a string it
# writes to its revert file.

function Get-TuneTarget {
    param([string]$Path)
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors.Count) { return @{} }

    # simple top-level string assignments, so $mmKey and $nic can be resolved
    $var = @{}
    foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        $lhs = $a.Left.Extent.Text
        if ($lhs -notmatch '^\$[A-Za-z_]\w*$') { continue }
        $rhs = $a.Right.Extent.Text.Trim()
        if ($rhs -match "^'([^']*)'$" -or $rhs -match '^"([^"$`]*)"$') { $var[$lhs] = $Matches[1] }
    }
    function Resolve-Text {
        param([string]$Text, [hashtable]$Var)
        $t = $Text.Trim([char]39, [char]34)
        if ($Var.ContainsKey($t)) { return $Var[$t] }
        return $t
    }

    $target = @{}
    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $c.GetCommandName()
        if (-not $name) { continue }
        $el = @($c.CommandElements | ForEach-Object { Resolve-Text $_.Extent.Text $var })
        switch -Regex ($name) {
            '^netsh$' {
                foreach ($e in $el) {
                    if ($e -match '^([a-z]+)=(.+)$' -and $TCP_LABEL.ContainsKey($Matches[1])) {
                        $target["tcp|$($TCP_LABEL[$Matches[1]])"] = $Matches[2]
                    }
                }
            }
            '^powercfg$' {
                for ($i = 0; $i -lt $el.Count; $i++) {
                    if ($el[$i] -notmatch '^/set(ac|dc)valueindex$') { continue }
                    if ($el.Count -lt $i + 5) { continue }
                    # the scheme GUID is read from the live machine at run time, so
                    # only the sub-group, the setting and the rail are static here.
                    $rail = if ($el[$i] -eq '/setacvalueindex') { 'AC' } else { 'DC' }
                    $target["power|$($el[$i + 2])|$($el[$i + 3])|$rail"] = $el[$i + 4]
                }
            }
            '^Set-ItemProperty$' {
                $p = $el[1]; $n = $null; $v = $null
                for ($i = 1; $i -lt $el.Count - 1; $i++) {
                    if ($el[$i] -eq '-Name') { $n = $el[$i + 1] }
                    if ($el[$i] -eq '-Value') { $v = $el[$i + 1] }
                }
                if ($p -and $n -and $null -ne $v) {
                    # a tune may write hex where its revert writes decimal
                    if ($v -match '^0x[0-9a-fA-F]+$') {
                        try { $v = [Convert]::ToUInt32($v, 16).ToString() } catch { }
                    }
                    $target["reg|$p|$n"] = $v
                }
            }
            '^Set-Service$' {
                $svc = $el[1]; $st = $null
                for ($i = 1; $i -lt $el.Count - 1; $i++) { if ($el[$i] -eq '-StartupType') { $st = $el[$i + 1] } }
                if ($svc -and $st) { $target["service|$svc"] = $st }
            }
            '^Set-DnsClientServerAddress$' {
                $ifa = $null; $srv = $null
                for ($i = 1; $i -lt $el.Count - 1; $i++) {
                    if ($el[$i] -eq '-InterfaceAlias') { $ifa = $el[$i + 1] }
                    if ($el[$i] -eq '-ServerAddresses') { $srv = $el[$i + 1] }
                }
                if ($ifa -and $srv) {
                    $list = @([regex]::Matches($srv, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
                    if ($list.Count -eq 0) { $list = @($srv.Trim('(', ')')) }
                    $target["dns|$ifa"] = ($list -join ', ')
                }
            }
        }
    }

    # NIC advanced properties are applied from a table, not one command each:
    #     $staged = @( @{ Name = 'Green Ethernet'; Value = 'Disabled' } ... )
    #     foreach ($s in $staged) { Set-NetAdapterAdvancedProperty ... $s.Name ... $s.Value }
    # so the targets live in the hashtable literals. Only read them when the file
    # really does invoke Set-NetAdapterAdvancedProperty, or an unrelated table
    # with the same keys would be mistaken for NIC settings.
    #
    # The ADAPTER NAME is deliberately not part of the key. 01-network-tune.ps1
    # takes it as a parameter and resolves it against the live machine, so it
    # cannot be read statically - exactly like the power scheme GUID above. Key
    # on the property's DisplayName, which IS static, and let Get-ClaimKey drop
    # the adapter from the other side so the two still join.
    $usesNic = @($ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Set-NetAdapterAdvancedProperty' }, $true)).Count -gt 0
    if ($usesNic) {
        foreach ($h in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)) {
            $pair = @{}
            foreach ($kv in $h.KeyValuePairs) {
                $pair[$kv.Item1.Extent.Text.Trim([char]39, [char]34)] = $kv.Item2.Extent.Text.Trim([char]39, [char]34)
            }
            # 'Name'/'Value' is this repo's shape; 'n'/'v' is the older one.
            $pn = if ($pair.ContainsKey('Name')) { $pair['Name'] } elseif ($pair.ContainsKey('n')) { $pair['n'] } else { $null }
            $pv = if ($pair.ContainsKey('Value')) { $pair['Value'] } elseif ($pair.ContainsKey('v')) { $pair['v'] } else { $null }
            if ($pn -and $pv) { $target["nic|$pn"] = $pv }
        }
    }
    return $target
}

# The claim key must be the same shape on both sides, or nothing ever joins.
function Get-ClaimKey {
    param($Claim)
    if ($Claim.Class -eq 'power') {
        # drop the runtime-resolved scheme GUID; keep sub|setting|rail
        $p = $Claim.Target -split '\|'
        if ($p.Count -ge 4) { return "power|$($p[1])|$($p[2])|$($p[3])" }
    }
    if ($Claim.Class -eq 'nic') {
        # drop the adapter name, which the tune resolves at runtime; keep the
        # property DisplayName, which is the only half either side can be sure of
        $p = $Claim.Target -split '\|', 2
        if ($p.Count -eq 2) { return "nic|$($p[1])" }
    }
    return "$($Claim.Class)|$($Claim.Target)"
}

# ------------------------------------------------------------------ report ----
$credible = 0; $notApplied = 0; $noop = 0; $drift = 0; $unknown = 0; $missing = 0; $claims = 0; $targets = 0

foreach ($r in (Get-ChildItem $ScriptsDir -File -Filter '*-revert.ps1' | Sort-Object Name)) {
    $sourceName = $r.Name -replace '-revert\.ps1$', '.ps1'
    $sourcePath = Join-Path $ScriptsDir $sourceName
    Write-Host ''
    Write-Host "=== $($r.Name)  (tune: $sourceName)" -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        Write-Host "  the tune script is gone - nothing to compare against" -ForegroundColor Red
        continue
    }
    $tune = Get-TuneTarget $sourcePath
    $targets += $tune.Count
    Write-Host "  $($tune.Count) target(s) read from $sourceName"

    foreach ($c in (Get-RevertClaim $r.FullName)) {
        $claims++
        $key = Get-ClaimKey $c
        $now = Read-Current $c
        $want = if ($tune.ContainsKey($key)) { $tune[$key] } else { $null }
        $said = "$($c.Claimed)".Trim()
        $has = "$now".Trim()

        if ($null -eq $now -or $has -eq '') {
            # No current value to compare against - the setting is gone, not drifted.
            # revert-drift.ps1 is the one that FAILS on this; naming it here too
            # keeps the two reports telling the same story about the same claim.
            $missing++
            Write-Host ("  MISSING     {0} - the tune sets '{1}' and the revert says '{2}', but this setting does not exist on the machine at all" -f $c.Target, $want, $said) -ForegroundColor Red
        } elseif ($null -eq $want) {
            $unknown++
            Write-Host ("  UNKNOWN     {0} - the tune sets no static target for this, so credibility cannot be judged here" -f $c.Target) -ForegroundColor DarkGray
        } elseif ($said -ieq "$want".Trim()) {
            $noop++
            Write-Host ("  NO-OP       {0} - the revert would restore '{1}', which is what the tune SETS. This revert undoes nothing." -f $c.Target, $said) -ForegroundColor Red
        } elseif ($has -ieq "$want".Trim()) {
            $credible++
            Write-Host ("  credible    {0} - tune set '{1}', machine holds it, revert would put back '{2}'" -f $c.Target, $want, $said) -ForegroundColor Green
        } elseif ($has -ieq $said) {
            $notApplied++
            Write-Host ("  NOT APPLIED {0} - machine holds the revert's value '{1}', so this tune is not in effect here" -f $c.Target, $said) -ForegroundColor Yellow
        } else {
            $drift++
            Write-Host ("  DRIFT       {0} - tune sets '{1}', revert says '{2}', machine has '{3}' - something else moved it" -f $c.Target, $want, $said, $has) -ForegroundColor Magenta
        }
    }
}

Write-Host ''
Write-Host ('{0} claim(s) against {1} tune target(s): {2} credible, {3} not applied, {4} drift, {5} unknown, {6} missing, {7} NO-OP' -f `
        $claims, $targets, $credible, $notApplied, $drift, $unknown, $missing, $noop)
if ($missing) { Write-Host "$missing claim(s) name a setting that no longer exists - revert-drift.ps1 is the check that fails on those" -ForegroundColor Red }
Write-Host 'Nothing was applied and nothing was written. DRIFT and NOT APPLIED are reported,'
Write-Host 'not judged - only a human knows whether a value moved for a good reason.'

if ($targets -eq 0) {
    Write-Host 'no tune targets read at all - this script proved nothing' -ForegroundColor Red
    exit 1
}
if ($noop) {
    Write-Host ''
    Write-Host "$noop claim(s) would restore the value the tune SETS - a revert that undoes nothing is worse than no revert, because it looks like one" -ForegroundColor Red
    exit 1
}
exit 0
