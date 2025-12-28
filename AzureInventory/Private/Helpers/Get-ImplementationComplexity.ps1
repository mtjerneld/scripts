<#
.SYNOPSIS
    Estimates implementation complexity for a cost recommendation.

.DESCRIPTION
    Returns complexity rating (low/medium/high) based on recommendation type
    and impact characteristics.

.PARAMETER Recommendation
    Recommendation object from Azure Advisor.

.EXAMPLE
    $complexity = Get-ImplementationComplexity -Recommendation $rec
#>
function Get-ImplementationComplexity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Recommendation
    )
    
    # Simple heuristic based on category and impact
    $complexity = switch ($Recommendation.Category) {
        "Shutdown" { 
            # Shutting down VMs is low complexity
            "low" 
        }
        "Right-size" { 
            # Right-sizing requires testing but is generally straightforward
            if ($Recommendation.Impact -eq "High") {
                "medium"  # High-impact changes need more caution
            } else {
                "low"
            }
        }
        "Reserved Instance" { 
            # RI purchases require financial analysis
            "medium" 
        }
        "Reserved Capacity" { 
            # Similar to RI
            "medium" 
        }
        "Storage Tier" { 
            # Storage tier changes are low risk
            "low" 
        }
        "App Service Plan" {
            # App Service changes can affect availability
            "medium"
        }
        default { 
            # Unknown categories default to medium
            "medium" 
        }
    }
    
    # Adjust for very high savings (needs more scrutiny)
    if ($Recommendation.PotentialSavings -and $Recommendation.PotentialSavings -gt 50000) {
        if ($complexity -eq "low") {
            $complexity = "medium"
        }
    }
    
    return $complexity
}

