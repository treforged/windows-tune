# windows-tune-gui.ps1
# Get-OptionPlan receives one boolean per option row (19 rows) and a list of read-only rows.

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# -------------------------------------------------------------------
# Helper functions
# -------------------------------------------------------------------
function Set-Status {
    param(
        [int]$Index,
        [string]$Text
    )
    if ($global:StatusLabels -and $Index -ge 0 -and $Index -lt $global:StatusLabels.Count) {
        $global:StatusLabels[$Index].Text = $Text
    }
}

function Get-OptionPlan {
    param(
        [bool[]]$Checked,                 # one per row of $optionDefs, in order
        [int[]]$ReadOnly = @(1, 2, 8, 11, 13, 14)     # rows (1-based) that change nothing: storage report, antivirus status, game mode preview, update settings, privacy audit, recommended
    )
    $plan = @()
    for ($i = 0; $i -lt $Checked.Length; $i++) {
        if ($Checked[$i]) {
            $choice = $i + 1
            $changes = $ReadOnly -notcontains $choice
            $plan += [PSCustomObject]@{
                Choice  = $choice
                Changes = $changes
            }
        }
    }
    return $plan
}

function Get-RecommendedRows {
    # Pure. Which option rows (0-based) the Recommended view should tick: every recommendation the
    # catalogue marks PreTicked (safe), found by its menu key in the rows' -Choice. Nothing is run here.
    param($Recommendations, [object[]]$Defs, [switch]$All)
    $rows = @()
    foreach ($r in @($Recommendations)) {
        if (-not $r) { continue }
        if (-not $All -and -not $r.PreTicked) { continue }
        for ($i = 0; $i -lt $Defs.Count; $i++) {
            if ($Defs[$i].Args -match "-Choice $([regex]::Escape([string]$r.Key))(\s|$)") { $rows += $i; break }
        }
    }
    return $rows
}

function Show-ChangeConfirmation {
    param(
        [string[]]$OptionLabels
    )
    $message = "The following actions will modify this computer:`n`n"
    $message += ($OptionLabels -join "`n")
    $message += "`n`nDo you want to continue?"
    $result = [System.Windows.Forms.MessageBox]::Show($message,
        "Confirm changes",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    return $result -eq [System.Windows.Forms.DialogResult]::Yes
}

function Is-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# -------------------------------------------------------------------
# Validate script location
# -------------------------------------------------------------------
if (-not $PSScriptRoot) {
    throw "Script folder could not be determined. Run this script from a file location (e.g., save as windows-tune-gui.ps1 and execute it)."
}
$scriptDir = $PSScriptRoot.TrimEnd('\')

# -------------------------------------------------------------------
# UI definition
# -------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Windows Tune"
$form.Size = New-Object System.Drawing.Size(660, 430)   # height is set below, once the rows are counted
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false

# Option definitions. A change option passes neither -AcceptRisk nor -Yes, so its own console
# window shows NOTICE.md, asks for I ACCEPT and then asks Run it? - the GUI never accepts the
# risk for the user (audit 2c24feed lead 2). Read-only options change nothing and skip that.
$optionDefs = @(
    @{ Label = 'Storage report (read-only)';            Args = '-Choice 1 -AcceptRisk -NoElevate' },
    @{ Label = 'Antivirus status check (read-only)';    Args = '-Choice 2 -AcceptRisk -NoElevate' },
    @{ Label = 'Network tune';                          Args = '-Choice 3' },
    @{ Label = 'Power tune';                            Args = '-Choice 4' },
    @{ Label = 'Component store cleanup';               Args = '-Choice 5' },
    @{ Label = 'Remove a third-party antivirus';        Args = '-Choice 6' },
    @{ Label = 'Keep every CPU core unparked';          Args = '-Choice 7' },
    @{ Label = 'Game mode preview (read-only)';         Args = '-Choice 8 -AcceptRisk -NoElevate' },
    @{ Label = 'Game mode: watch for games now';        Args = '-Choice 9' },
    @{ Label = 'Game mode: start at every sign-in';     Args = '-Choice G' },
    @{ Label = 'Update settings (read-only)';           Args = '-Choice U -AcceptRisk -NoElevate' },
    @{ Label = 'Updates: choose Off, Check or Install'; Args = '-Choice V' },
    @{ Label = 'Privacy audit (read-only)';             Args = '-Choice P -AcceptRisk -NoElevate' },
    @{ Label = 'Recommended changes for this PC (read-only)'; Args = '-Choice S -AcceptRisk -NoElevate' },
    @{ Label = 'Turn off Windows ad and diagnostic settings'; Args = '-Choice T' },
    @{ Label = 'Disable the DiagTrack and dmwappush services'; Args = '-Choice Y' },
    @{ Label = 'Hide your language list from websites'; Args = '-Choice L' },
    @{ Label = 'Block third-party cookies in Chrome and Edge'; Args = '-Choice B' },
    @{ Label = 'Encrypt DNS lookups (DNS over HTTPS)';  Args = '-Choice D' }
)

$checkboxes = @()
$global:StatusLabels = @()
$y = 20
for ($i = 0; $i -lt $optionDefs.Count; $i++) {
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $optionDefs[$i].Label
    $cb.Location = New-Object System.Drawing.Point(20, $y)
    $cb.AutoSize = $true
    $form.Controls.Add($cb)
    $checkboxes += $cb

    $status = New-Object System.Windows.Forms.Label
    $status.Text = ''
    $status.Location = New-Object System.Drawing.Point(360, ($y + 3))
    $status.AutoSize = $true
    $form.Controls.Add($status)
    $global:StatusLabels += $status

    $y += 30
}

# Buttons
$form.ClientSize = New-Object System.Drawing.Size(640, ($y + 70))
$btnRecommended = New-Object System.Windows.Forms.Button
$btnRecommended.Text = 'Recommended...'
$btnRecommended.Size = New-Object System.Drawing.Size(140, 30)
$btnRecommended.Location = New-Object System.Drawing.Point(20, ($y + 10))
$form.Controls.Add($btnRecommended)

$btnInstallSelected = New-Object System.Windows.Forms.Button
$btnInstallSelected.Text = 'Install selected'
$btnInstallSelected.Size = New-Object System.Drawing.Size(120, 30)
$btnInstallSelected.Location = New-Object System.Drawing.Point(300, ($y + 10))
$form.Controls.Add($btnInstallSelected)

$btnInstallAll = New-Object System.Windows.Forms.Button
$btnInstallAll.Text = 'Install all'
$btnInstallAll.Size = New-Object System.Drawing.Size(130, 30)
$btnInstallAll.Location = New-Object System.Drawing.Point(480, ($y + 10))
$form.Controls.Add($btnInstallAll)

# -------------------------------------------------------------------
# Core execution logic
# -------------------------------------------------------------------
$runSelected = {
    # Capture checked states
    $checkedStates = $checkboxes | ForEach-Object { $_.Checked }

    # Build plan
    $plan = Get-OptionPlan -Checked $checkedStates

    # Determine changing options that are checked
    $changing = $plan | Where-Object { $_.Changes }
    if ($changing.Count -gt 0) {
        # Confirm with user
        $changeLabels = $changing | ForEach-Object {
            $optionDefs[$_.Choice - 1].Label
        }
        $proceed = Show-ChangeConfirmation -OptionLabels $changeLabels
        if (-not $proceed) {
            # User declined; skip changing options
            $plan = $plan | Where-Object { -not $_.Changes }
        }
    }

    $isAdmin = Is-Admin

    foreach ($item in $plan) {
        $idx = $item.Choice - 1
        $scriptArgs = $optionDefs[$idx].Args
        $scriptPath = Join-Path $scriptDir 'windows-tune.ps1'

        if ($item.Changes -and -not $isAdmin) {
            Set-Status -Index $idx -Text 'Run windows-tune.ps1 elevated.'
            continue
        }

        # Own console window, not redirected: a redirected pipe nobody reads can
        # fill and block the child, and the user should see what a change printed.
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" $scriptArgs" -Wait -PassThru
        $exitCode = $proc.ExitCode

        # Exit 4: the menu refused to run elevated from a folder a normal program can write (audit 2c24feed lead 1).
        if ($exitCode -eq 4) { Set-Status -Index $idx -Text 'Refused: this folder can be changed without admin. Install with install.ps1 (Program Files).' }
        else { Set-Status -Index $idx -Text "Exit code: $exitCode" }
    }
}

# Recommended view: reads this PC (read-only), lists each suggested change with what it does, the risk,
# the undo and the source, pre-ticks only the SAFE ones, and applies NOTHING. "Tick in main window" ticks
# the matching rows; the person still presses Install selected and answers the confirmation box.
$showRecommended = {
    $script11 = Join-Path (Join-Path $scriptDir 'scripts') '11-recommended.ps1'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script11 -Json 2>&1 | Out-String
    $recs = $null
    try { $recs = @($out | ConvertFrom-Json) } catch { }
    if ($null -eq $recs) {
        [void][System.Windows.Forms.MessageBox]::Show("The privacy audit could not be read, so nothing can be recommended. This is not a claim your PC is fine.`n`n$out", 'Recommended', 'OK', 'Warning')
        return
    }
    if ($recs.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Nothing to recommend: every setting the audit checks is already where it should be.', 'Recommended', 'OK', 'Information')
        return
    }
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Recommended for this PC (nothing is applied from here)'
    $dlg.StartPosition = 'CenterParent'
    $dlg.ClientSize = New-Object System.Drawing.Size(720, (60 + 120 * $recs.Count + 50))
    $recBoxes = @()
    $ry = 15
    foreach ($r in $recs) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = "$($r.Title)   [menu $($r.Key)]"
        $cb.Checked = [bool]$r.PreTicked
        $cb.AutoSize = $true
        $cb.Location = New-Object System.Drawing.Point(15, $ry)
        $dlg.Controls.Add($cb)
        $recBoxes += $cb
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = "Does: $($r.What)`nRisk: $($r.Risk)`nUndo: $($r.Undo)`nSource: $($r.Source)"
        $lbl.Location = New-Object System.Drawing.Point(35, ($ry + 22))
        $lbl.Size = New-Object System.Drawing.Size(670, 92)
        $dlg.Controls.Add($lbl)
        $ry += 120
    }
    $note = New-Object System.Windows.Forms.Label
    $note.Text = 'Ticked = safe, pre-ticked. Unticked = your call. Nothing runs until you press Install selected and confirm.'
    $note.Location = New-Object System.Drawing.Point(15, $ry)
    $note.AutoSize = $true
    $dlg.Controls.Add($note)
    $use = New-Object System.Windows.Forms.Button
    $use.Text = 'Tick in main window'
    $use.Size = New-Object System.Drawing.Size(160, 30)
    $use.Location = New-Object System.Drawing.Point(545, ($ry + 20))
    $use.Add_Click([System.EventHandler]{ param($sender, $e)
        $chosen = @(); for ($i = 0; $i -lt $recs.Count; $i++) { if ($recBoxes[$i].Checked) { $chosen += $recs[$i] } }
        foreach ($cb in $checkboxes) { $cb.Checked = $false }
        foreach ($i in (Get-RecommendedRows -Recommendations $chosen -Defs $optionDefs -All)) { $checkboxes[$i].Checked = $true }
        $dlg.Close()
    })
    $dlg.Controls.Add($use)
    $dlg.ClientSize = New-Object System.Drawing.Size(720, ($ry + 65))
    if ($env:WT_GUI_NO_SHOW -ne '1') { [void]$dlg.ShowDialog($form) }
    return $dlg
}
$btnRecommended.Add_Click([System.EventHandler]{ param($sender, $e) [void](& $showRecommended) })

# Button handlers
$btnInstallSelected.Add_Click([System.EventHandler]{ param($sender, $e) & $runSelected })

$btnInstallAll.Add_Click([System.EventHandler]{ param($sender, $e)
    foreach ($cb in $checkboxes) { $cb.Checked = $true }
    & $runSelected
})

# Show the form. A test sets WT_GUI_NO_SHOW=1 and presses the buttons itself.
if ($env:WT_GUI_NO_SHOW -ne '1') { [void]$form.ShowDialog() }
