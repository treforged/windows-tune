<#
.SYNOPSIS
    Shared readers and revert-claim parsing for the two revert checks.

.DESCRIPTION
    Dot-sourced by revert-drift.ps1 (does the machine differ from what a revert
    names?) and revert-credibility.ps1 (would it restore what was actually
    there?). One copy, because two copies of a reader is two chances for them to
    disagree about what "the current value" means.

    Nothing here writes anything. Every reader returns $null rather than
    throwing, so an unreadable setting is reported as unreadable instead of
    taking the whole run down.
#>

# ---------------------------------------------------------------- readers ----
# One per setting class. Each is dumb on purpose: read one value, return $null
# if it cannot, never throw, never write.

function Read-TcpGlobal {
    # netsh int tcp show global prints "Label   : value". Return the value for
    # the label given, or $null if this Windows does not print that label -
    # a localized Windows will not, and saying so beats guessing.
    param([string]$Setting)
    try { $out = & netsh int tcp show global 2>$null } catch { return $null }
    foreach ($line in @($out)) {
        $i = $line.IndexOf(':')
        if ($i -lt 1) { continue }
        if ($line.Substring(0, $i).Trim() -ieq $Setting) { return $line.Substring($i + 1).Trim() }
    }
    return $null
}

function Read-NicProperty {
    param([string]$Nic, [string]$DisplayName)
    try {
        $p = Get-NetAdapterAdvancedProperty -Name $Nic -DisplayName $DisplayName -ErrorAction Stop
        return @($p)[0].DisplayValue
    } catch { return $null }
}

function Read-RegValue {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    } catch { return $null }
}

function Read-PowerValue {
    # powercfg /query <scheme> <sub> prints an AC and a DC index in hex for the
    # setting GUID. Read the one asked for and return it as decimal, or $null.
    param([string]$Scheme, [string]$Sub, [string]$Setting, [string]$Rail)
    try { $out = & powercfg /query $Scheme $Sub $Setting 2>$null } catch { return $null }
    if (-not $out) { return $null }
    $want = if ($Rail -eq 'AC') { 'AC' } else { 'DC' }
    foreach ($line in @($out)) {
        if ($line -notmatch "Current $want Power Setting Index:\s*(0x[0-9a-fA-F]+)") { continue }
        try { return [Convert]::ToInt32($Matches[1], 16).ToString() } catch { return $null }
    }
    return $null
}

function Read-DnsServer {
    param([string]$InterfaceAlias)
    try {
        $a = Get-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction Stop
        $s = @(@($a)[0].ServerAddresses)
        if ($s.Count -eq 0) { return $null }
        return ($s -join ', ')
    } catch { return $null }
}

function Read-ServiceStartType {
    param([string]$Name)
    try { return (Get-Service -Name $Name -ErrorAction Stop).StartType.ToString() } catch { return $null }
}

# ------------------------------------------------------------ claim parser ----
# What does a revert file SAY it would put back? Read through the Parser's AST
# rather than by text, so a comment mentioning netsh is not mistaken for a claim.

$TCP_LABEL = @{
    'autotuninglevel' = 'Receive Window Auto-Tuning Level'
    'rss'             = 'Receive-Side Scaling State'
    'rsc'             = 'Receive Segment Coalescing State'
}

function Get-RevertClaim {
    param([string]$Path)
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors.Count) { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $c.GetCommandName()
        if (-not $name) { continue }
        $el = @($c.CommandElements | ForEach-Object { $_.Extent.Text.Trim([char]39, [char]34) })
        switch -Regex ($name) {
            '^netsh$' {
                # netsh int tcp set global <key>=<value>
                foreach ($e in $el) {
                    if ($e -match '^([a-z]+)=(.+)$' -and $TCP_LABEL.ContainsKey($Matches[1])) {
                        $out.Add([pscustomobject]@{ Class = 'tcp'; Target = $TCP_LABEL[$Matches[1]]; Claimed = $Matches[2] })
                    }
                }
            }
            '^powercfg$' {
                for ($i = 0; $i -lt $el.Count; $i++) {
                    if ($el[$i] -notmatch '^/set(ac|dc)valueindex$') { continue }
                    if ($el.Count -lt $i + 5) { continue }
                    $rail = if ($el[$i] -eq '/setacvalueindex') { 'AC' } else { 'DC' }
                    $out.Add([pscustomobject]@{
                        Class   = 'power'
                        Target  = ($el[$i + 1], $el[$i + 2], $el[$i + 3], $rail) -join '|'
                        Claimed = $el[$i + 4]
                    })
                }
            }
            '^Set-NetAdapterAdvancedProperty$' {
                $nic = $null; $dn = $null; $dv = $null
                for ($i = 1; $i -lt $el.Count - 1; $i++) {
                    switch ($el[$i]) {
                        '-Name' { $nic = $el[$i + 1] }
                        '-DisplayName' { $dn = $el[$i + 1] }
                        '-DisplayValue' { $dv = $el[$i + 1] }
                    }
                }
                if ($nic -and $dn) { $out.Add([pscustomobject]@{ Class = 'nic'; Target = "$nic|$dn"; Claimed = $dv }) }
            }
            '^Set-ItemProperty$' {
                $p = $el[1]; $n = $null; $v = $null
                for ($i = 1; $i -lt $el.Count - 1; $i++) {
                    if ($el[$i] -eq '-Name') { $n = $el[$i + 1] }
                    if ($el[$i] -eq '-Value') { $v = $el[$i + 1] }
                }
                if ($p -and $n) { $out.Add([pscustomobject]@{ Class = 'reg'; Target = "$p|$n"; Claimed = $v }) }
            }
            '^Set-DnsClientServerAddress$' {
                $ifa = $null; $srv = $null
                for ($i = 1; $i -lt $el.Count - 1; $i++) {
                    if ($el[$i] -eq '-InterfaceAlias') { $ifa = $el[$i + 1] }
                    if ($el[$i] -eq '-ServerAddresses') { $srv = $el[$i + 1] }
                }
                if ($ifa) { $out.Add([pscustomobject]@{ Class = 'dns'; Target = $ifa; Claimed = $srv }) }
            }
            '^Set-Service$' {
                $svc = $el[1]; $st = $null
                for ($i = 1; $i -lt $el.Count - 1; $i++) { if ($el[$i] -eq '-StartupType') { $st = $el[$i + 1] } }
                if ($svc -and $st) { $out.Add([pscustomobject]@{ Class = 'service'; Target = $svc; Claimed = $st }) }
            }
        }
    }
    , $out.ToArray()
}

function Read-Current {
    param($Claim)
    switch ($Claim.Class) {
        'tcp' { return Read-TcpGlobal $Claim.Target }
        'nic' { $p = $Claim.Target -split '\|', 2; return Read-NicProperty $p[0] $p[1] }
        'reg' { $p = $Claim.Target -split '\|', 2; return Read-RegValue $p[0] $p[1] }
        'power' { $p = $Claim.Target -split '\|'; return Read-PowerValue $p[0] $p[1] $p[2] $p[3] }
        'dns' { return Read-DnsServer $Claim.Target }
        'service' { return Read-ServiceStartType $Claim.Target }
    }
    return $null
}

