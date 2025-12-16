<#
.SYNOPSIS
    Loads deprecation rules from DeprecationRules.json configuration file.

.DESCRIPTION
    Reads deprecation rules from Config/DeprecationRules.json and returns them as an array.
    These rules define which Azure resources/components are deprecated and when they reach EOL.

.PARAMETER DeprecationRulesPath
    Optional path to DeprecationRules.json. Defaults to Config/DeprecationRules.json in module root.

.OUTPUTS
    Array of deprecation rule objects from JSON.
#>
function Get-DeprecationRules {
    [CmdletBinding()]
    param(
        [string]$DeprecationRulesPath
    )
    
    # Resolve module root
    if (-not $DeprecationRulesPath) {
        $moduleRoot = $PSScriptRoot -replace '\\Private\\Helpers$', ''
        $DeprecationRulesPath = Join-Path $moduleRoot "Config\DeprecationRules.json"
    }
    
    if (-not (Test-Path $DeprecationRulesPath)) {
        Write-Verbose "DeprecationRules file not found at $DeprecationRulesPath"
        return @()
    }
    
    try {
        $jsonContent = Get-Content -Path $DeprecationRulesPath -Raw | ConvertFrom-Json
        $rules = if ($jsonContent.deprecations) { @($jsonContent.deprecations) } else { @() }
        Write-Verbose "Loaded $($rules.Count) deprecation rule(s) from $DeprecationRulesPath"
        return $rules
    }
    catch {
        Write-Warning "Failed to load deprecation rules from $DeprecationRulesPath : $_"
        return @()
    }
}

