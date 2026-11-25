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
    $extra = @('*bitwarden*','claude','*ollama*','llama-server','windowsterminal','wt','openconsole','msmpeng','securityhealthsystray','vgc','vgk','*vanguard*')
    foreach ($p in $extra) {
        if ($n -like $p) {
            return "a live desk, local model or security app ($n)"
        }
    }
    return $null
}
