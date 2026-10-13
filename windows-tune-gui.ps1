# windows-tune-gui.ps1
# Assumption: Get-OptionPlan receives an array of 6 booleans indicating the checked state of options 1‑6.

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
        [bool[]]$Checked   # array length 6
    )
    $plan = @()
    for ($i = 0; $i -lt $Checked.Length; $i++) {
        if ($Checked[$i]) {
            $choice = $i + 1
            $changes = $choice -ge 3   # options 3‑6 change the machine
            $plan += [PSCustomObject]@{
                Choice  = $choice
                Changes = $changes
            }
        }
    }
    return $plan
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
$form.Size = New-Object System.Drawing.Size(460, 340)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false

# Option definitions
$optionDefs = @(
    @{ Label = 'Storage report (read-only)';            Args = '-Choice 1 -AcceptRisk -NoElevate' },
    @{ Label = 'Antivirus status check (read-only)';    Args = '-Choice 2 -AcceptRisk -NoElevate' },
    @{ Label = 'Network tune';                          Args = '-Choice 3 -AcceptRisk -Yes' },
    @{ Label = 'Power tune';                            Args = '-Choice 4 -AcceptRisk -Yes' },
    @{ Label = 'Component store cleanup';               Args = '-Choice 5 -AcceptRisk -Yes' },
    @{ Label = 'Remove a third-party antivirus';        Args = '-Choice 6 -AcceptRisk -Yes' }
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
    $status.Location = New-Object System.Drawing.Point(250, ($y + 3))
    $status.AutoSize = $true
    $form.Controls.Add($status)
    $global:StatusLabels += $status

    $y += 30
}

# Buttons
$btnInstallSelected = New-Object System.Windows.Forms.Button
$btnInstallSelected.Text = 'Install selected'
$btnInstallSelected.Size = New-Object System.Drawing.Size(120, 30)
$btnInstallSelected.Location = New-Object System.Drawing.Point(60, ($y + 10))
$form.Controls.Add($btnInstallSelected)

$btnInstallAll = New-Object System.Windows.Forms.Button
$btnInstallAll.Text = 'Install all'
$btnInstallAll.Size = New-Object System.Drawing.Size(120, 30)
$btnInstallAll.Location = New-Object System.Drawing.Point(250, ($y + 10))
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

        Set-Status -Index $idx -Text "Exit code: $exitCode"
    }
}

# Button handlers
$btnInstallSelected.Add_Click([System.EventHandler]{ param($sender, $e) & $runSelected })

$btnInstallAll.Add_Click([System.EventHandler]{ param($sender, $e)
    foreach ($cb in $checkboxes) { $cb.Checked = $true }
    & $runSelected
})

# Show the form. A test sets WT_GUI_NO_SHOW=1 and presses the buttons itself.
if ($env:WT_GUI_NO_SHOW -ne '1') { [void]$form.ShowDialog() }
