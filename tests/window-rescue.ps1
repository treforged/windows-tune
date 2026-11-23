param(
    [string]$Script = (Join-Path $PSScriptRoot '..\scripts\13-window-rescue.ps1')
)

Add-Type -AssemblyName System.Windows.Forms

# Compute the minimum left coordinate across all screens
$minLeft = [System.Int32]::MaxValue
foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
    if ($scr.Bounds.Left -lt $minLeft) {
        $minLeft = $scr.Bounds.Left
    }
}

# Create the test form far off to the left
$form = New-Object System.Windows.Forms.Form
$form.Text = 'window-rescue-test-' + ([guid]::NewGuid().ToString())
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Width = 400
$form.Height = 300
$form.ShowInTaskbar = $true
$form.Location = New-Object System.Drawing.Point ($minLeft - 3000), 100

$failCount = 0

try {
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()

    # Precondition: the form must not intersect any screen
    $preconditionFailed = $false
    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        if ($scr.Bounds.IntersectsWith($form.Bounds)) {
            Write-Output 'FAIL precondition: test window is on a screen'
            $preconditionFailed = $true
            $failCount++
            break
        }
    }

    # Start the script under test
    $p = Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$Script -PassThru -WindowStyle Hidden

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt 30) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }

    # Pump a few more times after exit or timeout
    1..20 | ForEach-Object {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }

    if (-not $p.HasExited) {
        try { $p.Kill() } catch {}
        Write-Output 'FAIL script did not exit'
        $failCount++
    }

    # Check final position of the form
    $primaryWA = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($primaryWA.IntersectsWith($form.Bounds)) {
        $x = $form.Bounds.X
        $y = $form.Bounds.Y
        Write-Output ("PASS stranded window moved to the primary screen at {0},{1}" -f $x, $y)
    } else {
        $x = $form.Bounds.X
        $y = $form.Bounds.Y
        Write-Output ("FAIL stranded window still at {0},{1}" -f $x, $y)
        $failCount++
    }
}
finally {
    if ($form -ne $null) {
        $form.Close()
        $form.Dispose()
    }
}

Write-Output ("window-rescue: 1 check, {0} failed" -f $failCount)
if ($failCount -gt 0) { exit 1 } else { exit 0 }
