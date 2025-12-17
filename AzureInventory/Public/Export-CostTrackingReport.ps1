<#
.SYNOPSIS
    Generates a consolidated HTML report for Azure Cost Tracking data.

.DESCRIPTION
    Creates an interactive HTML report showing Azure cost data with meter-level granularity,
    aggregated by subscription, meter category, and resource. Includes stacked bar chart visualization.

.PARAMETER CostTrackingData
    Hashtable with aggregated cost data from Collect-CostData.

.PARAMETER OutputPath
    Path for the HTML report output.

.PARAMETER TenantId
    Azure Tenant ID for display in report.

.OUTPUTS
    Hashtable with OutputPath and metadata for Dashboard.
#>
function Export-CostTrackingReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$CostTrackingData,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        
        [string]$TenantId = "Unknown"
    )
    
    # Handle empty/null data
    if (-not $CostTrackingData -or $CostTrackingData.Count -eq 0) {
        $CostTrackingData = @{
            GeneratedAt = Get-Date
            PeriodStart = (Get-Date).AddDays(-30)
            PeriodEnd = Get-Date
            DaysToInclude = 30
            TotalCostLocal = 0
            TotalCostUSD = 0
            Currency = ""
            BySubscription = @{}
            ByMeterCategory = @{}
            TopResources = @()
            DailyTrend = @()
            RawData = @()
            SubscriptionCount = 0
        }
    }
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $periodStart = $CostTrackingData.PeriodStart
    $periodEnd = $CostTrackingData.PeriodEnd
    $totalCostLocal = [math]::Round($CostTrackingData.TotalCostLocal, 2)
    $totalCostUSD = [math]::Round($CostTrackingData.TotalCostUSD, 2)
    $currency = $CostTrackingData.Currency
    $subscriptionCount = $CostTrackingData.SubscriptionCount
    $bySubscription = $CostTrackingData.BySubscription
    $byMeterCategory = $CostTrackingData.ByMeterCategory
    # Sort top resources by CostUSD descending
    $topResources = @($CostTrackingData.TopResources | Sort-Object CostUSD -Descending)
    $dailyTrend = $CostTrackingData.DailyTrend
    
    # Calculate trend (compare first half vs second half of period)
    $trendPercent = 0
    $trendDirection = "neutral"
    if ($dailyTrend.Count -ge 2) {
        $midPoint = [math]::Floor($dailyTrend.Count / 2)
        $firstHalf = ($dailyTrend[0..($midPoint - 1)] | ForEach-Object { $_.TotalCostLocal } | Measure-Object -Sum).Sum
        $secondHalf = ($dailyTrend[$midPoint..($dailyTrend.Count - 1)] | ForEach-Object { $_.TotalCostLocal } | Measure-Object -Sum).Sum
        
        if ($firstHalf -gt 0) {
            $trendPercent = [math]::Round((($secondHalf - $firstHalf) / $firstHalf) * 100, 1)
            $trendDirection = if ($trendPercent -gt 0) { "up" } elseif ($trendPercent -lt 0) { "down" } else { "neutral" }
        }
    }
    
    # Prepare subscription data as array
    $subscriptionsArray = @($bySubscription.Values | Sort-Object CostLocal -Descending)
    
    # Prepare categories data as array
    $categoriesArray = @($byMeterCategory.Values | Sort-Object CostLocal -Descending)
    
    # Get unique meter categories, subscriptions, meters, and resources for chart
    $allCategories = @($byMeterCategory.Keys | Sort-Object)
    $allSubscriptionNames = @($bySubscription.Values | ForEach-Object { $_.Name } | Sort-Object)
    
    # Get unique meters across all days (top 15 by total cost)
    $meterTotals = @{}
    foreach ($day in $dailyTrend) {
        if ($day.ByMeter) {
            foreach ($meterEntry in $day.ByMeter.GetEnumerator()) {
                if (-not $meterTotals.ContainsKey($meterEntry.Key)) {
                    $meterTotals[$meterEntry.Key] = 0
                }
                $meterTotals[$meterEntry.Key] += $meterEntry.Value.CostLocal
            }
        }
    }
    $allMeters = @($meterTotals.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15 | ForEach-Object { $_.Key })
    
    # Get unique resources across all days (top 15 by total cost)
    $resourceTotals = @{}
    foreach ($day in $dailyTrend) {
        if ($day.ByResource) {
            foreach ($resEntry in $day.ByResource.GetEnumerator()) {
                if (-not $resourceTotals.ContainsKey($resEntry.Key)) {
                    $resourceTotals[$resEntry.Key] = 0
                }
                $resourceTotals[$resEntry.Key] += $resEntry.Value.CostLocal
            }
        }
    }
    $allResourceNames = @($resourceTotals.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15 | ForEach-Object { $_.Key })
    
    # Prepare daily trend data with breakdowns for stacked chart
    $chartLabels = @()
    $chartDatasetsByCategory = @{}
    $chartDatasetsBySubscription = @{}
    $chartDatasetsByMeter = @{}
    $chartDatasetsByResource = @{}
    
    # Also prepare raw data with category breakdown for filtering
    $rawDailyData = @()
    
    foreach ($category in $allCategories) {
        $chartDatasetsByCategory[$category] = @()
    }
    foreach ($subName in $allSubscriptionNames) {
        $chartDatasetsBySubscription[$subName] = @()
    }
    foreach ($meter in $allMeters) {
        $chartDatasetsByMeter[$meter] = @()
    }
    foreach ($resName in $allResourceNames) {
        $chartDatasetsByResource[$resName] = @()
    }
    
    foreach ($day in ($dailyTrend | Sort-Object { $_.Date })) {
        $chartLabels += $day.DateString
        
        # Build raw daily data for JavaScript filtering
        $dayData = @{
            date = $day.DateString
            categories = @{}
            subscriptions = @{}
            meters = @{}
            resources = @{}
            totalCostLocal = [math]::Round($day.TotalCostLocal, 2)
        }
        
        # By Category (with subscription breakdown)
        $dayMeterOtherCost = $day.TotalCostLocal
        $dayResourceOtherCost = $day.TotalCostLocal
        
        foreach ($category in $allCategories) {
            $catCost = 0
            $catSubBreakdown = @{}
            if ($day.ByCategory -and $day.ByCategory.ContainsKey($category)) {
                $catCost = [math]::Round($day.ByCategory[$category].CostLocal, 2)
                if ($day.ByCategory[$category].BySubscription) {
                    foreach ($subEntry in $day.ByCategory[$category].BySubscription.GetEnumerator()) {
                        $catSubBreakdown[$subEntry.Key] = [math]::Round($subEntry.Value.CostLocal, 2)
                    }
                }
            }
            $chartDatasetsByCategory[$category] += $catCost
            $dayData.categories[$category] = @{ total = $catCost; bySubscription = $catSubBreakdown }
        }
        
        # By Subscription (with category breakdown)
        foreach ($subName in $allSubscriptionNames) {
            $subCost = 0
            $subCatBreakdown = @{}
            if ($day.BySubscription -and $day.BySubscription.ContainsKey($subName)) {
                $subCost = [math]::Round($day.BySubscription[$subName].CostLocal, 2)
                if ($day.BySubscription[$subName].ByCategory) {
                    foreach ($catEntry in $day.BySubscription[$subName].ByCategory.GetEnumerator()) {
                        $subCatBreakdown[$catEntry.Key] = [math]::Round($catEntry.Value.CostLocal, 2)
                    }
                }
            }
            $chartDatasetsBySubscription[$subName] += $subCost
            $dayData.subscriptions[$subName] = @{ total = $subCost; byCategory = $subCatBreakdown }
        }
        
        # By Meter (with category and subscription breakdown)
        foreach ($meter in $allMeters) {
            $meterCost = 0
            $meterCatBreakdown = @{}
            $meterSubBreakdown = @{}
            if ($day.ByMeter -and $day.ByMeter.ContainsKey($meter)) {
                $meterCost = [math]::Round($day.ByMeter[$meter].CostLocal, 2)
                $dayMeterOtherCost -= $day.ByMeter[$meter].CostLocal
                if ($day.ByMeter[$meter].ByCategory) {
                    foreach ($catEntry in $day.ByMeter[$meter].ByCategory.GetEnumerator()) {
                        $meterCatBreakdown[$catEntry.Key] = [math]::Round($catEntry.Value.CostLocal, 2)
                    }
                }
                if ($day.ByMeter[$meter].BySubscription) {
                    foreach ($subEntry in $day.ByMeter[$meter].BySubscription.GetEnumerator()) {
                        $meterSubBreakdown[$subEntry.Key] = [math]::Round($subEntry.Value.CostLocal, 2)
                    }
                }
            }
            $chartDatasetsByMeter[$meter] += $meterCost
            $dayData.meters[$meter] = @{ total = $meterCost; byCategory = $meterCatBreakdown; bySubscription = $meterSubBreakdown }
        }
        
        # Add "Other" for meters
        $dayData.meters["Other"] = @{ total = [math]::Round([math]::Max(0, $dayMeterOtherCost), 2); byCategory = @{}; bySubscription = @{} }
        
        # By Resource (with category and subscription breakdown)
        foreach ($resName in $allResourceNames) {
            $resCost = 0
            $resCatBreakdown = @{}
            $resSubBreakdown = @{}
            if ($day.ByResource -and $day.ByResource.ContainsKey($resName)) {
                $resCost = [math]::Round($day.ByResource[$resName].CostLocal, 2)
                $dayResourceOtherCost -= $day.ByResource[$resName].CostLocal
                if ($day.ByResource[$resName].ByCategory) {
                    foreach ($catEntry in $day.ByResource[$resName].ByCategory.GetEnumerator()) {
                        $resCatBreakdown[$catEntry.Key] = [math]::Round($catEntry.Value.CostLocal, 2)
                    }
                }
                if ($day.ByResource[$resName].BySubscription) {
                    foreach ($subEntry in $day.ByResource[$resName].BySubscription.GetEnumerator()) {
                        $resSubBreakdown[$subEntry.Key] = [math]::Round($subEntry.Value.CostLocal, 2)
                    }
                }
            }
            $chartDatasetsByResource[$resName] += $resCost
            $dayData.resources[$resName] = @{ total = $resCost; byCategory = $resCatBreakdown; bySubscription = $resSubBreakdown }
        }
        
        # Add "Other" for resources
        $dayData.resources["Other"] = @{ total = [math]::Round([math]::Max(0, $dayResourceOtherCost), 2); byCategory = @{}; bySubscription = @{} }
        
        $rawDailyData += $dayData
    }
    
    # Convert raw daily data to JSON for JavaScript
    $rawDailyDataJson = $rawDailyData | ConvertTo-Json -Depth 6 -Compress
    
    # Color palette for categories
    $colors = @(
        "rgba(84, 160, 255, 0.8)",   # Blue
        "rgba(0, 210, 106, 0.8)",    # Green
        "rgba(255, 107, 107, 0.8)",  # Red
        "rgba(254, 202, 87, 0.8)",   # Yellow
        "rgba(155, 89, 182, 0.8)",   # Purple
        "rgba(255, 159, 67, 0.8)",   # Orange
        "rgba(52, 152, 219, 0.8)",   # Light Blue
        "rgba(46, 204, 113, 0.8)",   # Emerald
        "rgba(231, 76, 60, 0.8)",    # Alizarin
        "rgba(241, 196, 15, 0.8)",   # Sunflower
        "rgba(142, 68, 173, 0.8)",   # Wisteria
        "rgba(230, 126, 34, 0.8)",   # Carrot
        "rgba(26, 188, 156, 0.8)",   # Turquoise
        "rgba(192, 57, 43, 0.8)",    # Pomegranate
        "rgba(39, 174, 96, 0.8)",    # Nephritis
        "rgba(41, 128, 185, 0.8)"    # Belize Hole
    )
    
    # Build datasets JSON for Chart.js - by Category
    $datasetsByCategoryJson = @()
    $colorIndex = 0
    foreach ($category in $allCategories) {
        $color = $colors[$colorIndex % $colors.Count]
        $dataArray = $chartDatasetsByCategory[$category] -join ","
        $escapedCategory = $category -replace '"', '\"'
        $datasetsByCategoryJson += @"
            {
                label: "$escapedCategory",
                data: [$dataArray],
                backgroundColor: "$color",
                borderColor: "$color",
                borderWidth: 1
            }
"@
        $colorIndex++
    }
    $datasetsByCategoryJsonString = $datasetsByCategoryJson -join ",`n"
    
    # Build datasets JSON for Chart.js - by Subscription
    $datasetsBySubscriptionJson = @()
    $colorIndex = 0
    foreach ($subName in $allSubscriptionNames) {
        $color = $colors[$colorIndex % $colors.Count]
        $dataArray = $chartDatasetsBySubscription[$subName] -join ","
        $escapedSubName = $subName -replace '"', '\"'
        $datasetsBySubscriptionJson += @"
            {
                label: "$escapedSubName",
                data: [$dataArray],
                backgroundColor: "$color",
                borderColor: "$color",
                borderWidth: 1
            }
"@
        $colorIndex++
    }
    $datasetsBySubscriptionJsonString = $datasetsBySubscriptionJson -join ",`n"
    
    # Build datasets JSON for Chart.js - by Meter
    $datasetsByMeterJson = @()
    $colorIndex = 0
    foreach ($meter in $allMeters) {
        $color = $colors[$colorIndex % $colors.Count]
        $dataArray = $chartDatasetsByMeter[$meter] -join ","
        $escapedMeter = $meter -replace '"', '\"'
        $datasetsByMeterJson += @"
            {
                label: "$escapedMeter",
                data: [$dataArray],
                backgroundColor: "$color",
                borderColor: "$color",
                borderWidth: 1
            }
"@
        $colorIndex++
    }
    $datasetsByMeterJsonString = $datasetsByMeterJson -join ",`n"
    
    # Build datasets JSON for Chart.js - by Resource
    $datasetsByResourceJson = @()
    $colorIndex = 0
    foreach ($resName in $allResourceNames) {
        $color = $colors[$colorIndex % $colors.Count]
        $dataArray = $chartDatasetsByResource[$resName] -join ","
        $escapedResName = $resName -replace '"', '\"'
        $datasetsByResourceJson += @"
            {
                label: "$escapedResName",
                data: [$dataArray],
                backgroundColor: "$color",
                borderColor: "$color",
                borderWidth: 1
            }
"@
        $colorIndex++
    }
    $datasetsByResourceJsonString = $datasetsByResourceJson -join ",`n"
    
    # Convert chart labels to JSON
    $chartLabelsJson = ($chartLabels | ForEach-Object { "`"$_`"" }) -join ","
    
    # Build subscription options for filter
    $subscriptionOptionsHtml = ""
    foreach ($sub in $subscriptionsArray) {
        $subName = if ($sub.Name) { [System.Web.HttpUtility]::HtmlEncode($sub.Name) } else { "Unknown" }
        $subId = if ($sub.SubscriptionId) { $sub.SubscriptionId } else { "" }
        $subscriptionOptionsHtml += @"
                        <label class="subscription-checkbox">
                            <input type="checkbox" value="$subName" data-subid="$subId" checked onchange="filterBySubscription()">
                            <span>$subName</span>
                        </label>
"@
    }
    
    # Generate subscription rows HTML
    $subscriptionRowsHtml = ""
    foreach ($sub in $subscriptionsArray) {
        $subName = if ($sub.Name) { [System.Web.HttpUtility]::HtmlEncode($sub.Name) } else { "Unknown" }
        $subCostLocal = [math]::Round($sub.CostLocal, 2)
        $subCostUSD = [math]::Round($sub.CostUSD, 2)
        $subCount = $sub.ItemCount
        $subscriptionRowsHtml += @"
                        <tr data-subscription="$subName">
                            <td>$subName</td>
                            <td class="cost-value">$currency $subCostLocal</td>
                            <td class="cost-value">`$$subCostUSD</td>
                            <td>$subCount</td>
                        </tr>
"@
    }
    
    # Generate top resources rows HTML (sorted by CostUSD)
    $topResourcesRowsHtml = ""
    foreach ($res in $topResources) {
        $resName = if ($res.ResourceName) { [System.Web.HttpUtility]::HtmlEncode($res.ResourceName) } else { "N/A" }
        $resGroup = if ($res.ResourceGroup) { [System.Web.HttpUtility]::HtmlEncode($res.ResourceGroup) } else { "N/A" }
        $resSub = if ($res.SubscriptionName) { [System.Web.HttpUtility]::HtmlEncode($res.SubscriptionName) } else { "N/A" }
        $resType = if ($res.ResourceType) { [System.Web.HttpUtility]::HtmlEncode($res.ResourceType) } else { "N/A" }
        $resCat = if ($res.MeterCategory) { [System.Web.HttpUtility]::HtmlEncode($res.MeterCategory) } else { "N/A" }
        $resCostLocal = [math]::Round($res.CostLocal, 2)
        $resCostUSD = [math]::Round($res.CostUSD, 2)
        $topResourcesRowsHtml += @"
                        <tr data-subscription="$resSub">
                            <td>$resName</td>
                            <td>$resGroup</td>
                            <td>$resSub</td>
                            <td>$resType</td>
                            <td>$resCat</td>
                            <td class="cost-value">$currency $resCostLocal</td>
                            <td class="cost-value">`$$resCostUSD</td>
                        </tr>
"@
    }
    
    # Generate category sections HTML with drilldown (4 levels: Category > SubCategory > Meter > Resource)
    $categorySectionsHtml = ""
    $meterIdCounter = 0
    foreach ($cat in $categoriesArray) {
        $catName = if ($cat.MeterCategory) { [System.Web.HttpUtility]::HtmlEncode($cat.MeterCategory) } else { "Unknown" }
        $catCostLocal = [math]::Round($cat.CostLocal, 2)
        $catCostUSD = [math]::Round($cat.CostUSD, 2)
        
        $subCatHtml = ""
        if ($cat.SubCategories -and $cat.SubCategories.Count -gt 0) {
            # Sort subcategories by cost descending
            $sortedSubCats = $cat.SubCategories.GetEnumerator() | Sort-Object { $_.Value.CostUSD } -Descending
            foreach ($subCatEntry in $sortedSubCats) {
                $subCat = $subCatEntry.Value
                $subCatName = if ($subCat.MeterSubCategory) { [System.Web.HttpUtility]::HtmlEncode($subCat.MeterSubCategory) } else { "N/A" }
                $subCatCostLocal = [math]::Round($subCat.CostLocal, 2)
                $subCatCostUSD = [math]::Round($subCat.CostUSD, 2)
                
                $meterCardsHtml = ""
                if ($subCat.Meters -and $subCat.Meters.Count -gt 0) {
                    # Sort meters by cost descending
                    $sortedMeters = $subCat.Meters.GetEnumerator() | Sort-Object { $_.Value.CostUSD } -Descending
                    foreach ($meterEntry in $sortedMeters) {
                        $meter = $meterEntry.Value
                        $meterName = if ($meter.Meter) { [System.Web.HttpUtility]::HtmlEncode($meter.Meter) } else { "Unknown" }
                        $meterCostLocal = [math]::Round($meter.CostLocal, 2)
                        $meterCostUSD = [math]::Round($meter.CostUSD, 2)
                        $meterCount = $meter.ItemCount
                        $meterId = "meter_$meterIdCounter"
                        $meterIdCounter++
                        
                        # Build resource rows if available
                        $resourceRowsHtml = ""
                        $hasResources = $false
                        if ($meter.Resources -and $meter.Resources.Count -gt 0) {
                            $hasResources = $true
                            # Sort resources by cost descending
                            $sortedResources = $meter.Resources.GetEnumerator() | Sort-Object { $_.Value.CostUSD } -Descending
                            foreach ($resEntry in $sortedResources) {
                                $res = $resEntry.Value
                                $resName = if ($res.ResourceName) { [System.Web.HttpUtility]::HtmlEncode($res.ResourceName) } else { "Unknown" }
                                $resGroup = if ($res.ResourceGroup) { [System.Web.HttpUtility]::HtmlEncode($res.ResourceGroup) } else { "N/A" }
                                $resSub = if ($res.SubscriptionName) { [System.Web.HttpUtility]::HtmlEncode($res.SubscriptionName) } else { "N/A" }
                                $resCostLocal = [math]::Round($res.CostLocal, 2)
                                $resCostUSD = [math]::Round($res.CostUSD, 2)
                                $resourceRowsHtml += @"
                                            <tr data-subscription="$resSub">
                                                <td>$resName</td>
                                                <td>$resGroup</td>
                                                <td>$resSub</td>
                                                <td class="cost-value">$currency $resCostLocal</td>
                                                <td class="cost-value">`$$resCostUSD</td>
                                            </tr>
"@
                            }
                        }
                        
                        if ($hasResources) {
                            $meterCardsHtml += @"
                            <div class="meter-card">
                                <div class="meter-header" onclick="toggleMeter(this)">
                                    <span class="expand-arrow">&#9654;</span>
                                    <span class="meter-name">$meterName</span>
                                    <span class="meter-cost">$currency $meterCostLocal (`$$meterCostUSD)</span>
                                    <span class="meter-count">$meterCount records</span>
                                </div>
                                <div class="meter-content">
                                    <table class="cost-table resource-table">
                                        <thead>
                                            <tr>
                                                <th>Resource</th>
                                                <th>Resource Group</th>
                                                <th>Subscription</th>
                                                <th>Cost ($currency)</th>
                                                <th>Cost (USD)</th>
                                            </tr>
                                        </thead>
                                        <tbody>
$resourceRowsHtml
                                        </tbody>
                                    </table>
                                </div>
                            </div>
"@
                        } else {
                            $meterCardsHtml += @"
                            <div class="meter-card no-expand">
                                <div class="meter-header">
                                    <span class="meter-name">$meterName</span>
                                    <span class="meter-cost">$currency $meterCostLocal (`$$meterCostUSD)</span>
                                    <span class="meter-count">$meterCount records</span>
                                </div>
                            </div>
"@
                        }
                    }
                }
                
                $subCatHtml += @"
                        <div class="subcategory-drilldown">
                            <div class="subcategory-header" onclick="toggleSubCategory(this)">
                                <span class="expand-arrow">&#9654;</span>
                                <span class="subcategory-name">$subCatName</span>
                                <span class="subcategory-cost">$currency $subCatCostLocal (`$$subCatCostUSD)</span>
                            </div>
                            <div class="subcategory-content">
$meterCardsHtml
                            </div>
                        </div>
"@
            }
        }
        
        $categorySectionsHtml += @"
                    <div class="category-card">
                        <div class="category-header" onclick="toggleCategory(this)">
                            <span class="expand-arrow">&#9654;</span>
                            <span class="category-title">$catName</span>
                            <span class="category-cost">$currency $catCostLocal (`$$catCostUSD)</span>
                        </div>
                        <div class="category-content">
$subCatHtml
                        </div>
                    </div>
"@
    }
    
    # Build trend indicator
    $trendIndicator = switch ($trendDirection) {
        "up" { "<span class='trend up'>&#8593; $trendPercent% Increasing</span>" }
        "down" { "<span class='trend down'>&#8595; $([math]::Abs($trendPercent))% Decreasing</span>" }
        default { "<span class='trend neutral'>&#8594; Stable</span>" }
    }
    
    # Start building HTML
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure Cost Tracking Report</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
$(Get-ReportStylesheet)
        /* Cost Tracking specific styles */
        .summary-cards {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        
        .summary-card {
            background: var(--bg-surface);
            border-radius: var(--radius-md);
            padding: 24px;
            border: 1px solid var(--border-color);
            text-align: center;
            transition: transform 0.2s, box-shadow 0.2s;
        }
        
        .summary-card:hover {
            transform: translateY(-3px);
            box-shadow: var(--shadow-md);
        }
        
        .summary-card .value {
            font-size: 1.8rem;
            font-weight: 700;
            color: var(--accent-blue);
            margin-bottom: 8px;
        }
        
        .summary-card .label {
            color: var(--text-secondary);
            font-size: 0.85rem;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        
        .summary-card .trend {
            font-size: 0.85rem;
            margin-top: 10px;
            padding: 4px 8px;
            border-radius: 4px;
        }
        
        .trend.up {
            background: rgba(255, 107, 107, 0.15);
            color: var(--accent-red);
        }
        
        .trend.down {
            background: rgba(0, 210, 106, 0.15);
            color: var(--accent-green);
        }
        
        .trend.neutral {
            background: rgba(136, 136, 136, 0.15);
            color: var(--text-muted);
        }
        
        /* Global filter bar */
        .global-filter-bar {
            background: var(--bg-surface);
            border-radius: var(--radius-md);
            padding: 16px 20px;
            margin-bottom: 30px;
            border: 1px solid var(--border-color);
        }
        
        .global-filter-bar h3 {
            margin: 0 0 12px 0;
            font-size: 0.9rem;
            color: var(--text-secondary);
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        
        .subscription-filter-container {
            display: flex;
            flex-wrap: wrap;
            gap: 12px;
            align-items: center;
        }
        
        .subscription-checkbox {
            display: flex;
            align-items: center;
            gap: 6px;
            padding: 6px 12px;
            background: var(--bg-secondary);
            border-radius: 6px;
            cursor: pointer;
            transition: background 0.2s;
            font-size: 0.9rem;
        }
        
        .subscription-checkbox:hover {
            background: var(--bg-hover);
        }
        
        .subscription-checkbox input {
            cursor: pointer;
            accent-color: var(--accent-blue);
        }
        
        .filter-actions {
            display: flex;
            gap: 10px;
            margin-left: auto;
        }
        
        .filter-btn {
            padding: 6px 12px;
            background: var(--bg-secondary);
            border: 1px solid var(--border-color);
            border-radius: 6px;
            color: var(--text-secondary);
            cursor: pointer;
            font-size: 0.85rem;
            transition: all 0.2s;
        }
        
        .filter-btn:hover {
            background: var(--bg-hover);
            color: var(--text-primary);
        }
        
        .chart-section {
            background: var(--bg-surface);
            border-radius: var(--radius-md);
            padding: 24px;
            margin-bottom: 30px;
            border: 1px solid var(--border-color);
        }
        
        .chart-section h2 {
            margin-top: 0;
            margin-bottom: 20px;
            color: var(--text-primary);
        }
        
        .chart-controls {
            display: flex;
            gap: 15px;
            margin-bottom: 20px;
            flex-wrap: wrap;
        }
        
        .chart-controls select {
            background: var(--bg-secondary);
            border: 1px solid var(--border-color);
            color: var(--text-primary);
            padding: 8px 12px;
            border-radius: 6px;
            font-size: 0.9rem;
        }
        
        .chart-container {
            position: relative;
            height: 400px;
            width: 100%;
        }
        
        .section {
            background: var(--bg-surface);
            border-radius: var(--radius-md);
            padding: 24px;
            margin-bottom: 30px;
            border: 1px solid var(--border-color);
        }
        
        .section h2 {
            margin-top: 0;
            margin-bottom: 20px;
            color: var(--text-primary);
            cursor: pointer;
            display: flex;
            align-items: center;
            gap: 10px;
        }
        
        .section h2 .expand-arrow {
            font-size: 0.8rem;
            transition: transform 0.2s;
            color: var(--accent-blue);
        }
        
        .section h2.expanded .expand-arrow {
            transform: rotate(90deg);
        }
        
        .section-content {
            display: none;
        }
        
        .section h2.expanded + .section-content {
            display: block;
        }
        
        .cost-table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 15px;
        }
        
        .cost-table thead {
            background: var(--bg-secondary);
        }
        
        .cost-table th {
            padding: 12px 16px;
            text-align: left;
            font-weight: 600;
            color: var(--text-primary);
            border-bottom: 2px solid var(--border-color);
            font-size: 0.85rem;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        
        .cost-table td {
            padding: 12px 16px;
            border-bottom: 1px solid var(--border-color);
            color: var(--text-secondary);
        }
        
        .cost-table tbody tr:hover {
            background: var(--bg-hover);
        }
        
        .cost-table tbody tr.filtered-out,
        .meter-card.filtered-out,
        .subcategory-drilldown.filtered-out,
        .category-card.filtered-out {
            display: none;
        }
        
        .cost-value {
            font-weight: 600;
            color: var(--text-primary);
            font-family: 'Consolas', 'Monaco', monospace;
        }
        
        .category-card {
            background: var(--bg-secondary);
            border-radius: var(--radius-sm);
            margin-bottom: 15px;
            overflow: hidden;
        }
        
        .category-header {
            padding: 16px 20px;
            display: flex;
            align-items: center;
            gap: 10px;
            cursor: pointer;
            transition: background 0.2s;
        }
        
        .category-header:hover {
            background: var(--bg-hover);
        }
        
        .category-header .expand-arrow {
            font-size: 0.8rem;
            transition: transform 0.2s;
            color: var(--accent-blue);
        }
        
        .category-card.expanded .category-header .expand-arrow {
            transform: rotate(90deg);
        }
        
        .category-title {
            font-weight: 600;
            color: var(--text-primary);
            flex: 1;
        }
        
        .category-cost {
            color: var(--accent-blue);
            font-weight: 600;
            font-family: 'Consolas', 'Monaco', monospace;
        }
        
        .category-content {
            display: none;
            padding: 0 20px 20px;
        }
        
        .category-card.expanded .category-content {
            display: block;
        }
        
        /* SubCategory level */
        .subcategory-drilldown {
            margin-top: 10px;
            background: var(--bg-surface);
            border-radius: var(--radius-sm);
            overflow: hidden;
        }
        
        .subcategory-header {
            padding: 12px 16px;
            display: flex;
            align-items: center;
            gap: 10px;
            cursor: pointer;
            transition: background 0.2s;
        }
        
        .subcategory-header:hover {
            background: var(--bg-hover);
        }
        
        .subcategory-header .expand-arrow {
            font-size: 0.7rem;
            transition: transform 0.2s;
            color: var(--accent-blue);
        }
        
        .subcategory-drilldown.expanded .subcategory-header .expand-arrow {
            transform: rotate(90deg);
        }
        
        .subcategory-name {
            font-weight: 500;
            color: var(--text-primary);
            flex: 1;
        }
        
        .subcategory-cost {
            color: var(--accent-blue);
            font-weight: 600;
            font-family: 'Consolas', 'Monaco', monospace;
            font-size: 0.9rem;
        }
        
        .subcategory-content {
            display: none;
            padding: 0 16px 16px;
        }
        
        .subcategory-drilldown.expanded .subcategory-content {
            display: block;
        }
        
        /* Meter level */
        .meter-card {
            margin-top: 8px;
            background: var(--bg-primary);
            border-radius: var(--radius-sm);
            overflow: hidden;
            border: 1px solid var(--border-color);
        }
        
        .meter-card.no-expand .meter-header {
            cursor: default;
        }
        
        .meter-header {
            padding: 10px 14px;
            display: flex;
            align-items: center;
            gap: 10px;
            cursor: pointer;
            transition: background 0.2s;
        }
        
        .meter-header:hover {
            background: var(--bg-hover);
        }
        
        .meter-card.no-expand .meter-header:hover {
            background: transparent;
        }
        
        .meter-header .expand-arrow {
            font-size: 0.6rem;
            transition: transform 0.2s;
            color: var(--text-muted);
        }
        
        .meter-card.expanded .meter-header .expand-arrow {
            transform: rotate(90deg);
        }
        
        .meter-name {
            font-weight: 500;
            color: var(--text-secondary);
            flex: 1;
            font-size: 0.9rem;
        }
        
        .meter-cost {
            color: var(--accent-green);
            font-weight: 600;
            font-family: 'Consolas', 'Monaco', monospace;
            font-size: 0.85rem;
        }
        
        .meter-count {
            color: var(--text-muted);
            font-size: 0.8rem;
        }
        
        .meter-content {
            display: none;
            padding: 0 14px 14px;
        }
        
        .meter-card.expanded .meter-content {
            display: block;
        }
        
        .resource-table {
            margin-top: 10px;
            font-size: 0.85rem;
        }
        
        .resource-table th {
            font-size: 0.75rem;
            padding: 8px 12px;
        }
        
        .resource-table td {
            padding: 8px 12px;
        }
        
        .filter-bar {
            background: var(--bg-surface);
            border-radius: var(--radius-md);
            padding: 16px 20px;
            margin-bottom: 20px;
            border: 1px solid var(--border-color);
            display: flex;
            gap: 20px;
            flex-wrap: wrap;
            align-items: center;
        }
        
        .filter-bar label {
            color: var(--text-secondary);
            font-size: 0.85rem;
        }
        
        .filter-bar input {
            background: var(--bg-secondary);
            border: 1px solid var(--border-color);
            color: var(--text-primary);
            padding: 8px 12px;
            border-radius: 6px;
            font-size: 0.9rem;
            width: 250px;
        }
    </style>
</head>
<body>
    $(Get-ReportNavigation -ActivePage "CostTracking")
    
    <div class="container">
        <div class="page-header">
            <h1>Cost Tracking</h1>
            <p class="subtitle">Cost analysis with meter-level granularity - Period: $($periodStart.ToString('yyyy-MM-dd')) to $($periodEnd.ToString('yyyy-MM-dd'))</p>
        </div>
        
        <div class="global-filter-bar">
            <h3>Filter by Subscription</h3>
            <div class="subscription-filter-container">
$subscriptionOptionsHtml
                <div class="filter-actions">
                    <button class="filter-btn" onclick="selectAllSubscriptions()">Select All</button>
                    <button class="filter-btn" onclick="deselectAllSubscriptions()">Deselect All</button>
                </div>
            </div>
        </div>
        
        <div class="summary-cards">
            <div class="summary-card">
                <div class="value">$totalCostLocal</div>
                <div class="label">Total Cost ($currency)</div>
            </div>
            <div class="summary-card">
                <div class="value">$totalCostUSD</div>
                <div class="label">Total Cost (USD)</div>
            </div>
            <div class="summary-card">
                <div class="value">$subscriptionCount</div>
                <div class="label">Subscriptions</div>
            </div>
            <div class="summary-card">
                <div class="value">$($byMeterCategory.Count)</div>
                <div class="label">Meter Categories</div>
            </div>
            <div class="summary-card">
                <div class="value">$([math]::Abs($trendPercent))%</div>
                <div class="label">Cost Trend</div>
                $trendIndicator
            </div>
        </div>
        
        <div class="chart-section">
            <h2>Daily Cost Breakdown</h2>
            <div class="chart-controls">
                <select id="chartView" onchange="updateChartView()">
                    <option value="stacked-category">Stacked by Category</option>
                    <option value="stacked-subscription">Stacked by Subscription</option>
                    <option value="stacked-meter">Stacked by Meter (Top 15)</option>
                    <option value="stacked-resource">Stacked by Resource (Top 15)</option>
                    <option value="total">Total Cost</option>
                </select>
                <select id="categoryFilter" onchange="filterChartCategory()">
                    <option value="all">All Categories</option>
                </select>
            </div>
            <div class="chart-container">
                <canvas id="costChart"></canvas>
            </div>
        </div>
        
        <div class="section">
            <h2 onclick="toggleSection(this)"><span class="expand-arrow">&#9654;</span> Cost by Subscription</h2>
            <div class="section-content">
                <table class="cost-table" id="subscriptionTable">
                    <thead>
                        <tr>
                            <th>Subscription</th>
                            <th>Cost ($currency)</th>
                            <th>Cost (USD)</th>
                            <th>Records</th>
                        </tr>
                    </thead>
                    <tbody>
$subscriptionRowsHtml
                    </tbody>
                </table>
            </div>
        </div>
        
        <div class="section">
            <h2 onclick="toggleSection(this)"><span class="expand-arrow">&#9654;</span> Cost by Meter Category</h2>
            <div class="section-content">
$categorySectionsHtml
            </div>
        </div>
        
        <div class="section">
            <h2 onclick="toggleSection(this)"><span class="expand-arrow">&#9654;</span> Top $($topResources.Count) Resources by Cost</h2>
            <div class="section-content">
                <div class="filter-bar">
                    <label>Search:</label>
                    <input type="text" id="resourceSearch" placeholder="Filter resources..." oninput="filterResources()">
                </div>
                <table class="cost-table" id="resourcesTable">
                    <thead>
                        <tr>
                            <th>Resource Name</th>
                            <th>Resource Group</th>
                            <th>Subscription</th>
                            <th>Type</th>
                            <th>Category</th>
                            <th>Cost ($currency)</th>
                            <th>Cost (USD)</th>
                        </tr>
                    </thead>
                    <tbody>
$topResourcesRowsHtml
                    </tbody>
                </table>
            </div>
        </div>
    </div>
    
    <script>
        // Chart data
        const chartLabels = [$chartLabelsJson];
        const datasetsByCategory = [
$datasetsByCategoryJsonString
        ];
        const datasetsBySubscription = [
$datasetsBySubscriptionJsonString
        ];
        const datasetsByMeter = [
$datasetsByMeterJsonString
        ];
        const datasetsByResource = [
$datasetsByResourceJsonString
        ];
        
        // Raw daily data for cross-filtering
        const rawDailyData = $rawDailyDataJson;
        
        // Color palette
        const chartColors = [
            'rgba(84, 160, 255, 0.8)',
            'rgba(0, 210, 106, 0.8)',
            'rgba(255, 107, 107, 0.8)',
            'rgba(254, 202, 87, 0.8)',
            'rgba(155, 89, 182, 0.8)',
            'rgba(255, 159, 67, 0.8)',
            'rgba(52, 152, 219, 0.8)',
            'rgba(46, 204, 113, 0.8)',
            'rgba(231, 76, 60, 0.8)',
            'rgba(241, 196, 15, 0.8)',
            'rgba(142, 68, 173, 0.8)',
            'rgba(230, 126, 34, 0.8)',
            'rgba(26, 188, 156, 0.8)',
            'rgba(192, 57, 43, 0.8)',
            'rgba(39, 174, 96, 0.8)',
            'rgba(41, 128, 185, 0.8)'
        ];
        
        let costChart = null;
        let currentView = 'stacked-category';
        let currentCategoryFilter = 'all';
        let selectedSubscriptions = new Set();
        
        // Initialize
        document.addEventListener('DOMContentLoaded', function() {
            // Initialize selected subscriptions from checkboxes
            document.querySelectorAll('.subscription-checkbox input').forEach(cb => {
                if (cb.checked) {
                    selectedSubscriptions.add(cb.value);
                }
            });
            
            initChart();
            populateCategoryFilter();
        });
        
        function initChart() {
            const ctx = document.getElementById('costChart').getContext('2d');
            
            // Sort initial datasets by total cost (largest at bottom for stacked chart)
            const sortedDatasetsByCategory = [...datasetsByCategory].sort((a, b) => {
                const aTotal = a.data.reduce((sum, val) => sum + val, 0);
                const bTotal = b.data.reduce((sum, val) => sum + val, 0);
                return bTotal - aTotal;
            });
            
            costChart = new Chart(ctx, {
                type: 'bar',
                data: {
                    labels: chartLabels,
                    datasets: sortedDatasetsByCategory
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    plugins: {
                        legend: {
                            position: 'bottom',
                            labels: {
                                color: '#e8e8e8',
                                padding: 15,
                                usePointStyle: true
                            }
                        },
                        tooltip: {
                            mode: 'index',
                            intersect: false,
                            backgroundColor: 'rgba(37, 37, 66, 0.95)',
                            titleColor: '#e8e8e8',
                            bodyColor: '#b8b8b8',
                            borderColor: '#3d3d5c',
                            borderWidth: 1,
                            callbacks: {
                                label: function(context) {
                                    return context.dataset.label + ': $currency ' + context.parsed.y.toFixed(2);
                                }
                            }
                        }
                    },
                    scales: {
                        x: {
                            stacked: true,
                            grid: {
                                color: 'rgba(61, 61, 92, 0.5)'
                            },
                            ticks: {
                                color: '#888',
                                maxRotation: 45,
                                minRotation: 45
                            }
                        },
                        y: {
                            stacked: true,
                            grid: {
                                color: 'rgba(61, 61, 92, 0.5)'
                            },
                            ticks: {
                                color: '#888',
                                callback: function(value) {
                                    return '$currency ' + value.toFixed(0);
                                }
                            }
                        }
                    }
                }
            });
        }
        
        function populateCategoryFilter() {
            const select = document.getElementById('categoryFilter');
            datasetsByCategory.forEach(ds => {
                const option = document.createElement('option');
                option.value = ds.label;
                option.textContent = ds.label;
                select.appendChild(option);
            });
        }
        
        function updateChart() {
            const view = currentView;
            const categoryFilter = currentCategoryFilter;
            const stacked = view !== 'total';
            
            costChart.options.scales.x.stacked = stacked;
            costChart.options.scales.y.stacked = stacked;
            
            let datasets;
            
            if (view === 'total') {
                // Show only total (filtered by category and subscription)
                const totalData = rawDailyData.map(day => {
                    let dayTotal = 0;
                    if (categoryFilter === 'all') {
                        // Sum all categories for selected subscriptions
                        Object.entries(day.categories || {}).forEach(([cat, catData]) => {
                            if (selectedSubscriptions.size === 0) {
                                dayTotal += catData.total || 0;
                            } else {
                                selectedSubscriptions.forEach(sub => {
                                    dayTotal += (catData.bySubscription && catData.bySubscription[sub]) || 0;
                                });
                            }
                        });
                    } else {
                        // Single category
                        const catData = day.categories && day.categories[categoryFilter];
                        if (catData) {
                            if (selectedSubscriptions.size === 0) {
                                dayTotal = catData.total || 0;
                            } else {
                                selectedSubscriptions.forEach(sub => {
                                    dayTotal += (catData.bySubscription && catData.bySubscription[sub]) || 0;
                                });
                            }
                        }
                    }
                    return dayTotal;
                });
                datasets = [{
                    label: categoryFilter === 'all' ? 'Total Cost' : categoryFilter,
                    data: totalData,
                    backgroundColor: 'rgba(84, 160, 255, 0.8)',
                    borderColor: 'rgba(84, 160, 255, 1)',
                    borderWidth: 1
                }];
            } else if (view === 'stacked-category') {
                datasets = buildFilteredDatasets('categories', categoryFilter, false);
            } else if (view === 'stacked-subscription') {
                datasets = buildFilteredDatasets('subscriptions', categoryFilter, false);
            } else if (view === 'stacked-meter') {
                datasets = buildFilteredDatasets('meters', categoryFilter, true);
            } else if (view === 'stacked-resource') {
                datasets = buildFilteredDatasets('resources', categoryFilter, true);
            } else {
                datasets = buildFilteredDatasets('categories', categoryFilter, false);
            }
            
            costChart.data.datasets = datasets;
            costChart.update();
        }
        
        function buildFilteredDatasets(dimension, categoryFilter, includeOther) {
            // Get all unique keys for this dimension (excluding "Other" which we handle separately)
            const allKeys = new Set();
            rawDailyData.forEach(day => {
                Object.keys(day[dimension] || {}).forEach(key => {
                    if (key !== 'Other') allKeys.add(key);
                });
            });
            
            const datasets = [];
            let colorIndex = 0;
            let otherData = null;
            
            if (includeOther) {
                otherData = rawDailyData.map(() => 0);
            }
            
            allKeys.forEach(key => {
                // Skip if subscription filter active and this is subscriptions dimension
                if (dimension === 'subscriptions' && selectedSubscriptions.size > 0 && !selectedSubscriptions.has(key)) {
                    return;
                }
                
                const data = rawDailyData.map((day, dayIndex) => {
                    const dimData = day[dimension] && day[dimension][key];
                    if (!dimData) return 0;
                    
                    let value = 0;
                    
                    // Apply subscription filter
                    if (selectedSubscriptions.size === 0 || dimension === 'subscriptions') {
                        // No subscription filter or we're viewing by subscription
                        if (categoryFilter === 'all') {
                            value = dimData.total || 0;
                        } else {
                            value = (dimData.byCategory && dimData.byCategory[categoryFilter]) || 0;
                        }
                    } else {
                        // Subscription filter active - sum only selected subscriptions
                        if (categoryFilter === 'all') {
                            selectedSubscriptions.forEach(sub => {
                                value += (dimData.bySubscription && dimData.bySubscription[sub]) || 0;
                            });
                        } else {
                            // Both category and subscription filter - this is complex
                            // For simplicity, just filter by subscription total within category
                            selectedSubscriptions.forEach(sub => {
                                value += (dimData.bySubscription && dimData.bySubscription[sub]) || 0;
                            });
                        }
                    }
                    
                    return value;
                });
                
                // Only include if there's non-zero data
                if (data.some(v => v > 0)) {
                    // Calculate total cost for sorting
                    const totalCost = data.reduce((sum, val) => sum + val, 0);
                    datasets.push({
                        label: key,
                        data: data,
                        totalCost: totalCost, // Store for sorting
                        backgroundColor: chartColors[colorIndex % chartColors.length],
                        borderColor: chartColors[colorIndex % chartColors.length],
                        borderWidth: 1
                    });
                    colorIndex++;
                }
            });
            
            // Sort datasets by total cost descending (largest at bottom for stacked chart)
            datasets.sort((a, b) => b.totalCost - a.totalCost);
            
            // Add "Other" for meters and resources (at the top, before sorted items)
            if (includeOther) {
                const otherDataCalc = rawDailyData.map((day, dayIndex) => {
                    // Calculate total and subtract known items
                    let dayTotal = 0;
                    
                    // Get total for the day (filtered by subscription if needed)
                    if (selectedSubscriptions.size === 0) {
                        dayTotal = day.totalCostLocal || 0;
                    } else {
                        // Sum selected subscriptions
                        Object.entries(day.subscriptions || {}).forEach(([sub, subData]) => {
                            if (selectedSubscriptions.has(sub)) {
                                if (categoryFilter === 'all') {
                                    dayTotal += subData.total || 0;
                                } else {
                                    dayTotal += (subData.byCategory && subData.byCategory[categoryFilter]) || 0;
                                }
                            }
                        });
                    }
                    
                    // Subtract known items
                    let knownTotal = 0;
                    datasets.forEach(ds => {
                        knownTotal += ds.data[dayIndex] || 0;
                    });
                    
                    return Math.max(0, dayTotal - knownTotal);
                });
                
                const otherTotal = otherDataCalc.reduce((sum, val) => sum + val, 0);
                if (otherTotal > 0.01) {
                    // Insert "Other" at the beginning (top of stack)
                    datasets.unshift({
                        label: 'Other',
                        data: otherDataCalc,
                        totalCost: otherTotal,
                        backgroundColor: 'rgba(128, 128, 128, 0.6)',
                        borderColor: 'rgba(128, 128, 128, 0.8)',
                        borderWidth: 1
                    });
                }
            }
            
            return datasets;
        }
        
        function updateChartView() {
            currentView = document.getElementById('chartView').value;
            updateChart();
        }
        
        function filterChartCategory() {
            currentCategoryFilter = document.getElementById('categoryFilter').value;
            updateChart();
        }
        
        function filterBySubscription() {
            // Update selected subscriptions set
            selectedSubscriptions.clear();
            document.querySelectorAll('.subscription-checkbox input:checked').forEach(cb => {
                selectedSubscriptions.add(cb.value);
            });
            
            // Filter tables
            filterTableBySubscription('subscriptionTable');
            filterTableBySubscription('resourcesTable');
            
            // Filter category sections
            filterCategorySections();
            
            // Update chart with new subscription filter
            updateChart();
        }
        
        function filterTableBySubscription(tableId) {
            const rows = document.querySelectorAll('#' + tableId + ' tbody tr');
            rows.forEach(row => {
                const subscription = row.getAttribute('data-subscription');
                if (subscription && selectedSubscriptions.size > 0) {
                    row.classList.toggle('filtered-out', !selectedSubscriptions.has(subscription));
                } else {
                    row.classList.remove('filtered-out');
                }
            });
        }
        
        function filterCategorySections() {
            // Filter resource rows within meter sections by subscription
            document.querySelectorAll('.resource-table tbody tr').forEach(row => {
                const subscription = row.getAttribute('data-subscription');
                if (subscription && selectedSubscriptions.size > 0) {
                    row.classList.toggle('filtered-out', !selectedSubscriptions.has(subscription));
                } else {
                    row.classList.remove('filtered-out');
                }
            });
            
            // Update visibility of meter cards based on whether they have visible resources
            document.querySelectorAll('.meter-card').forEach(card => {
                const visibleRows = card.querySelectorAll('.resource-table tbody tr:not(.filtered-out)');
                const totalRows = card.querySelectorAll('.resource-table tbody tr');
                if (totalRows.length > 0 && selectedSubscriptions.size > 0) {
                    card.classList.toggle('filtered-out', visibleRows.length === 0);
                } else {
                    card.classList.remove('filtered-out');
                }
            });
            
            // Update visibility of subcategory drilldowns based on visible meters
            document.querySelectorAll('.subcategory-drilldown').forEach(subcat => {
                const visibleMeters = subcat.querySelectorAll('.meter-card:not(.filtered-out)');
                const totalMeters = subcat.querySelectorAll('.meter-card');
                if (totalMeters.length > 0 && selectedSubscriptions.size > 0) {
                    subcat.classList.toggle('filtered-out', visibleMeters.length === 0);
                } else {
                    subcat.classList.remove('filtered-out');
                }
            });
            
            // Update visibility of category cards based on visible subcategories
            document.querySelectorAll('.category-card').forEach(cat => {
                const visibleSubcats = cat.querySelectorAll('.subcategory-drilldown:not(.filtered-out)');
                const totalSubcats = cat.querySelectorAll('.subcategory-drilldown');
                if (totalSubcats.length > 0 && selectedSubscriptions.size > 0) {
                    cat.classList.toggle('filtered-out', visibleSubcats.length === 0);
                } else {
                    cat.classList.remove('filtered-out');
                }
            });
        }
        
        function selectAllSubscriptions() {
            document.querySelectorAll('.subscription-checkbox input').forEach(cb => {
                cb.checked = true;
            });
            filterBySubscription();
        }
        
        function deselectAllSubscriptions() {
            document.querySelectorAll('.subscription-checkbox input').forEach(cb => {
                cb.checked = false;
            });
            filterBySubscription();
        }
        
        function toggleSection(element) {
            element.classList.toggle('expanded');
        }
        
        function toggleCategory(element) {
            element.parentElement.classList.toggle('expanded');
        }
        
        function toggleSubCategory(element) {
            element.parentElement.classList.toggle('expanded');
        }
        
        function toggleMeter(element) {
            element.parentElement.classList.toggle('expanded');
        }
        
        function filterResources() {
            const searchText = document.getElementById('resourceSearch').value.toLowerCase();
            const rows = document.querySelectorAll('#resourcesTable tbody tr');
            
            rows.forEach(row => {
                const text = row.textContent.toLowerCase();
                const matchesSearch = text.includes(searchText);
                const subscription = row.getAttribute('data-subscription');
                const matchesSubscription = selectedSubscriptions.size === 0 || selectedSubscriptions.has(subscription);
                
                row.style.display = (matchesSearch && matchesSubscription) ? '' : 'none';
            });
        }
    </script>
</body>
</html>
"@
    
    # Write HTML to file
    try {
        $html | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
        Write-Verbose "Cost Tracking report written to: $OutputPath"
        
        return @{
            OutputPath = $OutputPath
            TotalCostLocal = $totalCostLocal
            TotalCostUSD = $totalCostUSD
            Currency = $currency
            SubscriptionCount = $subscriptionCount
            MeterCategoryCount = $byMeterCategory.Count
            ResourceCount = $topResources.Count
        }
    }
    catch {
        Write-Error "Failed to write Cost Tracking report: $_"
        throw
    }
}
