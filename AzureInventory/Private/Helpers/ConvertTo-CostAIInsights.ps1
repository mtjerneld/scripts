<#
.SYNOPSIS
    Converts cost analysis data into AI-ready JSON insights.

.DESCRIPTION
    Extracts and structures the most important cost optimization insights
    for AI analysis, filtering to top opportunities and aggregating by
    customer and category.

.PARAMETER AdvisorRecommendations
    Array of Advisor recommendation objects (from Get-AzureAdvisorRecommendations).

.PARAMETER TopN
    Number of top opportunities to include (default: 15).

.PARAMETER MinSavings
    Minimum annual savings threshold (default: 100).

.EXAMPLE
    $insights = ConvertTo-CostAIInsights -AdvisorRecommendations $recs -TopN 20
#>
function ConvertTo-CostAIInsights {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$AdvisorRecommendations,
        
        [Parameter(Mandatory = $false)]
        [int]$TopN = 15,
        
        [Parameter(Mandatory = $false)]
        [double]$MinSavings = 100
    )
    
    Write-Verbose "Converting cost data to AI insights (TopN: $TopN, MinSavings: $MinSavings)"
    
    # Filter to cost recommendations only
    $costRecommendations = @($AdvisorRecommendations | Where-Object { $_.Category -eq 'Cost' })
    
    if ($costRecommendations.Count -eq 0) {
        Write-Verbose "No cost recommendations found"
        return @{
            domain = "cost_optimization"
            generated_at = (Get-Date).ToString("o")
            summary = @{
                total_potential_savings_annual = 0
                total_potential_savings_monthly = 0
                recommendation_count = 0
                high_impact_count = 0
                affected_customers = 0
                average_savings_per_recommendation = 0
            }
            top_opportunities = @()
            by_category = @()
            by_customer = @()
            by_impact = @()
        }
    }
    
    # Filter recommendations by minimum savings
    $filteredRecommendations = $costRecommendations | Where-Object { 
        $_.PotentialSavings -and $_.PotentialSavings -ge $MinSavings 
    }
    
    # Calculate summary statistics
    $totalSavings = ($filteredRecommendations | Measure-Object -Property PotentialSavings -Sum).Sum
    if (-not $totalSavings) { $totalSavings = 0 }
    
    $highImpactCount = ($filteredRecommendations | Where-Object { 
        $_.Impact -eq 'High' 
    }).Count
    
    # Get unique customers (subscriptions)
    $uniqueCustomers = $filteredRecommendations | Select-Object -ExpandProperty SubscriptionName -Unique
    
    $insights = @{
        domain = "cost_optimization"
        generated_at = (Get-Date).ToString("o")
        
        summary = @{
            total_potential_savings_annual = [math]::Round($totalSavings, 2)
            total_potential_savings_monthly = [math]::Round($totalSavings / 12, 2)
            recommendation_count = $filteredRecommendations.Count
            high_impact_count = $highImpactCount
            affected_customers = $uniqueCustomers.Count
            average_savings_per_recommendation = if ($filteredRecommendations.Count -gt 0) {
                [math]::Round($totalSavings / $filteredRecommendations.Count, 2)
            } else { 0 }
        }
        
        top_opportunities = @($filteredRecommendations | 
            Sort-Object -Property PotentialSavings -Descending |
            Select-Object -First $TopN |
            ForEach-Object {
                @{
                    customer = $_.SubscriptionName
                    subscription = $_.SubscriptionName
                    subscription_id = $_.SubscriptionId
                    resource_name = $_.ResourceName
                    category = $_.Category
                    impact = $_.Impact
                    annual_savings = [math]::Round($_.PotentialSavings, 2)
                    monthly_savings = if ($_.MonthlySavings) { 
                        [math]::Round($_.MonthlySavings, 2) 
                    } else { 
                        [math]::Round($_.PotentialSavings / 12, 2) 
                    }
                    complexity = Get-ImplementationComplexity -Recommendation $_
                    short_description = $_.Problem
                    recommendation_text = $_.Solution
                    technical_details = $_.TechnicalDetails
                }
            })
        
        by_category = @($filteredRecommendations | 
            Group-Object -Property @{
                Expression = {
                    # Extract category from problem/solution text
                    if ($_.Problem -like "*reserved instance*" -or $_.Solution -like "*reserved instance*") {
                        "Reserved Instance"
                    } elseif ($_.Problem -like "*savings plan*" -or $_.Solution -like "*savings plan*") {
                        "Savings Plan"
                    } elseif ($_.Problem -like "*right-size*" -or $_.Solution -like "*right-size*") {
                        "Right-size"
                    } elseif ($_.Problem -like "*shutdown*" -or $_.Solution -like "*shutdown*") {
                        "Shutdown"
                    } elseif ($_.Problem -like "*storage*" -or $_.Solution -like "*storage*") {
                        "Storage Tier"
                    } else {
                        "Other"
                    }
                }
            } |
            Sort-Object { ($_.Group | Measure-Object -Property PotentialSavings -Sum).Sum } -Descending |
            ForEach-Object {
                @{
                    category = $_.Name
                    count = $_.Count
                    total_annual_savings = [math]::Round(
                        ($_.Group | Measure-Object -Property PotentialSavings -Sum).Sum, 2
                    )
                    average_savings = [math]::Round(
                        ($_.Group | Measure-Object -Property PotentialSavings -Average).Average, 2
                    )
                }
            })
        
        by_customer = @($filteredRecommendations |
            Group-Object -Property SubscriptionName |
            Sort-Object { ($_.Group | Measure-Object -Property PotentialSavings -Sum).Sum } -Descending |
            Select-Object -First 10 |
            ForEach-Object {
                $customerRecs = $_.Group
                @{
                    customer = $_.Name
                    recommendation_count = $_.Count
                    total_potential_savings_annual = [math]::Round(
                        ($customerRecs | Measure-Object -Property PotentialSavings -Sum).Sum, 2
                    )
                    top_category = ($customerRecs | 
                        Group-Object -Property @{
                            Expression = {
                                if ($_.Problem -like "*reserved instance*") { "Reserved Instance" }
                                elseif ($_.Problem -like "*right-size*") { "Right-size" }
                                elseif ($_.Problem -like "*shutdown*") { "Shutdown" }
                                else { "Other" }
                            }
                        } | 
                        Sort-Object Count -Descending | 
                        Select-Object -First 1).Name
                    high_impact_count = ($customerRecs | Where-Object { 
                        $_.Impact -eq 'High' 
                    }).Count
                }
            })
        
        by_impact = @($filteredRecommendations |
            Group-Object -Property Impact |
            ForEach-Object {
                @{
                    impact_level = $_.Name
                    count = $_.Count
                    total_savings = [math]::Round(
                        ($_.Group | Measure-Object -Property PotentialSavings -Sum).Sum, 2
                    )
                }
            })
    }
    
    Write-Verbose "Cost insights generated: $($insights.summary.recommendation_count) recommendations, $$($insights.summary.total_potential_savings_annual) total savings"
    
    return $insights
}

