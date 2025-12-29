<#
.SYNOPSIS
    Converts Azure Advisor recommendations into AI-ready JSON insights.

.DESCRIPTION
    Extracts and structures Advisor recommendations across ALL categories
    (Cost, Security, Reliability, Operational Excellence, Performance)
    for comprehensive AI analysis.

.PARAMETER AdvisorRecommendations
    Array of Advisor recommendation objects from Get-AzureAdvisorRecommendations.

.PARAMETER TopN
    Number of top recommendations per category to include (default: 15).

.PARAMETER MinSavings
    Minimum annual savings threshold for cost recommendations (default: 100).

.EXAMPLE
    $insights = ConvertTo-AdvisorAIInsights -AdvisorRecommendations $recs -TopN 20
#>
function ConvertTo-AdvisorAIInsights {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$AdvisorRecommendations,
        
        [Parameter(Mandatory = $false)]
        [int]$TopN = 15,
        
        [Parameter(Mandatory = $false)]
        [double]$MinSavings = 100
    )
    
    Write-Verbose "Converting Advisor data to AI insights (TopN: $TopN, MinSavings: $MinSavings)"
    
    # Handle empty/null data
    if (-not $AdvisorRecommendations -or $AdvisorRecommendations.Count -eq 0) {
        Write-Verbose "No Advisor recommendations found"
        return @{
            domain = "advisor_recommendations"
            generated_at = (Get-Date).ToString("o")
            summary = @{
                total_recommendations = 0
                cost_count = 0
                security_count = 0
                reliability_count = 0
                operational_count = 0
                performance_count = 0
                high_impact_count = 0
                affected_customers = 0
            }
            by_category = @{}
            top_recommendations = @()
            by_impact = @()
            by_subscription = @()
        }
    }
    
    # Group by category
    $costRecs = @($AdvisorRecommendations | Where-Object { $_.Category -eq 'Cost' })
    $securityRecs = @($AdvisorRecommendations | Where-Object { $_.Category -eq 'Security' })
    $reliabilityRecs = @($AdvisorRecommendations | Where-Object { 
        $_.Category -eq 'Reliability' -or $_.Category -eq 'HighAvailability' 
    })
    $operationalRecs = @($AdvisorRecommendations | Where-Object { $_.Category -eq 'OperationalExcellence' })
    $performanceRecs = @($AdvisorRecommendations | Where-Object { $_.Category -eq 'Performance' })
    
    # Calculate summary statistics
    $totalRecs = $AdvisorRecommendations.Count
    $highImpactCount = @($AdvisorRecommendations | Where-Object { $_.Impact -eq 'High' }).Count
    $uniqueCustomers = ($AdvisorRecommendations | Select-Object -ExpandProperty SubscriptionName -Unique).Count
    
    # Process cost recommendations (filter by savings threshold)
    $filteredCostRecs = @($costRecs | Where-Object { 
        -not $_.PotentialSavings -or $_.PotentialSavings -ge $MinSavings 
    })
    
    $totalCostSavings = ($filteredCostRecs | Measure-Object -Property PotentialSavings -Sum).Sum
    if (-not $totalCostSavings) { $totalCostSavings = 0 }
    
    # Build category summaries
    $byCategory = @{}
    
    # Cost category
    if ($filteredCostRecs.Count -gt 0) {
        $byCategory.cost = @{
            count = $filteredCostRecs.Count
            high_impact = @($filteredCostRecs | Where-Object { $_.Impact -eq 'High' }).Count
            total_potential_savings_annual = [math]::Round($totalCostSavings, 2)
            total_potential_savings_monthly = [math]::Round($totalCostSavings / 12, 2)
            affected_resources = ($filteredCostRecs | Select-Object -ExpandProperty ResourceName -Unique).Count
            top_recommendations = @($filteredCostRecs | 
                Sort-Object @{
                    Expression = { if ($_.Impact -eq 'High') { 0 } else { 1 } }
                }, @{
                    Expression = { if ($_.PotentialSavings) { $_.PotentialSavings } else { 0 } }
                    Descending = $true
                } | 
                Select-Object -First $TopN | 
                ForEach-Object {
                    @{
                        resource_name = $_.ResourceName
                        subscription = $_.SubscriptionName
                        impact = $_.Impact
                        problem = $_.Problem
                        solution = $_.Solution
                        annual_savings = if ($_.PotentialSavings) { [math]::Round($_.PotentialSavings, 2) } else { 0 }
                        recommendation_type = $_.RecommendationTypeId
                    }
                })
        }
    }
    
    # Security category
    if ($securityRecs.Count -gt 0) {
        $byCategory.security = @{
            count = $securityRecs.Count
            high_impact = @($securityRecs | Where-Object { $_.Impact -eq 'High' }).Count
            affected_resources = ($securityRecs | Select-Object -ExpandProperty ResourceName -Unique).Count
            top_recommendations = @($securityRecs | 
                Sort-Object @{
                    Expression = { if ($_.Impact -eq 'High') { 0 } else { 1 } }
                }, ResourceName | 
                Select-Object -First $TopN | 
                ForEach-Object {
                    @{
                        resource_name = $_.ResourceName
                        subscription = $_.SubscriptionName
                        impact = $_.Impact
                        problem = $_.Problem
                        solution = $_.Solution
                        risk = $_.Risk
                        recommendation_type = $_.RecommendationTypeId
                    }
                })
        }
    }
    
    # Reliability category
    if ($reliabilityRecs.Count -gt 0) {
        $byCategory.reliability = @{
            count = $reliabilityRecs.Count
            high_impact = @($reliabilityRecs | Where-Object { $_.Impact -eq 'High' }).Count
            affected_resources = ($reliabilityRecs | Select-Object -ExpandProperty ResourceName -Unique).Count
            top_recommendations = @($reliabilityRecs | 
                Sort-Object @{
                    Expression = { if ($_.Impact -eq 'High') { 0 } else { 1 } }
                }, ResourceName | 
                Select-Object -First $TopN | 
                ForEach-Object {
                    @{
                        resource_name = $_.ResourceName
                        subscription = $_.SubscriptionName
                        impact = $_.Impact
                        problem = $_.Problem
                        solution = $_.Solution
                        recommendation_type = $_.RecommendationTypeId
                    }
                })
        }
    }
    
    # Operational Excellence category
    if ($operationalRecs.Count -gt 0) {
        $byCategory.operational_excellence = @{
            count = $operationalRecs.Count
            high_impact = @($operationalRecs | Where-Object { $_.Impact -eq 'High' }).Count
            affected_resources = ($operationalRecs | Select-Object -ExpandProperty ResourceName -Unique).Count
            top_recommendations = @($operationalRecs | 
                Sort-Object @{
                    Expression = { if ($_.Impact -eq 'High') { 0 } else { 1 } }
                }, ResourceName | 
                Select-Object -First $TopN | 
                ForEach-Object {
                    @{
                        resource_name = $_.ResourceName
                        subscription = $_.SubscriptionName
                        impact = $_.Impact
                        problem = $_.Problem
                        solution = $_.Solution
                        recommendation_type = $_.RecommendationTypeId
                    }
                })
        }
    }
    
    # Performance category
    if ($performanceRecs.Count -gt 0) {
        $byCategory.performance = @{
            count = $performanceRecs.Count
            high_impact = @($performanceRecs | Where-Object { $_.Impact -eq 'High' }).Count
            affected_resources = ($performanceRecs | Select-Object -ExpandProperty ResourceName -Unique).Count
            top_recommendations = @($performanceRecs | 
                Sort-Object @{
                    Expression = { if ($_.Impact -eq 'High') { 0 } else { 1 } }
                }, ResourceName | 
                Select-Object -First $TopN | 
                ForEach-Object {
                    @{
                        resource_name = $_.ResourceName
                        subscription = $_.SubscriptionName
                        impact = $_.Impact
                        problem = $_.Problem
                        solution = $_.Solution
                        recommendation_type = $_.RecommendationTypeId
                    }
                })
        }
    }
    
    # Build top recommendations across all categories (prioritize High impact)
    $topRecommendations = @($AdvisorRecommendations | 
        Sort-Object @{
            Expression = {
                # Prioritize by impact (High first), then by category importance
                $impactScore = switch ($_.Impact) {
                    "High" { 0 }
                    "Medium" { 1 }
                    "Low" { 2 }
                    default { 3 }
                }
                $categoryScore = switch ($_.Category) {
                    "Security" { 0 }
                    "Cost" { 1 }
                    "Reliability" { 2 }
                    "Performance" { 3 }
                    "OperationalExcellence" { 4 }
                    default { 5 }
                }
                ($impactScore * 10) + $categoryScore
            }
        } | 
        Select-Object -First $TopN | 
        ForEach-Object {
            @{
                category = $_.Category
                resource_name = $_.ResourceName
                subscription = $_.SubscriptionName
                impact = $_.Impact
                problem = $_.Problem
                solution = $_.Solution
                annual_savings = if ($_.PotentialSavings) { [math]::Round($_.PotentialSavings, 2) } else { $null }
                risk = $_.Risk
                recommendation_type = $_.RecommendationTypeId
            }
        })
    
    # Group by impact
    $byImpact = @($AdvisorRecommendations | 
        Group-Object Impact | 
        ForEach-Object {
            @{
                impact_level = $_.Name
                count = $_.Count
                percentage = [math]::Round(($_.Count / $totalRecs) * 100, 1)
                categories = @($_.Group | Select-Object -ExpandProperty Category -Unique)
            }
        } | Sort-Object @{
            Expression = {
                switch ($_.impact_level) {
                    "High" { 0 }
                    "Medium" { 1 }
                    "Low" { 2 }
                    default { 3 }
                }
            }
        })
    
    # Group by subscription
    $bySubscription = @($AdvisorRecommendations | 
        Group-Object SubscriptionName | 
        Sort-Object Count -Descending | 
        Select-Object -First 10 | 
        ForEach-Object {
            $subRecs = $_.Group
            @{
                subscription = $_.Name
                total_recommendations = $subRecs.Count
                cost_count = @($subRecs | Where-Object { $_.Category -eq 'Cost' }).Count
                security_count = @($subRecs | Where-Object { $_.Category -eq 'Security' }).Count
                reliability_count = @($subRecs | Where-Object { $_.Category -eq 'Reliability' -or $_.Category -eq 'HighAvailability' }).Count
                operational_count = @($subRecs | Where-Object { $_.Category -eq 'OperationalExcellence' }).Count
                performance_count = @($subRecs | Where-Object { $_.Category -eq 'Performance' }).Count
                high_impact_count = @($subRecs | Where-Object { $_.Impact -eq 'High' }).Count
            }
        })
    
    $insights = @{
        domain = "advisor_recommendations"
        generated_at = (Get-Date).ToString("o")
        
        summary = @{
            total_recommendations = $totalRecs
            cost_count = $filteredCostRecs.Count
            security_count = $securityRecs.Count
            reliability_count = $reliabilityRecs.Count
            operational_count = $operationalRecs.Count
            performance_count = $performanceRecs.Count
            high_impact_count = $highImpactCount
            affected_customers = $uniqueCustomers
            total_potential_savings_annual = [math]::Round($totalCostSavings, 2)
        }
        
        by_category = $byCategory
        
        top_recommendations = $topRecommendations
        
        by_impact = $byImpact
        
        by_subscription = $bySubscription
    }
    
    Write-Verbose "Advisor insights generated: $totalRecs recommendations across all categories"
    
    return $insights
}

