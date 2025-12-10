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
        if (-not $_.EOLDate) { return $false }
        $eolDateStr = $_.EOLDate.ToString().Trim()
        if ([string]::IsNullOrWhiteSpace($eolDateStr)) { return $false }
        if ($eolDateStr -eq "N/A" -or $eolDateStr -eq "n/a") { return $false }
        return $true
    })
}

