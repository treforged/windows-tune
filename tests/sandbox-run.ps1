<#
.SYNOPSIS
    Run windows-tune inside Windows Sandbox - a real other machine, disposable.

.DESCRIPTION
    Every other check in this repo runs on the machine that wrote it. That is the
    known limit of all of them: this box has the toolchain, the tuned NIC, the
    English locale and an already-installed everything. Windows Sandbox is a
    clean, default Windows that is thrown away when it closes, which is the
    closest thing to a stranger's PC available without a second computer.

    What it exercises that nothing else can:
      - the INSTALLER as a stranger runs it, into a profile that has never seen
        this repo, with no toolchain and no network
      - the ELEVATED paths, safely: the sandbox user is an administrator and the
        whole machine evaporates on close, so a script that changes a system
        setting can be RUN rather than reasoned about
      - a default Windows: whatever this repo silently assumes is present, is not

.PARAMETER RunTune
    Also press option 1 (network tune) inside the sandbox, elevated, for real.
    Off by default - the read-only stages prove the install and the menu first,
    and a failure there should not be buried under a tuning run.

.PARAMETER KeepArtifacts
    Do not delete the staging folder afterwards. For reading what the sandbox
    left behind when something failed.

.NOTES
    SECURITY. The repo goes in READ-ONLY, so nothing inside the sandbox can
    modify this working tree. Exactly one writable folder is mapped - a fresh
    empty temp directory for the result file - because a writable host mapping is
    the one way a disposable VM can reach back into the real machine. Networking
    is DISABLED: the install is proven from a local zip, which is also the
    offline path a cautious stranger uses.
#>
[CmdletBinding()]
param(
    [switch]$RunTune,
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'

# Resolve this script's own folder BEFORE anything is derived from it.
# Split-Path THROWS on an empty string, so this is checked before it is called.
$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { throw 'Cannot resolve this script''s own folder. Run it as a file (.\tests\sandbox-run.ps1), not by pasting its body into a console.' }
$repo = Split-Path -Parent $here

function Fail($m) { Write-Host "FAIL  $m" -ForegroundColor Red }
function Pass($m) { Write-Host "ok    $m" -ForegroundColor Green }
function Note($m) { Write-Host "      $m" -ForegroundColor DarkGray }

# ---------------------------------------------------------- preconditions ----
$exe = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
if (-not (Test-Path $exe)) {
    Fail 'Windows Sandbox is not installed, so this proved nothing.'
    Note 'Enable it ELEVATED, then reboot:'
    Note '  Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -NoRestart'
    Note 'It needs Windows Pro/Enterprise and virtualization enabled in firmware.'
    exit 1
}
Pass 'Windows Sandbox is installed'

# --------------------------------------------------------------- staging -----
# in: the repo as a zip, read-only. out: an empty folder, writable, nothing else.
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stage = Join-Path $env:TEMP "wt-sandbox-$stamp"
$inDir = Join-Path $stage 'in'
$outDir = Join-Path $stage 'out'
New-Item -ItemType Directory -Path $inDir | Out-Null
New-Item -ItemType Directory -Path $outDir | Out-Null

$zip = Join-Path $inDir 'windows-tune.zip'
$stageRepo = Join-Path $stage 'repo\windows-tune'
New-Item -ItemType Directory -Path $stageRepo -Force | Out-Null
Get-ChildItem $repo -Force | Where-Object { $_.Name -ne '.git' } | Copy-Item -Destination $stageRepo -Recurse -Force
Compress-Archive -Path $stageRepo -DestinationPath $zip -Force
Remove-Item (Join-Path $stage 'repo') -Recurse -Force
Pass "staged a zip of this tree ($([math]::Round((Get-Item $zip).Length / 1KB)) KB)"

# The script the sandbox runs on logon. It writes ONE result file to the mapped
# writable folder; the host reads that file and nothing else.
$guest = @'
$ErrorActionPreference = 'Continue'
$out = 'C:\out\result.txt'
$log = New-Object System.Collections.Generic.List[string]
function Say($m) { $log.Add($m); Write-Host $m }
function Flush { Set-Content -Path $out -Value $log -Encoding UTF8 }

Say "SANDBOX $(Get-Date -Format s)"
Say "OS: $((Get-CimInstance Win32_OperatingSystem).Caption) $((Get-CimInstance Win32_OperatingSystem).OSArchitecture)"
Say "Culture: $((Get-Culture).Name)  UICulture: $((Get-UICulture).Name)"
Say "PSVersion: $($PSVersionTable.PSVersion)"
Say "Elevated: $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
Say ''
Flush

# 1. the installer, offline, as a stranger runs it
$dest = Join-Path $env:LOCALAPPDATA 'windows-tune'
try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\in\install-from-zip.ps1' *>&1 | ForEach-Object { Say "  install: $_" }
    if (Test-Path (Join-Path $dest 'windows-tune.ps1')) { Say 'STAGE install: PASS' } else { Say 'STAGE install: FAIL - no windows-tune.ps1 at the target' }
} catch { Say "STAGE install: FAIL - $($_.Exception.Message)" }
Flush

# 2. the repo's own gate, on a machine that is not the one that wrote it
try {
    $pf = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dest 'tests\preflight.ps1') *>&1
    $code = $LASTEXITCODE
    foreach ($l in $pf) { if ("$l" -match '^(FAIL|\s*\d+ FAILED|all green)') { Say "  preflight: $l" } }
    Say "STAGE preflight: exit $code"
    if ($code -eq 0) { Say 'STAGE preflight: PASS' } else { Say 'STAGE preflight: FAIL' }
} catch { Say "STAGE preflight: FAIL - $($_.Exception.Message)" }
Flush

# 3. the menu's read-only path, elevated, on a default Windows
try {
    $m = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dest 'windows-tune.ps1') -AcceptRisk -Choice R *>&1
    Say "STAGE menu -Choice R: exit $LASTEXITCODE"
    foreach ($l in @($m)[0..([Math]::Min(14, @($m).Count - 1))]) { Say "  menu: $l" }
} catch { Say "STAGE menu: FAIL - $($_.Exception.Message)" }
Flush

# 4. 05 -Diagnose: reads Defender state on a machine whose Defender is untouched
try {
    $d = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dest 'scripts\05-defender-handover.ps1') -Diagnose *>&1
    Say "STAGE 05 -Diagnose: exit $LASTEXITCODE"
    foreach ($l in @($d)[0..([Math]::Min(14, @($d).Count - 1))]) { Say "  05: $l" }
} catch { Say "STAGE 05: FAIL - $($_.Exception.Message)" }
Flush

RUNTUNE_STAGE

Say ''
Say 'SANDBOX RUN COMPLETE'
Flush
'@

$runTuneBlock = if ($RunTune) {
    @'
# 5. option 1 for real, elevated, on a machine that is thrown away afterwards.
#    This is the first place this repo's write path has ever been RUN.
try {
    $t = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dest 'windows-tune.ps1') -AcceptRisk -Choice 1 *>&1
    Say "STAGE tune -Choice 1: exit $LASTEXITCODE"
    foreach ($l in @($t)) { Say "  tune: $l" }
    $rev = Get-ChildItem (Join-Path $dest 'scripts') -Filter '*-revert.ps1' -ErrorAction SilentlyContinue
    if ($rev) { Say "STAGE revert file written: $($rev.Name)" } else { Say 'STAGE revert file: NONE WRITTEN - the tune changed things with no way back' }
} catch { Say "STAGE tune: FAIL - $($_.Exception.Message)" }
Flush
'@
} else {
    "Say 'STAGE tune: skipped (pass -RunTune to press option 1 for real)'"
}

$guest = $guest.Replace('RUNTUNE_STAGE', $runTuneBlock)
Set-Content -Path (Join-Path $inDir 'guest.ps1') -Value $guest -Encoding UTF8

# the installer call, kept in its own file so the guest script stays readable
Set-Content -Path (Join-Path $inDir 'install-from-zip.ps1') -Encoding UTF8 -Value @'
$tmp = Join-Path $env:TEMP 'wt-unpack'
Expand-Archive -Path 'C:\in\windows-tune.zip' -DestinationPath $tmp -Force
$inner = @(Get-ChildItem $tmp -Directory)[0].FullName
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $inner 'install.ps1') -FromZip 'C:\in\windows-tune.zip'
'@

# ------------------------------------------------------------------ .wsb -----
$wsb = Join-Path $stage 'windows-tune.wsb'
$wsbXml = @"
<Configuration>
  <Networking>Disable</Networking>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$inDir</HostFolder>
      <SandboxFolder>C:\in</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$outDir</HostFolder>
      <SandboxFolder>C:\out</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell -NoProfile -ExecutionPolicy Bypass -File C:\in\guest.ps1</Command>
  </LogonCommand>
</Configuration>
"@
Set-Content -Path $wsb -Value $wsbXml -Encoding UTF8
Pass 'wrote the sandbox config (repo read-only, one writable out folder, no network)'

# ------------------------------------------------------------------- run -----
Write-Host ''
Write-Host 'Starting Windows Sandbox. It opens a window and runs on its own;' -ForegroundColor Cyan
Write-Host 'close that window when the run reports COMPLETE, or leave it - the' -ForegroundColor Cyan
Write-Host 'result file is written as it goes.' -ForegroundColor Cyan
Start-Process -FilePath $exe -ArgumentList "`"$wsb`""

$result = Join-Path $outDir 'result.txt'
$deadline = (Get-Date).AddMinutes(12)
$seen = 0
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    if (-not (Test-Path $result)) { continue }
    $lines = @(Get-Content $result -ErrorAction SilentlyContinue)
    if ($lines.Count -gt $seen) {
        $lines[$seen..($lines.Count - 1)] | ForEach-Object { Write-Host "  | $_" }
        $seen = $lines.Count
    }
    if ($lines -contains 'SANDBOX RUN COMPLETE') { break }
}

Write-Host ''
if (-not (Test-Path $result)) {
    Fail 'the sandbox wrote no result file at all - it did not start, or the logon command did not run'
    Note "staging kept at: $stage"
    exit 1
}
$all = @(Get-Content $result)
if ($all -notcontains 'SANDBOX RUN COMPLETE') {
    Fail 'the sandbox run did not finish inside 12 minutes - what it did write is above'
    Note "staging kept at: $stage"
    exit 1
}

$failed = @($all | Where-Object { $_ -match ': FAIL' })
Write-Host ''
if ($failed.Count) {
    foreach ($f in $failed) { Fail $f }
    Note "full result: $result"
    exit 1
}
Pass "every stage passed on a clean Windows ($(@($all | Where-Object { $_ -match '^STAGE ' }).Count) stages)"
if (-not $KeepArtifacts) { Remove-Item $stage -Recurse -Force } else { Note "staging kept at: $stage" }
exit 0
