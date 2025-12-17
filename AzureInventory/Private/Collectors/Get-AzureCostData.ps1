<#
.SYNOPSIS
    Retrieves Azure cost data for a subscription via Cost Management REST API.

.DESCRIPTION
    Uses Azure Cost Management REST API to fetch cost data with meter-level granularity.
    Supports pagination via nextLink and handles rate limiting.

.PARAMETER SubscriptionId
    Azure subscription ID.

.PARAMETER StartDate
    Start date for the cost query (DateTime).

.PARAMETER EndDate
    End date for the cost query (DateTime).

.OUTPUTS
    Array of PSCustomObject with cost data: Date, MeterCategory, MeterSubCategory, Meter, ResourceId, ResourceName, ResourceGroup, ResourceType, CostLocal, CostUSD, Currency
#>
function Get-AzureCostData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [DateTime]$StartDate,
        
        [Parameter(Mandatory = $true)]
        [DateTime]$EndDate
    )
    
    try {
        # Build API endpoint
        $apiVersion = "2023-11-01"
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=$apiVersion"
        
        # Build request body
        $requestBody = @{
            type = "ActualCost"
            dataSet = @{
                granularity = "Daily"
                aggregation = @{
                    totalCost = @{
                        name = "Cost"
                        function = "Sum"
                    }
                    totalCostUSD = @{
                        name = "CostUSD"
                        function = "Sum"
                    }
                }
                grouping = @(
                    @{ type = "Dimension"; name = "MeterCategory" }
                    @{ type = "Dimension"; name = "MeterSubCategory" }
                    @{ type = "Dimension"; name = "Meter" }
                    @{ type = "Dimension"; name = "ResourceId" }
                )
                sorting = @(
                    @{ direction = "descending"; name = "UsageDate" }
                )
            }
            timeframe = "Custom"
            timePeriod = @{
                from = $StartDate.ToString("yyyy-MM-dd")
                to = $EndDate.ToString("yyyy-MM-dd")
            }
        } | ConvertTo-Json -Depth 10
        
        Write-Verbose "Fetching cost data for subscription $SubscriptionId from $($StartDate.ToString('yyyy-MM-dd')) to $($EndDate.ToString('yyyy-MM-dd'))"
        
        # Pagination variables
        $allRows = [System.Collections.Generic.List[PSObject]]::new()
        $nextLink = $null
        $pageCount = 0
        $maxPages = 50  # Prevent infinite loops
        
        do {
            $pageCount++
            Write-Verbose "Fetching cost data page $pageCount..."
            
            # Use Invoke-AzRestMethod for automatic auth handling
            try {
                if ($nextLink) {
                    # Follow nextLink for pagination
                    $response = Invoke-AzRestMethod -Method GET -Uri $nextLink -ErrorAction Stop
                } else {
                    # Initial POST request
                    $response = Invoke-AzRestMethod -Method POST -Uri $uri -Payload $requestBody -ErrorAction Stop
                }
            }
            catch {
                # Handle rate limiting (429) and other errors
                if ($_.Exception.Message -match '429|throttl|TooManyRequests') {
                    Write-Warning "Rate limited. Waiting before retry..."
                    Start-Sleep -Seconds 5
                    continue
                }
                elseif ($_.Exception.Message -match '400|BadRequest') {
                    Write-Warning "Bad Request for subscription $SubscriptionId. Cost data may not be available or query parameters invalid."
                    Write-Verbose "Error: $($_.Exception.Message)"
                    return @()  # Return empty array instead of throwing
                }
                elseif ($_.Exception.Message -match '404|NotFound') {
                    Write-Verbose "Cost Management API not available for subscription $SubscriptionId (404). Skipping."
                    return @()  # Return empty array
                }
                else {
                    Write-Warning "Failed to fetch cost data for subscription ${SubscriptionId}: $($_.Exception.Message)"
                    throw
                }
            }
            
            if ($response.StatusCode -eq 200 -and $response.Content) {
                $responseData = $response.Content | ConvertFrom-Json
                
                # Parse response structure
                if ($responseData.properties -and $responseData.properties.columns -and $responseData.properties.rows) {
                    $columns = $responseData.properties.columns
                    $rows = $responseData.properties.rows
                    
                    # Find column indices
                    $costIndex = -1
                    $costUsdIndex = -1
                    $usageDateIndex = -1
                    $meterCategoryIndex = -1
                    $meterSubCategoryIndex = -1
                    $meterIndex = -1
                    $resourceIdIndex = -1
                    $currencyIndex = -1
                    
                    for ($i = 0; $i -lt $columns.Count; $i++) {
                        $colName = $columns[$i].name
                        switch ($colName) {
                            "Cost" { $costIndex = $i }
                            "CostUSD" { $costUsdIndex = $i }
                            "UsageDate" { $usageDateIndex = $i }
                            "MeterCategory" { $meterCategoryIndex = $i }
                            "MeterSubCategory" { $meterSubCategoryIndex = $i }
                            "Meter" { $meterIndex = $i }
                            "ResourceId" { $resourceIdIndex = $i }
                            "Currency" { $currencyIndex = $i }
                        }
                    }
                    
                    # Parse rows
                    foreach ($row in $rows) {
                        if ($row.Count -lt $columns.Count) {
                            Write-Verbose "Skipping incomplete row (expected $($columns.Count) columns, got $($row.Count))"
                            continue
                        }
                        
                        # Extract values from row array
                        $costLocal = if ($costIndex -ge 0) { [decimal]$row[$costIndex] } else { 0 }
                        $costUSD = if ($costUsdIndex -ge 0) { [decimal]$row[$costUsdIndex] } else { 0 }
                        $usageDate = if ($usageDateIndex -ge 0) { $row[$usageDateIndex] } else { $null }
                        $meterCategory = if ($meterCategoryIndex -ge 0) { [string]$row[$meterCategoryIndex] } else { "" }
                        $meterSubCategory = if ($meterSubCategoryIndex -ge 0) { [string]$row[$meterSubCategoryIndex] } else { "" }
                        $meter = if ($meterIndex -ge 0) { [string]$row[$meterIndex] } else { "" }
                        $resourceId = if ($resourceIdIndex -ge 0) { [string]$row[$resourceIdIndex] } else { "" }
                        $currency = if ($currencyIndex -ge 0) { [string]$row[$currencyIndex] } else { "" }
                        
                        # Parse UsageDate (format: YYYYMMDD as integer)
                        $dateObj = $null
                        if ($usageDate -and $usageDate -is [int]) {
                            $dateStr = $usageDate.ToString()
                            if ($dateStr.Length -eq 8) {
                                try {
                                    $year = [int]$dateStr.Substring(0, 4)
                                    $month = [int]$dateStr.Substring(4, 2)
                                    $day = [int]$dateStr.Substring(6, 2)
                                    $dateObj = Get-Date -Year $year -Month $month -Day $day
                                }
                                catch {
                                    Write-Verbose "Failed to parse UsageDate: $usageDate"
                                }
                            }
                        }
                        
                        # Parse ResourceId to extract ResourceName, ResourceGroup, ResourceType
                        $resourceName = ""
                        $resourceGroup = ""
                        $resourceType = ""
                        
                        if ($resourceId -and -not [string]::IsNullOrWhiteSpace($resourceId)) {
                            $parsed = Parse-ResourceId -ResourceId $resourceId
                            $resourceName = $parsed.ResourceName
                            $resourceGroup = $parsed.ResourceGroup
                            $resourceType = if ($parsed.Provider -and $parsed.ResourceType) {
                                "$($parsed.Provider)/$($parsed.ResourceType)"
                            } else { "" }
                        }
                        
                        # Create cost object
                        $costObj = [PSCustomObject]@{
                            Date = $dateObj
                            MeterCategory = $meterCategory
                            MeterSubCategory = if ([string]::IsNullOrWhiteSpace($meterSubCategory)) { "N/A" } else { $meterSubCategory }
                            Meter = $meter
                            ResourceId = $resourceId
                            ResourceName = $resourceName
                            ResourceGroup = $resourceGroup
                            ResourceType = $resourceType
                            CostLocal = $costLocal
                            CostUSD = $costUSD
                            Currency = $currency
                            SubscriptionId = $SubscriptionId
                        }
                        
                        $allRows.Add($costObj)
                    }
                    
                    Write-Verbose "Retrieved $($rows.Count) rows from page $pageCount (total: $($allRows.Count))"
                }
                else {
                    Write-Verbose "No cost data in response (empty result set)"
                }
                
                # Check for nextLink
                if ($responseData.properties.nextLink) {
                    $nextLink = $responseData.properties.nextLink
                    Write-Verbose "Found nextLink, continuing pagination..."
                }
                else {
                    $nextLink = $null
                }
                
                if ($pageCount -ge $maxPages) {
                    Write-Warning "Reached maximum page limit ($maxPages). Stopping pagination."
                    break
                }
            }
            else {
                Write-Warning "Unexpected response status: $($response.StatusCode)"
                break
            }
        } while ($nextLink)
        
        Write-Verbose "Total cost rows retrieved: $($allRows.Count)"
        return @($allRows)
    }
    catch {
        Write-Warning "Failed to get cost data for subscription ${SubscriptionId}: $_"
        return @()  # Return empty array on error
    }
}

