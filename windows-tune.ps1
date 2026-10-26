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

    It elevates only from a folder that needs administrator rights to change
    (install.ps1 puts it in Program Files). From any other folder a normal
    program could swap a script before it runs as admin, so there it runs the
    read-only options only, and an elevated run refuses with exit 4.

.PARAMETER Choice
    Run one menu option without showing the menu, then exit: 1-7, R or Q.

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
    [ValidateSet('1', '2', '3', '4', '5', '6', '7', 'R', 'Q')][string]$Choice,
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

# ---- Elevated code runs only from a folder a normal program cannot write (audit 2c24feed lead 1). ----
# Elevated, this menu runs windows-tune.ps1, the scripts and the *-revert.ps1 files beside it. If any
# of them, or a folder above them, can be changed without admin rights (the old %LOCALAPPDATA% install,
# or any folder you extracted the zip to), a program running as you could plant or swap a script and
# your Yes on the admin prompt would run it. So from such a folder the menu does not elevate, and an
# elevated run refuses. Install under Program Files (install.ps1, from an elevated PowerShell) to fix it.
function Test-UserWritable([string]$Path, [int64]$Mask = 0x500D0046) {
    # $true when a program running as you WITHOUT admin could change, replace or re-permission $Path.
    # Unreadable counts as writable: a check that cannot see the ACL must not vouch for it.
    # Default mask: WriteData 0x2, AppendData 0x4, DeleteChild 0x40, Delete 0x10000, WriteDac 0x40000,
    # WriteOwner 0x80000, GenericAll 0x10000000, GenericWrite 0x40000000. Modify also carries READ bits,
    # so it cannot be the test.
    try { $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop } catch { return $true }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    # The SIDs a non-elevated process of this user holds: the user and every token group, minus the
    # two UAC strips from the filtered token (Administrators, local-account-and-admin) and the labels.
    $weak = @($id.User.Value) + @($id.Groups | ForEach-Object { $_.Value } | Where-Object { $_ -notin 'S-1-5-32-544', 'S-1-5-114' -and $_ -notlike 'S-1-16-*' })
    try { $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { return $true }
    if ($weak -contains $owner) { return $true }   # an owner can always rewrite the DACL
    foreach ($ace in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($ace.AccessControlType -ne 'Allow') { continue }
        if ($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
        if ($weak -contains $ace.IdentityReference.Value -and ([int64]$ace.FileSystemRights -band $Mask)) { return $true }
    }
    return $false
}
function Get-UnsafeRunReason([string]$File) {
    # $null when $File, its folder and every folder above it are admin-only; otherwise a sentence
    # naming the first path a normal program could use to change what runs.
    try { $full = [IO.Path]::GetFullPath($File) } catch { return "$File is not a usable path" }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return "$full does not exist" }
    if (Test-UserWritable $full) { return "$full can be changed without admin rights" }
    $dir = Split-Path -Parent $full
    if (Test-UserWritable $dir) { return "$dir lets a program running as you add or swap files in it" }
    # Above that, only the rights that let someone rename or replace a folder inside it matter:
    # DeleteChild 0x40, WriteDac, WriteOwner, GenericAll. Creating a new folder in C:\ is not enough.
    $p = Split-Path -Parent $dir
    while ($p) {
        if (Test-UserWritable $p 0x100C0040) { return "$p lets a program running as you rename or replace the folders inside it" }
        $p = Split-Path -Parent $p
    }
    return $null
}
function Invoke-Checked([string]$File, [hashtable]$Arguments = @{}, [switch]$Elevated) {
    # The ONLY place this menu runs another script. Elevated, it re-checks the exact file first, so a
    # revert file or script that is writable on its own is refused even inside an admin-only folder.
    if ($Elevated) {
        $why = Get-UnsafeRunReason $File
        if ($why) {
            Write-Host "REFUSED: $why. It was not run." -ForegroundColor Red
            return
        }
    }
    & $File @Arguments
}
$installHint = "From an ELEVATED PowerShell: .\install.ps1   (installs to $env:ProgramFiles\windows-tune, which only administrators can write)"

# ---- Elevation, once. -------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$selfRisk = Get-UnsafeRunReason $PSCommandPath
if ($isAdmin -and $selfRisk) {
    Write-Host "REFUSED to run elevated: $selfRisk, so a program running as you could change what runs as administrator." -ForegroundColor Red
    Write-Host "  $installHint" -ForegroundColor Yellow
    Write-Host 'Nothing was run.' -ForegroundColor Yellow
    exit 4
}
if (-not $isAdmin) {
    if ($NoElevate) {
        Write-Host 'Not elevated: only the storage report (1), the antivirus status check (2) and the revert list (R) will work.' -ForegroundColor Yellow
    } elseif ($selfRisk) {
        Write-Host "Not elevating: $selfRisk, so a program running as you could change what runs as administrator." -ForegroundColor Yellow
        Write-Host 'Only the storage report (1), the antivirus status check (2) and the revert list (R) will work from here.' -ForegroundColor Yellow
        Write-Host "  $installHint" -ForegroundColor Yellow
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
             changes = 'Deletes superseded component versions - the same DISM StartComponentCleanup Windows schedules itself, WITHOUT /ResetBase, so recent updates stay uninstallable; asks DISM first and skips if no cleanup is recommended' }
    '6' = @{ name = '06-remove-third-party-av.ps1'; args = @{};                       label = 'Remove a third-party antivirus';
             changes = 'UNINSTALLS a product you name - NOT reversible; the script asks for the product name itself' }
    '7' = @{ name = '08-core-unpark.ps1';          args = @{};                        label = 'Keep every CPU core unparked';
             changes = 'Minimum unparked cores = 100% on the active plan, AC and battery; costs idle power; writes 08-core-unpark-revert.ps1' }
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
    try { Invoke-Checked $file.FullName -Elevated:$isAdmin } catch { Write-Host "Revert failed: $($_.Exception.Message)" -ForegroundColor Red }
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
        Invoke-Checked $scriptPath $scriptArgs -Elevated:$isAdmin
    } catch {
        Write-Host "$($item.name) failed: $($_.Exception.Message)" -ForegroundColor Red
    }
} while (-not $once)
exit 0
