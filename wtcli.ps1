<#
.SYNOPSIS
    JSON-only engine CLI for Escanor's System tab (GUS-88, DEC-739).

.DESCRIPTION
    wtcli.ps1 tune list   READ-ONLY. One JSON object on stdout: the speed and
                          gaming tweaks with current value, recommended value,
                          state (on|off|partial|unknown) and whether a revert
                          file exists. Needs no admin. Writes nothing.

    A value that cannot be read is "current": null and "state": "unknown",
    never 0. A failure is {"ok":false,"reason":...} with a non-zero exit:
    1 = a reader threw, 2 = unknown command.

    The network comparison is lifted from 01-network-tune.ps1 by AST, so the
    targets live in one place (the same way tests\preflight.ps1 stage 10 does).
#>
param([Parameter(Position=0)][string]$Area,[Parameter(Position=1)][string]$Action)

function Get-PowerPlanGuid {
    $output = powercfg /getactivescheme
    if ($output -match '([a-f0-9]{8}-[a-f0-9\-]{27})') {
        return $matches[1]
    }
    return $null
}

function Get-PowerIndex {
    param (
        [string]$Plan,
        [string]$Sub,
        [string]$Setting,
        [string]$Side
    )
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$Plan\$Sub\$Setting"
    $value = Get-ItemProperty -Path $path -Name "${Side}SettingIndex" -ErrorAction SilentlyContinue
    if ($value) {
        return [int]$value."${Side}SettingIndex"
    }
    return $null
}


function Get-SideState {
    param (
        [object]$Ac,
        [object]$Dc,
        [int]$Target
    )
    if ($Ac -eq $null -and $Dc -eq $null) {
        return 'unknown'
    }
    if ($Ac -eq $Target -and $Dc -eq $Target) {
        return 'on'
    }
    if ($Ac -ne $Target -and $Dc -ne $Target) {
        return 'off'
    }
    return 'partial'
}

function New-TweakRow {
    param([string]$Id, [string]$Group, [string]$Name, [object]$Current, [object]$Recommended, [string]$State, [bool]$UndoReady, [bool]$NeedsAdmin, [string]$Why)
    return [ordered]@{ id = $Id; group = $Group; name = $Name; current = $Current; recommended = $Recommended; state = $State; undo_ready = $UndoReady; needs_admin = $NeedsAdmin; why = $Why }
}

function Get-PowerTweakRow {
    param([string]$Id, [string]$Name, [string]$Setting, [int]$Target, [string]$RevertFile, [string]$Why)
    $sub = '54533251-82be-4824-96c1-47b60b740d00'
    $plan = Get-PowerPlanGuid
    $ac, $dc = $null, $null
    if ($plan) {
        $ac = Get-PowerIndex -Plan $plan -Sub $sub -Setting $Setting -Side 'AC'
        $dc = Get-PowerIndex -Plan $plan -Sub $sub -Setting $Setting -Side 'DC'
    }
    $acStr = if ($ac -eq $null) { 'not stored' } else { "$ac%" }
    $dcStr = if ($dc -eq $null) { 'not stored' } else { "$dc%" }
    $current = if ($ac -eq $null -and $dc -eq $null) { $null } else { "AC $acStr / DC $dcStr" }
    $state = Get-SideState -Ac $ac -Dc $dc -Target $Target
    return New-TweakRow -Id $Id -Group 'speed' -Name $Name -Current $current -Recommended "$Target%" -State $state -UndoReady (Test-Path -LiteralPath $RevertFile) -NeedsAdmin $true -Why $Why
}

function Get-NicTweakRow {
    param([object]$Pending, [int]$Total, [bool]$UndoReady)
    if ($Pending -eq $null) {
        $current = $null
        $state = 'unknown'
    } else {
        $done = $Total - $Pending
        $current = "$done of $Total at target"
        $state = if ($Pending -eq 0) { 'on' } elseif ($Pending -eq $Total) { 'off' } else { 'partial' }
    }
    return New-TweakRow -Id 'nic' -Group 'speed' -Name 'Network adapter tuning' -Current $current -Recommended "$Total of $Total at target" -State $state -UndoReady $UndoReady -NeedsAdmin $true -Why 'TCP autotuning, RSS, RSC, throttling index and NIC power saving set for steady throughput.'
}

function Get-GameModeTweakRow {
    param([string]$TaskName, [bool]$UndoReady)
    $current, $state = $null, 'unknown'
    try {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $current = 'watcher installed'
        $state = 'on'
    } catch [Microsoft.PowerShell.Cmdletization.Cim.CimJobException] {
        $current = 'not installed'
        $state = 'off'
    } catch {
        $current = $null
        $state = 'unknown'
    }
    return New-TweakRow -Id 'game-mode' -Group 'gaming' -Name 'Game mode watcher' -Current $current -Recommended 'watcher installed' -State $state -UndoReady $UndoReady -NeedsAdmin $true -Why 'Pauses listed background apps and services while a game runs, then restores them.'
}

function Import-NetLogic {
    param([string]$ScriptPath)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
    $fn = $ast.FindAll({$args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and ($args[0].Name -eq 'Get-PendingNetworkChanges')}, $true) | Select-Object -First 1
    if ($null -eq $fn) { throw 'network logic not found in 01-network-tune.ps1' }
    $assign = $ast.FindAll({$args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and ($args[0].Left.Extent.Text -eq '$staged')}, $true) | Select-Object -First 1
    if ($null -eq $assign) { throw 'network logic not found in 01-network-tune.ps1' }
    return @{ FnText = $fn.Extent.Text; Staged = @(& ([scriptblock]::Create($assign.Right.Extent.Text))) }
}

function Get-TcpLabel {
    param([string[]]$Lines, [string]$Label)
    foreach ($line in $Lines) {
        if ($line.Contains($Label)) {
            return $line.Split(':')[1].Trim()
        }
    }
    return $null
}

function Get-NicSnapshot {
    param([object[]]$Staged)
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    if ($null -eq $route) { return $null }
    $name = (Get-NetAdapter -InterfaceIndex $route.ifIndex -ErrorAction SilentlyContinue).Name
    if ([string]::IsNullOrEmpty($name)) { return $null }
    $g = @(netsh int tcp show global)
    $pm = Get-NetAdapterPowerManagement -Name $name -ErrorAction SilentlyContinue
    $power = $null
    if ($pm) { $power = [string]$pm.AllowComputerToTurnOffDevice }
    $adv = @{}
    foreach ($s in $Staged) {
        $p = Get-NetAdapterAdvancedProperty -Name $name -DisplayName $s.Name -ErrorAction SilentlyContinue
        if ($p) { $adv[$s.Name] = $p.DisplayValue }
    }
    return @{ AutoTuning = Get-TcpLabel $g 'Receive Window Auto-Tuning Level'; Rss = Get-TcpLabel $g 'Receive-Side Scaling State'; Rsc = Get-TcpLabel $g 'Receive Segment Coalescing State'; ThrottlingIndex = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -ErrorAction SilentlyContinue).NetworkThrottlingIndex; NicPowerDown = $power; Advanced = $adv }
}

function Get-NicPendingCount {
    param([hashtable]$Snapshot,[object[]]$Staged)
    if ($null -eq $Snapshot) {
        return @{ Pending = $null; Total = 0 }
    }
    $p = @(Get-PendingNetworkChanges -Current $Snapshot -Staged $Staged)
    $total = 4 + $Snapshot.Advanced.Count
    if ($null -ne $Snapshot.NicPowerDown) {
        $total++
    }
    return @{ Pending = $p.Count; Total = $total }
}

function Get-TuneList {
    param([string]$Root)
    $scripts = Join-Path $Root 'scripts'
    $rows = @()
    $rows += Get-PowerTweakRow -Id 'power-min' -Name 'Power minimum state' -Setting '893dee8e-2bef-41e0-89c6-b55d0929964c' -Target 0 -RevertFile (Join-Path $scripts '02-power-tune-revert.ps1') -Why 'Lets the CPU idle down fully; boost handles load.'
    $rows += Get-PowerTweakRow -Id 'core-unpark' -Name 'Keep all CPU cores unparked' -Setting '0cc5b647-c1df-4637-891a-dec35c318583' -Target 100 -RevertFile (Join-Path $scripts '08-core-unpark-revert.ps1') -Why 'Stops Windows parking cores, which cuts wake-up stutter in games.'
    $logic = Import-NetLogic -ScriptPath (Join-Path $scripts '01-network-tune.ps1')
    . ([scriptblock]::Create($logic.FnText))
    $c = Get-NicPendingCount -Snapshot (Get-NicSnapshot -Staged $logic.Staged) -Staged $logic.Staged
    $rows += Get-NicTweakRow -Pending $c.Pending -Total $c.Total -UndoReady (Test-Path -LiteralPath (Join-Path $scripts '01-network-tune-revert.ps1'))
    $rows += Get-GameModeTweakRow -TaskName 'windows-tune game mode' -UndoReady (Test-Path -LiteralPath (Join-Path $scripts '09-game-mode-watcher-revert.ps1'))
    return $rows
}

function Write-Result {
    param([object]$Object,[int]$Code)
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::Out.Write(($Object | ConvertTo-Json -Depth 6 -Compress))
    exit $Code
}

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -TotalCount 1).Trim()
try {
    if ($Area -eq 'tune' -and $Action -eq 'list') {
        $rows = @(Get-TuneList -Root $root)
        Write-Result ([ordered]@{ ok = $true; engine = 'windows-tune'; version = $version; tweaks = $rows }) 0
    } else {
        Write-Result ([ordered]@{ ok = $false; reason = "unknown command: $Area $Action" }) 2
    }
} catch {
    Write-Result ([ordered]@{ ok = $false; reason = $_.Exception.Message }) 1
}
