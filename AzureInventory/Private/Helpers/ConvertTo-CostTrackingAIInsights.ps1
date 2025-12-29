<#
.SYNOPSIS
    Converts cost tracking data into AI-ready JSON insights.

.DESCRIPTION
    Extracts and structures actual cost spending data (not recommendations)
    for AI analysis, focusing on top spenders, cost trends, and anomalies.

.PARAMETER CostTrackingData
    Hashtable with aggregated cost data from Collect-CostData.

.PARAMETER TopN
    Number of top spenders to include (default: 20).

.EXAMPLE
    $insights = ConvertTo-CostTrackingAIInsights -CostTrackingData $costData -TopN 25
#>
function ConvertTo-CostTrackingAIInsights {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$CostTrackingData,
        
        [Parameter(Mandatory = $false)]
        [int]$TopN = 20
    )
    
    Write-Verbose "Converting cost tracking data to AI insights (TopN: $TopN)"
    
    # Handle empty/null data
    if (-not $CostTrackingData -or $CostTrackingData.Count -eq 0) {
        Write-Verbose "No cost tracking data found"
        return @{
            domain = "cost_tracking"
            generated_at = (Get-Date).ToString("o")
            summary = @{
                total_cost_usd = 0
                total_cost_local = 0
                currency = ""
                period_days = 0
                subscription_count = 0
                resource_count = 0
                category_count = 0
            }
            top_spenders = @()
            cost_trends = @{}
            by_category = @()
            anomalies = @()
            by_subscription = @()
        }
    }
    
    # Extract data
    $totalCostUSD = if ($CostTrackingData.TotalCostUSD) { $CostTrackingData.TotalCostUSD } else { 0 }
    $totalCostLocal = if ($CostTrackingData.TotalCostLocal) { $CostTrackingData.TotalCostLocal } else { 0 }
    $currency = if ($CostTrackingData.Currency) { $CostTrackingData.Currency } else { "USD" }
    $periodDays = if ($CostTrackingData.DaysToInclude) { $CostTrackingData.DaysToInclude } else { 30 }
    
    $bySubscription = if ($CostTrackingData.BySubscription) { $CostTrackingData.BySubscription } else { @{} }
    $byMeterCategory = if ($CostTrackingData.ByMeterCategory) { $CostTrackingData.ByMeterCategory } else { @{} }
    $topResources = if ($CostTrackingData.TopResources) { $CostTrackingData.TopResources } else { @() }
    $dailyTrend = if ($CostTrackingData.DailyTrend) { $CostTrackingData.DailyTrend } else { @() }
    $rawData = if ($CostTrackingData.RawData) { $CostTrackingData.RawData } else { @() }
    
    $subscriptionCount = $bySubscription.Count
    $categoryCount = $byMeterCategory.Count
    
    # Calculate resource count
    $resourceCount = if ($topResources.Count -gt 0) {
        $topResources.Count
    } elseif ($rawData.Count -gt 0) {
        ($rawData | Select-Object -ExpandProperty ResourceName -Unique).Count
    } else {
        0
    }
    
    # Build top spenders (resources)
    $topSpenders = @()
    if ($topResources.Count -gt 0) {
        $topSpenders = @($topResources | 
            Select-Object -First $TopN | 
            ForEach-Object {
                @{
                    resource_name = $_.ResourceName
                    resource_type = $_.ResourceType
                    resource_group = $_.ResourceGroup
                    subscription = $_.SubscriptionName
                    cost_usd = [math]::Round($_.CostUSD, 2)
                    cost_local = [math]::Round($_.CostLocal, 2)
                    meter_category = $_.MeterCategory
                }
            })
    } elseif ($rawData.Count -gt 0) {
        # Fallback: calculate from raw data
        $resourceGroups = $rawData | 
            Where-Object { $_.ResourceName -and -not [string]::IsNullOrWhiteSpace($_.ResourceName) } |
            Group-Object ResourceName
        
        $topSpenders = @($resourceGroups | 
            ForEach-Object {
                $resItems = $_.Group
                $resCostUSD = ($resItems | Measure-Object -Property CostUSD -Sum).Sum
                $resCostLocal = ($resItems | Measure-Object -Property CostLocal -Sum).Sum
                $firstItem = $resItems[0]
                
                [PSCustomObject]@{
                    ResourceName = $_.Name
                    ResourceType = $firstItem.ResourceType
                    ResourceGroup = $firstItem.ResourceGroup
                    SubscriptionName = $firstItem.SubscriptionName
                    CostUSD = $resCostUSD
                    CostLocal = $resCostLocal
                    MeterCategory = ($resItems | Group-Object MeterCategory | Sort-Object Count -Descending | Select-Object -First 1).Name
                }
            } | 
            Sort-Object CostUSD -Descending | 
            Select-Object -First $TopN | 
            ForEach-Object {
                @{
                    resource_name = $_.ResourceName
                    resource_type = $_.ResourceType
                    resource_group = $_.ResourceGroup
                    subscription = $_.SubscriptionName
                    cost_usd = [math]::Round($_.CostUSD, 2)
                    cost_local = [math]::Round($_.CostLocal, 2)
                    meter_category = $_.MeterCategory
                }
            })
    }
    
    # Calculate cost trends
    $costTrends = @{}
    if ($dailyTrend.Count -ge 2) {
        # Compare first half vs second half
        $totalDays = $dailyTrend.Count
        $daysPerHalf = [math]::Floor($totalDays / 2)
        
        $firstHalfDays = $dailyTrend[0..($daysPerHalf - 1)]
        $secondHalfDays = $dailyTrend[($totalDays - $daysPerHalf)..($totalDays - 1)]
        
        $firstHalfTotal = ($firstHalfDays | ForEach-Object { $_.TotalCostLocal } | Measure-Object -Sum).Sum
        $secondHalfTotal = ($secondHalfDays | ForEach-Object { $_.TotalCostLocal } | Measure-Object -Sum).Sum
        
        if ($firstHalfTotal -gt 0) {
            $trendPercent = [math]::Round((($secondHalfTotal - $firstHalfTotal) / $firstHalfTotal) * 100, 1)
            $trendDirection = if ($trendPercent -gt 5) { "increasing" } elseif ($trendPercent -lt -5) { "decreasing" } else { "stable" }
            
            $costTrends = @{
                trend_direction = $trendDirection
                trend_percentage = $trendPercent
                first_half_total = [math]::Round($firstHalfTotal, 2)
                second_half_total = [math]::Round($secondHalfTotal, 2)
                period_days = $periodDays
            }
        }
    }
    
    # Build by category
    $byCategory = @()
    if ($byMeterCategory.Count -gt 0) {
        $byCategory = @($byMeterCategory.Values | 
            Sort-Object { $_.CostUSD } -Descending | 
            Select-Object -First 10 | 
            ForEach-Object {
                $categoryName = if ($_.MeterCategory) { $_.MeterCategory } else { "Unknown" }
                @{
                    category = $categoryName
                    cost_usd = [math]::Round($_.CostUSD, 2)
                    cost_local = [math]::Round($_.CostLocal, 2)
                    percentage = if ($totalCostUSD -gt 0) {
                        [math]::Round(($_.CostUSD / $totalCostUSD) * 100, 1)
                    } else {
                        0
                    }
                }
            })
    }
    
    # Detect anomalies (unusual spikes in daily costs)
    $anomalies = @()
    if ($dailyTrend.Count -gt 3) {
        $dailyCosts = $dailyTrend | ForEach-Object { $_.TotalCostLocal }
        $mean = ($dailyCosts | Measure-Object -Average).Average
        $stdDev = if ($dailyCosts.Count -gt 1) {
            $variance = ($dailyCosts | ForEach-Object { [math]::Pow($_ - $mean, 2) } | Measure-Object -Average).Average
            [math]::Sqrt($variance)
        } else {
            0
        }
        $threshold = $mean + (2 * $stdDev)
        
        foreach ($day in $dailyTrend) {
            if ($day.TotalCostLocal -gt $threshold) {
                $anomalies += @{
                    date = if ($day.Date -is [DateTime]) {
                        $day.Date.ToString("yyyy-MM-dd")
                    } else {
                        $day.DateString
                    }
                    cost_local = [math]::Round($day.TotalCostLocal, 2)
                    cost_usd = [math]::Round($day.TotalCostUSD, 2)
                    deviation = [math]::Round((($day.TotalCostLocal - $mean) / $mean) * 100, 1)
                    description = "Unusual cost spike: $($day.TotalCostLocal) (mean: $([math]::Round($mean, 2)))"
                }
            }
        }
    }
    
    # Build by subscription
    $bySubscriptionList = @()
    if ($bySubscription.Count -gt 0) {
        $bySubscriptionList = @($bySubscription.Values | 
            Sort-Object { $_.CostUSD } -Descending | 
            Select-Object -First 10 | 
            ForEach-Object {
                @{
                    subscription = $_.Name
                    cost_usd = [math]::Round($_.CostUSD, 2)
                    cost_local = [math]::Round($_.CostLocal, 2)
                    percentage = if ($totalCostUSD -gt 0) {
                        [math]::Round(($_.CostUSD / $totalCostUSD) * 100, 1)
                    } else {
                        0
                    }
                }
            })
    }
    
    $insights = @{
        domain = "cost_tracking"
        generated_at = (Get-Date).ToString("o")
        
        summary = @{
            total_cost_usd = [math]::Round($totalCostUSD, 2)
            total_cost_local = [math]::Round($totalCostLocal, 2)
            currency = $currency
            period_days = $periodDays
            subscription_count = $subscriptionCount
            resource_count = $resourceCount
            category_count = $categoryCount
        }
        
        top_spenders = $topSpenders
        
        cost_trends = $costTrends
        
        by_category = $byCategory
        
        anomalies = $anomalies
        
        by_subscription = $bySubscriptionList
    }
    
    Write-Verbose "Cost tracking insights generated: $$totalCostUSD USD total, $resourceCount resources, $subscriptionCount subscriptions"
    
    return $insights
}

