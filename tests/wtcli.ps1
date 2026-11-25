# Gate for wtcli.ps1 (GUS-88): the real read-only run, planted revert/failure state in a temp copy, and the null rule.
# Exit 0 all pass, 1 a check failed, 2 checked nothing.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$cli = Join-Path $repo 'wtcli.ps1'
$script:fails = 0
$script:checks = 0
function Check([string]$What,[bool]$Ok) { $script:checks++; if ($Ok) { Write-Host "PASS $What" } else { Write-Host "FAIL $What" -ForegroundColor Red; $script:fails++ } }
function Invoke-Cli([string]$Path,[string[]]$CliArgs) { $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @CliArgs; return @{ Code = $LASTEXITCODE; Text = ($out -join "`n") } }
function Get-Tweak($json, $id) { return @($json.tweaks | Where-Object { $_.id -eq $id })[0] }
$r = Invoke-Cli $cli @('tune','list')
Check -What 'Exit code 0' -Ok ($r.Code -eq 0)
$j = $r.Text | ConvertFrom-Json
Check -What 'j.ok is true' -Ok ($j.ok -eq $true)
Check -What 'tweaks list' -Ok ((($j.tweaks.id -join ',') -eq 'power-min,core-unpark,nic,game-mode'))
$tweaks = $j.tweaks
foreach ($tweak in $tweaks) { Check -What "tweak state $($tweak.id) is valid" -Ok ($tweak.state -in @('on','off','partial','unknown')); if ($tweak.state -eq 'unknown') { Check -What "unknown tweak $($tweak.id) has null current" -Ok ($null -eq $tweak.current) } }
$groups = @('power-min','core-unpark','nic','game-mode')
foreach ($group in $groups) { $tweak = $tweaks | Where-Object { $_.id -eq $group }; if ($group -eq 'game-mode') { Check -What "group $group is gaming" -Ok ($tweak.group -eq 'gaming') } else { Check -What "group $group is speed" -Ok ($tweak.group -eq 'speed') } }
$tmp = Join-Path $env:TEMP ("wtcli-test-" + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $tmp 'scripts') | Out-Null
    $tmpCli = Join-Path $tmp 'wtcli.ps1'
    Copy-Item $cli -Destination $tmp
    Copy-Item (Join-Path $repo 'VERSION') -Destination $tmp
    Copy-Item (Join-Path $repo 'scripts\01-network-tune.ps1') -Destination (Join-Path $tmp 'scripts')
    $r = Invoke-Cli $tmpCli @('tune','list')
    Check -What 'Initial tune list exit 0' -Ok ($r.Code -eq 0)
    Check -What 'power-min undo_ready false' -Ok ((Get-Tweak ($r.Text | ConvertFrom-Json) 'power-min').undo_ready -eq $false)
    Set-Content -Path (Join-Path $tmp 'scripts\02-power-tune-revert.ps1') -Value '# planted'
    $r = Invoke-Cli $tmpCli @('tune','list')
    Check -What 'After revert script' -Ok ($r.Code -eq 0)
    Check -What 'power-min undo_ready true' -Ok ((Get-Tweak ($r.Text | ConvertFrom-Json) 'power-min').undo_ready -eq $true)
    Set-Content -Path (Join-Path $tmp 'scripts\01-network-tune.ps1') -Value 'function Nothing {}'
    $r = Invoke-Cli $tmpCli @('tune','list')
    Check -What 'Exit code 1 after overwriting' -Ok ($r.Code -eq 1)
    $j = $r.Text | ConvertFrom-Json
    Check -What 'ok false' -Ok ($j.ok -eq $false)
    Check -What 'reason not empty' -Ok ($j.reason -ne $null)
    $r = Invoke-Cli $tmpCli @('bogus','cmd')
    Check -What 'Exit code 2 for bogus command' -Ok ($r.Code -eq 2)
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
$ast = [System.Management.Automation.Language.Parser]::ParseFile($cli, [ref]$null, [ref]$null)
$functions = $ast.FindAll({$args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)
foreach ($f in $functions) { . ([scriptblock]::Create($f.Extent.Text)) }
$row = New-TweakRow -Id 'x' -Group 'speed' -Name 'x' -Current $null -Recommended '0%' -State 'unknown' -UndoReady $false -NeedsAdmin $true -Why 'x'
Check -What 'a null current stays null' -Ok ((($row | ConvertTo-Json -Compress) -match '"current":null'))
$n = Get-NicTweakRow -Pending $null -Total 15 -UndoReady $false
Check -What 'n.state unknown' -Ok ($n.state -eq 'unknown')
Check -What 'n.current null' -Ok ($null -eq $n.current)
Check -What 'Get-SideState null null 0' -Ok ((Get-SideState -Ac $null -Dc $null -Target 0) -eq 'unknown')
Check -What 'Get-SideState 0 0 0' -Ok ((Get-SideState 0 0 0) -eq 'on')
Check -What 'Get-SideState 5 0 0' -Ok ((Get-SideState 5 0 0) -eq 'partial')
Check -What 'Get-SideState null 0 0' -Ok ((Get-SideState $null 0 0) -eq 'partial')
Check -What 'Get-SideState 5 5 0 is off' -Ok ((Get-SideState 5 5 0) -eq 'off')
if ($script:checks -eq 0) { Write-Host 'FAIL checked nothing'; exit 2 }
Write-Host "$($script:checks) checks, $($script:fails) failed"
if ($script:fails -gt 0) { exit 1 } else { exit 0 }
