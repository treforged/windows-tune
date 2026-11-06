<#
.SYNOPSIS
    Elevated end-to-end test of the update machinery, in a throwaway Program Files folder.

.DESCRIPTION
    Run ELEVATED, by the maintainer, before cutting a release. It never touches an existing windows-tune
    install: it works in %ProgramFiles%\windows-tune-elevtest, which it refuses to reuse, and it removes
    that folder and the 'windows-tune update' scheduled task when it ends.

    It unpacks a release zip into that folder as the "installed" copy (VERSION set back to v1.1.0), then:
      1. reads the status: the shipped signing key fingerprint, mode Off.
      2. SetMode Check: the task is registered, the mode reads back Check, the revert file exists.
         Running the revert file removes the task and puts the mode back to Off.
      3. SetMode Install -Yes: task registered with the highest run level and two triggers; SetMode Off removes it.
      4. The REAL Invoke-UpdateInstall (lifted from the installed script) with file:// URLs, so no GitHub is needed:
         a tampered zip (hash matches, signature does not), a signature made by ANOTHER key, no .sig, and a wrong
         digest must each refuse and leave the installed VERSION and files unchanged. Then the real zip with its
         real signature must install, the VERSION must read the new tag, the previous copy and the revert file
         must exist, and running the revert file must put the old VERSION back.
    Results go to -Out, one PASS or FAIL line each. Exit 0 only when every check passed.

.PARAMETER Zip
    The release zip to test (windows-tune-vX.Y.Z.zip).

.PARAMETER Sig
    Its signature file (windows-tune-vX.Y.Z.zip.sig).

.PARAMETER Out
    Where to write the result lines.

.PARAMETER Tag
    The version the zip carries. Default v1.2.0.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Zip,
    [Parameter(Mandatory)][string]$Sig,
    [Parameter(Mandatory)][string]$Out,
    [string]$Tag = 'v1.2.0'
)
$ErrorActionPreference = 'Stop'
$script:bad = 0
Remove-Item -LiteralPath $Out -ErrorAction SilentlyContinue
function Log([string]$m) { Add-Content -LiteralPath $Out -Value $m -Encoding ASCII; Write-Host $m }
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Log "PASS $name" } else { $script:bad++; Log "FAIL $name $detail" } }
function Invoke-Child([string]$File, [string[]]$Arguments) {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $text = (& { $ErrorActionPreference = 'Continue'; & $ps -NoProfile -ExecutionPolicy Bypass -File $File @Arguments 2>&1 }) -join "`n"
    return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = $text }
}

$TASK = 'windows-tune update'
$base = Join-Path $env:ProgramFiles 'windows-tune-elevtest'
$stage = Join-Path $env:ProgramFiles 'windows-tune-elevtest-src'
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Log 'FAIL not elevated: run this from an elevated PowerShell'; exit 1 }
    if ((Test-Path $base) -or (Test-Path $stage)) { Log "FAIL refusing to reuse $base or $stage (remove it first)"; exit 1 }
    if (Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue) { Log "FAIL a task named '$TASK' already exists; this test will not touch it"; exit 1 }
    foreach ($f in $Zip, $Sig) { if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Log "FAIL missing $f"; exit 1 } }
    $Zip = (Resolve-Path -LiteralPath $Zip).Path; $Sig = (Resolve-Path -LiteralPath $Sig).Path

    # --- the "installed" copy, one version behind -------------------------------------------------------------
    New-Item -ItemType Directory -Path $stage | Out-Null
    Expand-Archive -LiteralPath $Zip -DestinationPath $stage
    $top = @(Get-ChildItem $stage -Directory)
    Check 'the zip unpacks to one top folder' ($top.Count -eq 1)
    New-Item -ItemType Directory -Path $base | Out-Null
    Copy-Item -Path (Join-Path $top[0].FullName '*') -Destination $base -Recurse -Force
    $old = 'v1.1.0'
    Set-Content -LiteralPath (Join-Path $base 'VERSION') -Value $old -Encoding ASCII
    $s10 = Join-Path $base 'scripts\10-auto-update.ps1'
    Check 'the installed copy carries the shipped public key' (Test-Path (Join-Path $base 'scripts\update-pubkey.xml'))

    # --- 1. status ---------------------------------------------------------------------------------------------
    $r = Invoke-Child $s10 @('-Status')
    Check 'status: mode Off and a key fingerprint shown' ($r.Exit -eq 0 -and $r.Text -match 'Update mode: Off' -and $r.Text -match 'fingerprint [0-9a-f]{64}') $r.Text

    # --- 2. Check mode and its revert ---------------------------------------------------------------------------
    $r = Invoke-Child $s10 @('-SetMode', 'Check')
    $t = Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
    $modeFile = Join-Path $base 'scripts\10-update-mode.json'
    Check 'SetMode Check: exit 0, task registered, mode reads back Check' ($r.Exit -eq 0 -and $t -and ((Get-Content $modeFile -Raw) -match '"mode":"Check"')) $r.Text
    $rev = Join-Path $base 'scripts\10-update-task-revert.ps1'
    Check 'SetMode Check wrote 10-update-task-revert.ps1' (Test-Path $rev)
    if (Test-Path $rev) {
        $rr = Invoke-Child $rev @()
        Check 'running the revert removes the task, sets mode Off, removes itself' ($rr.Exit -eq 0 -and -not (Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue) -and ((Get-Content $modeFile -Raw) -match 'Off') -and -not (Test-Path $rev)) $rr.Text
    }

    # --- 3. Install mode registration, then Off -------------------------------------------------------------------
    $r = Invoke-Child $s10 @('-SetMode', 'Install', '-Yes')
    $t = Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
    $okTask = $false
    if ($t) { $okTask = ($t.Principal.RunLevel -eq 'Highest') -and (@($t.Triggers).Count -eq 2) }
    Check 'SetMode Install: task registered, highest run level, two triggers' ($r.Exit -eq 0 -and $okTask) $r.Text
    $r = Invoke-Child $s10 @('-SetMode', 'Off')
    Check 'SetMode Off removes the task and reads back Off' ($r.Exit -eq 0 -and -not (Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue) -and ((Get-Content $modeFile -Raw) -match 'Off')) $r.Text

    # --- 4. the real install code, file:// instead of GitHub ----------------------------------------------------------
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($s10, [ref]$null, [ref]$null)
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($fn.Extent.Text)) }
    $here = Join-Path $base 'scripts'; $root = $base
    $logPath = Join-Path $here '10-update.log'; $noticePath = Join-Path $here '10-update-notice.txt'
    $installRevert = Join-Path $here '10-update-revert.ps1'; $pubKeyPath = Join-Path $here 'update-pubkey.xml'
    $isAdmin = $true
    if (Test-GameNow) { Log 'FAIL a game from the game list is running, so Install would skip; close it and rerun'; $script:bad++ }
    else {
        $digest = (Get-FileHash -Algorithm SHA256 -LiteralPath $Zip).Hash.ToLowerInvariant()
        $uri = { param($p) ([Uri]$p).AbsoluteUri }
        $verdict = { param($zipPath, $sigPath, $dg) [pscustomobject]@{ Status = 'Newer'; Installed = $old; Latest = $Tag; Digest = $dg; Url = (& $uri $zipPath); SigUrl = $(if ($sigPath) { & $uri $sigPath } else { $null }) } }
        $unchanged = { ((Get-Content (Join-Path $base 'VERSION') -Raw).Trim() -eq $old) -and -not (Test-Path "$base.previous") -and -not (Test-Path $installRevert) }
        function Try-Install($v, [string]$expect, [string]$name) {
            $msg = ''
            try { Invoke-UpdateInstall $v } catch { $msg = $_.Exception.Message }
            Check $name ($msg -match $expect -and (& $unchanged)) "got [$msg]"
        }
        # tampered: the bytes change AFTER signing; the digest is recomputed so only the signature can catch it
        $tam = Join-Path $stage 'tampered.zip'
        $bytes = [IO.File]::ReadAllBytes($Zip); $bytes[$bytes.Length - 5] = $bytes[$bytes.Length - 5] -bxor 0xFF
        [IO.File]::WriteAllBytes($tam, $bytes)
        $tamDigest = (Get-FileHash -Algorithm SHA256 -LiteralPath $tam).Hash.ToLowerInvariant()
        Try-Install (& $verdict $tam $Sig $tamDigest) 'Signature check failed' 'REAL install code: a tampered zip with a matching hash is refused, nothing installed'
        # another key signs the real zip
        $rsa2 = New-Object System.Security.Cryptography.RSACryptoServiceProvider(3072); $rsa2.PersistKeyInCsp = $false
        $sig2 = Join-Path $stage 'otherkey.sig'
        [IO.File]::WriteAllText($sig2, [Convert]::ToBase64String($rsa2.SignData([IO.File]::ReadAllBytes($Zip), 'SHA256')), [Text.Encoding]::ASCII); $rsa2.Dispose()
        Try-Install (& $verdict $Zip $sig2 $digest) 'Signature check failed' 'REAL install code: a signature from ANOTHER key is refused, nothing installed'
        Try-Install (& $verdict $Zip $null $digest) 'publishes no \.sig' 'REAL install code: a release with no .sig is refused, nothing installed'
        Try-Install (& $verdict $Zip $Sig ('0' * 64)) 'SHA256 mismatch' 'REAL install code: a wrong digest is refused, nothing installed'
        # the real thing
        $beforeFiles = @(Get-ChildItem $base -Recurse -File).Count
        $msg = ''
        try { Invoke-UpdateInstall (& $verdict $Zip $Sig $digest) } catch { $msg = $_.Exception.Message }
        $ver = (Get-Content (Join-Path $base 'VERSION') -Raw).Trim()
        Check "REAL install code: the signed zip installs, VERSION reads $Tag" ($msg -eq '' -and $ver -eq $Tag) "msg [$msg] version [$ver]"
        Check 'the previous copy was kept and the revert file written' ((Test-Path "$base.previous") -and (Test-Path $installRevert))
        Check 'the shipped public key survived the update unchanged' ((Get-KeyFingerprint (Get-Content $pubKeyPath -Raw)) -eq (Get-KeyFingerprint (Get-Content (Join-Path $top[0].FullName 'scripts\update-pubkey.xml') -Raw)))
        if (Test-Path $installRevert) {
            $rr = Invoke-Child $installRevert @()
            $ver = (Get-Content (Join-Path $base 'VERSION') -Raw).Trim()
            Check "running 10-update-revert.ps1 puts VERSION back to $old and removes itself" ($rr.Exit -eq 0 -and $ver -eq $old -and -not (Test-Path $installRevert)) "exit $($rr.Exit) version [$ver] $($rr.Text)"
        }
    }
} catch {
    $script:bad++
    Log "FAIL the test itself threw: $($_.Exception.Message)"
} finally {
    Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue | ForEach-Object { Unregister-ScheduledTask -TaskName $TASK -Confirm:$false -ErrorAction SilentlyContinue }
    foreach ($d in $base, "$base.previous", $stage) { if ($d -like "$env:ProgramFiles\windows-tune-elevtest*" -and (Test-Path -LiteralPath $d)) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }
    Check 'cleanup: the test folders and the task are gone' (-not (Test-Path $base) -and -not (Test-Path $stage) -and -not (Test-Path "$base.previous") -and -not (Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue))
    Log "DONE failures=$script:bad"
}
exit $(if ($script:bad) { 1 } else { 0 })
