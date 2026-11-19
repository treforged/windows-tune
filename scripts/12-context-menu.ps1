# 12-context-menu.ps1 - tidy the right-click menu with plain registry settings (no code injection).
# Runs as YOU, no admin needed: every write is under HKCU (your own user only).
#
#   (no switch)   1. adds "Open in Admin Terminal" to folders, folder backgrounds and drives
#                 2. hides app items: Edit with Clipchamp, OneDrive, Ask Copilot, Microsoft 365 Copilot,
#                    and Scan with Microsoft Defender (Defender itself keeps running; only the menu item goes)
#   -DryRun       print what would change, change nothing
#   -Undo         remove exactly what this script added (it records that in 12-context-menu-state.json)
#   -NoTerminal   skip step 1        -NoBlock   skip step 2
#
# How: step 1 is the standard "runas" shell verb, which Windows itself elevates (you see one UAC prompt
# when you click it). The folder path is passed by Explorer as %V. It is never put inside a command
# string for a shell to parse, so a folder name cannot inject a command.
# Step 2 adds the handler IDs to HKCU\...\Shell Extensions\Blocked, the switch Windows reads before it loads
# a menu handler. The IDs are READ FROM EACH INSTALLED APP'S OWN MANIFEST at run time, never from a fixed
# list, because they differ between app versions. An app that is not installed is reported and skipped.
# Changes show in new Explorer windows; a restart of Explorer or a sign-out applies them everywhere.

param([switch]$DryRun, [switch]$Undo, [switch]$NoTerminal, [switch]$NoBlock)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $here) { throw 'Run this as a file (.\12-context-menu.ps1).' }
$statePath = Join-Path $here '12-context-menu-state.json'
$revertPath = Join-Path $here '12-context-menu-revert.ps1'
$blockedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
$verbRoots = 'Directory\Background', 'Directory', 'Drive'
$menuText = 'Open in Admin Terminal'

# App packages whose context-menu verbs are hidden. Verb filter is a regex on the manifest Verb Id.
$APPS = @(
    @{ Name = 'Clipchamp.Clipchamp';          Label = 'Edit with Clipchamp';        Verb = '.' }
    @{ Name = 'Microsoft.OneDriveSync';       Label = 'OneDrive';                   Verb = '.' }
    @{ Name = 'Microsoft.Copilot';            Label = 'Ask Copilot';                Verb = '.' }
    @{ Name = 'Microsoft.MicrosoftOfficeHub'; Label = 'Microsoft 365 Copilot';      Verb = '.' }
)

function Get-AppMenuClsids([string]$PackageName, [string]$VerbFilter) {
    $p = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { return $null }
    $mf = Join-Path $p.InstallLocation 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $mf)) { return @() }
    [xml]$m = Get-Content -LiteralPath $mf -Raw
    $verbs = $m.SelectNodes("//*[local-name()='FileExplorerContextMenus']//*[local-name()='Verb']")
    return @($verbs | Where-Object { $_.Id -match $VerbFilter -and $_.Clsid -match '^[0-9A-Fa-f-]{36}$' } |
        ForEach-Object { '{' + $_.Clsid.ToUpper() + '}' } | Select-Object -Unique)
}

function Get-DefenderMenuClsid {
    $v = (Get-ItemProperty -LiteralPath 'Registry::HKEY_CLASSES_ROOT\*\shellex\ContextMenuHandlers\EPP' -ErrorAction SilentlyContinue).'(default)'
    if ($v -match '^\{[0-9A-Fa-f-]{36}\}$') { return $v.ToUpper() } else { return $null }
}

function Get-TerminalPath {
    $wt = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
    if (Test-Path -LiteralPath $wt) { return $wt } else { return $null }
}

function Invoke-Undo {
    if (-not (Test-Path -LiteralPath $statePath)) { Write-Host 'Nothing to undo: no state file.'; return 0 }
    $st = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $bad = 0
    foreach ($k in @($st.VerbKeys)) {
        if ($DryRun) { Write-Host "would remove $k"; continue }
        if (Test-Path -LiteralPath $k) { Remove-Item -LiteralPath $k -Recurse -Force }
        if (Test-Path -LiteralPath $k) { Write-Host "FAILED to remove $k"; $bad++ } else { Write-Host "removed $k" }
    }
    foreach ($c in @($st.BlockedAdded)) {
        if ($DryRun) { Write-Host "would unblock $c"; continue }
        Remove-ItemProperty -LiteralPath $blockedKey -Name $c -ErrorAction SilentlyContinue
        if ($null -ne (Get-ItemProperty -LiteralPath $blockedKey -Name $c -ErrorAction SilentlyContinue)) { Write-Host "FAILED to unblock $c"; $bad++ } else { Write-Host "unblocked $c" }
    }
    # The Blocked key is removed only if this script created it and it is now empty.
    if (-not $DryRun -and $st.CreatedBlockedKey -and (Test-Path -LiteralPath $blockedKey)) {
        $left = @((Get-Item -LiteralPath $blockedKey).GetValueNames()).Count + @(Get-ChildItem -LiteralPath $blockedKey).Count
        if ($left -eq 0) { Remove-Item -LiteralPath $blockedKey -Force; Write-Host 'removed the empty Blocked key this script created' }
    }
    if (-not $DryRun -and $bad -eq 0) { Remove-Item -LiteralPath $statePath, $revertPath -Force -ErrorAction SilentlyContinue }
    return $bad
}

if ($Undo) { $b = Invoke-Undo; if ($b) { exit 1 } else { exit 0 } }
if (Test-Path -LiteralPath $statePath) { Write-Host "Already applied. Run with -Undo first ($statePath)."; exit 2 }

$verbKeys = New-Object System.Collections.Generic.List[string]
$blockedAdded = New-Object System.Collections.Generic.List[string]
$failed = 0
$createdBlockedKey = $false

# 1. Open in Admin Terminal
if (-not $NoTerminal) {
    $wt = Get-TerminalPath
    if (-not $wt) { Write-Host 'SKIP admin terminal: Windows Terminal (wt.exe) is not installed.' }
    else {
        foreach ($r in $verbRoots) {
            $merged = "Registry::HKEY_CLASSES_ROOT\$r\shell\runas"
            $mine = "HKCU:\Software\Classes\$r\shell\runas"
            if (Test-Path -LiteralPath $merged) { Write-Host "SKIP $r : a 'runas' item already exists there and is not ours."; continue }
            if ($DryRun) { Write-Host "would add '$menuText' to $r"; continue }
            New-Item -Path "$mine\command" -Force | Out-Null
            Set-ItemProperty -LiteralPath $mine -Name '(default)' -Value $menuText
            Set-ItemProperty -LiteralPath $mine -Name 'HasLUAShield' -Value ''
            Set-ItemProperty -LiteralPath "$mine\command" -Name '(default)' -Value ('"' + $wt + '" -d "%V\."')
            $verbKeys.Add($mine)
            if ((Get-ItemProperty -LiteralPath $mine).'(default)' -eq $menuText) { Write-Host "added '$menuText' to $r" } else { Write-Host "FAILED read-back on $r"; $failed++ }
        }
    }
}

# 2. hide app menu items
if (-not $NoBlock) {
    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($a in $APPS) {
        $ids = Get-AppMenuClsids $a.Name $a.Verb
        if ($null -eq $ids) { Write-Host "SKIP $($a.Label): app not installed"; continue }
        if ($ids.Count -eq 0) { Write-Host "SKIP $($a.Label): installed, but it declares no menu items"; continue }
        foreach ($i in $ids) { $targets.Add(@{ Id = $i; Label = $a.Label }) }
    }
    $def = Get-DefenderMenuClsid
    if ($def) { $targets.Add(@{ Id = $def; Label = 'Scan with Microsoft Defender' }) } else { Write-Host 'SKIP Defender: its menu handler is not registered' }
    if (-not $DryRun -and $targets.Count -gt 0 -and -not (Test-Path -LiteralPath $blockedKey)) { New-Item -Path $blockedKey -Force | Out-Null; $createdBlockedKey = $true }
    foreach ($t in $targets) {
        $exists = (Test-Path -LiteralPath $blockedKey) -and ($null -ne (Get-ItemProperty -LiteralPath $blockedKey -Name $t.Id -ErrorAction SilentlyContinue))
        if ($exists) { Write-Host "already hidden: $($t.Label) $($t.Id) (not ours, left alone)"; continue }
        if ($DryRun) { Write-Host "would hide $($t.Label) $($t.Id)"; continue }
        New-ItemProperty -LiteralPath $blockedKey -Name $t.Id -Value $t.Label -PropertyType String | Out-Null
        $blockedAdded.Add($t.Id)
        if ($null -ne (Get-ItemProperty -LiteralPath $blockedKey -Name $t.Id -ErrorAction SilentlyContinue)) { Write-Host "hidden: $($t.Label) $($t.Id)" } else { Write-Host "FAILED read-back: $($t.Id)"; $failed++ }
    }
}

if ($DryRun) { Write-Host 'Dry run: nothing changed.'; exit 0 }
@{ VerbKeys = @($verbKeys); BlockedAdded = @($blockedAdded); CreatedBlockedKey = $createdBlockedKey; Applied = (Get-Date -Format s) } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding ASCII
Set-Content -LiteralPath $revertPath -Encoding ASCII -Value @(
    '# Undo for 12-context-menu.ps1: removes exactly what it added (listed in 12-context-menu-state.json).',
    '& (Join-Path $PSScriptRoot ''12-context-menu.ps1'') -Undo; exit $LASTEXITCODE')
Write-Host "Done: $($verbKeys.Count) menu item(s) added, $($blockedAdded.Count) app item(s) hidden. Undo: $revertPath"
Write-Host 'Open a new Explorer window to see it, or sign out and in for every window.'
if ($failed) { exit 1 } else { exit 0 }
