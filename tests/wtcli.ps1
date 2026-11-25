# Gate for wtcli.ps1 (GUS-88): the real read-only run, advisor inventory with a planted HKCU Run entry (removed in finally), planted revert/failure state in a temp copy, and the null rule.
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
# stage 4
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$apKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$plant = 'wtcli-test-' + [guid]::NewGuid().ToString('N')
try {
    New-ItemProperty -Path $runKey -Name $plant -Value 'cmd.exe /c rem' -PropertyType String -Force | Out-Null
    $r = Invoke-Cli $cli @('advisor','inventory')
    Check -What 'inventory exit 0' -Ok ($r.Code -eq 0)
    $inv = $r.Text | ConvertFrom-Json
    Check -What 'inventory ok' -Ok ($inv.ok -eq $true)
    Check -What 'inventory has processes, services, drivers' -Ok ((@($inv.processes).Count -gt 0) -and (@($inv.services).Count -gt 0) -and (@($inv.drivers).Count -gt 0))
    $e = @($inv.startup | Where-Object { $_.name -eq $plant })
    Check -What 'planted Run entry is listed once as user/run' -Ok (($e.Count -eq 1) -and ($e[0].scope -eq 'user') -and ($e[0].kind -eq 'run'))
    Check -What 'planted entry with no approval byte reads enabled' -Ok ($e[0].state -eq 'enabled')
    if (-not (Test-Path -LiteralPath $apKey)) { New-Item -Path $apKey -Force | Out-Null }
    New-ItemProperty -Path $apKey -Name $plant -Value ([byte[]](3,0,0,0,0,0,0,0,0,0,0,0)) -PropertyType Binary -Force | Out-Null
    $inv = (Invoke-Cli $cli @('advisor','inventory')).Text | ConvertFrom-Json
    $e = @($inv.startup | Where-Object { $_.name -eq $plant })
    Check -What 'approval byte 03 reads disabled' -Ok ($e[0].state -eq 'disabled')
} finally {
    Remove-ItemProperty -Path $runKey -Name $plant -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $apKey -Name $plant -ErrorAction SilentlyContinue
}
Check -What 'planted entry removed' -Ok ($null -eq (Get-ItemProperty -Path $runKey -Name $plant -ErrorAction SilentlyContinue))
# stage 5: apply then undo round-trip on a FIXTURE (Sam 11-25: never on live settings)
$fx = Join-Path $env:TEMP ('wtcli-fx-' + [guid]::NewGuid().ToString('N'))
try
{
    New-Item -ItemType Directory -Path (Join-Path $fx 'privacy') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fx 'scripts') | Out-Null
    Copy-Item $cli -Destination $fx
    Copy-Item (Join-Path $repo 'VERSION') -Destination $fx
    Copy-Item (Join-Path $repo 'scripts\01-network-tune.ps1') -Destination (Join-Path $fx 'scripts')
    $fxCli = Join-Path $fx 'wtcli.ps1'
    $marker = Join-Path $fx 'privacy\applied.txt'
    $privacyScript = Join-Path $fx 'privacy\privacy-tune.ps1'
    $scriptContent = @'
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'applied.txt') -Value 'on'
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'privacy-tune-revert.ps1') -Value 'Remove-Item -LiteralPath (Join-Path $PSScriptRoot ''applied.txt''); Remove-Item -LiteralPath $PSCommandPath'
exit 0
'@
    Set-Content -LiteralPath $privacyScript -Value $scriptContent
    $r = Invoke-Cli $fxCli @('net','undo','privacy')
    Check -What 'undo before apply refuses: no undo recorded, exit 1' -Ok (($r.Code -eq 1) -and (($r.Text | ConvertFrom-Json).reason -eq 'no undo recorded'))
    $out = Join-Path $fx 'out.json'
    $r = Invoke-Cli $fxCli @('net','apply','privacy','-Out',$out)
    $j = $r.Text | ConvertFrom-Json
    Check -What 'fixture apply exit 0 and ok' -Ok (($r.Code -eq 0) -and ($j.ok -eq $true))
    Check -What 'fixture apply changed the fixture' -Ok ((Test-Path -LiteralPath $marker) -and ($j.changed -eq $true))
    Check -What 'apply names its undo file' -Ok ([string]$j.undo).EndsWith('privacy-tune-revert.ps1')
    Check -What '-Out file equals stdout' -Ok ((Test-Path -LiteralPath $out) -and ((Get-Content -LiteralPath $out -Raw).Trim().TrimStart([char]0xFEFF) -eq $r.Text.Trim()))
    $r = Invoke-Cli $fxCli @('net','undo','privacy')
    Check -What 'fixture undo exit 0 and the change is gone' -Ok (($r.Code -eq 0) -and -not (Test-Path -LiteralPath $marker))
    Check -What 'undo readback says no undo file' -Ok ((($r.Text | ConvertFrom-Json).readback) -eq 'no undo file')
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin)
    {
        $r = Invoke-Cli $fxCli @('tune','apply','power-min')
        Check -What 'admin action unelevated returns needs_admin, exit 3' -Ok (($r.Code -eq 3) -and (($r.Text | ConvertFrom-Json).reason -eq 'needs_admin'))
    }
}
finally
{
    Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:checks -eq 0) { Write-Host 'FAIL checked nothing'; exit 2 }
Write-Host "$($script:checks) checks, $($script:fails) failed"
if ($script:fails -gt 0) { exit 1 } else { exit 0 }
