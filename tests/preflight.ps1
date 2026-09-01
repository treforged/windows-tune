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
         (or reports no) revert files without touching anything.
      7. install.ps1 -FromZip <zip built from this tree> -Path <temp>:
         files land, are unblocked, a pre-existing revert file survives,
         temp files cleaned up.
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

if ($fails.Count) { Write-Host "`n$($fails.Count) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "`nall green" -ForegroundColor Green
exit 0
