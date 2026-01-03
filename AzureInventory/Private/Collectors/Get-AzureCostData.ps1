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
    Array of PSCustomObject with cost data: Date, MeterCategory, MeterSubCategory, Meter, ResourceId, ResourceName, ResourceGroup, ResourceType, CostLocal, CostUSD, Currency, Quantity, UnitOfMeasure, UnitPrice, UnitPriceUSD
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
        $maxPages = 200  # Increased to handle large datasets (200 pages * 5000 records = 1M records)
        $maxRetriesPerPage = 5  # Maximum retries for rate limiting per page
        $baseRetryDelay = 5  # Base delay in seconds for exponential backoff
        $stopPagination = $false  # Flag to stop pagination loop
        
        do {
            $pageCount++
            Write-Verbose "Fetching cost data page $pageCount..."
            
            $retryCount = 0
            $pageRetrieved = $false
            
            # Retry loop for rate limiting
            while (-not $pageRetrieved -and $retryCount -lt $maxRetriesPerPage -and -not $stopPagination) {
                # Use Invoke-AzRestMethod for automatic auth handling
                try {
                    if ($nextLink) {
                        # Follow nextLink for pagination - Azure Cost Management API requires POST with same body
                        $response = Invoke-AzRestMethod -Method POST -Uri $nextLink -Payload $requestBody -ErrorAction Stop
                    } else {
                        # Initial POST request
                        $response = Invoke-AzRestMethod -Method POST -Uri $uri -Payload $requestBody -ErrorAction Stop
                    }
                    
                    # Check for rate limiting in response status code
                    if ($response.StatusCode -eq 429) {
                        $retryCount++
                        $retryDelay = $baseRetryDelay * [math]::Pow(2, $retryCount - 1)  # Exponential backoff: 5, 10, 20, 40, 80 seconds
                        Write-Verbose "Rate limited (429) on page $pageCount. Retry $retryCount/$maxRetriesPerPage. Waiting $retryDelay seconds..."
                        Start-Sleep -Seconds $retryDelay
                        continue  # Retry the same page
                    }
                    
                    # If we get here, we have a valid response (or non-429 error)
                    $pageRetrieved = $true
                }
                catch {
                    # Handle rate limiting (429) in exception message
                    if ($_.Exception.Message -match '429|throttl|TooManyRequests') {
                        $retryCount++
                        $retryDelay = $baseRetryDelay * [math]::Pow(2, $retryCount - 1)  # Exponential backoff
                        Write-Verbose "Rate limited (429) on page $pageCount. Retry $retryCount/$maxRetriesPerPage. Waiting $retryDelay seconds..."
                        Start-Sleep -Seconds $retryDelay
                        continue  # Retry the same page
                    }
                    elseif ($_.Exception.Message -match '405|MethodNotAllowed') {
                        Write-Warning "Method not allowed (405) for subscription $SubscriptionId. This may indicate a pagination issue."
                        Write-Verbose "Error: $($_.Exception.Message)"
                        if ($nextLink) {
                            Write-Verbose "Attempted to use nextLink: $nextLink"
                        }
                        # Stop pagination loop but return what we have so far
                        $stopPagination = $true
                        break
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
            }
            
            # If we exhausted retries, break and return what we have
            if (-not $pageRetrieved -and -not $stopPagination) {
                Write-Warning "Exhausted retry attempts for page $pageCount due to rate limiting. Returning $($allRows.Count) records collected so far."
                break
            }
            
            # If stop flag is set, break from pagination
            if ($stopPagination) {
                break
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
                    $quantityIndex = -1
                    $unitOfMeasureIndex = -1
                    
                    # Log all available columns for debugging
                    $availableColumns = $columns | ForEach-Object { $_.name }
                    Write-Verbose "Available columns in API response: $($availableColumns -join ', ')"
                    
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
                            "Quantity" { $quantityIndex = $i }
                            "UnitOfMeasure" { $unitOfMeasureIndex = $i }
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
                        $quantity = if ($quantityIndex -ge 0) { [decimal]$row[$quantityIndex] } else { 0 }
                        $unitOfMeasure = if ($unitOfMeasureIndex -ge 0) { [string]$row[$unitOfMeasureIndex] } else { "" }
                        
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
                        
                        # Calculate unit price if quantity is available
                        $unitPrice = if ($quantity -gt 0) { $costLocal / $quantity } else { 0 }
                        $unitPriceUSD = if ($quantity -gt 0) { $costUSD / $quantity } else { 0 }
                        
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
                    if ($pageCount % 10 -eq 0) {
                        Write-Host "    Progress: $pageCount pages, $($allRows.Count) records collected..." -ForegroundColor Gray
                    }
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
            elseif ($response.StatusCode -eq 429) {
                # This should have been caught in the retry loop, but handle it here as a fallback
                Write-Warning "Rate limited (429) on page $pageCount after retries. Returning $($allRows.Count) records collected so far."
                break
            }
            else {
                if ($response.StatusCode -eq 405) {
                    Write-Warning "Method not allowed (405) for subscription $SubscriptionId. Pagination may have failed."
                    if ($nextLink) {
                        Write-Verbose "Attempted to use nextLink: $nextLink"
                    }
                } else {
                    Write-Warning "Unexpected response status: $($response.StatusCode) for subscription $SubscriptionId"
                }
                break
            }
        } while ($nextLink -and -not $stopPagination)
        
        Write-Verbose "Total cost rows retrieved: $($allRows.Count)"
        return @($allRows)
    }
    catch {
        Write-Warning "Failed to get cost data for subscription ${SubscriptionId}: $_"
        return @()  # Return empty array on error
    }
}

