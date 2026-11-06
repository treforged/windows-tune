<#
.SYNOPSIS
    Opt-in update choice for windows-tune: Off (default), Check and tell me, or Install updates automatically.

.DESCRIPTION
    Off      Nothing is checked and nothing runs. This is the default and what a fresh install has.
    Check    A scheduled task asks GitHub for the latest release and writes a notice you read with
             -Status (menu U). It downloads and installs nothing.
    Install  The same task also downloads the new release zip, checks its SHA256 against the digest
             GitHub publishes for that asset, checks what is inside the zip, keeps a copy of the
             current install in <install folder>.previous, and then installs it through install.ps1
             -FromZip -Sha256 (the same hash-checked path as a first install). A mismatch refuses
             and installs nothing. No downloaded file is ever run, and nothing is piped to Invoke-Expression.

    NEVER while a game is running: the task skips the whole run when a game from the game mode list
    (09-game-mode.json, else 09-game-mode.defaults.json) is running, and re-checks after the download.

    SIGNATURE. The SHA256 comes from the same GitHub release as the zip, so alone it proves only that the
    file is the release's file. It does NOT prove the publisher: whoever controls the release controls the
    hash too. So Install mode ALSO needs a detached RSA/SHA-256 signature (windows-tune-vX.Y.Z.zip.sig,
    made by tools\sign-release.ps1) that verifies against the public key in scripts\update-pubkey.xml,
    the key shipped with the INSTALLED copy. It refuses without the key file, without the .sig, with a
    signature made by another key, or when the zip was changed after signing. The private key lives on
    the maintainer's PC, outside every repo (tools\new-signing-key.ps1).

    LIMITS, said plainly:
      - The public key itself reaches a PC with the first install. That install is trusted by the SHA256
        pinned in install.ps1 on the main branch, so the first-install trust path is that pin and the
        maintainer's GitHub account, not the signature.
      - A new key cannot be pushed by an update (an update is verified with the OLD key). Rotating the key
        means a fresh manual install. If the private key is lost, installs carrying the old public key
        cannot take another automatic update.
      - A signature proves the maintainer signed those bytes. It does not prove the bytes are free of bugs.
    Check mode downloads and installs nothing, so it needs no key.

.PARAMETER Status
    Read-only. Shows the mode, the scheduled task, the installed version and the last notice. Default.

.PARAMETER Configure
    Ask which mode you want, explain it, and apply it. This is what menu V runs.

.PARAMETER SetMode
    Set Off, Check or Install without asking (a test, or a script).

.PARAMETER Run
    What the scheduled task runs. Does whatever the saved mode says, once.

.PARAMETER DryRun
    With -SetMode or -Run: say what would happen and change nothing.

.PARAMETER Yes
    With -SetMode Install: confirm the trust-limit prompt. Not used by the menu.
#>
[CmdletBinding()]
param(
    [switch]$Status,
    [switch]$Configure,
    [ValidateSet('Off', 'Check', 'Install')][string]$SetMode,
    [switch]$Run,
    [switch]$DryRun,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { throw 'Cannot resolve this script''s own folder. Run it as a file (.\10-auto-update.ps1).' }
$root = Split-Path -Parent $here

$TASK_NAME = 'windows-tune update'
$RepoSlug  = 'treforged/windows-tune'

# ------------------------------------------------------------ pure parts ----
# These take readings as arguments and touch nothing, so tests\preflight.ps1 CALLS them.

function Read-UpdateMode {
    # The saved mode, from the JSON text. Anything unreadable, missing or unknown is Off: the safe default.
    param([AllowNull()][string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return 'Off' }
    try { $m = [string]($Json | ConvertFrom-Json -ErrorAction Stop).mode } catch { return 'Off' }
    if ($m -in 'Check', 'Install') { return $m }
    return 'Off'
}

function Test-GameRunning {
    # $true when any listed game is in the running process names. $null list or names counts as running:
    # a game list that could not be read must not let an install through.
    param([AllowNull()][string[]]$Games, [AllowNull()][string[]]$Running)
    if ($null -eq $Games -or $Games.Count -eq 0 -or $null -eq $Running) { return $true }
    foreach ($g in $Games) {
        $n = ([string]$g).Trim().ToLowerInvariant() -replace '\.exe$', ''
        if ($n -and $Running -contains $n) { return $true }
    }
    return $false
}

function Get-UpdateAction {
    # What one scheduled run should do. Order matters: Off first, then game, then what GitHub said.
    param([string]$Mode, $Verdict, [bool]$GameRunning, [bool]$SafeToInstall, [bool]$KeyShipped = $true)
    if ($Mode -notin 'Check', 'Install') { return 'Off' }
    if ($GameRunning) { return 'SkipGame' }
    if (-not $Verdict -or $Verdict.Status -eq 'Unknown') { return 'SkipUnknown' }
    if ($Verdict.Status -ne 'Newer') { return 'UpToDate' }
    if ($Mode -eq 'Check') { return 'Notify' }
    if (-not $KeyShipped) { return 'SkipNoKey' }
    if (-not $SafeToInstall) { return 'SkipUnsafeFolder' }
    return 'Install'
}

function Get-KeyFingerprint {
    # SHA-256 (hex) of modulus + exponent of a public key in .NET XML form, or $null when it is not a usable key.
    param([AllowNull()][string]$PublicKeyXml)
    if ([string]::IsNullOrWhiteSpace($PublicKeyXml)) { return $null }
    $r = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    try {
        $r.FromXmlString($PublicKeyXml)
        $q = $r.ExportParameters($false)
        $sha = [Security.Cryptography.SHA256]::Create()
        return (($sha.ComputeHash([byte[]]($q.Modulus + $q.Exponent)) | ForEach-Object { $_.ToString('x2') }) -join '')
    } catch { return $null } finally { $r.Dispose() }
}

function Test-ReleaseSignature {
    # $null when SignatureText (base64) is a valid RSA/SHA-256 signature over the zip's bytes made by the key in
    # PublicKeyXml; otherwise a sentence naming why not. Every doubt is a refusal.
    param([byte[]]$ZipBytes, [AllowNull()][string]$SignatureText, [AllowNull()][string]$PublicKeyXml)
    if ([string]::IsNullOrWhiteSpace($PublicKeyXml)) { return 'no public key is shipped with this install (scripts\update-pubkey.xml), so a signature cannot be checked' }
    if ($PublicKeyXml -match '<(D|P|Q|DP|DQ|InverseQ)>') { return 'the shipped key file holds private key parts, so it is not trusted' }
    if ([string]::IsNullOrWhiteSpace($SignatureText)) { return 'the release has no signature file (.sig)' }
    if ($SignatureText.Length -gt 4096) { return 'the signature file is too large to be a signature' }
    if ($null -eq $ZipBytes -or $ZipBytes.Length -eq 0) { return 'the zip is empty' }
    try { $sig = [Convert]::FromBase64String($SignatureText.Trim()) } catch { return 'the signature file is not base64' }
    $r = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    try {
        try { $r.FromXmlString($PublicKeyXml) } catch { return 'the shipped public key could not be read' }
        if ($r.KeySize -lt 2048) { return "the shipped key is only $($r.KeySize) bits" }
        if (-not $r.VerifyData($ZipBytes, 'SHA256', $sig)) { return 'the signature does not match this zip and this key (changed after signing, or signed by another key)' }
        return $null
    } catch { return "the signature could not be checked: $($_.Exception.Message)" } finally { $r.Dispose() }
}

function Test-UpdateZipEntries {
    # $null when the entry names of a release zip look like windows-tune, else a sentence naming the problem.
    param([string[]]$Names, [string]$Tag)
    if (-not $Names -or $Names.Count -eq 0) { return 'the zip is empty' }
    $tops = @{}
    # every extension in the v1.1.0 release zip: .py is an inert lab script, .gitignore is how GetExtension reads a dotfile
    $allowedExt = '.ps1', '.md', '.json', '.cmd', '.txt', '.mjs', '.py', '.gitignore', ''
    foreach ($raw in $Names) {
        $n = ([string]$raw) -replace '\\', '/'
        if ($n -match '(^|/)\.\.(/|$)' -or $n.StartsWith('/') -or $n -match '^[A-Za-z]:' -or $n -match '[\x00-\x1f]') { return "the zip has an unsafe path: $raw" }
        $tops[($n -split '/')[0]] = $true
        if ($n.EndsWith('/')) { continue }
        $ext = [IO.Path]::GetExtension($n).ToLowerInvariant()
        if ($allowedExt -notcontains $ext) { return "the zip holds a file type this tool never ships: $raw" }
    }
    if ($tops.Count -ne 1) { return "the zip has $($tops.Count) top-level entries, expected one folder" }
    $top = @($tops.Keys)[0]
    foreach ($need in 'windows-tune.ps1', 'install.ps1', 'VERSION', 'NOTICE.md', 'scripts/10-auto-update.ps1') {
        if (-not ($Names | Where-Object { (($_ -replace '\\', '/') -eq "$top/$need") })) { return "the zip is missing $need" }
    }
    return $null
}

# Lift the verdict function from 07 and the folder check from the menu, through the Parser, so there is one copy of each.
function Get-FunctionText {
    # The source text of the named functions in $File, or $null when any is missing. The CALLER dot-sources
    # each one, because a function defined here would vanish when this function returns.
    param([string]$File, [string[]]$Names)
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$errors)
    $fns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $Names }, $true))
    if ($errors.Count -or $fns.Count -ne $Names.Count) { return $null }
    return @($fns | ForEach-Object { $_.Extent.Text })
}

if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced by a test: functions only

# ------------------------------------------------------------------ main ----
$pubKeyPath = Join-Path $here 'update-pubkey.xml'
function Get-ShippedKey { if (Test-Path -LiteralPath $pubKeyPath -PathType Leaf) { Get-Content -LiteralPath $pubKeyPath -Raw } else { $null } }
$modePath   = Join-Path $here '10-update-mode.json'
$noticePath = Join-Path $here '10-update-notice.txt'
$logPath    = Join-Path $here '10-update.log'
$taskRevert = Join-Path $here '10-update-task-revert.ps1'
$installRevert = Join-Path $here '10-update-revert.ps1'

function Write-UpdateLog([string]$Text, [string]$Color = 'Gray') {
    Write-Host $Text -ForegroundColor $Color
    try { Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format s) $Text" -Encoding UTF8 } catch { }
}
function Get-SavedMode { if (Test-Path -LiteralPath $modePath) { Read-UpdateMode (Get-Content -LiteralPath $modePath -Raw) } else { 'Off' } }
function Get-InstalledVersion { $v = Join-Path $root 'VERSION'; if (Test-Path -LiteralPath $v) { (Get-Content -LiteralPath $v -Raw).Trim() } else { $null } }
function Get-FolderRisk {
    # $null when this script, the menu, install.ps1 and every folder above are admin-only. Else a sentence.
    $menuPath = Join-Path $root 'windows-tune.ps1'
    $src = Get-FunctionText $menuPath @('Test-UserWritable', 'Get-UnsafeRunReason')
    if (-not $src) { return 'the folder check in windows-tune.ps1 could not be read' }
    foreach ($t in $src) { . ([scriptblock]::Create($t)) }
    foreach ($f in @($PSCommandPath, $menuPath, (Join-Path $root 'install.ps1'))) { $why = Get-UnsafeRunReason $f; if ($why) { return $why } }
    return $null
}
function Get-GameNames {
    $own = Join-Path $here '09-game-mode.json'
    $file = if (Test-Path -LiteralPath $own) { $own } else { Join-Path $here '09-game-mode.defaults.json' }
    try { return @((Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).games | Where-Object { $_ }) } catch { return $null }
}
function Get-RunningNames { @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName.ToLowerInvariant() }) }
function Test-GameNow { Test-GameRunning -Games (Get-GameNames) -Running (Get-RunningNames) }

function Get-LatestVerdict {
    $src = Get-FunctionText (Join-Path $here '07-update-check.ps1') @('Get-UpdateVerdict')
    if (-not $src) { return $null }
    foreach ($t in $src) { . ([scriptblock]::Create($t)) }
    $latest = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $latest = Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoSlug/releases/latest" -Headers @{ Accept = 'application/vnd.github+json' } -TimeoutSec 15
    } catch { Write-UpdateLog "Could not reach GitHub: $($_.Exception.Message)" 'Yellow' }
    return Get-UpdateVerdict -Installed (Get-InstalledVersion) -Latest $latest
}

function Show-Status {
    $mode = Get-SavedMode
    Write-Host "Update mode: $mode   (Off = default: nothing is checked)" -ForegroundColor Cyan
    Write-Host "Installed version: $(Get-InstalledVersion)"
    $fp = Get-KeyFingerprint (Get-ShippedKey)
    Write-Host "Release signing key: $(if ($fp) { "fingerprint $fp" } else { 'NONE shipped - Install mode is unavailable (Check still works)' })"
    $t = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    Write-Host "Scheduled task '$TASK_NAME': $(if ($t) { $t.State } else { 'not registered' })"
    if (Test-Path -LiteralPath $noticePath) { Write-Host "`nLast notice:" -ForegroundColor Yellow; Get-Content -LiteralPath $noticePath | ForEach-Object { Write-Host "  $_" } }
    else { Write-Host 'No update notice.' }
    Write-Host 'Change it with menu V. To see the latest release now, run scripts\07-update-check.ps1.'
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Set-UpdateMode {
    param([string]$Mode)
    if ($Mode -eq 'Install' -and -not (Get-KeyFingerprint (Get-ShippedKey))) {
        Write-Host 'REFUSED to turn Install on: this copy ships no release signing key (scripts\update-pubkey.xml), so a download could not be verified against the publisher. Use Check, or install a release that ships the key. Nothing was changed.' -ForegroundColor Red
        exit 5
    }
    if ($Mode -ne 'Off') {
        $risk = Get-FolderRisk
        if ($risk) {
            Write-Host "REFUSED to turn updates on: $risk, so a program running as you could change what the update task runs as administrator." -ForegroundColor Red
            Write-Host '  Install windows-tune with install.ps1 (Program Files) first. Nothing was changed.' -ForegroundColor Yellow
            exit 4
        }
    }
    $existing = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    if ($DryRun) {
        Write-Host "DRY RUN - mode would become $Mode (now $(Get-SavedMode)); task '$TASK_NAME' would be $(if ($Mode -eq 'Off') { 'removed' } else { 'registered at sign-in and daily, hidden, highest privileges' }). Nothing changed." -ForegroundColor Cyan
        return
    }
    if (-not $isAdmin) { throw 'Run this from an elevated PowerShell (Run as administrator). -DryRun works without it.' }
    if ($Mode -eq (Get-SavedMode) -and (($Mode -eq 'Off' -and -not $existing) -or ($Mode -ne 'Off' -and $existing))) {
        Write-Host 'already at target - nothing to change' -ForegroundColor Green; Write-Host "  mode is $Mode." -ForegroundColor DarkGray; return
    }
    if ($Mode -eq 'Off') {
        if ($existing) {
            Stop-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction Stop
            if (Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue) { throw "Task '$TASK_NAME' is still registered after Unregister-ScheduledTask." }
        }
        Remove-Item -LiteralPath $taskRevert, $noticePath -ErrorAction SilentlyContinue
    } else {
        $tn = "'" + ($TASK_NAME -replace "'", "''") + "'"
        Set-Content -LiteralPath $taskRevert -Encoding UTF8 -Value @(
            '# Auto-generated revert for 10-auto-update.ps1. Run ELEVATED. Turns automatic updates off.',
            "# Captured $(Get-Date -Format s). Removes the update task, sets the mode to Off, then removes itself.",
            "Stop-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue",
            "Unregister-ScheduledTask -TaskName $tn -Confirm:`$false -ErrorAction SilentlyContinue",
            "if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) { Write-Host 'The update task is still registered.' -ForegroundColor Red; exit 1 }",
            "Set-Content -LiteralPath (Join-Path `$PSScriptRoot '10-update-mode.json') -Value '{ ""mode"": ""Off"" }' -Encoding ASCII",
            'Remove-Item -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue',
            "Write-Host 'Automatic updates are off.' -ForegroundColor Green")
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action    = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Run" -WorkingDirectory $here
        $triggers  = @((New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME), (New-ScheduledTaskTrigger -Daily -At '12:00'))
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
        if ($existing) { Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false }
        Register-ScheduledTask -TaskName $TASK_NAME -Action $action -Trigger $triggers -Principal $principal -Settings $settings | Out-Null
        if (-not (Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue)) { throw "NOT CONFIRMED: task '$TASK_NAME' cannot be read back after registering." }
    }
    Set-Content -LiteralPath $modePath -Value (@{ mode = $Mode } | ConvertTo-Json -Compress) -Encoding ASCII
    $back = Get-SavedMode
    if ($back -ne $Mode) { throw "Mode reads $back after writing $Mode." }
    Write-Host "Update mode is now $Mode (read back)." -ForegroundColor Green
    if ($Mode -ne 'Off') { Write-Host "UNDO: menu R, or choose Off in menu V. Revert file: $taskRevert" -ForegroundColor Cyan }
}

function Invoke-UpdateInstall {
    param($Verdict)
    $stageRoot = $env:ProgramFiles
    $zip = Join-Path $stageRoot ('windows-tune-update-' + [Guid]::NewGuid().ToString() + '.zip')
    $installed = Get-InstalledVersion
    try {
        Write-UpdateLog "Downloading $($Verdict.Latest) ..." 'Cyan'
        Invoke-WebRequest -UseBasicParsing -Uri $Verdict.Url -OutFile $zip -TimeoutSec 180
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
        if ($actual -ne $Verdict.Digest) { throw "SHA256 mismatch: expected $($Verdict.Digest), got $actual. Nothing was installed." }
        Write-UpdateLog "SHA256 verified: $actual" 'Green'

        # The signature, against the key shipped with THIS install. Not the key inside the new zip.
        if (-not $Verdict.SigUrl) { throw 'The release publishes no .sig file. Nothing was installed.' }
        $sigResp = Invoke-WebRequest -UseBasicParsing -Uri $Verdict.SigUrl -TimeoutSec 60
        $sigText = if ($sigResp.Content -is [byte[]]) { [Text.Encoding]::ASCII.GetString($sigResp.Content) } else { [string]$sigResp.Content }
        $sigBad = Test-ReleaseSignature -ZipBytes ([IO.File]::ReadAllBytes($zip)) -SignatureText $sigText -PublicKeyXml (Get-ShippedKey)
        if ($sigBad) { throw "Signature check failed: $sigBad. Nothing was installed." }
        Write-UpdateLog 'Signature verified against the shipped release key.' 'Green'

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $za = [IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $names = @($za.Entries | ForEach-Object { $_.FullName })
            $bad = Test-UpdateZipEntries -Names $names -Tag $Verdict.Latest
            if ($bad) { throw "$bad. Nothing was installed." }
            $ver = $za.Entries | Where-Object { ($_.FullName -replace '\\', '/') -match '^[^/]+/VERSION$' } | Select-Object -First 1
            $sr = New-Object IO.StreamReader($ver.Open()); $zipVer = $sr.ReadToEnd().Trim(); $sr.Dispose()
        } finally { $za.Dispose() }
        if ($zipVer -ne $Verdict.Latest) { throw "The zip says it is $zipVer but the release is $($Verdict.Latest). Nothing was installed." }

        if (Test-GameNow) { Write-UpdateLog 'A game started while the download ran. Update skipped; it will retry at the next run.' 'Yellow'; return }

        $prev = "$root.previous"
        if (Test-Path -LiteralPath $prev) { Remove-Item -LiteralPath $prev -Recurse -Force }
        Copy-Item -LiteralPath $root -Destination $prev -Recurse -Force
        $pe = "'" + ($prev -replace "'", "''") + "'"; $re = "'" + ($root -replace "'", "''") + "'"
        Set-Content -LiteralPath $installRevert -Encoding UTF8 -Value @(
            '# Auto-generated revert for an automatic windows-tune update. Run ELEVATED.',
            "# Captured $(Get-Date -Format s). Puts back $installed from the copy kept before the update, then removes itself.",
            "if (-not (Test-Path -LiteralPath $pe)) { Write-Host 'The kept copy is gone: $prev' -ForegroundColor Red; exit 1 }",
            "Get-ChildItem -LiteralPath $pe -Force | Where-Object { `$_.Name -notlike '*-revert.ps1' } | Copy-Item -Destination $re -Recurse -Force",
            'Remove-Item -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue',
            "Write-Host 'Restored the previous windows-tune files ($installed).' -ForegroundColor Green")

        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'install.ps1') -FromZip $zip -Sha256 $Verdict.Digest -Path $root
        if ($LASTEXITCODE -ne 0) { throw "install.ps1 exited $LASTEXITCODE. The previous copy is in $prev; run $installRevert to restore it." }
        $now = Get-InstalledVersion
        if ($now -ne $Verdict.Latest) { throw "VERSION reads $now after the update, expected $($Verdict.Latest). Run $installRevert to restore $installed." }
        Write-UpdateLog "Updated $installed -> $now. UNDO: menu R (10-update-revert.ps1)." 'Green'
        Remove-Item -LiteralPath $noticePath -ErrorAction SilentlyContinue
    } finally {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-UpdateRun {
    $mode = Get-SavedMode
    if ($mode -eq 'Off') { Write-Host 'Automatic updates are off. Nothing was checked.'; return }   # no log file, no network, no task
    $gameNow = if ($mode -eq 'Off') { $false } else { Test-GameNow }
    $verdict = if ($mode -eq 'Off' -or $gameNow) { $null } else { Get-LatestVerdict }
    $risk = if ($mode -eq 'Install') { Get-FolderRisk } else { $null }
    $safe = ($mode -eq 'Install') -and (-not $risk) -and $isAdmin
    $action = Get-UpdateAction -Mode $mode -Verdict $verdict -GameRunning $gameNow -SafeToInstall $safe -KeyShipped ([bool](Get-KeyFingerprint (Get-ShippedKey)))
    Write-UpdateLog "Update run: mode $mode -> $action" 'Cyan'
    switch ($action) {
        'Off'              { Write-Host 'Automatic updates are off. Nothing was checked.' }
        'SkipGame'         { Write-UpdateLog 'A game is running. Nothing was checked or installed.' 'Yellow' }
        'SkipUnknown'      { Write-UpdateLog 'Update status UNKNOWN. This is not a claim you are up to date.' 'Yellow' }
        'UpToDate'         { Write-UpdateLog "windows-tune $($verdict.Installed) is the latest release." 'Green'; Remove-Item -LiteralPath $noticePath -ErrorAction SilentlyContinue }
        'SkipNoKey'        { Write-UpdateLog 'Install refused: this copy ships no release signing key. A notice was written instead.' 'Red' }
        'SkipUnsafeFolder' { Write-UpdateLog "Install refused: $(if ($risk) { $risk } else { 'this run is not elevated' }). A notice was written instead." 'Red' }
    }
    if ($action -in 'Notify', 'SkipUnsafeFolder', 'SkipNoKey') {
        $text = "A newer windows-tune is available: $($verdict.Latest) (you have $($verdict.Installed)). Checked $(Get-Date -Format s). Update with install.ps1, or choose Install in menu V."
        if ($DryRun) { Write-Host "DRY RUN - would write notice: $text" -ForegroundColor Cyan } else { Set-Content -LiteralPath $noticePath -Value $text -Encoding ASCII; Write-UpdateLog $text 'Cyan' }
    }
    if ($action -eq 'Install') {
        if ($DryRun) { Write-Host "DRY RUN - would download $($verdict.Url), verify SHA256 $($verdict.Digest), keep $root.previous, install through install.ps1." -ForegroundColor Cyan }
        else { Invoke-UpdateInstall $verdict }
    }
}

if ($Configure) {
    Write-Host "`nAutomatic updates for windows-tune. Now: $(Get-SavedMode)" -ForegroundColor Cyan
    Write-Host '  1. Off      - nothing is checked. (default)'
    Write-Host '  2. Check    - check GitHub at sign-in and daily, and leave a notice. Installs nothing.'
    Write-Host '  3. Install  - also download and install new releases by itself, never while a game runs.'
    $pick = (Read-Host 'Choice (1-3, Enter to leave it as it is)').Trim()
    $chosen = switch ($pick) { '1' { 'Off' } '2' { 'Check' } '3' { 'Install' } default { $null } }
    if (-not $chosen) { Write-Host 'Nothing changed.'; exit 0 }
    if ($chosen -eq 'Install') {
        Write-Host "`nREAD THIS: Install replaces an administrator-level tool without asking you. Each update must match the SHA256" -ForegroundColor Yellow
        Write-Host 'GitHub publishes AND carry a signature that verifies against the release key shipped with this copy. A copy' -ForegroundColor Yellow
        Write-Host 'without that key refuses. Limits: this copy was trusted at first install by the SHA256 pinned in install.ps1,' -ForegroundColor Yellow
        Write-Host 'and a new key needs a fresh manual install. A previous copy is kept, and menu R restores it.' -ForegroundColor Yellow
        if ((Read-Host 'Type INSTALL to turn this on') -cne 'INSTALL') { Write-Host 'Nothing changed.'; exit 0 }
    }
    Set-UpdateMode $chosen
    exit 0
}
if ($SetMode) {
    if ($SetMode -eq 'Install' -and -not $Yes -and -not $DryRun) { throw 'Install needs -Yes: it installs an administrator-level tool without asking, after a SHA256 and signature check (see Get-Help for the limits).' }
    Set-UpdateMode $SetMode
    exit 0
}
if ($Run) { Invoke-UpdateRun; exit 0 }
Show-Status
exit 0
