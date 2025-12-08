<#
.SYNOPSIS
    Loads control definitions from JSON configuration file.

.DESCRIPTION
    Reads control definitions and deprecation rules from Config directory.

.OUTPUTS
    Hashtable with control definitions and deprecation rules.
#>
function Get-ControlDefinitions {
    [CmdletBinding()]
    param()
    
    $moduleRoot = $PSScriptRoot -replace '\\Private\\Config$', ''
    $controlDefPath = Join-Path $moduleRoot "Config\ControlDefinitions.json"
    $deprecationPath = Join-Path $moduleRoot "Config\DeprecationRules.json"
    
    $result = @{
        Controls = @()
        Deprecations = @()
    }
    
    try {
        if (Test-Path $controlDefPath) {
            $jsonContent = Get-Content -Path $controlDefPath -Raw | ConvertFrom-Json
            # Return the controls array from the JSON structure
            $result.Controls = $jsonContent.controls
        }
    }
    catch {
        Write-Warning "Failed to load control definitions: $_"
    }
    
    try {
        if (Test-Path $deprecationPath) {
            $result.Deprecations = Get-Content -Path $deprecationPath -Raw | ConvertFrom-Json
        }
    }
    catch {
        Write-Warning "Failed to load deprecation rules: $_"
    }
    
    return $result
}

<#
.SYNOPSIS
    Gets control definitions for a specific category.

.DESCRIPTION
    Retrieves enabled control definitions from JSON for a specific category.
    Filters out disabled controls and optionally Level 2 controls.

.PARAMETER Category
    The category to filter controls by (e.g., "Storage", "SQL", "Network", "VM", "AppService").

.PARAMETER IncludeLevel2
    If specified, includes Level 2 (L2) controls. Otherwise, only Level 1 (L1) controls are returned.

.OUTPUTS
    Array of control definition objects.
#>
function Get-ControlsForCategory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category,
        
        [switch]$IncludeLevel2
    )
    
    $definitions = Get-ControlDefinitions
    $controls = $definitions.Controls
    
    if ($null -eq $controls) {
        Write-Warning "No control definitions loaded"
        return @()
    }
    
    # Filter by category and enabled status
    $filtered = $controls | Where-Object {
        $_.category -eq $Category -and
        ($_.enabled -ne $false) -and  # enabled can be true, null, or missing (default to enabled)
        ($IncludeLevel2 -or $_.level -ne "L2")  # Include L2 only if flag is set
    }
    
    return $filtered
}

<#
.SYNOPSIS
    Gets description and references for a control from ControlDefinitions.

.DESCRIPTION
    Retrieves the description (or businessImpact as fallback) and references array
    for a given control definition object.

.PARAMETER Control
    The control definition object from ControlDefinitions.json.

.OUTPUTS
    Hashtable with Description and References keys.
#>
function Get-ControlDescriptionAndReferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$Control
    )
    
    $description = if ($Control.description) { 
        $Control.description 
    } elseif ($Control.businessImpact) { 
        $Control.businessImpact 
    } else { 
        "" 
    }
    
    $references = if ($Control.references) { 
        $Control.references 
    } else { 
        @() 
    }
    
    return @{
        Description = $description
        References = $references
    }
}


