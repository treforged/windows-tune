function Test-AdvisorDenied {
    param (
        [string]$Name,
        [string]$Kind
    )
    $r = Test-GameModeProtected -Name $Name -Kind $Kind
    if ($null -ne $r) {
        return $r
    }
    $n = ([string]$Name).Trim().ToLowerInvariant() -replace '\.exe$', ''
    $extra = @('bitwarden','claude','ollama','ollama app','llama-server','windowsterminal','wt','openconsole','msmpeng','securityhealthsystray','vgc','vgk')
    if ($extra -contains $n) {
        return "a live desk, local model or security app ($n)"
    }
    return $null
}
function Get-UndoPath {
    return Join-Path $env:LOCALAPPDATA 'windows-tune\advisor-undo.json'
}
function Read-UndoStore {
    $p = Get-UndoPath
    $store = @{}
    if (-not (Test-Path -LiteralPath $p)) {
        return $store
    }
    $obj = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
    foreach ($prop in $obj.PSObject.Properties) {
        $store[$prop.Name] = $prop.Value
    }
    return $store
}
function Save-UndoStore {
    param (
        [hashtable]$Store
    )
    $p = Get-UndoPath
    $dir = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -LiteralPath $p -Value ($Store | ConvertTo-Json -Depth 5) -Encoding UTF8
}
function Save-UndoRecord {
    param (
        [string]$Key,
        [hashtable]$Record
    )
    $s = Read-UndoStore
    $s[$Key] = $Record
    Save-UndoStore -Store $s
    $back = Read-UndoStore
    return ($back.ContainsKey($Key) -and ([string]$back[$Key].name -eq [string]$Record.name))
}
function Remove-UndoRecord {
    param (
        [string]$Key
    )
    $s = Read-UndoStore
    $s.Remove($Key) | Out-Null
    Save-UndoStore -Store $s
}
function Find-StartupEntry {
    param (
        [string]$Name
    )
    $pairs = @(
        @{
            Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
            Admin = $false
        },
        @{
            Run = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
            Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
            Admin = $true
        }
    )
    foreach ($pair in $pairs) {
        $v = (Get-ItemProperty -LiteralPath $pair.Run -Name $Name -ErrorAction SilentlyContinue).$Name
        if ($null -ne $v) {
            return @{
                Run = $pair.Run
                Approved = $pair.Approved
                Admin = $pair.Admin
                Command = [string]$v
            }
        }
    }
    return $null
}
function New-AdvisorResult {
    param (
        [bool]$Ok,
        [bool]$Changed,
        $Undo,
        $Readback,
        [string]$Reason,
        [int]$Code
    )
    return @{
        Result = [ordered]@{
            ok = $Ok
            changed = $Changed
            undo = $Undo
            readback = $Readback
            reason = $Reason
        }
        Code = $Code
    }
}
function Invoke-StartupToggle {
    param (
        [string]$Name,
        [ValidateSet('disable-startup','enable-startup')][string]$Verb
    )
    $deny = Test-AdvisorDenied -Name $Name -Kind 'App'
    if ($null -ne $deny) {
        return New-AdvisorResult $false $false $null $null "refused: $deny" 4
    }
    $e = Find-StartupEntry -Name $Name
    if ($null -eq $e) {
        return New-AdvisorResult $false $false $null $null 'startup entry not found' 1
    }
    if ($e.Admin -and -not (Test-IsAdmin)) {
        $state = Get-ApprovedState -ApprovedKey $e.Approved -Name $Name
        return New-AdvisorResult $false $false $null $state 'needs_admin' 3
    }
    $key = 'startup:' + $Name
    $undoText = "wtcli.ps1 advisor enable-startup $Name"
    if ($Verb -eq 'disable-startup') {
        $old = (Get-ItemProperty -LiteralPath $e.Approved -Name $Name -ErrorAction SilentlyContinue).$Name
        $prior = $null
        if ($null -ne $old) {
            $prior = [Convert]::ToBase64String([byte[]]$old)
        }
        $record = @{
            kind = 'startup'
            name = $Name
            approved = $e.Approved
            prior = $prior
        }
        if (-not (Save-UndoRecord -Key $key -Record $record)) {
            return New-AdvisorResult $false $false $null $null 'undo record could not be written; nothing changed' 1
        }
        if (-not (Test-Path -LiteralPath $e.Approved)) {
            New-Item -Path $e.Approved -Force | Out-Null
        }
        New-ItemProperty -LiteralPath $e.Approved -Name $Name -Value ([byte[]](3,0,0,0,0,0,0,0,0,0,0,0)) -PropertyType Binary -Force | Out-Null
        $rb = Get-ApprovedState -ApprovedKey $e.Approved -Name $Name
        return New-AdvisorResult ($rb -eq 'disabled') $true $undoText $rb '' 0
    } else {
        $s = Read-UndoStore
        if (-not $s.ContainsKey($key)) {
            $state = Get-ApprovedState -ApprovedKey $e.Approved -Name $Name
            return New-AdvisorResult $false $false $null $state 'no undo recorded' 1
        }
        $rec = $s[$key]
        if ($null -eq $rec.prior) {
            Remove-ItemProperty -LiteralPath $e.Approved -Name $Name -ErrorAction SilentlyContinue
        } else {
            $bytes = [Convert]::FromBase64String([string]$rec.prior)
            New-ItemProperty -LiteralPath $e.Approved -Name $Name -Value $bytes -PropertyType Binary -Force | Out-Null
        }
        Remove-UndoRecord -Key $key
        $rb = Get-ApprovedState -ApprovedKey $e.Approved -Name $Name
        return New-AdvisorResult $true $true $null $rb '' 0
    }
}
