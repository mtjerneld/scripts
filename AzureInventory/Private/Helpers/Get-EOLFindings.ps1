<#
.SYNOPSIS
    Filters findings to return only those with valid EOL (End of Life) dates.

.DESCRIPTION
    Filters an array of security findings to return only those that have an EOLDate property
    with a valid, non-empty value. Excludes findings where EOLDate is null, empty, "N/A", or "n/a".

.PARAMETER Findings
    Array of security finding objects to filter.

.EXAMPLE
    $eolFindings = Get-EOLFindings -Findings $allFindings
#>
function Get-EOLFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
        [array]$Findings = @()
    )
    
    # Handle null or empty findings
    if (-not $Findings -or $Findings.Count -eq 0) {
        return @()
    }
    
    return @($Findings | Where-Object { 
        # Handle case-sensitivity: PowerShell property access is case-insensitive, but -contains is case-sensitive
        # So we'll use case-insensitive matching to find the property
        $eolDateValue = $null
        $propertyNames = $_.PSObject.Properties.Name
        # Case-insensitive search for EOLDate property
        $eolDateProp = $propertyNames | Where-Object { $_ -like 'EOLDate' -or $_ -like 'EolDate' -or $_ -like 'eolDate' } | Select-Object -First 1
        if ($eolDateProp) {
            $eolDateValue = $_.$eolDateProp
        } else {
            # Fallback: try direct access (PowerShell is case-insensitive for property access)
            $eolDateValue = $_.EOLDate
        }
        
        if (-not $eolDateValue) { return $false }
        $eolDateStr = "$eolDateValue".Trim()
        if ([string]::IsNullOrWhiteSpace($eolDateStr)) { return $false }
        if ($eolDateStr -eq "N/A" -or $eolDateStr -eq "n/a") { return $false }
        return $true
    })
}

