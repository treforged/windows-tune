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
     16. sandbox-run.ps1's New-SandboxConfig is lifted and CALLED: the repo must
         be mapped READ-ONLY and only the out folder writable, and networking
         must be off. A writable host mapping is the one way a disposable VM can
         reach back into the real machine, so it is asserted rather than trusted.
     15. 04's Get-StoreHealth is lifted by the Parser and CALLED with synthetic
         DISM text: healthy, repairable, the exact "has been corrupted" wording
         this machine produced on 2026-09-03, and unreadable output which must
         come back as Unknown rather than as healthy. Then 04 is checked
         statically for the STOP that must sit between that verdict and the
         cleanup.
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

# 7b. the download path is pinned: a release tag and a 64-hex SHA256
$inst = Get-Content (Join-Path $repo 'install.ps1') -Raw
if ($inst -match "(?m)^\`$ReleaseTag\s*=\s*'v\d+\.\d+\.\d+'") { Pass 'install.ps1 pins a release tag' } else { Fail 'install.ps1 carries no release tag pin' }
if ($inst -match "(?m)^\`$ReleaseSha256\s*=\s*'[0-9a-fA-F]{64}'") { Pass 'install.ps1 pins a release SHA256' } else { Fail 'install.ps1 carries no release SHA256 pin' }
if ($inst -match 'archive/refs/heads') { Fail 'install.ps1 still downloads a moving branch zip' } else { Pass 'install.ps1 downloads no branch zip' }

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

    # 7a. a wrong hash must REFUSE, and must leave nothing unpacked behind
    $badTarget = Join-Path $env:TEMP ('wt-bad-' + [Guid]::NewGuid())
    $out = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install.ps1') -FromZip $zip -Path $badTarget -Sha256 ('0' * 64)
    if ($LASTEXITCODE -eq 1 -and ($out -join ' ') -match 'SHA256 mismatch') { Pass 'install.ps1 refuses a zip whose SHA256 differs' }
    else { Fail "wrong-hash install was not refused: exit $LASTEXITCODE`n$out" }
    if (Test-Path (Join-Path $badTarget 'windows-tune.ps1')) { Fail 'wrong-hash install still unpacked files' } else { Pass 'wrong-hash install unpacked nothing' }
    Remove-Item -Recurse -Force $badTarget -ErrorAction SilentlyContinue

    # 7b. NO hash given: a zip that is not the pinned release must REFUSE too, never unpack unchecked
    $noHashTarget = Join-Path $env:TEMP ('wt-nohash-' + [Guid]::NewGuid())
    $out = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install.ps1') -FromZip $zip -Path $noHashTarget
    if ($LASTEXITCODE -eq 1 -and ($out -join ' ') -match 'SHA256 mismatch') { Pass 'install.ps1 -FromZip with no -Sha256 refuses a zip that is not the pinned release' }
    else { Fail "no-hash install of a non-release zip was not refused: exit $LASTEXITCODE`n$out" }
    if (Test-Path (Join-Path $noHashTarget 'windows-tune.ps1')) { Fail 'no-hash install still unpacked files' } else { Pass 'no-hash install unpacked nothing' }
    Remove-Item -Recurse -Force $noHashTarget -ErrorAction SilentlyContinue

    $goodHash = (Get-FileHash -Algorithm SHA256 $zip).Hash
    $out = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install.ps1') -FromZip $zip -Path $target -Sha256 $goodHash
    if ($LASTEXITCODE -ne 0) { Fail "install.ps1 exit $LASTEXITCODE`n$out" } else { Pass 'install.ps1 -FromZip with the right SHA256 exit 0' }
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

# 15. the component-store HEALTH verdict, and the stop that must follow it.
#     A cleanup on a damaged store reclaims nothing and still prints success -
#     which is what this machine did before its corruption surfaced elsewhere.
$cleanPath15 = Join-Path (Join-Path $repo 'scripts') '04-component-cleanup.ps1'
$errors = $null
$cleanAst15 = [System.Management.Automation.Language.Parser]::ParseFile($cleanPath15, [ref]$null, [ref]$errors)
$healthFn = $cleanAst15.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-StoreHealth' }, $true)
if (-not $healthFn) {
    Fail '04-component-cleanup.ps1 has no Get-StoreHealth - stage 15 checked nothing'
} else {
    . ([scriptblock]::Create($healthFn.Extent.Text))
    $cases15 = @(
        @{ n = 'healthy';    t = @('Deployment Image Servicing and Management tool', 'No component store corruption detected.', 'The operation completed successfully.'); want = 'Healthy' },
        @{ n = 'repairable'; t = @('The component store is repairable.', 'The operation completed successfully.'); want = 'Repairable' },
        @{ n = 'corrupt';    t = @('Error: 14098', 'The component store has been corrupted.'); want = 'Corrupt' },
        @{ n = 'repaired';   t = @('The component store corruption was repaired.'); want = 'Healthy' },
        @{ n = 'localized';  t = @('Bereitstellungsabbildwartung', 'irgendwas ganz anderes'); want = 'Unknown' },
        @{ n = 'empty';      t = @(); want = 'Unknown' }
    )
    foreach ($c15 in $cases15) {
        $got15 = Get-StoreHealth $c15.t
        if ($got15 -eq $c15.want) { Pass "Get-StoreHealth reads $($c15.n) DISM output as $($c15.want)" }
        else { Fail "Get-StoreHealth read $($c15.n) output as [$got15], expected [$($c15.want)] - a damaged store would be cleaned anyway" }
    }
}

# the verdict is worthless if nothing acts on it: the stop must come BEFORE the
# cleanup, not after it.
$cleanText15 = Get-Content $cleanPath15 -Raw
$iHealth15 = $cleanText15.IndexOf('Get-StoreHealth $healthOut')
$iStop15 = $cleanText15.IndexOf('STOPPING')
$iClean15 = $cleanText15.IndexOf('/StartComponentCleanup')
if ($iHealth15 -lt 0 -or $iStop15 -lt 0 -or $iClean15 -lt 0) {
    Fail '04 is missing the health read, the stop, or the cleanup - stage 15 could not check their order'
} elseif ($iHealth15 -lt $iStop15 -and $iStop15 -lt $iClean15) {
    Pass '04 reads the store health and stops before it ever runs a cleanup'
} else {
    Fail "04's health stop is not between the verdict and the cleanup (health=$iHealth15 stop=$iStop15 cleanup=$iClean15) - a damaged store gets cleaned anyway"
}

# 16. the sandbox harness cannot be RUN without Windows Sandbox installed, but
#     the part that matters can be: what it maps, and how.
$sbPath16 = Join-Path (Join-Path $repo 'tests') 'sandbox-run.ps1'
if (-not (Test-Path $sbPath16)) {
    Fail 'tests\sandbox-run.ps1 is missing - stage 16 checked nothing'
} else {
    $errors = $null
    $sbAst16 = [System.Management.Automation.Language.Parser]::ParseFile($sbPath16, [ref]$null, [ref]$errors)
    $cfgFn16 = $sbAst16.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-SandboxConfig' }, $true)
    if (-not $cfgFn16) {
        Fail 'sandbox-run.ps1 has no New-SandboxConfig - stage 16 could not check what it maps'
    } else {
        . ([scriptblock]::Create($cfgFn16.Extent.Text))
        $xml16 = New-SandboxConfig 'C:\PLANTED-REPO' 'C:\PLANTED-OUT'
        $doc16 = $null
        try { $doc16 = [xml]$xml16 } catch { Fail "New-SandboxConfig produced invalid XML: $($_.Exception.Message)" }
        if ($doc16) {
            $maps16 = @($doc16.Configuration.MappedFolders.MappedFolder)
            $ro16 = @($maps16 | Where-Object { $_.HostFolder -eq 'C:\PLANTED-REPO' })
            $rw16 = @($maps16 | Where-Object { $_.HostFolder -eq 'C:\PLANTED-OUT' })

            if ($ro16.Count -eq 1 -and $ro16[0].ReadOnly -eq 'true') { Pass 'sandbox maps the repo READ-ONLY' }
            else { Fail "sandbox does NOT map the repo read-only (found $($ro16.Count) mapping(s), ReadOnly=$($ro16[0].ReadOnly)) - the VM could write into the working tree" }

            if ($rw16.Count -eq 1 -and $rw16[0].ReadOnly -eq 'false') { Pass 'sandbox maps exactly the out folder writable' }
            else { Fail "the writable out mapping is wrong (found $($rw16.Count), ReadOnly=$($rw16[0].ReadOnly))" }

            $writable16 = @($maps16 | Where-Object { $_.ReadOnly -ne 'true' })
            if ($writable16.Count -eq 1) { Pass 'exactly one writable host mapping, and it is the out folder' }
            else { Fail "$($writable16.Count) writable host mapping(s) - every extra one is a way out of the sandbox onto this machine" }

            if ($doc16.Configuration.Networking -eq 'Disable') { Pass 'sandbox networking is disabled' }
            else { Fail "sandbox networking is [$($doc16.Configuration.Networking)] - the offline install path is then not what is being tested" }
        }
    }
}

# 17. "applied" is not "changed". 01's Confirm-Applied is lifted and CALLED, and
#     unreadable must NOT be counted as a failed change - saying a change did not
#     take when the value merely could not be read sends someone chasing nothing.
$netPath17 = Join-Path (Join-Path $repo 'scripts') '01-network-tune.ps1'
$errors = $null
$netAst17 = [System.Management.Automation.Language.Parser]::ParseFile($netPath17, [ref]$null, [ref]$errors)
$okFn17 = $netAst17.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Confirm-Applied' }, $true)
if (-not $okFn17) {
    Fail '01-network-tune.ps1 has no Confirm-Applied - it prints an after-state without checking it'
} else {
    $notApplied = New-Object System.Collections.Generic.List[string]
    $unreadable = New-Object System.Collections.Generic.List[string]
    . ([scriptblock]::Create($okFn17.Extent.Text))
    Confirm-Applied 'match' 'normal' 'normal'      *> $null
    Confirm-Applied 'wrong' 'normal' 'disabled'    *> $null
    Confirm-Applied 'blank' 'normal' ''            *> $null
    if ($notApplied.Count -eq 1 -and $notApplied[0] -eq 'wrong') { Pass 'Confirm-Applied counts a mismatch as NOT APPLIED' }
    else { Fail "Confirm-Applied recorded $($notApplied.Count) not-applied, expected exactly the mismatch" }
    if ($unreadable.Count -eq 1 -and $unreadable[0] -eq 'blank') { Pass 'Confirm-Applied counts an unreadable value separately, not as a failure' }
    else { Fail "Confirm-Applied recorded $($unreadable.Count) unreadable, expected exactly the blank - conflating the two sends people chasing changes that were fine" }
}

# the check is worthless if it sits before the change it is checking
$netText17 = Get-Content $netPath17 -Raw
$iApply17 = $netText17.IndexOf('=== AFTER ===')
$iVerify17 = $netText17.IndexOf('=== VERIFY')
if ($iApply17 -ge 0 -and $iVerify17 -gt $iApply17) { Pass '01 reads its values back AFTER applying them' }
else { Fail "01's verify block is not after the changes (after=$iApply17 verify=$iVerify17)" }

# --- stage 18: the two revert checks, pressed until each one goes RED ---------
# These read the LIVE machine, so a clean checkout has no revert files and they
# would prove nothing. Drive them against fixture folders instead: four planted
# pairs, each one aimed at a different verdict, so a check that can no longer
# fail is caught here rather than trusted forever.
#
# The fixtures are PARSED, never run. Both scripts read a tune and its revert
# through the PowerShell AST and change nothing, which is what makes it safe to
# plant a Set-Service line and read the real service beside it.
$drift18 = Join-Path $repo 'tests\revert-drift.ps1'
$cred18  = Join-Path $repo 'tests\revert-credibility.ps1'

$svcActual18 = ''
$svc18 = Get-Service -Name 'Winmgmt' -ErrorAction SilentlyContinue
if ($svc18) { $svcActual18 = $svc18.StartType.ToString() }

if (-not $svcActual18) {
    Fail 'Winmgmt start type could not be read, so the revert checks could not be pressed at all'
} else {
    $svcOther18 = 'Manual'
    if ($svcActual18 -eq 'Manual') { $svcOther18 = 'Disabled' }

    $tmp18 = Join-Path $env:TEMP ('wt-revert-' + [guid]::NewGuid().ToString('N'))
    try {
        # name => @(tune line, revert line); $null means the folder stays empty
        $fixtures18 = [ordered]@{
            'healthy' = @("Set-Service 'Winmgmt' -StartupType $svcActual18", "Set-Service 'Winmgmt' -StartupType $svcOther18")
            'noop'    = @("Set-Service 'Winmgmt' -StartupType $svcActual18", "Set-Service 'Winmgmt' -StartupType $svcActual18")
            'gone'    = @("Set-Service 'WindowsTuneNoSuchService' -StartupType Automatic", "Set-Service 'WindowsTuneNoSuchService' -StartupType Manual")
            'empty'   = $null
        }
        foreach ($name18 in $fixtures18.Keys) {
            $dir18 = Join-Path $tmp18 $name18
            New-Item -ItemType Directory -Path $dir18 -Force | Out-Null
            $pair18 = $fixtures18[$name18]
            if ($pair18) {
                Set-Content -LiteralPath (Join-Path $dir18 'svc-probe.ps1')        -Value $pair18[0] -Encoding ascii
                Set-Content -LiteralPath (Join-Path $dir18 'svc-probe-revert.ps1') -Value $pair18[1] -Encoding ascii
            }
        }

        # what each fixture must produce, and WHY - the why is the part that
        # stops someone "fixing" a red by loosening the expectation.
        #   script | fixture | expected exit | what it proves
        $expect18 = @(
            @{ s = $drift18; f = 'healthy'; x = 0; w = 'a revert naming a value the machine does not hold reads as healthy, not as a failure' }
            @{ s = $cred18;  f = 'healthy'; x = 0; w = 'a revert that would undo what the tune set is credible' }
            @{ s = $drift18; f = 'noop';    x = 0; w = 'a revert already matching the machine is reported, not failed - only a human knows why' }
            @{ s = $cred18;  f = 'noop';    x = 1; w = 'RED: a revert restoring the value the tune SETS undoes nothing' }
            @{ s = $drift18; f = 'gone';    x = 1; w = 'RED: a claim whose current value cannot be read at all is unverifiable' }
            @{ s = $cred18;  f = 'gone';    x = 0; w = 'a setting that no longer exists is reported as MISSING and left to the drift check to fail' }
            @{ s = $drift18; f = 'empty';   x = 1; w = 'RED: no claims read means the check proved nothing' }
            @{ s = $cred18;  f = 'empty';   x = 1; w = 'RED: no tune targets read means the check proved nothing' }
        )
        foreach ($e18 in $expect18) {
            $leaf18 = Split-Path -Leaf $e18.s
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $e18.s -ScriptsDir (Join-Path $tmp18 $e18.f) *> $null
            $got18 = $LASTEXITCODE
            if ($got18 -eq $e18.x) {
                Pass ("{0} on the '{1}' fixture -> exit {2}: {3}" -f $leaf18, $e18.f, $got18, $e18.w)
            } else {
                Fail ("{0} on the '{1}' fixture exited {2}, expected {3} - {4}" -f $leaf18, $e18.f, $got18, $e18.x, $e18.w)
            }
        }
    } finally {
        Remove-Item -LiteralPath $tmp18 -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- stage 19: the update verdict, CALLED with synthetic release data ----------
# 07-update-check.ps1 must never report "up to date" on a read it could not
# verify. Get-UpdateVerdict is lifted by the Parser and CALLED with fixtures:
# no network, nothing downloaded. Every malformed case must come back Unknown.
$updPath19 = Join-Path (Join-Path $repo 'scripts') '07-update-check.ps1'
$errors = $null
$updAst19 = [System.Management.Automation.Language.Parser]::ParseFile($updPath19, [ref]$null, [ref]$errors)
if ($errors.Count) { Fail "07-update-check.ps1 does not parse: $($errors[0].Message)" }
$verFn19 = $updAst19.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-UpdateVerdict' }, $true)
if (-not $verFn19) {
    Fail '07-update-check.ps1 has no Get-UpdateVerdict - stage 19 checked nothing'
} else {
    . ([scriptblock]::Create($verFn19.Extent.Text))
    $dg19 = 'sha256:' + ('ab' * 32)
    $good19 = [pscustomobject]@{ tag_name = 'v1.1.0'; assets = @([pscustomobject]@{ name = 'windows-tune-v1.1.0.zip'; digest = $dg19; browser_download_url = 'https://github.com/treforged/windows-tune/releases/download/v1.1.0/windows-tune-v1.1.0.zip' }) }
    $offHost19 = [pscustomobject]@{ tag_name = 'v1.1.0'; assets = @([pscustomobject]@{ name = 'windows-tune-v1.1.0.zip'; digest = $dg19; browser_download_url = 'https://example.invalid/z.zip' }) }
    $same19 = [pscustomobject]@{ tag_name = 'v1.0.0'; assets = @([pscustomobject]@{ name = 'windows-tune-v1.0.0.zip'; digest = $dg19; browser_download_url = 'https://github.com/treforged/windows-tune/releases/download/v1.0.0/windows-tune-v1.0.0.zip' }) }
    $noDig19 = [pscustomobject]@{ tag_name = 'v1.1.0'; assets = @([pscustomobject]@{ name = 'windows-tune-v1.1.0.zip'; digest = $null; browser_download_url = 'u' }) }
    $noAsset19 = [pscustomobject]@{ tag_name = 'v1.1.0'; assets = @() }
    $badTag19 = [pscustomobject]@{ tag_name = 'latest'; assets = @([pscustomobject]@{ name = 'windows-tune-latest.zip'; digest = $dg19; browser_download_url = 'u' }) }
    $cases19 = @(
        @{ n = 'a newer release';          i = 'v1.0.0'; l = $good19;    s = 'Newer' }
        @{ n = 'the same release';         i = 'v1.0.0'; l = $same19;    s = 'UpToDate' }
        @{ n = 'no digest published';      i = 'v1.0.0'; l = $noDig19;   s = 'Unknown' }
        @{ n = 'no matching asset';        i = 'v1.0.0'; l = $noAsset19; s = 'Unknown' }
        @{ n = 'a non-version tag';        i = 'v1.0.0'; l = $badTag19;  s = 'Unknown' }
        @{ n = 'no response at all';       i = 'v1.0.0'; l = $null;      s = 'Unknown' }
        @{ n = 'a download URL off this repo'; i = 'v1.0.0'; l = $offHost19; s = 'Unknown' }
        @{ n = 'no installed VERSION';     i = $null;    l = $good19;    s = 'Unknown' }
    )
    foreach ($c in $cases19) {
        try { $got19 = (Get-UpdateVerdict -Installed $c.i -Latest $c.l).Status }
        catch { $got19 = 'threw: ' + $_.Exception.Message }
        if ($got19 -eq $c.s) { Pass "Get-UpdateVerdict on $($c.n) -> $got19" }
        else { Fail "Get-UpdateVerdict on $($c.n) said $got19, expected $($c.s)" }
    }
}

# --- stage 20: the click-install window agrees with the menu it presses --------
# windows-tune-gui.ps1 drives windows-tune.ps1 by -Choice. Each option's labels
# and flags must match the menu row for the same key, or a press runs the wrong
# thing. Get-OptionPlan is lifted by the Parser and CALLED with fixtures.
$guiPath20 = Join-Path $repo 'windows-tune-gui.ps1'
$menuText20 = Get-Content (Join-Path $repo 'windows-tune.ps1') -Raw
$guiText20 = Get-Content $guiPath20 -Raw
$errors = $null
$guiAst20 = [System.Management.Automation.Language.Parser]::ParseFile($guiPath20, [ref]$null, [ref]$errors)
if ($errors.Count) { Fail "windows-tune-gui.ps1 does not parse: $($errors[0].Message)" }
$planFn20 = $guiAst20.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-OptionPlan' }, $true)
if (-not $planFn20) {
    Fail 'windows-tune-gui.ps1 has no Get-OptionPlan - stage 20 checked nothing'
} else {
    . ([scriptblock]::Create($planFn20.Extent.Text))
    $p20 = @(Get-OptionPlan -Checked @($true,$false,$false,$true,$false,$false))
    if (($p20.Count -eq 2) -and ($p20[0].Choice -eq 1) -and (-not $p20[0].Changes) -and ($p20[1].Choice -eq 4) -and $p20[1].Changes) {
        Pass 'Get-OptionPlan marks option 1 read-only and option 4 as a change'
    } else { Fail "Get-OptionPlan wrong for options 1 and 4: count=$($p20.Count)" }
    if (@(Get-OptionPlan -Checked @($false,$false,$false,$false,$false,$false)).Count -eq 0) { Pass 'Get-OptionPlan with nothing checked plans nothing' }
    else { Fail 'Get-OptionPlan planned something with nothing checked' }
    # rows 8-10 are game mode: 8 the read-only preview, 9 and 10 change the machine
    $p20 = @(Get-OptionPlan -Checked @($false,$false,$false,$false,$false,$false,$false,$true,$true,$true))
    if ($p20.Count -eq 3 -and -not $p20[0].Changes -and $p20[1].Changes -and $p20[2].Changes) { Pass 'Get-OptionPlan marks the game mode preview read-only and watch / start-at-sign-in as changes' }
    else { Fail "Get-OptionPlan wrong for the game mode rows: $(($p20 | ForEach-Object { "$($_.Choice)=$($_.Changes)" }) -join ' ')" }
}
# every option's label is the menu's label for the same key, and its -Choice is that key
$argRows20 = [regex]::Matches($guiText20, "Label = '([^']+)';\s+Args = '-Choice ([0-9A-Z])( -AcceptRisk)?(?: -NoElevate)?( -Yes)?'")
if ($argRows20.Count -ne 19) { Fail "windows-tune-gui.ps1 has $($argRows20.Count) option rows, expected 19 - stage 20 checked nothing" }
# and the other way round: every menu row that runs a script has a GUI row, so no action exists in one surface only
$menuKeys20 = @([regex]::Matches($menuText20, "(?m)^\s*'([0-9A-Z])' = @\{ name = '[^']+\.ps1'") | ForEach-Object { $_.Groups[1].Value })
$guiKeys20 = @($argRows20 | ForEach-Object { $_.Groups[2].Value })
$missing20 = @($menuKeys20 | Where-Object { $guiKeys20 -notcontains $_ })
if ($menuKeys20.Count -eq 0) { Fail 'stage 20 found no script rows in the menu - checked nothing' }
elseif ($missing20.Count) { Fail "menu option(s) $($missing20 -join ', ') have no row in the click-install window" }
else { Pass "every one of the $($menuKeys20.Count) menu options that runs a script is also in the click-install window" }
foreach ($r20 in $argRows20) {
    $label20 = $r20.Groups[1].Value; $key20 = $r20.Groups[2].Value; $accept20 = $r20.Groups[3].Value; $yes20 = $r20.Groups[4].Value
    if (-not $accept20 -and $r20.Value -match '-NoElevate') { Fail "GUI option $key20 passes -NoElevate without -AcceptRisk"; continue }
    $menuLine20 = ($menuText20 -split "`n") | Where-Object { $_ -match "^\s*'$key20' = " } | Select-Object -First 1
    if (-not $menuLine20 -or $menuLine20 -notmatch [regex]::Escape("label = '$label20'")) {
        Fail "GUI option $key20 label '$label20' does not match the menu row for $key20"; continue
    }
    # a row that changes the machine must leave I ACCEPT and Run it? to the person in the console:
    # no -AcceptRisk, no -Yes (audit 2c24feed lead 2). A read-only row runs unelevated with -AcceptRisk -NoElevate.
    $menuChanges20 = ($menuText20 -split "`n") | Where-Object { $_ -match "^\s*'$key20' = " } | Out-String
    $changesRow20 = $menuChanges20 -notmatch "changes = ''"
    if ($yes20) { Fail "GUI option $key20 is pressed with -Yes - the GUI answers Run it? for the user" }
    elseif ($changesRow20 -and $accept20) { Fail "GUI option $key20 changes the machine but passes -AcceptRisk - the GUI accepts the notice for the user" }
    elseif (-not $changesRow20 -and -not $accept20) { Fail "GUI option $key20 is read-only but is not pressed with -AcceptRisk -NoElevate" }
    else { Pass "GUI option $key20 matches menu row $key20 (label, -Choice, notice gate left to the user)" }
}

# --- stage 21: README revert claims match which scripts write a revert file ---
# The README said every script writes a revert file. Only 01 and 02 do. This
# stage asserts the README's stated list against the scripts themselves, so the
# claim cannot drift from the code again.
$revertScripts21 = @(Get-ChildItem (Join-Path $repo 'scripts') -Filter '*.ps1' | Where-Object { $_.Name -match '^\d\d-' } | Where-Object {
    (Get-Content $_.FullName -Raw) -match "Join-Path[^
]*'[^']*-revert\.ps1'"
} | ForEach-Object { $_.Name.Substring(0,2) } | Sort-Object)
$readme21 = Get-Content (Join-Path $repo 'README.md') -Raw
$claimOk21 = $readme21 -match 'Only 01, 02, 08, 09 and 10\s+write a `\*-revert\.ps1`'
if ($revertScripts21.Count -eq 0) { Fail 'stage 21 found no script that writes a revert file - checked nothing' }
elseif (($revertScripts21 -join ',') -ne '01,02,08,09,10') { Fail "scripts that write a revert file are $($revertScripts21 -join ','), expected 01,02,08,09,10" }
elseif (-not $claimOk21) { Fail 'README does not state that only 01, 02, 08, 09 and 10 write a revert file' }
else { Pass 'only 01, 02, 08, 09 and 10 write a revert file, and the README says so' }

# --- stage 22: privacy\ scripts (imported from net-tune) are portable and the audit runs --
# Each script must exist, be ASCII, and carry nothing from the author's PC. The
# detector is proven on a planted bad line, and the read-only audit is RUN.
$privFiles22 = @('privacy-tune.ps1','privacy-audit.ps1','browser-privacy.ps1','dns-encrypt.ps1','telemetry-tune.ps1')
$badRe22 = '(?i)tvonh|surfshark|\\Desktop\\(getforgenta|forged-glass|claudecontext)|192\.168\.|\bGus\b|\d{3}[-. ]\d{3}[-. ]\d{4}'
$seen22 = 0
foreach ($n in $privFiles22) {
    $p = Join-Path $repo "privacy\$n"
    if (-not (Test-Path $p)) { Fail "privacy\$n is missing"; continue }
    $seen22++
    $raw = Get-Content $p -Raw
    if ($raw -match '[^\x00-\x7F]') { Fail "privacy\$n has non-ASCII characters" }
    if ($raw -match $badRe22) { Fail "privacy\$n carries machine-specific or personal text: $($Matches[0])" }
}
if ($seen22 -eq 0) { Fail 'stage 22 found no privacy scripts - checked nothing' }
if ('C:\Users\tvonh\Desktop\x' -notmatch $badRe22) { Fail 'stage 22 detector missed a planted personal path - it proved nothing' }
$aud22 = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'privacy\privacy-audit.ps1') 2>&1 | Out-String
if (($LASTEXITCODE -in 0,1) -and $aud22 -match '\d+ checks, \d+ readable') { Pass "privacy scripts are portable ($seen22 checked) and privacy-audit ran (exit $LASTEXITCODE)" }
else { Fail "privacy-audit.ps1 did not report a result (exit $LASTEXITCODE)" }

# --- stage 23: 05 -Repair records a Defender value before clearing it, and leaves policy alone on a managed PC ---
# (audit 2c24feed lead 4). A source check: -Repair writes HKLM and cannot be run here. It asserts ORDER, so a
# Remove-ItemProperty with no capture line before it in the same loop fails.
$src23 = Get-Content (Join-Path $repo 'scripts\05-defender-handover.ps1') -Raw
$rm23 = [regex]::Matches($src23, 'Remove-ItemProperty \$k -Name \$n')
if ($rm23.Count -eq 0) { Fail 'stage 23 found no Defender value clear in 05 - checked nothing' }
foreach ($m23 in $rm23) {
    $before23 = $src23.Substring([Math]::Max(0, $m23.Index - 400), [Math]::Min(400, $m23.Index))
    if ($before23 -match 'Add-Content -Path \$captureLog') { Pass '05 -Repair records each Defender value before it clears it' }
    else { Fail '05 -Repair clears a Defender value with no capture before it' }
}
if ($src23 -match 'PartOfDomain' -and $src23 -match "\`$managed -and \`$k -like '\*\\Policies\\\*'") { Pass '05 -Repair skips Defender POLICY keys on a domain-joined or MDM-managed PC' }
else { Fail '05 -Repair has no domain/MDM skip for Defender policy keys' }

# --- stage 24: the elevated menu can tell a user-writable folder from an admin-only one (audit 2c24feed lead 1) ---
$errors24 = $null
$ast24 = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'windows-tune.ps1'), [ref]$null, [ref]$errors24)
$fn24 = $ast24.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-UserWritable' }, $true)
if (-not $fn24) { Fail 'windows-tune.ps1 has no Test-UserWritable - stage 24 checked nothing' }
else {
    . ([scriptblock]::Create($fn24.Extent.Text))
    if (Test-UserWritable $env:LOCALAPPDATA) { Pass 'Test-UserWritable: %LOCALAPPDATA% (the old default install) reads as user-writable' }
    else { Fail 'Test-UserWritable says %LOCALAPPDATA% is not user-writable - the warning would never show' }
    if (-not (Test-UserWritable (Join-Path $env:SystemRoot 'System32'))) { Pass 'Test-UserWritable: System32 (admin-only) reads as not user-writable' }
    else { Fail 'Test-UserWritable says System32 is user-writable - the warning would cry wolf everywhere' }
    if (-not (Test-UserWritable $env:ProgramFiles)) { Pass 'Test-UserWritable: Program Files (the install.ps1 default) reads as not user-writable' }
    else { Fail 'Test-UserWritable says Program Files is user-writable - the default install would be refused' }
}

# --- stage 25: elevated, the menu never runs a script or revert a normal program could have planted (audit 2c24feed lead 1) ---
$fnNames25 = 'Test-UserWritable', 'Get-UnsafeRunReason', 'Invoke-Checked'
$fns25 = @($ast24.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $fnNames25 -contains $n.Name }, $true))
if ($fns25.Count -ne 3) { Fail "windows-tune.ps1 has $($fns25.Count) of the 3 run-guard functions - stage 25 checked nothing" }
else {
    foreach ($f25 in $fns25) { . ([scriptblock]::Create($f25.Extent.Text)) }
    $plant25 = Join-Path $env:TEMP ('wt-plant-' + [Guid]::NewGuid())
    New-Item -ItemType Directory -Path (Join-Path $plant25 'scripts') | Out-Null
    try {
        $marker25 = Join-Path $plant25 'PLANTED-RAN.txt'
        $revert25 = Join-Path $plant25 'scripts\99-planted-revert.ps1'
        Set-Content $revert25 "Set-Content -LiteralPath '$marker25' 'ran'" -Encoding ascii
        # 25a. elevated: the planted revert in a user-writable folder must NOT run
        $said25 = (Invoke-Checked $revert25 -Elevated 6>&1 | Out-String)
        if (-not (Test-Path $marker25) -and $said25 -match 'REFUSED') { Pass 'elevated: a planted *-revert.ps1 in a user-writable folder is refused and does not run' }
        else { Fail "elevated: the planted revert RAN or was not refused (marker: $(Test-Path $marker25)) $said25" }
        # 25b. control: the same file not elevated does run, so 25a refused a payload that works
        Invoke-Checked $revert25 6>$null | Out-Null
        if (Test-Path $marker25) { Pass 'control: the planted revert is a working payload when not elevated' }
        else { Fail 'control: the planted revert did not run even unelevated - 25a proved nothing' }
        # 25c. an admin-only file passes the same check, so the guard does not refuse everything
        $sys25 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $why25 = Get-UnsafeRunReason $sys25
        if (-not $why25) { Pass 'an admin-only file (System32 powershell.exe) passes the run check' }
        else { Fail "an admin-only file was refused: $why25" }
        if (Get-UnsafeRunReason (Join-Path $plant25 'missing.ps1')) { Pass 'a missing file is refused, not vouched for' } else { Fail 'a missing file passed the run check' }
    } finally { Remove-Item -Recurse -Force $plant25 -ErrorAction SilentlyContinue }
}
# 25d. static: Invoke-Checked is the ONLY place the menu runs a script by '&', so nothing can skip the check
$amp25 = @($ast24.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand }, $true))
$outside25 = @($amp25 | Where-Object { $p = $_.Parent; while ($p -and -not ($p -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $p = $p.Parent }; -not $p -or $p.Name -ne 'Invoke-Checked' })
if ($amp25.Count -eq 0) { Fail 'stage 25 found no & invocation in windows-tune.ps1 - checked nothing' }
elseif ($outside25.Count) { Fail "windows-tune.ps1 runs a script with & outside Invoke-Checked at line $($outside25[0].Extent.StartLineNumber)" }
else { Pass "windows-tune.ps1 runs scripts only through Invoke-Checked ($($amp25.Count) & call)" }
# 25e. the whole menu, from a user-writable copy, with NO -NoElevate: it must not ask for elevation.
#      Start-Process is shadowed by a function, so a regression records a call instead of raising UAC.
$scratch25 = Join-Path $env:TEMP ('wt-noelev-' + [Guid]::NewGuid())
New-Item -ItemType Directory -Path (Join-Path $scratch25 'scripts') | Out-Null
try {
    Copy-Item (Join-Path $repo 'windows-tune.ps1'), (Join-Path $repo 'NOTICE.md') $scratch25
    Set-Content (Join-Path $scratch25 'scripts\03-storage-report.ps1') '"ARGS=$($args.Count)"' -Encoding ascii
    $wrap25 = Join-Path $scratch25 'wrap.ps1'
    Set-Content $wrap25 ("function Start-Process { 'START-PROCESS-CALLED' }`n& '" + (Join-Path $scratch25 'windows-tune.ps1') + "' -AcceptRisk -Choice 1`nexit `$LASTEXITCODE") -Encoding ascii
    $out25 = (& $ps -NoProfile -ExecutionPolicy Bypass -File $wrap25) -join "`n"
    if ($elevated) {
        if ($LASTEXITCODE -eq 4 -and $out25 -match 'REFUSED to run elevated' -and $out25 -notmatch 'ARGS=') { Pass 'elevated from a user-writable folder: the menu refuses with exit 4 and runs nothing' }
        else { Fail "elevated from a user-writable folder: exit $LASTEXITCODE`n$out25" }
    } elseif ($LASTEXITCODE -eq 0 -and $out25 -match 'Not elevating' -and $out25 -match 'ARGS=0' -and $out25 -notmatch 'START-PROCESS-CALLED') {
        Pass 'from a user-writable folder the menu does not elevate, and the read-only option still runs'
    } else { Fail "from a user-writable folder: exit $LASTEXITCODE`n$out25" }
} finally { Remove-Item -Recurse -Force $scratch25 -ErrorAction SilentlyContinue }
# 25f. install.ps1 with no -Path and no admin refuses up front instead of failing half way into Program Files
if (-not $elevated) {
    $pf25 = Join-Path $env:ProgramFiles 'windows-tune'
    $had25 = Test-Path $pf25
    $out25 = (& $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install.ps1') -FromZip (Join-Path $repo 'README.md')) -join ' '
    if ($LASTEXITCODE -eq 1 -and $out25 -match 'needs administrator rights' -and ($had25 -or -not (Test-Path $pf25))) { Pass 'install.ps1 default (Program Files) without admin: refused, nothing installed' }
    else { Fail "install.ps1 default without admin: exit $LASTEXITCODE $out25" }
} else { Pass 'stage 25f skipped: this gate is ELEVATED, and it must not install into Program Files' }
# 25g. no script runs a revert file it just wrote back off disk (privacy\dns-encrypt.ps1 rolls back from memory)
$src25 = @(Get-ChildItem $repo -Recurse -File -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '\\(\.git|tests)\\' -and $_.Name -notlike '*-revert.ps1' })
$runsRevert25 = @($src25 | Select-String -Pattern '&\s*\$revert\b')
if ($src25.Count -eq 0) { Fail 'stage 25g scanned no scripts - checked nothing' }
elseif ($runsRevert25.Count) { foreach ($h25 in $runsRevert25) { Fail "$($h25.Filename):$($h25.LineNumber) runs its revert file back off disk" } }
else { Pass "no script runs a just-written revert file back off disk ($($src25.Count) scanned)" }

# --- stage 26: game mode (09) never touches anti-cheat or Windows itself, and its undo undoes what it did --------
# The pure parts are lifted by the Parser and CALLED. Enter and restore are CALLED too, against stand-in
# cmdlets that only record what they were asked to do, so nothing on this machine is stopped or capped.
# Then the real script is RUN with -DryRun from a scratch copy, and -InstallWatcher -DryRun must refuse there.
$gmPath26 = Join-Path $repo 'scripts\09-game-mode.ps1'
$errors = $null
$gmAst26 = [System.Management.Automation.Language.Parser]::ParseFile($gmPath26, [ref]$null, [ref]$errors)
$fnNames26 = 'Test-GameModeProtected', 'ConvertTo-GameModeName', 'Read-GameModeConfig', 'Get-GameModePlan', 'Get-GameModeStep',
             'ConvertTo-PsLiteral', 'New-GameModeRevertLines', 'Read-GameModeState', 'Write-GameModeLog', 'Save-GameModeRecord',
             'Clear-GameModeRecord', 'Invoke-GameModeEnter', 'Invoke-GameModeRestore'
$fns26 = @($gmAst26.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $fnNames26 -contains $n.Name }, $false))
$consts26 = @($gmAst26.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -in 'NAME_RE', 'POLICY_PREFIX' }, $false))
if ($errors.Count -or $fns26.Count -ne $fnNames26.Count -or $consts26.Count -ne 2) {
    Fail "09-game-mode.ps1: found $($fns26.Count) of $($fnNames26.Count) functions and $($consts26.Count) of 2 constants - stage 26 checked nothing"
} else {
    foreach ($c26 in $consts26) { . ([scriptblock]::Create($c26.Extent.Text)) }
    foreach ($f26 in $fns26) { . ([scriptblock]::Create($f26.Extent.Text)) }

    # 26a. the hard denylist. Each of these must be refused whatever a config says.
    $mustRefuse26 = @(
        @('vgc', 'Process'), @('vgk', 'Process'), @('vgtray.exe', 'Process'), @('EasyAntiCheat.exe', 'Process'), @('EasyAntiCheat_EOS', 'Process'),
        @('BEService', 'Process'), @('BEService_x64.exe', 'Process'), @('FACEIT', 'Process'), @('FACEITClient', 'Process'), @('faceitservice', 'Process'),
        @('Ricochet', 'Process'), @('randgrid', 'Process'), @('PnkBstrA', 'Process'), @('EAAntiCheat.GameService', 'Process'),
        @('csrss', 'Process'), @('wininit', 'Process'), @('lsass.exe', 'Process'), @('services', 'Process'), @('smss', 'Process'),
        @('winlogon', 'Process'), @('svchost', 'Process'), @('explorer.exe', 'Process'), @('dwm', 'Process'), @('MsMpEng', 'Process'),
        @('SecurityHealthService', 'Process'), @('vgc.exe', 'App'), @('lsass.exe', 'App'),
        @('vgc', 'Service'), @('vgk', 'Service'), @('EasyAntiCheat', 'Service'), @('EasyAntiCheat_EOS', 'Service'), @('BEService', 'Service'),
        @('FACEIT', 'Service'), @('WinDefend', 'Service'), @('WdNisSvc', 'Service'), @('Winmgmt', 'Service'), @('mpssvc', 'Service'), @('EventLog', 'Service')
    )
    $leaks26 = @($mustRefuse26 | Where-Object { -not (Test-GameModeProtected $_[0] $_[1]) } | ForEach-Object { "$($_[1]) $($_[0])" })
    if ($leaks26.Count) { Fail "game mode would touch protected names: $($leaks26 -join ', ')" }
    else { Pass "game mode refuses all $($mustRefuse26.Count) anti-cheat, system and security names it is handed" }
    # control: the denylist does not refuse everything, or 26a proved nothing
    $mayTouch26 = @(@('notepad', 'Process'), @('Docker Desktop', 'Process'), @('ollama', 'Process'), @('OneDrive.exe', 'App'), @('GoogleDriveFS.exe', 'App'), @('Spooler', 'Service'), @('com.docker.service', 'Service'))
    $over26 = @($mayTouch26 | Where-Object { Test-GameModeProtected $_[0] $_[1] } | ForEach-Object { "$($_[1]) $($_[0])" })
    if ($over26.Count) { Fail "game mode refuses ordinary programs: $($over26 -join ', ')" } else { Pass "control: $($mayTouch26.Count) ordinary programs and services are allowed" }

    # 26b. a hostile config: protected names and the game itself in the stop lists. The plan must refuse every one out loud.
    $hostile26 = @'
{ "games": ["cs2.exe"],
  "stopProcesses": [ {"name":"vgc"}, {"name":"EasyAntiCheat_EOS.exe"}, {"name":"BEService"}, {"name":"FACEITClient"}, {"name":"lsass"},
                     {"name":"explorer.exe"}, {"name":"svchost"}, {"name":"MsMpEng"}, {"name":"cs2"}, {"name":"fakeapp"}, {"name":"offapp", "enabled": false} ],
  "stopServices": [ {"name":"vgk"}, {"name":"WinDefend"}, {"name":"Winmgmt"}, {"name":"fakesvc"} ],
  "uploadCaps": [ {"app":"vgc.exe","bitsPerSecond":1000000}, {"app":"fakesync.exe","bitsPerSecond":1000000} ] }
'@
    try {
        $cfg26 = Read-GameModeConfig $hostile26
        $plan26 = @(Get-GameModePlan -Config $cfg26 -Running @('vgc', 'easyanticheat_eos', 'beservice', 'faceitclient', 'lsass', 'explorer', 'svchost', 'msmpeng', 'cs2', 'fakeapp') `
                     -ServiceState @{ vgk = 'Running'; windefend = 'Running'; winmgmt = 'Running'; fakesvc = 'Running' } -ExistingPolicies @())
        $acting26 = @($plan26 | Where-Object { $_.Action -in 'Stop', 'Cap', 'Shutdown' } | ForEach-Object { "$($_.Kind):$($_.Name)" } | Sort-Object)
        $refused26 = @($plan26 | Where-Object { $_.Action -eq 'Refused' })
        if (($acting26 -join ',') -eq 'Cap:fakesync.exe,Process:fakeapp,Service:fakesvc' -and $refused26.Count -eq 13) {
            Pass 'a hostile config: 13 protected or game entries REFUSED, only the 3 ordinary ones planned, the disabled one ignored'
        } else { Fail "hostile config planned [$($acting26 -join ', ')] and refused $($refused26.Count), expected the 3 ordinary entries and 13 refusals" }
        if (@($plan26 | Where-Object { $_.Name -eq 'cs2' -and $_.Action -eq 'Refused' -and $_.Why -match 'game list' }).Count -eq 1) { Pass 'a stop entry naming a listed game is refused' }
        else { Fail 'a stop entry naming a listed game was not refused' }
        $plan26b = @(Get-GameModePlan -Config $cfg26 -Running @() -ServiceState @{ fakesvc = 'Stopped' } -ExistingPolicies @('windows-tune game mode fakesync.exe'))
        if (@($plan26b | Where-Object { $_.Action -in 'Stop', 'Cap', 'Shutdown' }).Count -eq 0) { Pass 'nothing running, service stopped, cap present -> nothing planned (idempotent)' }
        else { Fail 'an already-applied state still plans changes' }
    } catch { Fail "the hostile config could not be planned: $($_.Exception.Message)" }

    # 26c. a config that would put code into the revert file, or is otherwise unusable, is refused before anything runs
    $bad26 = [ordered]@{
        'no games'           = '{ "games": [] }'
        'a quote in a name'  = '{ "games": ["x.exe"], "stopProcesses": [ {"name": "a''b"} ] }'
        'a ; in a name'      = '{ "games": ["x.exe"], "stopServices": [ {"name": "a; Remove-Item C:\\x"} ] }'
        'a $( in a name'     = '{ "games": ["x.exe"], "stopProcesses": [ {"name": "$(calc)"} ] }'
        'a cap below 64k'    = '{ "games": ["x.exe"], "uploadCaps": [ {"app": "a.exe", "bitsPerSecond": 10} ] }'
        'a cap app no .exe'  = '{ "games": ["x.exe"], "uploadCaps": [ {"app": "a", "bitsPerSecond": 1000000} ] }'
        'poll 0 seconds'     = '{ "games": ["x.exe"], "pollSeconds": 0 }'
        'not JSON'           = '{ games: '
    }
    foreach ($k26 in $bad26.Keys) {
        try { [void](Read-GameModeConfig $bad26[$k26]); Fail "game mode config with $k26 was accepted" }
        catch { Pass "game mode config with $k26 is refused" }
    }

    # 26d. the shipped defaults: valid, generic, and they stop nothing unless the user switches an entry on
    $defPath26 = Join-Path $repo 'scripts\09-game-mode.defaults.json'
    $defRaw26 = Get-Content -LiteralPath $defPath26 -Raw
    try {
        $def26 = Read-GameModeConfig $defRaw26
        if ($def26.Games.Count -ge 5 -and $def26.StopProcesses.Count -eq 0 -and $def26.StopServices.Count -eq 0 -and -not $def26.WslShutdown -and $def26.UploadCaps.Count -ge 1) {
            Pass "shipped defaults: $($def26.Games.Count) games, $($def26.UploadCaps.Count) upload caps, and every stop entry is off"
        } else { Fail "shipped defaults switch on a stop entry or list too few games (games=$($def26.Games.Count) procs=$($def26.StopProcesses.Count) svcs=$($def26.StopServices.Count) wsl=$($def26.WslShutdown))" }
    } catch { Fail "shipped defaults do not load: $($_.Exception.Message)" }
    $personal26 = '(?i)tvonh|claude|\bdesk\b|\\Users\\|Sam Game Mode|SamGameMode'
    foreach ($n26 in '09-game-mode.ps1', '09-game-mode.defaults.json') {
        $t26 = Get-Content -LiteralPath (Join-Path $repo "scripts\$n26") -Raw
        if ($t26 -match $personal26) { Fail "$n26 carries personal text: $($Matches[0])" }
        elseif ($t26 -match '[^\x00-\x7F]') { Fail "$n26 has non-ASCII characters" }
        else { Pass "$n26 is ASCII and carries no personal paths or names" }
    }
    if ('C:\Users\x\Desktop' -notmatch $personal26) { Fail 'stage 26 personal-text detector missed a planted path - it proved nothing' }

    # 26e. the watcher's decision
    $steps26 = @((Get-GameModeStep $true $false), (Get-GameModeStep $false $true), (Get-GameModeStep $true $true), (Get-GameModeStep $false $false)) -join ','
    if ($steps26 -eq 'enter,restore,none,none') { Pass 'Get-GameModeStep: enter when a game starts, restore when it ends, nothing otherwise' }
    else { Fail "Get-GameModeStep gave $steps26, expected enter,restore,none,none" }

    # 26f. the revert file undoes exactly what was applied, newest first, parses, and never stops anything
    $applied26 = @(
        [pscustomobject]@{ Kind = 'Cap';     Name = 'fakesync.exe'; Path = $null; Restart = $false; PolicyName = 'windows-tune game mode fakesync.exe' }
        [pscustomobject]@{ Kind = 'Service'; Name = 'fakesvc';      Path = $null; Restart = $false; PolicyName = '' }
        [pscustomobject]@{ Kind = 'Process'; Name = 'fakeapp';      Path = "C:\Program Files\it's fake\fakeapp.exe"; Restart = $true; PolicyName = '' }
        [pscustomobject]@{ Kind = 'Process'; Name = 'norestart';    Path = 'C:\Program Files\n\norestart.exe'; Restart = $false; PolicyName = '' }
    )
    $lines26 = @(New-GameModeRevertLines -Applied $applied26 -Captured 'test')
    $text26 = $lines26 -join "`n"
    $errors = $null; $tokens26 = $null
    $rAst26 = [System.Management.Automation.Language.Parser]::ParseInput($text26, [ref]$tokens26, [ref]$errors)
    $cmds26 = @($rAst26.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
    # positions of the COMMANDS in the parsed file, not of the text: a commented-out step must count as missing
    $cmdAsts26 = @($rAst26.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
    function Get-CmdOffset26([string]$Name) { $c = @($cmdAsts26 | Where-Object { $_.GetCommandName() -eq $Name } | Select-Object -First 1); if ($c.Count) { $c[0].Extent.StartOffset } else { -1 } }
    $iSvc26 = Get-CmdOffset26 'Start-Service'; $iCap26 = Get-CmdOffset26 'Remove-NetQosPolicy'; $iProc26 = Get-CmdOffset26 'Start-Process'
    $pathLit26 = @($rAst26.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -like '*fakeapp.exe*' }, $true) | ForEach-Object { $_.Value })
    if ($errors.Count) { Fail "the game mode revert file does not parse: $($errors[0].Message)" }
    elseif (@($cmds26 | Where-Object { $_ -match '^(Stop-|Invoke-Expression$|iex$)' }).Count) { Fail "the game mode revert file runs $($cmds26 -join ', ')" }
    elseif ($iCap26 -lt 0 -or $iSvc26 -lt 0 -or $iProc26 -lt 0) { Fail "the game mode revert file is missing a step (cap=$iCap26 service=$iSvc26 restart=$iProc26)" }
    elseif (-not ($iProc26 -lt $iSvc26 -and $iSvc26 -lt $iCap26)) { Fail 'the game mode revert file does not undo newest-first' }
    elseif ($pathLit26 -notcontains """C:\Program Files\it's fake\fakeapp.exe""") { Fail "a program path with a quote did not survive the revert file intact: $($pathLit26 -join ' | ')" }
    elseif ($text26 -match "Get-Process -Name 'norestart'") { Fail 'the revert file restarts a program whose entry says restart: false' }
    else { Pass 'the revert file parses, undoes the restart, service and cap newest-first, keeps a quoted path intact, and stops nothing' }

    # 26g. enter and restore, CALLED, against stand-ins. A protected row smuggled past the plan must still not be touched.
    $calls26 = New-Object System.Collections.Generic.List[string]
    $fake26 = @{ running = @{ fakeapp = $true; vgc = $true }; svc = @{ fakesvc = 'Running' }; qos = New-Object System.Collections.Generic.List[string] }
    # The stand-ins keep their record in GLOBAL variables: the generated revert file is run as its own script,
    # where $script: would point at the revert file, not at this gate.
    $global:calls26 = $calls26; $global:fake26 = $fake26
    function global:New-NetQosPolicy { [CmdletBinding()] param($Name, $AppPathNameMatchCondition, $ThrottleRateActionBitsPerSecond, $PolicyStore) $global:calls26.Add("cap $AppPathNameMatchCondition $ThrottleRateActionBitsPerSecond"); $global:fake26.qos.Add($Name) }
    function global:Get-NetQosPolicy { [CmdletBinding()] param($Name, $PolicyStore) if ($global:fake26.qos -contains $Name) { [pscustomobject]@{ Name = $Name } } }
    function global:Remove-NetQosPolicy { [CmdletBinding()] param($Name, $PolicyStore, [switch]$Confirm) $global:calls26.Add("uncap $Name"); [void]$global:fake26.qos.Remove($Name) }
    function global:Stop-Service { [CmdletBinding()] param($Name) $global:calls26.Add("stop-service $Name"); $global:fake26.svc[$Name] = 'Stopped' }
    function global:Start-Service { [CmdletBinding()] param($Name) $global:calls26.Add("start-service $Name"); $global:fake26.svc[$Name] = 'Running' }
    function global:Get-Service { [CmdletBinding()] param($Name) if ($global:fake26.svc.ContainsKey($Name)) { [pscustomobject]@{ Name = $Name; Status = $global:fake26.svc[$Name] } } }
    function global:Get-Process { [CmdletBinding()] param($Name)
        if (-not $global:fake26.running[$Name]) { return }
        $o = [pscustomobject]@{ Id = 1; ProcessName = $Name; Path = "C:\Program Files\Fake\$Name.exe" }
        $o | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { $global:calls26.Add("close $($this.ProcessName)"); $global:fake26.running[$this.ProcessName] = $false; $true }
        $o }
    function global:Stop-Process { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject, [switch]$Force) process { $global:calls26.Add("kill $($InputObject.ProcessName)") } }
    function global:Start-Process { [CmdletBinding()] param($FilePath, $ArgumentList) $global:calls26.Add("start $(Split-Path -Leaf $FilePath) $ArgumentList") }
    $gmTmp26 = Join-Path $env:TEMP ('wt-gm-' + [Guid]::NewGuid())
    New-Item -ItemType Directory -Path $gmTmp26 | Out-Null
    $script:RevertPath = Join-Path $gmTmp26 '09-game-mode-revert.ps1'
    $script:StatePath  = Join-Path $gmTmp26 '09-game-mode-state.json'
    $script:LogPath    = $null
    try {
        $planIn26 = @(
            [pscustomobject]@{ Kind = 'Process'; Name = 'fakeapp'; Action = 'Stop'; Why = ''; Restart = $true; Force = $false; BitsPerSecond = 0; PolicyName = '' }
            [pscustomobject]@{ Kind = 'Process'; Name = 'vgc';     Action = 'Stop'; Why = ''; Restart = $true; Force = $true;  BitsPerSecond = 0; PolicyName = '' }
            [pscustomobject]@{ Kind = 'Service'; Name = 'fakesvc'; Action = 'Stop'; Why = ''; Restart = $false; Force = $false; BitsPerSecond = 0; PolicyName = '' }
            [pscustomobject]@{ Kind = 'Cap';     Name = 'fakesync.exe'; Action = 'Cap'; Why = ''; Restart = $false; Force = $false; BitsPerSecond = 1000000; PolicyName = 'windows-tune game mode fakesync.exe' }
            [pscustomobject]@{ Kind = 'Process'; Name = 'notrunning'; Action = 'Skip'; Why = 'not running'; Restart = $true; Force = $false; BitsPerSecond = 0; PolicyName = '' }
        )
        $got26 = @(Invoke-GameModeEnter $planIn26 6> $null)
        $did26 = ($calls26 -join ', ')
        if ($did26 -match 'vgc') { Fail "Invoke-GameModeEnter touched vgc when handed it directly: $did26" }
        else { Pass 'Invoke-GameModeEnter refuses a protected row even when the plan hands it one (vgc not closed, not killed)' }
        if ($did26 -eq 'close fakeapp, stop-service fakesvc, cap fakesync.exe 1000000' -and $got26.Count -eq 3) { Pass "enter applied exactly the 3 ordinary changes: $did26" }
        else { Fail "enter did [$did26] and returned $($got26.Count) applied" }
        $state26 = if (Test-Path -LiteralPath $script:StatePath) { @(Read-GameModeState (Get-Content -LiteralPath $script:StatePath -Raw)) } else { @() }
        if ((Test-Path -LiteralPath $script:RevertPath) -and $state26.Count -eq 3 -and (($state26 | ForEach-Object { $_.Name }) -join ',') -eq 'fakeapp,fakesvc,fakesync.exe') { Pass 'enter wrote the revert and state files, naming only the 3 changes that took' }
        else { Fail "after enter: revert exists=$(Test-Path -LiteralPath $script:RevertPath), state rows=$($state26.Count)" }
        $calls26.Clear()
        $failed26 = Invoke-GameModeRestore $state26 6> $null
        $undo26 = ($calls26 -join ', ')
        if ($failed26 -eq 0 -and $undo26 -eq 'uncap windows-tune game mode fakesync.exe, start-service fakesvc, start explorer.exe "C:\Program Files\Fake\fakeapp.exe"') { Pass "restore from the state file undid all 3, newest first: $undo26" }
        else { Fail "restore returned $failed26 and did [$undo26]" }
        if ($fake26.svc['fakesvc'] -eq 'Running' -and $fake26.qos.Count -eq 0) { Pass 'after restore the service is running again and no cap is left' } else { Fail 'restore left the fake machine changed' }
        Clear-GameModeRecord
        if (-not (Test-Path -LiteralPath $script:RevertPath) -and -not (Test-Path -LiteralPath $script:StatePath)) { Pass 'once restored, the revert and state files are gone (both exist only while game mode is on)' }
        else { Fail 'the revert or state file is still there after a full restore' }
        # the GENERATED revert file, RUN as a file from the temp folder, against the same stand-ins
        $fake26.running['fakeapp'] = $true; $fake26.svc['fakesvc'] = 'Running'
        [void](Invoke-GameModeEnter $planIn26 6> $null)
        $calls26.Clear()
        # never run it unless every command it calls is a stand-in: a real Start-Process here would open a window
        $real26 = @('Start-Process', 'Start-Service', 'Remove-NetQosPolicy', 'Get-NetQosPolicy', 'Get-Process' | Where-Object { (Get-Command $_).CommandType -ne 'Function' })
        if ($real26.Count) { throw "stand-ins are not in place for $($real26 -join ', ') - the revert file was not run" }
        & $script:RevertPath 6> $null
        $rev26 = ($calls26 -join ', ')
        if ($rev26 -eq 'uncap windows-tune game mode fakesync.exe, start-service fakesvc, start explorer.exe "C:\Program Files\Fake\fakeapp.exe"' -and $fake26.qos.Count -eq 0) { Pass "the generated revert file, run, undid all 3: $rev26" }
        else { Fail "the generated revert file did [$rev26]" }
        if (-not (Test-Path -LiteralPath $script:RevertPath) -and -not (Test-Path -LiteralPath $script:StatePath)) { Pass 'the revert file removed itself and the state file once every step worked' }
        else { Fail "after running the revert file: revert exists=$(Test-Path -LiteralPath $script:RevertPath) state exists=$(Test-Path -LiteralPath $script:StatePath)" }
        # nothing to do -> no files, says so
        $calls26.Clear()
        $none26 = @(Invoke-GameModeEnter @($planIn26[4]) 6> $null)
        if ($none26.Count -eq 0 -and $calls26.Count -eq 0 -and -not (Test-Path -LiteralPath $script:RevertPath)) { Pass 'enter with nothing to change changes nothing and writes no revert file' }
        else { Fail 'enter with nothing to change still acted or wrote a file' }
        # a tampered state file naming anti-cheat is refused, not restored from
        try { [void](Read-GameModeState '[{"Kind":"Service","Name":"vgk","Path":"","Restart":false,"PolicyName":""}]'); Fail 'a state file naming vgk was accepted' }
        catch { Pass 'a state file naming a protected entry is refused' }
    } finally {
        foreach ($s26 in 'New-NetQosPolicy', 'Get-NetQosPolicy', 'Remove-NetQosPolicy', 'Stop-Service', 'Start-Service', 'Get-Service', 'Get-Process', 'Stop-Process', 'Start-Process') { Remove-Item "function:global:$s26" -ErrorAction SilentlyContinue }
        Remove-Variable -Name calls26, fake26 -Scope Global -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $gmTmp26 -ErrorAction SilentlyContinue
    }
}

# 26h. the real script, RUN with -DryRun from a scratch copy: it refuses the hostile entries, changes nothing,
#      and -InstallWatcher refuses from a folder a normal program can write (no scheduled task appears).
$gmRun26 = Join-Path $env:TEMP ('wt-gmrun-' + [Guid]::NewGuid())
New-Item -ItemType Directory -Path (Join-Path $gmRun26 'scripts') | Out-Null
try {
    Copy-Item (Join-Path $repo 'windows-tune.ps1') $gmRun26
    Copy-Item (Join-Path $repo 'scripts\09-game-mode.ps1'), (Join-Path $repo 'scripts\09-game-mode.defaults.json') (Join-Path $gmRun26 'scripts')
    $hostilePath26 = Join-Path $gmRun26 'hostile.json'
    Set-Content -LiteralPath $hostilePath26 -Encoding ascii -Value '{ "games": ["cs2.exe"], "stopProcesses": [ {"name":"vgc"}, {"name":"lsass"}, {"name":"explorer.exe"} ], "stopServices": [ {"name":"vgk"}, {"name":"WinDefend"} ] }'
    $gmScript26 = Join-Path $gmRun26 'scripts\09-game-mode.ps1'
    $out26 = (& $ps -NoProfile -ExecutionPolicy Bypass -File $gmScript26 -DryRun -ConfigPath $hostilePath26) -join "`n"
    $exit26 = $LASTEXITCODE
    $refusedRun26 = ([regex]::Matches($out26, 'REFUSED ')).Count
    $written26 = @(Get-ChildItem (Join-Path $gmRun26 'scripts') -File | Where-Object { $_.Name -notin '09-game-mode.ps1', '09-game-mode.defaults.json' })
    if ($exit26 -eq 0 -and $out26 -match 'DRY RUN' -and $refusedRun26 -eq 5 -and $written26.Count -eq 0) { Pass '09 -DryRun with a hostile config: exit 0, 5 REFUSED lines, no file written' }
    else { Fail "09 -DryRun: exit $exit26, $refusedRun26 REFUSED, wrote [$($written26.Name -join ', ')]`n$out26" }
    $taskBefore26 = @(Get-ScheduledTask -TaskName 'windows-tune game mode' -ErrorAction SilentlyContinue).Count
    $out26 = (& $ps -NoProfile -ExecutionPolicy Bypass -File $gmScript26 -InstallWatcher -DryRun) -join "`n"
    $exit26 = $LASTEXITCODE
    $taskAfter26 = @(Get-ScheduledTask -TaskName 'windows-tune game mode' -ErrorAction SilentlyContinue).Count
    if ($exit26 -eq 4 -and $out26 -match 'REFUSED to install the watcher' -and $taskAfter26 -eq $taskBefore26) { Pass "09 -InstallWatcher from a user-writable folder: exit 4, refused, scheduled tasks unchanged ($taskAfter26)" }
    else { Fail "09 -InstallWatcher from a user-writable folder: exit $exit26, tasks $taskBefore26 -> $taskAfter26`n$out26" }
    if (-not $elevated) {
        # 2>&1 on a native command throws under ErrorActionPreference Stop in PowerShell 5.1, so relax it for this call only
        $out26 = (& { $ErrorActionPreference = 'Continue'; & $ps -NoProfile -ExecutionPolicy Bypass -File $gmScript26 -Watch 2>&1 }) -join "`n"
        if ($LASTEXITCODE -ne 0 -and $out26 -match 'elevated PowerShell') { Pass '09 -Watch without admin refuses before it watches anything' }
        else { Fail "09 -Watch without admin: exit $LASTEXITCODE`n$out26" }
    } else { Pass 'stage 26 -Watch refusal skipped: this gate is ELEVATED, and -Watch would really watch' }
} finally { Remove-Item -Recurse -Force $gmRun26 -ErrorAction SilentlyContinue }

# --- stage 27: automatic updates (10) are OFF by default, never install on a bad read, never during a game ----
# The pure functions of 10-auto-update.ps1 are dot-sourced (its guard returns before it touches anything) and
# CALLED with fixtures. Then the script is pressed from a scratch copy: it must refuse to switch updates on
# from a folder a normal program can write, and it must not write a file or register a task while Off.
$upd27 = Join-Path $repo 'scripts\10-auto-update.ps1'
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($upd27, [ref]$null, [ref]$errors)
if ($errors.Count) { Fail "10-auto-update.ps1 does not parse: $($errors[0].Message)" }
. $upd27
foreach ($fn27 in 'Read-UpdateMode', 'Test-GameRunning', 'Get-UpdateAction', 'Test-UpdateZipEntries') {
    if (-not (Get-Command $fn27 -ErrorAction SilentlyContinue)) { Fail "10-auto-update.ps1 has no $fn27 - stage 27 checked nothing" }
}
if (Get-Command Get-UpdateAction -ErrorAction SilentlyContinue) {
    $modeCases27 = @(
        @{ n = 'no file';            j = $null;                    w = 'Off' }
        @{ n = 'empty text';         j = '   ';                    w = 'Off' }
        @{ n = 'garbage';            j = '{not json';              w = 'Off' }
        @{ n = 'an unknown mode';    j = '{ "mode": "Bogus" }';    w = 'Off' }
        @{ n = 'no mode key';        j = '{ "x": 1 }';             w = 'Off' }
        @{ n = 'Check';              j = '{ "mode": "Check" }';    w = 'Check' }
        @{ n = 'Install';            j = '{ "mode": "Install" }';  w = 'Install' }
    )
    foreach ($c27 in $modeCases27) {
        $got27 = Read-UpdateMode $c27.j
        if ("$got27" -eq $c27.w) { Pass "Read-UpdateMode on $($c27.n) -> $got27" } else { Fail "Read-UpdateMode on $($c27.n) said '$got27', expected $($c27.w)" }
    }
    $gameCases27 = @(
        @{ n = 'a listed game is running';   g = @('cs2.exe', 'dota2.exe'); r = @('explorer', 'cs2');   w = $true }
        @{ n = 'no listed game is running';  g = @('cs2.exe', 'dota2.exe'); r = @('explorer', 'code');  w = $false }
        @{ n = 'a game list that is $null';  g = $null;                     r = @('code');              w = $true }
        @{ n = 'an empty game list';         g = @();                       r = @('code');              w = $true }
        @{ n = 'a process list that is $null'; g = @('cs2.exe');            r = $null;                  w = $true }
    )
    foreach ($c27 in $gameCases27) {
        $got27 = Test-GameRunning -Games $c27.g -Running $c27.r
        if ($got27 -eq $c27.w) { Pass "Test-GameRunning with $($c27.n) -> $got27" } else { Fail "Test-GameRunning with $($c27.n) said $got27, expected $($c27.w)" }
    }
    $newer27 = [pscustomobject]@{ Status = 'Newer'; Installed = 'v1.0.0'; Latest = 'v1.1.0' }
    $same27 = [pscustomobject]@{ Status = 'UpToDate' }
    $unk27 = [pscustomobject]@{ Status = 'Unknown' }
    $act27 = @(
        @{ n = 'Off with a newer release';                  m = 'Off';     v = $newer27; g = $false; s = $true;  w = 'Off' }
        @{ n = 'an unknown mode with a newer release';      m = 'Bogus';   v = $newer27; g = $false; s = $true;  w = 'Off' }
        @{ n = 'Check with a newer release';                m = 'Check';   v = $newer27; g = $false; s = $true;  w = 'Notify' }
        @{ n = 'Check, a newer release, safe folder (still only a notice)'; m = 'Check'; v = $newer27; g = $false; s = $true; w = 'Notify' }
        @{ n = 'Install, newer, safe folder, no game';      m = 'Install'; v = $newer27; g = $false; s = $true;  w = 'Install' }
        @{ n = 'Install, newer, safe folder, A GAME RUNNING'; m = 'Install'; v = $newer27; g = $true; s = $true; w = 'SkipGame' }
        @{ n = 'Check, a game running';                     m = 'Check';   v = $newer27; g = $true;  s = $true;  w = 'SkipGame' }
        @{ n = 'Install, newer, folder a program can write'; m = 'Install'; v = $newer27; g = $false; s = $false; w = 'SkipUnsafeFolder' }
        @{ n = 'Install, status UNKNOWN';                   m = 'Install'; v = $unk27;   g = $false; s = $true;  w = 'SkipUnknown' }
        @{ n = 'Install, no answer from GitHub';            m = 'Install'; v = $null;    g = $false; s = $true;  w = 'SkipUnknown' }
        @{ n = 'Install, already up to date';               m = 'Install'; v = $same27;  g = $false; s = $true;  w = 'UpToDate' }
    )
    foreach ($c27 in $act27) {
        $got27 = Get-UpdateAction -Mode $c27.m -Verdict $c27.v -GameRunning $c27.g -SafeToInstall $c27.s
        if ($got27 -eq $c27.w) { Pass "Get-UpdateAction on $($c27.n) -> $got27" } else { Fail "Get-UpdateAction on $($c27.n) said $got27, expected $($c27.w)" }
    }
    $good27 = @('windows-tune-v1.2.0/windows-tune.ps1', 'windows-tune-v1.2.0/install.ps1', 'windows-tune-v1.2.0/VERSION', 'windows-tune-v1.2.0/NOTICE.md', 'windows-tune-v1.2.0/scripts/10-auto-update.ps1', 'windows-tune-v1.2.0/LICENSE', 'windows-tune-v1.2.0/scripts/', 'windows-tune-v1.2.0/.gitignore', 'windows-tune-v1.2.0/.githooks/pre-commit', 'windows-tune-v1.2.0/labs/head-parallax/head_parallax.py', 'windows-tune-v1.2.0/privacy/telemetry-tune.ps1')   # the dotfile, hook and lab names are the real v1.1.0 layout
    $zipCases27 = @(
        @{ n = 'a normal release zip';     e = $good27;                                                   w = $false }
        @{ n = 'a ../ path';               e = $good27 + 'windows-tune-v1.2.0/../evil.ps1';               w = $true }
        @{ n = 'a backslash traversal';    e = $good27 + 'windows-tune-v1.2.0\..\..\evil.ps1';            w = $true }
        @{ n = 'an absolute path';         e = $good27 + '/etc/evil.ps1';                                 w = $true }
        @{ n = 'a drive path';             e = $good27 + 'C:\Windows\evil.ps1';                           w = $true }
        @{ n = 'an .exe inside';           e = $good27 + 'windows-tune-v1.2.0/scripts/payload.exe';       w = $true }
        @{ n = 'a .dll inside';            e = $good27 + 'windows-tune-v1.2.0/scripts/payload.dll';       w = $true }
        @{ n = 'two top-level folders';    e = $good27 + 'other/readme.md';                               w = $true }
        @{ n = 'no install.ps1';           e = @($good27 | Where-Object { $_ -notlike '*/install.ps1' }); w = $true }
        @{ n = 'no 10-auto-update.ps1';    e = @($good27 | Where-Object { $_ -notlike '*10-auto-update.ps1' }); w = $true }
        @{ n = 'an empty zip';             e = @();                                                       w = $true }
    )
    foreach ($c27 in $zipCases27) {
        $bad27 = Test-UpdateZipEntries -Names $c27.e -Tag 'v1.2.0'
        if ([bool]$bad27 -eq $c27.w) { Pass "Test-UpdateZipEntries on $($c27.n) -> $(if ($bad27) { 'refused' } else { 'accepted' })" } else { Fail "Test-UpdateZipEntries on $($c27.n): $(if ($bad27) { "refused ($bad27)" } else { 'accepted' }), expected $(if ($c27.w) { 'refused' } else { 'accepted' })" }
    }
}
# source facts a fixture cannot reach: the install path is the hash-checked one, nothing is piped to a shell,
# the game check runs again after the download, and a fresh install ships with nothing switched on.
$src27 = Get-Content $upd27 -Raw
$ast27 = [System.Management.Automation.Language.Parser]::ParseFile($upd27, [ref]$null, [ref]$null)
$iex27 = @($ast27.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'iex', 'Invoke-Expression' }, $true))
if ($iex27.Count -or $src27 -match 'DownloadString') { Fail '10-auto-update.ps1 calls Invoke-Expression or DownloadString' } else { Pass '10-auto-update.ps1 never calls Invoke-Expression (read from the syntax tree, not the comments)' }
if ($src27 -match '-FromZip \$zip -Sha256 \$Verdict\.Digest') { Pass '10 installs through install.ps1 -FromZip -Sha256 (the hash-checked path)' } else { Fail '10 does not install through install.ps1 -FromZip -Sha256' }
$instBody27 = if ($src27 -match '(?s)function Invoke-UpdateInstall(.*?)\nfunction Invoke-UpdateRun') { $Matches[1] } else { '' }
if (-not $instBody27) { Fail 'stage 27 could not find Invoke-UpdateInstall' }
elseif (([regex]::Matches($instBody27, 'Test-GameNow')).Count -ge 1 -and $instBody27.IndexOf('Test-GameNow') -gt $instBody27.IndexOf('Get-FileHash') -and $instBody27.IndexOf('Test-GameNow') -lt $instBody27.IndexOf('-FromZip')) { Pass '10 checks for a running game again after the download and before it installs' }
else { Fail '10 does not re-check for a running game between the download and the install' }
if (($src27 -match 'Get-ScheduledTask|Register-ScheduledTask') -and ((Get-Content (Join-Path $repo 'install.ps1') -Raw) -match 'windows-tune update|10-update-mode')) { Fail 'install.ps1 touches the update task or mode, so a fresh install would not be Off' } else { Pass 'install.ps1 does not switch updates on' }
if (Test-Path (Join-Path $repo 'scripts\10-update-mode.json')) { Fail 'scripts\10-update-mode.json is in the repo: a fresh install would not be Off' } else { Pass 'no update mode file ships in the repo (default is Off)' }
$gi27 = Get-Content (Join-Path $repo '.gitignore') -Raw
if ($gi27 -match '10-update-mode\.json' -and $gi27 -match '10-update-notice\.txt') { Pass '.gitignore keeps the update mode and notice out of commits' } else { Fail '.gitignore does not list 10-update-mode.json and 10-update-notice.txt' }
# press it, from a scratch copy that any program can write
$run27 = Join-Path $env:TEMP ('wt-update-' + [Guid]::NewGuid())
try {
    New-Item -ItemType Directory -Path (Join-Path $run27 'scripts') -Force | Out-Null
    foreach ($n27 in 'windows-tune.ps1', 'install.ps1', 'VERSION') { Copy-Item (Join-Path $repo $n27) $run27 }
    foreach ($n27 in '10-auto-update.ps1', '07-update-check.ps1', '09-game-mode.defaults.json') { Copy-Item (Join-Path $repo "scripts\$n27") (Join-Path $run27 'scripts') }
    $s27 = Join-Path $run27 'scripts\10-auto-update.ps1'
    $out27 = (& { $ErrorActionPreference = 'Continue'; & $ps -NoProfile -ExecutionPolicy Bypass -File $s27 2>&1 }) -join "`n"
    if ($LASTEXITCODE -eq 0 -and $out27 -match 'Update mode: Off' -and $out27 -match 'not registered') { Pass '10 (no arguments) reports Off and no task' } else { Fail "10 status: exit $LASTEXITCODE`n$out27" }
    $taskBefore27 = @(Get-ScheduledTask -TaskName 'windows-tune update' -ErrorAction SilentlyContinue).Count
    $out27 = (& { $ErrorActionPreference = 'Continue'; & $ps -NoProfile -ExecutionPolicy Bypass -File $s27 -SetMode Check -DryRun 2>&1 }) -join "`n"
    $exit27 = $LASTEXITCODE
    $taskAfter27 = @(Get-ScheduledTask -TaskName 'windows-tune update' -ErrorAction SilentlyContinue).Count
    if ($exit27 -eq 4 -and $out27 -match 'REFUSED to turn updates on' -and $taskAfter27 -eq $taskBefore27) { Pass "10 -SetMode Check from a user-writable folder: exit 4, refused, tasks unchanged ($taskAfter27)" }
    else { Fail "10 -SetMode Check from a user-writable folder: exit $exit27, tasks $taskBefore27 -> $taskAfter27`n$out27" }
    $out27 = (& { $ErrorActionPreference = 'Continue'; & $ps -NoProfile -ExecutionPolicy Bypass -File $s27 -SetMode Install 2>&1 }) -join "`n"
    if ($LASTEXITCODE -ne 0 -and $out27 -match '-Yes') { Pass '10 -SetMode Install without -Yes refuses and names -Yes' } else { Fail "10 -SetMode Install without -Yes: exit $LASTEXITCODE`n$out27" }
    $out27 = (& { $ErrorActionPreference = 'Continue'; & $ps -NoProfile -ExecutionPolicy Bypass -File $s27 -Run 2>&1 }) -join "`n"
    $made27 = @(Get-ChildItem (Join-Path $run27 'scripts') -File | Where-Object { $_.Name -notin '10-auto-update.ps1', '07-update-check.ps1', '09-game-mode.defaults.json' })
    if ($LASTEXITCODE -eq 0 -and $out27 -match 'updates are off' -and $made27.Count -eq 0) { Pass '10 -Run while Off: nothing checked, no file written' } else { Fail "10 -Run while Off: exit $LASTEXITCODE, wrote [$($made27.Name -join ', ')]`n$out27" }
    # a saved Check mode with a game running must skip, and say so
    Set-Content -LiteralPath (Join-Path $run27 'scripts\10-update-mode.json') -Value '{ "mode": "Check" }' -Encoding ascii
    $psi27 = New-Object System.Diagnostics.ProcessStartInfo
    $psi27.FileName = Join-Path $env:SystemRoot 'System32\ping.exe'
    $psi27.Arguments = '-n 30 127.0.0.1'
    $psi27.CreateNoWindow = $true
    $psi27.UseShellExecute = $false
    $hold27 = [System.Diagnostics.Process]::Start($psi27)
    try {
        Set-Content -LiteralPath (Join-Path $run27 'scripts\09-game-mode.json') -Value '{ "games": ["ping.exe"] }' -Encoding ascii
        $out27 = (& { $ErrorActionPreference = 'Continue'; & $ps -NoProfile -ExecutionPolicy Bypass -File $s27 -Run -DryRun 2>&1 }) -join "`n"
        if ($LASTEXITCODE -eq 0 -and $out27 -match 'mode Check -> SkipGame' -and $out27 -match 'A game is running') { Pass '10 -Run in Check mode with a listed game running: skipped, said so' } else { Fail "10 -Run with a game running: exit $LASTEXITCODE`n$out27" }
    } finally { try { $hold27.Kill() } catch { } }
} finally { Remove-Item -Recurse -Force $run27 -ErrorAction SilentlyContinue }

# --- stage 28: telemetry-tune plans only what Microsoft's docs support, and refuses a policy it did not set ----
$tt28 = Join-Path $repo 'privacy\telemetry-tune.ps1'
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($tt28, [ref]$null, [ref]$errors)
if ($errors.Count) { Fail "telemetry-tune.ps1 does not parse: $($errors[0].Message)" }
. $tt28
if (-not (Get-Command Get-TelemetryPlan -ErrorAction SilentlyContinue)) { Fail 'telemetry-tune.ps1 has no Get-TelemetryPlan - stage 28 checked nothing' }
else {
    $edCases28 = @(@('Professional', 1), @('Core', 1), @('CoreSingleLanguage', 1), @('Enterprise', 0), @('Education', 0), @('ServerStandard', 0))
    foreach ($e28 in $edCases28) {
        $g28 = Get-TelemetryTarget $e28[0]
        if ($g28 -eq $e28[1]) { Pass "Get-TelemetryTarget($($e28[0])) -> $g28" } else { Fail "Get-TelemetryTarget($($e28[0])) said $g28, expected $($e28[1])" }
    }
    function Get-Act28($plan, $id) { ($plan | Where-Object { $_.Id -eq $id }).Action }
    $blank28 = @{ 'telemetry-policy' = $null; 'activity-feed' = $null; 'advertising-id' = $null; 'tailored' = $null; 'svc-diagtrack' = 'Automatic'; 'svc-dmwappush' = 'Manual' }
    $p28 = @(Get-TelemetryPlan -Current $blank28 -EditionId 'Professional')
    if ($p28.Count -eq 4 -and (@($p28 | Where-Object { $_.Action -eq 'Set' }).Count -eq 4) -and ($p28 | Where-Object { $_.Id -eq 'telemetry-policy' }).Target -eq 1) { Pass 'a default Pro PC: four settings to set, diagnostic policy target 1 (Required), no service rows' }
    else { Fail "default Pro plan wrong: $(($p28 | ForEach-Object { "$($_.Id)=$($_.Action)/$($_.Target)" }) -join ' ')" }
    $p28 = @(Get-TelemetryPlan -Current $blank28 -EditionId 'Enterprise')
    if (($p28 | Where-Object { $_.Id -eq 'telemetry-policy' }).Target -eq 0) { Pass 'Enterprise gets diagnostic policy target 0' } else { Fail 'Enterprise did not get target 0' }
    $cur28 = $blank28.Clone(); $cur28['telemetry-policy'] = 0
    if ((Get-Act28 (Get-TelemetryPlan -Current $cur28 -EditionId 'Professional') 'telemetry-policy') -eq 'AtTarget') { Pass 'a policy already stricter than the target (0 on Pro) is left alone' } else { Fail 'a stricter policy was not left alone' }
    $cur28['telemetry-policy'] = 3
    if ((Get-Act28 (Get-TelemetryPlan -Current $cur28 -EditionId 'Professional') 'telemetry-policy') -eq 'Refuse') { Pass 'a policy somebody else set to 3 is refused, not overwritten' } else { Fail 'a foreign policy value was not refused' }
    $cur28 = $blank28.Clone(); $cur28['advertising-id'] = 1
    if ((Get-Act28 (Get-TelemetryPlan -Current $cur28 -EditionId 'Professional') 'advertising-id') -eq 'Set') { Pass 'advertising ID on -> Set' } else { Fail 'advertising ID on was not planned' }
    $cur28['advertising-id'] = 0
    if ((Get-Act28 (Get-TelemetryPlan -Current $cur28 -EditionId 'Professional') 'advertising-id') -eq 'AtTarget') { Pass 'advertising ID already off -> AtTarget' } else { Fail 'advertising ID off was not AtTarget' }
    $s28 = @(Get-TelemetryPlan -Current $blank28 -EditionId 'Professional' -ServicesOnly $true)
    if ($s28.Count -eq 2 -and (@($s28 | Where-Object { $_.Action -eq 'Set' }).Count -eq 2)) { Pass '-ServicesOnly plans only the two services' } else { Fail "-ServicesOnly plan wrong: $(($s28 | ForEach-Object { "$($_.Id)=$($_.Action)" }) -join ' ')" }
    $cur28 = $blank28.Clone(); $cur28['svc-diagtrack'] = 'Disabled'; $cur28['svc-dmwappush'] = $null
    $s28 = @(Get-TelemetryPlan -Current $cur28 -EditionId 'Professional' -ServicesOnly $true)
    if ((Get-Act28 $s28 'svc-diagtrack') -eq 'AtTarget' -and (Get-Act28 $s28 'svc-dmwappush') -eq 'Skip') { Pass 'a disabled service is AtTarget and a missing service is skipped' } else { Fail 'service AtTarget/Skip wrong' }
}
$ttSrc28 = Get-Content $tt28 -Raw
if ($ttSrc28 -match '(?s)ConvertTo-Json.*Set-ItemProperty -Path \$r\.Path') { Pass 'telemetry-tune writes its state file before the first registry write' } else { Fail 'telemetry-tune does not record state before writing' }
$tp28 = Join-Path $env:TEMP ('wt-telem-' + [Guid]::NewGuid())
try {
    New-Item -ItemType Directory -Path $tp28 | Out-Null
    Copy-Item $tt28 $tp28
    $out28 = (& { $ErrorActionPreference = 'Continue'; & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tp28 'telemetry-tune.ps1') -DryRun 2>&1 }) -join "`n"
    $made28 = @(Get-ChildItem $tp28 -File | Where-Object { $_.Name -ne 'telemetry-tune.ps1' })
    if ($LASTEXITCODE -in 0, 1 -and $out28 -match 'Windows edition' -and $made28.Count -eq 0) { Pass "telemetry-tune -DryRun ran unelevated (exit $LASTEXITCODE) and wrote no file" } else { Fail "telemetry-tune -DryRun: exit $LASTEXITCODE, wrote [$($made28.Name -join ', ')]`n$out28" }
    if (-not $elevated) {
        $out28 = (& { $ErrorActionPreference = 'Continue'; & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tp28 'telemetry-tune.ps1') 2>&1 }) -join "`n"
        $made28 = @(Get-ChildItem $tp28 -File | Where-Object { $_.Name -ne 'telemetry-tune.ps1' })
        if ($LASTEXITCODE -ne 0 -and $out28 -match 'elevated PowerShell' -and $made28.Count -eq 0) { Pass 'telemetry-tune without admin refuses before it writes anything' } else { Fail "telemetry-tune without admin: exit $LASTEXITCODE, wrote [$($made28.Name -join ', ')]`n$out28" }
    } else { Pass 'stage 28 unelevated refusal skipped: this gate is ELEVATED' }
} finally { Remove-Item -Recurse -Force $tp28 -ErrorAction SilentlyContinue }

# --- stage 29: the Recommended view only recommends what the audit found, and pre-ticks only the safe ones ----
$rec29 = Join-Path $repo 'scripts\11-recommended.ps1'
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($rec29, [ref]$null, [ref]$errors)
if ($errors.Count) { Fail "11-recommended.ps1 does not parse: $($errors[0].Message)" }
. $rec29
if (-not (Get-Command Get-Recommendations -ErrorAction SilentlyContinue)) { Fail '11-recommended.ps1 has no Get-Recommendations - stage 29 checked nothing' }
else {
    function Get-Ids29($lines) { $r = Get-Recommendations $lines; if ($null -eq $r) { '<null>' } else { (@($r) | ForEach-Object { $_.Id }) -join ',' } }
    $allOk29 = @('  ok         Language list hidden = 1', '  ok         Advertising ID = 0')
    if ((Get-Ids29 $allOk29) -eq '') { Pass 'an audit with nothing wrong recommends nothing (empty, not null)' } else { Fail "an all-ok audit recommended: $(Get-Ids29 $allOk29)" }
    if ((Get-Ids29 @('garbage', '')) -eq '<null>') { Pass 'an audit that read nothing returns null, never an empty all-clear' } else { Fail 'an unreadable audit did not return null' }
    if ((Get-Ids29 @('  DRIFT      Advertising ID = 1, expected 0')) -eq 'telemetry-ads') { Pass 'drifted advertising ID -> telemetry-ads' } else { Fail 'drifted advertising ID did not give telemetry-ads' }
    if ((Get-Ids29 @('  UNREADABLE Telemetry policy - expected 0, value absent')) -eq 'telemetry-ads') { Pass 'an absent telemetry policy (Windows default) -> telemetry-ads' } else { Fail 'an absent telemetry policy was not recommended' }
    if ((Get-Ids29 @('  UNREADABLE Edge 3p cookies blocked - expected 1, value absent')) -eq '') { Pass 'an unreadable Edge value (Edge not installed) is NOT recommended' } else { Fail 'an unreadable Edge value was recommended' }
    $r29 = Get-Recommendations @('  DRIFT      DiagTrack start type = Automatic, expected Disabled', '  DRIFT      Language list hidden = 0, expected 1', '  DRIFT      Chrome 3p cookies blocked = 0, expected 1', '  DRIFT      DoH auto-upgrade 1.1.1.1 = False, expected True')
    $r29 = @($r29)
    $pre29 = ($r29 | Where-Object { $_.PreTicked } | ForEach-Object { $_.Id }) -join ','
    if ($r29.Count -eq 4 -and $pre29 -eq 'language-list') { Pass 'of four mixed findings only the safe one (language list) is pre-ticked' } else { Fail "pre-ticked set wrong: [$pre29] of $($r29.Count)" }
    foreach ($row29 in $CATALOGUE) {
        $blank29 = @('What', 'Risk', 'Undo', 'Source', 'Title') | Where-Object { [string]::IsNullOrWhiteSpace($row29[$_]) }
        if ($blank29) { Fail "catalogue row $($row29.Id) has no $($blank29 -join ', ')" }
        elseif ($row29.Safe -and $row29.Source -match 'NOT FOUND') { Fail "catalogue row $($row29.Id) is pre-ticked but its source says NOT FOUND" }
        else { Pass "catalogue row $($row29.Id): what, risk, undo and source stated$(if ($row29.Safe) { ' (safe, pre-ticked)' } else { ' (not pre-ticked)' })" }
    }
}
$out29 = (& { $ErrorActionPreference = 'Continue'; & $ps -NoProfile -ExecutionPolicy Bypass -File $rec29 -Json 2>&1 }) -join "`n"
$json29 = $null; try { $json29 = $out29 | ConvertFrom-Json } catch { }
if ($LASTEXITCODE -eq 0 -and $null -ne $json29 -or ($LASTEXITCODE -eq 0 -and $out29.Trim() -eq '[]')) { Pass '11 -Json against this PC returns parseable JSON' } else { Fail "11 -Json: exit $LASTEXITCODE`n$out29" }
# the click-install window ticks rows by menu key, and every key it can recommend has a row there and a menu row
$guiAst29 = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'windows-tune-gui.ps1'), [ref]$null, [ref]$null)
$rowsFn29 = $guiAst29.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-RecommendedRows' }, $true)
if (-not $rowsFn29) { Fail 'windows-tune-gui.ps1 has no Get-RecommendedRows - stage 29 checked nothing' }
else {
    . ([scriptblock]::Create($rowsFn29.Extent.Text))
    $defs29 = @(@{ Args = '-Choice 1 -AcceptRisk -NoElevate' }, @{ Args = '-Choice T' }, @{ Args = '-Choice L' }, @{ Args = '-Choice Y' })
    $recs29 = @([pscustomobject]@{ Key = 'T'; PreTicked = $true }, [pscustomobject]@{ Key = 'Y'; PreTicked = $false }, [pscustomobject]@{ Key = 'Q'; PreTicked = $true })
    $got29 = (Get-RecommendedRows -Recommendations $recs29 -Defs $defs29) -join ','
    if ($got29 -eq '1') { Pass 'Get-RecommendedRows ticks only the pre-ticked row that exists (row 1), not the unsafe Y nor the unknown key' } else { Fail "Get-RecommendedRows gave [$got29], expected 1" }
    $gotAll29 = (Get-RecommendedRows -Recommendations $recs29 -Defs $defs29 -All) -join ','
    if ($gotAll29 -eq '1,3') { Pass 'Get-RecommendedRows -All ticks T and Y (the person chose them)' } else { Fail "Get-RecommendedRows -All gave [$gotAll29], expected 1,3" }
    $guiText29 = Get-Content (Join-Path $repo 'windows-tune-gui.ps1') -Raw
    $menuText29 = Get-Content (Join-Path $repo 'windows-tune.ps1') -Raw
    foreach ($row29 in $CATALOGUE) {
        $k29 = $row29.Key
        if ($guiText29 -match "Args = '-Choice $k29'" -and $menuText29 -match "(?m)^\s*'$k29' = @\{ name = '[^']+\.ps1'") { Pass "recommended change $($row29.Id) (key $k29) has a menu row and a click-install row" } else { Fail "recommended change $($row29.Id) (key $k29) is missing from the menu or the click-install window" }
    }
    $ro29 = [regex]::Match($guiText29, '\[int\[\]\]\$ReadOnly = @\(([0-9, ]+)\)').Groups[1].Value -split ',' | ForEach-Object { [int]$_.Trim() }
    $labelsRO29 = @(); $i29 = 0
    foreach ($m29 in [regex]::Matches($guiText29, "Label = '([^']+)';\s+Args = '-Choice ([0-9A-Z])")) {
        $i29++
        $line29 = ($menuText29 -split "`n") | Where-Object { $_ -match "^\s*'$($m29.Groups[2].Value)' = " } | Out-String
        $isRO29 = ($line29 -match "changes = ''")
        if ($isRO29 -and $ro29 -notcontains $i29) { Fail "GUI row $i29 (menu $($m29.Groups[2].Value)) is read-only in the menu but not in Get-OptionPlan's ReadOnly list" }
        if (-not $isRO29 -and $ro29 -contains $i29) { Fail "GUI row $i29 (menu $($m29.Groups[2].Value)) changes the machine but Get-OptionPlan treats it as read-only" }
    }
    Pass "Get-OptionPlan's ReadOnly rows ($($ro29 -join ',')) were compared with every menu row"
}

# --- stage 30: Install mode refuses without a valid release signature (missing .sig, wrong key, tampered zip) ----
# Real RSA keys are made in temp folders by tools\new-signing-key.ps1 (never in a repo, never the real key dir),
# a fixture zip is signed by tools\sign-release.ps1, and Test-ReleaseSignature is CALLED on every shape of failure.
$nk30 = Join-Path $repo 'tools\new-signing-key.ps1'
$sr30 = Join-Path $repo 'tools\sign-release.ps1'
foreach ($f30 in $nk30, $sr30) {
    if (-not (Test-Path $f30)) { Fail "$f30 is missing - stage 30 checked nothing"; continue }
    $e30 = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($f30, [ref]$null, [ref]$e30)
    if ($e30.Count) { Fail "$(Split-Path -Leaf $f30) does not parse: $($e30[0].Message)" }
    if ((Get-Content $f30 -Raw) -match '[^\x00-\x7F]') { Fail "$(Split-Path -Leaf $f30) has non-ASCII characters" }
}
$t30 = Join-Path $env:TEMP ('wt-sig-' + [Guid]::NewGuid())
try {
    New-Item -ItemType Directory -Path $t30 | Out-Null
    $pubA = Join-Path $t30 'a.pub.xml'; $pubB = Join-Path $t30 'b.pub.xml'
    $outA = (& { $ErrorActionPreference = 'Continue'; & $ps -NoProfile -ExecutionPolicy Bypass -File $nk30 -KeyDir (Join-Path $t30 'keyA') -WritePublicKeyTo $pubA 2>&1 }) -join "`n"
    $exitA = $LASTEXITCODE
    $outB = (& { $ErrorActionPreference = 'Continue'; & $ps -NoProfile -ExecutionPolicy Bypass -File $nk30 -KeyDir (Join-Path $t30 'keyB') -WritePublicKeyTo $pubB 2>&1 }) -join "`n"
    if ($exitA -eq 0 -and (Test-Path $pubA) -and (Test-Path $pubB) -and $outA -match 'FINGERPRINT') { Pass 'new-signing-key.ps1 made two key pairs and printed a fingerprint' } else { Fail "new-signing-key.ps1: exit $exitA`n$outA" }
    # nothing private is printed or written to the public file
    $privHit30 = ($outA + $outB + (Get-Content $pubA -Raw) + (Get-Content $pubB -Raw)) -match '<(D|P|Q|DP|DQ|InverseQ)>'
    if (-not $privHit30) { Pass 'new-signing-key.ps1 prints and writes no private key parts' } else { Fail 'new-signing-key.ps1 leaked private key parts (D, P, Q ...)' }
    $privFile30 = Join-Path $t30 'keyA\private.dpapi'
    $head30 = [IO.File]::ReadAllBytes($privFile30)[0..3] -join ','
    if ($head30 -eq '1,0,0,0' -and ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($privFile30)) -notmatch '<RSAKeyValue')) { Pass 'the private key file is a DPAPI blob, not readable XML' } else { Fail "the private key file is not DPAPI-protected (header $head30)" }
    # never overwrite, never inside a git tree
    $again30 = (& { $ErrorActionPreference = 'Continue'; & $ps -NoProfile -ExecutionPolicy Bypass -File $nk30 -KeyDir (Join-Path $t30 'keyA') 2>&1 }) -join "`n"
    if ($LASTEXITCODE -ne 0 -and $again30 -match 'never overwritten') { Pass 'new-signing-key.ps1 refuses to overwrite an existing key' } else { Fail "overwrite not refused: exit $LASTEXITCODE`n$again30" }
    $inTree30 = Join-Path $repo 'wt-test-keydir-should-not-exist'
    $tree30 = (& { $ErrorActionPreference = 'Continue'; & $ps -NoProfile -ExecutionPolicy Bypass -File $nk30 -KeyDir $inTree30 2>&1 }) -join "`n"
    if ($LASTEXITCODE -ne 0 -and $tree30 -match 'inside a git working tree' -and -not (Test-Path $inTree30)) { Pass 'new-signing-key.ps1 refuses a key folder inside a git tree and creates nothing' } else { Fail "in-tree key folder not refused: exit $LASTEXITCODE`n$tree30"; Remove-Item -Recurse -Force $inTree30 -ErrorAction SilentlyContinue }

    # sign a fixture zip with key A
    $payload30 = Join-Path $t30 'payload.txt'; Set-Content $payload30 'windows-tune fixture' -Encoding ascii
    $zip30 = Join-Path $t30 'fixture.zip'; Compress-Archive -Path $payload30 -DestinationPath $zip30
    $so30 = (& { $ErrorActionPreference = 'Continue'; & $ps -NoProfile -ExecutionPolicy Bypass -File $sr30 -Zip $zip30 -KeyDir (Join-Path $t30 'keyA') 2>&1 }) -join "`n"
    $sigPath30 = "$zip30.sig"
    if ($LASTEXITCODE -eq 0 -and (Test-Path $sigPath30)) { Pass 'sign-release.ps1 wrote a .sig' } else { Fail "sign-release.ps1: exit $LASTEXITCODE`n$so30" }
    $pkA = Get-Content $pubA -Raw; $pkB = Get-Content $pubB -Raw
    $sig30 = if (Test-Path $sigPath30) { Get-Content $sigPath30 -Raw } else { '' }
    $bytes30 = [IO.File]::ReadAllBytes($zip30)
    $tampered30 = $bytes30.Clone(); $tampered30[$tampered30.Length - 5] = $tampered30[$tampered30.Length - 5] -bxor 0xFF
    $otherSig30 = ''
    $zipB30 = Join-Path $t30 'fixtureB.zip'; Copy-Item $zip30 $zipB30
    [void](& { $ErrorActionPreference = 'Continue'; & $ps -NoProfile -ExecutionPolicy Bypass -File $sr30 -Zip $zipB30 -KeyDir (Join-Path $t30 'keyB') 2>&1 })
    if (Test-Path "$zipB30.sig") { $otherSig30 = Get-Content "$zipB30.sig" -Raw }
    $sigCases30 = @(
        @{ n = 'a good signature, right key';              z = $bytes30;    s = $sig30;                 k = $pkA; ok = $true  }
        @{ n = 'a MISSING .sig (null)';                    z = $bytes30;    s = $null;                  k = $pkA; ok = $false }
        @{ n = 'a MISSING .sig (empty)';                   z = $bytes30;    s = '   ';                  k = $pkA; ok = $false }
        @{ n = 'the WRONG key (signed by B, shipped A)';   z = $bytes30;    s = $otherSig30;            k = $pkA; ok = $false }
        @{ n = 'the WRONG key (signed by A, shipped B)';   z = $bytes30;    s = $sig30;                 k = $pkB; ok = $false }
        @{ n = 'a TAMPERED zip';                           z = $tampered30; s = $sig30;                 k = $pkA; ok = $false }
        @{ n = 'a signature that is not base64';           z = $bytes30;    s = '!!not base64!!';       k = $pkA; ok = $false }
        @{ n = 'base64 that is not a signature';           z = $bytes30;    s = 'AAAA';                 k = $pkA; ok = $false }
        @{ n = 'an oversize signature file';               z = $bytes30;    s = ('A' * 5000);           k = $pkA; ok = $false }
        @{ n = 'NO shipped public key (null)';             z = $bytes30;    s = $sig30;                 k = $null; ok = $false }
        @{ n = 'a shipped key file that is not a key';     z = $bytes30;    s = $sig30;                 k = '<RSAKeyValue>nope</RSAKeyValue>'; ok = $false }
        @{ n = 'a shipped key file holding private parts'; z = $bytes30;    s = $sig30;                 k = ($pkA -replace '</RSAKeyValue>', '<D>AAAA</D></RSAKeyValue>'); ok = $false }
        @{ n = 'an empty zip';                             z = [byte[]]@();  s = $sig30;                 k = $pkA; ok = $false }
    )
    foreach ($c30 in $sigCases30) {
        $why30 = Test-ReleaseSignature -ZipBytes $c30.z -SignatureText $c30.s -PublicKeyXml $c30.k
        if ([bool]($null -eq $why30) -eq $c30.ok) { Pass "Test-ReleaseSignature on $($c30.n) -> $(if ($why30) { 'refused' } else { 'accepted' })" }
        else { Fail "Test-ReleaseSignature on $($c30.n): $(if ($why30) { "refused ($why30)" } else { 'accepted' }), expected $(if ($c30.ok) { 'accepted' } else { 'refused' })" }
    }
    $fpA30 = Get-KeyFingerprint $pkA; $fpB30 = Get-KeyFingerprint $pkB
    if ($fpA30 -match '^[0-9a-f]{64}$' -and $fpA30 -ne $fpB30 -and -not (Get-KeyFingerprint $null) -and -not (Get-KeyFingerprint 'junk')) { Pass 'Get-KeyFingerprint: 64 hex for a key, different per key, $null for nothing or junk' } else { Fail 'Get-KeyFingerprint wrong' }
} finally { Remove-Item -Recurse -Force $t30 -ErrorAction SilentlyContinue }

# no key, no Install: the action and the mode switch both refuse
$newer30 = [pscustomobject]@{ Status = 'Newer'; Installed = 'v1.0.0'; Latest = 'v1.2.0' }
$a30 = Get-UpdateAction -Mode 'Install' -Verdict $newer30 -GameRunning $false -SafeToInstall $true -KeyShipped $false
if ($a30 -eq 'SkipNoKey') { Pass 'Get-UpdateAction: Install, newer, safe, NO shipped key -> SkipNoKey' } else { Fail "Get-UpdateAction without a key said $a30" }
$a30 = Get-UpdateAction -Mode 'Check' -Verdict $newer30 -GameRunning $false -SafeToInstall $true -KeyShipped $false
if ($a30 -eq 'Notify') { Pass 'Get-UpdateAction: Check needs no key -> Notify' } else { Fail "Get-UpdateAction Check without a key said $a30" }
$run30 = Join-Path $env:TEMP ('wt-nokey-' + [Guid]::NewGuid())
try {
    New-Item -ItemType Directory -Path (Join-Path $run30 'scripts') -Force | Out-Null
    foreach ($n30 in 'windows-tune.ps1', 'install.ps1', 'VERSION') { Copy-Item (Join-Path $repo $n30) $run30 }
    foreach ($n30 in '10-auto-update.ps1', '07-update-check.ps1') { Copy-Item (Join-Path $repo "scripts\$n30") (Join-Path $run30 'scripts') }
    $o30 = (& { $ErrorActionPreference = 'Continue'; & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $run30 'scripts\10-auto-update.ps1') -SetMode Install -Yes -DryRun 2>&1 }) -join "`n"
    if ($LASTEXITCODE -eq 5 -and $o30 -match 'ships no release signing key') { Pass '10 -SetMode Install on a copy with no key: exit 5, refused' } else { Fail "10 -SetMode Install with no key: exit $LASTEXITCODE`n$o30" }
} finally { Remove-Item -Recurse -Force $run30 -ErrorAction SilentlyContinue }

# the verdict carries the .sig URL only from this repo's release page
$ast30 = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\07-update-check.ps1'), [ref]$null, [ref]$null)
$vf30 = $ast30.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-UpdateVerdict' }, $true)
. ([scriptblock]::Create($vf30.Extent.Text))
$base30 = 'https://github.com/treforged/windows-tune/releases/download/v1.2.0/'
$dg30 = 'sha256:' + ('ab' * 32)
function New-Rel30($sigUrl) {
    $assets = @([pscustomobject]@{ name = 'windows-tune-v1.2.0.zip'; digest = $dg30; browser_download_url = $base30 + 'windows-tune-v1.2.0.zip' })
    if ($sigUrl) { $assets += [pscustomobject]@{ name = 'windows-tune-v1.2.0.zip.sig'; digest = $null; browser_download_url = $sigUrl } }
    [pscustomobject]@{ tag_name = 'v1.2.0'; assets = $assets }
}
$vs30 = (Get-UpdateVerdict -Installed 'v1.1.0' -Latest (New-Rel30 ($base30 + 'windows-tune-v1.2.0.zip.sig'))).SigUrl
if ($vs30 -eq ($base30 + 'windows-tune-v1.2.0.zip.sig')) { Pass 'Get-UpdateVerdict returns the .sig URL from this repo release' } else { Fail "Get-UpdateVerdict SigUrl was [$vs30]" }
if (-not (Get-UpdateVerdict -Installed 'v1.1.0' -Latest (New-Rel30 'https://example.invalid/x.sig')).SigUrl) { Pass 'Get-UpdateVerdict drops a .sig URL that is off this repo' } else { Fail 'Get-UpdateVerdict kept an off-repo .sig URL' }
$vn30 = Get-UpdateVerdict -Installed 'v1.1.0' -Latest (New-Rel30 $null)
if ($vn30.Status -eq 'Newer' -and -not $vn30.SigUrl) { Pass 'a release with no .sig is still Newer for Check, with no SigUrl for Install' } else { Fail 'unsigned release verdict wrong' }

# source facts: the install path checks the signature with the SHIPPED key, after the hash and before anything is installed;
# no private key part is anywhere in the repo.
$src30 = Get-Content (Join-Path $repo 'scripts\10-auto-update.ps1') -Raw
$ib30 = if ($src30 -match '(?s)function Invoke-UpdateInstall(.*?)\nfunction Invoke-UpdateRun') { $Matches[1] } else { '' }
$iH = $ib30.IndexOf('Get-FileHash'); $iS = $ib30.IndexOf('Test-ReleaseSignature'); $iF = $ib30.IndexOf('-FromZip'); $iC = $ib30.IndexOf('Copy-Item -LiteralPath $root')
if ($iH -ge 0 -and $iS -gt $iH -and $iF -gt $iS -and $iC -gt $iS -and $ib30 -match 'PublicKeyXml \(Get-ShippedKey\)') { Pass 'Install verifies the signature with the shipped key, after the hash and before the backup and the install' } else { Fail 'Install does not verify the signature in the right place' }
$leak30 = @(Get-ChildItem $repo -Recurse -File | Where-Object { $_.FullName -notmatch '\\(\.git|tests)\\' -and $_.Extension -in '.xml', '.ps1', '.md', '.json' } | Select-String -Pattern '<(D|DP|DQ|InverseQ)>[A-Za-z0-9+/=]{20,}' -List)
if ($leak30.Count -eq 0) { Pass 'no private key part appears anywhere in the repo' } else { Fail "private key parts in: $($leak30.Filename -join ', ')" }
$shipped30 = Join-Path $repo 'scripts\update-pubkey.xml'
if (Test-Path $shipped30) {
    $sk30 = Get-Content $shipped30 -Raw
    if ($sk30 -notmatch '<(D|P|Q|DP|DQ|InverseQ)>' -and (Get-KeyFingerprint $sk30)) { Pass "scripts\update-pubkey.xml is a public-only RSA key (fingerprint $(Get-KeyFingerprint $sk30))" } else { Fail 'scripts\update-pubkey.xml is not a valid public-only key' }
} else { Pass 'scripts\update-pubkey.xml is not in the repo yet: Install mode stays unavailable until the maintainer ships the public key' }

if ($fails.Count) { Write-Host "`n$($fails.Count) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "`nall green" -ForegroundColor Green
exit 0
