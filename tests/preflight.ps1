<#
.SYNOPSIS
    Press the buttons before committing: parse, ASCII, notice gate, installer.

.DESCRIPTION
    Run from any PowerShell (no admin needed). Non-zero exit on any failure.

      1. Every .ps1 parses (PowerShell parser, no execution).
      2. NOTICE.md, install.ps1, windows-tune.ps1, the .cmd are ASCII.
      3. No file in the repo pipes a download into Invoke-Expression, except
         the four docs (NOTICE, README, SECURITY, handoff) that explain why not.
      4. windows-tune.ps1: missing NOTICE.md -> exit 2, nothing run.
      5. windows-tune.ps1: notice declined -> exit 3, nothing run.
      6. windows-tune.ps1 -Choice R -AcceptRisk -NoElevate -> exit 0 and lists
         (or reports no) revert files without touching anything. Then, with
         stand-in scripts that only echo how they were called: -Choice 1
         reaches its script with no arguments, -Choice 3 -Yes reaches its
         script with -BounceAdapter as a switch (the menu's splat).
      7. install.ps1 -FromZip <zip built from this tree> -Path <temp>:
         files land, are unblocked, a pre-existing revert file survives,
         temp files cleaned up.
      8. windows-tune.ps1 -Choice 2 -AcceptRisk -NoElevate runs
         05-defender-handover.ps1 -Diagnose from a normal prompt: exit 0, a
         REAL-TIME PROTECTION line, no admin refusal. Run this gate UNELEVATED
         or stage 8 proves nothing - it says which it was.
      9. Static: every key in a menu row's args hashtable is a declared
         parameter of that row's script (Parser on both files, nothing run).
     10. 01-network-tune.ps1's Get-PendingNetworkChanges is lifted out by the
         Parser and CALLED with synthetic states: an already-tuned machine must
         return nothing, each off-target value must be named, an unsupported
         setting must not count, and 0xFFFFFFFF read back as Int32 -1 must read
         as at-target rather than throwing.
     11. Every script that changes something says "already at target - nothing
         to change" somewhere (01, 02, 04), so no option performs a silent no-op.
     12. 04's Get-StoreFacts is lifted by the Parser and CALLED with synthetic
         DISM text: real output, nothing-to-reclaim, odd spacing, and unreadable
         output which must come back as unknown rather than as success.
     13. LOCALE: 01's Get-TcpGlobal is CALLED with synthetic German netsh output
         and must throw naming the cause; 02's Get-MinState is checked statically
         for the same guard ahead of its ToInt32.
     14. No file hardcodes an absolute machine-specific path (C:\Users\..., a
         C:\tools\... install root). Those break the moment the folder moves and
         resolve somewhere unexpected on a stranger's box. The detector is then
         handed a PLANTED bad path, because a scanner with no planted positive
         reports clean forever.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fails = New-Object System.Collections.Generic.List[string]
function Fail($m) { $script:fails.Add($m); Write-Host "FAIL  $m" -ForegroundColor Red }
function Pass($m) { Write-Host "ok    $m" -ForegroundColor Green }
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# 1. parse
foreach ($f in Get-ChildItem $repo -Recurse -Filter '*.ps1' | Where-Object { $_.Name -notlike '*-revert.ps1' }) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    if ($errors.Count) { Fail "$($f.Name) does not parse: $($errors[0].Message)" } else { Pass "$($f.Name) parses" }
}

# 2. ascii
foreach ($n in 'NOTICE.md', 'install.ps1', 'windows-tune.ps1', 'Run-WindowsTune.cmd') {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $repo $n))
    $bad = @($bytes | Where-Object { $_ -gt 127 }).Count
    if ($bad) { Fail "$n has $bad non-ASCII bytes" } else { Pass "$n is ASCII" }
}

# 3. no pipe-to-iex anywhere but the docs that warn about it. An explicit list, not
#    an extension: a new INSTALL.md or QUICKSTART.md must be scanned by default.
$hits = Get-ChildItem $repo -Recurse -File | Where-Object { $_.FullName -notmatch '\\(\.git|tests)\\' -and $_.Name -notin 'NOTICE.md', 'README.md', 'SECURITY.md', 'handoff.md' } |
    Select-String -Pattern '\|\s*(iex|Invoke-Expression)\b', 'DownloadString' -SimpleMatch:$false
if ($hits) { foreach ($h in $hits) { Fail "pipe-to-iex in $($h.Filename):$($h.LineNumber)" } } else { Pass 'no pipe-to-iex outside the notice' }

# 4-6. the menu's gate, in a scratch copy so NOTICE.md can be removed safely
$scratch = Join-Path $env:TEMP ('wt-preflight-' + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    Copy-Item (Join-Path $repo 'windows-tune.ps1') $scratch
    New-Item -ItemType Directory -Path (Join-Path $scratch 'scripts') | Out-Null
    $menu = Join-Path $scratch 'windows-tune.ps1'

    & $ps -NoProfile -ExecutionPolicy Bypass -File $menu -AcceptRisk -NoElevate -Choice Q *> $null
    if ($LASTEXITCODE -eq 2) { Pass 'missing NOTICE.md -> exit 2' } else { Fail "missing NOTICE.md gave exit $LASTEXITCODE, expected 2" }

    Copy-Item (Join-Path $repo 'NOTICE.md') $scratch
    $out = 'no thanks' | & $ps -NoProfile -ExecutionPolicy Bypass -File $menu -NoElevate -Choice Q
    if ($LASTEXITCODE -eq 3 -and ($out -join "`n") -match 'Nothing was run') { Pass 'declined notice -> exit 3, nothing run' }
    else { Fail "declined notice gave exit $LASTEXITCODE" }

    $out = & $ps -NoProfile -ExecutionPolicy Bypass -File $menu -AcceptRisk -NoElevate -Choice R
    if ($LASTEXITCODE -eq 0 -and ($out -join "`n") -match 'No revert files yet') { Pass 'Choice R with no reverts -> exit 0, honest message' }
    else { Fail "Choice R gave exit $LASTEXITCODE" }

    Set-Content (Join-Path $scratch 'scripts\02-power-tune-revert.ps1') '# fake revert' -Encoding ascii
    $out = & $ps -NoProfile -ExecutionPolicy Bypass -File $menu -AcceptRisk -NoElevate -Choice R
    if ($LASTEXITCODE -eq 0 -and ($out -join "`n") -match '02-power-tune-revert\.ps1') { Pass 'Choice R lists an existing revert file' }
    else { Fail 'Choice R did not list the revert file' }

    # the menu's wiring for both argument shapes, against stand-ins that only echo.
    # Found by stage 8 on 2026-09-01: @($item.args) went in as ONE positional
    # Object[] and every option with an argument failed before its script ran.
    Set-Content (Join-Path $scratch 'scripts\03-storage-report.ps1') '"ARGS=$($args.Count)"' -Encoding ascii
    $out = & $ps -NoProfile -ExecutionPolicy Bypass -File $menu -AcceptRisk -NoElevate -Choice 1
    if ($LASTEXITCODE -eq 0 -and ($out -join "`n") -match 'ARGS=0') { Pass 'Choice 1 reaches its script with no arguments' }
    else { Fail "Choice 1 wiring: exit $LASTEXITCODE`n$($out -join "`n")" }

    Set-Content (Join-Path $scratch 'scripts\01-network-tune.ps1') 'param([switch]$BounceAdapter) "BOUNCE=$BounceAdapter"' -Encoding ascii
    $out = & $ps -NoProfile -ExecutionPolicy Bypass -File $menu -AcceptRisk -NoElevate -Yes -Choice 3
    if ($LASTEXITCODE -eq 0 -and ($out -join "`n") -match 'BOUNCE=True') { Pass 'Choice 3 -Yes reaches its script with -BounceAdapter as a switch' }
    else { Fail "Choice 3 wiring: exit $LASTEXITCODE`n$($out -join "`n")" }
} finally { Remove-Item -Recurse -Force $scratch }

# 7. the installer, offline, from a zip of this tree
$zipDir = Join-Path $env:TEMP ('wt-zip-' + [Guid]::NewGuid())
$target = Join-Path $env:TEMP ('wt-target-' + [Guid]::NewGuid())
try {
    $stage = Join-Path $zipDir 'windows-tune-main'
    New-Item -ItemType Directory -Path $stage | Out-Null
    foreach ($n in 'install.ps1', 'windows-tune.ps1', 'Run-WindowsTune.cmd', 'NOTICE.md', 'README.md', 'LICENSE') { Copy-Item (Join-Path $repo $n) $stage }
    Copy-Item (Join-Path $repo 'scripts') (Join-Path $stage 'scripts') -Recurse -Filter '*.ps1'
    $zip = Join-Path $zipDir 'windows-tune.zip'
    Compress-Archive -Path $stage -DestinationPath $zip

    New-Item -ItemType Directory -Path (Join-Path $target 'scripts') | Out-Null
    Set-Content (Join-Path $target 'scripts\01-network-tune-revert.ps1') '# the user''s own revert' -Encoding ascii

    $out = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install.ps1') -FromZip $zip -Path $target
    if ($LASTEXITCODE -ne 0) { Fail "install.ps1 exit $LASTEXITCODE`n$out" } else { Pass 'install.ps1 -FromZip exit 0' }
    foreach ($n in 'windows-tune.ps1', 'Run-WindowsTune.cmd', 'NOTICE.md', 'scripts\01-network-tune.ps1', 'scripts\06-remove-third-party-av.ps1') {
        if (Test-Path (Join-Path $target $n)) { Pass "installed $n" } else { Fail "missing after install: $n" }
    }
    if ((Get-Content (Join-Path $target 'scripts\01-network-tune-revert.ps1')) -match "user's own") { Pass 'pre-existing revert file untouched' }
    else { Fail 'pre-existing revert file was overwritten' }
    $streams = Get-ChildItem $target -Recurse -File | Get-Item -Stream Zone.Identifier -ErrorAction SilentlyContinue
    if ($streams) { Fail 'files still carry Zone.Identifier' } else { Pass 'files unblocked' }
    $leftover = Get-ChildItem $env:TEMP -Directory -Filter 'windows-tune-*' | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-5) }
    if ($leftover) { Fail "temp folder left behind: $($leftover.Name -join ', ')" } else { Pass 'temp files cleaned up' }
} finally {
    Remove-Item -Recurse -Force $zipDir -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $target -ErrorAction SilentlyContinue
}

# 8. the antivirus status check (menu 2 -> 05 -Diagnose) needs no admin. The menu
#    catches a script's throw and exits 0 anyway, so the OUTPUT is what is checked -
#    against the script's own refusal and the menu's "failed:" line, not the word
#    "elevated", which NOTICE.md (printed first) uses twice.
$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$out = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'windows-tune.ps1') -AcceptRisk -NoElevate -Choice 2
$text = $out -join "`n"
if ($LASTEXITCODE -eq 0 -and $text -match 'REAL-TIME PROTECTION:' -and $text -notmatch 'Run this from an elevated|\.ps1 failed:') {
    if ($elevated) { Pass 'Choice 2 (05 -Diagnose) ran - but this gate is ELEVATED, so the no-admin path is not proven; rerun from a normal prompt' }
    else           { Pass 'Choice 2 (05 -Diagnose) works without admin' }
} else { Fail "Choice 2 (05 -Diagnose) unelevated: exit $LASTEXITCODE`n$text" }

# 9. static: every args key the menu passes exists in the target script's param()
#    block. Parser only - nothing is dot-sourced or run. A typo like `Diagnos = $true`
#    would pass every other stage and fail only when a user presses the option.
#    $assign.Right is a CommandExpressionAst wrapping [ordered]@{...}; the table is
#    the HashtableAst inside it, each row is another HashtableAst one level down.
$errors = $null
$menuAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'windows-tune.ps1'), [ref]$null, [ref]$errors)
$assign = $menuAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -eq 'menu' }, $true) | Select-Object -First 1
$table = if ($assign) { $assign.Right.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) } else { $null }
$rows = if ($table) { @($table.KeyValuePairs) } else { @() }
$named = 0
foreach ($pair in $rows) {
    $key = $pair.Item1.Value
    $row = $pair.Item2.PipelineElements[0].Expression
    $name = $row.KeyValuePairs | Where-Object { $_.Item1.Value -eq 'name' } | Select-Object -First 1 | ForEach-Object { $_.Item2.PipelineElements[0].Expression.Value }
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $named++
    $argsAst = $row.KeyValuePairs | Where-Object { $_.Item1.Value -eq 'args' } | Select-Object -First 1 | ForEach-Object { $_.Item2.PipelineElements[0].Expression }
    $scriptPath = Join-Path $repo "scripts\$name"
    if (-not (Test-Path $scriptPath)) { Fail "menu ${key}: scripts\$name does not exist"; continue }
    $errors = $null
    $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errors)
    if ($errors.Count) { Fail "menu ${key}: scripts\$name does not parse: $($errors[0].Message)"; continue }
    $declared = @($scriptAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    if (-not $argsAst -or $argsAst.KeyValuePairs.Count -eq 0) {
        Pass "menu ${key}: $name takes no arguments"
    } else {
        foreach ($argPair in $argsAst.KeyValuePairs) {
            $argName = $argPair.Item1.Value
            if ($declared -contains $argName) { Pass "menu ${key}: -$argName is a parameter of $name" }
            else { Fail "menu ${key}: -$argName is not a parameter of $name (declared: $($declared -join ', '))" }
        }
    }
}
if ($named -eq 0) { Fail 'menu table not found in windows-tune.ps1 - stage 9 checked nothing' }

# 10. the idempotency check in 01, actually CALLED. The script throws on the admin
#     test at line 1, so it cannot be dot-sourced from a normal prompt; the Parser
#     lifts just the pure function out and this stage invokes it. Synthetic states
#     only - nothing on this machine is read or written.
$netPath = Join-Path $repo 'scripts\01-network-tune.ps1'
$errors = $null
$netAst = [System.Management.Automation.Language.Parser]::ParseFile($netPath, [ref]$null, [ref]$errors)
$fnAst = $netAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-PendingNetworkChanges' }, $true) | Select-Object -First 1
if (-not $fnAst) {
    Fail 'Get-PendingNetworkChanges not found in 01-network-tune.ps1 - stage 10 checked nothing'
} else {
    . ([scriptblock]::Create($fnAst.Extent.Text))
    $stagedProbe = @(
        @{ Name = 'Green Ethernet'; Value = 'Disabled' }
        @{ Name = 'Flow Control';   Value = 'Disabled' }
        @{ Name = 'Gigabit Lite';   Value = 'Disabled' }   # deliberately absent from the snapshots below
    )
    function New-TunedState {
        @{
            AutoTuning      = 'normal'
            Rss             = 'enabled'
            Rsc             = 'enabled'
            ThrottlingIndex = -1          # what Get-ItemProperty returns for a 0xFFFFFFFF DWORD
            NicPowerDown    = 'Disabled'
            Advanced        = @{ 'Green Ethernet' = 'Disabled'; 'Flow Control' = 'Disabled' }
        }
    }

    $r = @(Get-PendingNetworkChanges -Current (New-TunedState) -Staged $stagedProbe)
    if ($r.Count -eq 0) { Pass 'already-tuned machine -> 0 pending changes (Int32 -1 reads as 0xFFFFFFFF, not a throw)' }
    else { Fail "already-tuned machine reported $($r.Count) pending: $(($r | ForEach-Object { $_.Item }) -join ', ')" }

    # An unsupported property is absent from the snapshot and must not be invented.
    if (($r | Where-Object { $_.Item -eq 'Gigabit Lite' }).Count -eq 0) { Pass 'a NIC property the adapter lacks is not counted as a change' }
    else { Fail 'an unsupported NIC property was reported as a pending change' }

    # Each off-target value must be named, one at a time, so a stage that finds
    # nothing cannot pass green by accident.
    $cases = @(
        @{ Key = 'AutoTuning';      Bad = 'disabled';  Item = 'TCP autotuning' }
        @{ Key = 'Rss';             Bad = 'disabled';  Item = 'RSS' }
        @{ Key = 'Rsc';             Bad = 'disabled';  Item = 'RSC' }
        @{ Key = 'ThrottlingIndex'; Bad = 10;          Item = 'NetworkThrottlingIndex' }
        @{ Key = 'NicPowerDown';    Bad = 'Enabled';   Item = 'NIC power-down' }
    )
    foreach ($c in $cases) {
        $state = New-TunedState
        $state[$c.Key] = $c.Bad
        $r = @(Get-PendingNetworkChanges -Current $state -Staged $stagedProbe)
        if ($r.Count -eq 1 -and $r[0].Item -eq $c.Item) { Pass "$($c.Item) off target -> reported, and nothing else is" }
        else { Fail "$($c.Item) off target gave $($r.Count) result(s): $(($r | ForEach-Object { $_.Item }) -join ', ')" }
    }

    $state = New-TunedState
    $state.Advanced['Flow Control'] = 'Rx & Tx Enabled'
    $r = @(Get-PendingNetworkChanges -Current $state -Staged $stagedProbe)
    if ($r.Count -eq 1 -and $r[0].Item -eq 'Flow Control') { Pass 'an off-target NIC property is reported' }
    else { Fail "off-target NIC property gave $($r.Count) result(s)" }

    # A missing reading is a difference, never a match.
    $state = New-TunedState
    $state.AutoTuning = $null
    $state.ThrottlingIndex = $null
    $r = @(Get-PendingNetworkChanges -Current $state -Staged $stagedProbe)
    if ($r.Count -eq 2) { Pass 'unreadable values count as differences, not as "already correct"' }
    else { Fail "unreadable values gave $($r.Count) result(s), expected 2" }
}

# 11. every script that changes something reports the no-op case. A user who picks
#     an option must be able to tell "applied" from "was already correct".
$idempotent = 0
foreach ($n in '01-network-tune.ps1', '02-power-tune.ps1', '04-component-cleanup.ps1') {
    $body = Get-Content -Raw (Join-Path $repo "scripts\$n")
    if ($body -match 'already at target - nothing to change') { $idempotent++; Pass "$n reports the already-at-target case" }
    else { Fail "$n can perform a silent no-op - no 'already at target' message" }
}
if ($idempotent -eq 0) { Fail 'stage 11 checked no scripts' }

# 12. 04's Get-StoreFacts, actually CALLED. 04 throws on the admin test, so the
#     Parser lifts the pure function out and this stage invokes it with synthetic
#     DISM text - no DISM run, nothing on this machine touched. The point is the
#     UNKNOWN case: unparseable output must come back $null so the script can say
#     'unknown' rather than treat a failed read as success.
$cleanPath = Join-Path (Join-Path $repo 'scripts') '04-component-cleanup.ps1'
$errors = $null
$cleanAst = [System.Management.Automation.Language.Parser]::ParseFile($cleanPath, [ref]$null, [ref]$errors)
$factsFn = $cleanAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-StoreFacts' }, $true)
if (-not $factsFn) {
    Fail '04-component-cleanup.ps1 has no Get-StoreFacts - stage 12 checked nothing'
} else {
    . ([scriptblock]::Create($factsFn.Extent.Text))
    $cases = @(
        @{ n = 'real DISM output';   in = @('Actual Size of Component Store : 14.88 GB', 'Number of Reclaimable Packages : 2', 'Component Store Cleanup Recommended : Yes', 'The operation completed successfully.'); pk = 2;     rec = 'Yes' }
        @{ n = 'nothing to reclaim'; in = @('Number of Reclaimable Packages : 0', 'Component Store Cleanup Recommended : No');  pk = 0;     rec = 'No' }
        @{ n = 'wide spacing';       in = @('Number of Reclaimable Packages :    17', 'Component Store Cleanup Recommended :   Yes'); pk = 17; rec = 'Yes' }
        @{ n = 'unreadable output';  in = @('Error: 87', 'The operation failed.');     pk = $null; rec = $null }
    )
    foreach ($c in $cases) {
        $got = Get-StoreFacts $c.in
        if ($got.Packages -eq $c.pk -and $got.Recommended -eq $c.rec) {
            Pass "Get-StoreFacts reads $($c.n) as packages=$(if ($null -eq $c.pk) { 'unknown' } else { $c.pk })"
        } else {
            Fail "Get-StoreFacts on $($c.n): got packages=$($got.Packages) recommended=$($got.Recommended), expected $($c.pk)/$($c.rec)"
        }
    }
}

# 13. LOCALE. Every parser here reads the ENGLISH labels of netsh/powercfg/DISM
#     output, which Windows localizes. This is the class of bug a second machine
#     would find, tested without one: 01's Get-TcpGlobal is lifted and CALLED
#     with synthetic German netsh output, and 02's Get-MinState is checked
#     STATICALLY for its guard (it shells out to powercfg, so calling it here
#     would only re-test this English machine - said plainly rather than faked).
$netPath13 = Join-Path (Join-Path $repo 'scripts') '01-network-tune.ps1'
$errors = $null
$netAst13 = [System.Management.Automation.Language.Parser]::ParseFile($netPath13, [ref]$null, [ref]$errors)
$tcpFn = $netAst13.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-TcpGlobal' }, $true)
if (-not $tcpFn) {
    Fail '01-network-tune.ps1 has no Get-TcpGlobal - stage 13 checked nothing'
} else {
    . ([scriptblock]::Create($tcpFn.Extent.Text))
    $g = @('Receive Window Auto-Tuning Level    : normal', 'Receive-Side Scaling State          : enabled')
    try {
        $v = Get-TcpGlobal 'Receive Window Auto-Tuning Level'
        if ($v -eq 'normal') { Pass 'Get-TcpGlobal reads an English netsh label' }
        else { Fail "Get-TcpGlobal on English netsh returned [$v], expected [normal]" }
    } catch { Fail "Get-TcpGlobal threw on valid English input: $($_.Exception.Message)" }

    $g = @('Empf. Fenster Auto-Tuningstufe      : normal', 'Skalierungsstatus empfangsseitig    : aktiviert')
    try {
        $v = Get-TcpGlobal 'Receive Window Auto-Tuning Level'
        Fail "Get-TcpGlobal on LOCALIZED netsh returned [$v] instead of throwing - a revert file would be written with no value"
    } catch {
        if ($_.Exception.Message -match 'English-language Windows') { Pass 'Get-TcpGlobal on localized netsh throws and names the cause' }
        else { Fail "Get-TcpGlobal threw on localized netsh but the message names no cause: $($_.Exception.Message)" }
    }
}

$pwrPath13 = Join-Path (Join-Path $repo 'scripts') '02-power-tune.ps1'
$errors = $null
$pwrAst13 = [System.Management.Automation.Language.Parser]::ParseFile($pwrPath13, [ref]$null, [ref]$errors)
$minFn = $pwrAst13.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-MinState' }, $true)
if (-not $minFn) {
    Fail '02-power-tune.ps1 has no Get-MinState - stage 13 checked nothing'
} else {
    $body = $minFn.Extent.Text
    $throws = $body -match 'English-language Windows'
    $guardFirst = ($body.IndexOf('throw') -ge 0) -and ($body.IndexOf('throw') -lt $body.IndexOf('ToInt32'))
    if ($throws -and $guardFirst) { Pass 'Get-MinState guards a localized powercfg before ToInt32, naming the cause' }
    else { Fail "Get-MinState has no locale guard ahead of ToInt32 (throws=$throws, guardFirst=$guardFirst) - a non-English Windows gets 'Index was out of range'" }
}

# 14. no hardcoded absolute machine path. Every path must be derived at runtime
#     ($PSScriptRoot, $env:...), so a moved folder cannot leave a script pointing
#     at somewhere that no longer exists - or, worse, at somewhere that does.
function Get-HardcodedPathHit {
    param([string]$Text)
    if (-not $Text) { return @() }
    # A drive letter, then \Users\ or \tools\. C:\Windows and C:\Program Files are
    # genuine fixed system locations and are not machine-specific.
    @([regex]::Matches($Text, '(?i)\b[a-z]:\\(users|tools)\\[^\s''"<>|)\]]*') | ForEach-Object { $_.Value })
}

$pathHits = 0
$scanned14 = 0
foreach ($f in Get-ChildItem $repo -Recurse -File -Include '*.ps1', '*.cmd' |
         Where-Object { $_.FullName -notmatch '\\(\.git|tests)\\' -and $_.Name -notlike '*-revert.ps1' }) {
    $scanned14++
    $n = 0
    foreach ($line in (Get-Content $f.FullName)) {
        $n++
        foreach ($hit in (Get-HardcodedPathHit $line)) {
            $pathHits++
            Fail "hardcoded absolute path in $($f.Name):$n -> $hit"
        }
    }
}
if ($scanned14 -eq 0) { Fail 'stage 14 scanned no files - the check proved nothing' }
elseif ($pathHits -eq 0) { Pass "no hardcoded absolute machine paths ($scanned14 files scanned)" }

# and prove the detector actually detects, or the clean result above means nothing
$planted = 'C:' + '\Users\someone\Desktop\thing.ps1'
if (@(Get-HardcodedPathHit $planted).Count) { Pass 'hardcoded-path detector catches a planted path' }
else { Fail 'hardcoded-path detector matched nothing on a planted bad path - stage 14 proved nothing' }

if ($fails.Count) { Write-Host "`n$($fails.Count) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "`nall green" -ForegroundColor Green
exit 0
