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
    
    # Filter recommendations to remove RI duplicates before cost calculation
    $riRecs = $Recommendations | Where-Object { 
        $_.Category -eq 'Cost' -and (
            $_.Problem -like "*reserved instance*" -or 
            $_.Solution -like "*reserved instance*"
        )
    }
    
    if ($riRecs.Count -gt 0) {
        Write-Verbose "Deduplicating $($riRecs.Count) RI recommendations for cost calculation"
        
        # Extract metadata from TechnicalDetails for filtering
        foreach ($rec in $riRecs) {
            if ($rec.TechnicalDetails -match 'Lookback:\s*(\d+)') {
                $rec | Add-Member -NotePropertyName '_Lookback' -NotePropertyValue $Matches[1] -Force
            }
            if ($rec.TechnicalDetails -match 'Term:\s*(\w+)') {
                $rec | Add-Member -NotePropertyName '_Term' -NotePropertyValue $Matches[1] -Force
            }
            if ($rec.TechnicalDetails -match 'VM Size:\s*([^\|]+)') {
                $rec | Add-Member -NotePropertyName '_VMSize' -NotePropertyValue $Matches[1].Trim() -Force
            }
            
            # Also try to extract from ExtendedProperties if TechnicalDetails doesn't have it
            if (-not $rec._VMSize -and $rec.ExtendedProperties) {
                $extProps = $rec.ExtendedProperties
                if ($extProps -is [string]) {
                    try {
                        $extProps = $extProps | ConvertFrom-Json
                    } catch {
                        Write-Verbose "Could not parse ExtendedProperties JSON for lookback/term extraction"
                    }
                }
                if ($extProps) {
                    if ($extProps.vmSize -and -not $rec._VMSize) {
                        $rec | Add-Member -NotePropertyName '_VMSize' -NotePropertyValue $extProps.vmSize -Force
                    }
                    if ($extProps.lookbackPeriod -and -not $rec._Lookback) {
                        $rec | Add-Member -NotePropertyName '_Lookback' -NotePropertyValue $extProps.lookbackPeriod -Force
                    }
                    if ($extProps.term -and -not $rec._Term) {
                        $rec | Add-Member -NotePropertyName '_Term' -NotePropertyValue $extProps.term -Force
                    }
                }
            }
        }
        
        # Filter to 60-day lookback (most reliable)
        $riFiltered = $riRecs | Where-Object { $_._Lookback -eq '60' }
        
        if ($riFiltered.Count -eq 0) {
            Write-Verbose "No 60-day lookback found, using all lookback periods"
            $riFiltered = $riRecs
        }
        
        # Group by (Subscription + VMSize) and keep best term per group
        $riGroups = $riFiltered | Group-Object -Property { 
            "$($_.SubscriptionName)|$($_._VMSize)" 
        }
        
        $optimizedRi = foreach ($group in $riGroups) {
            # Prefer P3Y (better savings) if available, otherwise P1Y
            $p3y = $group.Group | Where-Object { $_._Term -eq 'P3Y' } | Select-Object -First 1
            $p1y = $group.Group | Where-Object { $_._Term -eq 'P1Y' } | Select-Object -First 1
            
            if ($p3y) { 
                $p3y 
            } elseif ($p1y) { 
                $p1y 
            } else {
                # Fallback: use first item if no term match
                $group.Group | Select-Object -First 1
            }
        }
        
        # Replace RI recommendations with deduplicated versions
        $nonRiRecs = $Recommendations | Where-Object { 
            -not ($_.Category -eq 'Cost' -and (
                $_.Problem -like "*reserved instance*" -or 
                $_.Solution -like "*reserved instance*"
            ))
        }
        
        $Recommendations = @($nonRiRecs) + @($optimizedRi)
        
        Write-Verbose "RI recommendations reduced from $($riRecs.Count) to $($optimizedRi.Count) for cost calculation"
    }
    
    $costRecsRaw = @($Recommendations | Where-Object { $_.Category -eq 'Cost' })
    
    if ($costRecsRaw.Count -eq 0) {
        return @{
            TotalSavings   = 0
            MonthlySavings = 0
            Currency       = "USD"
        }
    }
    
    # Ensure ExtendedProperty is parsed and PotentialSavings is extracted for all cost recommendations
    foreach ($rec in $costRecsRaw) {
        if (-not $rec.PotentialSavings -and $rec.ExtendedProperties) {
            $extProps = $rec.ExtendedProperties
            
            # Parse if JSON string
            if ($extProps -is [string]) {
                try {
                    $extProps = $extProps | ConvertFrom-Json
                } catch {
                    Write-Verbose "Could not parse ExtendedProperties JSON for savings extraction"
                    continue
                }
            }
            
            # Extract savings values if not already set
            if ($extProps) {
                if (-not $rec.PotentialSavings -and $extProps.annualSavingsAmount) {
                    try {
                        $rec.PotentialSavings = [decimal]$extProps.annualSavingsAmount
                    } catch {
                        Write-Verbose "Could not parse annualSavingsAmount: $($extProps.annualSavingsAmount)"
                    }
                }
                if (-not $rec.MonthlySavings -and $extProps.savingsAmount) {
                    try {
                        $rec.MonthlySavings = [decimal]$extProps.savingsAmount
                    } catch {
                        Write-Verbose "Could not parse savingsAmount: $($extProps.savingsAmount)"
                    }
                }
                if (-not $rec.SavingsCurrency -and $extProps.savingsCurrency) {
                    $rec.SavingsCurrency = $extProps.savingsCurrency
                }
                
                # If we only have monthly, calculate annual
                if (-not $rec.PotentialSavings -and $rec.MonthlySavings) {
                    $rec.PotentialSavings = [decimal]$rec.MonthlySavings * 12
                }
            }
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


