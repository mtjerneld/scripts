<#
.SYNOPSIS
    Groups findings by severity and returns counts for each severity level.

.DESCRIPTION
    Analyzes an array of security findings and returns a hashtable with counts
    for each severity level (Critical, High, Medium, Low).

.PARAMETER Findings
    Array of security finding objects to analyze.

.PARAMETER StatusFilter
    Optional status filter. If specified, only findings with this status are counted.
    Valid values: PASS, FAIL, ERROR, SKIPPED.

.EXAMPLE
    $severityCounts = Get-FindingsBySeverity -Findings $allFindings
    # Returns: @{ Critical = 5; High = 10; Medium = 3; Low = 1 }

.EXAMPLE
    $failedSeverityCounts = Get-FindingsBySeverity -Findings $allFindings -StatusFilter "FAIL"
#>
function Get-FindingsBySeverity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
        [array]$Findings = @(),
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('PASS', 'FAIL', 'ERROR', 'SKIPPED')]
        [string]$StatusFilter
    )
    
    # Handle null or empty findings
    if (-not $Findings -or $Findings.Count -eq 0) {
        return @{
            Critical = 0
            High     = 0
            Medium   = 0
            Low      = 0
            Total    = 0
        }
    }
    
    # Filter by status if specified
    $filteredFindings = if ($StatusFilter) {
        @($Findings | Where-Object { $_.Status -eq $StatusFilter })
    } else {
        @($Findings)
    }
    
    # Count by severity
    $criticalCount = @($filteredFindings | Where-Object { $_.Severity -eq 'Critical' }).Count
    $highCount = @($filteredFindings | Where-Object { $_.Severity -eq 'High' }).Count
    $mediumCount = @($filteredFindings | Where-Object { $_.Severity -eq 'Medium' }).Count
    $lowCount = @($filteredFindings | Where-Object { $_.Severity -eq 'Low' }).Count
    
    return @{
        Critical = $criticalCount
        High     = $highCount
        Medium   = $mediumCount
        Low      = $lowCount
        Total    = $filteredFindings.Count
    }
}

