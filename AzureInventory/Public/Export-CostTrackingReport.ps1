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
    $totalCostLocal = [math]::Round($CostTrackingData.TotalCostLocal, 2)
    $totalCostUSD = [math]::Round($CostTrackingData.TotalCostUSD, 2)
    $currency = $CostTrackingData.Currency
    
    # Helper function to format numbers with thousand separator (space)
    function Format-NumberWithSeparator {
        param(
            [double]$Number,
            [int]$Decimals = 2
        )
        $rounded = [math]::Round($Number, $Decimals)
        $formatted = $rounded.ToString("N$Decimals", [System.Globalization.CultureInfo]::InvariantCulture)
        # Replace comma with space for thousand separator
        return $formatted -replace ',', ' '
    }
    
    # Helper function to format numbers without decimals (for cards)
    function Format-NumberNoDecimals {
        param([double]$Number)
        $rounded = [math]::Round($Number, 0)
        $formatted = $rounded.ToString("N0", [System.Globalization.CultureInfo]::InvariantCulture)
        return $formatted -replace ',', ' '
    }
    
    # Helper function to format quantity with unit of measure
    function Format-QuantityWithUnit {
        param(
            [double]$Quantity,
            [string]$UnitOfMeasure
        )
        if ($Quantity -gt 0 -and $UnitOfMeasure -and -not [string]::IsNullOrWhiteSpace($UnitOfMeasure)) {
            $formattedQty = Format-NumberWithSeparator -Number $Quantity -Decimals 2
            return "$formattedQty $UnitOfMeasure"
        }
        return ""
    }
    $subscriptionCount = $CostTrackingData.SubscriptionCount
    $bySubscription = $CostTrackingData.BySubscription
    $byMeterCategory = $CostTrackingData.ByMeterCategory
    # Recalculate top resources from RawData to ensure we get the truly most expensive ones
    $rawData = if ($CostTrackingData.RawData) { $CostTrackingData.RawData } else { @() }
    if ($rawData.Count -gt 0) {
        # Group by ResourceId and calculate totals
        $resourceGroups = $rawData | Where-Object { $_.ResourceId -and -not [string]::IsNullOrWhiteSpace($_.ResourceId) } | Group-Object ResourceId
        $allResources = @()
        foreach ($resGroup in $resourceGroups) {
            $resItems = $resGroup.Group
            $resCostUSD = ($resItems | Measure-Object -Property CostUSD -Sum).Sum
            $resCostLocal = ($resItems | Measure-Object -Property CostLocal -Sum).Sum
            
            $allResources += [PSCustomObject]@{
                ResourceId = $resGroup.Name
                ResourceName = $resItems[0].ResourceName
                ResourceGroup = $resItems[0].ResourceGroup
                ResourceType = $resItems[0].ResourceType
                SubscriptionName = $resItems[0].SubscriptionName
                SubscriptionId = $resItems[0].SubscriptionId
                MeterCategory = ($resItems | Group-Object MeterCategory | Sort-Object Count -Descending | Select-Object -First 1).Name
                CostLocal = $resCostLocal
                CostUSD = $resCostUSD
                ItemCount = $resItems.Count
            }
        }
        # Get all resources (not just top 20) so JavaScript can recalculate top 20 based on filters
        # Sort by CostUSD descending for initial display order
        $topResources = @($allResources | Sort-Object CostUSD -Descending)
    } else {
        # Fallback to pre-calculated if no raw data
        # Use all resources (not just top 20) so JavaScript can recalculate top 20 based on filters
        $topResources = @($CostTrackingData.TopResources | Sort-Object { $_.CostUSD } -Descending)
    }
    
    # Initially hide resources beyond top 20 (JavaScript will show/hide based on filters)
    # We generate HTML for all resources so JavaScript can recalculate top 20 based on subscription filter
    # Handle both hashtable and array formats for DailyTrend
    $dailyTrendRaw = if ($CostTrackingData.DailyTrend) { $CostTrackingData.DailyTrend } else { @() }
    $dailyTrend = @()
    
    if ($dailyTrendRaw) {
        if ($dailyTrendRaw -is [hashtable]) {
            # Convert hashtable to array (Collect-CostData returns hashtable keyed by date string)
            $dailyTrend = @($dailyTrendRaw.Values | Sort-Object { $_.Date })
        } elseif ($dailyTrendRaw -is [System.Array] -or $dailyTrendRaw -is [System.Collections.IList]) {
            # Already an array (test data generator returns array directly)
            $dailyTrend = @($dailyTrendRaw)
        } elseif ($dailyTrendRaw -is [PSCustomObject] -or $dailyTrendRaw -is [PSObject]) {
            # Single object, wrap in array
            $dailyTrend = @($dailyTrendRaw)
        } else {
            # Unknown type, attempt to enumerate
            $dailyTrend = @($dailyTrendRaw)
        }
    }
    
    # Calculate cost increases for resources (compare first half vs second half, similar to trend calculation)
    $resourceIncreaseData = @{}  # Store increase data keyed by resource name
    if ($dailyTrend.Count -ge 4) {
        $totalDays = $dailyTrend.Count
        $daysPerHalf = [math]::Floor($totalDays / 2)
        $firstHalfDays = $dailyTrend[0..($daysPerHalf - 1)]
        $secondHalfDays = $dailyTrend[($totalDays - $daysPerHalf)..($totalDays - 1)]
        
        # Get all unique resource names from daily trend
        $allResourceNamesInTrend = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($day in $dailyTrend) {
            if ($day.ByResource) {
                foreach ($resKey in $day.ByResource.Keys) {
                    if ($resKey -and $resKey -ne 'Other') {
                        [void]$allResourceNamesInTrend.Add($resKey)
                    }
                }
            }
        }
        
        # Calculate costs per resource for each half
        foreach ($resName in $allResourceNamesInTrend) {
            $firstHalfCost = 0
            $secondHalfCost = 0
            
            # Sum costs for first half
            foreach ($day in $firstHalfDays) {
                if ($day.ByResource -and $day.ByResource.ContainsKey($resName)) {
                    $resData = $day.ByResource[$resName]
                    $cost = if ($resData.CostLocal) { $resData.CostLocal } else { 0 }
                    $firstHalfCost += $cost
                }
            }
            
            # Sum costs for second half
            foreach ($day in $secondHalfDays) {
                if ($day.ByResource -and $day.ByResource.ContainsKey($resName)) {
                    $resData = $day.ByResource[$resName]
                    $cost = if ($resData.CostLocal) { $resData.CostLocal } else { 0 }
                    $secondHalfCost += $cost
                }
            }
            
            # Calculate percentage increase (only if first half > 0)
            $increasePercent = 0
            $increaseAmount = $secondHalfCost - $firstHalfCost
            if ($firstHalfCost -gt 0) {
                $increasePercent = (($secondHalfCost - $firstHalfCost) / $firstHalfCost) * 100
            } elseif ($secondHalfCost -gt 0) {
                # If first half was 0 but second half has cost, it's a new resource (100%+ increase)
                $increasePercent = 1000  # Use large number to prioritize new resources
            }
            
            # Only store if there's an increase
            if ($increaseAmount -gt 0) {
                $resourceIncreaseData[$resName] = @{
                    ResourceName = $resName
                    FirstHalfCost = $firstHalfCost
                    SecondHalfCost = $secondHalfCost
                    IncreaseAmount = $increaseAmount
                    IncreasePercent = $increasePercent
                }
            }
        }
    }
    
    # Now match with actual resource objects from topResources (or rawData) and sort by increase amount
    $increasedResourcesWithObjects = @()
    foreach ($resName in $resourceIncreaseData.Keys) {
        # Find the resource object - check topResources first, then rawData
        $resObj = $topResources | Where-Object { $_.ResourceName -eq $resName } | Select-Object -First 1
        if (-not $resObj -and $rawData.Count -gt 0) {
            # Try to find in rawData - match by ResourceName (case-insensitive)
            $resItem = $rawData | Where-Object { $_.ResourceName -and $_.ResourceName -eq $resName } | Select-Object -First 1
            if ($resItem) {
                # Aggregate costs for all entries with this resource name
                $matchingItems = $rawData | Where-Object { $_.ResourceName -eq $resName }
                $resObj = [PSCustomObject]@{
                    ResourceId = $resItem.ResourceId
                    ResourceName = $resItem.ResourceName
                    ResourceGroup = $resItem.ResourceGroup
                    ResourceType = $resItem.ResourceType
                    SubscriptionName = $resItem.SubscriptionName
                    SubscriptionId = $resItem.SubscriptionId
                    CostLocal = ($matchingItems | Measure-Object -Property CostLocal -Sum).Sum
                    CostUSD = ($matchingItems | Measure-Object -Property CostUSD -Sum).Sum
                }
            }
        }
        
        # If still no match, create a basic resource object from daily trend data
        if (-not $resObj) {
            # Try to get resource info from any day's ByResource entry
            $trendResourceInfo = $null
            foreach ($day in $dailyTrend) {
                if ($day.ByResource -and $day.ByResource.ContainsKey($resName)) {
                    $dayResData = $day.ByResource[$resName]
                    # Try to get subscription name from BySubscription
                    $subName = $null
                    if ($dayResData.BySubscription) {
                        $subKeys = $dayResData.BySubscription.Keys
                        if ($subKeys.Count -gt 0) {
                            $subName = $subKeys[0]
                        }
                    }
                    # Try to get category (and infer resource type)
                    $category = $null
                    if ($dayResData.ByCategory) {
                        $catKeys = $dayResData.ByCategory.Keys
                        if ($catKeys.Count -gt 0) {
                            $category = $catKeys[0]
                        }
                    }
                    
                    $trendResourceInfo = @{
                        SubscriptionName = $subName
                        Category = $category
                    }
                    break
                }
            }
            
            # Create minimal resource object
            $resObj = [PSCustomObject]@{
                ResourceId = ""  # Unknown
                ResourceName = $resName
                ResourceGroup = ""  # Unknown
                ResourceType = ""  # Unknown
                SubscriptionName = if ($trendResourceInfo) { $trendResourceInfo.SubscriptionName } else { "" }
                SubscriptionId = ""  # Unknown
                CostLocal = $resourceIncreaseData[$resName].SecondHalfCost  # Use second half cost as estimate
                CostUSD = $resourceIncreaseData[$resName].SecondHalfCost
            }
        }
        
        if ($resObj) {
            $increasedResourcesWithObjects += [PSCustomObject]@{
                Resource = $resObj
                IncreaseData = $resourceIncreaseData[$resName]
            }
        }
    }
    
    # Sort by increase amount (descending) and get top 20
    $topIncreasedResources = @($increasedResourcesWithObjects |
        Sort-Object { $_.IncreaseData.IncreaseAmount } -Descending |
        Select-Object -First 20 |
        ForEach-Object { $_.Resource })

    # Calculate trend (compare first half vs second half of period)
    # Remove highest and lowest day from each half to reduce outlier impact
    $trendPercent = 0
    $trendDirection = "neutral"
    if ($dailyTrend.Count -ge 4) {  # Need at least 4 days (2 per half after removing outliers)
        $totalDays = $dailyTrend.Count
        $daysPerHalf = [math]::Floor($totalDays / 2)
        
        # If odd number of days, exclude the middle day(s) to ensure equal comparison
        # First half: first N days
        # Second half: last N days
        $firstHalfDays = $dailyTrend[0..($daysPerHalf - 1)]
        $secondHalfDays = $dailyTrend[($totalDays - $daysPerHalf)..($totalDays - 1)]
        
        # Remove highest and lowest day from first half
        if ($firstHalfDays.Count -ge 3) {
            $firstHalfSorted = $firstHalfDays | Sort-Object { $_.TotalCostLocal }
            $firstHalfFiltered = $firstHalfSorted[1..($firstHalfSorted.Count - 2)]  # Remove first (lowest) and last (highest)
            $firstHalf = ($firstHalfFiltered | ForEach-Object { $_.TotalCostLocal } | Measure-Object -Sum).Sum
        } else {
            $firstHalf = ($firstHalfDays | ForEach-Object { $_.TotalCostLocal } | Measure-Object -Sum).Sum
        }
        
        # Remove highest and lowest day from second half
        if ($secondHalfDays.Count -ge 3) {
            $secondHalfSorted = $secondHalfDays | Sort-Object { $_.TotalCostLocal }
            $secondHalfFiltered = $secondHalfSorted[1..($secondHalfSorted.Count - 2)]  # Remove first (lowest) and last (highest)
            $secondHalf = ($secondHalfFiltered | ForEach-Object { $_.TotalCostLocal } | Measure-Object -Sum).Sum
        } else {
            $secondHalf = ($secondHalfDays | ForEach-Object { $_.TotalCostLocal } | Measure-Object -Sum).Sum
        }
        
        if ($firstHalf -gt 0) {
            # Calculate percentage change: ((new - old) / old) * 100
            $trendPercent = [math]::Round((($secondHalf - $firstHalf) / $firstHalf) * 100, 1)
            $trendDirection = if ($trendPercent -gt 0) { "up" } elseif ($trendPercent -lt 0) { "down" } else { "neutral" }
        }
    }
    
    # Prepare subscription data as array (sorted by cost descending)
    # Convert hashtable values to PSCustomObjects for reliable property access
    # Use hashtable keys as fallback for Name if not present in value
    $subscriptionsArray = @($bySubscription.GetEnumerator() | ForEach-Object {
        $key = $_.Key
        $ht = $_.Value
        [PSCustomObject]@{
            Name = if ($ht -is [hashtable] -and $ht.ContainsKey('Name') -and $ht['Name']) { 
                $ht['Name'] 
            } elseif ($ht -is [PSCustomObject] -and $ht.Name) {
                $ht.Name
            } else { 
                $key  # Use hashtable key as fallback
            }
            SubscriptionId = if ($ht -is [hashtable] -and $ht.ContainsKey('SubscriptionId') -and $ht['SubscriptionId']) { 
                $ht['SubscriptionId'] 
            } elseif ($ht -is [PSCustomObject] -and $ht.SubscriptionId) {
                $ht.SubscriptionId
            } else { 
                "" 
            }
            CostLocal = if ($ht -is [hashtable] -and $ht.ContainsKey('CostLocal')) { 
                $ht['CostLocal'] 
            } elseif ($ht -is [PSCustomObject] -and $ht.CostLocal) {
                $ht.CostLocal
            } else { 
                0 
            }
            CostUSD = if ($ht -is [hashtable] -and $ht.ContainsKey('CostUSD')) { 
                $ht['CostUSD'] 
            } elseif ($ht -is [PSCustomObject] -and $ht.CostUSD) {
                $ht.CostUSD
            } else { 
                0 
            }
            Currency = if ($ht -is [hashtable] -and $ht.ContainsKey('Currency') -and $ht['Currency']) { 
                $ht['Currency'] 
            } elseif ($ht -is [PSCustomObject] -and $ht.Currency) {
                $ht.Currency
            } else { 
                "USD" 
            }
            ItemCount = if ($ht -is [hashtable] -and $ht.ContainsKey('ItemCount')) { 
                $ht['ItemCount'] 
            } elseif ($ht -is [hashtable] -and $ht.ContainsKey('MeterCount')) { 
                $ht['MeterCount'] 
            } elseif ($ht -is [PSCustomObject] -and $ht.ItemCount) {
                $ht.ItemCount
            } elseif ($ht -is [PSCustomObject] -and $ht.MeterCount) {
                $ht.MeterCount
            } else { 
                0 
            }
        }
    } | Sort-Object { $_.CostUSD } -Descending)
    
    # Prepare categories data as array (sorted by cost descending)
    $categoriesArray = @($byMeterCategory.Values | Sort-Object { $_.CostUSD } -Descending)
    
    # Get unique meter categories, subscriptions, meters, and resources for chart
    $allCategories = @($byMeterCategory.Keys | Sort-Object)
    $allSubscriptionNames = @($bySubscription.Values | ForEach-Object { $_.Name } | Sort-Object)
    
    # Get unique meters across all days (ALL meters, not just top 15, so category filtering can work correctly)
    $meterTotals = @{}
    $allMetersSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($day in $dailyTrend) {
        if ($day.ByMeter) {
            foreach ($meterEntry in $day.ByMeter.GetEnumerator()) {
                if (-not $meterTotals.ContainsKey($meterEntry.Key)) {
                    $meterTotals[$meterEntry.Key] = 0
                }
                $meterTotals[$meterEntry.Key] += $meterEntry.Value.CostLocal
                [void]$allMetersSet.Add($meterEntry.Key)
            }
        }
    }
    # Get all unique meters for raw data (needed for category filtering)
    $allMeters = @($allMetersSet | Sort-Object)
    # Top 15 for initial chart display (when no category filter)
    $top15Meters = @($meterTotals.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15 | ForEach-Object { $_.Key })
    
    # Get unique resources - use all unique names from raw data (for category filtering support)
    # Calculate totals from daily trend for top 15 selection
    $resourceTotals = @{}
    if ($CostTrackingData.AllUniqueResourceNames) {
        # Use pre-collected unique resource names from raw data (more complete)
        $allResourceNames = $CostTrackingData.AllUniqueResourceNames
    } else {
        # Fallback: collect from daily trend (may miss some resources)
        $allResourcesSet = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($day in $dailyTrend) {
            if ($day.ByResource) {
                foreach ($resEntry in $day.ByResource.GetEnumerator()) {
                    [void]$allResourcesSet.Add($resEntry.Key)
                    if (-not $resourceTotals.ContainsKey($resEntry.Key)) {
                        $resourceTotals[$resEntry.Key] = 0
                    }
                    $resourceTotals[$resEntry.Key] += $resEntry.Value.CostLocal
                }
            }
        }
        $allResourceNames = @($allResourcesSet | Sort-Object)
    }
    
    # Calculate totals for top 15 selection (from daily trend)
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
    # Top 15 for initial chart display (when no category filter)
    $top15Resources = @($resourceTotals.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15 | ForEach-Object { $_.Key })
    
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
    
    # Sort daily trend by Date, handling null dates gracefully
    # Handle both array and single object cases, and ensure we have valid data
    $sortedDailyTrend = @()
    if ($dailyTrend) {
        if ($dailyTrend -is [System.Array]) {
            if ($dailyTrend.Count -gt 0) {
                $sortedDailyTrend = $dailyTrend | Where-Object { 
                    $null -ne $_ -and ($null -ne $_.Date -or $_.DateString)
                } | Sort-Object { 
                    if ($_.Date) { $_.Date } elseif ($_.DateString) { [DateTime]::Parse($_.DateString) } else { [DateTime]::MinValue }
                }
            }
        } elseif ($dailyTrend -is [PSCustomObject] -or $dailyTrend -is [Hashtable]) {
            # Single object, wrap in array
            if ($null -ne $dailyTrend.Date -or $dailyTrend.DateString) {
                $sortedDailyTrend = @($dailyTrend)
            }
        }
    }
    
    foreach ($day in $sortedDailyTrend) {
        # Get date string - try DateString first, then generate from Date, then empty string
        $dayDateString = $null
        if ($day.DateString -and $day.DateString.ToString().Trim() -ne '') {
            $dayDateString = $day.DateString.ToString().Trim()
        } elseif ($day.Date) {
            try {
                if ($day.Date -is [DateTime]) {
                    $dayDateString = Get-Date $day.Date -Format 'yyyy-MM-dd'
                } elseif ($day.Date -is [String]) {
                    $dayDateString = (Get-Date $day.Date -Format 'yyyy-MM-dd')
                } else {
                    $dayDateString = $day.Date.ToString()
                }
            } catch {
                $dayDateString = $null
            }
        }
        
        if ($dayDateString) {
            $chartLabels += $dayDateString
        } else {
            # Skip days without valid dates
            continue
        }
        
        # Build raw daily data for JavaScript filtering (use the same date string)
        $dayData = @{
            date = $dayDateString
            categories = @{}
            subscriptions = @{}
            meters = @{}
            resources = @{}
            totalCostLocal = [math]::Round($day.TotalCostLocal, 2)
            totalCostUSD = [math]::Round($day.TotalCostUSD, 2)
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
    # Ensure we always have a valid JSON array, even if empty
    if ($rawDailyData -and $rawDailyData.Count -gt 0) {
        $rawDailyDataJson = $rawDailyData | ConvertTo-Json -Depth 6 -Compress
    } else {
        $rawDailyDataJson = "[]"
    }
    
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
    
    # Build datasets JSON for Chart.js - by Meter (use top 15 for initial display)
    $datasetsByMeterJson = @()
    $colorIndex = 0
    foreach ($meter in $top15Meters) {
        if ($chartDatasetsByMeter.ContainsKey($meter)) {
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
    }
    $datasetsByMeterJsonString = $datasetsByMeterJson -join ",`n"
    
    # Build datasets JSON for Chart.js - by Resource (use top 15 for initial display)
    $datasetsByResourceJson = @()
    $colorIndex = 0
    foreach ($resName in $top15Resources) {
        if ($chartDatasetsByResource.ContainsKey($resName)) {
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
    }
    $datasetsByResourceJsonString = $datasetsByResourceJson -join ",`n"
    
    # Convert chart labels to JSON
    $chartLabelsJson = ($chartLabels | ForEach-Object { "`"$_`"" }) -join ","
    
    # Build subscription options for filter (sorted by name)
    $subscriptionOptionsHtml = ""
    $subscriptionsForFilter = $subscriptionsArray | Sort-Object { if ($_.Name) { $_.Name } else { "Unknown" } }
    foreach ($sub in $subscriptionsForFilter) {
        $subName = if ($sub.Name) { [System.Web.HttpUtility]::HtmlEncode($sub.Name) } else { "Unknown" }
        $subId = if ($sub.SubscriptionId) { $sub.SubscriptionId } else { "" }
        $subscriptionOptionsHtml += @"
                        <label class="subscription-checkbox">
                            <input type="checkbox" value="$subName" data-subid="$subId" onchange="filterBySubscription()">
                            <span>$subName</span>
                        </label>
"@
    }
    
    # Generate subscription rows HTML
    $subscriptionRowsHtml = ""
    foreach ($sub in $subscriptionsArray) {
        $subName = if ($sub.Name) { [System.Web.HttpUtility]::HtmlEncode($sub.Name) } else { "Unknown" }
        $subCostLocal = Format-NumberWithSeparator -Number $sub.CostLocal
        $subCostUSD = Format-NumberWithSeparator -Number $sub.CostUSD
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
    
    # Generate top resources drilldown HTML (Resource > Meter Category > Meter)
    $topResourcesSectionsHtml = ""
    $topResourceMeterIdCounter = 0
    
    foreach ($res in $topResources) {
        $resId = $res.ResourceId
        $resName = if ($res.ResourceName) { [System.Web.HttpUtility]::HtmlEncode($res.ResourceName) } else { "N/A" }
        $resGroup = if ($res.ResourceGroup) { [System.Web.HttpUtility]::HtmlEncode($res.ResourceGroup) } else { "N/A" }
        $resSub = if ($res.SubscriptionName) { [System.Web.HttpUtility]::HtmlEncode($res.SubscriptionName) } else { "N/A" }
        $resType = if ($res.ResourceType) { [System.Web.HttpUtility]::HtmlEncode($res.ResourceType) } else { "N/A" }
        $resCostLocal = Format-NumberWithSeparator -Number $res.CostLocal
        $resCostUSD = Format-NumberWithSeparator -Number $res.CostUSD
        
        # Get all cost data for this resource from raw data
        $resourceData = $rawData | Where-Object { $_.ResourceId -eq $resId }
        
        # Group by Meter Category
        $categoryGroups = $resourceData | Group-Object MeterCategory
        $categoryHtml = ""
        
        foreach ($catGroup in ($categoryGroups | Sort-Object { ($_.Group | Measure-Object -Property CostUSD -Sum).Sum } -Descending)) {
            $catName = $catGroup.Name
            if ([string]::IsNullOrWhiteSpace($catName)) {
                $catName = "Unknown"
            }
            $catItems = $catGroup.Group
            $catCostLocal = ($catItems | Measure-Object -Property CostLocal -Sum).Sum
            $catCostUSD = ($catItems | Measure-Object -Property CostUSD -Sum).Sum
            $catCostLocalRounded = Format-NumberWithSeparator -Number $catCostLocal
            $catCostUSDRounded = Format-NumberWithSeparator -Number $catCostUSD
            $catNameEncoded = [System.Web.HttpUtility]::HtmlEncode($catName)
            
            # Group by Meter within category
            $meterGroups = $catItems | Group-Object Meter
            $meterCardsHtml = ""
            
            foreach ($meterGroup in ($meterGroups | Sort-Object { ($_.Group | Measure-Object -Property CostUSD -Sum).Sum } -Descending)) {
                $meterName = $meterGroup.Name
                if ([string]::IsNullOrWhiteSpace($meterName)) {
                    $meterName = "Unknown"
                }
                $meterItems = $meterGroup.Group
                $meterCostLocal = ($meterItems | Measure-Object -Property CostLocal -Sum).Sum
                $meterCostUSD = ($meterItems | Measure-Object -Property CostUSD -Sum).Sum
                $meterQuantity = ($meterItems | Measure-Object -Property Quantity -Sum).Sum
                $meterUnitOfMeasureGroups = $meterItems | Where-Object { $_.UnitOfMeasure -and -not [string]::IsNullOrWhiteSpace($_.UnitOfMeasure) } | Group-Object UnitOfMeasure
                $meterUnitOfMeasure = if ($meterUnitOfMeasureGroups.Count -gt 0) {
                    ($meterUnitOfMeasureGroups | Sort-Object Count -Descending | Select-Object -First 1).Name
                } else { "" }
                $meterUnitPrice = if ($meterQuantity -gt 0) { $meterCostLocal / $meterQuantity } else { 0 }
                $meterUnitPriceUSD = if ($meterQuantity -gt 0) { $meterCostUSD / $meterQuantity } else { 0 }
                $meterCostLocalRounded = Format-NumberWithSeparator -Number $meterCostLocal
                $meterCostUSDRounded = Format-NumberWithSeparator -Number $meterCostUSD
                $meterNameEncoded = [System.Web.HttpUtility]::HtmlEncode($meterName)
                $meterCount = $meterItems.Count
                $quantityDisplay = Format-QuantityWithUnit -Quantity $meterQuantity -UnitOfMeasure $meterUnitOfMeasure
                $unitPriceDisplay = if ($meterUnitPrice -gt 0) { Format-NumberWithSeparator -Number $meterUnitPrice } else { "" }
                $unitPriceUSDDisplay = if ($meterUnitPriceUSD -gt 0) { Format-NumberWithSeparator -Number $meterUnitPriceUSD } else { "" }
                $topResourceMeterIdCounter++
                
                $meterCardsHtml += @"
                            <div class="meter-card no-expand">
                                <div class="expandable__header meter-header" style="display: flex; align-items: center; justify-content: space-between;">
                                    <span class="meter-name" style="flex-grow: 1; font-weight: 600; margin-right: 10px;">$meterNameEncoded</span>
                                    <span class="meter-cost" style="color: #54a0ff !important; text-align: right; font-weight: 600; white-space: nowrap; margin-left: auto;">$currency $meterCostLocalRounded (`$$meterCostUSDRounded)</span>
                                    $(if ($quantityDisplay) { "<span class='meter-quantity'>$quantityDisplay</span>" } else { "" })
                                    $(if ($unitPriceDisplay) { "<span class='meter-unit-price'>Unit: $currency $unitPriceDisplay (`$$unitPriceUSDDisplay)</span>" } else { "" })
                                    <span class="meter-count">$meterCount records</span>
                                </div>
                            </div>
"@
            }
            
            $categoryHtml += @"
                        <div class="category-card collapsed">
                            <div class="expandable__header category-header collapsed" onclick="toggleCategory(this, event)">
                                <span class="expand-arrow">&#9654;</span>
                                <span class="category-title">$catNameEncoded</span>
                                <span class="category-cost">$currency $catCostLocalRounded (`$$catCostUSDRounded)</span>
                            </div>
                            <div class="category-content" style="display: none !important;">
$meterCardsHtml
                            </div>
                        </div>
"@
        }
        
        $topResourcesSectionsHtml += @"
                    <div class="category-card resource-card" data-subscription="$resSub">
                        <div class="category-header" onclick="toggleCategory(this, event)">
                            <span class="expand-arrow">&#9654;</span>
                            <span class="category-title">$resName</span>
                            <span class="category-cost">$currency $resCostLocal (`$$resCostUSD)</span>
                        </div>
                        <div class="category-content" style="display: none !important;">
                            <div class="resource-info">
                                <div>
                                    <div><strong>Resource Group:</strong> $resGroup</div>
                                    <div><strong>Subscription:</strong> $resSub</div>
                                    <div><strong>Type:</strong> $resType</div>
                                </div>
                            </div>
$categoryHtml
                        </div>
                    </div>
"@
    }
    
    # Generate Top 20 Cost Increase Drivers HTML (similar structure to top resources)
    $topIncreasedResourcesSectionsHtml = ""

    foreach ($res in $topIncreasedResources) {
        # Find the increase data for this resource
        $increaseData = $resourceIncreaseData[$res.ResourceName]
        if (-not $increaseData) {
            continue  # Skip if no increase data found
        }
        $resId = $res.ResourceId
        $resName = if ($res.ResourceName) { [System.Web.HttpUtility]::HtmlEncode($res.ResourceName) } else { "N/A" }
        $resGroup = if ($res.ResourceGroup) { [System.Web.HttpUtility]::HtmlEncode($res.ResourceGroup) } else { "N/A" }
        $resSub = if ($res.SubscriptionName) { [System.Web.HttpUtility]::HtmlEncode($res.SubscriptionName) } else { "N/A" }
        $resType = if ($res.ResourceType) { [System.Web.HttpUtility]::HtmlEncode($res.ResourceType) } else { "N/A" }
        $increaseAmount = Format-NumberWithSeparator -Number $increaseData.IncreaseAmount
        $increasePercent = [math]::Round($increaseData.IncreasePercent, 1)
        $increasePercentDisplay = if ($increasePercent -gt 1000) { "New" } else { "$increasePercent%" }
        
        # Get all cost data for this resource from raw data
        # Try matching by ResourceId first, then fall back to ResourceName if ResourceId is empty
        $resourceData = @()
        if ($resId -and -not [string]::IsNullOrWhiteSpace($resId)) {
            $resourceData = $rawData | Where-Object { $_.ResourceId -eq $resId }
        }
        # Fall back to ResourceName matching if no match by ResourceId
        if ($resourceData.Count -eq 0 -and $resName -and $resName -ne "N/A") {
            $resourceData = $rawData | Where-Object { $_.ResourceName -eq $resName }
        }
        
        # Group by Meter Category (reuse same logic as top resources)
        $categoryGroups = $resourceData | Group-Object MeterCategory
        $categoryHtml = ""
        
        foreach ($catGroup in ($categoryGroups | Sort-Object { ($_.Group | Measure-Object -Property CostUSD -Sum).Sum } -Descending)) {
            $catName = $catGroup.Name
            if ([string]::IsNullOrWhiteSpace($catName)) {
                $catName = "Unknown"
            }
            $catItems = $catGroup.Group
            $catCostLocal = ($catItems | Measure-Object -Property CostLocal -Sum).Sum
            $catCostUSD = ($catItems | Measure-Object -Property CostUSD -Sum).Sum
            $catCostLocalRounded = Format-NumberWithSeparator -Number $catCostLocal
            $catCostUSDRounded = Format-NumberWithSeparator -Number $catCostUSD
            $catNameEncoded = [System.Web.HttpUtility]::HtmlEncode($catName)
            
            # Group by Meter within category
            $meterGroups = $catItems | Group-Object Meter
            $meterCardsHtml = ""
            
            foreach ($meterGroup in ($meterGroups | Sort-Object { ($_.Group | Measure-Object -Property CostUSD -Sum).Sum } -Descending)) {
                $meterName = $meterGroup.Name
                if ([string]::IsNullOrWhiteSpace($meterName)) {
                    $meterName = "Unknown"
                }
                $meterItems = $meterGroup.Group
                $meterCostLocal = ($meterItems | Measure-Object -Property CostLocal -Sum).Sum
                $meterCostUSD = ($meterItems | Measure-Object -Property CostUSD -Sum).Sum
                $meterQuantity = ($meterItems | Measure-Object -Property Quantity -Sum).Sum
                $meterUnitOfMeasureGroups = $meterItems | Where-Object { $_.UnitOfMeasure -and -not [string]::IsNullOrWhiteSpace($_.UnitOfMeasure) } | Group-Object UnitOfMeasure
                $meterUnitOfMeasure = if ($meterUnitOfMeasureGroups.Count -gt 0) {
                    ($meterUnitOfMeasureGroups | Sort-Object Count -Descending | Select-Object -First 1).Name
                } else { "" }
                $meterUnitPrice = if ($meterQuantity -gt 0) { $meterCostLocal / $meterQuantity } else { 0 }
                $meterUnitPriceUSD = if ($meterQuantity -gt 0) { $meterCostUSD / $meterQuantity } else { 0 }
                $meterCostLocalRounded = Format-NumberWithSeparator -Number $meterCostLocal
                $meterCostUSDRounded = Format-NumberWithSeparator -Number $meterCostUSD
                $meterNameEncoded = [System.Web.HttpUtility]::HtmlEncode($meterName)
                $meterCount = $meterItems.Count
                $quantityDisplay = Format-QuantityWithUnit -Quantity $meterQuantity -UnitOfMeasure $meterUnitOfMeasure
                $unitPriceDisplay = if ($meterUnitPrice -gt 0) { Format-NumberWithSeparator -Number $meterUnitPrice } else { "" }
                $unitPriceUSDDisplay = if ($meterUnitPriceUSD -gt 0) { Format-NumberWithSeparator -Number $meterUnitPriceUSD } else { "" }
                
                $meterCardsHtml += @"
                            <div class="meter-card no-expand">
                                <div class="expandable__header meter-header" style="display: flex; align-items: center; justify-content: space-between;">
                                    <span class="meter-name" style="flex-grow: 1; font-weight: 600; margin-right: 10px;">$meterNameEncoded</span>
                                    <span class="meter-cost" style="color: #54a0ff !important; text-align: right; font-weight: 600; white-space: nowrap; margin-left: auto;">$currency $meterCostLocalRounded (`$$meterCostUSDRounded)</span>
                                    $(if ($quantityDisplay) { "<span class='meter-quantity'>$quantityDisplay</span>" } else { "" })
                                    $(if ($unitPriceDisplay) { "<span class='meter-unit-price'>Unit: $currency $unitPriceDisplay (`$$unitPriceUSDDisplay)</span>" } else { "" })
                                    <span class="meter-count">$meterCount records</span>
                                </div>
                            </div>
"@
            }
            
            $categoryHtml += @"
                        <div class="category-card collapsed">
                            <div class="expandable__header category-header collapsed" onclick="toggleCategory(this, event)">
                                <span class="expand-arrow">&#9654;</span>
                                <span class="category-title">$catNameEncoded</span>
                                <span class="category-cost">$currency $catCostLocalRounded (`$$catCostUSDRounded)</span>
                            </div>
                            <div class="category-content" style="display: none !important;">
$meterCardsHtml
                            </div>
                        </div>
"@
        }
        
        $topIncreasedResourcesSectionsHtml += @"
                    <div class="category-card resource-card increased-cost-card" data-subscription="$resSub">
                        <div class="category-header" onclick="toggleCategory(this, event)">
                            <span class="expand-arrow">&#9654;</span>
                            <span class="category-title">$resName</span>
                            <span class="category-cost">+$currency $increaseAmount ($increasePercentDisplay)</span>
                        </div>
                        <div class="category-content" style="display: none !important;">
                            <div class="resource-info">
                                <div>
                                    <div><strong>Resource Group:</strong> $resGroup</div>
                                    <div><strong>Subscription:</strong> $resSub</div>
                                    <div><strong>Type:</strong> $resType</div>
                                    <div><strong>Cost Increase:</strong> +$currency $increaseAmount ($increasePercentDisplay)</div>
                                </div>
                            </div>
$categoryHtml
                        </div>
                    </div>
"@
    }

    # Generate category sections HTML with drilldown (4 levels: Category > SubCategory > Meter > Resource)
    $categorySectionsHtml = ""
    $meterIdCounter = 0
    
    # Build categories structure from rawData if available, otherwise use simple byMeterCategory
    if ($rawData.Count -gt 0) {
        # Group raw data by category
        $categoryGroups = $rawData | Group-Object MeterCategory
        $categoriesArray = @()
        foreach ($catGroup in ($categoryGroups | Sort-Object { ($_.Group | Measure-Object -Property CostUSD -Sum).Sum } -Descending)) {
            $catName = $catGroup.Name
            if ([string]::IsNullOrWhiteSpace($catName)) {
                $catName = "Unknown"
            }
            $catItems = $catGroup.Group
            $catCostLocal = ($catItems | Measure-Object -Property CostLocal -Sum).Sum
            $catCostUSD = ($catItems | Measure-Object -Property CostUSD -Sum).Sum
            
            # Build SubCategories structure
            $subCatGroups = $catItems | Group-Object MeterSubCategory
            $subCategories = @{}
            foreach ($subCatGroup in ($subCatGroups | Sort-Object { ($_.Group | Measure-Object -Property CostUSD -Sum).Sum } -Descending)) {
                $subCatName = $subCatGroup.Name
                if ([string]::IsNullOrWhiteSpace($subCatName)) {
                    $subCatName = "N/A"
                }
                $subCatItems = $subCatGroup.Group
                $subCatCostLocal = ($subCatItems | Measure-Object -Property CostLocal -Sum).Sum
                $subCatCostUSD = ($subCatItems | Measure-Object -Property CostUSD -Sum).Sum
                
                # Build Meters structure
                $meterGroups = $subCatItems | Group-Object Meter
                $meters = @{}
                foreach ($meterGroup in ($meterGroups | Sort-Object { ($_.Group | Measure-Object -Property CostUSD -Sum).Sum } -Descending)) {
                    $meterName = $meterGroup.Name
                    if ([string]::IsNullOrWhiteSpace($meterName)) {
                        $meterName = "Unknown"
                    }
                    $meterItems = $meterGroup.Group
                    $meterCostLocal = ($meterItems | Measure-Object -Property CostLocal -Sum).Sum
                    $meterCostUSD = ($meterItems | Measure-Object -Property CostUSD -Sum).Sum
                    $meterQuantity = ($meterItems | Measure-Object -Property Quantity -Sum).Sum
                    $meterUnitOfMeasureGroups = $meterItems | Where-Object { $_.UnitOfMeasure -and -not [string]::IsNullOrWhiteSpace($_.UnitOfMeasure) } | Group-Object UnitOfMeasure
                    $meterUnitOfMeasure = if ($meterUnitOfMeasureGroups.Count -gt 0) {
                        ($meterUnitOfMeasureGroups | Sort-Object Count -Descending | Select-Object -First 1).Name
                    } else { "" }
                    $meterUnitPrice = if ($meterQuantity -gt 0) { $meterCostLocal / $meterQuantity } else { 0 }
                    $meterUnitPriceUSD = if ($meterQuantity -gt 0) { $meterCostUSD / $meterQuantity } else { 0 }
                    $meterCount = $meterItems.Count
                    
                    # Build Resources structure
                    $resourceGroups = $meterItems | Where-Object { $_.ResourceName -and -not [string]::IsNullOrWhiteSpace($_.ResourceName) } | Group-Object ResourceName
                    $resources = @{}
                    foreach ($resGroup in ($resourceGroups | Sort-Object { ($_.Group | Measure-Object -Property CostUSD -Sum).Sum } -Descending)) {
                        $resName = $resGroup.Name
                        $resItems = $resGroup.Group
                        $resCostLocal = ($resItems | Measure-Object -Property CostLocal -Sum).Sum
                        $resCostUSD = ($resItems | Measure-Object -Property CostUSD -Sum).Sum
                        $resources[$resName] = @{
                            ResourceName = $resName
                            ResourceGroup = if ($resItems[0].ResourceGroup) { $resItems[0].ResourceGroup } else { "N/A" }
                            SubscriptionName = if ($resItems[0].SubscriptionName) { $resItems[0].SubscriptionName } else { "N/A" }
                            CostLocal = $resCostLocal
                            CostUSD = $resCostUSD
                        }
                    }
                    
                    $meters[$meterName] = @{
                        Meter = $meterName
                        CostLocal = $meterCostLocal
                        CostUSD = $meterCostUSD
                        Quantity = $meterQuantity
                        UnitOfMeasure = $meterUnitOfMeasure
                        UnitPrice = $meterUnitPrice
                        UnitPriceUSD = $meterUnitPriceUSD
                        ItemCount = $meterCount
                        Resources = $resources
                    }
                }
                
                $subCategories[$subCatName] = @{
                    MeterSubCategory = $subCatName
                    CostLocal = $subCatCostLocal
                    CostUSD = $subCatCostUSD
                    Meters = $meters
                }
            }
            
            $categoriesArray += [PSCustomObject]@{
                MeterCategory = $catName
                CostLocal = $catCostLocal
                CostUSD = $catCostUSD
                SubCategories = $subCategories
            }
        }
    }
    
    foreach ($cat in $categoriesArray) {
        $catName = if ($cat.MeterCategory) { [System.Web.HttpUtility]::HtmlEncode($cat.MeterCategory) } else { "Unknown" }
        $catCostLocal = Format-NumberWithSeparator -Number $cat.CostLocal
        $catCostUSD = Format-NumberWithSeparator -Number $cat.CostUSD
        
        $subCatHtml = ""
        if ($cat.SubCategories -and $cat.SubCategories.Count -gt 0) {
            # Sort subcategories by cost descending
            $sortedSubCats = $cat.SubCategories.GetEnumerator() | Sort-Object { $_.Value.CostUSD } -Descending
            foreach ($subCatEntry in $sortedSubCats) {
                $subCat = $subCatEntry.Value
                $subCatName = if ($subCat.MeterSubCategory) { [System.Web.HttpUtility]::HtmlEncode($subCat.MeterSubCategory) } else { "N/A" }
                $subCatCostLocal = Format-NumberWithSeparator -Number $subCat.CostLocal
                $subCatCostUSD = Format-NumberWithSeparator -Number $subCat.CostUSD
                
                $meterCardsHtml = ""
                if ($subCat.Meters -and $subCat.Meters.Count -gt 0) {
                    # Sort meters by cost descending
                    $sortedMeters = $subCat.Meters.GetEnumerator() | Sort-Object { $_.Value.CostUSD } -Descending
                    foreach ($meterEntry in $sortedMeters) {
                        $meter = $meterEntry.Value
                        $meterName = if ($meter.Meter) { [System.Web.HttpUtility]::HtmlEncode($meter.Meter) } else { "Unknown" }
                        $meterCostLocal = Format-NumberWithSeparator -Number $meter.CostLocal
                        $meterCostUSD = Format-NumberWithSeparator -Number $meter.CostUSD
                        $meterCount = $meter.ItemCount
                        $meterQuantity = if ($meter.Quantity) { $meter.Quantity } else { 0 }
                        $meterUnitOfMeasure = if ($meter.UnitOfMeasure) { [System.Web.HttpUtility]::HtmlEncode($meter.UnitOfMeasure) } else { "" }
                        $meterUnitPrice = if ($meter.UnitPrice) { Format-NumberWithSeparator -Number $meter.UnitPrice } else { "" }
                        $meterUnitPriceUSD = if ($meter.UnitPriceUSD) { Format-NumberWithSeparator -Number $meter.UnitPriceUSD } else { "" }
                        $quantityDisplay = Format-QuantityWithUnit -Quantity $meterQuantity -UnitOfMeasure $meterUnitOfMeasure
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
                                $resCostLocalFormatted = Format-NumberWithSeparator -Number $res.CostLocal
                                $resCostUSDFormatted = Format-NumberWithSeparator -Number $res.CostUSD
                                $resourceRowsHtml += @"
                                            <tr data-subscription="$resSub">
                                                <td>$resName</td>
                                                <td>$resGroup</td>
                                                <td>$resSub</td>
                                                <td class="cost-value text-right">$currency $resCostLocalFormatted</td>
                                                <td class="cost-value text-right">`$$resCostUSDFormatted</td>
                                            </tr>
"@
                            }
                        }
                        
                        if ($hasResources) {
                            $meterCardsHtml += @"
                            <div class="meter-card">
                                <div class="meter-header" onclick="toggleMeter(this)" style="display: flex; align-items: center; justify-content: space-between;">
                                    <span class="expand-arrow">&#9654;</span>
                                    <span class="meter-name" style="flex-grow: 1; font-weight: 600; margin-right: 10px;">$meterName</span>
                                    <div class="meter-header-right" style="display: flex; align-items: center; gap: 10px; margin-left: auto;">
                                        <span class="meter-cost" style="color: #54a0ff !important; text-align: right; font-weight: 600; white-space: nowrap;">$currency $meterCostLocal (`$$meterCostUSD)</span>
                                        $(if ($quantityDisplay) { "<span class='meter-quantity'>$quantityDisplay</span>" } else { "" })
                                        $(if ($meterUnitPrice) { "<span class='meter-unit-price'>Unit: $currency $meterUnitPrice (`$$meterUnitPriceUSD)</span>" } else { "" })
                                        <span class="meter-count">$meterCount records</span>
                                    </div>
                                </div>
                                <div class="meter-content">
                                    <table class="data-table">
                                        <thead>
                                            <tr>
                                                <th>Resource</th>
                                                <th>Resource Group</th>
                                                <th>Subscription</th>
                                                <th class="text-right">Cost (Local)</th>
                                                <th class="text-right">Cost (USD)</th>
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
                                <div class="expandable__header meter-header" style="display: flex; align-items: center; justify-content: space-between;">
                                    <span class="meter-name" style="flex-grow: 1; font-weight: 600; margin-right: 10px;">$meterName</span>
                                    <span class="meter-cost" style="color: #54a0ff !important; text-align: right; font-weight: 600; white-space: nowrap; margin-left: auto;">$currency $meterCostLocal (`$$meterCostUSD)</span>
                                    $(if ($quantityDisplay) { "<span class='meter-quantity'>$quantityDisplay</span>" } else { "" })
                                    $(if ($meterUnitPrice) { "<span class='meter-unit-price'>Unit: $currency $meterUnitPrice (`$$meterUnitPriceUSD)</span>" } else { "" })
                                    <span class="meter-count">$meterCount records</span>
                                </div>
                            </div>
"@
                        }
                    }
                }
                
                $subCatHtml += @"
                        <div class="subcategory-drilldown">
                            <div class="expandable__header subcategory-header" onclick="toggleSubCategory(this, event)" style="display: flex; align-items: center; justify-content: space-between;">
                                <span class="expand-arrow">&#9654;</span>
                                <span class="subcategory-name" style="flex-grow: 1; font-weight: 600; margin-right: 10px;">$subCatName</span>
                                <span class="subcategory-cost" style="color: #54a0ff !important; text-align: right; font-weight: 600; white-space: nowrap; margin-left: auto;">$currency $subCatCostLocal (`$$subCatCostUSD)</span>
                            </div>
                            <div class="subcategory-content" style="display: none !important;">
$meterCardsHtml
                            </div>
                        </div>
"@
            }
        }
        
        $categorySectionsHtml += @"
                    <div class="category-card collapsed">
                        <div class="category-header collapsed" onclick="toggleCategory(this, event)">
                            <span class="expand-arrow">&#9654;</span>
                            <span class="category-title">$catName</span>
                            <span class="category-cost">$currency $catCostLocal (`$$catCostUSD)</span>
                        </div>
                        <div class="category-content" style="display: none !important;">
$subCatHtml
                        </div>
                    </div>
"@
    }
    
    # Generate subscription sections HTML with drilldown (5 levels: Subscription > Category > SubCategory > Meter > Resource)
    $subscriptionSectionsHtml = ""
    $subscriptionMeterIdCounter = 0
    $rawData = if ($CostTrackingData.RawData) { $CostTrackingData.RawData } else { @() }
    
    # Group raw data by subscription
    if ($rawData.Count -gt 0) {
        $subscriptionGroups = $rawData | Group-Object SubscriptionId
        foreach ($subGroup in ($subscriptionGroups | Sort-Object { ($_.Group | Measure-Object -Property CostUSD -Sum).Sum } -Descending)) {
            $subId = $subGroup.Name
            $subItems = $subGroup.Group
            $subName = if ($subItems[0].SubscriptionName) { $subItems[0].SubscriptionName } else { "Unknown" }
            $subCostLocal = ($subItems | Measure-Object -Property CostLocal -Sum).Sum
            $subCostUSD = ($subItems | Measure-Object -Property CostUSD -Sum).Sum
            $subCostLocalRounded = Format-NumberWithSeparator -Number $subCostLocal
            $subCostUSDRounded = Format-NumberWithSeparator -Number $subCostUSD
            $subNameEncoded = [System.Web.HttpUtility]::HtmlEncode($subName)
            
            # Group by category within subscription
            $categoryGroups = $subItems | Group-Object MeterCategory
            $categoryHtml = ""
            
            foreach ($catGroup in ($categoryGroups | Sort-Object { ($_.Group | Measure-Object -Property CostUSD -Sum).Sum } -Descending)) {
                $catName = $catGroup.Name
                if ([string]::IsNullOrWhiteSpace($catName)) {
                    $catName = "Unknown"
                }
                $catItems = $catGroup.Group
                $catCostLocal = ($catItems | Measure-Object -Property CostLocal -Sum).Sum
                $catCostUSD = ($catItems | Measure-Object -Property CostUSD -Sum).Sum
                $catCostLocalRounded = Format-NumberWithSeparator -Number $catCostLocal
                $catCostUSDRounded = Format-NumberWithSeparator -Number $catCostUSD
                $catNameEncoded = [System.Web.HttpUtility]::HtmlEncode($catName)
                
                # Group by subcategory within category
                $subCatGroups = $catItems | Group-Object MeterSubCategory
                $subCatHtml = ""
                
                foreach ($subCatGroup in ($subCatGroups | Sort-Object { ($_.Group | Measure-Object -Property CostUSD -Sum).Sum } -Descending)) {
                    $subCatName = $subCatGroup.Name
                    if ([string]::IsNullOrWhiteSpace($subCatName)) {
                        $subCatName = "N/A"
                    }
                    $subCatItems = $subCatGroup.Group
                    $subCatCostLocal = ($subCatItems | Measure-Object -Property CostLocal -Sum).Sum
                    $subCatCostUSD = ($subCatItems | Measure-Object -Property CostUSD -Sum).Sum
                    $subCatCostLocalRounded = [math]::Round($subCatCostLocal, 2)
                    $subCatCostUSDRounded = [math]::Round($subCatCostUSD, 2)
                    $subCatNameEncoded = [System.Web.HttpUtility]::HtmlEncode($subCatName)
                    
                    # Group by meter within subcategory
                    $meterGroups = $subCatItems | Group-Object Meter
                    $meterCardsHtml = ""
                    
                    foreach ($meterGroup in ($meterGroups | Sort-Object { ($_.Group | Measure-Object -Property CostUSD -Sum).Sum } -Descending)) {
                        $meterName = $meterGroup.Name
                        if ([string]::IsNullOrWhiteSpace($meterName)) {
                            $meterName = "Unknown"
                        }
                        $meterItems = $meterGroup.Group
                        $meterCostLocal = ($meterItems | Measure-Object -Property CostLocal -Sum).Sum
                        $meterCostUSD = ($meterItems | Measure-Object -Property CostUSD -Sum).Sum
                        $meterQuantity = ($meterItems | Measure-Object -Property Quantity -Sum).Sum
                        $meterUnitOfMeasureGroups = $meterItems | Where-Object { $_.UnitOfMeasure -and -not [string]::IsNullOrWhiteSpace($_.UnitOfMeasure) } | Group-Object UnitOfMeasure
                        $meterUnitOfMeasure = if ($meterUnitOfMeasureGroups.Count -gt 0) {
                            ($meterUnitOfMeasureGroups | Sort-Object Count -Descending | Select-Object -First 1).Name
                        } else { "" }
                        $meterUnitPrice = if ($meterQuantity -gt 0) { $meterCostLocal / $meterQuantity } else { 0 }
                        $meterUnitPriceUSD = if ($meterQuantity -gt 0) { $meterCostUSD / $meterQuantity } else { 0 }
                        $meterCostLocalRounded = Format-NumberWithSeparator -Number $meterCostLocal
                        $meterCostUSDRounded = Format-NumberWithSeparator -Number $meterCostUSD
                        $meterNameEncoded = [System.Web.HttpUtility]::HtmlEncode($meterName)
                        $meterCount = $meterItems.Count
                        $quantityDisplay = Format-QuantityWithUnit -Quantity $meterQuantity -UnitOfMeasure $meterUnitOfMeasure
                        $unitPriceDisplay = if ($meterUnitPrice -gt 0) { Format-NumberWithSeparator -Number $meterUnitPrice } else { "" }
                        $unitPriceUSDDisplay = if ($meterUnitPriceUSD -gt 0) { Format-NumberWithSeparator -Number $meterUnitPriceUSD } else { "" }
                        $subscriptionMeterIdCounter++
                        
                        # Group by resource within meter
                        $resourceGroups = $meterItems | Where-Object { $_.ResourceName -and -not [string]::IsNullOrWhiteSpace($_.ResourceName) } | Group-Object ResourceName
                        $resourceRowsHtml = ""
                        $hasResources = $false
                        
                        if ($resourceGroups.Count -gt 0) {
                            $hasResources = $true
                            foreach ($resGroup in ($resourceGroups | Sort-Object { ($_.Group | Measure-Object -Property CostUSD -Sum).Sum } -Descending)) {
                                $resName = $resGroup.Name
                                $resItems = $resGroup.Group
                                $resCostLocal = ($resItems | Measure-Object -Property CostLocal -Sum).Sum
                                $resCostUSD = ($resItems | Measure-Object -Property CostUSD -Sum).Sum
                                $resCostLocalFormatted = Format-NumberWithSeparator -Number $resCostLocal
                                $resCostUSDFormatted = Format-NumberWithSeparator -Number $resCostUSD
                                $resNameEncoded = [System.Web.HttpUtility]::HtmlEncode($resName)
                                $resGroupName = if ($resItems[0].ResourceGroup) { [System.Web.HttpUtility]::HtmlEncode($resItems[0].ResourceGroup) } else { "N/A" }
                                
                                $resourceRowsHtml += @"
                                            <tr data-subscription="$subNameEncoded">
                                                <td>$resNameEncoded</td>
                                                <td>$resGroupName</td>
                                                <td class="cost-value text-right">$currency $resCostLocalFormatted</td>
                                                <td class="cost-value text-right">`$$resCostUSDFormatted</td>
                                            </tr>
"@
                            }
                        }
                        
                        if ($hasResources) {
                            $meterCardsHtml += @"
                            <div class="meter-card">
                                <div class="meter-header" onclick="toggleMeter(this)" style="display: flex; align-items: center; justify-content: space-between;">
                                    <span class="expand-arrow">&#9654;</span>
                                    <span class="meter-name" style="flex-grow: 1; font-weight: 600; margin-right: 10px;">$meterNameEncoded</span>
                                    <div class="meter-header-right" style="display: flex; align-items: center; gap: 10px; margin-left: auto;">
                                        <span class="meter-cost" style="color: #54a0ff !important; text-align: right; font-weight: 600; white-space: nowrap;">$currency $meterCostLocalRounded (`$$meterCostUSDRounded)</span>
                                        $(if ($quantityDisplay) { "<span class='meter-quantity'>$quantityDisplay</span>" } else { "" })
                                        $(if ($unitPriceDisplay) { "<span class='meter-unit-price'>Unit: $currency $unitPriceDisplay (`$$unitPriceUSDDisplay)</span>" } else { "" })
                                        <span class="meter-count">$meterCount records</span>
                                    </div>
                                </div>
                                <div class="meter-content">
                                    <table class="data-table">
                                        <thead>
                                            <tr>
                                                <th>Resource</th>
                                                <th>Resource Group</th>
                                                <th class="text-right">Cost (Local)</th>
                                                <th class="text-right">Cost (USD)</th>
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
                                <div class="expandable__header meter-header" style="display: flex; align-items: center; justify-content: space-between;">
                                    <span class="meter-name" style="flex-grow: 1; font-weight: 600; margin-right: 10px;">$meterNameEncoded</span>
                                    <span class="meter-cost" style="color: #54a0ff !important; text-align: right; font-weight: 600; white-space: nowrap; margin-left: auto;">$currency $meterCostLocalRounded (`$$meterCostUSDRounded)</span>
                                    $(if ($quantityDisplay) { "<span class='meter-quantity'>$quantityDisplay</span>" } else { "" })
                                    $(if ($unitPriceDisplay) { "<span class='meter-unit-price'>Unit: $currency $unitPriceDisplay (`$$unitPriceUSDDisplay)</span>" } else { "" })
                                    <span class="meter-count">$meterCount records</span>
                                </div>
                            </div>
"@
                        }
                    }
                    
                    $subCatHtml += @"
                        <div class="subcategory-drilldown">
                            <div class="expandable__header subcategory-header" onclick="toggleSubCategory(this, event)" style="display: flex; align-items: center; justify-content: space-between;">
                                <span class="expand-arrow">&#9654;</span>
                                <span class="subcategory-name" style="flex-grow: 1; font-weight: 600; margin-right: 10px;">$subCatNameEncoded</span>
                                <span class="subcategory-cost" style="color: #54a0ff !important; text-align: right; font-weight: 600; white-space: nowrap; margin-left: auto;">$currency $subCatCostLocalRounded (`$$subCatCostUSDRounded)</span>
                            </div>
                            <div class="subcategory-content" style="display: none !important;">
$meterCardsHtml
                            </div>
                        </div>
"@
                }
                
                $categoryHtml += @"
                        <div class="category-card collapsed">
                            <div class="expandable__header category-header collapsed" onclick="toggleCategory(this, event)">
                                <span class="expand-arrow">&#9654;</span>
                                <span class="category-title">$catNameEncoded</span>
                                <span class="category-cost">$currency $catCostLocalRounded (`$$catCostUSDRounded)</span>
                            </div>
                            <div class="category-content" style="display: none !important;">
$subCatHtml
                            </div>
                        </div>
"@
            }
            
            $subscriptionSectionsHtml += @"
                    <div class="category-card subscription-card collapsed" data-subscription="$subNameEncoded">
                        <div class="category-header collapsed" onclick="toggleCategory(this, event)">
                            <span class="expand-arrow">&#9654;</span>
                            <span class="category-title">$subNameEncoded</span>
                            <span class="category-cost">$currency $subCostLocalRounded (`$$subCostUSDRounded)</span>
                        </div>
                        <div class="category-content" style="display: none !important;">
$categoryHtml
                        </div>
                    </div>
"@
        }
    }
    
    # Build trend indicator with arrow and color class
    $trendArrow = switch ($trendDirection) {
        "up" { "&#8593;" }
        "down" { "&#8595;" }
        default { "&#8594;" }
    }
    $trendColorClass = switch ($trendDirection) {
        "up" { "trend-increasing" }
        "down" { "trend-decreasing" }
        default { "trend-stable" }
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
    </style>
</head>
<body>
    $(Get-ReportNavigation -ActivePage "CostTracking")
    
    <div class="container">
        <div class="page-header">
            <h1>&#128176; Cost Tracking</h1>
            <div class="metadata">
                <p><strong>Tenant:</strong> $TenantId</p>
                <p><strong>Scanned:</strong> $timestamp</p>
                <p><strong>Subscriptions:</strong> $($CostTrackingData.SubscriptionCount)</p>
                <p><strong>Resources:</strong> $($CostTrackingData.TopResources.Count)</p>
                <p><strong>Total Findings:</strong> $($CostTrackingData.TopResources.Count)</p>
            </div>
        </div>
        
        <div class="section-box">
            <h2>Cost Overview</h2>
            <div class="summary-grid">
                <div class="summary-card blue-border">
                    <div class="summary-card-value" id="summary-total-cost-local">$(Format-NumberNoDecimals -Number $totalCostLocal)</div>
                    <div class="summary-card-label">Total Cost ($currency)</div>
                </div>
                <div class="summary-card green-border">
                    <div class="summary-card-value" id="summary-total-cost-usd">$(Format-NumberNoDecimals -Number $totalCostUSD)</div>
                    <div class="summary-card-label">Total Cost (USD)</div>
                </div>
                <div class="summary-card purple-border">
                    <div class="summary-card-value" id="summary-subscription-count">$subscriptionCount</div>
                    <div class="summary-card-label">Subscriptions</div>
                </div>
                <div class="summary-card teal-border">
                    <div class="summary-card-value" id="summary-category-count">$($byMeterCategory.Count)</div>
                    <div class="summary-card-label">Meter Categories</div>
                </div>
                <div class="summary-card $(if ($trendDirection -eq 'up') { 'red-border' } elseif ($trendDirection -eq 'down') { 'green-border' } else { 'gray-border' })">
                    <div class="summary-card-value $trendColorClass" id="summary-trend-percent">$trendArrow $([math]::Abs($trendPercent))%</div>
                    <div class="summary-card-label">Cost Trend</div>
                </div>
            </div>
        </div>
        
        <div class="section-box">
            <h2>Daily Cost Chart</h2>
            <div class="chart-controls">
                <select id="chartView" onchange="updateChartView()">
                    <option value="stacked-category">Stacked by Category</option>
                    <option value="stacked-subscription">Stacked by Subscription</option>
                    <option value="stacked-meter">Stacked by Meter (Top 15)</option>
                    <option value="stacked-resource">Stacked by Resource (Top 15)</option>
                    <option value="total" selected>Total Cost</option>
                </select>
                <select id="categoryFilter" onchange="filterChartCategory()">
                    <option value="all">All Categories</option>
                </select>
            </div>
            <div class="chart-container">
                <canvas id="costChart"></canvas>
            </div>
        </div>
        
        <div class="section-box">
            <h2>Filters</h2>
            <div class="global-filter-bar">
                <div class="filter-bar" style="margin-bottom: 15px;">
                    <label>Search:</label>
                    <input type="text" id="resourceSearch" placeholder="Filter all sections..." oninput="filterResources()">
                </div>
                <h3 onclick="toggleSubscriptionFilter(this)">
                    <span class="expand-arrow">&#9654;</span> Filter by Subscription
                </h3>
                <div class="subscription-filter-content">
                    <div class="subscription-filter-container">
$subscriptionOptionsHtml
                        <div class="filter-actions">
                            <button class="filter-btn" onclick="selectAllSubscriptions()">Select All</button>
                            <button class="filter-btn" onclick="deselectAllSubscriptions()">Deselect All</button>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        
        <div class="section-box">
            <h2>Cost Breakdown</h2>
            <div class="expandable expandable--collapsed">
                <div class="expandable__header" onclick="toggleSection(this)">
                    <div class="expandable__title">
                        <span class="expand-arrow">&#9654;</span>
                        <h3>Cost by Subscription</h3>
                    </div>
                </div>
                <div class="expandable__content">
$subscriptionSectionsHtml
                </div>
            </div>
            
            <div class="expandable expandable--collapsed">
                <div class="expandable__header" onclick="toggleSection(this)">
                    <div class="expandable__title">
                        <span class="expand-arrow">&#9654;</span>
                        <h3>Cost by Meter Category</h3>
                    </div>
                </div>
                <div class="expandable__content">
$categorySectionsHtml
                </div>
            </div>
            
            <div class="expandable expandable--collapsed">
                <div class="expandable__header" onclick="toggleSection(this)">
                    <div class="expandable__title">
                        <span class="expand-arrow">&#9654;</span>
                        <h3>Top 20 Resources by Cost</h3>
                    </div>
                </div>
                <div class="expandable__content">
$topResourcesSectionsHtml
                </div>
            </div>
            
            <div class="expandable expandable--collapsed">
                <div class="expandable__header" onclick="toggleSection(this)">
                    <div class="expandable__title">
                        <span class="expand-arrow">&#9654;</span>
                        <h3>Top 20 Cost Increase Drivers</h3>
                    </div>
                </div>
                <div class="expandable__content">
$topIncreasedResourcesSectionsHtml
                </div>
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
        let currentView = 'total';
        let currentCategoryFilter = 'all';
        let selectedSubscriptions = new Set();
        
        // Store original summary card values
        const originalSummaryValues = {
            totalCostLocal: null,
            totalCostUSD: null,
            subscriptionCount: null,
            categoryCount: null,
            trendPercent: null,
            trendColorClass: null
        };
        
        // Helper function to format numbers with thousand separator (space) and round to nearest integer
        function formatNumberNoDecimals(number) {
            return Math.round(number).toLocaleString('en-US').replace(/,/g, ' ');
        }
        
        // Helper function to format numbers with thousand separator (space) and 2 decimals
        function formatNumberWithDecimals(number) {
            return number.toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
        }
        
        // Initialize
        document.addEventListener('DOMContentLoaded', function() {

            // Initialize: Ensure all meter-cards are collapsed by default
            document.querySelectorAll('.meter-card:not(.no-expand)').forEach(card => {
                
                if (!card.classList.contains('expanded')) {
                    card.classList.remove('expanded');
                    const meterHeader = card.querySelector('.meter-header');
                    if (meterHeader) {
                        const arrow = meterHeader.querySelector('.expand-arrow');
                        if (arrow) {
                            arrow.textContent = '\u25B6'; // ▶ (collapsed)
                        }
                    }
                }
            });
            
            // Initialize: Ensure all category-cards are collapsed by default
            document.querySelectorAll('.category-card').forEach(card => {
                // Always remove expanded class to ensure collapsed state
                card.classList.remove('expanded');
                const categoryContent = card.querySelector('.category-content');
                if (categoryContent) {
                    // Force hide with multiple methods to ensure it works
                    categoryContent.style.display = 'none';
                    categoryContent.style.visibility = 'hidden';
                    categoryContent.style.height = '0';
                    categoryContent.style.overflow = 'hidden';
                }
                const categoryHeader = card.querySelector('.category-header, .expandable__header.category-header');
                if (categoryHeader) {
                    const arrow = categoryHeader.querySelector('.expand-arrow');
                    if (arrow) {
                        arrow.textContent = '\u25B6'; // ▶ (collapsed)
                    }
                }
            });
            
            // Initialize: Ensure all subcategory-drilldowns are collapsed by default
            document.querySelectorAll('.subcategory-drilldown').forEach(drilldown => {
                // Always remove expanded class to ensure collapsed state
                drilldown.classList.remove('expanded');
                const subcategoryContent = drilldown.querySelector('.subcategory-content');
                if (subcategoryContent) {
                    // Force hide with multiple methods to ensure it works - use !important via setProperty
                    // Also remove any inline styles that might make it visible
                    subcategoryContent.removeAttribute('style');
                    subcategoryContent.style.setProperty('display', 'none', 'important');
                    subcategoryContent.style.setProperty('visibility', 'hidden', 'important');
                    subcategoryContent.style.setProperty('height', '0', 'important');
                    subcategoryContent.style.setProperty('overflow', 'hidden', 'important');
                    subcategoryContent.style.setProperty('max-height', '0', 'important');
                    subcategoryContent.style.setProperty('opacity', '0', 'important');
                }
                const subcategoryHeader = drilldown.querySelector('.subcategory-header, .expandable__header.subcategory-header');
                if (subcategoryHeader) {
                    const arrow = subcategoryHeader.querySelector('.expand-arrow');
                    if (arrow) {
                        arrow.textContent = '\u25B6'; // ▶ (collapsed)
                    }
                }
            });
            
            // Initialize selected subscriptions from checkboxes
            document.querySelectorAll('.subscription-checkbox input').forEach(cb => {
                if (cb.checked) {
                    selectedSubscriptions.add(cb.value);
                }
            });
            
            // Store original summary values
            const totalCostLocalEl = document.getElementById('summary-total-cost-local');
            const totalCostUsdEl = document.getElementById('summary-total-cost-usd');
            const subscriptionCountEl = document.getElementById('summary-subscription-count');
            const categoryCountEl = document.getElementById('summary-category-count');
            const trendPercentEl = document.getElementById('summary-trend-percent');
            
            if (totalCostLocalEl) originalSummaryValues.totalCostLocal = totalCostLocalEl.textContent;
            if (totalCostUsdEl) originalSummaryValues.totalCostUSD = totalCostUsdEl.textContent;
            if (subscriptionCountEl) originalSummaryValues.subscriptionCount = subscriptionCountEl.textContent;
            if (categoryCountEl) originalSummaryValues.categoryCount = categoryCountEl.textContent;
            if (trendPercentEl) {
                originalSummaryValues.trendPercent = trendPercentEl.innerHTML; // Store HTML to preserve arrow entity
                // Store the color class
                if (trendPercentEl.classList.contains('trend-increasing')) {
                    originalSummaryValues.trendColorClass = 'trend-increasing';
                } else if (trendPercentEl.classList.contains('trend-decreasing')) {
                    originalSummaryValues.trendColorClass = 'trend-decreasing';
                } else if (trendPercentEl.classList.contains('trend-stable')) {
                    originalSummaryValues.trendColorClass = 'trend-stable';
                }
            }
            
            initChart();
            populateCategoryFilter();
            // Update chart to show default view (Total Cost)
            updateChart();
            
            // Initially hide resources beyond top 20 in "Top 20 Resources" section only
            // Don't hide cards in "Top 20 Cost Increase Drivers" section (they use .increased-cost-card class)
            const resourceCards = document.querySelectorAll('.resource-card:not(.increased-cost-card)');
            resourceCards.forEach((card, index) => {
                if (index >= 20) {
                    card.classList.add('filtered-out');
                }
            });
        });
        
        function initChart() {
            const ctx = document.getElementById('costChart');
            if (!ctx) {
                console.error('Chart canvas element not found');
                return;
            }
            
            // Initialize with empty data - updateChart() will populate it
            costChart = new Chart(ctx.getContext('2d'), {
                type: 'bar',
                data: {
                    labels: chartLabels,
                    datasets: []
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
                                minRotation: 45,
                                autoSkip: false,
                                maxTicksLimit: null
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
        
        // Helper function to calculate filtered total for a day (reused by total view and Other calculation)
        function getFilteredDayTotal(day, categoryFilter, selectedSubscriptions) {
            if (!day) return 0;
            let dayTotal = 0;
            if (categoryFilter === 'all') {
                // Sum all categories for selected subscriptions
                if (day.categories && typeof day.categories === 'object') {
                    Object.entries(day.categories).forEach(([cat, catData]) => {
                        if (catData && typeof catData === 'object') {
                            if (selectedSubscriptions.size === 0) {
                                dayTotal += (catData.total || 0);
                            } else {
                                selectedSubscriptions.forEach(sub => {
                                    dayTotal += (catData.bySubscription && catData.bySubscription[sub]) || 0;
                                });
                            }
                        }
                    });
                }
            } else {
                // Single category
                const catData = day.categories && day.categories[categoryFilter];
                if (catData && typeof catData === 'object') {
                    if (selectedSubscriptions.size === 0) {
                        dayTotal = catData.total || 0;
                    } else {
                        selectedSubscriptions.forEach(sub => {
                            dayTotal += (catData.bySubscription && catData.bySubscription[sub]) || 0;
                        });
                    }
                }
            }
            return dayTotal || 0; // Ensure we always return a number
        }
        
        function updateChart() {
            // Ensure chart is initialized before updating
            if (!costChart) {
                console.warn('Chart not initialized yet, skipping update');
                return;
            }
            
            // Ensure rawDailyData is available
            if (!rawDailyData || !Array.isArray(rawDailyData) || rawDailyData.length === 0) {
                console.warn('rawDailyData not available or empty, skipping chart update');
                return;
            }
            
            const view = currentView;
            const categoryFilter = currentCategoryFilter;
            const stacked = view !== 'total';
            
            costChart.options.scales.x.stacked = stacked;
            costChart.options.scales.y.stacked = stacked;
            // Ensure all labels are shown (no auto-skip)
            costChart.options.scales.x.ticks.autoSkip = false;
            costChart.options.scales.x.ticks.maxTicksLimit = null;
            
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
            
            costChart.data.labels = chartLabels;
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
            
            // Calculate totals for each key based on current filters (for top 15 selection)
            const keyTotals = [];
            allKeys.forEach(key => {
                // Skip if subscription filter active and this is subscriptions dimension
                if (dimension === 'subscriptions' && selectedSubscriptions.size > 0 && !selectedSubscriptions.has(key)) {
                    return;
                }
                
                // Skip if category filter active and this is categories dimension (key IS the category)
                if (dimension === 'categories' && categoryFilter !== 'all' && key !== categoryFilter) {
                    return;
                }
                
                let totalCost = 0;
                rawDailyData.forEach((day, dayIndex) => {
                    const dimData = day[dimension] && day[dimension][key];
                    if (!dimData) return;
                    
                    let value = 0;
                    
                    // Apply filters based on dimension type
                    if (dimension === 'categories') {
                        // When dimension is categories, key IS the category name
                        // Apply subscription filter only
                        if (selectedSubscriptions.size === 0) {
                            value = dimData.total || 0;
                        } else {
                            selectedSubscriptions.forEach(sub => {
                                value += (dimData.bySubscription && dimData.bySubscription[sub]) || 0;
                            });
                        }
                    } else if (dimension === 'subscriptions') {
                        // When dimension is subscriptions, apply category filter
                        if (categoryFilter === 'all') {
                            value = dimData.total || 0;
                        } else {
                            value = (dimData.byCategory && dimData.byCategory[categoryFilter]) || 0;
                        }
                    } else {
                        // For meters and resources, apply both filters
                        if (categoryFilter === 'all') {
                            // No category filter - use total and apply subscription filter
                            if (selectedSubscriptions.size === 0) {
                                value = dimData.total || 0;
                            } else {
                                selectedSubscriptions.forEach(sub => {
                                    value += (dimData.bySubscription && dimData.bySubscription[sub]) || 0;
                                });
                            }
                        } else {
                            // Category filter active - get value for this category
                            const catValue = (dimData.byCategory && dimData.byCategory[categoryFilter]) || 0;
                            if (catValue > 0) {
                                // This meter/resource has costs in the filtered category
                                // For category-filtered values, we can't break down by subscription
                                // So we use the category value proportionally based on subscription filter
                                if (selectedSubscriptions.size === 0) {
                                    value = catValue;
                                } else {
                                    // Estimate: use category value proportionally based on subscription share of total
                                    const totalValue = dimData.total || 0;
                                    if (totalValue > 0) {
                                        let subscriptionShare = 0;
                                        selectedSubscriptions.forEach(sub => {
                                            subscriptionShare += (dimData.bySubscription && dimData.bySubscription[sub]) || 0;
                                        });
                                        // Apply the same proportion to the category value
                                        value = catValue * (subscriptionShare / totalValue);
                                    } else {
                                        value = 0;
                                    }
                                }
                            }
                        }
                    }
                    
                    totalCost += value;
                });
                
                if (totalCost > 0) {
                    keyTotals.push({ key: key, totalCost: totalCost });
                }
            });
            
            // Sort by total cost and get top 15 for meter/resource views
            keyTotals.sort((a, b) => b.totalCost - a.totalCost);
            const topKeys = includeOther ? keyTotals.slice(0, 15).map(item => item.key) : keyTotals.map(item => item.key);
            
            const datasets = [];
            let colorIndex = 0;
            
            topKeys.forEach(key => {
                const data = rawDailyData.map((day, dayIndex) => {
                    const dimData = day[dimension] && day[dimension][key];
                    if (!dimData) return 0;
                    
                    let value = 0;
                    
                    // Apply filters based on dimension type
                    if (dimension === 'categories') {
                        // When dimension is categories, key IS the category name
                        // Apply subscription filter only
                        if (selectedSubscriptions.size === 0) {
                            value = dimData.total || 0;
                        } else {
                            selectedSubscriptions.forEach(sub => {
                                value += (dimData.bySubscription && dimData.bySubscription[sub]) || 0;
                            });
                        }
                    } else if (dimension === 'subscriptions') {
                        // When dimension is subscriptions, apply category filter
                        if (categoryFilter === 'all') {
                            value = dimData.total || 0;
                        } else {
                            value = (dimData.byCategory && dimData.byCategory[categoryFilter]) || 0;
                        }
                    } else {
                        // For meters and resources, apply both filters
                        if (categoryFilter === 'all') {
                            // No category filter - use total and apply subscription filter
                            if (selectedSubscriptions.size === 0) {
                                value = dimData.total || 0;
                            } else {
                                selectedSubscriptions.forEach(sub => {
                                    value += (dimData.bySubscription && dimData.bySubscription[sub]) || 0;
                                });
                            }
                        } else {
                            // Category filter active - get value for this category
                            const catValue = (dimData.byCategory && dimData.byCategory[categoryFilter]) || 0;
                            if (catValue > 0) {
                                // This meter/resource has costs in the filtered category
                                // For category-filtered values, we can't break down by subscription
                                // So we use the category value proportionally based on subscription filter
                                if (selectedSubscriptions.size === 0) {
                                    value = catValue;
                                } else {
                                    // Estimate: use category value proportionally based on subscription share of total
                                    const totalValue = dimData.total || 0;
                                    if (totalValue > 0) {
                                        let subscriptionShare = 0;
                                        selectedSubscriptions.forEach(sub => {
                                            subscriptionShare += (dimData.bySubscription && dimData.bySubscription[sub]) || 0;
                                        });
                                        // Apply the same proportion to the category value
                                        value = catValue * (subscriptionShare / totalValue);
                                    } else {
                                        value = 0;
                                    }
                                }
                            }
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
                    // Use the filtered day total (already calculated based on filters)
                    const dayTotal = getFilteredDayTotal(day, categoryFilter, selectedSubscriptions);
                    
                    // Calculate the sum of ALL resources/meters for this day that match the filter
                    // (not just the top 15, to correctly calculate "Other")
                    let allFilteredResourcesTotal = 0;
                    if (dimension === 'resources' || dimension === 'meters') {
                        Object.keys(day[dimension] || {}).forEach(key => {
                            if (key === 'Other') return;
                            const dimData = day[dimension][key];
                            if (!dimData) return;
                            
                            let value = 0;
                            if (categoryFilter === 'all') {
                                if (selectedSubscriptions.size === 0) {
                                    value = dimData.total || 0;
                                } else {
                                    selectedSubscriptions.forEach(sub => {
                                        value += (dimData.bySubscription && dimData.bySubscription[sub]) || 0;
                                    });
                                }
                            } else {
                                const catValue = (dimData.byCategory && dimData.byCategory[categoryFilter]) || 0;
                                if (catValue > 0) {
                                    if (selectedSubscriptions.size === 0) {
                                        value = catValue;
                                    } else {
                                        const totalValue = dimData.total || 0;
                                        if (totalValue > 0) {
                                            let subscriptionShare = 0;
                                            selectedSubscriptions.forEach(sub => {
                                                subscriptionShare += (dimData.bySubscription && dimData.bySubscription[sub]) || 0;
                                            });
                                            value = catValue * (subscriptionShare / totalValue);
                                        }
                                    }
                                }
                            }
                            allFilteredResourcesTotal += value;
                        });
                    }
                    
                    // Subtract the top 15 datasets (which are already filtered)
                    const knownTotal = datasets.reduce((sum, ds) => sum + (ds.data[dayIndex] || 0), 0);
                    
                    // "Other" = all filtered resources - top 15 filtered resources
                    return Math.max(0, allFilteredResourcesTotal - knownTotal);
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
            
            // Filter category sections, subscription sections, and resource sections
            filterCategorySections();
            
            // Apply search filter to all sections (if search input exists)
            if (document.getElementById('resourceSearch')) {
                filterResources();
            } else {
                // If no search input, still recalculate top resources with subscription filter
                recalculateTopResources();
            }
            
            // Update summary cards with filtered data
            updateSummaryCards();
            
            // Update chart with new subscription filter
            updateChart();
        }
        
        function updateSummaryCards() {
            const totalCostLocalEl = document.getElementById('summary-total-cost-local');
            const totalCostUsdEl = document.getElementById('summary-total-cost-usd');
            const subscriptionCountEl = document.getElementById('summary-subscription-count');
            const categoryCountEl = document.getElementById('summary-category-count');
            const trendPercentEl = document.getElementById('summary-trend-percent');
            
            if (selectedSubscriptions.size === 0) {
                // No filter - restore original values
                if (totalCostLocalEl && originalSummaryValues.totalCostLocal !== null) {
                    totalCostLocalEl.textContent = originalSummaryValues.totalCostLocal;
                }
                if (totalCostUsdEl && originalSummaryValues.totalCostUSD !== null) {
                    totalCostUsdEl.textContent = originalSummaryValues.totalCostUSD;
                }
                if (subscriptionCountEl && originalSummaryValues.subscriptionCount !== null) {
                    subscriptionCountEl.textContent = originalSummaryValues.subscriptionCount;
                }
                if (categoryCountEl && originalSummaryValues.categoryCount !== null) {
                    categoryCountEl.textContent = originalSummaryValues.categoryCount;
                }
                if (trendPercentEl && originalSummaryValues.trendPercent !== null) {
                    trendPercentEl.innerHTML = originalSummaryValues.trendPercent; // Restore HTML to preserve arrow entity
                    // Restore color class
                    trendPercentEl.classList.remove('trend-increasing', 'trend-decreasing', 'trend-stable');
                    if (originalSummaryValues.trendColorClass) {
                        trendPercentEl.classList.add(originalSummaryValues.trendColorClass);
                    }
                }
                return;
            }
            
            // Calculate filtered totals from rawDailyData
            let filteredTotalCostLocal = 0;
            let filteredTotalCostUSD = 0;
            const filteredSubscriptions = new Set();
            const filteredCategories = new Set();
            
            rawDailyData.forEach(day => {
                // Sum costs for selected subscriptions
                Object.entries(day.subscriptions || {}).forEach(([subName, subData]) => {
                    if (selectedSubscriptions.has(subName)) {
                        const subCostLocal = subData.total || 0;
                        filteredTotalCostLocal += subCostLocal;
                        
                        // Calculate USD proportionally based on the day's total
                        let subCostUSD = 0;
                        if (day.totalCostLocal > 0 && day.totalCostUSD !== undefined) {
                            subCostUSD = (day.totalCostUSD / day.totalCostLocal) * subCostLocal;
                        }
                        filteredTotalCostUSD += subCostUSD;
                        filteredSubscriptions.add(subName);
                        
                        // Get categories for this subscription
                        Object.keys(subData.byCategory || {}).forEach(cat => {
                            filteredCategories.add(cat);
                        });
                    }
                });
            });
            
            // Update summary card values (rounded to nearest integer with thousand separator)
            if (totalCostLocalEl) {
                totalCostLocalEl.textContent = formatNumberNoDecimals(filteredTotalCostLocal);
            }
            if (totalCostUsdEl) {
                totalCostUsdEl.textContent = formatNumberNoDecimals(filteredTotalCostUSD);
            }
            if (subscriptionCountEl) {
                subscriptionCountEl.textContent = filteredSubscriptions.size;
            }
            if (categoryCountEl) {
                categoryCountEl.textContent = filteredCategories.size;
            }
            
            // Calculate trend for filtered data
            // Remove highest and lowest day from each half to reduce outlier impact
            if (rawDailyData.length >= 4) {  // Need at least 4 days (2 per half after removing outliers)
                const totalDays = rawDailyData.length;
                const daysPerHalf = Math.floor(totalDays / 2);
                
                // If odd number of days, exclude the middle day(s) to ensure equal comparison
                // First half: first N days
                // Second half: last N days
                
                // Build first half data with costs
                const firstHalfDays = [];
                for (let i = 0; i < daysPerHalf; i++) {
                    const day = rawDailyData[i];
                    let dayCost = 0;
                    Object.entries(day.subscriptions || {}).forEach(([subName, subData]) => {
                        if (selectedSubscriptions.has(subName)) {
                            dayCost += subData.total || 0;
                        }
                    });
                    firstHalfDays.push({ index: i, cost: dayCost });
                }
                
                // Build second half data with costs
                const secondHalfDays = [];
                for (let i = totalDays - daysPerHalf; i < totalDays; i++) {
                    const day = rawDailyData[i];
                    let dayCost = 0;
                    Object.entries(day.subscriptions || {}).forEach(([subName, subData]) => {
                        if (selectedSubscriptions.has(subName)) {
                            dayCost += subData.total || 0;
                        }
                    });
                    secondHalfDays.push({ index: i, cost: dayCost });
                }
                
                // Remove highest and lowest day from first half
                let firstHalf = 0;
                if (firstHalfDays.length >= 3) {
                    firstHalfDays.sort((a, b) => a.cost - b.cost);  // Sort by cost ascending
                    const firstHalfFiltered = firstHalfDays.slice(1, -1);  // Remove first (lowest) and last (highest)
                    firstHalf = firstHalfFiltered.reduce((sum, day) => sum + day.cost, 0);
                } else {
                    firstHalf = firstHalfDays.reduce((sum, day) => sum + day.cost, 0);
                }
                
                // Remove highest and lowest day from second half
                let secondHalf = 0;
                if (secondHalfDays.length >= 3) {
                    secondHalfDays.sort((a, b) => a.cost - b.cost);  // Sort by cost ascending
                    const secondHalfFiltered = secondHalfDays.slice(1, -1);  // Remove first (lowest) and last (highest)
                    secondHalf = secondHalfFiltered.reduce((sum, day) => sum + day.cost, 0);
                } else {
                    secondHalf = secondHalfDays.reduce((sum, day) => sum + day.cost, 0);
                }
                
                let trendPercent = 0;
                let trendDirection = 'neutral';
                if (firstHalf > 0) {
                    // Calculate percentage change: ((new - old) / old) * 100
                    trendPercent = ((secondHalf - firstHalf) / firstHalf) * 100;
                    trendDirection = trendPercent > 0 ? 'up' : (trendPercent < 0 ? 'down' : 'neutral');
                }
                
                const trendPercentEl = document.getElementById('summary-trend-percent');
                
                if (trendPercentEl) {
                    // Determine arrow and color class
                    let arrow = '&#8594;'; // Default: stable
                    let colorClass = 'trend-stable';
                    
                    if (trendDirection === 'up') {
                        arrow = '&#8593;';
                        colorClass = 'trend-increasing';
                    } else if (trendDirection === 'down') {
                        arrow = '&#8595;';
                        colorClass = 'trend-decreasing';
                    }
                    
                    // Update content with arrow (using innerHTML to render HTML entities)
                    trendPercentEl.innerHTML = arrow + ' ' + Math.abs(trendPercent).toFixed(1) + '%';
                    
                    // Update color class
                    trendPercentEl.classList.remove('trend-increasing', 'trend-decreasing', 'trend-stable');
                    trendPercentEl.classList.add(colorClass);
                }
            }
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
            // Get search text for combined filtering
            const searchInput = document.getElementById('resourceSearch');
            const searchText = searchInput ? searchInput.value.toLowerCase().trim() : '';
            
            // Filter subscription cards first (for subscription drilldown section)
            document.querySelectorAll('.subscription-card').forEach(subCard => {
                const subscription = subCard.getAttribute('data-subscription');
                const matchesSubscription = selectedSubscriptions.size === 0 || 
                    (subscription && selectedSubscriptions.has(subscription));
                const cardText = subCard.textContent.toLowerCase();
                const matchesSearch = searchText === '' || cardText.includes(searchText);
                
                subCard.classList.toggle('filtered-out', !matchesSubscription || !matchesSearch);
            });
            
            // Filter resource rows within meter sections by subscription and search
            document.querySelectorAll('.resource-table tbody tr').forEach(row => {
                const subscription = row.getAttribute('data-subscription');
                const matchesSubscription = selectedSubscriptions.size === 0 || 
                    (subscription && selectedSubscriptions.has(subscription));
                const rowText = row.textContent.toLowerCase();
                const matchesSearch = searchText === '' || rowText.includes(searchText);
                
                row.classList.toggle('filtered-out', !matchesSubscription || !matchesSearch);
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
            
            // Update visibility of category cards based on visible subcategories (but not subscription cards or resource cards)
            document.querySelectorAll('.category-card:not(.subscription-card):not(.resource-card)').forEach(cat => {
                const visibleSubcats = cat.querySelectorAll('.subcategory-drilldown:not(.filtered-out)');
                const totalSubcats = cat.querySelectorAll('.subcategory-drilldown');
                if (totalSubcats.length > 0 && selectedSubscriptions.size > 0) {
                    cat.classList.toggle('filtered-out', visibleSubcats.length === 0);
                } else {
                    cat.classList.remove('filtered-out');
                }
            });
        }
        
        function recalculateTopResources() {
            try {
                // Safety check: ensure DOM is ready
                const searchInput = document.getElementById('resourceSearch');
                if (!searchInput) {
                    console.warn('resourceSearch element not found, skipping recalculateTopResources');
                    return;
                }
                
                // Find the Top 20 Resources section by finding the expandable that contains resource-card elements (but not increased-cost-card)
                const allExpandables = document.querySelectorAll('.expandable__content');
                let resourcesContainer = null;
                for (const container of allExpandables) {
                    if (container.querySelector('.resource-card:not(.increased-cost-card)')) {
                        resourcesContainer = container;
                        break;
                    }
                }
                
                if (!resourcesContainer) {
                    console.warn('resourcesContainer not found, skipping recalculateTopResources');
                    return;
                }
                
                // Check if rawDailyData is available
                if (typeof rawDailyData === 'undefined' || !rawDailyData || !Array.isArray(rawDailyData)) {
                    console.warn('rawDailyData not available, skipping recalculateTopResources');
                    return;
                }
                
                // Check if resource cards exist (only in Top 20 Resources section, not Cost Increase Drivers)
                const resourceCards = resourcesContainer.querySelectorAll('.resource-card:not(.increased-cost-card)');
                if (resourceCards.length === 0) {
                    console.warn('No resource cards found, skipping recalculateTopResources');
                    return;
                }
                
                // Calculate filtered costs for each resource from rawDailyData
                const resourceCosts = new Map();
                
                rawDailyData.forEach(day => {
                    if (day && day.resources) {
                        Object.entries(day.resources).forEach(([resName, resData]) => {
                            if (resName === 'Other') return; // Skip "Other"
                            
                            if (!resourceCosts.has(resName)) {
                                resourceCosts.set(resName, 0);
                            }
                            
                            // Calculate cost based on subscription filter
                            if (selectedSubscriptions.size === 0) {
                                // No subscription filter - use total
                                resourceCosts.set(resName, resourceCosts.get(resName) + (resData.total || 0));
                            } else {
                                // Sum costs for selected subscriptions only
                                if (resData.bySubscription) {
                                    let dayCost = 0;
                                    selectedSubscriptions.forEach(sub => {
                                        dayCost += (resData.bySubscription[sub] || 0);
                                    });
                                    resourceCosts.set(resName, resourceCosts.get(resName) + dayCost);
                                }
                            }
                        });
                    }
                });
                
                // Get all resource cards and calculate their filtered costs
                const resourceCardsArray = Array.from(resourceCards);
                
                const cardsWithCosts = resourceCardsArray.map(card => {
                    const resName = card.querySelector('.category-title')?.textContent?.trim();
                    const subscription = card.getAttribute('data-subscription');
                    const filteredCost = resName ? (resourceCosts.get(resName) || 0) : 0;
                    
                    return {
                        card: card,
                        name: resName,
                        subscription: subscription,
                        filteredCost: filteredCost
                    };
                });
                
                // Sort by filtered cost (descending)
                cardsWithCosts.sort((a, b) => b.filteredCost - a.filteredCost);
                
                const searchText = searchInput.value.toLowerCase();
                
                // Remove all resource cards from DOM (temporarily)
                const cardsToReorder = cardsWithCosts.map(item => item.card);
                cardsToReorder.forEach(card => card.remove());
                
                // Filter by subscription first to get resources matching the subscription filter
                const subscriptionFiltered = cardsWithCosts.filter(item => {
                    return selectedSubscriptions.size === 0 || 
                        (item.subscription && selectedSubscriptions.has(item.subscription));
                });
                
                // Get top 20 most costly resources that match subscription filter
                const top20BySubscription = subscriptionFiltered.slice(0, 20);
                
                // Add all cards back in sorted order
                // First, add the top 20 matching subscription filter (they may be filtered by search)
                top20BySubscription.forEach((item) => {
                    const card = item.card;
                    const text = card.textContent.toLowerCase();
                    const matchesSearch = searchText === '' || text.includes(searchText);
                    
                    if (matchesSearch) {
                        card.classList.remove('filtered-out');
                    } else {
                        card.classList.add('filtered-out');
                    }
                    resourcesContainer.appendChild(card);
                });
                
                // Add remaining resources that match subscription (beyond top 20) but keep them hidden
                subscriptionFiltered.slice(20).forEach(item => {
                    const card = item.card;
                    card.classList.add('filtered-out');
                    resourcesContainer.appendChild(card);
                });
                
                // Add resources that don't match subscription filter (keep hidden)
                cardsWithCosts.forEach(item => {
                    const matchesSubscription = selectedSubscriptions.size === 0 || 
                        (item.subscription && selectedSubscriptions.has(item.subscription));
                    if (!matchesSubscription) {
                        const card = item.card;
                        card.classList.add('filtered-out');
                        if (!resourcesContainer.contains(card)) {
                            resourcesContainer.appendChild(card);
                        }
                    }
                });
                
                // Update section title - always show "Top 20" (showing the 20 most costly based on current filter)
                const topResourcesSection = resourcesContainer.closest('.section');
                if (topResourcesSection) {
                    const sectionHeader = topResourcesSection.querySelector('h2');
                    if (sectionHeader && sectionHeader.textContent.includes('Top')) {
                        const arrow = sectionHeader.querySelector('.expand-arrow')?.outerHTML || '<span class="expand-arrow">&#9654;</span>';
                        sectionHeader.innerHTML = arrow + ' Top 20 Resources by Cost';
                    }
                }
            } catch (error) {
                console.error('Error in recalculateTopResources:', error);
            }
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
            // Find the closest expandable parent
            const expandable = element.closest('.expandable');
            if (expandable) {
                expandable.classList.toggle('expandable--collapsed');
                // Update expand arrow - ▶ when collapsed (pointing right = expand), ▼ when expanded (pointing down = collapse)
                const arrow = element.querySelector('.expand-arrow');
                if (arrow) {
                    if (expandable.classList.contains('expandable--collapsed')) {
                        arrow.textContent = '\u25B6'; // ▶ (collapsed - click to expand)
                    } else {
                        arrow.textContent = '\u25BC'; // ▼ (expanded - click to collapse)
                    }
                }
            }
        }
        
        function toggleSubscriptionFilter(element) {
            // Toggle the subscription filter content visibility
            const filterContent = element.nextElementSibling;
            if (filterContent && filterContent.classList.contains('subscription-filter-content')) {
                filterContent.classList.toggle('show');
                // Update expand arrow
                const arrow = element.querySelector('.expand-arrow');
                if (arrow) {
                    if (filterContent.classList.contains('show')) {
                        arrow.textContent = '\u25BC'; // ▼
                    } else {
                        arrow.textContent = '\u25B6'; // ▶
                    }
                }
            }
        }
        
        function toggleCategory(element, event) {
            // Stop event propagation to prevent parent category cards from toggling
            if (event) {
                event.stopPropagation();
            }
            const categoryCard = element.closest('.category-card');
            if (categoryCard && categoryCard.classList.contains('category-card')) {
                const wasExpanded = categoryCard.classList.contains('expanded');
                categoryCard.classList.toggle('expanded');
                const isNowExpanded = categoryCard.classList.contains('expanded');
                
                // Force update display style to ensure CSS is applied
                const categoryContent = categoryCard.querySelector('.category-content');
                if (categoryContent) {
                    if (isNowExpanded) {
                        categoryContent.style.setProperty('display', 'block', 'important');
                        categoryContent.style.setProperty('visibility', 'visible', 'important');
                        categoryContent.style.setProperty('height', 'auto', 'important');
                        categoryContent.style.setProperty('overflow', 'visible', 'important');
                    } else {
                        categoryContent.style.setProperty('display', 'none', 'important');
                        categoryContent.style.setProperty('visibility', 'hidden', 'important');
                        categoryContent.style.setProperty('height', '0', 'important');
                        categoryContent.style.setProperty('overflow', 'hidden', 'important');
                    }
                }
                
                // Update expand arrow
                const arrow = element.querySelector('.expand-arrow');
                if (arrow) {
                    if (isNowExpanded) {
                        arrow.textContent = '\u25BC'; // ▼
                    } else {
                        arrow.textContent = '\u25B6'; // ▶
                    }
                }
            }
        }
        
        function toggleSubCategory(element, event) {
            if (event) {
                event.stopPropagation();
            }

            const subcategoryDrilldown = element.closest('.subcategory-drilldown');
            if (subcategoryDrilldown) {
                const wasExpanded = subcategoryDrilldown.classList.contains('expanded');
                
                subcategoryDrilldown.classList.toggle('expanded');
                const isNowExpanded = subcategoryDrilldown.classList.contains('expanded');
                
                // Visual feedback removed per user request

                // Force update display style to ensure CSS is applied - use setProperty for !important
                const subcategoryContent = subcategoryDrilldown.querySelector('.subcategory-content');
                if (subcategoryContent) {
                    if (isNowExpanded) {
                        subcategoryContent.style.setProperty('display', 'block', 'important');
                        subcategoryContent.style.setProperty('visibility', 'visible', 'important');
                        subcategoryContent.style.setProperty('height', 'auto', 'important');
                        subcategoryContent.style.setProperty('overflow', 'visible', 'important');
                        subcategoryContent.style.setProperty('max-height', 'none', 'important');
                        subcategoryContent.style.setProperty('opacity', '1', 'important');
                    } else {
                        subcategoryContent.style.setProperty('display', 'none', 'important');
                        subcategoryContent.style.setProperty('visibility', 'hidden', 'important');
                        subcategoryContent.style.setProperty('height', '0', 'important');
                        subcategoryContent.style.setProperty('overflow', 'hidden', 'important');
                        subcategoryContent.style.setProperty('max-height', '0', 'important');
                        subcategoryContent.style.setProperty('opacity', '0', 'important');
                    }
                }
                
                // Update expand arrow
                const arrow = element.querySelector('.expand-arrow');
                if (arrow) {
                    if (isNowExpanded) {
                        arrow.textContent = '\u25BC'; // ▼
                    } else {
                        arrow.textContent = '\u25B6'; // ▶
                    }
                }
            }
        }
        
        function toggleMeter(element) {
            const meterCard = element.closest('.meter-card');
            if (meterCard && meterCard.classList.contains('meter-card')) {
                meterCard.classList.toggle('expanded');
                // Update expand arrow rotation
                const arrow = element.querySelector('.expand-arrow');
                if (arrow) {
                    if (meterCard.classList.contains('expanded')) {
                        arrow.textContent = '\u25BC'; // ▼
                    } else {
                        arrow.textContent = '\u25B6'; // ▶
                    }
                }
            }
        }
        
        function filterResources() {
            const searchInput = document.getElementById('resourceSearch');
            const searchText = searchInput ? searchInput.value.toLowerCase().trim() : '';
            
            // Filter subscription cards (Cost by Subscription section) - respect both subscription and search filters
            document.querySelectorAll('.subscription-card').forEach(card => {
                const subscription = card.getAttribute('data-subscription');
                const matchesSubscription = selectedSubscriptions.size === 0 || 
                    (subscription && selectedSubscriptions.has(subscription));
                const cardText = card.textContent.toLowerCase();
                const matchesSearch = searchText === '' || cardText.includes(searchText);
                
                card.classList.toggle('filtered-out', !matchesSubscription || !matchesSearch);
            });
            
            // Filter category cards (Cost by Meter Category section) - exclude subscription-card and resource-card
            document.querySelectorAll('.category-card:not(.subscription-card):not(.resource-card)').forEach(card => {
                const cardText = card.textContent.toLowerCase();
                const matchesSearch = searchText === '' || cardText.includes(searchText);
                if (matchesSearch) {
                    card.classList.remove('filtered-out');
                } else {
                    card.classList.add('filtered-out');
                }
            });
            
            // Filter subcategory drilldowns (nested in category cards)
            document.querySelectorAll('.subcategory-drilldown').forEach(subcat => {
                const subcatText = subcat.textContent.toLowerCase();
                const matchesSearch = searchText === '' || subcatText.includes(searchText);
                if (matchesSearch) {
                    subcat.classList.remove('filtered-out');
                } else {
                    subcat.classList.add('filtered-out');
                }
            });
            
            // Filter meter cards (nested in categories/subcategories)
            document.querySelectorAll('.meter-card').forEach(card => {
                const cardText = card.textContent.toLowerCase();
                const matchesSearch = searchText === '' || cardText.includes(searchText);
                if (matchesSearch) {
                    card.classList.remove('filtered-out');
                } else {
                    card.classList.add('filtered-out');
                }
            });
            
            // Filter resource rows in meter sections - respect both subscription and search filters
            document.querySelectorAll('.resource-table tbody tr').forEach(row => {
                const subscription = row.getAttribute('data-subscription');
                const matchesSubscription = selectedSubscriptions.size === 0 || 
                    (subscription && selectedSubscriptions.has(subscription));
                const rowText = row.textContent.toLowerCase();
                const matchesSearch = searchText === '' || rowText.includes(searchText);
                
                row.classList.toggle('filtered-out', !matchesSubscription || !matchesSearch);
            });
            
            // Update visibility of parent containers based on visible children
            // Update meter cards based on visible resource rows
            document.querySelectorAll('.meter-card').forEach(card => {
                const visibleRows = card.querySelectorAll('.resource-table tbody tr:not(.filtered-out)');
                const totalRows = card.querySelectorAll('.resource-table tbody tr');
                if (totalRows.length > 0 && searchText !== '') {
                    const cardMatches = card.textContent.toLowerCase().includes(searchText);
                    card.classList.toggle('filtered-out', !cardMatches && visibleRows.length === 0);
                }
            });
            
            // Update subcategory drilldowns based on visible meters
            document.querySelectorAll('.subcategory-drilldown').forEach(subcat => {
                const visibleMeters = subcat.querySelectorAll('.meter-card:not(.filtered-out)');
                const totalMeters = subcat.querySelectorAll('.meter-card');
                if (totalMeters.length > 0 && searchText !== '') {
                    const subcatMatches = subcat.textContent.toLowerCase().includes(searchText);
                    subcat.classList.toggle('filtered-out', !subcatMatches && visibleMeters.length === 0);
                }
            });
            
            // Update category cards based on visible subcategories
            document.querySelectorAll('.category-card:not(.subscription-card):not(.resource-card)').forEach(cat => {
                const visibleSubcats = cat.querySelectorAll('.subcategory-drilldown:not(.filtered-out)');
                const totalSubcats = cat.querySelectorAll('.subcategory-drilldown');
                if (totalSubcats.length > 0 && searchText !== '') {
                    const catMatches = cat.textContent.toLowerCase().includes(searchText);
                    cat.classList.toggle('filtered-out', !catMatches && visibleSubcats.length === 0);
                }
            });
            
            // Recalculate and reorder Top 20 resources (this also applies search filter to resource cards)
            if (document.getElementById('resourceSearch')) {
                recalculateTopResources();
            }
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
            CategoryCount = $byMeterCategory.Count
            MeterCategoryCount = $byMeterCategory.Count
            ResourceCount = $topResources.Count
            TrendPercent = $trendPercent
            TrendDirection = $trendDirection
            DaysIncluded = $CostTrackingData.DaysToInclude
        }
    }
    catch {
        Write-Error "Failed to write Cost Tracking report: $_"
        throw
    }
}
