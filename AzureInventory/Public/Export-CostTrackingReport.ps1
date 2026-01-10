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
    
    # Helper function for robust Date parsing (handles DateTime objects and /Date(ms)/ format strings)
    function Get-DateObj {
        param($d)
        if ($d -is [DateTime]) { return $d }
        
        # "/Date(1767254991215)/" or "\/Date(1767)\/"
        $s = [string]$d
        if ($s -match 'Date\((\d+)\)') {
            $ms = [long]$matches[1]
            return [DateTimeOffset]::FromUnixTimeMilliseconds($ms).UtcDateTime
        }
        
        # Fallback if it's already epoch ms as string
        if ($s -match '^\d+$') {
            return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$s).UtcDateTime
        }
        
        throw "Unparseable Date: $s"
    }
    
    # Build canonical factRows from RawData (one row per cost record)
    # Use List for O(n) performance instead of array += which is O(n²)
    $factRows = [System.Collections.Generic.List[object]]::new()
    if ($rawData.Count -gt 0) {
        foreach ($row in $rawData) {
            # Ensure we have required fields (only Date is required, ResourceId is optional)
            if (-not $row.Date) { continue }
            
            # Parse date robustly
            try {
                $dateObj = Get-DateObj -d $row.Date
            } catch {
                Write-Warning "Failed to parse date for row: $($row.Date). Skipping."
                continue
            }
            
            $dateKeyStr = $dateObj.ToString("yyyy-MM-dd")
            
            # Precompute resourceKey (canonical key for resources)
            $resourceId = if ($row.ResourceId) { $row.ResourceId } else { "" }
            $resourceKey = if ($resourceId -and $resourceId.Trim() -ne "") {
                $resourceId
            } else {
                $subId = if ($row.SubscriptionId) { $row.SubscriptionId } else { "" }
                $rg = if ($row.ResourceGroup) { $row.ResourceGroup } else { "" }
                $resName = if ($row.ResourceName) { $row.ResourceName } else { "noresource" }
                "sub:" + $subId + "|rg:" + $rg + "|res:" + $resName
            }
            
            # Precompute subscriptionKey (ID-first: use SubscriptionId as key)
            $subscriptionKey = if ($row.SubscriptionId) { $row.SubscriptionId } else { "" }
            
            # Precompute meterKey (normalized composite for Phase 4)
            $meterCategoryNorm = if ($row.MeterCategory) { ($row.MeterCategory).Trim().ToLower() } else { "unknown" }
            $meterSubcategoryNorm = if ($row.MeterSubCategory) { ($row.MeterSubCategory).Trim().ToLower() } else { "n/a" }
            $meterNameNorm = if ($row.Meter) { ($row.Meter).Trim().ToLower() } else { "unknown" }
            $meterKey = ($meterCategoryNorm + "|" + $meterSubcategoryNorm + "|" + $meterNameNorm) -replace '\s+', ' '
            
            $factRow = [PSCustomObject]@{
                day = $dateKeyStr
                dateKey = $dateKeyStr  # Precomputed
                subscriptionId = if ($row.SubscriptionId) { $row.SubscriptionId } else { "" }
                subscriptionName = if ($row.SubscriptionName) { $row.SubscriptionName } else { "Unknown" }
                subscriptionKey = $subscriptionKey  # Precomputed (ID-first)
                resourceId = $resourceId
                resourceName = if ($row.ResourceId) { 
                    if ($row.ResourceName) { $row.ResourceName } else { "" }
                } else { 
                    "(no resource)" 
                }
                resourceGroup = if ($row.ResourceGroup) { $row.ResourceGroup } else { "" }
                resourceKey = $resourceKey  # Precomputed
                meterCategory = if ($row.MeterCategory) { $row.MeterCategory } else { "Unknown" }
                meterSubcategory = if ($row.MeterSubCategory) { $row.MeterSubCategory } else { "N/A" }
                # Note: Property name is MeterSubCategory (capital C) as per Get-AzureCostData.ps1
                meterName = if ($row.Meter) { $row.Meter } else { "Unknown" }
                meterKey = $meterKey  # Precomputed (normalized, for Phase 4)
                # Keep full precision - round only at presentation layer
                costLocal = [double]$row.CostLocal
                costUSD = [double]$row.CostUSD
                currency = if ($row.Currency) { $row.Currency } else { $currency }
            }
            $factRows.Add($factRow)
        }
    }
    # Convert to array for JSON serialization
    $factRows = @($factRows)
    
    if ($rawData.Count -gt 0) {
        # Group by ResourceId and calculate totals
        # Performance: Use ArrayList instead of array += to avoid O(n²) behavior
        $resourceGroups = $rawData | Where-Object { $_.ResourceId -and -not [string]::IsNullOrWhiteSpace($_.ResourceId) } | Group-Object ResourceId
        $allResources = [System.Collections.ArrayList]::new()
        foreach ($resGroup in $resourceGroups) {
            $resItems = $resGroup.Group
            $resCostUSD = ($resItems | Measure-Object -Property CostUSD -Sum).Sum
            $resCostLocal = ($resItems | Measure-Object -Property CostLocal -Sum).Sum
            
            [void]$allResources.Add([PSCustomObject]@{
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
            })
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
        
        # Calculate costs per resource for each half (with outlier removal)
        # Performance: Use List instead of array += to avoid O(n²) behavior in nested loops
        foreach ($resName in $allResourceNamesInTrend) {
            $firstHalfCost = 0
            $secondHalfCost = 0
            
            # Collect costs for first half - use List for O(n) performance
            $firstHalfResourceCosts = [System.Collections.Generic.List[double]]::new()
            foreach ($day in $firstHalfDays) {
                if ($day.ByResource -and $day.ByResource.ContainsKey($resName)) {
                    $resData = $day.ByResource[$resName]
                    $cost = if ($resData.CostLocal) { $resData.CostLocal } else { 0 }
                    if ($cost -gt 0) {
                        $firstHalfResourceCosts.Add($cost)
                    }
                }
            }
            
            # Remove outliers from first half (same logic as total trend)
            if ($firstHalfResourceCosts.Count -ge 3) {
                $firstHalfSorted = $firstHalfResourceCosts | Sort-Object
                $firstHalfFiltered = $firstHalfSorted[1..($firstHalfSorted.Count - 2)]  # Remove first (lowest) and last (highest)
                $firstHalfCost = ($firstHalfFiltered | Measure-Object -Sum).Sum
            } else {
                $firstHalfCost = ($firstHalfResourceCosts | Measure-Object -Sum).Sum
            }
            
            # Collect costs for second half - use List for O(n) performance
            $secondHalfResourceCosts = [System.Collections.Generic.List[double]]::new()
            foreach ($day in $secondHalfDays) {
                if ($day.ByResource -and $day.ByResource.ContainsKey($resName)) {
                    $resData = $day.ByResource[$resName]
                    $cost = if ($resData.CostLocal) { $resData.CostLocal } else { 0 }
                    if ($cost -gt 0) {
                        $secondHalfResourceCosts.Add($cost)
                    }
                }
            }
            
            # Remove outliers from second half (same logic as total trend)
            if ($secondHalfResourceCosts.Count -ge 3) {
                $secondHalfSorted = $secondHalfResourceCosts | Sort-Object
                $secondHalfFiltered = $secondHalfSorted[1..($secondHalfSorted.Count - 2)]  # Remove first (lowest) and last (highest)
                $secondHalfCost = ($secondHalfFiltered | Measure-Object -Sum).Sum
            } else {
                $secondHalfCost = ($secondHalfResourceCosts | Measure-Object -Sum).Sum
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
    if (-not $bySubscription) { $bySubscription = @{} }
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
    
    # Phase 5.1.1: Prepare chartLabels only (legacy daily data structures removed - engine-only now)
    # Performance: Use ArrayList instead of array += to avoid O(n²) behavior
    $chartLabels = [System.Collections.ArrayList]::new()
    
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
    
    # Phase 5.1.1: Build chartLabels only (legacy daily data structures removed - engine-only now)
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
            [void]$chartLabels.Add($dayDateString)
        }
    }
    
    # Convert to array for JavaScript embedding
    $chartLabels = @($chartLabels)
    
    # Performance: Stopwatch measurements for performance profiling
    $swAll = [Diagnostics.Stopwatch]::StartNew()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    
    # Convert raw daily data to JSON for JavaScript
    # Serialize factRows for JavaScript embedding (robust: no escaping needed)
    $factRowsJson = "[]"
    if ($factRows.Count -gt 0) {
        $factRowsJson = $factRows | ConvertTo-Json -Depth 4 -Compress
        # Protect against </script> in JSON (edge case but zero cost)
        $factRowsJson = $factRowsJson -replace '</script', '<\/script'
        # No other escaping needed - we'll use <script type="application/json">
    }
    Write-Host ("[CostTracking] JSON factRows: {0}" -f $sw.Elapsed)
    
    # Phase 5.1.1: legacy daily data JSON generation removed - engine-only now
    
    # All known subscriptions for JS (HTML encoded to match checkboxes)
    $allSubscriptionNamesEncoded = $allSubscriptionNames | ForEach-Object { [System.Web.HttpUtility]::HtmlEncode($_) }
    if ($allSubscriptionNamesEncoded -and $allSubscriptionNamesEncoded.Count -gt 0) {
        $allSubscriptionsJson = $allSubscriptionNamesEncoded | ConvertTo-Json -Compress
        # Escape backslashes first, then single quotes for safe embedding in JavaScript string (using single quotes)
        $allSubscriptionsJson = $allSubscriptionsJson -replace '\\', '\\\\' -replace "'", "\'"
    } else {
        $allSubscriptionsJson = "[]"
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
    # Phase 5.1: datasetsBy* JSON generation removed - engine-only now
    
    # Convert chart labels to JSON
    $chartLabelsJson = ($chartLabels | ForEach-Object { "`"$_`"" }) -join ","
    
    # Build subscription options for filter (sorted by name)
    # Performance: Use StringBuilder for HTML concatenation to avoid O(n²) behavior
    $sw.Restart()
    $subscriptionOptionsHtml = [System.Text.StringBuilder]::new()
    $subscriptionsForFilter = $subscriptionsArray | Sort-Object { if ($_.Name) { $_.Name } else { "Unknown" } }
    foreach ($sub in $subscriptionsForFilter) {
        $subName = if ($sub.Name) { [System.Web.HttpUtility]::HtmlEncode($sub.Name) } else { "Unknown" }
        $subId = if ($sub.SubscriptionId) { $sub.SubscriptionId } else { "" }
        [void]$subscriptionOptionsHtml.Append(@"
                        <label class="subscription-checkbox">
                            <input type="checkbox" value="$subName" data-subid="$subId" onchange="filterBySubscription()">
                            <span>$subName</span>
                        </label>
"@)
    }
    
    # Generate subscription rows HTML
    # Performance: Use StringBuilder for HTML concatenation to avoid O(n²) behavior
    $subscriptionRowsHtml = [System.Text.StringBuilder]::new()
    foreach ($sub in $subscriptionsArray) {
        $subName = if ($sub.Name) { [System.Web.HttpUtility]::HtmlEncode($sub.Name) } else { "Unknown" }
        $subCostLocal = Format-NumberWithSeparator -Number $sub.CostLocal
        $subCostUSD = Format-NumberWithSeparator -Number $sub.CostUSD
        $subCount = $sub.ItemCount
        $subId = if ($sub.SubscriptionId) { $sub.SubscriptionId } else { "" }
        $subIdEncoded = if ($subId) { [System.Web.HttpUtility]::HtmlEncode($subId) } else { "" }
        $subNameEncodedForAttr = [System.Web.HttpUtility]::HtmlEncode($subName)
        [void]$subscriptionRowsHtml.Append(@"
                        <tr data-subscription-id="$subIdEncoded" data-subscription-name="$subNameEncodedForAttr" data-subscription="$subIdEncoded">
                            <td>$subName</td>
                            <td class="cost-value">$currency $subCostLocal</td>
                            <td class="cost-value">`$$subCostUSD</td>
                            <td>$subCount</td>
                        </tr>
"@)
    }
    
    # Performance: Pre-group rawData by ResourceId and ResourceName for O(1) lookup
    # This avoids O(n*m) Where-Object operations in loops (n=rawData.Count, m=resources.Count)
    # Build once, reuse in both TopResources and TopIncreasedResources sections
    $rawDataByResourceId = @{}
    $rawDataByResourceName = @{}
    if ($rawData.Count -gt 0) {
        foreach ($row in $rawData) {
            if ($row.ResourceId -and -not [string]::IsNullOrWhiteSpace($row.ResourceId)) {
                if (-not $rawDataByResourceId.ContainsKey($row.ResourceId)) {
                    $rawDataByResourceId[$row.ResourceId] = [System.Collections.Generic.List[object]]::new()
                }
                $rawDataByResourceId[$row.ResourceId].Add($row)
            }
            if ($row.ResourceName -and -not [string]::IsNullOrWhiteSpace($row.ResourceName)) {
                if (-not $rawDataByResourceName.ContainsKey($row.ResourceName)) {
                    $rawDataByResourceName[$row.ResourceName] = [System.Collections.Generic.List[object]]::new()
                }
                $rawDataByResourceName[$row.ResourceName].Add($row)
            }
        }
    }
    
    # Generate top resources drilldown HTML (Resource > Meter Category > Meter)
    # Performance: Use StringBuilder for HTML concatenation to avoid O(n²) behavior
    $sw.Restart()
    $topResourcesSectionsHtml = [System.Text.StringBuilder]::new()
    $topResourceMeterIdCounter = 0
    
    foreach ($res in $topResources) {
        $resId = $res.ResourceId
        $resNameRaw = if ($res.ResourceName) { $res.ResourceName } else { "N/A" }
        $resName = if ($res.ResourceName) { [System.Web.HttpUtility]::HtmlEncode($res.ResourceName) } else { "N/A" }
        $resGroup = if ($res.ResourceGroup) { [System.Web.HttpUtility]::HtmlEncode($res.ResourceGroup) } else { "N/A" }
        $resSub = if ($res.SubscriptionName) { [System.Web.HttpUtility]::HtmlEncode($res.SubscriptionName) } else { "N/A" }
        $resType = if ($res.ResourceType) { [System.Web.HttpUtility]::HtmlEncode($res.ResourceType) } else { "N/A" }
        $resCostLocal = Format-NumberWithSeparator -Number $res.CostLocal
        $resCostUSD = Format-NumberWithSeparator -Number $res.CostUSD
        
        # Get all cost data for this resource from pre-grouped hashtable (O(1) lookup)
        $resourceData = if ($resId -and $rawDataByResourceId.ContainsKey($resId)) {
            $rawDataByResourceId[$resId]
        } else {
            @()
        }
        
        # Group by Meter Category
        $categoryGroups = $resourceData | Group-Object MeterCategory
        $categoryHtml = [System.Text.StringBuilder]::new()
        
        # Performance: Precompute sums to avoid O(n²) in Sort-Object
        $categoryGroupsWithSums = $categoryGroups | ForEach-Object {
            $sumUsd = ($_.Group | Measure-Object -Property CostUSD -Sum).Sum
            [PSCustomObject]@{ Name = $_.Name; Group = $_.Group; SumUsd = $sumUsd }
        } | Sort-Object SumUsd -Descending
        
        foreach ($catGroup in $categoryGroupsWithSums) {
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
            $meterCardsHtml = [System.Text.StringBuilder]::new()
            
            # Performance: Precompute sums to avoid O(n²) in Sort-Object
            $meterGroupsWithSums = $meterGroups | ForEach-Object {
                $sumUsd = ($_.Group | Measure-Object -Property CostUSD -Sum).Sum
                [PSCustomObject]@{ Name = $_.Name; Group = $_.Group; SumUsd = $sumUsd }
            } | Sort-Object SumUsd -Descending
            
            foreach ($meterGroup in $meterGroupsWithSums) {
                $meterName = $meterGroup.Name
                if ([string]::IsNullOrWhiteSpace($meterName)) {
                    $meterName = "Unknown"
                }
                $meterItems = $meterGroup.Group
                $meterCostLocal = ($meterItems | Measure-Object -Property CostLocal -Sum).Sum
                $meterCostUSD = ($meterItems | Measure-Object -Property CostUSD -Sum).Sum
                
                $meterCostLocalRounded = Format-NumberWithSeparator -Number $meterCostLocal
                $meterCostUSDRounded = Format-NumberWithSeparator -Number $meterCostUSD
                $meterNameEncoded = [System.Web.HttpUtility]::HtmlEncode($meterName)
                $meterCount = $meterItems.Count
                
                $topResourceMeterIdCounter++
                
                [void]$meterCardsHtml.Append(@"
                            <div class="meter-card no-expand">
                                <div class="expandable__header meter-header" style="display: flex; align-items: center; justify-content: space-between;">
                                    <span class="meter-name" style="flex-grow: 1; font-weight: 600; margin-right: 10px;">$meterNameEncoded</span>
                                    <span class="meter-cost" style="color: #54a0ff !important; text-align: right; font-weight: 600; white-space: nowrap; margin-left: auto;">$currency $meterCostLocalRounded (`$$meterCostUSDRounded)</span>
                                    <span class="meter-count">$meterCount records</span>
                                </div>
                            </div>
"@)
            }
            
            $meterCardsHtmlString = $meterCardsHtml.ToString()
            [void]$categoryHtml.Append(@"
                        <div class="category-card collapsed">
                            <div class="expandable__header category-header collapsed" onclick="toggleCategory(this, event)">
                                <span class="expand-arrow">&#9654;</span>
                                <span class="category-title">$catNameEncoded</span>
                                <span class="category-cost">$currency $catCostLocalRounded (`$$catCostUSDRounded)</span>
                            </div>
                            <div class="category-content" style="display: none !important;">
$meterCardsHtmlString
                            </div>
                        </div>
"@)
        }
        
        $resNameEncoded = [System.Web.HttpUtility]::HtmlEncode($resNameRaw)
        $resSubId = if ($res.SubscriptionId) { $res.SubscriptionId } else { "" }
        $resSubIdEncoded = if ($resSubId) { [System.Web.HttpUtility]::HtmlEncode($resSubId) } else { "" }
        $resSubNameEncodedForAttr = [System.Web.HttpUtility]::HtmlEncode($resSub)
        $categoryHtmlString = $categoryHtml.ToString()
        [void]$topResourcesSectionsHtml.Append(@"
                    <div class="category-card resource-card" data-subscription-id="$resSubIdEncoded" data-subscription-name="$resSubNameEncodedForAttr" data-subscription="$resSubIdEncoded" data-resource="$resNameEncoded">
                        <div class="category-header" onclick="handleResourceCardSelection(this, event) || toggleCategory(this, event)">
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
$categoryHtmlString
                        </div>
                    </div>
"@)
    }
    Write-Host ("[CostTracking] Build TopResources HTML: {0}" -f $sw.Elapsed)
    
    # Generate Top 20 Cost Increase Drivers HTML (similar structure to top resources)
    # Performance: Use StringBuilder for HTML concatenation to avoid O(n²) behavior
    # Performance: Reuse pre-grouped rawData hashtables for O(1) lookup
    $sw.Restart()
    $topIncreasedResourcesSectionsHtml = [System.Text.StringBuilder]::new()

    foreach ($res in $topIncreasedResources) {
        # Find the increase data for this resource
        $increaseData = $resourceIncreaseData[$res.ResourceName]
        if (-not $increaseData) {
            continue  # Skip if no increase data found
        }
        $resId = $res.ResourceId
        $resNameRaw = if ($res.ResourceName) { $res.ResourceName } else { "N/A" }
        $resName = if ($res.ResourceName) { [System.Web.HttpUtility]::HtmlEncode($res.ResourceName) } else { "N/A" }
        $resGroup = if ($res.ResourceGroup) { [System.Web.HttpUtility]::HtmlEncode($res.ResourceGroup) } else { "N/A" }
        $resSub = if ($res.SubscriptionName) { [System.Web.HttpUtility]::HtmlEncode($res.SubscriptionName) } else { "N/A" }
        $resType = if ($res.ResourceType) { [System.Web.HttpUtility]::HtmlEncode($res.ResourceType) } else { "N/A" }
        $increaseAmount = Format-NumberWithSeparator -Number $increaseData.IncreaseAmount
        $increasePercent = [math]::Round($increaseData.IncreasePercent, 1)
        $increasePercentDisplay = if ($increasePercent -gt 1000) { "New" } else { "$increasePercent%" }
        
        # Get all cost data for this resource from pre-grouped hashtables (O(1) lookup)
        # Try matching by ResourceId first, then fall back to ResourceName if ResourceId is empty
        $resourceData = @()
        if ($resId -and -not [string]::IsNullOrWhiteSpace($resId) -and $rawDataByResourceId.ContainsKey($resId)) {
            $resourceData = $rawDataByResourceId[$resId]
        }
        # Fall back to ResourceName matching if no match by ResourceId
        if ($resourceData.Count -eq 0 -and $resNameRaw -and $resNameRaw -ne "N/A" -and $rawDataByResourceName.ContainsKey($resNameRaw)) {
            $resourceData = $rawDataByResourceName[$resNameRaw]
        }
        
        # Group by Meter Category (reuse same logic as top resources)
        $categoryGroups = $resourceData | Group-Object MeterCategory
        $categoryHtml = [System.Text.StringBuilder]::new()
        
        # Performance: Precompute sums to avoid O(n²) in Sort-Object
        $categoryGroupsWithSums = $categoryGroups | ForEach-Object {
            $sumUsd = ($_.Group | Measure-Object -Property CostUSD -Sum).Sum
            [PSCustomObject]@{ Name = $_.Name; Group = $_.Group; SumUsd = $sumUsd }
        } | Sort-Object SumUsd -Descending
        
        foreach ($catGroup in $categoryGroupsWithSums) {
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
            $meterCardsHtml = [System.Text.StringBuilder]::new()
            
            # Performance: Precompute sums to avoid O(n²) in Sort-Object
            $meterGroupsWithSums = $meterGroups | ForEach-Object {
                $sumUsd = ($_.Group | Measure-Object -Property CostUSD -Sum).Sum
                [PSCustomObject]@{ Name = $_.Name; Group = $_.Group; SumUsd = $sumUsd }
            } | Sort-Object SumUsd -Descending
            
            foreach ($meterGroup in $meterGroupsWithSums) {
                $meterName = $meterGroup.Name
                if ([string]::IsNullOrWhiteSpace($meterName)) {
                    $meterName = "Unknown"
                }
                $meterItems = $meterGroup.Group
                $meterCostLocal = ($meterItems | Measure-Object -Property CostLocal -Sum).Sum
                $meterCostUSD = ($meterItems | Measure-Object -Property CostUSD -Sum).Sum
                
                $meterCostLocalRounded = Format-NumberWithSeparator -Number $meterCostLocal
                $meterCostUSDRounded = Format-NumberWithSeparator -Number $meterCostUSD
                $meterNameEncoded = [System.Web.HttpUtility]::HtmlEncode($meterName)
                $meterCount = $meterItems.Count
                
                [void]$meterCardsHtml.Append(@"
                            <div class="meter-card no-expand">
                                <div class="expandable__header meter-header" style="display: flex; align-items: center; justify-content: space-between;">
                                    <span class="meter-name" style="flex-grow: 1; font-weight: 600; margin-right: 10px;">$meterNameEncoded</span>
                                    <span class="meter-cost" style="color: #54a0ff !important; text-align: right; font-weight: 600; white-space: nowrap; margin-left: auto;">$currency $meterCostLocalRounded (`$$meterCostUSDRounded)</span>
                                    <span class="meter-count">$meterCount records</span>
                                </div>
                            </div>
"@)
            }
            
            $meterCardsHtmlString = $meterCardsHtml.ToString()
            [void]$categoryHtml.Append(@"
                        <div class="category-card collapsed">
                            <div class="expandable__header category-header collapsed" onclick="toggleCategory(this, event)">
                                <span class="expand-arrow">&#9654;</span>
                                <span class="category-title">$catNameEncoded</span>
                                <span class="category-cost">$currency $catCostLocalRounded (`$$catCostUSDRounded)</span>
                            </div>
                            <div class="category-content" style="display: none !important;">
$meterCardsHtmlString
                            </div>
                        </div>
"@)
        }
        
        $resNameEncoded = [System.Web.HttpUtility]::HtmlEncode($resNameRaw)
        $resSubIdForIncreased = if ($res.SubscriptionId) { $res.SubscriptionId } else { "" }
        $resSubIdForIncreasedEncoded = if ($resSubIdForIncreased) { [System.Web.HttpUtility]::HtmlEncode($resSubIdForIncreased) } else { "" }
        $resSubNameForIncreasedEncoded = [System.Web.HttpUtility]::HtmlEncode($resSub)
        $categoryHtmlString = $categoryHtml.ToString()
        [void]$topIncreasedResourcesSectionsHtml.Append(@"
                    <div class="category-card resource-card increased-cost-card" data-subscription-id="$resSubIdForIncreasedEncoded" data-subscription-name="$resSubNameForIncreasedEncoded" data-subscription="$resSubIdForIncreasedEncoded" data-resource="$resNameEncoded">
                        <div class="category-header" onclick="handleResourceCardSelection(this, event) || toggleCategory(this, event)">
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
$categoryHtmlString
                        </div>
                    </div>
"@)
    }
    Write-Host ("[CostTracking] Build TopIncreasedResources HTML: {0}" -f $sw.Elapsed)

    # Generate category sections HTML with drilldown (4 levels: Category > SubCategory > Meter > Resource)
    # Performance: Use StringBuilder for HTML concatenation to avoid O(n²) behavior
    $sw.Restart()
    $categorySectionsHtml = [System.Text.StringBuilder]::new()
    $meterIdCounter = 0
    
    # Build categories structure from rawData if available, otherwise use simple byMeterCategory
    if ($rawData.Count -gt 0) {
        # Group raw data by category
        $categoryGroups = $rawData | Group-Object MeterCategory
        $categoriesArray = @()
        
        # Performance: Precompute sums to avoid O(n²) in Sort-Object
        $categoryGroupsWithSums = $categoryGroups | ForEach-Object {
            $sumUsd = ($_.Group | Measure-Object -Property CostUSD -Sum).Sum
            [PSCustomObject]@{ Name = $_.Name; Group = $_.Group; SumUsd = $sumUsd }
        } | Sort-Object SumUsd -Descending
        
        foreach ($catGroup in $categoryGroupsWithSums) {
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
            # Performance: Precompute sums to avoid O(n²) in Sort-Object
            $subCatGroupsWithSums = $subCatGroups | ForEach-Object {
                $sumUsd = ($_.Group | Measure-Object -Property CostUSD -Sum).Sum
                [PSCustomObject]@{ Name = $_.Name; Group = $_.Group; SumUsd = $sumUsd }
            } | Sort-Object SumUsd -Descending
            
            foreach ($subCatGroup in $subCatGroupsWithSums) {
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
                # Performance: Precompute sums to avoid O(n²) in Sort-Object
                $meterGroupsWithSums = $meterGroups | ForEach-Object {
                    $sumUsd = ($_.Group | Measure-Object -Property CostUSD -Sum).Sum
                    [PSCustomObject]@{ Name = $_.Name; Group = $_.Group; SumUsd = $sumUsd }
                } | Sort-Object SumUsd -Descending
                
                foreach ($meterGroup in $meterGroupsWithSums) {
                    $meterName = $meterGroup.Name
                    if ([string]::IsNullOrWhiteSpace($meterName)) {
                        $meterName = "Unknown"
                    }
                    $meterItems = $meterGroup.Group
                    $meterCostLocal = ($meterItems | Measure-Object -Property CostLocal -Sum).Sum
                    $meterCostUSD = ($meterItems | Measure-Object -Property CostUSD -Sum).Sum
                    $meterCount = $meterItems.Count
                    
                    # Build Resources structure (Phase 3: group by ResourceId for consistency with engine)
                    $resourceGroups = $meterItems | Where-Object { $_.ResourceId -and -not [string]::IsNullOrWhiteSpace($_.ResourceId) } | Group-Object ResourceId
                    $resources = @{}
                    # Performance: Precompute sums to avoid O(n²) in Sort-Object
                    $resourceGroupsWithSums = $resourceGroups | ForEach-Object {
                        $sumUsd = ($_.Group | Measure-Object -Property CostUSD -Sum).Sum
                        [PSCustomObject]@{ Name = $_.Name; Group = $_.Group; SumUsd = $sumUsd }
                    } | Sort-Object SumUsd -Descending
                    
                    foreach ($resGroup in $resourceGroupsWithSums) {
                        $resId = $resGroup.Name  # ResourceId from the group
                        $resItems = $resGroup.Group
                        $resName = if ($resItems[0].ResourceName) { $resItems[0].ResourceName } else { "Unknown" }
                        $resCostLocal = ($resItems | Measure-Object -Property CostLocal -Sum).Sum
                        $resCostUSD = ($resItems | Measure-Object -Property CostUSD -Sum).Sum
                        $resources[$resId] = @{
                            ResourceId = $resId
                            ResourceName = $resName
                            ResourceGroup = if ($resItems[0].ResourceGroup) { $resItems[0].ResourceGroup } else { "N/A" }
                            SubscriptionId = if ($resItems[0].SubscriptionId) { $resItems[0].SubscriptionId } else { "" }
                            SubscriptionName = if ($resItems[0].SubscriptionName) { $resItems[0].SubscriptionName } else { "N/A" }
                            CostLocal = $resCostLocal
                            CostUSD = $resCostUSD
                        }
                    }
                    
                    # Also keep Resources indexed by ResourceName for backward compatibility (if needed)
                    # But primary key is ResourceId
                    
                    $meters[$meterName] = @{
                        Meter = $meterName
                        CostLocal = $meterCostLocal
                        CostUSD = $meterCostUSD
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
        
        $subCatHtml = [System.Text.StringBuilder]::new()
        if ($cat.SubCategories -and $cat.SubCategories.Count -gt 0) {
            # Sort subcategories by cost descending
            $sortedSubCats = $cat.SubCategories.GetEnumerator() | Sort-Object { $_.Value.CostUSD } -Descending
            foreach ($subCatEntry in $sortedSubCats) {
                $subCat = $subCatEntry.Value
                $subCatName = if ($subCat.MeterSubCategory) { [System.Web.HttpUtility]::HtmlEncode($subCat.MeterSubCategory) } else { "N/A" }
                $subCatNameEncoded = $subCatName
                $subCatCostLocal = Format-NumberWithSeparator -Number $subCat.CostLocal
                $subCatCostUSD = Format-NumberWithSeparator -Number $subCat.CostUSD
                
                $meterCardsHtml = [System.Text.StringBuilder]::new()
                if ($subCat.Meters -and $subCat.Meters.Count -gt 0) {
                    # Sort meters by cost descending
                    $sortedMeters = $subCat.Meters.GetEnumerator() | Sort-Object { $_.Value.CostUSD } -Descending
                    foreach ($meterEntry in $sortedMeters) {
                        $meter = $meterEntry.Value
                        $meterName = if ($meter.Meter) { [System.Web.HttpUtility]::HtmlEncode($meter.Meter) } else { "Unknown" }
                        $meterNameEncoded = $meterName
                        $meterCostLocal = Format-NumberWithSeparator -Number $meter.CostLocal
                        $meterCostUSD = Format-NumberWithSeparator -Number $meter.CostUSD
                        $meterCount = $meter.ItemCount
                        $meterIdCounter++
                        
                        # Build resource rows if available
                        $resourceRowsHtml = [System.Text.StringBuilder]::new()
                        $hasResources = $false
                        if ($meter.Resources -and $meter.Resources.Count -gt 0) {
                            $hasResources = $true
                            # Sort resources by cost descending
                            $sortedResources = $meter.Resources.GetEnumerator() | Sort-Object { $_.Value.CostUSD } -Descending
                            foreach ($resEntry in $sortedResources) {
                                $res = $resEntry.Value
                                $resName = if ($res.ResourceName) { [System.Web.HttpUtility]::HtmlEncode($res.ResourceName) } else { "Unknown" }
                                $resNameEncoded = $resName
                                $resId = if ($res.ResourceId) { $res.ResourceId } else { "" }
                                $resIdEncoded = if ($resId) { [System.Web.HttpUtility]::HtmlEncode($resId) } else { "" }
                                $resGroup = if ($res.ResourceGroup) { [System.Web.HttpUtility]::HtmlEncode($res.ResourceGroup) } else { "N/A" }
                                $resSubName = if ($res.SubscriptionName) { [System.Web.HttpUtility]::HtmlEncode($res.SubscriptionName) } else { "N/A" }
                                $resSubId = if ($res.SubscriptionId) { $res.SubscriptionId } else { "" }
                                $resSubIdEncoded = if ($resSubId) { [System.Web.HttpUtility]::HtmlEncode($resSubId) } else { "" }
                                
                                # Compute resourceKey (canonical key for resources)
                                $resourceKey = if ($resId -and $resId.Trim() -ne "") {
                                    $resId
                                } else {
                                    $subId = if ($resSubId) { $resSubId } else { "" }
                                    $rg = if ($res.ResourceGroup) { $res.ResourceGroup } else { "" }
                                    $resNameRaw = if ($res.ResourceName) { $res.ResourceName } else { "noresource" }
                                    "sub:" + $subId + "|rg:" + $rg + "|res:" + $resNameRaw
                                }
                                $resourceKeyEncoded = [System.Web.HttpUtility]::HtmlEncode($resourceKey)
                                
                                # Build attributes: always data-resource-key, data-resource-id only if ResourceId exists
                                $attr = "class=""clickable"" data-resource-key=""$resourceKeyEncoded"""
                                if ($resIdEncoded) { $attr += " data-resource-id=""$resIdEncoded""" }
                                
                                # Build subscription attributes: data-subscription = GUID (ID-first), data-subscription-name = display name
                                $subscriptionAttr = if ($resSubIdEncoded) { "data-subscription-id=""$resSubIdEncoded"" data-subscription-name=""$resSubName"" data-subscription=""$resSubIdEncoded""" } else { "" }
                                
                                $resCostLocalFormatted = Format-NumberWithSeparator -Number $res.CostLocal
                                $resCostUSDFormatted = Format-NumberWithSeparator -Number $res.CostUSD
                                [void]$resourceRowsHtml.Append(@"
                                            <tr $attr $subscriptionAttr data-resource="$resNameEncoded" data-meter="$meterNameEncoded" data-subcategory="$subCatNameEncoded" data-category="$catName" style="cursor: pointer;">
                                                <td>$resName</td>
                                                <td>$resGroup</td>
                                                <td>$resSubName</td>
                                                <td class="cost-value text-right">$currency $resCostLocalFormatted</td>
                                                <td class="cost-value text-right">`$$resCostUSDFormatted</td>
                                            </tr>
"@)
                            }
                        }
                        
                        if ($hasResources) {
                            $resourceRowsHtmlString = $resourceRowsHtml.ToString()
                            [void]$meterCardsHtml.Append(@"
                            <div class="meter-card" data-meter="$meterNameEncoded" data-subcategory="$subCatNameEncoded" data-category="$catName">
                                <div class="expandable__header meter-header" data-meter="$meterNameEncoded" data-subcategory="$subCatNameEncoded" data-category="$catName" onclick="handleMeterSelection(this, event)" style="display: flex; align-items: center; justify-content: space-between;">
                                    <span class="expand-arrow">&#9654;</span>
                                    <span class="meter-name" style="flex-grow: 1; font-weight: 600; margin-right: 10px;">$meterName</span>
                                    <div class="meter-header-right" style="display: flex; align-items: center; gap: 10px; margin-left: auto;">
                                        <span class="meter-cost" style="color: #54a0ff !important; text-align: right; font-weight: 600; white-space: nowrap;">$currency $meterCostLocal (`$$meterCostUSD)</span>
                                        <span class="meter-count">$meterCount records</span>
                                    </div>
                                </div>
                                <div class="meter-content">
                                    <table class="data-table resource-table">
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
                                            $resourceRowsHtmlString
                                        </tbody>
                                    </table>
                                </div>
                            </div>
"@)
                        } else {
                            [void]$meterCardsHtml.Append(@"
                            <div class="meter-card no-expand" data-meter="$meterNameEncoded" data-subcategory="$subCatNameEncoded" data-category="$catName">
                                <div class="expandable__header meter-header" data-meter="$meterNameEncoded" data-subcategory="$subCatNameEncoded" data-category="$catName" style="display: flex; align-items: center; justify-content: space-between;">
                                    <span class="meter-name" style="flex-grow: 1; font-weight: 600; margin-right: 10px;">$meterName</span>
                                    <span class="meter-cost" style="color: #54a0ff !important; text-align: right; font-weight: 600; white-space: nowrap; margin-left: auto;">$currency $meterCostLocal (`$$meterCostUSD)</span>
                                    <span class="meter-count">$meterCount records</span>
                                </div>
                            </div>
"@)
                        }
                    }
                }
                
                $meterCardsHtmlString = $meterCardsHtml.ToString()
                [void]$subCatHtml.Append(@"
                        <div class="subcategory-drilldown" data-subcategory="$subCatNameEncoded" data-category="$catName">
                            <div class="expandable__header subcategory-header" data-subcategory="$subCatNameEncoded" data-category="$catName" data-subcategory-key="$catName|$subCatNameEncoded" onclick="handleSubcategorySelection(this, event)" style="display: flex; align-items: center; justify-content: space-between;">
                                <span class="expand-arrow">&#9654;</span>
                                <span class="subcategory-name" style="flex-grow: 1; font-weight: 600; margin-right: 10px;">$subCatName</span>
                                <span class="subcategory-cost" style="color: #54a0ff !important; text-align: right; font-weight: 600; white-space: nowrap; margin-left: auto;">$currency $subCatCostLocal (`$$subCatCostUSD)</span>
                            </div>
                            <div class="subcategory-content" style="display: none !important;">
$meterCardsHtmlString
                            </div>
                        </div>
"@)
            }
        }
        
        $subCatHtmlString = $subCatHtml.ToString()
        [void]$categorySectionsHtml.Append(@"
                    <div class="category-card collapsed" data-category="$catName">
                        <div class="category-header collapsed" data-category="$catName" onclick="handleCategorySelection(this, event)">
                            <span class="expand-arrow">&#9654;</span>
                            <span class="category-title">$catName</span>
                            <span class="category-cost">$currency $catCostLocal (`$$catCostUSD)</span>
                        </div>
                        <div class="category-content" style="display: none !important;">
$subCatHtmlString
                        </div>
                    </div>
"@)
    }
    Write-Host ("[CostTracking] Build MeterCategory HTML: {0}" -f $sw.Elapsed)
    
    # Generate subscription sections HTML with drilldown (5 levels: Subscription > Category > SubCategory > Meter > Resource)
    # This is the "Cost Breakdown" / "Cost by Subscription" section
    # Performance: Use StringBuilder for HTML concatenation to avoid O(n²) behavior
    $sw.Restart()
    $subscriptionSectionsHtml = [System.Text.StringBuilder]::new()
    $subscriptionMeterIdCounter = 0
    $rawData = if ($CostTrackingData.RawData) { $CostTrackingData.RawData } else { @() }
    
    # Group raw data by subscription
    if ($rawData.Count -gt 0) {
        $subscriptionGroups = $rawData | Group-Object SubscriptionId
        # Performance: Precompute sums to avoid O(n²) in Sort-Object
        $subscriptionGroupsWithSums = $subscriptionGroups | ForEach-Object {
            $sumUsd = ($_.Group | Measure-Object -Property CostUSD -Sum).Sum
            [PSCustomObject]@{ Name = $_.Name; Group = $_.Group; SumUsd = $sumUsd }
        } | Sort-Object SumUsd -Descending
        
        foreach ($subGroup in $subscriptionGroupsWithSums) {
            $subId = $subGroup.Name  # SubscriptionId (GUID)
            $subItems = $subGroup.Group
            $subName = if ($subItems[0].SubscriptionName) { $subItems[0].SubscriptionName } else { "Unknown" }
            $subCostLocal = ($subItems | Measure-Object -Property CostLocal -Sum).Sum
            $subCostUSD = ($subItems | Measure-Object -Property CostUSD -Sum).Sum
            $subCostLocalRounded = Format-NumberWithSeparator -Number $subCostLocal
            $subCostUSDRounded = Format-NumberWithSeparator -Number $subCostUSD
            $subNameEncoded = [System.Web.HttpUtility]::HtmlEncode($subName)
            $subIdEncoded = if ($subId) { [System.Web.HttpUtility]::HtmlEncode($subId) } else { "" }
            
            # Group by category within subscription
            $categoryGroups = $subItems | Group-Object MeterCategory
            $categoryHtml = [System.Text.StringBuilder]::new()
            
            # Performance: Precompute sums to avoid O(n²) in Sort-Object
            $categoryGroupsWithSums = $categoryGroups | ForEach-Object {
                $sumUsd = ($_.Group | Measure-Object -Property CostUSD -Sum).Sum
                [PSCustomObject]@{ Name = $_.Name; Group = $_.Group; SumUsd = $sumUsd }
            } | Sort-Object SumUsd -Descending
            
            foreach ($catGroup in $categoryGroupsWithSums) {
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
                $subCatHtml = [System.Text.StringBuilder]::new()
                
                # Performance: Precompute sums to avoid O(n²) in Sort-Object
                $subCatGroupsWithSums = $subCatGroups | ForEach-Object {
                    $sumUsd = ($_.Group | Measure-Object -Property CostUSD -Sum).Sum
                    [PSCustomObject]@{ Name = $_.Name; Group = $_.Group; SumUsd = $sumUsd }
                } | Sort-Object SumUsd -Descending
                
                foreach ($subCatGroup in $subCatGroupsWithSums) {
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
                    $meterCardsHtml = [System.Text.StringBuilder]::new()
                    
                    # Performance: Precompute sums to avoid O(n²) in Sort-Object
                    $meterGroupsWithSums = $meterGroups | ForEach-Object {
                        $sumUsd = ($_.Group | Measure-Object -Property CostUSD -Sum).Sum
                        [PSCustomObject]@{ Name = $_.Name; Group = $_.Group; SumUsd = $sumUsd }
                    } | Sort-Object SumUsd -Descending
                    
                    foreach ($meterGroup in $meterGroupsWithSums) {
                        $meterName = $meterGroup.Name
                        if ([string]::IsNullOrWhiteSpace($meterName)) {
                            $meterName = "Unknown"
                        }
                        $meterItems = $meterGroup.Group
                        $meterCostLocal = ($meterItems | Measure-Object -Property CostLocal -Sum).Sum
                        $meterCostUSD = ($meterItems | Measure-Object -Property CostUSD -Sum).Sum
                        
                        $meterCostLocalRounded = Format-NumberWithSeparator -Number $meterCostLocal
                        $meterCostUSDRounded = Format-NumberWithSeparator -Number $meterCostUSD
                        $meterNameEncoded = [System.Web.HttpUtility]::HtmlEncode($meterName)
                        $meterCount = $meterItems.Count
                        
                        $subscriptionMeterIdCounter++
                        
                        # Group by resource within meter (by ResourceId for consistency with engine)
                        $resourceGroups = $meterItems | Where-Object { $_.ResourceId -and -not [string]::IsNullOrWhiteSpace($_.ResourceId) } | Group-Object ResourceId
                        $resourceRowsHtml = [System.Text.StringBuilder]::new()
                        $hasResources = $false
                        
                        if ($resourceGroups.Count -gt 0) {
                            $hasResources = $true
                            # Performance: Precompute sums to avoid O(n²) in Sort-Object
                            $resourceGroupsWithSums = $resourceGroups | ForEach-Object {
                                $sumUsd = ($_.Group | Measure-Object -Property CostUSD -Sum).Sum
                                [PSCustomObject]@{ Name = $_.Name; Group = $_.Group; SumUsd = $sumUsd }
                            } | Sort-Object SumUsd -Descending
                            
                            foreach ($resGroup in $resourceGroupsWithSums) {
                                $resId = $resGroup.Name  # ResourceId from the group
                                $resItems = $resGroup.Group
                                $resName = if ($resItems[0].ResourceName) { $resItems[0].ResourceName } else { "Unknown" }
                                $resCostLocal = ($resItems | Measure-Object -Property CostLocal -Sum).Sum
                                $resCostUSD = ($resItems | Measure-Object -Property CostUSD -Sum).Sum
                                $resCostLocalFormatted = Format-NumberWithSeparator -Number $resCostLocal
                                $resCostUSDFormatted = Format-NumberWithSeparator -Number $resCostUSD
                                $resNameEncoded = [System.Web.HttpUtility]::HtmlEncode($resName)
                                $resIdEncoded = if ($resId) { [System.Web.HttpUtility]::HtmlEncode($resId) } else { "" }
                                $resGroupName = if ($resItems[0].ResourceGroup) { [System.Web.HttpUtility]::HtmlEncode($resItems[0].ResourceGroup) } else { "N/A" }
                                
                                # Compute resourceKey (canonical key for resources)
                                $resourceKey = if ($resId -and $resId.Trim() -ne "") {
                                    $resId
                                } else {
                                    $resSubId = if ($resItems[0].SubscriptionId) { $resItems[0].SubscriptionId } else { $subId }
                                    $rg = if ($resItems[0].ResourceGroup) { $resItems[0].ResourceGroup } else { "" }
                                    $resNameRaw = if ($resItems[0].ResourceName) { $resItems[0].ResourceName } else { "noresource" }
                                    "sub:" + $resSubId + "|rg:" + $rg + "|res:" + $resNameRaw
                                }
                                $resourceKeyEncoded = [System.Web.HttpUtility]::HtmlEncode($resourceKey)
                                
                                # Build attributes: always data-resource-key, data-resource-id only if ResourceId exists
                                $attr = "class=""clickable"" data-resource-key=""$resourceKeyEncoded"""
                                if ($resIdEncoded) { $attr += " data-resource-id=""$resIdEncoded""" }
                                
                                # Build subscription attributes: data-subscription = GUID (ID-first), data-subscription-name = display name
                                $subscriptionAttr = if ($subIdEncoded) { "data-subscription-id=""$subIdEncoded"" data-subscription-name=""$subNameEncoded"" data-subscription=""$subIdEncoded""" } else { "" }
                                
                                [void]$resourceRowsHtml.Append(@"
                                            <tr $attr $subscriptionAttr data-resource="$resNameEncoded" data-meter="$meterNameEncoded" data-subcategory="$subCatNameEncoded" data-category="$catNameEncoded" style="cursor: pointer;">
                                                <td>$resNameEncoded</td>
                                                <td>$resGroupName</td>
                                                <td class="cost-value text-right">$currency $resCostLocalFormatted</td>
                                                <td class="cost-value text-right">`$$resCostUSDFormatted</td>
                                            </tr>
"@)
                            }
                        }
                        
                        if ($hasResources) {
                            $resourceRowsHtmlString = $resourceRowsHtml.ToString()
                            [void]$meterCardsHtml.Append(@"
                            <div class="meter-card" data-meter="$meterNameEncoded" data-subcategory="$subCatNameEncoded" data-category="$catNameEncoded" data-subscription-id="$subIdEncoded" data-subscription-name="$subNameEncoded" data-subscription="$subIdEncoded">
                                <div class="expandable__header meter-header" data-meter="$meterNameEncoded" data-subcategory="$subCatNameEncoded" data-category="$catNameEncoded" data-subscription-id="$subIdEncoded" data-subscription-name="$subNameEncoded" data-subscription="$subIdEncoded" onclick="handleMeterSelection(this, event)" style="display: flex; align-items: center; justify-content: space-between;">
                                    <span class="expand-arrow">&#9654;</span>
                                    <span class="meter-name" style="flex-grow: 1; font-weight: 600; margin-right: 10px;">$meterNameEncoded</span>
                                    <div class="meter-header-right" style="display: flex; align-items: center; gap: 10px; margin-left: auto;">
                                        <span class="meter-cost" style="color: #54a0ff !important; text-align: right; font-weight: 600; white-space: nowrap;">$currency $meterCostLocalRounded (`$$meterCostUSDRounded)</span>
                                        <span class="meter-count">$meterCount records</span>
                                    </div>
                                </div>
                                <div class="meter-content">
                                    <table class="data-table resource-table">
                                        <thead>
                                            <tr>
                                                <th>Resource</th>
                                                <th>Resource Group</th>
                                                <th class="text-right">Cost (Local)</th>
                                                <th class="text-right">Cost (USD)</th>
                                            </tr>
                                        </thead>
                                        <tbody>
                                            $resourceRowsHtmlString
                                        </tbody>
                                    </table>
                                </div>
                            </div>
"@)
                        } else {
                            [void]$meterCardsHtml.Append(@"
                            <div class="meter-card no-expand" data-meter="$meterNameEncoded" data-subcategory="$subCatNameEncoded" data-category="$catNameEncoded" data-subscription-id="$subIdEncoded" data-subscription-name="$subNameEncoded" data-subscription="$subIdEncoded">
                                <div class="expandable__header meter-header" data-meter="$meterNameEncoded" data-subcategory="$subCatNameEncoded" data-category="$catNameEncoded" data-subscription-id="$subIdEncoded" data-subscription-name="$subNameEncoded" data-subscription="$subIdEncoded" onclick="handleMeterSelection(this, event)" style="display: flex; align-items: center; justify-content: space-between;">
                                    <span class="meter-name" style="flex-grow: 1; font-weight: 600; margin-right: 10px;">$meterNameEncoded</span>
                                    <span class="meter-cost" style="color: #54a0ff !important; text-align: right; font-weight: 600; white-space: nowrap; margin-left: auto;">$currency $meterCostLocalRounded (`$$meterCostUSDRounded)</span>
                                    <span class="meter-count">$meterCount records</span>
                                </div>
                            </div>
"@)
                        }
                    }
                    
                    $meterCardsHtmlString = $meterCardsHtml.ToString()
                    [void]$subCatHtml.Append(@"
                        <div class="subcategory-drilldown" data-subcategory="$subCatNameEncoded" data-category="$catNameEncoded" data-subscription-id="$subIdEncoded" data-subscription-name="$subNameEncoded" data-subscription="$subIdEncoded">
                            <div class="expandable__header subcategory-header" data-subcategory="$subCatNameEncoded" data-category="$catNameEncoded" data-subscription-id="$subIdEncoded" data-subscription-name="$subNameEncoded" data-subscription="$subIdEncoded" data-subcategory-key="$subIdEncoded|$catNameEncoded|$subCatNameEncoded" onclick="handleSubcategorySelection(this, event)" style="display: flex; align-items: center; justify-content: space-between;">
                                <span class="expand-arrow">&#9654;</span>
                                <span class="subcategory-name" style="flex-grow: 1; font-weight: 600; margin-right: 10px;">$subCatNameEncoded</span>
                                <span class="subcategory-cost" style="color: #54a0ff !important; text-align: right; font-weight: 600; white-space: nowrap; margin-left: auto;">$currency $subCatCostLocalRounded (`$$subCatCostUSDRounded)</span>
                            </div>
                            <div class="subcategory-content" style="display: none !important;">
$meterCardsHtmlString
                            </div>
                        </div>
"@)
                }
                
                $subCatHtmlString = $subCatHtml.ToString()
                [void]$categoryHtml.Append(@"
                        <div class="category-card collapsed" data-category="$catNameEncoded" data-subscription-id="$subIdEncoded" data-subscription-name="$subNameEncoded" data-subscription="$subIdEncoded">
                            <div class="expandable__header category-header collapsed" data-category="$catNameEncoded" data-category-key="$subIdEncoded|$catNameEncoded" data-subscription-id="$subIdEncoded" data-subscription-name="$subNameEncoded" data-subscription="$subIdEncoded" data-category-name="$catNameEncoded" onclick="handleCategorySelection(this, event)">
                                <span class="expand-arrow">&#9654;</span>
                                <span class="category-title">$catNameEncoded</span>
                                <span class="category-cost">$currency $catCostLocalRounded (`$$catCostUSDRounded)</span>
                            </div>
                            <div class="category-content" style="display: none !important;">
$subCatHtmlString
                            </div>
                        </div>
"@)
            }
            
            $categoryHtmlString = $categoryHtml.ToString()
            [void]$subscriptionSectionsHtml.Append(@"
                    <div class="category-card subscription-card collapsed" data-subscription-id="$subIdEncoded" data-subscription-name="$subNameEncoded" data-subscription="$subIdEncoded">
                        <div class="category-header collapsed" data-subscription-id="$subIdEncoded" data-subscription-name="$subNameEncoded" data-subscription="$subIdEncoded" onclick="if (!handleSubscriptionSelection(this, event)) return; toggleCategory(this, event)">
                            <span class="expand-arrow">&#9654;</span>
                            <span class="category-title">$subNameEncoded</span>
                            <span class="category-cost">$currency $subCostLocalRounded (`$$subCostUSDRounded)</span>
                        </div>
                        <div class="category-content" style="display: none !important;">
$categoryHtmlString
                        </div>
                    </div>
"@)
        }
    }
    Write-Host ("[CostTracking] Build CostBreakdown HTML: {0}" -f $sw.Elapsed)
    
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
    <script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.0/chart.umd.min.js" crossorigin="anonymous" referrerpolicy="no-referrer"></script>
    <style>
$(Get-ReportStylesheet)
        
        /* Pick-selected (BLUE) - explicit user picks */
        .pick-selected,
        .category-header.pick-selected,
        .subcategory-header.pick-selected,
        .meter-header.pick-selected,
        .cost-table tbody tr.pick-selected,
        .resource-table tbody tr.pick-selected {
            background-color: rgba(84, 160, 255, 0.25) !important;
            border-left: 3px solid var(--accent-blue) !important;
        }
        
        /* Cross-selected (YELLOW) - rows affected by current results */
        .cross-selected,
        .cost-table tbody tr.cross-selected,
        .resource-table tbody tr.cross-selected {
            background-color: rgba(254, 202, 87, 0.2) !important;
            border-left: 2px solid var(--accent-yellow) !important;
        }
        
        /* Blue replaces yellow - when both are present, only blue shows */
        .pick-selected.cross-selected,
        .category-header.pick-selected.cross-selected,
        .subcategory-header.pick-selected.cross-selected,
        .meter-header.pick-selected.cross-selected,
        .cost-table tbody tr.pick-selected.cross-selected,
        .resource-table tbody tr.pick-selected.cross-selected {
            background-color: rgba(84, 160, 255, 0.25) !important;
            border-left: 3px solid var(--accent-blue) !important;
        }
        
        /* Selection legend */
        .selection-legend {
            display: flex;
            gap: 16px;
            font-size: 0.85rem;
            color: var(--text-secondary);
            margin-top: 8px;
            margin-bottom: 12px;
        }
        
        .selection-legend-item {
            display: flex;
            align-items: center;
            gap: 6px;
        }
        
        .selection-legend-color {
            width: 16px;
            height: 16px;
            border-radius: 3px;
            flex-shrink: 0;
        }
        
        .selection-legend-color.pick {
            background-color: rgba(84, 160, 255, 0.25);
            border-left: 3px solid var(--accent-blue);
        }
        
        .selection-legend-color.cross {
            background-color: rgba(254, 202, 87, 0.2);
            border-left: 2px solid var(--accent-yellow);
        }
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
                    <option value="stacked-meter">Stacked by Meter</option>
                    <option value="stacked-resource">Stacked by Resource</option>
                    <option value="total" selected>Total Cost</option>
                </select>
                <button id="clearChartSelections" onclick="clearAllChartSelections()" style="display: none; padding: 8px 12px; border: 1px solid var(--border-color); border-radius: 6px; background: var(--bg-surface); color: var(--text); cursor: pointer; font-size: 0.9rem;">
                    Clear Chart Selections
                </button>
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
$($subscriptionOptionsHtml.ToString())
                        <div class="filter-actions">
                            <button class="filter-btn" onclick="selectAllSubscriptions()">Select All</button>
                            <button class="filter-btn" onclick="deselectAllSubscriptions()">Deselect All</button>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        
        <div id="costBreakdownRoot" class="section-box">
            <h2>Cost Breakdown</h2>
            <div class="selection-legend">
                <div class="selection-legend-item">
                    <div class="selection-legend-color pick"></div>
                    <span>Blue = selection</span>
                </div>
                <div class="selection-legend-item">
                    <div class="selection-legend-color cross"></div>
                    <span>Yellow = affected by selection</span>
                </div>
            </div>
            <div class="expandable expandable--collapsed">
                <div class="expandable__header" onclick="toggleSection(this)">
                    <div class="expandable__title">
                        <span class="expand-arrow">&#9654;</span>
                        <h3>Cost by Subscription</h3>
                    </div>
                </div>
                <div class="expandable__content">
$($subscriptionSectionsHtml.ToString())
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
                    <div class="selection-legend">
                        <div class="selection-legend-item">
                            <div class="selection-legend-color pick"></div>
                            <span>Blue = selection</span>
                        </div>
                        <div class="selection-legend-item">
                            <div class="selection-legend-color cross"></div>
                            <span>Yellow = affected by selection</span>
                        </div>
                    </div>
                    <div id="meterCategoryDynamicRoot"></div>
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
$($topResourcesSectionsHtml.ToString())
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
$($topIncreasedResourcesSectionsHtml.ToString())
                </div>
            </div>
        </div>
    </div>
    
    <!-- Canonical factRows embedded as JSON (robust, no escaping issues) -->
    <script id="factRowsJson" type="application/json">
$factRowsJson
</script>
    <script>
        // Parse factRows from embedded JSON (robust method)
        const factRows = JSON.parse(document.getElementById('factRowsJson').textContent);
        console.log('factRows loaded:', factRows.length, 'rows');
        
        // Chart data
        const chartLabels = [$chartLabelsJson];
        // Phase 5.1: datasetsBy* constants removed - engine-only now
        
        // Phase 5.1.1: legacy daily data removed - engine-only now
        const allKnownSubscriptions = new Set(JSON.parse('$allSubscriptionsJson'));
        
        // Currency for formatting
        const currency = "$currency";
        
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
        // Phase 5.1: legacy category/subscription filter state removed - engine-only now
        
        // ============================================================================
        // Cost Tracking Engine - Single Source of Truth for Filtering & Aggregation
        // ============================================================================
        
        function createEngine(factRows) {
            // Build indices: dimension -> Set<rowId>
            const index = {
                bySubscriptionId: new Map(),
                bySubscriptionName: new Map(),
                byCategory: new Map(),
                byCategoryScoped: new Map(),  // Phase 5.2: Scoped category index (key = subscriptionId|category) for Cost by Subscription
                bySubcategory: new Map(),  // P4-1: Subcategory index (composite key = subscriptionId|category|subcategory)
                bySubcategoryGlobal: new Map(),  // FIX: Global subcategory index (key = category|subcategory) for Meter Category section
                byMeter: new Map(),
                byResourceId: new Map(),
                byResourceKey: new Map(),  // Canonical resource key index
                byResourceName: new Map(),
                byResourceGroup: new Map(),
                byDay: new Map()
            };
            
            // Build allRowIds once (reuse instead of creating new Set each time)
            const allRowIds = new Set(factRows.map((_, i) => i));
            
            // Build indices by iterating factRows once
            factRows.forEach((row, rowId) => {
                // Subscription indices
                if (row.subscriptionId) {
                    if (!index.bySubscriptionId.has(row.subscriptionId)) {
                        index.bySubscriptionId.set(row.subscriptionId, new Set());
                    }
                    index.bySubscriptionId.get(row.subscriptionId).add(rowId);
                }
                if (row.subscriptionName) {
                    if (!index.bySubscriptionName.has(row.subscriptionName)) {
                        index.bySubscriptionName.set(row.subscriptionName, new Set());
                    }
                    index.bySubscriptionName.get(row.subscriptionName).add(rowId);
                }
                
                // Category index
                if (row.meterCategory) {
                    if (!index.byCategory.has(row.meterCategory)) {
                        index.byCategory.set(row.meterCategory, new Set());
                    }
                    index.byCategory.get(row.meterCategory).add(rowId);
                    
                    // Phase 5.2: Scoped category index (subscriptionId|category) for Cost by Subscription
                    if (row.subscriptionId) {
                        const scopedCatKey = row.subscriptionId + '|' + row.meterCategory;
                        if (!index.byCategoryScoped.has(scopedCatKey)) {
                            index.byCategoryScoped.set(scopedCatKey, new Set());
                        }
                        index.byCategoryScoped.get(scopedCatKey).add(rowId);
                    }
                }
                
                // P4-1: Subcategory index (subscription+category-scoped: composite key = subscriptionId|category|subcategory)
                // This prevents false matches when same subcategory exists under different categories
                if (row.meterSubcategory) {
                    const subcatKey = (row.subscriptionId || '') + '|' + 
                                     (row.meterCategory || '') + '|' + 
                                     row.meterSubcategory;
                    if (!index.bySubcategory.has(subcatKey)) {
                        index.bySubcategory.set(subcatKey, new Set());
                    }
                    index.bySubcategory.get(subcatKey).add(rowId);
                    
                    // FIX: Also build global subcategory index (category|subcategory) for Meter Category section
                    const globalSubcatKey = (row.meterCategory || '') + '|' + row.meterSubcategory;
                    if (!index.bySubcategoryGlobal.has(globalSubcatKey)) {
                        index.bySubcategoryGlobal.set(globalSubcatKey, new Set());
                    }
                    index.bySubcategoryGlobal.get(globalSubcatKey).add(rowId);
                }
                
                // Meter index
                if (row.meterName) {
                    if (!index.byMeter.has(row.meterName)) {
                        index.byMeter.set(row.meterName, new Set());
                    }
                    index.byMeter.get(row.meterName).add(rowId);
                }
                
                // Resource indices
                if (row.resourceId) {
                    if (!index.byResourceId.has(row.resourceId)) {
                        index.byResourceId.set(row.resourceId, new Set());
                    }
                    index.byResourceId.get(row.resourceId).add(rowId);
                }
                
                // Canonical resourceKey index (only for clickable rows, i.e. where resourceId exists)
                // "no-resource"-rows (subscription-level costs) should be counted in totals but are not pickable
                // This prevents "noresource" fallbacks from being pickable and causing bugs
                if (row.resourceId && typeof row.resourceId === 'string' && row.resourceId.trim() !== '') {
                    const resourceKey = row.resourceKey || row.resourceId; // Use precomputed key from PowerShell
                    if (!index.byResourceKey.has(resourceKey)) {
                        index.byResourceKey.set(resourceKey, new Set());
                    }
                    index.byResourceKey.get(resourceKey).add(rowId);
                }
                
                if (row.resourceName) {
                    if (!index.byResourceName.has(row.resourceName)) {
                        index.byResourceName.set(row.resourceName, new Set());
                    }
                    index.byResourceName.get(row.resourceName).add(rowId);
                }
                if (row.resourceGroup) {
                    if (!index.byResourceGroup.has(row.resourceGroup)) {
                        index.byResourceGroup.set(row.resourceGroup, new Set());
                    }
                    index.byResourceGroup.get(row.resourceGroup).add(rowId);
                }
                
                // Day index
                if (row.day) {
                    if (!index.byDay.has(row.day)) {
                        index.byDay.set(row.day, new Set());
                    }
                    index.byDay.get(row.day).add(rowId);
                }
            });
            
            // Selection state: union picks + scope intersection
            // Phase 5.2: Filter stack (layers) - top layer is active, others show as "yellow" (cross-selected)
            const state = {
                scope: {
                    subscriptionIds: new Set(),  // Checkbox selections
                    subscriptionNames: new Set(), // For compatibility
                    dayFrom: null,
                    dayTo: null
                },
                picks: {
                    resourceIds: new Set(),      // DEPRECATED (Phase 5 PR3A) - kept for backward compatibility, should be empty
                    resourceKeys: new Set(),    // Canonical resource keys (Phase 3) - PRIMARY
                    resourceNames: new Set(),   // DEPRECATED (Phase 5 PR3A) - kept for backward compatibility, should be empty
                    resourceGroups: new Set(),  // DEPRECATED (Phase 5 PR3A) - kept for backward compatibility, should be empty
                    meterNames: new Set(),
                    categories: new Set(),
                    subcategories: new Set()    // P4-2: Subcategory picks (composite key = subscriptionId|category|subcategory)
                },
                layers: []  // Filter stack: [{ source: "subscription"|"meter", picks: { categories:Set, subcategories:Set, meterNames:Set, resourceKeys:Set, ... } }]
            };
            
            // Helper: intersect two Sets (used internally and exposed for chart breakdown)
            // Optimized: iterate over smallest set for better performance
            function intersectSets(setA, setB) {
                // Swap if needed to iterate over smallest set
                if (setA.size > setB.size) {
                    [setA, setB] = [setB, setA];
                }
                const result = new Set();
                for (const item of setA) {
                    if (setB.has(item)) {
                        result.add(item);
                    }
                }
                return result;
            }
            
            // Helper: union multiple Sets
            function unionSets(...sets) {
                const result = new Set();
                for (const s of sets) {
                    for (const item of s) {
                        result.add(item);
                    }
                }
                return result;
            }
            
            // Get rowIds matching scope filters (AND logic)
            function getScopeRowIds() {
                let scopeRowIds = null;
                
                // Start with all rows if no scope filters
                // Always return a copy to prevent mutation of internal state
                if (state.scope.subscriptionIds.size === 0 && 
                    state.scope.subscriptionNames.size === 0 &&
                    !state.scope.dayFrom && !state.scope.dayTo) {
                    return new Set(allRowIds); // Return copy, never allRowIds directly
                }
                
                // Apply subscription scope (ID-first: subscriptionIds is primary, subscriptionNames is for compatibility/debug)
                if (state.scope.subscriptionIds.size > 0 || state.scope.subscriptionNames.size > 0) {
                    const subRowIds = new Set();
                    // Primary path: subscriptionIds (GUID)
                    state.scope.subscriptionIds.forEach(subId => {
                        const rows = index.bySubscriptionId.get(subId);
                        if (rows) {
                            rows.forEach(rowId => subRowIds.add(rowId));
                        }
                    });
                    // Secondary path: subscriptionNames (for compatibility/debug, not primary)
                    state.scope.subscriptionNames.forEach(subName => {
                        const rows = index.bySubscriptionName.get(subName);
                        if (rows) {
                            rows.forEach(rowId => subRowIds.add(rowId));
                        }
                    });
                    scopeRowIds = subRowIds.size > 0 ? subRowIds : null; // Use null instead of empty Set to indicate "no filter applied"
                }
                
                // Apply day range scope (intersect with subscription scope if exists)
                // Use ISO string comparison (YYYY-MM-DD) - faster and deterministic
                if (state.scope.dayFrom || state.scope.dayTo) {
                    const dayRowIds = new Set();
                    for (const [day, rows] of index.byDay.entries()) {
                        // String comparison for ISO dates (YYYY-MM-DD) - no Date parsing needed
                        if (state.scope.dayFrom && day < state.scope.dayFrom) continue;
                        if (state.scope.dayTo && day > state.scope.dayTo) continue;
                        rows.forEach(rowId => dayRowIds.add(rowId));
                    }
                    
                    if (scopeRowIds) {
                        scopeRowIds = intersectSets(scopeRowIds, dayRowIds);
                    } else {
                        scopeRowIds = dayRowIds.size > 0 ? dayRowIds : null;
                    }
                }
                
                // CRITICAL: Always return a copy to prevent mutation of internal state
                // Never return allRowIds directly - always create new Set(allRowIds)
                // If scopeRowIds is null, it means no filters were applied, so return all rows
                // If scopeRowIds is an empty Set, it means filters were applied but matched nothing
                return scopeRowIds !== null ? scopeRowIds : new Set(allRowIds);
            }
            
            // Get rowIds from picks (UNION logic)
            function getPickedRowIdsUnion() {
                const pickedSets = [];
                
                // Canonical resourceKeys (Phase 3 - primary)
                if (state.picks.resourceKeys.size > 0) {
                    state.picks.resourceKeys.forEach(resourceKey => {
                        const rows = index.byResourceKey.get(resourceKey);
                        if (rows) pickedSets.push(rows);
                    });
                }
                
                // Legacy resourceIds (DEPRECATED - Phase 5: kept for backward compatibility, should be empty in runtime)
                // PR3A: No code writes to these anymore, only clears them. Will be removed in PR3B if possible.
                if (state.picks.resourceIds.size > 0) {
                    state.picks.resourceIds.forEach(resId => {
                        const rows = index.byResourceId.get(resId);
                        if (rows) pickedSets.push(rows);
                    });
                }
                
                // Legacy resourceNames (DEPRECATED - Phase 5: kept for backward compatibility, should be empty in runtime)
                if (state.picks.resourceNames.size > 0) {
                    state.picks.resourceNames.forEach(resName => {
                        const rows = index.byResourceName.get(resName);
                        if (rows) pickedSets.push(rows);
                    });
                }
                
                // Legacy resourceGroups (DEPRECATED - Phase 5: kept for backward compatibility, should be empty in runtime)
                if (state.picks.resourceGroups.size > 0) {
                    state.picks.resourceGroups.forEach(rg => {
                        const rows = index.byResourceGroup.get(rg);
                        if (rows) pickedSets.push(rows);
                    });
                }
                
                if (state.picks.meterNames.size > 0) {
                    state.picks.meterNames.forEach(meter => {
                        const rows = index.byMeter.get(meter);
                        if (rows) pickedSets.push(rows);
                    });
                }
                
                if (state.picks.categories.size > 0) {
                    state.picks.categories.forEach(cat => {
                        const rows = index.byCategory.get(cat);
                        if (rows) pickedSets.push(rows);
                    });
                }
                
                // P4-3: Subcategory picks (REVERT: scoped keys = subscriptionId|category|subcategory)
                // Use scoped index for subcategory picks
                if (state.picks.subcategories.size > 0) {
                    state.picks.subcategories.forEach(subcatKey => {
                        // Scoped key: subscriptionId|category|subcategory
                        const rows = index.bySubcategory.get(subcatKey);
                        if (rows) pickedSets.push(rows);
                    });
                }
                
                return unionSets(...pickedSets);
            }
            
            // Phase 5.2: Get active rowIds: scope ∩ top-layer picks (or just scope if no top-layer)
            function getActiveRowIds() {
                const scope = getScopeRowIds();
                const topLayer = getTopLayer();
                
                if (!topLayer) {
                    return scope;  // Baseline: no picks, return scope only
                }
                
                // Get picks from top-layer only
                const picked = getPickedRowIdsUnionFromLayer(topLayer);
                
                if (picked.size === 0) {
                    return scope;
                }
                
                return intersectSets(scope, picked);
            }
            
            // Helper: Get picked rowIds from a specific layer
            function getPickedRowIdsUnionFromLayer(layer) {
                const pickedSets = [];
                
                if (layer.picks.resourceKeys.size > 0) {
                    layer.picks.resourceKeys.forEach(resKey => {
                        const rows = index.byResourceKey.get(resKey);
                        if (rows) pickedSets.push(rows);
                    });
                }
                
                if (layer.picks.meterNames.size > 0) {
                    layer.picks.meterNames.forEach(meter => {
                        const rows = index.byMeter.get(meter);
                        if (rows) pickedSets.push(rows);
                    });
                }
                
                if (layer.picks.categories.size > 0) {
                    layer.picks.categories.forEach(cat => {
                        // Phase 5.2: Support scoped category keys (subscriptionId|category)
                        const rows = index.byCategoryScoped?.get(cat) || index.byCategory.get(cat);
                        if (rows) pickedSets.push(rows);
                    });
                }
                
                if (layer.picks.subcategories.size > 0) {
                    layer.picks.subcategories.forEach(subcatKey => {
                        const rows = index.bySubcategory.get(subcatKey);
                        if (rows) pickedSets.push(rows);
                    });
                }
                
                return unionSets(...pickedSets);
            }
            
            // Phase 5.2: State management functions - work with top-layer
            function togglePick(dimension, value, mode = 'toggle', source = null) {
                // Phase 5.2: If source provided, ensure top-layer and work with it
                let pickSet;
                if (source) {
                    const topLayer = ensureTopLayer(source);
                    pickSet = topLayer.picks[dimension];
                    if (!pickSet) {
                        console.warn('Unknown pick dimension in layer:', dimension);
                        return;
                    }
                } else {
                    // Fallback: work with state.picks (for backward compatibility during migration)
                    pickSet = state.picks[dimension];
                if (!pickSet) {
                    console.warn('Unknown pick dimension:', dimension);
                    return;
                    }
                }
                
                // REVERT: No canonicalization - use scoped keys as-is
                // Subcategories use subscriptionId|category|subcategory (scoped)
                // Categories use subscriptionId|category (scoped) in Cost by Subscription
                
                if (mode === 'replace') {
                    pickSet.clear();
                    pickSet.add(value);
                } else if (mode === 'toggle') {
                    if (pickSet.has(value)) {
                        pickSet.delete(value);
                        // Phase 5.2: Pop layer if empty after toggle
                        if (source) {
                            popTopLayerIfEmpty();
                        }
                    } else {
                        pickSet.add(value);
                    }
                } else if (mode === 'add') {
                    pickSet.add(value);
                } else if (mode === 'remove') {
                    pickSet.delete(value);
                    // Phase 5.2: Pop layer if empty after remove
                    if (source) {
                        popTopLayerIfEmpty();
                    }
                }
            }
            
            function setScopeSubscriptions(subIds) {
                state.scope.subscriptionIds.clear();
                if (Array.isArray(subIds)) {
                    subIds.forEach(id => state.scope.subscriptionIds.add(id));
                }
            }
            
            function setScopeSubscriptionNames(subNames) {
                state.scope.subscriptionNames.clear();
                if (Array.isArray(subNames)) {
                    subNames.forEach(name => state.scope.subscriptionNames.add(name));
                }
            }
            
            function setScopeDayRange(from, to) {
                state.scope.dayFrom = from;
                state.scope.dayTo = to;
            }
            
            function clearPicks() {
                Object.values(state.picks).forEach(set => set.clear());
            }
            
            // Phase 5.2: Clear picks in top-layer (for clear button)
            function clearTopLayerPicks(source) {
                clearTopLayer(source);
            }
            
            function clearScope() {
                state.scope.subscriptionIds.clear();
                state.scope.subscriptionNames.clear();
                state.scope.dayFrom = null;
                state.scope.dayTo = null;
            }
            
            // Phase 5.2: Filter stack (layers) helpers
            function getTopLayer() {
                return state.layers.length > 0 ? state.layers[state.layers.length - 1] : null;
            }
            
            function ensureTopLayer(source) {
                const top = getTopLayer();
                if (!top || top.source !== source) {
                    // Create new layer with empty picks
                    const newLayer = {
                        source: source,
                        picks: {
                            resourceKeys: new Set(),
                            meterNames: new Set(),
                            categories: new Set(),
                            subcategories: new Set()
                        }
                    };
                    state.layers.push(newLayer);
                    return newLayer;
                }
                return top;
            }
            
            function popTopLayerIfEmpty() {
                const top = getTopLayer();
                if (top) {
                    const allEmpty = Object.values(top.picks).every(set => set.size === 0);
                    if (allEmpty) {
                        state.layers.pop();
                    }
                }
            }
            
            function clearTopLayer(source) {
                const top = getTopLayer();
                if (top && top.source === source) {
                    Object.values(top.picks).forEach(set => set.clear());
                    popTopLayerIfEmpty();
                }
            }
            
            // Aggregation functions
            function sumCosts(rowIds) {
                let totalLocal = 0;
                let totalUSD = 0;
                
                rowIds.forEach(rowId => {
                    const row = factRows[rowId];
                    if (row) {
                        totalLocal += row.costLocal || 0;
                        totalUSD += row.costUSD || 0;
                    }
                });
                
                return { local: totalLocal, usd: totalUSD };
            }
            
            function trendByDay(rowIds) {
                const byDay = new Map();
                
                rowIds.forEach(rowId => {
                    const row = factRows[rowId];
                    if (!row || !row.day) return;
                    
                    if (!byDay.has(row.day)) {
                        byDay.set(row.day, { day: row.day, local: 0, usd: 0 });
                    }
                    
                    const dayData = byDay.get(row.day);
                    dayData.local += row.costLocal || 0;
                    dayData.usd += row.costUSD || 0;
                });
                
                // Convert to sorted array
                return Array.from(byDay.values()).sort((a, b) => a.day.localeCompare(b.day));
            }
            
            function groupByResource(rowIds) {
                const byResource = new Map();
                
                rowIds.forEach(rowId => {
                    const row = factRows[rowId];
                    if (!row || !row.resourceId) return;
                    
                    if (!byResource.has(row.resourceId)) {
                        byResource.set(row.resourceId, {
                            resourceId: row.resourceId,
                            resourceName: row.resourceName || '',
                            resourceGroup: row.resourceGroup || '',
                            subscriptionId: row.subscriptionId || '',
                            subscriptionName: row.subscriptionName || '',
                            local: 0,
                            usd: 0
                        });
                    }
                    
                    const resData = byResource.get(row.resourceId);
                    resData.local += row.costLocal || 0;
                    resData.usd += row.costUSD || 0;
                });
                
                return Array.from(byResource.values())
                    .sort((a, b) => b.local - a.local);
            }
            
            function groupByCategory(rowIds) {
                const byCategory = new Map();
                
                rowIds.forEach(rowId => {
                    const row = factRows[rowId];
                    if (!row || !row.meterCategory) return;
                    
                    if (!byCategory.has(row.meterCategory)) {
                        byCategory.set(row.meterCategory, {
                            category: row.meterCategory,
                            local: 0,
                            usd: 0
                        });
                    }
                    
                    const catData = byCategory.get(row.meterCategory);
                    catData.local += row.costLocal || 0;
                    catData.usd += row.costUSD || 0;
                });
                
                return Array.from(byCategory.values())
                    .sort((a, b) => b.local - a.local);
            }
            
            function groupByMeter(rowIds) {
                const byMeter = new Map();
                
                rowIds.forEach(rowId => {
                    const row = factRows[rowId];
                    if (!row || !row.meterName) return;
                    
                    if (!byMeter.has(row.meterName)) {
                        byMeter.set(row.meterName, {
                            meter: row.meterName,
                            category: row.meterCategory || '',
                            local: 0,
                            usd: 0
                        });
                    }
                    
                    const meterData = byMeter.get(row.meterName);
                    meterData.local += row.costLocal || 0;
                    meterData.usd += row.costUSD || 0;
                });
                
                return Array.from(byMeter.values())
                    .sort((a, b) => b.local - a.local);
            }
            
            // Helper: Get active resource keys from activeRowIds (for Meter Category resource highlighting)
            function getActiveResourceKeys() {
                const activeIds = getActiveRowIds();
                const resourceKeys = new Set();
                activeIds.forEach(rowId => {
                    const row = factRows[rowId];
                    if (row && row.resourceKey) {
                        resourceKeys.add(row.resourceKey);
                    }
                });
                return resourceKeys;
            }
            
            return {
                state,
                index,
                // Note: allRowIds is NOT exposed - always use getActiveRowIds() or return new Set(allRowIds)
                togglePick,
                setScopeSubscriptions,
                setScopeSubscriptionNames,
                setScopeDayRange,
                clearPicks,
                clearScope,
                getScopeRowIds,  // Expose for Meter Category (scope-only, ignores picks)
                getActiveRowIds,
                getActiveResourceKeys,  // Expose for Meter Category resource highlighting
                sumCosts,
                trendByDay,
                groupByResource,
                groupByCategory,
                groupByMeter,
                intersectSets, // Expose for chart breakdown (O(k) performance, iterates smallest set)
                // Phase 5.2: Filter stack (layers) API
                getTopLayer,
                ensureTopLayer,
                popTopLayerIfEmpty,
                clearTopLayerPicks,
                getPickedRowIdsUnionFromLayer  // Expose for yellow highlighting (cross-selected)
            };
        }
        
        // Initialize engine
        const engine = createEngine(factRows);
        console.log('Engine initialized with', factRows.length, 'fact rows');
        
        // Build subscription ID to name mapping (for UI filtering)
        function buildSubscriptionIdToNameMap() {
            const map = new Map();
            factRows.forEach(r => {
                if (r.subscriptionId && r.subscriptionName && !map.has(r.subscriptionId)) {
                    map.set(r.subscriptionId, r.subscriptionName);
                }
            });
            return map;
        }
        
        // Store mapping globally for reuse
        window._subIdToName = buildSubscriptionIdToNameMap();
        
        // Helper functions to extract identifiers from DOM elements
        function getSubscriptionFromElement(element) {
            const card = element.closest('[data-subscription]');
            return card ? card.getAttribute('data-subscription') : null;
        }
        
        function getCategoryFromElement(element) {
            const card = element.closest('[data-category]');
            return card ? card.getAttribute('data-category') : null;
        }
        
        function getSubcategoryFromElement(element) {
            const card = element.closest('[data-subcategory]');
            return card ? card.getAttribute('data-subcategory') : null;
        }
        
        function getMeterFromElement(element) {
            const card = element.closest('[data-meter]');
            return card ? card.getAttribute('data-meter') : null;
        }
        
        function getResourceFromElement(element) {
            const row = element.closest('[data-resource]');
            return row ? row.getAttribute('data-resource') : null;
        }
        
        // Helper function to create a key for sets in Maps
        function createSelectionKey(...args) {
            return args.filter(a => a != null).join('|');
        }
        
        // Helper function to check if a selection key matches
        function matchesSelectionKey(key, subscription, category, subcategory, meter) {
            const parts = key.split('|');
            let match = true;
            if (subscription && parts.indexOf(subscription) === -1) match = false;
            if (category && parts.indexOf(category) === -1) match = false;
            if (subcategory && parts.indexOf(subcategory) === -1) match = false;
            if (meter && parts.indexOf(meter) === -1) match = false;
            return match;
        }
        
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
                    // Hide content using display only (NOT visibility - breaks child rows)
                    categoryContent.style.display = 'none';
                    categoryContent.style.height = '0';
                    categoryContent.style.overflow = 'hidden';
                    // Remove any existing visibility property to avoid inherited hidden state
                    categoryContent.style.removeProperty('visibility');
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
                    // Hide content using display only (NOT visibility - breaks child rows)
                    subcategoryContent.removeAttribute('style');
                    subcategoryContent.style.setProperty('display', 'none', 'important');
                    subcategoryContent.style.setProperty('height', '0', 'important');
                    subcategoryContent.style.setProperty('overflow', 'hidden', 'important');
                    subcategoryContent.style.setProperty('max-height', '0', 'important');
                    subcategoryContent.style.setProperty('opacity', '0', 'important');
                    // Remove any existing visibility property to avoid inherited hidden state
                    subcategoryContent.style.removeProperty('visibility');
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
            // Phase 5.1: legacy subscription state removed - subscription state managed by engine scope
            
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
            // Phase 5.1: legacy category filter population removed
            
            // Initialize DOM-index after DOM is ready (Phase 3)
            initDomIndex();
            
            // Phase 5.2: Initialize event delegation for Meter Category table
            initMeterCategoryDelegatedClicks();
            
            // Phase 5.1: Use central refresh pipeline instead of manual updateChart() and renderCostByMeterCategory()
            refreshUIFromState({ skipMeterCategoryRerender: false });
            
            // Phase 5: Initial sync using central refresh pipeline
            refreshUIFromState({ skipMeterCategoryRerender: false }); // Initial render needs Meter Category
            
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
                                    return context.dataset.label + ': ' + currency + ' ' + context.parsed.y.toFixed(2);
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
                                    return currency + ' ' + value.toFixed(0);
                                }
                            }
                        }
                    }
                }
            });
        }
        
        // Phase 5.1: legacy category filter and day total functions removed - engine-only now
        
        // Helper function to extract cost value from various formats
        function getCostValue(cost) {
            if (cost === null || cost === undefined) return 0;
            if (typeof cost === 'number') return cost;
            if (typeof cost === 'object' && cost.CostLocal !== undefined) return cost.CostLocal || 0;
            console.warn('Unexpected cost type:', typeof cost, cost);
            return 0;
        }
        
        // Phase 5.1: Removed duplicate updateChart() function - keeping only the second one
        // Phase 5: Legacy chart filtering functions removed - engine-only now
        
        function updateChart() {
            if (!costChart) {
                console.warn('Chart not initialized yet, skipping update');
                return;
            }
            
            // Get active rowIds from engine
            const activeRowIds = engine.getActiveRowIds();
            const trend = engine.trendByDay(activeRowIds);
            
            // Build chart datasets based on current view
            const view = currentView || 'total';
            let datasets = [];
            let labels = [];
            
            if (trend.length === 0) {
                costChart.data.labels = [];
                costChart.data.datasets = [];
                costChart.update();
                return;
            }
            
            labels = trend.map(d => d.day);
            
            if (view === 'total') {
                // Total cost view - single dataset
                datasets = [{
                    label: 'Total Cost (' + currency + ')',
                    data: trend.map(d => d.local),
                    backgroundColor: chartColors[0],
                    borderColor: chartColors[0],
                    borderWidth: 1
                }];
            } else if (view === 'stacked-category' || view === 'category') {
                // Category breakdown - Top 15 categories with "Other" dataset
                // Edge case: empty activeRowIds (RETURN EARLY)
                if (activeRowIds.size === 0) {
                    datasets = [{
                        label: 'No data',
                        data: labels.map(() => 0)
                    }];
                } else {
                    // Use groupByCategory to get top categories
                const categories = engine.groupByCategory(activeRowIds);
                
                    // Ensure desc sort with tie-breaker for determinism
                    const sortedCategories = [...categories].sort((a, b) => {
                        const costDiff = b.local - a.local;
                        if (costDiff !== 0) return costDiff;
                        // Tie-breaker: alphabetical by category name for stability
                        return (a.category || '').localeCompare(b.category || '');
                    });
                    const top15Categories = sortedCategories.slice(0, 15);
                    
                    // Build datasets per category
                    top15Categories.forEach((cat, idx) => {
                        // Filter out null/empty category names
                        if (!cat.category || cat.category.trim() === '') return; // Skip, will be in "Other"
                        
                        // Use intersection: activeRowIds ∩ index.byCategory.get(cat) - O(k) performance
                    const catIndexRows = engine.index.byCategory.get(cat.category);
                    if (!catIndexRows) return;
                    
                    const categoryRowIds = engine.intersectSets(activeRowIds, catIndexRows);
                    const catTrend = engine.trendByDay(categoryRowIds);
                    const dayMap = new Map(catTrend.map(d => [d.day, d.local]));
                    
                    datasets.push({
                        label: cat.category,
                        data: labels.map(day => dayMap.get(day) || 0),
                        backgroundColor: chartColors[idx % chartColors.length],
                        borderColor: chartColors[idx % chartColors.length],
                        borderWidth: 1
                    });
                });
                    
                    // Build day-level totals for "Other" calculation
                    const trendForOther = engine.trendByDay(activeRowIds);
                    const totalByDay = new Map(trendForOther.map(d => [d.day, d.local]));
                    
                    // Calculate "Other" per day (OPTIMIZED: use index loop, not indexOf)
                    const otherData = [];
                    for (let i = 0; i < labels.length; i++) {
                        const day = labels[i];
                        const totalDay = totalByDay.get(day) || 0;
                        const top15Day = datasets.reduce((sum, ds) => {
                            return sum + (Number(ds.data[i]) || 0);
                        }, 0);
                        // Clamp to avoid rounding issues (small negative values can occur)
                        otherData.push(Math.max(0, totalDay - top15Day));
                    }
                    
                    const otherTotal = otherData.reduce((sum, val) => sum + val, 0);
                    if (otherTotal > 0.01) {
                        datasets.push({
                            label: 'Other',
                            data: otherData,
                            backgroundColor: 'rgba(128, 128, 128, 0.6)',
                            borderColor: 'rgba(128, 128, 128, 0.8)',
                            borderWidth: 1
                        });
                    }
                    // NOTE: "Other" will be moved to end AFTER all sorting (see P4-8)
                }
            } else if (view === 'stacked-subscription' || view === 'subscription') {
                // Subscription breakdown - Top 15 subscriptions with "Other" dataset
                // Edge case: empty activeRowIds (RETURN EARLY)
                if (activeRowIds.size === 0) {
                    datasets = [{
                        label: 'No data',
                        data: labels.map(() => 0)
                    }];
                } else {
                    // Collect subscriptions and their totals
                    const subscriptionMap = new Map();
                activeRowIds.forEach(rowId => {
                    const row = factRows[rowId];
                    if (row && row.subscriptionName) {
                            if (!subscriptionMap.has(row.subscriptionName)) {
                                subscriptionMap.set(row.subscriptionName, {
                                    name: row.subscriptionName,
                                    local: 0
                                });
                            }
                            subscriptionMap.get(row.subscriptionName).local += parseFloat(row.costLocal) || 0;
                        }
                    });
                    
                    // Sort subscriptions by total cost (desc) with tie-breaker
                    const sortedSubscriptions = Array.from(subscriptionMap.values()).sort((a, b) => {
                        const costDiff = b.local - a.local;
                        if (costDiff !== 0) return costDiff;
                        // Tie-breaker: alphabetical by subscription name for stability
                        return (a.name || '').localeCompare(b.name || '');
                    });
                    const top15Subscriptions = sortedSubscriptions.slice(0, 15);
                    
                    // Build datasets per subscription
                    top15Subscriptions.forEach((sub, idx) => {
                        // Filter out null/empty subscription names
                        if (!sub.name || sub.name.trim() === '') return; // Skip, will be in "Other"
                        
                    // Use intersection: activeRowIds ∩ index.bySubscriptionName.get(subName)
                        const subIndexRows = engine.index.bySubscriptionName.get(sub.name);
                    if (!subIndexRows) return;
                    
                    const subRowIds = engine.intersectSets(activeRowIds, subIndexRows);
                    const subTrend = engine.trendByDay(subRowIds);
                    const dayMap = new Map(subTrend.map(d => [d.day, d.local]));
                    
                    datasets.push({
                            label: sub.name,
                        data: labels.map(day => dayMap.get(day) || 0),
                            backgroundColor: chartColors[idx % chartColors.length],
                            borderColor: chartColors[idx % chartColors.length],
                        borderWidth: 1
                    });
                    });
                    
                    // Build day-level totals for "Other" calculation
                    const trendForOther = engine.trendByDay(activeRowIds);
                    const totalByDay = new Map(trendForOther.map(d => [d.day, d.local]));
                    
                    // Calculate "Other" per day (OPTIMIZED: use index loop, not indexOf)
                    const otherData = [];
                    for (let i = 0; i < labels.length; i++) {
                        const day = labels[i];
                        const totalDay = totalByDay.get(day) || 0;
                        const top15Day = datasets.reduce((sum, ds) => {
                            return sum + (Number(ds.data[i]) || 0);
                        }, 0);
                        // Clamp to avoid rounding issues (small negative values can occur)
                        otherData.push(Math.max(0, totalDay - top15Day));
                    }
                    
                    const otherTotal = otherData.reduce((sum, val) => sum + val, 0);
                    if (otherTotal > 0.01) {
                        datasets.push({
                            label: 'Other',
                            data: otherData,
                            backgroundColor: 'rgba(128, 128, 128, 0.6)',
                            borderColor: 'rgba(128, 128, 128, 0.8)',
                            borderWidth: 1
                        });
                    }
                    // NOTE: "Other" will be moved to end AFTER all sorting (see P4-8)
                }
            } else if (view === 'stacked-meter' || view === 'meter') {
                // Meter breakdown - Top 15 meters with "Other" dataset
                // Edge case: empty activeRowIds (RETURN EARLY)
                if (activeRowIds.size === 0) {
                    datasets = [{
                        label: 'No data',
                        data: labels.map(() => 0)
                        // Minimalistisk: använd default chartColors[0] styling (ingen special styling)
                    }];
                    // CRITICAL: Return early to skip all subsequent logic (no "Other" dataset, no sorting, etc.)
                    // Go directly to chart update at end of updateChart()
                    // Note: We'll set stacked and update chart below, so we need to continue
                } else {
                    // Use groupByMeter to get top meters
                    const meters = engine.groupByMeter(activeRowIds);
                    
                    // Ensure desc sort with tie-breaker for determinism
                    // CRITICAL: Use spread operator to avoid mutating groupBy result (may be reused elsewhere)
                    const sortedMeters = [...meters].sort((a, b) => {
                        const costDiff = b.local - a.local;
                        if (costDiff !== 0) return costDiff;
                        // Tie-breaker: alphabetical by meter name for stability
                        return (a.meter || '').localeCompare(b.meter || '');
                    });
                    const top15Meters = sortedMeters.slice(0, 15);
                    
                    // Build friendly meter name mapping (use meterName as friendly name, handle collisions)
                    // Note: meterName is already the friendly name displayed in tables
                    // Since groupByMeter groups by meterName, collisions are unlikely, but we handle them for robustness
                    const friendlyNameMap = new Map(); // canonical meterName -> friendly label (with collision handling)
                    const friendlyNameCount = new Map(); // friendly name -> count of occurrences
                    
                    // First pass: count occurrences of each friendly name
                    top15Meters.forEach((meter) => {
                        if (!meter.meter || meter.meter.trim() === '') return;
                        // Use meterName as friendly name (same as displayed in tables)
                        const friendlyName = meter.meter;
                        friendlyNameCount.set(friendlyName, (friendlyNameCount.get(friendlyName) || 0) + 1);
                    });
                    
                    // Second pass: assign labels, suffixing duplicates if needed
                    const friendlyNameUsage = new Map(); // friendly name -> usage counter
                    top15Meters.forEach((meter) => {
                        if (!meter.meter || meter.meter.trim() === '') return;
                        
                        const friendlyName = meter.meter;
                        const count = friendlyNameCount.get(friendlyName);
                        
                        if (count > 1) {
                            // Collision detected - suffix duplicates
                            const usage = (friendlyNameUsage.get(friendlyName) || 0) + 1;
                            friendlyNameUsage.set(friendlyName, usage);
                            // First occurrence keeps original name, subsequent ones get numbered
                            friendlyNameMap.set(meter.meter, usage === 1 ? friendlyName : friendlyName + ' (' + usage + ')');
                        } else {
                            // No collision - use friendly name as-is
                            friendlyNameMap.set(meter.meter, friendlyName);
                        }
                    });
                    
                    // Build datasets per meter
                    top15Meters.forEach((meter, idx) => {
                        // Filter out null/empty meter names
                        if (!meter.meter || meter.meter.trim() === '') return; // Skip, will be in "Other"
                        
                        // Use intersection: activeRowIds ∩ index.byMeter.get(meter) - O(k) performance
                        const meterIndexRows = engine.index.byMeter.get(meter.meter);
                        if (!meterIndexRows) return;
                        
                        const meterRowIds = engine.intersectSets(activeRowIds, meterIndexRows);
                        const meterTrend = engine.trendByDay(meterRowIds);
                        const dayMap = new Map(meterTrend.map(d => [d.day, d.local]));
                        
                        // Use friendly name for label (canonical meterName used for aggregation/index lookup)
                        const friendlyLabel = friendlyNameMap.get(meter.meter) || meter.meter;
                        
                        datasets.push({
                            label: friendlyLabel,
                            data: labels.map(day => dayMap.get(day) || 0),
                            backgroundColor: chartColors[idx % chartColors.length],
                            borderColor: chartColors[idx % chartColors.length],
                            borderWidth: 1
                        });
                    });
                    
                    // Build day-level totals for "Other" calculation
                    const trendForOther = engine.trendByDay(activeRowIds);
                    const totalByDay = new Map(trendForOther.map(d => [d.day, d.local]));
                    
                    // Calculate "Other" per day (OPTIMIZED: use index loop, not indexOf)
                    const otherData = [];
                    for (let i = 0; i < labels.length; i++) {
                        const day = labels[i];
                        const totalDay = totalByDay.get(day) || 0;
                        const top15Day = datasets.reduce((sum, ds) => {
                            return sum + (Number(ds.data[i]) || 0);
                        }, 0);
                        // Clamp to avoid rounding issues (small negative values can occur)
                        otherData.push(Math.max(0, totalDay - top15Day));
                    }
                    
                    const otherTotal = otherData.reduce((sum, val) => sum + val, 0);
                    if (otherTotal > 0.01) {
                        datasets.push({
                            label: 'Other',
                            data: otherData,
                            backgroundColor: 'rgba(128, 128, 128, 0.6)',
                            borderColor: 'rgba(128, 128, 128, 0.8)',
                            borderWidth: 1
                        });
                    }
                    // NOTE: "Other" will be moved to end AFTER all sorting (see P4-8)
                }
            } else if (view === 'stacked-resource' || view === 'resource') {
                // Resource breakdown - Top 15 resources with "Other" dataset
                // Edge case: empty activeRowIds (RETURN EARLY)
                if (activeRowIds.size === 0) {
                    datasets = [{
                        label: 'No data',
                        data: labels.map(() => 0)
                        // Minimalistisk: använd default chartColors[0] styling (ingen special styling)
                    }];
                    // CRITICAL: Skip all subsequent logic (no "Other" dataset, no sorting, etc.)
                    // Continue to chart update below
                } else {
                    // Use groupByResource to get top resources
                    const resources = engine.groupByResource(activeRowIds);
                    
                    // CRITICAL: Use spread operator to avoid mutating groupBy result (may be reused elsewhere)
                    const sortedResources = [...resources].sort((a, b) => {
                        const costDiff = b.local - a.local;
                        if (costDiff !== 0) return costDiff;
                        // Tie-breaker: alphabetical by resourceKey (canonical) for stability
                        return (a.resourceKey || a.resourceId || '').localeCompare(b.resourceKey || b.resourceId || '');
                    });
                    const top15Resources = sortedResources.slice(0, 15);
                    
                    // Build friendly resource name mapping (use resourceName as friendly name, handle collisions)
                    // Note: resourceName is already the friendly name displayed in tables
                    // Since groupByResource groups by resourceId, collisions are unlikely, but we handle them for robustness
                    const friendlyNameMap = new Map(); // canonical resourceKey -> friendly label (with collision handling)
                    const friendlyNameCount = new Map(); // friendly name -> count of occurrences
                    
                    // First pass: collect resourceKeys and resourceNames, count occurrences
                    top15Resources.forEach((resource) => {
                        if (!resource.resourceId) return;
                        
                        // Get resourceKey and resourceName from factRows
                        let resourceKey = null;
                        let resourceName = null;
                        for (const rowId of activeRowIds) {
                            const row = factRows[rowId];
                            if (row && row.resourceId === resource.resourceId) {
                                resourceKey = row.resourceKey || row.resourceId;
                                resourceName = row.resourceName || resource.resourceName || resourceKey;
                                break;
                            }
                        }
                        if (!resourceKey) resourceKey = resource.resourceId;
                        if (!resourceName) resourceName = resource.resourceName || resource.resourceId || resourceKey || 'Unknown';
                        
                        // Track usage count for collision detection
                        friendlyNameCount.set(resourceName, (friendlyNameCount.get(resourceName) || 0) + 1);
                    });
                    
                    // Second pass: assign labels, suffixing duplicates if needed
                    const friendlyNameUsage = new Map(); // friendly name -> usage counter
                    top15Resources.forEach((resource) => {
                        if (!resource.resourceId) return;
                        
                        // Get resourceKey and resourceName from factRows
                        let resourceKey = null;
                        let resourceName = null;
                        for (const rowId of activeRowIds) {
                            const row = factRows[rowId];
                            if (row && row.resourceId === resource.resourceId) {
                                resourceKey = row.resourceKey || row.resourceId;
                                resourceName = row.resourceName || resource.resourceName || resourceKey;
                                break;
                            }
                        }
                        if (!resourceKey) resourceKey = resource.resourceId;
                        if (!resourceName) resourceName = resource.resourceName || resource.resourceId || resourceKey || 'Unknown';
                        
                        const count = friendlyNameCount.get(resourceName);
                        if (count > 1) {
                            // Collision detected - suffix duplicates
                            const usage = (friendlyNameUsage.get(resourceName) || 0) + 1;
                            friendlyNameUsage.set(resourceName, usage);
                            // First occurrence keeps original name, subsequent ones get numbered
                            friendlyNameMap.set(resourceKey, usage === 1 ? resourceName : resourceName + ' (' + usage + ')');
                        } else {
                            // No collision - use friendly name as-is
                            friendlyNameMap.set(resourceKey, resourceName);
                        }
                    });
                    
                    // Build datasets per resource
                    top15Resources.forEach((resource, idx) => {
                        // CANONICAL KEY (CRITICAL): Get resourceKey from factRows
                        // groupByResource uses resourceId as key, but we need resourceKey for index lookup
                        let resourceKey = null;
                        for (const rowId of activeRowIds) {
                            const row = factRows[rowId];
                            if (row && row.resourceId === resource.resourceId) {
                                resourceKey = row.resourceKey || row.resourceId;
                                break;
                            }
                        }
                        // If no resourceKey found, use resourceId as fallback
                        if (!resourceKey) {
                            resourceKey = resource.resourceId;
                        }
                        
                        // Filter out null/empty resource keys
                        if (!resourceKey || resourceKey.trim() === '') return; // Skip, will be in "Other"
                        
                        // CANONICAL KEY (CRITICAL): Use resourceKey consistently
                        // Index lookup: byResourceKey (primär)
                        let resourceIndexRows = engine.index.byResourceKey.get(resourceKey);
                        
                        // Fallback byResourceId: Använd bara om resourceKey saknas OCH indexet finns
                        if (!resourceIndexRows && resource.resourceId && engine.index.byResourceId) {
                            // Fallback: use byResourceId only if index exists
                            resourceIndexRows = engine.index.byResourceId.get(resource.resourceId);
                        }
                        
                        // If still no index, fall back to scanning activeRowIds per day
                        if (!resourceIndexRows) {
                            // Fallback: scan activeRowIds for this resource
                            const resourceRowIds = new Set();
                            activeRowIds.forEach(rowId => {
                                const row = factRows[rowId];
                                if (row && (row.resourceKey === resourceKey || row.resourceId === resource.resourceId)) {
                                    resourceRowIds.add(rowId);
                                }
                            });
                            
                            if (resourceRowIds.size > 0) {
                                const resourceTrend = engine.trendByDay(resourceRowIds);
                                const dayMap = new Map(resourceTrend.map(d => [d.day, d.local]));
                                
                                // Use friendly name for label (same as displayed in tables, with collision handling)
                                // resourceKey used for aggregation/index lookup, friendlyName for display
                                const friendlyLabel = friendlyNameMap.get(resourceKey) || resourceKey || resource.resourceId || 'Unknown';
                                
                                datasets.push({
                                    label: friendlyLabel,
                                    data: labels.map(day => dayMap.get(day) || 0),
                                    backgroundColor: chartColors[idx % chartColors.length],
                                    borderColor: chartColors[idx % chartColors.length],
                                    borderWidth: 1
                                });
                            }
                            return;
                        }
                        
                        // Use intersection: activeRowIds ∩ index.byResourceKey.get(resourceKey) - O(k) performance
                        const resourceRowIds = engine.intersectSets(activeRowIds, resourceIndexRows);
                        const resourceTrend = engine.trendByDay(resourceRowIds);
                        const dayMap = new Map(resourceTrend.map(d => [d.day, d.local]));
                        
                        // Use friendly name for label (same as displayed in tables, with collision handling)
                        // resourceKey used for aggregation/index lookup, friendlyName for display
                        const friendlyLabel = friendlyNameMap.get(resourceKey) || resourceKey || resource.resourceId || 'Unknown';
                        
                        datasets.push({
                            label: friendlyLabel,
                            data: labels.map(day => dayMap.get(day) || 0),
                            backgroundColor: chartColors[idx % chartColors.length],
                            borderColor: chartColors[idx % chartColors.length],
                            borderWidth: 1
                        });
                    });
                    
                    // Build day-level totals for "Other" calculation
                    const trendForOther = engine.trendByDay(activeRowIds);
                    const totalByDay = new Map(trendForOther.map(d => [d.day, d.local]));
                    
                    // Calculate "Other" per day (OPTIMIZED: use index loop, not indexOf)
                    const otherData = [];
                    for (let i = 0; i < labels.length; i++) {
                        const day = labels[i];
                        const totalDay = totalByDay.get(day) || 0;
                        const top15Day = datasets.reduce((sum, ds) => {
                            return sum + (Number(ds.data[i]) || 0);
                        }, 0);
                        // Clamp to avoid rounding issues (small negative values can occur)
                        otherData.push(Math.max(0, totalDay - top15Day));
                    }
                    
                    const otherTotal = otherData.reduce((sum, val) => sum + val, 0);
                    if (otherTotal > 0.01) {
                        datasets.push({
                            label: 'Other',
                            data: otherData,
                            backgroundColor: 'rgba(128, 128, 128, 0.6)',
                            borderColor: 'rgba(128, 128, 128, 0.8)',
                            borderWidth: 1
                        });
                    }
                    // NOTE: "Other" will be moved to end AFTER all sorting (see P4-8)
                }
            } else {
                // Fallback for other views - use total for now
                datasets = [{
                    label: 'Total Cost (' + currency + ')',
                    data: trend.map(d => d.local),
                    backgroundColor: chartColors[0],
                    borderColor: chartColors[0],
                    borderWidth: 1
                }];
            }
            
            // Helper function to calculate total for a dataset
            function datasetTotal(ds) {
                return (ds.data || []).reduce((a, v) => a + (Number(v) || 0), 0);
            }
            
            // For stacked views: draw largest at bottom (first dataset)
            const stacked = view !== 'total';
            if (stacked && Array.isArray(datasets) && datasets.length > 1) {
                datasets.sort((a, b) => datasetTotal(b) - datasetTotal(a)); // DESC
            }
            
            // P4-8: Move "Other" Dataset to End (After All Sorting)
            // CRITICAL: Move "Other" to end of array (always last in stack, visually on top)
            // This must happen AFTER all dataset sorting to ensure "Other" is always last
            // IMPORTANT: Apply to all views that create "Other" dataset (all stacked views now use Top 15 + Other)
            // to avoid moving a legitimate dataset that happens to be named "Other"
            const viewsWithOther = ['stacked-category', 'category', 'stacked-subscription', 'subscription', 'stacked-meter', 'meter', 'stacked-resource', 'resource'];
            if (viewsWithOther.includes(view)) {
                const otherIndex = datasets.findIndex(ds => ds.label === 'Other');
                if (otherIndex >= 0 && otherIndex < datasets.length - 1) {
                    const otherDataset = datasets.splice(otherIndex, 1)[0];
                    datasets.push(otherDataset);
                }
            }
            
            // Update chart
            costChart.options.scales.x.stacked = stacked;
            costChart.options.scales.y.stacked = stacked;
            costChart.data.labels = labels;
            costChart.data.datasets = datasets;
            costChart.update();
            
            // Dev-mode validation (optional - add to updateSummaryCards and updateChart)
            if (window.DEBUG_COST_REPORT) {
                const activeRowIdsCheck = engine.getActiveRowIds();
                const totalsCheck = engine.sumCosts(activeRowIdsCheck);
                const trendCheck = engine.trendByDay(activeRowIdsCheck);
                const chartTotal = trendCheck.reduce((sum, d) => sum + d.local, 0);
                const diff = Math.abs(totalsCheck.local - chartTotal);
                const epsilon = 0.01; // Allow small floating point differences
                if (diff > epsilon) {
                    console.warn('⚠️ Mismatch detected: totals.local =', totalsCheck.local, 'chartTotal =', chartTotal, 'diff =', diff);
                    console.warn('Active rowIds:', activeRowIdsCheck.size, 'rows');
                } else {
                    console.log('✓ Validation passed: totals match chart (', totalsCheck.local, 'SEK)');
                }
            }
        }
        
        // DOM-index for resource selection visuals (Phase 3: replaces CSS.escape, more robust)
        const domIndex = {
            byResourceKey: new Map()
        };
        
        // Track previously selected resource keys for optimized updates
        let previousSelectedResourceKeys = new Set();
        
        // Initialize DOM-index (build once after DOM is ready)
        function initDomIndex() {
            const byResourceKey = new Map();
            
            // Index all rows that advertise a resource key.
            // If you want stricter scoping, use: 'tr.clickable[data-resource-key]'
            const rows = document.querySelectorAll('tr[data-resource-key]');
            
            rows.forEach(tr => {
                const key = tr.getAttribute('data-resource-key');
                if (!key) return;
                
                let arr = byResourceKey.get(key);
                if (!arr) {
                    arr = [];
                    byResourceKey.set(key, arr);
                }
                arr.push(tr);
            });
            
            const idx = { byResourceKey };
            
            // Update local domIndex variable (for backward compatibility)
            domIndex.byResourceKey.clear();
            byResourceKey.forEach((arr, key) => {
                domIndex.byResourceKey.set(key, arr);
            });
            
            // Expose globally for updateResourceSelectionVisual() and debugging
            window.domIndex = idx;
            
            return idx;
        }
        
        // Visual update for resource selections (Phase 3: DOM-index/cache, optimized O(#val) instead of O(#DOM-nodes))
        // Phase 5: syncUIFromEngine_OLD removed - all callsites now use refreshUIFromState() directly
        
        // Phase 5: Central refresh pipeline - single source of truth for UI updates
        // RAF debouncing for chart updates to handle ctrl-click storms
        let chartUpdateRafId = null;
        function refreshUIFromState(options = {}) {
            // Phase 5.2: Calculate visual context (top-layer state)
            const top = engine?.getTopLayer?.() || null;
            const topActive = engine?.getActiveRowIds?.() || new Set();
            const topSource = top?.source ?? null;
            
            // 1. Summary cards (immediate)
            updateSummaryCards();
            
            // 2. Meter Category rerender (FÖRE visuals - annars "blåser bort" markeringsklasser)
            if (!options.skipMeterCategoryRerender && typeof renderCostByMeterCategory === 'function') {
                renderCostByMeterCategory();
                // Phase 5.1 F: Re-index DOM after MeterCategory rerender (before visual updates)
                initDomIndex();
            }
            
            // 3. Visual updates (efter rerender) - pass visual context
            updateResourceSelectionVisual(top, topActive, topSource);
            updateHeaderSelectionVisual(top, topActive, topSource);
            
            // 4. Chart update (debounced via RAF, sist)
            if (chartUpdateRafId !== null) {
                cancelAnimationFrame(chartUpdateRafId);
            }
            chartUpdateRafId = requestAnimationFrame(() => {
                updateChart();
                chartUpdateRafId = null;
            });
        }
        
        // Phase 5: Alias functions removed - all callsites now use refreshUIFromState() directly
        
        // Phase 5.2: Update header visual sync to use top-layer logic
        function updateHeaderSelectionVisual(top, topActive, topSource) {
            if (!engine) return;
            
            // Phase 5.2: Clear all header markers first - scoped to prevent leakage
            const meterCategoryRoot = document.getElementById('meterCategoryDynamicRoot');
            const costBreakdownRoot = document.getElementById('costBreakdownRoot');
            
            if (meterCategoryRoot) {
                meterCategoryRoot.querySelectorAll('.expandable__header, .category-header, .subcategory-header, .meter-header').forEach(el => {
                    el.classList.remove('pick-selected', 'cross-selected', 'filter-selected');
                });
            }
            
            if (costBreakdownRoot) {
                costBreakdownRoot.querySelectorAll('.expandable__header, .category-header, .subcategory-header, .meter-header').forEach(el => {
                    el.classList.remove('pick-selected', 'cross-selected', 'filter-selected');
                });
            }
            
            // Phase 5.2: Get picks from top-layer
            const topLayerPicks = top?.picks || {
                categories: new Set(),
                subcategories: new Set(),
                meterNames: new Set(),
                resourceKeys: new Set()
            };
            
            // --- APPLY BLUE (subscription top-layer) ---
            // Robust application using document.querySelector (not scoped to costBreakdownRoot)
            if (topSource === 'subscription') {
                const catKeys = Array.from(topLayerPicks.categories || []);
                const subKeys = Array.from(topLayerPicks.subcategories || []);
                
                catKeys.forEach(key => {
                    const el = document.querySelector('[data-category-key="' + CSS.escape(key) + '"]');
                    if (el) el.classList.add('pick-selected');
                });
                
                subKeys.forEach(key => {
                    const el = document.querySelector('[data-subcategory-key="' + CSS.escape(key) + '"]');
                    if (el) el.classList.add('pick-selected');
                });
                
                // Temporär debug-logg (ta bort senare)
                console.log('DBG apply subscription picks', {
                    catKeys: Array.from(topLayerPicks.categories || []).slice(0, 3),
                    subKeys: Array.from(topLayerPicks.subcategories || []).slice(0, 3),
                    pickSelectedCount: document.querySelectorAll('.pick-selected').length
                });
            }
            
            // Update category headers - Phase 5.2: Hard-scope to correct roots, use data-category-key
            // Cost Breakdown category headers (scoped to costBreakdownRoot)
            if (costBreakdownRoot) {
                // Phase 5.2: Use data-category-key for exact matching (no text matching)
                if (topSource === 'subscription') {
                    // Top-layer is from subscription table: show blue for subscription picks
                    // (Already applied above with document.querySelector, but keep for compatibility)
                    topLayerPicks.categories.forEach(categoryKey => {
                        const elements = costBreakdownRoot.querySelectorAll('[data-category-key="' + categoryKey + '"]');
                        elements.forEach(element => {
                            element.classList.add('pick-selected');
                        });
                    });
                } else if (topSource === 'meter') {
                    // Top-layer is from meter table: show yellow for affected categories
                    if (topActive && topActive.size > 0 && engine.index.byCategoryScoped) {
                        engine.index.byCategoryScoped.forEach((catRowIds, categoryKey) => {
                            const intersection = engine.intersectSets(topActive, catRowIds);
                            if (intersection.size > 0) {
                                const elements = costBreakdownRoot.querySelectorAll('[data-category-key="' + categoryKey + '"]');
                                elements.forEach(element => {
                                    element.classList.add('cross-selected');
                                });
                            }
                        });
                    }
                }
                // If topSource === null: no markers (baseline)
            }
            
            // Meter Category category headers (scoped to meterCategoryRoot) - no visual markers from picks
            if (meterCategoryRoot) {
                meterCategoryRoot.querySelectorAll('.expandable__header.category-header[data-category], .category-header[data-category]').forEach(element => {
                    // Meter Category headers should not be marked by picks
                    element.classList.remove('pick-selected', 'cross-selected', 'filter-selected');
                });
            }
            
            // Update subcategory headers - Phase 5.2: Hard-scope to correct roots, use data-subcategory-key
            // Cost Breakdown subcategory headers (scoped to costBreakdownRoot)
            if (costBreakdownRoot) {
                // Phase 5.2: Use data-subcategory-key for exact matching (no text matching)
                if (topSource === 'subscription') {
                    // Top-layer is from subscription table: show blue for subscription picks
                    topLayerPicks.subcategories.forEach(scopedKey => {
                        // Only match scoped keys (3 parts: subscriptionId|category|subcategory)
                        const parts = scopedKey.split('|');
                        if (parts.length === 3) {
                            const elements = costBreakdownRoot.querySelectorAll('[data-subcategory-key="' + scopedKey + '"]');
                            elements.forEach(element => {
                    element.classList.add('pick-selected');
                            });
                        }
                    });
                } else if (topSource === 'meter') {
                    // Top-layer is from meter table: show yellow for affected subcategories
                    if (topActive && topActive.size > 0 && engine.index.bySubcategory) {
                        engine.index.bySubcategory.forEach((subcatRowIds, scopedKey) => {
                            // Only match scoped keys (3 parts: subscriptionId|category|subcategory)
                const parts = scopedKey.split('|');
                            if (parts.length === 3) {
                                const intersection = engine.intersectSets(topActive, subcatRowIds);
                                if (intersection.size > 0) {
                                    const elements = costBreakdownRoot.querySelectorAll('[data-subcategory-key="' + scopedKey + '"]');
                                    elements.forEach(element => {
                                        element.classList.add('cross-selected');
                                    });
                                }
                            }
                        });
                    }
                }
            }
            
            // Meter Category subcategory headers (scoped to meterCategoryRoot) - no visual markers from picks
            if (meterCategoryRoot) {
                meterCategoryRoot.querySelectorAll('.expandable__header.subcategory-header[data-subcategory-key]').forEach(element => {
                    // Meter Category headers should not be marked by scoped picks
                    element.classList.remove('pick-selected', 'cross-selected', 'filter-selected');
                });
            }
            
            // Update meter headers - Phase 5.2: Hard-scope to correct roots
            // (meterCategoryRoot and costBreakdownRoot already declared at function start)
            
            // Meter Category meter headers (scoped to meterCategoryRoot)
            if (meterCategoryRoot) {
                meterCategoryRoot.querySelectorAll('.expandable__header.meter-header[data-meter], .meter-header[data-meter]').forEach(element => {
                    const meter = element.getAttribute('data-meter');
                    
                    if (topSource === 'meter') {
                        // Top-layer is from meter table: show blue for meter picks
                        if (topLayerPicks.meterNames.has(meter)) {
                            element.classList.add('pick-selected');
                        }
                    } else if (topSource === 'subscription') {
                        // Top-layer is from subscription table: show yellow for affected meters
                        if (topActive && topActive.size > 0 && engine.index.byMeter) {
                            const meterRowIds = engine.index.byMeter.get(meter);
                            if (meterRowIds) {
                                const intersection = engine.intersectSets(topActive, meterRowIds);
                                if (intersection.size > 0) {
                                    element.classList.add('cross-selected');
                                }
                            }
                        }
                    }
                    // If topSource === null: no markers in Meter Category
                });
            }
            
            // Cost Breakdown meter headers (scoped to costBreakdownRoot)
            if (costBreakdownRoot) {
                // Cache: meter -> Set(resourceKeys) för snabb subset-check
                const meterToResourceKeys = new Map();
                function getMeterResourceKeys(meter) {
                    if (meterToResourceKeys.has(meter)) return meterToResourceKeys.get(meter);
                    
                    const rowIds = engine.index.byMeter?.get(meter);
                    const set = new Set();
                    if (rowIds && typeof factRows !== 'undefined') {
                        rowIds.forEach(rowId => {
                            const rk = factRows[rowId]?.resourceKey;
                            if (rk) set.add(rk);
                        });
                    }
                    meterToResourceKeys.set(meter, set);
                    return set;
                }
                
                function isSubset(subSet, superSet) {
                    for (const v of subSet) if (!superSet.has(v)) return false;
                    return true;
                }
                
                costBreakdownRoot.querySelectorAll('.expandable__header.meter-header[data-meter], .meter-header[data-meter]').forEach(element => {
                    const meter = element.getAttribute('data-meter');
                    
                    // 1) Om metern är explicit vald (meterNames) -> BLÅ
                    if (topSource === 'meter' && topLayerPicks.meterNames?.has(meter)) {
                        element.classList.add('pick-selected');
                        return;
                    }
                    
                    // 2) Om top är resourceKeys (meter-top) -> markera meter ENDAST om alla resurser under metern är valda
                    if (topSource === 'meter' && topLayerPicks.resourceKeys?.size > 0) {
                        const meterResources = getMeterResourceKeys(meter);
                        if (meterResources.size > 0 && isSubset(meterResources, topLayerPicks.resourceKeys)) {
                            element.classList.add('cross-selected'); // "complete coverage"
                        }
                        return; // annars: ingen markering
                    }
                    
                    // 3) Om top är subscription -> gul om påverkas (intersection > 0 är ok här)
                    if (topSource === 'subscription') {
                        if (topActive && topActive.size > 0 && engine.index.byMeter) {
                            const meterRowIds = engine.index.byMeter.get(meter);
                            if (meterRowIds) {
                                const intersection = engine.intersectSets(topActive, meterRowIds);
                                if (intersection.size > 0) {
                                    element.classList.add('cross-selected');
                                }
                            }
                        }
                    }
                    // If topSource === null: no markers in Cost Breakdown
                });
            }
            
            // Safety check: blue always wins over yellow
            document.querySelectorAll('.pick-selected').forEach(el => {
                el.classList.remove('cross-selected');
            });
        }
        
        // Phase 5.2: Update resource visual sync to use top-layer logic
        function updateResourceSelectionVisual(top, topActive, topSource) {
            // Use window.domIndex if available (global), otherwise fallback to local domIndex
            const domIdx = window.domIndex || domIndex;
            if (!domIdx || !domIdx.byResourceKey) {
                console.warn('DOM index not available, skipping visual update');
                return;
            }
            
            // Phase 5.2: Get picks from top-layer (if exists), otherwise empty
            const topLayerPicks = top?.picks?.resourceKeys || new Set();
            
            // Phase 5.2: Get active resource keys from topActive (for yellow highlighting)
            // Convert topActive (rowIds) to resourceKeys
            const activeResourceKeys = new Set();
            if (topActive && topActive.size > 0 && typeof factRows !== 'undefined' && factRows) {
                topActive.forEach(rowId => {
                    const row = factRows[rowId];
                    if (row && row.resourceKey) {
                        activeResourceKeys.add(row.resourceKey);
                    }
                });
            }
            
            // Phase 5.2: Clear all visual markers first
            document.querySelectorAll('.pick-selected, .cross-selected').forEach(el => {
                el.classList.remove('pick-selected', 'cross-selected', 'chart-selected', 'filter-selected');
            });
            
            // Phase 5.2: Apply visual markers based on top-layer source
            // Meter Category table (meterCategoryDynamicRoot)
            const meterCategoryRoot = document.getElementById('meterCategoryDynamicRoot');
            const costBreakdownRoot = document.getElementById('costBreakdownRoot');
            
            if (meterCategoryRoot) {
                if (topSource === 'meter') {
                    // Top-layer is from meter table: show blue for meter picks, no yellow
                    topLayerPicks.forEach(resourceKey => {
                        const elements = domIdx.byResourceKey.get(resourceKey) || [];
                        elements.forEach(el => {
                            if (meterCategoryRoot.contains(el)) {
                                el.classList.add('pick-selected');
                            }
                        });
                    });
                } else if (topSource === 'subscription') {
                    // Top-layer is from subscription table: show yellow for affected resources
            activeResourceKeys.forEach(resourceKey => {
                    const elements = domIdx.byResourceKey.get(resourceKey) || [];
                    elements.forEach(el => {
                            if (meterCategoryRoot.contains(el) && !topLayerPicks.has(resourceKey)) {
                            el.classList.add('cross-selected');
                            }
                        });
                    });
                }
                // If topSource === null: no markers (baseline)
            }
            
            // Cost Breakdown table (subscription table)
            // (costBreakdownRoot already declared above)
            if (costBreakdownRoot) {
                if (topSource === 'subscription') {
                    // Top-layer is from subscription table: blue handled in updateHeaderSelectionVisual
                    // Yellow for resources affected by subscription picks (if any)
                    // (Resources in subscription table are handled via headers, not rows)
                } else if (topSource === 'meter') {
                    // Top-layer is from meter table: show yellow for affected resources
                    activeResourceKeys.forEach(resourceKey => {
                    const elements = domIdx.byResourceKey.get(resourceKey) || [];
                    elements.forEach(el => {
                            if (costBreakdownRoot.contains(el) && !topLayerPicks.has(resourceKey)) {
                                el.classList.add('cross-selected');
                            }
                        });
                    });
                }
                // If topSource === null: no markers (baseline)
            }
            
            // Other tables (generic resource tables) - Phase 5.2: Scoped to costBreakdownRoot only
            if (costBreakdownRoot) {
                costBreakdownRoot.querySelectorAll('.cost-table tbody tr[data-resource-key], .resource-table tbody tr[data-resource-key]').forEach(row => {
                    const resourceKey = row.getAttribute('data-resource-key');
                    if (!resourceKey) return;
                    
                    if (topSource === 'meter' && topLayerPicks.has(resourceKey)) {
                        row.classList.add('pick-selected');
                    } else if (topSource === 'subscription' && activeResourceKeys.has(resourceKey) && !topLayerPicks.has(resourceKey)) {
                        row.classList.add('cross-selected');
                    } else if (topSource === 'meter' && activeResourceKeys.has(resourceKey) && !topLayerPicks.has(resourceKey)) {
                        // Meter picks affecting other tables
                        row.classList.add('cross-selected');
                    }
                });
            }
            
            // Phase 5.2: Defensive cleanup - remove cross-selected outside meter-root when topSource === 'subscription'
            if (topSource === 'subscription' && meterCategoryRoot) {
                document.querySelectorAll('.cross-selected').forEach(el => {
                    if (!meterCategoryRoot.contains(el)) {
                        el.classList.remove('cross-selected');
                    }
                });
            }
            
            // Safety check: blue always wins over yellow
            document.querySelectorAll('.pick-selected').forEach(el => {
                el.classList.remove('cross-selected');
            });
            
            // Update previous set
            previousSelectedResourceKeys = new Set(topLayerPicks);
            
            // Update clear button visibility (engine picks changed)
            updateClearSelectionsButtonVisibility();
        }
        
        // Phase 5.2: Event delegation for Meter Category table (#meterCategoryDynamicRoot)
        // All clicks in meter table should create meter-layer with source='meter'
        function initMeterCategoryDelegatedClicks() {
            const root = document.getElementById('meterCategoryDynamicRoot');
            if (!root || root.__delegationBound) return;
            root.__delegationBound = true;

            root.addEventListener('click', (event) => {
                // Protect against clicks on links/buttons
                if (event.target.closest('a,button,input,select,textarea,label')) return;
                
                // Phase 5.2: Resource row click in meter table → handleResourceSelection with source='meter'
                const tr = event.target.closest('tr.clickable[data-resource-key]');
                if (tr) {
                    event.stopPropagation(); // Prevent collapse/expand of parent sections
                    // Only handle Ctrl/Cmd clicks for picks
                    if (event.ctrlKey || event.metaKey) {
                        handleResourceSelection(tr, event, 'meter');
                    }
                    return;
                }

                // Phase 5.2: Meter header click in meter table → handleMeterSelection with source='meter'
                const meterHeader = event.target.closest('.expandable__header.meter-header');
                if (meterHeader && !meterHeader.closest('#costBreakdownRoot')) {
                    // Only handle if in meter table (not in Cost Breakdown)
                    // handleMeterSelection will be called via onclick, but we override source here
                    // Actually, we let onclick handle it and fix handleMeterSelection instead
                    return;
                }

                // Phase 5.2: Category header click in meter table → handleCategorySelection with source='meter'
                const catHeader = event.target.closest('.expandable__header.category-header[data-category]');
                if (catHeader && !catHeader.closest('#costBreakdownRoot')) {
                    // Only handle if in meter table (not in Cost Breakdown)
                    // handleCategorySelection will be called via onclick, but we override source
                    // Actually, we let onclick handle it and fix handleCategorySelection instead
                    return;
                }

                // Phase 5.2: Subcategory header click in meter table → handleSubcategorySelection with source='meter'
                const subHeader = event.target.closest('.expandable__header.subcategory-header[data-subcategory]');
                if (subHeader && !subHeader.closest('#costBreakdownRoot')) {
                    // Only handle if in meter table (not in Cost Breakdown)
                    // handleSubcategorySelection will be called via onclick, but we override source
                    // Actually, we let onclick handle it and fix handleSubcategorySelection instead
                    return;
                }
            }, true); // Use capture phase to catch before inline handlers
        }
        
        // Event delegation for resource clicks (Phase 3: use data-resource-key, canonical keys)
        // Resource tables are in multiple locations (category sections, subscription sections)
        // Use event delegation on document but check for data-resource-key attribute
        document.addEventListener('click', function(e) {
            // Phase 5.2: Skip if click is in meter table (handled by dedicated delegation)
            if (e.target.closest('#meterCategoryDynamicRoot')) return;
            
            // Protect against clicks on links/buttons in row (links should work without toggling selection)
            if (e.target.closest('a,button,input,select,textarea,label')) return;
            
            // A) Stop collapse on resource click - prevent event from bubbling to expandable handlers
            const row = e.target.closest('tr.clickable[data-resource-key]');
            if (!row) return;
            
            // Stop propagation to prevent collapse/expand of parent expandable sections
            e.stopPropagation();
            
            // B) Get resource key
            const key = row.getAttribute('data-resource-key') || row.dataset.resourceKey;
            if (!key) return;
            
            if (row.tagName !== 'TR') return;
            
            // Phase 5.2: Use handleResourceSelection with proper source detection
            // Only handle Ctrl/Cmd clicks for picks
            if (e.ctrlKey || e.metaKey) {
                // Detect source from element location (Cost Breakdown = subscription, otherwise = meter)
                const isInCostBreakdown = row.closest('#costBreakdownRoot') !== null;
                const source = isInCostBreakdown ? 'subscription' : 'meter';
                handleResourceSelection(row, e, source);
            }
            
            // Note: Single-click behavior removed in Phase 5.2 - only Ctrl/Cmd clicks create picks
            // If you need single-click behavior, it should be handled separately
        });
        
        // Phase 5: Legacy chart functions removed - engine-only now
        
        // Phase 5: Chart view change handler - use central refresh pipeline
        function updateChartView() {
            currentView = document.getElementById('chartView').value;
            refreshUIFromState({ skipMeterCategoryRerender: true }); // Chart view change doesn't affect Meter Category data
        }
        
        // Phase 5.1: legacy category filter handler removed - category filter UI removed
        
        // Hard hide subscription cards not in scope (GUID-based)
        // This hides entire subscription-card containers in "Cost by Subscription" section
        function applySubscriptionScopeToCards() {
            const scopeIds = engine.state.scope.subscriptionIds || new Set();
            
            document.querySelectorAll('.category-card.subscription-card[data-subscription]').forEach(card => {
                const sid = card.getAttribute('data-subscription'); // GUID
                const show = (scopeIds.size === 0) || scopeIds.has(sid);
                
                // Hard hide: use display only (not visibility)
                card.style.display = show ? '' : 'none';
                
                // Remove any stale visibility state
                card.style.removeProperty('visibility');
            });
        }
        
        // Apply subscription scope to UI tables (hide/show rows/sections based on scope)
        // This is a UI mirror of engine scope - doesn't replace engine logic, just prevents
        // user from clicking/interacting with rows from non-scoped subscriptions
        // Phase 3.2: data-subscription now contains subscriptionId (GUID), not subscriptionName
        // Use display:none only (not visibility) to avoid stale visibility state bugs
        function applySubscriptionScopeToTables() {
            const scopeIds = engine.state.scope.subscriptionIds || new Set();
            
            document.querySelectorAll('tr[data-subscription]').forEach(tr => {
                const sid = tr.getAttribute('data-subscription'); // GUID
                const show = (scopeIds.size === 0) || scopeIds.has(sid);
                
                // Endast display styr "hide". Visibility ska alltid vara default/visible.
                tr.style.display = show ? '' : 'none';
                
                // KRITISKT: rensa tidigare visibility:hidden för att undvika stale state
                tr.style.removeProperty('visibility');
            });
        }
        
        function filterBySubscription() {
            const checkboxes = document.querySelectorAll('.subscription-checkbox input[type="checkbox"]');
            
            const selectedSubIds = [];
            const selectedSubNames = [];
            const allSubIds = []; // All possible subscription IDs (for normalization)
            
            checkboxes.forEach(cb => {
                const subId = cb.getAttribute('data-subid');
                if (subId) {
                    allSubIds.push(subId);
                    if (cb.checked) {
                        selectedSubIds.push(subId);
                    }
                }
                
                // display name (ofta i value)
                if (cb.checked) {
                    const name = cb.value || cb.getAttribute('value');
                    if (name) selectedSubNames.push(name);
                }
            });
            
            // Normalize: if user selects all subscriptions, treat as 'no filter' (empty scope)
            // This avoids redundant state and special cases in later phases (Top 20, caching, logging, etc.)
            // UI still shows all checkboxes as checked - this is only internal state normalization
            const normalizedSubIds = (allSubIds.length > 0 && selectedSubIds.length === allSubIds.length) 
                ? [] 
                : selectedSubIds;
            
            // Single source of truth
            engine.setScopeSubscriptions(normalizedSubIds);
            
            // Optional (compat/debug)
            engine.setScopeSubscriptionNames(selectedSubNames);
            
            // Phase 5.1: legacy subscription state removed - use engine.state.scope.subscriptionIds
            
            // Apply subscription scope: hard hide cards + filter rows (GUID-based)
            applySubscriptionScopeToCards();  // Hide subscription-cards not in scope
            applySubscriptionScopeToTables(); // Hide table rows not in scope
            
            // Re-index DOM (needed before visual updates)
            initDomIndex();
            
            // Debug logging (Phase 3)
            if (window.DEBUG_COST_REPORT) {
                console.debug('Subscription filter state:', {
                    scopeSubscriptionIds: Array.from(engine.state.scope.subscriptionIds),
                    activeRowIdsSize: engine.getActiveRowIds().size
                });
                
                // Validate DOM index (quick check)
                if (!window.domIndex || !window.domIndex.byResourceKey || window.domIndex.byResourceKey.size === 0) {
                    console.warn('⚠️ DOM index missing or empty');
                }
            }
            
            // Phase 5: Use central refresh pipeline (scope change affects Meter Category data, so skip=false)
            refreshUIFromState({ skipMeterCategoryRerender: false });
            
            if (typeof applySearchAndSubscriptionFilters === 'function') {
                applySearchAndSubscriptionFilters();
            }
        }
        
        // Dynamic re-aggregation for "Cost by Meter Category" based on engine.getScopeRowIds()
        // Meter Category should only reflect scope (subscription filter), NOT picks (resource selections)
        // This allows users to pick resources in other sections without affecting Meter Category breakdown
        function renderCostByMeterCategory() {
            const container = document.getElementById('meterCategoryDynamicRoot');
            if (!container) {
                console.warn('meterCategoryDynamicRoot not found, skipping renderCostByMeterCategory');
                return;
            }
            
            // Safety check: ensure engine and factRows are initialized
            if (!engine || typeof engine.getActiveRowIds !== 'function') {
                console.warn('Engine not ready, skipping renderCostByMeterCategory');
                return;
            }
            
            if (!factRows || !Array.isArray(factRows) || factRows.length === 0) {
                console.warn('factRows not available or empty, skipping renderCostByMeterCategory');
                container.innerHTML = '<p>No cost data available.</p>';
                return;
            }
            
            // P4.1 FIX: Use scope-only for building structure (show all categories), but apply picks for filtering content
            // This ensures all categories are visible, but only selected items are highlighted/filtered
            let scopeRowIds;
            try {
                scopeRowIds = engine.getScopeRowIds();
            } catch (error) {
                console.error('Error calling engine.getScopeRowIds():', error);
                container.innerHTML = '<p>Error loading cost data.</p>';
                return;
            }
            
            // Get activeRowIds for filtering (scope + picks) - used to determine which rows to include in aggregation
            let activeRowIds;
            try {
                activeRowIds = engine.getActiveRowIds();
            } catch (error) {
                console.error('Error calling engine.getActiveRowIds():', error);
                activeRowIds = scopeRowIds; // Fallback to scope-only
            }
            
            // Safety check: ensure we have valid Sets
            if (!scopeRowIds || !(scopeRowIds instanceof Set)) {
                console.error('engine.getScopeRowIds() did not return a Set:', scopeRowIds);
                container.innerHTML = '<p>Error: Invalid data structure.</p>';
                return;
            }
            if (!activeRowIds || !(activeRowIds instanceof Set)) {
                activeRowIds = scopeRowIds; // Fallback
            }
            
            // Debug: log state for troubleshooting
            if (window.DEBUG_COST_REPORT) {
                console.debug('renderCostByMeterCategory:', {
                    scopeRowIdsSize: scopeRowIds.size,
                    activeRowIdsSize: activeRowIds.size,
                    scopeSubscriptionIds: Array.from(engine.state.scope.subscriptionIds),
                    picksCategories: Array.from(engine.state.picks.categories),
                    picksSubcategories: Array.from(engine.state.picks.subcategories),
                    picksMeterNames: Array.from(engine.state.picks.meterNames),
                    factRowsLength: factRows ? factRows.length : 0
                });
            }
            
            // Safety check: if scopeRowIds is empty but we have factRows, something is wrong
            if (scopeRowIds.size === 0) {
                // Check if this is because of filters or because there's no data at all
                if (!factRows || factRows.length === 0) {
                    container.innerHTML = '<p>No cost data available.</p>';
                } else {
                    // This can happen when scope filters exclude all data
                    container.innerHTML = '<p>No data available for selected subscription filter.</p>';
                        return;
                }
            }
            
            // Helper to format numbers (match PowerShell Format-NumberWithSeparator)
            function formatNumber(num) {
                if (typeof num !== 'number' || isNaN(num)) return '0';
                return num.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
            }
            
            // Build hierarchy: Category -> SubCategory -> Meter -> Resource (aggregated by resourceKey)
            // Use scopeRowIds to build structure (all categories visible), but activeRowIds to filter content
            const categoryMap = new Map();
            
            // Build structure from scope (so all categories are visible)
            scopeRowIds.forEach(rowId => {
                const row = factRows[rowId];
                if (!row) return;
                
                const catName = row.meterCategory || '(Unknown Category)';
                const subCatName = row.meterSubcategory || '(Unknown Subcategory)';
                const meterName = row.meterName || '(Unknown Meter)';
                
                // Get or create category (structure only - costs calculated separately)
                if (!categoryMap.has(catName)) {
                    categoryMap.set(catName, {
                        name: catName,
                        costLocal: 0,
                        costUSD: 0,
                        subCategories: new Map()
                    });
                }
                const category = categoryMap.get(catName);
                
                // Get or create subcategory
                if (!category.subCategories.has(subCatName)) {
                    category.subCategories.set(subCatName, {
                        name: subCatName,
                        costLocal: 0,
                        costUSD: 0,
                        meters: new Map()
                    });
                }
                const subCategory = category.subCategories.get(subCatName);
                
                // Get or create meter
                if (!subCategory.meters.has(meterName)) {
                    subCategory.meters.set(meterName, {
                        name: meterName,
                        costLocal: 0,
                        costUSD: 0,
                        recordCount: 0,
                        resources: new Map() // Aggregated by resourceKey
                    });
                }
                const meter = subCategory.meters.get(meterName);
                
                // Get or create resource (structure only)
                const resourceKey = row.resourceKey || '';
                if (resourceKey && !meter.resources.has(resourceKey)) {
                    meter.resources.set(resourceKey, {
                        resourceKey: resourceKey,
                        resourceId: row.resourceId || '',
                        resourceName: row.resourceName || 'Unknown',
                        resourceGroup: row.resourceGroup || 'N/A',
                        subscriptionId: row.subscriptionId || '',
                        subscriptionName: row.subscriptionName || 'N/A',
                        costLocal: 0,
                        costUSD: 0
                    });
                }
            });
            
            // Get active resource keys for highlighting (resources that are affected by current filters)
            const activeResourceKeys = engine.getActiveResourceKeys();
            
            // Now calculate costs from activeRowIds (scope + picks) - this filters content but keeps structure
            activeRowIds.forEach(rowId => {
                const row = factRows[rowId];
                if (!row) return;
                
                const catName = row.meterCategory || '(Unknown Category)';
                const subCatName = row.meterSubcategory || '(Unknown Subcategory)';
                const meterName = row.meterName || '(Unknown Meter)';
                const resourceKey = row.resourceKey || '';
                const costLocal = parseFloat(row.costLocal) || 0;
                const costUSD = parseFloat(row.costUSD) || 0;
                
                // Only add costs if structure exists (from scope)
                if (!categoryMap.has(catName)) return;
                const category = categoryMap.get(catName);
                category.costLocal += costLocal;
                category.costUSD += costUSD;
                
                if (!category.subCategories.has(subCatName)) return;
                const subCategory = category.subCategories.get(subCatName);
                subCategory.costLocal += costLocal;
                subCategory.costUSD += costUSD;
                
                if (!subCategory.meters.has(meterName)) return;
                const meter = subCategory.meters.get(meterName);
                meter.costLocal += costLocal;
                meter.costUSD += costUSD;
                meter.recordCount++;
                
                if (resourceKey && meter.resources.has(resourceKey)) {
                const resource = meter.resources.get(resourceKey);
                resource.costLocal += costLocal;
                resource.costUSD += costUSD;
                }
            });
            
            // Sort and render: Categories (desc by costLocal), then SubCategories, then Meters, then Resources
            const sortedCategories = Array.from(categoryMap.values())
                .sort((a, b) => b.costLocal - a.costLocal);
            
            let html = '';
            
            sortedCategories.forEach(category => {
                const catNameEncoded = escapeHtml(category.name);
                const catCostLocalFormatted = formatNumber(category.costLocal);
                const catCostUSDFormatted = formatNumber(category.costUSD);
                
                // Sort subcategories
                const sortedSubCats = Array.from(category.subCategories.values())
                    .sort((a, b) => b.costLocal - a.costLocal);
                
                let subCatHtml = '';
                
                sortedSubCats.forEach(subCat => {
                    const subCatNameEncoded = escapeHtml(subCat.name);
                    const subCatCostLocalFormatted = formatNumber(subCat.costLocal);
                    const subCatCostUSDFormatted = formatNumber(subCat.costUSD);
                    
                    // Sort meters
                    const sortedMeters = Array.from(subCat.meters.values())
                        .sort((a, b) => b.costLocal - a.costLocal);
                    
                    let meterCardsHtml = '';
                    
                    sortedMeters.forEach(meter => {
                        const meterNameEncoded = escapeHtml(meter.name);
                        const meterCostLocalFormatted = formatNumber(meter.costLocal);
                        const meterCostUSDFormatted = formatNumber(meter.costUSD);
                        
                        // Sort resources
                        const sortedResources = Array.from(meter.resources.values())
                            .sort((a, b) => b.costLocal - a.costLocal);
                        
                        let resourceRowsHtml = '';
                        let hasResources = sortedResources.length > 0;
                        
                        if (hasResources) {
                            sortedResources.forEach(resource => {
                                const resNameEncoded = escapeHtml(resource.resourceName);
                                const resGroupEncoded = escapeHtml(resource.resourceGroup);
                                const resSubNameEncoded = escapeHtml(resource.subscriptionName);
                                const resIdEncoded = escapeHtml(resource.resourceId);
                                const resourceKeyEncoded = escapeHtml(resource.resourceKey);
                                const resSubIdEncoded = escapeHtml(resource.subscriptionId);
                                
                                const resCostLocalFormatted = formatNumber(resource.costLocal);
                                const resCostUSDFormatted = formatNumber(resource.costUSD);
                                
                                // Check if this resource is in activeRowIds (affected by current filters)
                                const isActive = activeResourceKeys.has(resource.resourceKey);
                                // Phase 5.2: Visual markers applied in updateResourceSelectionVisual, not in render
                                
                                // Build attributes: always data-resource-key, data-resource-id only if ResourceId exists
                                let attr = 'class="clickable" data-resource-key="' + resourceKeyEncoded + '"';
                                if (resIdEncoded) {
                                    attr += ' data-resource-id="' + resIdEncoded + '"';
                                }
                                
                                // Build subscription attributes: data-subscription = GUID (ID-first)
                                const subscriptionAttr = resSubIdEncoded 
                                    ? 'data-subscription-id="' + resSubIdEncoded + '" data-subscription-name="' + resSubNameEncoded + '" data-subscription="' + resSubIdEncoded + '"'
                                    : '';
                                
                                resourceRowsHtml += '<tr ' + attr + ' ' + subscriptionAttr + 
                                    ' data-resource="' + resNameEncoded + '" data-meter="' + meterNameEncoded + 
                                    ' data-subcategory="' + subCatNameEncoded + '" data-category="' + catNameEncoded + 
                                    '" style="cursor: pointer;">' +
                                    '<td>' + resNameEncoded + '</td>' +
                                    '<td>' + resGroupEncoded + '</td>' +
                                    '<td>' + resSubNameEncoded + '</td>' +
                                    '<td class="cost-value text-right">' + currency + ' ' + resCostLocalFormatted + '</td>' +
                                    '<td class="cost-value text-right">$' + resCostUSDFormatted + '</td>' +
                                    '</tr>';
                            });
                        }
                        
                        if (hasResources) {
                            meterCardsHtml += '<div class="meter-card" data-meter="' + meterNameEncoded + 
                                '" data-subcategory="' + subCatNameEncoded + '" data-category="' + catNameEncoded + '">' +
                                '<div class="expandable__header meter-header" data-meter="' + meterNameEncoded + '" data-subcategory="' + subCatNameEncoded + 
                                '" data-category="' + catNameEncoded + '" onclick="handleMeterSelection(this, event)" ' +
                                'style="display: flex; align-items: center; justify-content: space-between;">' +
                                '<span class="expand-arrow">&#9654;</span>' +
                                '<span class="meter-name" style="flex-grow: 1; font-weight: 600; margin-right: 10px;">' + meterNameEncoded + '</span>' +
                                '<div class="meter-header-right" style="display: flex; align-items: center; gap: 10px; margin-left: auto;">' +
                                '<span class="meter-cost" style="color: #54a0ff !important; text-align: right; font-weight: 600; white-space: nowrap;">' +
                                currency + ' ' + meterCostLocalFormatted + ' ($' + meterCostUSDFormatted + ')</span>' +
                                '<span class="meter-count">' + meter.recordCount + ' records</span>' +
                                '</div></div>' +
                                '<div class="meter-content">' +
                                '<table class="data-table resource-table">' +
                                '<thead><tr><th>Resource</th><th>Resource Group</th><th>Subscription</th>' +
                                '<th class="text-right">Cost (Local)</th><th class="text-right">Cost (USD)</th></tr></thead>' +
                                '<tbody>' + resourceRowsHtml + '</tbody></table></div></div>';
                        } else {
                            meterCardsHtml += '<div class="meter-card no-expand" data-meter="' + meterNameEncoded + 
                                '" data-subcategory="' + subCatNameEncoded + '" data-category="' + catNameEncoded + '">' +
                                '<div class="expandable__header meter-header" data-meter="' + meterNameEncoded + 
                                '" data-subcategory="' + subCatNameEncoded + '" data-category="' + catNameEncoded + 
                                '" onclick="handleMeterSelection(this, event)" ' +
                                'style="display: flex; align-items: center; justify-content: space-between;">' +
                                '<span class="meter-name" style="flex-grow: 1; font-weight: 600; margin-right: 10px;">' + meterNameEncoded + '</span>' +
                                '<span class="meter-cost" style="color: #54a0ff !important; text-align: right; font-weight: 600; white-space: nowrap; margin-left: auto;">' +
                                currency + ' ' + meterCostLocalFormatted + ' ($' + meterCostUSDFormatted + ')</span>' +
                                '<span class="meter-count">' + meter.recordCount + ' records</span></div></div>';
                        }
                    });
                    
                    // Meter Category: Subcategory header (no subscriptionId, global key for Meter Category section)
                    // Note: Meter Category headers should NOT be marked by scoped picks
                    const globalSubcatKey = catNameEncoded + '|' + subCatNameEncoded; // Global key (not scoped)
                    subCatHtml += '<div class="subcategory-drilldown" data-subcategory="' + subCatNameEncoded + 
                        '" data-category="' + catNameEncoded + '">' +
                        '<div class="expandable__header subcategory-header" data-subcategory="' + subCatNameEncoded + 
                        '" data-category="' + catNameEncoded + '" data-subscription-id="" data-subcategory-key="' + globalSubcatKey + '" onclick="handleSubcategorySelection(this, event)" ' +
                        'style="display: flex; align-items: center; justify-content: space-between;">' +
                        '<span class="expand-arrow">&#9654;</span>' +
                        '<span class="subcategory-name" style="flex-grow: 1; font-weight: 600; margin-right: 10px;">' + subCatNameEncoded + '</span>' +
                        '<span class="subcategory-cost" style="color: #54a0ff !important; text-align: right; font-weight: 600; white-space: nowrap; margin-left: auto;">' +
                        currency + ' ' + subCatCostLocalFormatted + ' ($' + subCatCostUSDFormatted + ')</span>' +
                        '</div>' +
                        '<div class="subcategory-content" style="display: none !important;">' + meterCardsHtml + '</div></div>';
                });
                
                // P4.1: Category header needs expandable__header class for visual sync to work
                html += '<div class="category-card collapsed" data-category="' + catNameEncoded + '">' +
                    '<div class="expandable__header category-header collapsed" data-category="' + catNameEncoded + 
                    '" onclick="handleCategorySelection(this, event)">' +
                    '<span class="expand-arrow">&#9654;</span>' +
                    '<span class="category-title">' + catNameEncoded + '</span>' +
                    '<span class="category-cost">' + currency + ' ' + catCostLocalFormatted + ' ($' + catCostUSDFormatted + ')</span>' +
                    '</div>' +
                    '<div class="category-content" style="display: none !important;">' + subCatHtml + '</div></div>';
            });
            
            // Render content - do NOT manipulate display styles
            // Expand/collapse state is controlled solely by toggle handlers (toggleSection, etc.)
            container.innerHTML = html;
        }
        
        // Helper to escape HTML (for both text content and attribute values)
        function escapeHtml(text) {
            if (!text) return '';
            const div = document.createElement('div');
            div.textContent = text;
            // Also escape quotes for attribute values
            return div.innerHTML.replace(/"/g, '&quot;').replace(/'/g, '&#39;');
        }
        
        function updateSummaryCards() {
            const totalCostLocalEl = document.getElementById('summary-total-cost-local');
            const totalCostUsdEl = document.getElementById('summary-total-cost-usd');
            const subscriptionCountEl = document.getElementById('summary-subscription-count');
            const categoryCountEl = document.getElementById('summary-category-count');
            const trendPercentEl = document.getElementById('summary-trend-percent');
            
            if (!totalCostLocalEl || !totalCostUsdEl) return;
            
            // Get active rowIds from engine (single source of truth)
            const activeRowIds = engine.getActiveRowIds();
            const totals = engine.sumCosts(activeRowIds);
            
            // Update cost totals
            const formattedLocal = formatNumberNoDecimals(totals.local);
            const formattedUSD = formatNumberNoDecimals(totals.usd);
            totalCostLocalEl.textContent = formattedLocal;
            totalCostUsdEl.textContent = formattedUSD;
            
            // Count unique subscriptions and categories from active rows
            const activeSubscriptions = new Set();
            const activeCategories = new Set();
            
            activeRowIds.forEach(rowId => {
                const row = factRows[rowId];
                if (row) {
                    if (row.subscriptionName) activeSubscriptions.add(row.subscriptionName);
                    if (row.meterCategory) activeCategories.add(row.meterCategory);
                }
            });
            
            if (subscriptionCountEl) {
                subscriptionCountEl.textContent = activeSubscriptions.size;
            }
            if (categoryCountEl) {
                categoryCountEl.textContent = activeCategories.size;
            }
            
            // Calculate trend (compare first half vs second half of period)
            if (trendPercentEl && activeRowIds.size > 0) {
                const trend = engine.trendByDay(activeRowIds);
                if (trend.length >= 2) {
                    const midpoint = Math.floor(trend.length / 2);
                    const firstHalf = trend.slice(0, midpoint);
                    const secondHalf = trend.slice(midpoint);
                    
                    const firstHalfTotal = firstHalf.reduce((sum, d) => sum + d.local, 0);
                    const secondHalfTotal = secondHalf.reduce((sum, d) => sum + d.local, 0);
                    
                    let trendPercent = 0;
                    if (firstHalfTotal > 0) {
                        trendPercent = ((secondHalfTotal - firstHalfTotal) / firstHalfTotal) * 100;
                    }
                    
                    // Use HTML entities to avoid encoding issues (same as PowerShell uses)
                    const trendArrow = trendPercent > 0 ? '&#8593;' : trendPercent < 0 ? '&#8595;' : '&#8594;';
                    const trendColor = trendPercent > 0 ? 'trend-increasing' : trendPercent < 0 ? 'trend-decreasing' : 'trend-stable';
                    
                    trendPercentEl.innerHTML = '<span class="' + trendColor + '">' + trendArrow + ' ' + Math.abs(trendPercent).toFixed(1) + '%</span>';
                }
            }
            
            // Dev-mode validation (optional - add to updateSummaryCards and updateChart)
            if (window.DEBUG_COST_REPORT) {
                const activeRowIdsCheck = engine.getActiveRowIds();
                const totalsCheck = engine.sumCosts(activeRowIdsCheck);
                const trendCheck = engine.trendByDay(activeRowIdsCheck);
                const chartTotal = trendCheck.reduce((sum, d) => sum + d.local, 0);
                const diff = Math.abs(totalsCheck.local - chartTotal);
                const epsilon = 0.01; // Allow small floating point differences
                if (diff > epsilon) {
                    console.warn('⚠️ Mismatch detected: totals.local =', totalsCheck.local, 'chartTotal =', chartTotal, 'diff =', diff);
                    console.warn('Active rowIds:', activeRowIdsCheck.size, 'rows');
                } else {
                    console.log('✓ Validation passed: totals match chart (', totalsCheck.local, 'SEK)');
                }
            }
        }
        
        function filterTableBySubscription(tableId) {
            // GUID-based filtering: use engine scope (subscriptionIds) instead of names
            const scopeIds = engine.state.scope.subscriptionIds || new Set();
            const rows = document.querySelectorAll('#' + tableId + ' tbody tr');
            rows.forEach(row => {
                const subscriptionId = row.getAttribute('data-subscription'); // GUID
                if (subscriptionId && scopeIds.size > 0) {
                    row.classList.toggle('filtered-out', !scopeIds.has(subscriptionId));
                } else {
                    row.classList.remove('filtered-out');
                }
            });
        }
        
        function filterCategorySections() {
            // Get search text for combined filtering
            const searchInput = document.getElementById('resourceSearch');
            const searchText = searchInput ? searchInput.value.toLowerCase().trim() : '';
            
            // GUID-based filtering: use engine scope (subscriptionIds) instead of names
            const scopeIds = engine.state.scope.subscriptionIds || new Set();
            
            // Filter subscription cards first (for subscription drilldown section)
            // Note: applySubscriptionScopeToCards() handles hard hide, this is for search-only filtering
            document.querySelectorAll('.subscription-card').forEach(subCard => {
                const subscriptionId = subCard.getAttribute('data-subscription'); // GUID
                const matchesSubscription = scopeIds.size === 0 || 
                    (subscriptionId && scopeIds.has(subscriptionId));
                const cardText = subCard.textContent.toLowerCase();
                const matchesSearch = searchText === '' || cardText.includes(searchText);
                
                // Only apply filtered-out class if search doesn't match (subscription filtering handled by applySubscriptionScopeToCards)
                subCard.classList.toggle('filtered-out', !matchesSearch);
            });
            
            // Filter resource rows within meter sections by subscription and search
            // Phase 5.1: Use engine scope instead of legacy subscription state (scopeIds already declared above)
            document.querySelectorAll('.resource-table tbody tr').forEach(row => {
                const subscription = row.getAttribute('data-subscription');
                const matchesSubscription = scopeIds.size === 0 || 
                    (subscription && scopeIds.has(subscription));
                const rowText = row.textContent.toLowerCase();
                const matchesSearch = searchText === '' || rowText.includes(searchText);
                
                row.classList.toggle('filtered-out', !matchesSubscription || !matchesSearch);
            });
            
            // Update visibility of meter cards based on whether they have visible resources
            document.querySelectorAll('.meter-card').forEach(card => {
                const visibleRows = card.querySelectorAll('.resource-table tbody tr:not(.filtered-out)');
                const totalRows = card.querySelectorAll('.resource-table tbody tr');
                if (totalRows.length > 0 && scopeIds.size > 0) {
                    card.classList.toggle('filtered-out', visibleRows.length === 0);
                } else {
                    card.classList.remove('filtered-out');
                }
            });
            
            // Update visibility of subcategory drilldowns based on visible meters
            document.querySelectorAll('.subcategory-drilldown').forEach(subcat => {
                const visibleMeters = subcat.querySelectorAll('.meter-card:not(.filtered-out)');
                const totalMeters = subcat.querySelectorAll('.meter-card');
                if (totalMeters.length > 0 && scopeIds.size > 0) {
                    subcat.classList.toggle('filtered-out', visibleMeters.length === 0);
                } else {
                    subcat.classList.remove('filtered-out');
                }
            });
            
            // Update visibility of category cards based on visible subcategories (but not subscription cards or resource cards)
            document.querySelectorAll('.category-card:not(.subscription-card):not(.resource-card)').forEach(cat => {
                const visibleSubcats = cat.querySelectorAll('.subcategory-drilldown:not(.filtered-out)');
                const totalSubcats = cat.querySelectorAll('.subcategory-drilldown');
                if (totalSubcats.length > 0 && scopeIds.size > 0) {
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
                
                // Phase 5.1.1: Use engine data for engine-only consistency
                if (!engine) {
                    console.warn('Engine not available, skipping recalculateTopResources');
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
                
                // Check if resource cards exist (only in Top 20 Resources section, not Cost Increase Drivers)
                const resourceCards = resourcesContainer.querySelectorAll('.resource-card:not(.increased-cost-card)');
                if (resourceCards.length === 0) {
                    console.warn('No resource cards found, skipping recalculateTopResources');
                    return;
                }
                
                // Get scope-filtered rowIds (respects subscription filter from engine.state.scope)
                const scopeRowIds = engine.getScopeRowIds();
                
                // Group by resource using engine (aggregates totals, not daily series)
                const resourceGroups = engine.groupByResource(scopeRowIds);
                
                // Build resourceKey -> total cost map (using resourceName as key to match DOM cards)
                const resourceCosts = new Map();
                resourceGroups.forEach(resData => {
                    // Use resourceName as key (matches what's in DOM cards)
                    if (resData.resourceName) {
                        resourceCosts.set(resData.resourceName, resData.local || 0);
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
                
                // Get subscription scope from engine (for filtering cards by subscription)
                const scopeSubscriptionIds = engine.state.scope.subscriptionIds || new Set();
                
                // Remove all resource cards from DOM (temporarily)
                const cardsToReorder = cardsWithCosts.map(item => item.card);
                cardsToReorder.forEach(card => card.remove());
                
                // Filter by subscription first to get resources matching the subscription filter
                const subscriptionFiltered = cardsWithCosts.filter(item => {
                    return scopeSubscriptionIds.size === 0 || 
                        (item.subscription && scopeSubscriptionIds.has(item.subscription));
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
                    const matchesSubscription = scopeSubscriptionIds.size === 0 || 
                        (item.subscription && scopeSubscriptionIds.has(item.subscription));
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
        
        // Phase 5.1: Make toggleSection globally available for onclick handlers
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
        // Ensure toggleSection is globally available
        window.toggleSection = toggleSection;
        
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
        
        // Phase 5: Legacy select/deselect functions removed - engine-only state now
        
        // Phase 5.2: Update clear selections button visibility (top-layer aware)
        function updateClearSelectionsButtonVisibility() {
            const clearBtn = document.getElementById('clearChartSelections');
            if (!clearBtn) return;
            
            // Phase 5.2: Check if top-layer has any picks
            const top = engine?.getTopLayer?.();
            const hasTopLayerPicks = top && Object.values(top.picks).some(s => s && s.size > 0);
            
            // Fallback: check legacy picks if no layers
            const hasLegacyPicks = !top && engine && engine.state && engine.state.picks &&
                Object.values(engine.state.picks).some(s => s && s.size > 0);
            
            clearBtn.style.display = (hasTopLayerPicks || hasLegacyPicks) ? 'block' : 'none';
        }
        
        // Phase 5.2: Clear all selections (top-layer aware)
        function clearAllChartSelections() {
            if (!engine) return;
            
            // Phase 5.2: Clear top-layer if it exists
            const top = engine.getTopLayer?.();
            if (top) {
                engine.clearTopLayerPicks(top.source);
                engine.popTopLayerIfEmpty?.();
            } else {
                // Fallback: clear legacy picks if no layers exist
                if (typeof engine.clearPicks === 'function') {
                engine.clearPicks();
                } else if (engine.state && engine.state.picks) {
                Object.values(engine.state.picks).forEach(s => s && s.clear && s.clear());
                }
            }
            
            // Update visuals + data using central refresh pipeline
            refreshUIFromState();
            updateClearSelectionsButtonVisibility();
        }
        
        // Ctrl+Click event handlers
        function handleSubscriptionSelection(element, event) {
            if (event && (event.ctrlKey || event.metaKey)) {
                event.preventDefault();
                event.stopPropagation();
                const subscription = getSubscriptionFromElement(element);
                if (subscription && engine) {
                    // Toggle subscription in scope (subscriptions are scope, not picks)
                    const isInScope = engine.state.scope.subscriptionIds.has(subscription);
                    if (isInScope) {
                        engine.state.scope.subscriptionIds.delete(subscription);
                    } else {
                        engine.state.scope.subscriptionIds.add(subscription);
                    }
                    // Phase 5: Use central refresh pipeline
                    refreshUIFromState({ skipMeterCategoryRerender: true });
                }
                return false;
            }
            // If not Ctrl+Click, allow normal toggle behavior
            return true;
        }
        
        function handleCategorySelection(element, event) {
            if (event && (event.ctrlKey || event.metaKey)) {
                event.preventDefault();
                event.stopPropagation();
                // Phase 5.2: Use data-category-key if available (scoped), otherwise fallback to data-category
                const categoryKey = element.getAttribute('data-category-key') || getCategoryFromElement(element);
                if (categoryKey && engine) {
                    // Phase 5.2: Identify source - if in meter table, always use 'meter', otherwise check subscriptionId
                    const isInMeterTable = element.closest('#meterCategoryDynamicRoot') !== null;
                    let source;
                    let subscriptionId = ''; // Fix: definiera här i outer scope
                    
                    if (isInMeterTable) {
                        source = 'meter';
                    } else {
                        subscriptionId = element.getAttribute('data-subscription-id') || 
                                       element.closest('[data-subscription-id]')?.getAttribute('data-subscription-id') || '';
                        source = subscriptionId ? 'subscription' : 'meter';
                    }
                    
                    // Phase 5.2: If no data-category-key, build scoped key (fallback for Meter Category)
                    const finalCategoryKey = categoryKey.includes('|') ? categoryKey : (subscriptionId ? (subscriptionId + '|' + categoryKey) : categoryKey);
                    
                    // Phase 5.2: Ensure top-layer and clear other picks in that layer
                    const topLayer = engine.ensureTopLayer(source);
                    topLayer.picks.subcategories.clear();
                    topLayer.picks.meterNames.clear();
                    topLayer.picks.resourceKeys.clear();
                    // Keep: categories (for multi-select within level)
                    
                    // Toggle category pick in top-layer
                    engine.togglePick('categories', finalCategoryKey, 'toggle', source);
                    
                    // Phase 5: Use central refresh pipeline (skip meter category re-render to preserve expand/collapse state)
                    refreshUIFromState({ skipMeterCategoryRerender: true });
                }
                return false;
            }
            // If not Ctrl+Click, allow normal toggle behavior
            toggleCategory(element, event);
            return false;
        }
        
        function handleSubcategorySelection(element, event) {
            if (event && (event.ctrlKey || event.metaKey)) {
                event.preventDefault();
                event.stopPropagation();
                const subcategory = element.getAttribute('data-subcategory');
                const category = element.getAttribute('data-category');
                if (subcategory && category && engine) {
                    // Phase 5.2: Identify source - if in meter table, always use 'meter', otherwise check subscriptionId
                    const isInMeterTable = element.closest('#meterCategoryDynamicRoot') !== null;
                    let source;
                    let scopedKey;
                    
                    if (isInMeterTable) {
                        // Meter Category section - use global key (category|subcategory) and source='meter'
                        source = 'meter';
                        scopedKey = category + '|' + subcategory; // Global key for meter table
                    } else {
                        // Cost Breakdown section - use scoped key (subscriptionId|category|subcategory) and source='subscription'
                        const subscriptionId = element.getAttribute('data-subscription-id') || 
                                             element.closest('[data-subscription-id]')?.getAttribute('data-subscription-id') || '';
                        if (!subscriptionId) {
                            // No subscriptionId in Cost Breakdown - skip pick
                            return false;
                        }
                        source = 'subscription';
                        scopedKey = subscriptionId + '|' + category + '|' + subcategory;
                    }
                    
                    // Phase 5.2: Ensure top-layer and clear other picks in that layer
                    const topLayer = engine.ensureTopLayer(source);
                    topLayer.picks.categories.clear();
                    topLayer.picks.meterNames.clear();
                    topLayer.picks.resourceKeys.clear();
                    // Keep: subcategories (for multi-select within level)
                    
                    // Toggle subcategory pick in top-layer (scoped: subscriptionId|category|subcategory)
                    engine.togglePick('subcategories', scopedKey, 'toggle', source);
                    
                    // Phase 5: Use central refresh pipeline (skip meter category re-render to preserve expand/collapse state)
                    refreshUIFromState({ skipMeterCategoryRerender: true });
                }
                return false;
            }
            // If not Ctrl+Click, allow normal toggle behavior
            toggleSubCategory(element, event);
            return false;
        }
        
        function handleMeterSelection(element, event) {
            if (event && (event.ctrlKey || event.metaKey)) {
                event.preventDefault();
                event.stopPropagation();
                const meter = element.getAttribute('data-meter');
                if (meter && engine) {
                    // Phase 5.2: Identify source - if in meter table, always use 'meter', otherwise check subscriptionId
                    const isInMeterTable = element.closest('#meterCategoryDynamicRoot') !== null;
                    let source;
                    if (isInMeterTable) {
                        source = 'meter';
                    } else {
                        const subscriptionId = element.getAttribute('data-subscription-id') || 
                                             element.closest('[data-subscription-id]')?.getAttribute('data-subscription-id') || '';
                        source = subscriptionId ? 'subscription' : 'meter';
                    }
                    
                    // Phase 5.2: Ensure top-layer and clear other picks in that layer
                    const topLayer = engine.ensureTopLayer(source);
                    topLayer.picks.categories.clear();
                    topLayer.picks.subcategories.clear();
                    topLayer.picks.resourceKeys.clear();
                    // Keep: meterNames (for multi-select within level)
                    
                    // Toggle meter pick in top-layer
                    engine.togglePick('meterNames', meter, 'toggle', source);
                    
                    // Phase 5: Use central refresh pipeline (skip meter category re-render to preserve expand/collapse state)
                    refreshUIFromState({ skipMeterCategoryRerender: true });
                }
                return false;
            }
            // If not Ctrl+Click, allow normal toggle behavior
            toggleMeter(element);
            return false;
        }
        
        function handleResourceSelection(element, event, explicitSource) {
            if (event && (event.ctrlKey || event.metaKey)) {
                event.preventDefault();
                event.stopPropagation();
                
                // Phase 5.2: Always use data-resource-key (canonical key) instead of data-resource (short name)
                // This ensures the key matches what DOM-index uses for visual highlighting
                const resourceKey = element.getAttribute('data-resource-key') ||
                                   element.closest('tr[data-resource-key]')?.getAttribute('data-resource-key') ||
                                   null;
                
                if (resourceKey && engine) {
                    // Phase 5.2: Identify source - use explicitSource if provided, otherwise detect from element location
                    let source;
                    if (explicitSource) {
                        source = explicitSource;
                    } else {
                        // Phase 5.2: Detect source from element location (meter table vs Cost Breakdown)
                        const isInMeterTable = element.closest('#meterCategoryDynamicRoot') !== null;
                        const isInCostBreakdown = element.closest('#costBreakdownRoot') !== null;
                        if (isInMeterTable) {
                            source = 'meter';
                        } else if (isInCostBreakdown) {
                            source = 'subscription';
                        } else {
                            // Default to meter for resource picks (most common case)
                            source = 'meter';
                        }
                    }
                    
                    // Phase 5.2: Ensure top-layer and clear other picks in that layer
                    const topLayer = engine.ensureTopLayer(source);
                    topLayer.picks.categories.clear();
                    topLayer.picks.subcategories.clear();
                    topLayer.picks.meterNames.clear();
                    // Keep: resourceKeys (for multi-select within level)
                    
                    // Toggle resource pick in top-layer (canonical: resourceKeys)
                    // Use resourceKey (data-resource-key) instead of resource (data-resource) to match DOM-index
                    engine.togglePick('resourceKeys', resourceKey, 'toggle', source);
                    
                    // Phase 5: Use central refresh pipeline (skip meter category re-render to preserve expand/collapse state)
                    refreshUIFromState({ skipMeterCategoryRerender: true });
                }
                return false;
            }
            // If not Ctrl+Click, allow normal behavior (no toggle for rows)
            return true;
        }
        
        function handleResourceCardSelection(element, event) {
            if (event && (event.ctrlKey || event.metaKey)) {
                event.preventDefault();
                event.stopPropagation();
                
                // Get resource name from data-resource attribute
                const card = element.closest('[data-resource]');
                if (!card) return false;
                
                const resource = card.getAttribute('data-resource');
                if (!resource || resource === 'N/A' || !engine) return false;
                
                // Phase 5.2: Resource card picks are from meter table (Top 20 resources)
                const source = 'meter';
                
                // Phase 5.2: Ensure top-layer and clear other picks in that layer
                const topLayer = engine.ensureTopLayer(source);
                topLayer.picks.categories.clear();
                topLayer.picks.subcategories.clear();
                topLayer.picks.meterNames.clear();
                // Keep: resourceKeys (for multi-select within level)
                
                // Toggle resource pick in top-layer (canonical: resourceKeys)
                engine.togglePick('resourceKeys', resource, 'toggle', source);
                
                // Phase 5: Use central refresh pipeline (skip meter category re-render to preserve expand/collapse state)
                refreshUIFromState({ skipMeterCategoryRerender: true });
                
                return true; // Stop propagation
            }
            return false; // Allow normal toggle behavior
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
                        categoryContent.style.setProperty('height', 'auto', 'important');
                        categoryContent.style.setProperty('overflow', 'visible', 'important');
                        // Remove any existing visibility property when expanding
                        categoryContent.style.removeProperty('visibility');
                    } else {
                        categoryContent.style.setProperty('display', 'none', 'important');
                        categoryContent.style.setProperty('height', '0', 'important');
                        categoryContent.style.setProperty('overflow', 'hidden', 'important');
                        // Remove any existing visibility property when collapsing
                        categoryContent.style.removeProperty('visibility');
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
                        subcategoryContent.style.setProperty('height', 'auto', 'important');
                        subcategoryContent.style.setProperty('overflow', 'visible', 'important');
                        subcategoryContent.style.setProperty('max-height', 'none', 'important');
                        subcategoryContent.style.setProperty('opacity', '1', 'important');
                        // Remove any existing visibility property when expanding
                        subcategoryContent.style.removeProperty('visibility');
                    } else {
                        subcategoryContent.style.setProperty('display', 'none', 'important');
                        subcategoryContent.style.setProperty('height', '0', 'important');
                        subcategoryContent.style.setProperty('overflow', 'hidden', 'important');
                        subcategoryContent.style.setProperty('max-height', '0', 'important');
                        subcategoryContent.style.setProperty('opacity', '0', 'important');
                        // Remove any existing visibility property when collapsing
                        subcategoryContent.style.removeProperty('visibility');
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
            
            // GUID-based filtering: use engine scope (subscriptionIds) instead of names
            const scopeIds = engine.state.scope.subscriptionIds || new Set();
            
            // Filter subscription cards (Cost by Subscription section) - respect both subscription and search filters
            // Note: applySubscriptionScopeToCards() handles hard hide, this is for search-only filtering
            document.querySelectorAll('.subscription-card').forEach(card => {
                const subscriptionId = card.getAttribute('data-subscription'); // GUID
                const matchesSubscription = scopeIds.size === 0 || 
                    (subscriptionId && scopeIds.has(subscriptionId));
                const cardText = card.textContent.toLowerCase();
                const matchesSearch = searchText === '' || cardText.includes(searchText);
                
                // Only apply filtered-out class if search doesn't match (subscription filtering handled by applySubscriptionScopeToCards)
                card.classList.toggle('filtered-out', !matchesSearch);
            });
            
            // Filter category cards (Cost by Meter Category section) - exclude subscription-card and resource-card
            // Phase 5.1: scopeIds already declared above, reuse it
            document.querySelectorAll('.category-card:not(.subscription-card):not(.resource-card)').forEach(card => {
                const cardText = card.textContent.toLowerCase();
                const matchesSearch = searchText === '' || cardText.includes(searchText);
                
                // Check if this category card has any resources from selected subscriptions
                let matchesSubscription = scopeIds.size === 0;
                if (scopeIds.size > 0 && !matchesSubscription) {
                    // Check if any resource rows within this category match selected subscriptions
                    const categoryContent = card.querySelector('.category-content');
                    if (categoryContent) {
                        const visibleResourceRows = categoryContent.querySelectorAll('tr[data-subscription]');
                        if (visibleResourceRows.length > 0) {
                            visibleResourceRows.forEach(row => {
                                const rowSubId = row.getAttribute('data-subscription'); // GUID
                                if (rowSubId && scopeIds.has(rowSubId)) {
                                    matchesSubscription = true;
                                }
                            });
                        } else {
                            // Check subcategories and meters for subscription match
                            const subcats = categoryContent.querySelectorAll('.subcategory-drilldown');
                            subcats.forEach(subcat => {
                                const subcatSubId = subcat.getAttribute('data-subscription'); // GUID
                                if (subcatSubId && scopeIds.has(subcatSubId)) {
                                    matchesSubscription = true;
                                } else {
                                    // Check meters within subcategory
                                    const meters = subcat.querySelectorAll('.meter-card[data-subscription]');
                                    meters.forEach(meter => {
                                        const meterSubId = meter.getAttribute('data-subscription'); // GUID
                                        if (meterSubId && scopeIds.has(meterSubId)) {
                                            matchesSubscription = true;
                                        }
                                    });
                                }
                            });
                        }
                    }
                }
                
                card.classList.toggle('filtered-out', !matchesSearch || !matchesSubscription);
            });
            
            // Filter subcategory drilldowns (nested in category cards)
            // Phase 5.1: scopeIds already declared above, reuse it
            document.querySelectorAll('.subcategory-drilldown').forEach(subcat => {
                const subcatText = subcat.textContent.toLowerCase();
                const matchesSearch = searchText === '' || subcatText.includes(searchText);
                
                // Check subscription match - subcategories in "Cost by Meter Category" don't have data-subscription
                // but subcategories in "Cost by Subscription" do
                let matchesSubscription = scopeIds.size === 0;
                if (scopeIds.size > 0 && !matchesSubscription) {
                    const subcatSubId = subcat.getAttribute('data-subscription'); // GUID
                    if (subcatSubId) {
                        // Has subscription attribute - check directly
                        matchesSubscription = scopeIds.has(subcatSubId);
                    } else {
                        // No subscription attribute - check if any meters/resources within match
                        const meters = subcat.querySelectorAll('.meter-card[data-subscription]');
                        if (meters.length > 0) {
                            meters.forEach(meter => {
                                const meterSubId = meter.getAttribute('data-subscription'); // GUID
                                if (meterSubId && scopeIds.has(meterSubId)) {
                                    matchesSubscription = true;
                                }
                            });
                        } else {
                            // Check resource rows
                            const resourceRows = subcat.querySelectorAll('tr[data-subscription]');
                            resourceRows.forEach(row => {
                                const rowSubId = row.getAttribute('data-subscription'); // GUID
                                if (rowSubId && scopeIds.has(rowSubId)) {
                                    matchesSubscription = true;
                                }
                            });
                        }
                    }
                }
                
                subcat.classList.toggle('filtered-out', !matchesSearch || !matchesSubscription);
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
            // Phase 5.1: Use engine scope instead of legacy subscription state
            const scopeIdsForRows = engine && engine.state && engine.state.scope.subscriptionIds || new Set();
            document.querySelectorAll('.resource-table tbody tr').forEach(row => {
                const subscription = row.getAttribute('data-subscription');
                const matchesSubscription = scopeIdsForRows.size === 0 || 
                    (subscription && scopeIdsForRows.has(subscription));
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
            
            // Filter "Top 20 Cost Increase Drivers" cards by subscription
            // Phase 5.1: Use engine scope instead of legacy subscription state
            const scopeIdsForCards = engine && engine.state && engine.state.scope.subscriptionIds || new Set();
            document.querySelectorAll('.resource-card.increased-cost-card').forEach(card => {
                const subscription = card.getAttribute('data-subscription');
                const matchesSubscription = scopeIdsForCards.size === 0 || 
                    (subscription && scopeIdsForCards.has(subscription));
                const cardText = card.textContent.toLowerCase();
                const matchesSearch = searchText === '' || cardText.includes(searchText);
                
                card.classList.toggle('filtered-out', !matchesSubscription || !matchesSearch);
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
    
    Write-Host ("[CostTracking] Export total: {0}" -f $swAll.Elapsed)
    
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
