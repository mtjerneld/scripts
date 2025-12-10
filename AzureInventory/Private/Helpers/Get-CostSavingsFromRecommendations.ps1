<#
.SYNOPSIS
    Calculates total cost savings from Azure Advisor recommendations.

.DESCRIPTION
    Groups cost recommendations by type to avoid double-counting duplicates,
    then sums the total annual and monthly savings.

.PARAMETER Recommendations
    Array of Advisor recommendation objects.

.EXAMPLE
    $savings = Get-CostSavingsFromRecommendations -Recommendations $advisorRecs
    # Returns: @{ TotalSavings = 5000; MonthlySavings = 416.67; Currency = "USD" }
#>
function Get-CostSavingsFromRecommendations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [array]$Recommendations
    )
    
    $costRecsRaw = @($Recommendations | Where-Object { $_.Category -eq 'Cost' })
    
    if ($costRecsRaw.Count -eq 0) {
        return @{
            TotalSavings   = 0
            MonthlySavings = 0
            Currency       = "USD"
        }
    }
    
    # Group by RecommendationTypeId and ResourceId to avoid duplicates
    $groupedCostRecs = $costRecsRaw | Group-Object -Property @{
        Expression = {
            $typeId = if ($_.RecommendationTypeId) { $_.RecommendationTypeId } else { "Unknown" }
            $resId = if ($_.ResourceId) { $_.ResourceId } else { "Unknown" }
            "$typeId|$resId"
        }
    } | ForEach-Object {
        $group = $_.Group
        if ($group.Count -gt 1) {
            # Sum savings for duplicates
            $totalSavings = ($group | Where-Object { $_.PotentialSavings } | Measure-Object -Property PotentialSavings -Sum).Sum
            $monthlySavings = ($group | Where-Object { $_.MonthlySavings } | Measure-Object -Property MonthlySavings -Sum).Sum
            $currency = ($group | Where-Object { $_.SavingsCurrency } | Select-Object -First 1).SavingsCurrency
            if (-not $currency) { $currency = "USD" }
            
            $firstRec = $group[0]
            $firstRec.PotentialSavings = $totalSavings
            $firstRec.MonthlySavings = $monthlySavings
            $firstRec.SavingsCurrency = $currency
            $firstRec
        } else {
            $group[0]
        }
    }
    
    $costRecs = @($groupedCostRecs | Where-Object { $_.PotentialSavings -or $_.MonthlySavings })
    
    if ($costRecs.Count -eq 0) {
        return @{
            TotalSavings   = 0
            MonthlySavings = 0
            Currency       = "USD"
        }
    }
    
    $totalSavings = ($costRecs | Where-Object { $_.PotentialSavings } | Measure-Object -Property PotentialSavings -Sum).Sum
    $monthlySavings = ($costRecs | Where-Object { $_.MonthlySavings } | Measure-Object -Property MonthlySavings -Sum).Sum
    $currency = ($costRecs | Where-Object { $_.SavingsCurrency } | Select-Object -First 1).SavingsCurrency
    if (-not $currency) { $currency = "USD" }
    
    return @{
        TotalSavings   = if ($totalSavings) { [decimal]$totalSavings } else { 0 }
        MonthlySavings = if ($monthlySavings) { [decimal]$monthlySavings } else { 0 }
        Currency       = $currency
    }
}


