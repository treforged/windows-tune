<#
.SYNOPSIS
    Game mode: while a game you list is running, pause the background work you
    list, then put it back the moment the game exits.

.DESCRIPTION
    Everything game mode touches comes from a JSON config, and every entry is
    opt-in. With the shipped defaults it only caps the UPLOAD rate of common
    cloud-sync apps (OneDrive, Google Drive, Dropbox) with a Windows QoS policy
    while a game runs. A QoS cap kills nothing and interrupts no sync; it lives
    in the ActiveStore, so a reboot clears it too. Stopping programs, stopping
    services and shutting WSL down are in the config as examples, switched OFF.

    -Watch       Watch for a listed game. When one starts, apply the config;
                 when the last one exits, undo exactly what was applied.
                 Runs until you close the window or press Ctrl+C (Ctrl+C undoes
                 first). Needs admin.
    -DryRun      Print what game mode would do right now and change nothing.
                 Works without admin. With no other switch this is the default.
    -InstallWatcher  OPT-IN persistence: register a scheduled task that runs
                 -Watch, hidden, at every sign-in. Refused from a folder a
                 normal program can write (see windows-tune.ps1). Writes
                 09-game-mode-watcher-revert.ps1 first. Needs admin.
    -RemoveWatcher   Remove that task, and undo game mode if it was left on.

    NEVER TOUCHED, whatever the config says: anti-cheat (Vanguard vgc/vgk,
    EasyAntiCheat, BattlEye, FACEIT, Ricochet, PunkBuster, ...), Windows'
    own system processes and services (csrss, wininit, lsass, services, smss,
    winlogon, svchost, explorer, dwm, ...), Defender and Windows Security, and
    any program on your own game list. Those entries print REFUSED and are
    skipped. The list is in Test-GameModeProtected below and is not configurable
    on purpose.

    Before it changes anything it writes 09-game-mode-revert.ps1 (for a human,
    menu R) and 09-game-mode-state.json (for the watcher), naming only what it
    is about to change. After applying it rewrites both with only what it
    actually changed, read back off the machine. Both files exist exactly while
    game mode is on, and are removed once everything is put back. If a watcher
    is killed mid-game, the next -Watch or -RemoveWatcher puts things back from
    the state file first.

.PARAMETER ConfigPath
    A config file to use instead of 09-game-mode.json (your own, beside this
    script) or, when that does not exist, 09-game-mode.defaults.json.

.EXAMPLE
    .\09-game-mode.ps1 -DryRun

.EXAMPLE
    .\09-game-mode.ps1 -Watch

.NOTES
    Programs it stopped are started again through explorer.exe, so they come
    back with your normal rights, not the watcher's admin rights. A program is
    asked to close first; it is killed only when its entry says "force": true.
    Undo: run 09-game-mode-revert.ps1 elevated (menu R), and for the watcher
    09-game-mode-watcher-revert.ps1 or -RemoveWatcher.
#>
[CmdletBinding()]
param(
    [switch]$Watch,
    [switch]$InstallWatcher,
    [switch]$RemoveWatcher,
    [switch]$DryRun,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { throw 'Cannot resolve this script''s own folder. Run it as a file (.\09-game-mode.ps1).' }

$TASK_NAME     = 'windows-tune game mode'
$POLICY_PREFIX = 'windows-tune game mode '
$MUTEX_NAME    = 'Global\windows-tune-game-mode'
$NAME_RE       = '^[A-Za-z0-9][A-Za-z0-9 ._()+\-]{0,99}$'

# ------------------------------------------------------------ pure parts ----
# Everything below up to "the machine" takes readings as arguments and touches
# nothing, so tests\preflight.ps1 lifts these functions out and CALLS them.

function Test-GameModeProtected {
    # A reason string when $Name must never be stopped, killed or capped; $null when it may be.
    # Not configurable on purpose: a config file is exactly where a bad entry would come from.
    param([string]$Name, [ValidateSet('Process', 'Service', 'App')][string]$Kind = 'Process')
    $n = ([string]$Name).Trim().ToLowerInvariant() -replace '\.exe$', ''
    if (-not $n) { return 'an empty name' }

    # Anti-cheat. Stopping one gets you kicked from a match at best, and can flag the account.
    $antiCheat = @(
        'vgc', 'vgk', 'vgtray', 'vanguard',                                   # Riot Vanguard
        'easyanticheat', 'easyanticheat_eos', 'easyanticheat_setup', 'eac_launcher', 'eaanticheat.gameservice', 'eaanticheat.installer', 'eaanticheatservice',
        'beservice', 'beservice_x64', 'bedaisy', 'battleye', 'belauncher',    # BattlEye
        'faceit', 'faceitclient', 'faceitservice', 'faceit_ac', 'faceitac',   # FACEIT
        'ricochet', 'randgrid', 'atvi-randgrid_sc', 'atvi-randgrid_msstore',  # Call of Duty Ricochet
        'pnkbstra', 'pnkbstrb', 'punkbuster',                                 # PunkBuster
        'xigncode', 'xigncode3', 'x3', 'xxd-0.xem',                           # XIGNCODE
        'gameguard', 'gamemon', 'gamemon64', 'npggnt', 'nprotect',            # nProtect GameGuard
        'mhyprot', 'mhyprot2', 'mhyprot3',                                    # miHoYo
        'acebase', 'ace-base', 'sguard64', 'sguardsvc64', 'tencentace',       # Tencent ACE
        'javelin', 'zakynthos', 'wellbia', 'xhunter1'
    )
    $antiCheatPattern = @('*anticheat*', '*anti-cheat*', '*battleye*', '*faceit*', '*vanguard*', '*punkbuster*', '*pnkbstr*',
                          '*xigncode*', '*gameguard*', '*ricochet*', '*randgrid*', '*mhyprot*', '*sguard*')
    if ($antiCheat -contains $n) { return "anti-cheat ($n)" }
    foreach ($p in $antiCheatPattern) { if ($n -like $p) { return "anti-cheat ($n)" } }

    if ($Kind -eq 'Service') {
        $criticalService = @(
            'windefend', 'wdnissvc', 'wdnisdrv', 'wdfilter', 'wdboot', 'sense', 'mdcoresvc', 'securityhealthservice', 'wscsvc',
            'mpssvc', 'bfe', 'eventlog', 'rpcss', 'rpceptmapper', 'dcomlaunch', 'lsm', 'samss', 'schedule', 'winmgmt',
            'plugplay', 'power', 'profsvc', 'cryptsvc', 'dhcp', 'dnscache', 'nsi', 'audiosrv', 'audioendpointbuilder',
            'brokerinfrastructure', 'coremessagingregistrar', 'systemeventsbroker', 'gpsvc', 'usermanager', 'netlogon',
            'lanmanworkstation', 'trustedinstaller', 'wuauserv', 'msiserver', 'appinfo', 'keyiso', 'vaultsvc'
        )
        if ($criticalService -contains $n) { return "a Windows system or security service ($n)" }
        if ($n -like 'wd*' -and $n -like '*defend*') { return "a Defender service ($n)" }
        return $null
    }

    $critical = @(
        'system', 'idle', 'registry', 'memory compression', 'secure system', 'smss', 'csrss', 'wininit', 'winlogon',
        'services', 'lsass', 'lsaiso', 'svchost', 'explorer', 'dwm', 'fontdrvhost', 'sihost', 'ctfmon', 'taskhostw',
        'conhost', 'runtimebroker', 'audiodg', 'dllhost', 'wmiprvse', 'searchhost', 'startmenuexperiencehost',
        'shellexperiencehost', 'textinputhost', 'logonui', 'userinit', 'wudfhost', 'spoolsv', 'powershell', 'pwsh',
        'msmpeng', 'nissrv', 'mpdefendercoreservice', 'mpcmdrun', 'securityhealthservice', 'securityhealthsystray',
        'smartscreen', 'msseces', 'sgrmbroker', 'trustedinstaller', 'tiworker'
    )
    if ($critical -contains $n) { return "a Windows system or security process ($n)" }
    if ($n -like '*defender*' -or $n -like 'securityhealth*') { return "a Windows security process ($n)" }
    return $null
}

function ConvertTo-GameModeName {
    # Lower case, no .exe: how Get-Process names a process.
    param([string]$Name)
    ([string]$Name).Trim().ToLowerInvariant() -replace '\.exe$', ''
}

function Read-GameModeConfig {
    # Parse and validate config JSON text. Throws naming the first problem, so a half-valid config
    # can never run. Protected names are NOT rejected here - the plan refuses each one out loud.
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { throw 'game mode config is empty' }
    try { $raw = $Json | ConvertFrom-Json -ErrorAction Stop } catch { throw "game mode config is not valid JSON: $($_.Exception.Message)" }

    function Test-Enabled($e) { -not ($e.PSObject.Properties.Name -contains 'enabled') -or [bool]$e.enabled }
    function Assert-Name([string]$What, $Value) {
        if ($Value -isnot [string] -or $Value -notmatch $script:NAME_RE) {
            throw "game mode config: $What '$Value' is not a plain program or service name (letters, digits, space . _ ( ) + -)"
        }
    }

    $poll = 5
    if ($raw.PSObject.Properties.Name -contains 'pollSeconds') {
        $poll = $raw.pollSeconds -as [int]
        if ($null -eq $poll -or $poll -lt 2 -or $poll -gt 60) { throw "game mode config: pollSeconds must be 2 to 60, got '$($raw.pollSeconds)'" }
    }

    $games = New-Object System.Collections.Generic.List[string]
    foreach ($g in @($raw.games)) {
        if ($null -eq $g) { continue }
        Assert-Name 'game' $g
        $games.Add((ConvertTo-GameModeName $g))
    }
    if ($games.Count -eq 0) { throw 'game mode config lists no games, so game mode would never start' }

    $procs = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($raw.stopProcesses)) {
        if ($null -eq $p -or -not (Test-Enabled $p)) { continue }
        Assert-Name 'stopProcesses name' $p.name
        $restart = $true
        if ($p.PSObject.Properties.Name -contains 'restart') { $restart = [bool]$p.restart }
        $force = $false
        if ($p.PSObject.Properties.Name -contains 'force') { $force = [bool]$p.force }
        $procs.Add([pscustomobject]@{ Name = (ConvertTo-GameModeName $p.name); Restart = $restart; Force = $force })
    }

    $svcs = New-Object System.Collections.Generic.List[string]
    foreach ($s in @($raw.stopServices)) {
        if ($null -eq $s -or -not (Test-Enabled $s)) { continue }
        Assert-Name 'stopServices name' $s.name
        $svcs.Add([string]$s.name)
    }

    $caps = New-Object System.Collections.Generic.List[object]
    foreach ($c in @($raw.uploadCaps)) {
        if ($null -eq $c -or -not (Test-Enabled $c)) { continue }
        Assert-Name 'uploadCaps app' $c.app
        if ($c.app -notmatch '\.exe$') { throw "game mode config: uploadCaps app '$($c.app)' must be an .exe file name, e.g. OneDrive.exe" }
        $bps = $c.bitsPerSecond -as [int64]
        if ($null -eq $bps -or $bps -lt 64000 -or $bps -gt 10000000000) { throw "game mode config: uploadCaps bitsPerSecond for $($c.app) must be 64000 to 10000000000, got '$($c.bitsPerSecond)'" }
        $caps.Add([pscustomobject]@{ App = [string]$c.app; BitsPerSecond = $bps })
    }

    $wsl = $false
    if ($raw.PSObject.Properties.Name -contains 'wslShutdown') { $wsl = [bool]$raw.wslShutdown }

    [pscustomobject]@{
        PollSeconds   = $poll
        Games         = $games.ToArray()
        StopProcesses = $procs.ToArray()
        StopServices  = $svcs.ToArray()
        UploadCaps    = $caps.ToArray()
        WslShutdown   = $wsl
    }
}

function Get-GameModePlan {
    # What game mode WOULD do now, from readings passed in. Every config entry comes back as one row:
    # Action Stop / Cap / Shutdown when it would change something, Skip when it would not, Refused when
    # the entry is protected. $ServiceState: lower-case name -> 'Running'/'Stopped'; a missing key means
    # not installed. $ExistingPolicies $null means the QoS store could not be read.
    param($Config, [string[]]$Running = @(), [hashtable]$ServiceState = @{}, [AllowNull()][string[]]$ExistingPolicies, [bool]$WslRunning = $false)
    $running = @($Running | ForEach-Object { ConvertTo-GameModeName $_ })
    $rows = New-Object System.Collections.Generic.List[object]
    function Row($kind, $name, $action, $why, $extra) {
        $o = [ordered]@{ Kind = $kind; Name = $name; Action = $action; Why = $why; Restart = $false; Force = $false; BitsPerSecond = 0; PolicyName = '' }
        if ($extra) { foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] } }
        $rows.Add([pscustomobject]$o)
    }

    foreach ($p in @($Config.StopProcesses)) {
        $why = Test-GameModeProtected $p.Name 'Process'
        if (-not $why -and @($Config.Games) -contains $p.Name) { $why = 'it is on your game list' }
        if ($why) { Row 'Process' $p.Name 'Refused' $why $null; continue }
        if ($running -contains $p.Name) { Row 'Process' $p.Name 'Stop' 'running' @{ Restart = $p.Restart; Force = $p.Force } }
        else { Row 'Process' $p.Name 'Skip' 'not running' $null }
    }
    foreach ($s in @($Config.StopServices)) {
        $why = Test-GameModeProtected $s 'Service'
        if ($why) { Row 'Service' $s 'Refused' $why $null; continue }
        $state = $ServiceState[$s.ToLowerInvariant()]
        if (-not $state) { Row 'Service' $s 'Skip' 'not installed' $null }
        elseif ($state -eq 'Running') { Row 'Service' $s 'Stop' 'running' $null }
        else { Row 'Service' $s 'Skip' "already $($state.ToLowerInvariant())" $null }
    }
    foreach ($c in @($Config.UploadCaps)) {
        $why = Test-GameModeProtected $c.App 'App'
        if (-not $why -and @($Config.Games) -contains (ConvertTo-GameModeName $c.App)) { $why = 'it is on your game list' }
        if ($why) { Row 'Cap' $c.App 'Refused' $why $null; continue }
        $pn = $script:POLICY_PREFIX + $c.App
        if ($null -eq $ExistingPolicies) { Row 'Cap' $c.App 'Cap' 'QoS policies could not be read here (needs admin)' @{ BitsPerSecond = $c.BitsPerSecond; PolicyName = $pn } }
        elseif ($ExistingPolicies -contains $pn) { Row 'Cap' $c.App 'Skip' 'already capped' $null }
        else { Row 'Cap' $c.App 'Cap' 'upload cap' @{ BitsPerSecond = $c.BitsPerSecond; PolicyName = $pn } }
    }
    if ($Config.WslShutdown) {
        if ($WslRunning) { Row 'Wsl' 'WSL' 'Shutdown' 'a distro is running' $null } else { Row 'Wsl' 'WSL' 'Skip' 'not running' $null }
    }
    $rows.ToArray()
}

function Get-GameModeStep {
    # The watcher's whole decision: 'enter' when a game starts, 'restore' when the last one ends.
    param([bool]$GameRunning, [bool]$Active)
    if ($GameRunning -and -not $Active) { return 'enter' }
    if (-not $GameRunning -and $Active) { return 'restore' }
    'none'
}

function ConvertTo-PsLiteral {
    # A single-quoted PowerShell literal. Doubling ' is the whole escape rule for that form.
    param([string]$Text)
    "'" + ($Text -replace "'", "''") + "'"
}

function New-GameModeRevertLines {
    # The revert file for exactly what $Applied lists, newest change undone first. Each step checks
    # before acting, so running it twice, or after a reboot cleared a cap, is not an error.
    param([object[]]$Applied, [string]$Captured)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Auto-generated revert for 09-game-mode.ps1. Run ELEVATED.')
    $lines.Add("# Captured $Captured. It undoes only what game mode changed, then removes itself and the state file.")
    $lines.Add('$failed = 0')
    $items = @($Applied | ForEach-Object { $_ })   # a copy: Reverse works in place
    [array]::Reverse($items)
    foreach ($a in $items) {
        switch ($a.Kind) {
            'Cap' {
                $pn = ConvertTo-PsLiteral $a.PolicyName
                $lines.Add("try { if (Get-NetQosPolicy -Name $pn -PolicyStore ActiveStore -ErrorAction SilentlyContinue) { Remove-NetQosPolicy -Name $pn -PolicyStore ActiveStore -Confirm:`$false -ErrorAction Stop } } catch { `$failed++; Write-Host ('could not remove QoS policy ' + $pn + ': ' + `$_.Exception.Message) -ForegroundColor Red }")
            }
            'Service' {
                $sn = ConvertTo-PsLiteral $a.Name
                $lines.Add("try { Start-Service -Name $sn -ErrorAction Stop } catch { `$failed++; Write-Host ('could not start service ' + $sn + ': ' + `$_.Exception.Message) -ForegroundColor Red }")
            }
            'Process' {
                if ($a.Restart -and $a.Path) {
                    $pn = ConvertTo-PsLiteral $a.Name
                    $pp = ConvertTo-PsLiteral ('"' + $a.Path + '"')
                    $lines.Add("try { if (-not (Get-Process -Name $pn -ErrorAction SilentlyContinue)) { Start-Process -FilePath (Join-Path `$env:SystemRoot 'explorer.exe') -ArgumentList $pp -ErrorAction Stop } } catch { `$failed++; Write-Host ('could not start ' + $pn + ': ' + `$_.Exception.Message) -ForegroundColor Red }")
                } else {
                    $lines.Add("# $($a.Name) was stopped and is not restarted (restart is off, or its path could not be read).")
                }
            }
            'Wsl' { $lines.Add('# WSL was shut down. It starts again by itself the next time something uses it.') }
        }
    }
    $lines.Add('$state = Join-Path $PSScriptRoot ''09-game-mode-state.json''')
    $lines.Add('if ($failed -eq 0) { Remove-Item -LiteralPath $state -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue; Write-Host ''Game mode undone; this revert file removed itself.'' -ForegroundColor Green }')
    $lines.Add('else { Write-Host "$failed step(s) failed; this file is kept so you can run it again." -ForegroundColor Red; exit 1 }')
    $lines.ToArray()
}

function Read-GameModeState {
    # The state file is DATA, re-validated here, because the watcher acts on it with admin rights.
    param([string]$Json)
    # Assigned first, then @(): PowerShell 5.1 emits a JSON array as ONE object, so @(ConvertFrom-Json) nests it.
    try { $raw = $Json | ConvertFrom-Json -ErrorAction Stop } catch { throw "game mode state file is not valid JSON: $($_.Exception.Message)" }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($a in @($raw)) {
        if ($null -eq $a) { continue }
        if ($a.Kind -notin 'Cap', 'Service', 'Process', 'Wsl') { throw "game mode state file: unknown kind '$($a.Kind)'" }
        if ([string]$a.Name -notmatch $script:NAME_RE) { throw "game mode state file: '$($a.Name)' is not a plain name" }
        if ($a.Kind -eq 'Cap' -and ([string]$a.PolicyName -notlike ($script:POLICY_PREFIX + '*') -or [string]$a.PolicyName -match "['`"]")) { throw "game mode state file: policy '$($a.PolicyName)' was not made by game mode" }
        if ($a.Kind -ne 'Wsl' -and (Test-GameModeProtected $a.Name $(if ($a.Kind -eq 'Service') { 'Service' } elseif ($a.Kind -eq 'Cap') { 'App' } else { 'Process' }))) { throw "game mode state file names a protected entry '$($a.Name)'" }
        $path = [string]$a.Path
        if ($path -and ($path -notmatch '^[A-Za-z]:\\' -or $path -notmatch '\.exe$' -or $path -match '"')) { throw "game mode state file: '$path' is not a program path" }
        $out.Add([pscustomobject]@{ Kind = [string]$a.Kind; Name = [string]$a.Name; Path = $path; Restart = [bool]$a.Restart; PolicyName = [string]$a.PolicyName })
    }
    $out.ToArray()
}

# ------------------------------------------------------------ the machine ----

function Write-GameModeLog {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    if ($script:LogPath) {
        try { Add-Content -LiteralPath $script:LogPath -Value ((Get-Date -Format s) + ' ' + $Text) -Encoding UTF8 } catch { Write-Host "  (log not written: $($_.Exception.Message))" -ForegroundColor DarkYellow }
    }
}

function Get-RunningNames { @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName.ToLowerInvariant() }) }

function Get-ServiceStates {
    param([string[]]$Names)
    $h = @{}
    foreach ($n in $Names) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s) { $h[$n.ToLowerInvariant()] = $s.Status.ToString() }
    }
    $h
}

function Get-GameModePolicies {
    # $null when the store cannot be read (it needs admin), never an empty list that would read as "none".
    # The leading comma keeps an EMPTY list a list: unrolled, it would come back as $null and read as unreadable.
    try { , @(Get-NetQosPolicy -PolicyStore ActiveStore -ErrorAction Stop | ForEach-Object { $_.Name }) } catch { $null }
}

function Test-WslRunning {
    $wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
    if (-not (Test-Path -LiteralPath $wsl)) { return $false }
    $bytes = & $wsl -l --running -q 2>$null
    $text = (@($bytes) -join "`n") -replace "`0", ''
    return [bool]($text -split "`n" | Where-Object { $_.Trim() })
}

function Get-LivePlan {
    param($Config)
    $wslOn = $false
    if ($Config.WslShutdown) { $wslOn = Test-WslRunning }
    Get-GameModePlan -Config $Config -Running (Get-RunningNames) -ServiceState (Get-ServiceStates $Config.StopServices) -ExistingPolicies (Get-GameModePolicies) -WslRunning $wslOn
}

function Save-GameModeRecord {
    # Both records, or a throw: the revert is for a human, the state file for the watcher.
    param([object[]]$Applied)
    $rows = @($Applied | ForEach-Object { [pscustomobject]@{ Kind = $_.Kind; Name = $_.Name; Path = $_.Path; Restart = [bool]$_.Restart; PolicyName = $_.PolicyName } })
    Set-Content -LiteralPath $script:RevertPath -Encoding UTF8 -Value (New-GameModeRevertLines -Applied $rows -Captured (Get-Date -Format s))
    Set-Content -LiteralPath $script:StatePath -Encoding UTF8 -Value (ConvertTo-Json -InputObject @($rows) -Depth 3)
}

function Clear-GameModeRecord {
    foreach ($p in $script:RevertPath, $script:StatePath) { Remove-Item -LiteralPath $p -ErrorAction SilentlyContinue }
}

function Invoke-GameModeEnter {
    # Apply the plan's change rows. Returns what was changed AND read back as changed.
    param([object[]]$Plan)
    $todo = @($Plan | Where-Object { $_.Action -in 'Stop', 'Cap', 'Shutdown' })
    if ($todo.Count -eq 0) {
        Write-GameModeLog 'already at target - nothing to change' Green
        return
    }
    # Record what is about to change BEFORE changing it, so a crash mid-way still leaves a way back.
    $planned = @(foreach ($row in $todo) {
        $path = $null
        if ($row.Kind -eq 'Process') { $path = @(Get-Process -Name $row.Name -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1 | ForEach-Object { $_.Path })[0] }
        [pscustomobject]@{ Kind = $row.Kind; Name = $row.Name; Path = $path; Restart = $row.Restart; Force = $row.Force; BitsPerSecond = $row.BitsPerSecond; PolicyName = $row.PolicyName }
    })
    Save-GameModeRecord $planned
    Write-GameModeLog "Revert written: $script:RevertPath" Cyan

    $applied = New-Object System.Collections.Generic.List[object]
    foreach ($t in $planned) {
        # Checked again here, not only in the plan: this is the line that acts.
        $kind = 'Process'
        if ($t.Kind -eq 'Service') { $kind = 'Service' } elseif ($t.Kind -eq 'Cap') { $kind = 'App' }
        if ($t.Kind -ne 'Wsl') {
            $why = Test-GameModeProtected $t.Name $kind
            if ($why) { Write-GameModeLog "REFUSED $($t.Name): $why - never touched" Red; continue }
        }
        try {
            switch ($t.Kind) {
                'Cap' {
                    New-NetQosPolicy -Name $t.PolicyName -AppPathNameMatchCondition $t.Name -ThrottleRateActionBitsPerSecond $t.BitsPerSecond -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
                    if (Get-NetQosPolicy -Name $t.PolicyName -PolicyStore ActiveStore -ErrorAction SilentlyContinue) { $applied.Add($t); Write-GameModeLog "capped $($t.Name) upload at $([int64]($t.BitsPerSecond / 1000)) kbit/s (read back)" Green }
                    else { Write-GameModeLog "NOT CONFIRMED: the cap on $($t.Name) was added but cannot be read back" Red }
                }
                'Service' {
                    Stop-Service -Name $t.Name -ErrorAction Stop
                    $now = (Get-Service -Name $t.Name -ErrorAction SilentlyContinue).Status
                    if ("$now" -eq 'Stopped') { $applied.Add($t); Write-GameModeLog "stopped service $($t.Name) (read back)" Green }
                    else { Write-GameModeLog "NOT CONFIRMED: service $($t.Name) reads '$now' after the stop" Red }
                }
                'Process' {
                    $procs = @(Get-Process -Name $t.Name -ErrorAction SilentlyContinue)
                    foreach ($p in $procs) { try { [void]$p.CloseMainWindow() } catch { Write-GameModeLog "  $($t.Name) pid $($p.Id): close request failed: $($_.Exception.Message)" DarkYellow } }
                    $deadline = (Get-Date).AddSeconds(10)
                    while ((Get-Process -Name $t.Name -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
                    if ((Get-Process -Name $t.Name -ErrorAction SilentlyContinue) -and $t.Force) {
                        Get-Process -Name $t.Name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Stop
                        Start-Sleep -Milliseconds 500
                    }
                    if (Get-Process -Name $t.Name -ErrorAction SilentlyContinue) {
                        Write-GameModeLog "NOT STOPPED: $($t.Name) did not close when asked$(if (-not $t.Force) { ' (its entry has no "force": true)' }); left running" Yellow
                    } else {
                        $applied.Add($t); Write-GameModeLog "stopped $($t.Name)$(if ($t.Restart) { ', will restart it after' }) (read back)" Green
                    }
                }
                'Wsl' {
                    & (Join-Path $env:SystemRoot 'System32\wsl.exe') --shutdown
                    if ($LASTEXITCODE -eq 0 -and -not (Test-WslRunning)) { $applied.Add($t); Write-GameModeLog 'shut WSL down (read back)' Green }
                    else { Write-GameModeLog "NOT CONFIRMED: wsl --shutdown exit $LASTEXITCODE" Red }
                }
            }
        } catch {
            Write-GameModeLog "FAILED $($t.Kind) $($t.Name): $($_.Exception.Message)" Red
        }
    }
    # Rewrite the record with only what really changed, so the undo never starts something that was never stopped.
    if ($applied.Count -gt 0) { Save-GameModeRecord $applied.ToArray() } else { Clear-GameModeRecord; Write-GameModeLog 'nothing was changed, so no revert file is kept' Yellow }
    $applied.ToArray()
}

function Invoke-GameModeRestore {
    # Undo $Applied, newest first. Returns the number of steps that failed; 0 means everything is back.
    param([object[]]$Applied)
    $failed = 0
    $items = @($Applied | ForEach-Object { $_ })   # a copy: Reverse works in place
    [array]::Reverse($items)
    foreach ($a in $items) {
        try {
            switch ($a.Kind) {
                'Cap' {
                    if (Get-NetQosPolicy -Name $a.PolicyName -PolicyStore ActiveStore -ErrorAction SilentlyContinue) { Remove-NetQosPolicy -Name $a.PolicyName -PolicyStore ActiveStore -Confirm:$false -ErrorAction Stop }
                    Write-GameModeLog "removed the upload cap on $($a.Name)" Green
                }
                'Service' { Start-Service -Name $a.Name -ErrorAction Stop; Write-GameModeLog "started service $($a.Name) again" Green }
                'Process' {
                    if (-not $a.Restart) { Write-GameModeLog "$($a.Name) is not restarted (restart is off)" DarkGray }
                    elseif (-not $a.Path) { Write-GameModeLog "$($a.Name) cannot be restarted: its path was not readable when it was stopped" Yellow }
                    elseif (Get-Process -Name $a.Name -ErrorAction SilentlyContinue) { Write-GameModeLog "$($a.Name) is already running again" DarkGray }
                    else {
                        # explorer.exe starts it with your normal rights, not this process's admin rights.
                        Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('"' + $a.Path + '"') -ErrorAction Stop
                        Write-GameModeLog "started $($a.Name) again" Green
                    }
                }
                'Wsl' { Write-GameModeLog 'WSL starts again by itself the next time something uses it' DarkGray }
            }
        } catch {
            $failed++
            Write-GameModeLog "FAILED to undo $($a.Kind) $($a.Name): $($_.Exception.Message)" Red
        }
    }
    $failed
}

function Restore-LeftoverState {
    # A watcher killed mid-game leaves the state file behind. Put things back from it before anything else.
    if (-not (Test-Path -LiteralPath $script:StatePath)) { return $true }
    Write-GameModeLog "Game mode was left on by an earlier run ($script:StatePath). Undoing it first." Yellow
    $left = @(Read-GameModeState (Get-Content -LiteralPath $script:StatePath -Raw))
    $failed = Invoke-GameModeRestore $left
    if ($failed -eq 0) { Clear-GameModeRecord; return $true }
    Write-GameModeLog "$failed step(s) could not be undone. The revert file is kept: $script:RevertPath" Red
    return $false
}

function Show-Plan {
    param([object[]]$Plan)
    foreach ($r in $Plan) {
        switch ($r.Action) {
            'Refused'  { Write-Host "  REFUSED  $($r.Kind) $($r.Name): $($r.Why) - never touched, whatever the config says" -ForegroundColor Red }
            'Skip'     { Write-Host "  skip     $($r.Kind) $($r.Name): $($r.Why)" -ForegroundColor DarkGray }
            'Stop'     { Write-Host "  WOULD    stop $($r.Kind.ToLowerInvariant()) $($r.Name)$(if ($r.Kind -eq 'Process') { "  (ask it to close$(if ($r.Force) { ', then kill' }); restart after: $(if ($r.Restart) { 'yes' } else { 'no' }))" })" -ForegroundColor Yellow }
            'Cap'      { Write-Host "  WOULD    cap upload of $($r.Name) at $([int64]($r.BitsPerSecond / 1000)) kbit/s  ($($r.Why))" -ForegroundColor Yellow }
            'Shutdown' { Write-Host "  WOULD    shut WSL down ($($r.Why))" -ForegroundColor Yellow }
        }
    }
}

function Get-WatcherSafety {
    # The watcher runs this script as admin at every sign-in, so the script, its config and its folder
    # must be admin-only. The check is windows-tune.ps1's own (audit 2c24feed lead 1), read through the
    # Parser rather than copied, so there is one copy of it. A missing or unreadable check is a refusal.
    $menuPath = Join-Path (Split-Path -Parent $here) 'windows-tune.ps1'
    if (-not (Test-Path -LiteralPath $menuPath)) { return "windows-tune.ps1 is not beside the scripts folder, so the folder check cannot run" }
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($menuPath, [ref]$null, [ref]$errors)
    $fns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'Test-UserWritable', 'Get-UnsafeRunReason' }, $true))
    if ($errors.Count -or $fns.Count -ne 2) { return 'the folder check in windows-tune.ps1 could not be read' }
    foreach ($f in $fns) { . ([scriptblock]::Create($f.Extent.Text)) }
    foreach ($file in @($PSCommandPath, $script:ConfigUsed, $menuPath)) {
        $why = Get-UnsafeRunReason $file
        if ($why) { return $why }
    }
    return $null
}

# ------------------------------------------------------------------ main ----
$modes = @($Watch, $InstallWatcher, $RemoveWatcher | Where-Object { $_ })
if ($modes.Count -gt 1) { throw 'Pick one of -Watch, -InstallWatcher or -RemoveWatcher.' }
if ($modes.Count -eq 0) { $DryRun = [switch]$true }

$script:RevertPath = Join-Path $here '09-game-mode-revert.ps1'
$script:StatePath  = Join-Path $here '09-game-mode-state.json'
$watcherRevert     = Join-Path $here '09-game-mode-watcher-revert.ps1'
$script:LogPath    = $null

if ($ConfigPath) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Config not found: $ConfigPath" }
    $script:ConfigUsed = (Resolve-Path -LiteralPath $ConfigPath).Path
} else {
    $own = Join-Path $here '09-game-mode.json'
    $script:ConfigUsed = if (Test-Path -LiteralPath $own) { $own } else { Join-Path $here '09-game-mode.defaults.json' }
    if (-not (Test-Path -LiteralPath $script:ConfigUsed)) { throw "No game mode config: neither 09-game-mode.json nor 09-game-mode.defaults.json is in $here" }
}
$config = Read-GameModeConfig (Get-Content -LiteralPath $script:ConfigUsed -Raw)
Write-Host "Game mode config: $script:ConfigUsed" -ForegroundColor Cyan
Write-Host "  watching $($config.Games.Count) game(s): $($config.Games -join ', ')"

if ($InstallWatcher) {
    $unsafe = Get-WatcherSafety
    if ($unsafe) {
        Write-Host "REFUSED to install the watcher: $unsafe, so a program running as you could change what the watcher runs as administrator." -ForegroundColor Red
        Write-Host '  Install windows-tune with install.ps1 (Program Files) first. Nothing was changed.' -ForegroundColor Yellow
        exit 4
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $DryRun -and -not $isAdmin) { throw 'Run this from an elevated PowerShell (Run as administrator). -DryRun works without it.' }

if ($DryRun) {
    Write-Host "`nDRY RUN - nothing on this machine is changed." -ForegroundColor Cyan
    $games = @(Get-RunningNames | Where-Object { $config.Games -contains $_ } | Sort-Object -Unique)
    Write-Host "  game running now: $(if ($games.Count) { $games -join ', ' } else { 'none' })"
    if (Test-Path -LiteralPath $script:StatePath) { Write-Host "  game mode is ON from an earlier run: $script:StatePath exists (the next -Watch undoes it first)" -ForegroundColor Yellow }
    Write-Host '  When a listed game starts, game mode would:'
    $plan = @(Get-LivePlan $config)
    Show-Plan $plan
    $n = @($plan | Where-Object { $_.Action -in 'Stop', 'Cap', 'Shutdown' }).Count
    if ($n -eq 0) { Write-Host '  already at target - nothing to change' -ForegroundColor Green }
    else { Write-Host "  $n change(s). It would write $script:RevertPath first, and undo them all when the game exits." }
    if ($InstallWatcher) { Write-Host "  -InstallWatcher would register scheduled task '$TASK_NAME' (at sign-in, hidden, highest privileges) running: $PSCommandPath -Watch, and write $watcherRevert first." -ForegroundColor Yellow }
    if ($RemoveWatcher) { Write-Host "  -RemoveWatcher would stop and unregister scheduled task '$TASK_NAME' if it exists." -ForegroundColor Yellow }
    if ($Watch) { Write-Host "  -Watch would check every $($config.PollSeconds) s until closed." }
    return
}

if ($InstallWatcher) {
    $existing = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "already at target - nothing to change" -ForegroundColor Green
        Write-Host "  scheduled task '$TASK_NAME' already exists ($($existing.State)). Remove it with -RemoveWatcher or $watcherRevert." -ForegroundColor DarkGray
        return
    }
    $tn = ConvertTo-PsLiteral $TASK_NAME
    Set-Content -LiteralPath $watcherRevert -Encoding UTF8 -Value @(
        '# Auto-generated revert for 09-game-mode.ps1 -InstallWatcher. Run ELEVATED.',
        "# Captured $(Get-Date -Format s). Removes the game mode watcher task, then removes itself.",
        "Stop-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue",
        "Unregister-ScheduledTask -TaskName $tn -Confirm:`$false -ErrorAction SilentlyContinue",
        "if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) { Write-Host 'The watcher task is still registered.' -ForegroundColor Red; exit 1 }",
        "if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot '09-game-mode-revert.ps1')) { Write-Host 'Game mode was on when the watcher stopped: run 09-game-mode-revert.ps1 too.' -ForegroundColor Yellow }",
        'Remove-Item -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue',
        "Write-Host 'Game mode watcher removed.' -ForegroundColor Green"
    )
    Write-Host "Revert written: $watcherRevert" -ForegroundColor Cyan
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $taskArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Watch"
    if ($ConfigPath) { $taskArgs += " -ConfigPath `"$script:ConfigUsed`"" }
    $action    = New-ScheduledTaskAction -Execute $ps -Argument $taskArgs -WorkingDirectory $here
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TASK_NAME -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
    $back = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    if ($back) { Write-Host "Watcher task '$TASK_NAME' registered (read back: $($back.State)). It starts at your next sign-in." -ForegroundColor Green }
    else { Write-Host "NOT CONFIRMED: task '$TASK_NAME' cannot be read back after registering. The revert file is still valid." -ForegroundColor Red }
    return
}

if ($RemoveWatcher) {
    $existing = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    if ($existing) {
        Stop-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction Stop
        if (Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue) { throw "Task '$TASK_NAME' is still registered after Unregister-ScheduledTask." }
        Write-Host "Watcher task '$TASK_NAME' removed (read back: gone)." -ForegroundColor Green
    } else {
        Write-Host 'already at target - nothing to change' -ForegroundColor Green
        Write-Host "  no scheduled task '$TASK_NAME' is registered." -ForegroundColor DarkGray
    }
    Remove-Item -LiteralPath $watcherRevert -ErrorAction SilentlyContinue
    # a stopped watcher cannot undo game mode itself, so do it here
    [void](Restore-LeftoverState)
    return
}

# -Watch
$script:LogPath = Join-Path $here '09-game-mode.log'
$mutex = New-Object System.Threading.Mutex($false, $MUTEX_NAME)
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    Write-Host 'already at target - nothing to change' -ForegroundColor Green
    Write-Host '  another game mode watcher is already running on this PC.' -ForegroundColor DarkGray
    $mutex.Dispose()
    return
}
$active = $false
$applied = @()
try {
    if (-not (Restore-LeftoverState)) { throw 'Game mode from an earlier run could not be fully undone. Run 09-game-mode-revert.ps1 (menu R), then start again.' }
    Write-GameModeLog "Watching for $($config.Games.Count) game(s) every $($config.PollSeconds) s. Close this window or press Ctrl+C to stop; Ctrl+C undoes game mode first." Cyan
    while ($true) {
        $game = @(Get-RunningNames | Where-Object { $config.Games -contains $_ } | Sort-Object -Unique)
        switch (Get-GameModeStep -GameRunning ($game.Count -gt 0) -Active $active) {
            'enter' {
                Write-GameModeLog "game started: $($game -join ', ')" Cyan
                $plan = @(Get-LivePlan $config)
                foreach ($r in @($plan | Where-Object { $_.Action -eq 'Refused' })) { Write-GameModeLog "REFUSED $($r.Kind) $($r.Name): $($r.Why) - never touched" Red }
                $applied = @(Invoke-GameModeEnter $plan)
                $active = $true
            }
            'restore' {
                Write-GameModeLog 'game over: undoing game mode' Cyan
                $failed = Invoke-GameModeRestore $applied
                if ($failed -eq 0) { Clear-GameModeRecord; Write-GameModeLog 'game mode off: everything it changed is back' Green }
                else { Write-GameModeLog "$failed step(s) could not be undone. The revert file is kept: $script:RevertPath" Red }
                $applied = @()
                $active = $false
            }
        }
        Start-Sleep -Seconds $config.PollSeconds
    }
} finally {
    if ($active -and @($applied).Count -gt 0) {
        Write-GameModeLog 'stopping: undoing game mode first' Cyan
        $failed = Invoke-GameModeRestore $applied
        if ($failed -eq 0) { Clear-GameModeRecord } else { Write-GameModeLog "$failed step(s) could not be undone. The revert file is kept: $script:RevertPath" Red }
    }
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
