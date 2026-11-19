# context-menu-live.ps1 - proves scripts/12-context-menu.ps1 BOTH WAYS on this PC, for the current user.
# It applies the script, checks what Windows' own shell now lists in the right-click menu, runs the undo,
# checks again, and checks the Shell Extensions key is back byte-for-byte. No admin needed (HKCU only).
# Each menu reading is taken 5 times (see Read-Menu for why).
# Exit 0 = proven both ways. Exit 1 = a check failed. Exit 2 = it could not measure (e.g. no Clipchamp).
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $repo 'scripts\12-context-menu.ps1'
$fails = 0
function Pass($m) { Write-Host "ok    $m" }
function Fail($m) { Write-Host "FAIL  $m"; $script:fails++ }
if (Test-Path (Join-Path $repo 'scripts\12-context-menu-state.json')) { Write-Host 'Already applied on this PC; run its -Undo first. Nothing tested.'; exit 2 }

$work = Join-Path $env:TEMP ('wt-cm-' + [Guid]::NewGuid())
New-Item -ItemType Directory -Path (Join-Path $work 'folder') | Out-Null
Set-Content -LiteralPath (Join-Path $work 'folder\a.mp4') -Value '' -Encoding ASCII
$ext = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Shell Extensions'

$reader = Join-Path $work 'read-menu.ps1'
Set-Content -LiteralPath $reader -Encoding ASCII -Value @'
param([string]$w)
$sh = New-Object -ComObject Shell.Application
$f = ($sh.Namespace((Join-Path $w 'folder')).ParseName('a.mp4').Verbs() | ForEach-Object { $_.Name }) -join '|'
$d = ($sh.Namespace($w).ParseName('folder').Verbs() | ForEach-Object { $_.Name }) -join '|'
'{0}{1}' -f [int]($f -match 'Clipchamp'), [int]($d -match 'Open in Admin Terminal')
'@

function Read-Menu {
    # A NEW process for each reading, so nothing is cached from an earlier one.
    # Measured 11-19: with NO change, Clipchamp's packaged item sometimes fails to load (10,10,00).
    # So "present" in ANY of 5 readings counts as present, and "gone" needs all 5 to agree.
    # The admin item is a plain registry verb and must read the same every time.
    $r = @(1..5 | ForEach-Object { Start-Sleep -Milliseconds 700; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $reader -w $work })
    $clip = if (@($r | Where-Object { $_ -like '1?' }).Count -gt 0) { '1' } else { '0' }
    $adm = @($r | ForEach-Object { "$_".Substring(1, 1) } | Select-Object -Unique)
    if ($adm.Count -ne 1) { return "unstable-admin:$($r -join ',')" }
    return $clip + $adm[0]
}

try {
    & reg.exe export $ext (Join-Path $work 'before.reg') /y | Out-Null
    $before = Read-Menu
    if ($before -ne '10') { Write-Host "Cannot measure: expected Clipchamp listed and no admin item before, got '$before'."; exit 2 }
    Pass 'before: Edit with Clipchamp is listed, Open in Admin Terminal is not'

    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool
    if ($LASTEXITCODE -eq 0) { Pass 'apply exit 0' } else { Fail "apply exit $LASTEXITCODE`n$out" }
    $after = Read-Menu
    if ($after -eq '01') { Pass 'after apply: Clipchamp is gone and Open in Admin Terminal is listed (5 readings)' } else { Fail "after apply the menu reads '$after', expected 01" }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool | Out-Null
    if ($LASTEXITCODE -eq 2) { Pass 'a second apply refuses (exit 2) instead of stacking' } else { Fail "a second apply returned $LASTEXITCODE, expected 2" }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\12-context-menu-revert.ps1') | Out-Null
    if ($LASTEXITCODE -eq 0) { Pass 'undo exit 0' } else { Fail "undo exit $LASTEXITCODE" }
    $back = Read-Menu
    if ($back -eq '10') { Pass 'after undo: the menu is back as it was (5 readings)' } else { Fail "after undo the menu reads '$back', expected 10" }

    & reg.exe export $ext (Join-Path $work 'after.reg') /y | Out-Null
    $a = Get-Content (Join-Path $work 'before.reg') -Encoding Unicode; $b = Get-Content (Join-Path $work 'after.reg') -Encoding Unicode
    if ((Compare-Object $a $b).Count -eq 0) { Pass 'Shell Extensions key is byte-for-byte as before' } else { Fail ('Shell Extensions key differs after undo: ' + ((Compare-Object $a $b | Select-Object -First 3 | ForEach-Object { $_.InputObject }) -join ' ; ')) }
    foreach ($r in 'Directory\Background', 'Directory', 'Drive') {
        if (Test-Path "HKCU:\Software\Classes\$r\shell\runas") { Fail "undo left HKCU\Software\Classes\$r\shell\runas" } else { Pass "no runas key left under $r" }
    }
} finally {
    # A failed run must never leave the user's profile changed: restore from this test's own snapshot,
    # not from the script under test (which may be the thing that is broken).
    $snapIn = Join-Path $work 'before.reg'
    if (Test-Path -LiteralPath $snapIn) {
        & reg.exe export $ext (Join-Path $work 'final.reg') /y | Out-Null
        $x = Get-Content $snapIn -Encoding Unicode; $y = Get-Content (Join-Path $work 'final.reg') -Encoding Unicode
        if ((Compare-Object $x $y).Count -ne 0) {
            # reg.exe writes its success line to stderr, which Stop would turn into a throw here.
            $ErrorActionPreference = 'Continue'
            & cmd.exe /c "reg delete `"$ext\Blocked`" /f >nul 2>&1"
            & cmd.exe /c "reg import `"$snapIn`" >nul 2>&1"
            Write-Host 'restored the Shell Extensions key from the test snapshot'
        }
    }
    foreach ($r in 'Directory\Background', 'Directory', 'Drive') { Remove-Item -LiteralPath "HKCU:\Software\Classes\$r\shell\runas" -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath (Join-Path $repo 'scripts\12-context-menu-state.json'), (Join-Path $repo 'scripts\12-context-menu-revert.ps1') -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
if ($fails) { Write-Host "$fails FAILED"; exit 1 }
Write-Host 'proven both ways'; exit 0
