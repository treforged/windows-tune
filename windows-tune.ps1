<#
.SYNOPSIS
    Menu front-end for windows-tune: notice first, then one script at a time.

.DESCRIPTION
    Prints NOTICE.md (the risk and privacy notice) and refuses to run anything
    until you type I ACCEPT. Then it elevates itself once, shows a numbered
    menu of the scripts in scripts\, says what each one changes, confirms
    before any change, and lists the revert files the scripts have written.

    It runs nothing on its own. Every option calls one of the existing scripts
    with fixed arguments; nothing you type is turned into a command.

.PARAMETER Choice
    Run one menu option without showing the menu, then exit: 1-6, R or Q.

.PARAMETER AcceptRisk
    Skip the I ACCEPT prompt. The elevated relaunch passes this so you are not
    asked twice; a test can pass it too. It does not skip the y/N confirmation
    before a change - see -Yes.

.PARAMETER NoElevate
    Do not relaunch elevated. Only the storage report (1), the antivirus status
    check (2) and the revert-file listing (R) work without administrator
    rights; the rest will refuse.

.PARAMETER Yes
    Answer y to the "Run it?" confirmation. Never answers the I ACCEPT prompt.

.EXAMPLE
    .\windows-tune.ps1

.EXAMPLE
    .\windows-tune.ps1 -Choice 1 -AcceptRisk -NoElevate
    Run the read-only storage report without prompts, e.g. from a test.
#>
[CmdletBinding()]
param(
    [ValidateSet('1', '2', '3', '4', '5', '6', 'R', 'Q')][string]$Choice,
    [switch]$AcceptRisk,
    [switch]$NoElevate,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---- The notice gate. Nothing below runs until it passes. -------------------
$noticePath = Join-Path $here 'NOTICE.md'
if (-not (Test-Path $noticePath)) {
    Write-Host 'NOTICE.md is missing - refusing to run.' -ForegroundColor Red
    exit 2
}
Write-Host (Get-Content -Raw $noticePath)

if (-not $AcceptRisk) {
    $answer = Read-Host 'Type I ACCEPT to continue, anything else to quit'
    if ($answer -cne 'I ACCEPT') {
        Write-Host 'Nothing was run.' -ForegroundColor Yellow
        exit 3
    }
}

# ---- Elevation, once. -------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ($NoElevate) {
        Write-Host 'Not elevated: only the storage report (1), the antivirus status check (2) and the revert list (R) will work.' -ForegroundColor Yellow
    } else {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-AcceptRisk')
        if ($Choice) { $argList += @('-Choice', $Choice) }
        if ($Yes)    { $argList += '-Yes' }
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
        exit 0
    }
}

# ---- The menu. Script names and arguments are fixed here, never typed. ------
$scriptsDir = Join-Path $here 'scripts'
$menu = [ordered]@{
    '1' = @{ name = '03-storage-report.ps1';       args = @{};                        label = 'Storage report (read-only)';           changes = '' }
    '2' = @{ name = '05-defender-handover.ps1';    args = @{ Diagnose = $true };      label = 'Antivirus status check (read-only)';   changes = '' }
    '3' = @{ name = '01-network-tune.ps1';         args = @{ BounceAdapter = $true }; label = 'Network tune';
             changes = 'TCP auto-tuning, RSS, RSC, NIC offloads and NIC power-saving; bounces the adapter; writes 01-network-tune-revert.ps1' }
    '4' = @{ name = '02-power-tune.ps1';           args = @{};                        label = 'Power tune';
             changes = 'Minimum processor state of the active power plan; writes 02-power-tune-revert.ps1' }
    '5' = @{ name = '04-component-cleanup.ps1';    args = @{};                        label = 'Component store cleanup';
             changes = 'Removes superseded Windows update packages - NOT reversible' }
    '6' = @{ name = '06-remove-third-party-av.ps1'; args = @{};                       label = 'Remove a third-party antivirus';
             changes = 'UNINSTALLS a product you name - NOT reversible; the script asks for the product name itself' }
    'R' = @{ name = '';                            args = @{};                        label = 'List revert files';                    changes = '' }
    'Q' = @{ name = '';                            args = @{};                        label = 'Quit';                                 changes = '' }
}

function Show-RevertFiles {
    $files = @(Get-ChildItem $scriptsDir -Filter '*-revert.ps1' -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($files.Count -eq 0) {
        Write-Host 'No revert files yet - nothing has been changed on this machine.' -ForegroundColor Green
        return
    }
    Write-Host "`nRevert files (run one elevated to restore what that script changed):" -ForegroundColor Cyan
    for ($i = 0; $i -lt $files.Count; $i++) { Write-Host "  $($i + 1). $($files[$i].Name)" }
    if ($Choice) { return }
    $pick = Read-Host 'Which one to run? (number, or Enter to go back)'
    if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $files.Count) { Write-Host 'Back to the menu.'; return }
    $file = $files[[int]$pick - 1]
    if ((Read-Host "Run $($file.Name)? [y/N]") -ne 'y') { Write-Host 'Skipped.' -ForegroundColor Yellow; return }
    try { & $file.FullName } catch { Write-Host "Revert failed: $($_.Exception.Message)" -ForegroundColor Red }
}

$once = [bool]$Choice
do {
    if (-not $once) {
        Write-Host "`nwindows-tune" -ForegroundColor Cyan
        foreach ($key in $menu.Keys) {
            $item = $menu[$key]
            Write-Host "  $key. $($item.label)"
            if ($item.changes) { Write-Host "     changes: $($item.changes)" -ForegroundColor Yellow }
        }
        $selection = (Read-Host 'Choice').Trim().ToUpper()
    } else {
        $selection = $Choice
    }

    if (-not $menu.Contains($selection)) { Write-Host 'Not an option.' -ForegroundColor Red; continue }
    $item = $menu[$selection]

    if ($selection -eq 'Q') { exit 0 }
    if ($selection -eq 'R') { Show-RevertFiles; continue }

    if ($item.changes) {
        Write-Host "This will change: $($item.changes)" -ForegroundColor Yellow
        if (-not $Yes -and (Read-Host 'Run it? [y/N]') -ne 'y') { Write-Host 'Skipped.' -ForegroundColor Yellow; continue }
    }
    $scriptPath = Join-Path $scriptsDir $item.name
    # Splat a HASHTABLE through a variable. The original @($item.args) was an
    # array expression that landed as one positional Object[], and an array
    # splat of '-Diagnose' binds it as a positional string rather than the
    # switch - both found by tests\preflight.ps1 pressing options 2 and 3
    # (2026-09-01). Named splatting is the form that reaches a [switch].
    $scriptArgs = $item.args
    try {
        & $scriptPath @scriptArgs
    } catch {
        Write-Host "$($item.name) failed: $($_.Exception.Message)" -ForegroundColor Red
    }
} while (-not $once)
exit 0
