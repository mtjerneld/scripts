<#
.SYNOPSIS
    Collects cost data for all subscriptions and aggregates it.

.DESCRIPTION
    Iterates through subscriptions and collects cost data using Get-AzureCostData.
    Aggregates data by subscription, meter category, and resource.

.PARAMETER Subscriptions
    Array of subscription objects to collect data from.

.PARAMETER DaysToInclude
    Number of days to look back (default: 30, max: 90).

.PARAMETER Errors
    List to append errors to.

.OUTPUTS
    Hashtable with aggregated cost data structure.
#>
function Collect-CostData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Subscriptions,
        
        [Parameter(Mandatory = $false)]
        [int]$DaysToInclude = 30,
        
        [Parameter(Mandatory = $false)]
        [System.Collections.Generic.List[string]]$Errors
    )
    
    # Initialize errors list if not provided
    if ($null -eq $Errors) {
        $Errors = [System.Collections.Generic.List[string]]::new()
    }
    
    # Validate DaysToInclude (max 90 for Daily granularity)
    if ($DaysToInclude -gt 90) {
        Write-Warning "DaysToInclude ($DaysToInclude) exceeds maximum (90) for Daily granularity. Using 90 days."
        $DaysToInclude = 90
    }
    if ($DaysToInclude -lt 1) {
        Write-Warning "DaysToInclude must be at least 1. Using 1 day."
        $DaysToInclude = 1
    }
    
    # Calculate date range (exclude today - end date is yesterday)
    # If DaysToInclude is 31, we want yesterday through 31 days ago (31 days total, excluding today)
    $endDate = (Get-Date -Hour 0 -Minute 0 -Second 0 -Millisecond 0).AddDays(-1)
    $startDate = $endDate.AddDays(-($DaysToInclude - 1))
    
    Write-Host "Period: $($startDate.ToString('yyyy-MM-dd')) to $($endDate.ToString('yyyy-MM-dd')) ($DaysToInclude days)" -ForegroundColor Gray
    
    # Initialize aggregated data structure
    $allCostData = [System.Collections.Generic.List[PSObject]]::new()
    $bySubscription = @{}
    $byMeterCategory = @{}
    $byResource = @{}
    $dailyTrend = @{}
    
    # Get tenant ID for context switching
    $currentContext = Get-AzContext
    $tenantId = if ($currentContext -and $currentContext.Tenant) { $currentContext.Tenant.Id } else { $null }
    
    # Check if function exists, if not try to load it directly
    if (-not (Get-Command -Name Get-AzureCostData -ErrorAction SilentlyContinue)) {
        $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $collectorPath = Join-Path $moduleRoot "Private\Collectors\Get-AzureCostData.ps1"
        
        if (Test-Path $collectorPath) {
            try {
                . $collectorPath
            }
            catch {
                Write-Warning "Failed to load Get-AzureCostData function: $_"
            }
        }
    }
    
    # Collect data from each subscription
    foreach ($sub in $Subscriptions) {
        $subscriptionNameToUse = Get-SubscriptionDisplayName -Subscription $sub
        Write-Host "`n  Collecting from: $subscriptionNameToUse..." -ForegroundColor Gray
        
        try {
            # Set context
            Invoke-WithSuppressedWarnings {
                if ($tenantId) {
                    Set-AzContext -SubscriptionId $sub.Id -TenantId $tenantId -ErrorAction Stop | Out-Null
                } else {
                    Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
                }
            }
            
            # Get cost data
            $costData = Get-AzureCostData -SubscriptionId $sub.Id -StartDate $startDate -EndDate $endDate
            
            if ($costData -and $costData.Count -gt 0) {
                # Add subscription name to each item
                foreach ($item in $costData) {
                    $item | Add-Member -MemberType NoteProperty -Name "SubscriptionName" -Value $subscriptionNameToUse -Force
                    $allCostData.Add($item)
                }
                
                Write-Host "    Found $($costData.Count) cost records" -ForegroundColor Green
            }
            else {
                Write-Host "    No cost data available" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Warning "Failed to get cost data for $subscriptionNameToUse : $_"
            $Errors.Add("Failed to get cost data for $subscriptionNameToUse : $_")
        }
    }
    
    Write-Host "`n  Total cost records collected: $($allCostData.Count)" -ForegroundColor Green
    
    # Aggregate data
    if ($allCostData.Count -gt 0) {
        Write-Host "`n  Aggregating cost data..." -ForegroundColor Gray
        
        $totalCostLocal = 0
        $totalCostUSD = 0
        $currency = ""
        
        # Group by subscription
        $subscriptionGroups = $allCostData | Group-Object SubscriptionId
        foreach ($subGroup in $subscriptionGroups) {
            $subId = $subGroup.Name
            $subItems = $subGroup.Group
            $subName = $subItems[0].SubscriptionName
            
            $subCostLocal = ($subItems | Measure-Object -Property CostLocal -Sum).Sum
            $subCostUSD = ($subItems | Measure-Object -Property CostUSD -Sum).Sum
            $subCurrency = if ($subItems[0].Currency) { $subItems[0].Currency } else { "" }
            
            $bySubscription[$subId] = @{
                Name = $subName
                SubscriptionId = $subId
                CostLocal = $subCostLocal
                CostUSD = $subCostUSD
                Currency = $subCurrency
                ItemCount = $subItems.Count
            }
            
            $totalCostLocal += $subCostLocal
            $totalCostUSD += $subCostUSD
            if (-not $currency -and $subCurrency) {
                $currency = $subCurrency
            }
        }
        
        # Group by meter category
        $categoryGroups = $allCostData | Group-Object MeterCategory
        foreach ($catGroup in $categoryGroups) {
            $category = $catGroup.Name
            if ([string]::IsNullOrWhiteSpace($category)) {
                $category = "Unknown"
            }
            
            $catItems = $catGroup.Group
            $catCostLocal = ($catItems | Measure-Object -Property CostLocal -Sum).Sum
            $catCostUSD = ($catItems | Measure-Object -Property CostUSD -Sum).Sum
            
            # Group by subcategory
            $subCatGroups = $catItems | Group-Object MeterSubCategory
            $subCategories = @{}
            foreach ($subCatGroup in $subCatGroups) {
                $subCat = $subCatGroup.Name
                if ([string]::IsNullOrWhiteSpace($subCat)) {
                    $subCat = "N/A"
                }
                
                $subCatItems = $subCatGroup.Group
                $subCatCostLocal = ($subCatItems | Measure-Object -Property CostLocal -Sum).Sum
                $subCatCostUSD = ($subCatItems | Measure-Object -Property CostUSD -Sum).Sum
                
                # Group by meter
                $meterGroups = $subCatItems | Group-Object Meter
                $meters = @{}
                foreach ($meterGroup in $meterGroups) {
                    $meter = $meterGroup.Name
                    if ([string]::IsNullOrWhiteSpace($meter)) {
                        $meter = "Unknown"
                    }
                    
                    $meterItems = $meterGroup.Group
                    $meterCostLocal = ($meterItems | Measure-Object -Property CostLocal -Sum).Sum
                    $meterCostUSD = ($meterItems | Measure-Object -Property CostUSD -Sum).Sum
                    $meterQuantity = ($meterItems | Measure-Object -Property Quantity -Sum).Sum
                    # Get most common UnitOfMeasure for this meter
                    $unitOfMeasureGroups = $meterItems | Where-Object { $_.UnitOfMeasure -and -not [string]::IsNullOrWhiteSpace($_.UnitOfMeasure) } | Group-Object UnitOfMeasure
                    $meterUnitOfMeasure = if ($unitOfMeasureGroups.Count -gt 0) {
                        ($unitOfMeasureGroups | Sort-Object Count -Descending | Select-Object -First 1).Name
                    } else { "" }
                    # Calculate average unit price
                    $meterUnitPrice = if ($meterQuantity -gt 0) { $meterCostLocal / $meterQuantity } else { 0 }
                    $meterUnitPriceUSD = if ($meterQuantity -gt 0) { $meterCostUSD / $meterQuantity } else { 0 }
                    
                    # Group by resource within meter
                    $meterResourceGroups = $meterItems | Where-Object { $_.ResourceName } | Group-Object ResourceName
                    $meterResources = @{}
                    foreach ($meterResGroup in $meterResourceGroups) {
                        $resName = $meterResGroup.Name
                        if ([string]::IsNullOrWhiteSpace($resName)) { continue }
                        
                        $resItems = $meterResGroup.Group
                        $resCostLocal = ($resItems | Measure-Object -Property CostLocal -Sum).Sum
                        $resCostUSD = ($resItems | Measure-Object -Property CostUSD -Sum).Sum
                        
                        $meterResources[$resName] = @{
                            ResourceName = $resName
                            ResourceGroup = if ($resItems[0].ResourceGroup) { $resItems[0].ResourceGroup } else { "N/A" }
                            SubscriptionName = if ($resItems[0].SubscriptionName) { $resItems[0].SubscriptionName } else { "N/A" }
                            CostLocal = $resCostLocal
                            CostUSD = $resCostUSD
                            ItemCount = $resItems.Count
                        }
                    }
                    
                    $meters[$meter] = @{
                        Meter = $meter
                        CostLocal = $meterCostLocal
                        CostUSD = $meterCostUSD
                        Quantity = $meterQuantity
                        UnitOfMeasure = $meterUnitOfMeasure
                        UnitPrice = $meterUnitPrice
                        UnitPriceUSD = $meterUnitPriceUSD
                        ItemCount = $meterItems.Count
                        Resources = $meterResources
                    }
                }
                
                $subCategories[$subCat] = @{
                    MeterSubCategory = $subCat
                    CostLocal = $subCatCostLocal
                    CostUSD = $subCatCostUSD
                    Meters = $meters
                    ItemCount = $subCatItems.Count
                }
            }
            
            $byMeterCategory[$category] = @{
                MeterCategory = $category
                CostLocal = $catCostLocal
                CostUSD = $catCostUSD
                SubCategories = $subCategories
                ItemCount = $catItems.Count
            }
        }
        
        # Group by resource (for top resources)
        $resourceGroups = $allCostData | Where-Object { $_.ResourceId -and -not [string]::IsNullOrWhiteSpace($_.ResourceId) } | Group-Object ResourceId
        foreach ($resGroup in $resourceGroups) {
            $resourceId = $resGroup.Name
            $resItems = $resGroup.Group
            $resName = $resItems[0].ResourceName
            $resGroupName = $resItems[0].ResourceGroup
            $resType = $resItems[0].ResourceType
            $subName = $resItems[0].SubscriptionName
            $subId = $resItems[0].SubscriptionId
            
            # Get most common MeterCategory for this resource
            $meterCategoryGroups = $resItems | Group-Object MeterCategory
            $primaryCategory = if ($meterCategoryGroups.Count -gt 0) {
                ($meterCategoryGroups | Sort-Object Count -Descending | Select-Object -First 1).Name
            } else {
                ""
            }
            
            $resCostLocal = ($resItems | Measure-Object -Property CostLocal -Sum).Sum
            $resCostUSD = ($resItems | Measure-Object -Property CostUSD -Sum).Sum
            
            $byResource[$resourceId] = @{
                ResourceId = $resourceId
                ResourceName = $resName
                ResourceGroup = $resGroupName
                ResourceType = $resType
                SubscriptionName = $subName
                SubscriptionId = $subId
                MeterCategory = $primaryCategory
                CostLocal = $resCostLocal
                CostUSD = $resCostUSD
                ItemCount = $resItems.Count
            }
        }
        
        # Daily trend
        $dailyGroups = $allCostData | Where-Object { $_.Date } | Group-Object { $_.Date.ToString('yyyy-MM-dd') }
        foreach ($dayGroup in $dailyGroups) {
            $dateStr = $dayGroup.Name
            $dayItems = $dayGroup.Group
            
            $dayCostLocal = ($dayItems | Measure-Object -Property CostLocal -Sum).Sum
            $dayCostUSD = ($dayItems | Measure-Object -Property CostUSD -Sum).Sum
            
            # Group by category for daily trend (with subscription breakdown)
            $dayCategoryGroups = $dayItems | Group-Object MeterCategory
            $dayByCategory = @{}
            foreach ($dayCatGroup in $dayCategoryGroups) {
                $cat = $dayCatGroup.Name
                if ([string]::IsNullOrWhiteSpace($cat)) {
                    $cat = "Unknown"
                }
                $dayCatCostLocal = ($dayCatGroup.Group | Measure-Object -Property CostLocal -Sum).Sum
                $dayCatCostUSD = ($dayCatGroup.Group | Measure-Object -Property CostUSD -Sum).Sum
                
                # Subscription breakdown within category
                $catSubGroups = $dayCatGroup.Group | Group-Object SubscriptionName
                $catBySubscription = @{}
                foreach ($catSubGroup in $catSubGroups) {
                    $subName = $catSubGroup.Name
                    if ([string]::IsNullOrWhiteSpace($subName)) { $subName = "Unknown" }
                    $catBySubscription[$subName] = @{
                        CostLocal = ($catSubGroup.Group | Measure-Object -Property CostLocal -Sum).Sum
                        CostUSD = ($catSubGroup.Group | Measure-Object -Property CostUSD -Sum).Sum
                    }
                }
                
                $dayByCategory[$cat] = @{
                    CostLocal = $dayCatCostLocal
                    CostUSD = $dayCatCostUSD
                    BySubscription = $catBySubscription
                }
            }
            
            # Group by subscription for daily trend (with category breakdown)
            $daySubGroups = $dayItems | Group-Object SubscriptionName
            $dayBySubscription = @{}
            foreach ($daySubGroup in $daySubGroups) {
                $subName = $daySubGroup.Name
                if ([string]::IsNullOrWhiteSpace($subName)) {
                    $subName = "Unknown"
                }
                $daySubCostLocal = ($daySubGroup.Group | Measure-Object -Property CostLocal -Sum).Sum
                $daySubCostUSD = ($daySubGroup.Group | Measure-Object -Property CostUSD -Sum).Sum
                
                # Category breakdown within subscription
                $subCatGroups = $daySubGroup.Group | Group-Object MeterCategory
                $subByCategory = @{}
                foreach ($subCatGroup in $subCatGroups) {
                    $catName = $subCatGroup.Name
                    if ([string]::IsNullOrWhiteSpace($catName)) { $catName = "Unknown" }
                    $subByCategory[$catName] = @{
                        CostLocal = ($subCatGroup.Group | Measure-Object -Property CostLocal -Sum).Sum
                        CostUSD = ($subCatGroup.Group | Measure-Object -Property CostUSD -Sum).Sum
                    }
                }
                
                $dayBySubscription[$subName] = @{
                    CostLocal = $daySubCostLocal
                    CostUSD = $daySubCostUSD
                    ByCategory = $subByCategory
                }
            }
            
            # Group by meter for daily trend (with category and subscription breakdown)
            $dayMeterGroups = $dayItems | Group-Object Meter
            $dayByMeter = @{}
            foreach ($dayMeterGroup in $dayMeterGroups) {
                $meterName = $dayMeterGroup.Name
                if ([string]::IsNullOrWhiteSpace($meterName)) {
                    $meterName = "Unknown"
                }
                $dayMeterCostLocal = ($dayMeterGroup.Group | Measure-Object -Property CostLocal -Sum).Sum
                $dayMeterCostUSD = ($dayMeterGroup.Group | Measure-Object -Property CostUSD -Sum).Sum
                
                # Category breakdown within meter
                $meterCatGroups = $dayMeterGroup.Group | Group-Object MeterCategory
                $meterByCategory = @{}
                foreach ($meterCatGroup in $meterCatGroups) {
                    $catName = $meterCatGroup.Name
                    if ([string]::IsNullOrWhiteSpace($catName)) { $catName = "Unknown" }
                    $meterByCategory[$catName] = @{
                        CostLocal = ($meterCatGroup.Group | Measure-Object -Property CostLocal -Sum).Sum
                        CostUSD = ($meterCatGroup.Group | Measure-Object -Property CostUSD -Sum).Sum
                    }
                }
                
                # Subscription breakdown within meter
                $meterSubGroups = $dayMeterGroup.Group | Group-Object SubscriptionName
                $meterBySubscription = @{}
                foreach ($meterSubGroup in $meterSubGroups) {
                    $subName = $meterSubGroup.Name
                    if ([string]::IsNullOrWhiteSpace($subName)) { $subName = "Unknown" }
                    $meterBySubscription[$subName] = @{
                        CostLocal = ($meterSubGroup.Group | Measure-Object -Property CostLocal -Sum).Sum
                        CostUSD = ($meterSubGroup.Group | Measure-Object -Property CostUSD -Sum).Sum
                    }
                }
                
                $dayByMeter[$meterName] = @{
                    CostLocal = $dayMeterCostLocal
                    CostUSD = $dayMeterCostUSD
                    ByCategory = $meterByCategory
                    BySubscription = $meterBySubscription
                }
            }
            
            # Group by resource for daily trend (with category and subscription breakdown)
            # Limit to top 50 per day for performance, but collect all unique resource names separately
            $dayResourceGroups = $dayItems | Where-Object { $_.ResourceName } | Group-Object ResourceName
            $dayByResource = @{}
            
            # Pre-calculate costs for all resources to avoid expensive Measure-Object calls in Sort-Object
            $resourceCosts = @{}
            foreach ($dayResGroup in $dayResourceGroups) {
                $resName = $dayResGroup.Name
                if ([string]::IsNullOrWhiteSpace($resName)) {
                    continue
                }
                $resCostLocal = ($dayResGroup.Group | Measure-Object -Property CostLocal -Sum).Sum
                $resourceCosts[$resName] = @{
                    Group = $dayResGroup.Group
                    CostLocal = $resCostLocal
                }
            }
            
            # Process top 50 resources per day for performance (category filtering will use raw data)
            $topResourcesForDay = $resourceCosts.GetEnumerator() | Sort-Object { $_.Value.CostLocal } -Descending | Select-Object -First 50
            
            foreach ($resEntry in $topResourcesForDay) {
                $resName = $resEntry.Key
                $dayResGroupItems = $resEntry.Value.Group
                $dayResCostLocal = $resEntry.Value.CostLocal
                $dayResCostUSD = ($dayResGroupItems | Measure-Object -Property CostUSD -Sum).Sum
                
                # Category breakdown within resource
                $resCatGroups = $dayResGroupItems | Group-Object MeterCategory
                $resByCategory = @{}
                foreach ($resCatGroup in $resCatGroups) {
                    $catName = $resCatGroup.Name
                    if ([string]::IsNullOrWhiteSpace($catName)) { $catName = "Unknown" }
                    $resByCategory[$catName] = @{
                        CostLocal = ($resCatGroup.Group | Measure-Object -Property CostLocal -Sum).Sum
                        CostUSD = ($resCatGroup.Group | Measure-Object -Property CostUSD -Sum).Sum
                    }
                }
                
                # Subscription breakdown within resource
                $resSubGroups = $dayResGroupItems | Group-Object SubscriptionName
                $resBySubscription = @{}
                foreach ($resSubGroup in $resSubGroups) {
                    $subName = $resSubGroup.Name
                    if ([string]::IsNullOrWhiteSpace($subName)) { $subName = "Unknown" }
                    $resBySubscription[$subName] = @{
                        CostLocal = ($resSubGroup.Group | Measure-Object -Property CostLocal -Sum).Sum
                        CostUSD = ($resSubGroup.Group | Measure-Object -Property CostUSD -Sum).Sum
                    }
                }
                
                $dayByResource[$resName] = @{
                    CostLocal = $dayResCostLocal
                    CostUSD = $dayResCostUSD
                    ByCategory = $resByCategory
                    BySubscription = $resBySubscription
                }
            }
            
            $dailyTrend[$dateStr] = @{
                Date = [DateTime]::ParseExact($dateStr, 'yyyy-MM-dd', $null)
                DateString = $dateStr
                TotalCostLocal = $dayCostLocal
                TotalCostUSD = $dayCostUSD
                ByCategory = $dayByCategory
                BySubscription = $dayBySubscription
                ByMeter = $dayByMeter
                ByResource = $dayByResource
            }
        }
        
        # Collect ALL unique resource names from raw data (for category filtering support)
        # This is separate from daily trend which is limited for performance
        $allUniqueResourceNames = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($item in $allCostData) {
            if ($item.ResourceName -and -not [string]::IsNullOrWhiteSpace($item.ResourceName)) {
                [void]$allUniqueResourceNames.Add($item.ResourceName)
            }
        }
        
        # Fill in missing dates with zero-cost entries to ensure all dates in range are present
        $currentDate = $startDate
        while ($currentDate -le $endDate) {
            $dateStr = $currentDate.ToString('yyyy-MM-dd')
            if (-not $dailyTrend.ContainsKey($dateStr)) {
                $dailyTrend[$dateStr] = @{
                    Date = $currentDate
                    DateString = $dateStr
                    TotalCostLocal = 0
                    TotalCostUSD = 0
                    ByCategory = @{}
                    BySubscription = @{}
                    ByMeter = @{}
                    ByResource = @{}
                }
            }
            $currentDate = $currentDate.AddDays(1)
        }
    }
    
    # Build aggregated result
    $result = @{
        GeneratedAt = Get-Date
        PeriodStart = $startDate
        PeriodEnd = $endDate
        DaysToInclude = $DaysToInclude
        TotalCostLocal = $totalCostLocal
        TotalCostUSD = $totalCostUSD
        Currency = $currency
        BySubscription = $bySubscription
        ByMeterCategory = $byMeterCategory
        TopResources = @($byResource.Values | Sort-Object { $_.CostUSD } -Descending | Select-Object -First 20)
        DailyTrend = @($dailyTrend.Values | Sort-Object Date)
        RawData = $allCostData
        AllUniqueResourceNames = @($allUniqueResourceNames | Sort-Object)
        SubscriptionCount = $Subscriptions.Count
    }
    
    Write-Host "`n  Aggregation complete:" -ForegroundColor Green
    Write-Host "    Total Cost: $currency $([math]::Round($totalCostLocal, 2)) ($([math]::Round($totalCostUSD, 2)) USD)" -ForegroundColor Green
    Write-Host "    Subscriptions: $($bySubscription.Count)" -ForegroundColor Green
    Write-Host "    Meter Categories: $($byMeterCategory.Count)" -ForegroundColor Green
    Write-Host "    Resources: $($byResource.Count)" -ForegroundColor Green
    
    return $result
}

