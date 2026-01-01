<#
.SYNOPSIS
    Retrieves Azure resource changes using Resource Graph Change Analysis.

.DESCRIPTION
    Uses Azure Resource Graph resourcechanges table to get actual configuration changes
    on resources. This provides property-level change details (before/after values) and
    filters out audit log noise. Optionally includes RBAC role assignment events from Activity Log.

.PARAMETER SubscriptionIds
    Array of Azure subscription IDs to query.

.PARAMETER Days
    Number of days to look back (default: 14, max: 14 due to Azure limitation).

.PARAMETER IncludeSecurityEvents
    If true, also queries Activity Log for RBAC role assignment events (write/delete).
    Note: RBAC role assignments are NOT tracked in Resource Graph Change Analysis, so Activity Log
    is needed for these. Other security operations (NSG rules, Key Vault policies, Public IPs, etc.)
    are already tracked in Resource Graph Change Analysis via the resourcechanges table.

.OUTPUTS
    Array of change tracking objects with ChangeTime, ChangeType, ResourceType, etc.
#>
function Get-AzureChangeAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$SubscriptionIds,
        
        [Parameter(Mandatory = $false)]
        [int]$Days = 14,
        
        [Parameter(Mandatory = $false)]
        [switch]$IncludeSecurityEvents
    )
    
    # Validate days parameter (max 14 due to Azure limitation)
    if ($Days -gt 14) {
        Write-Warning "Days parameter cannot exceed 14 (Azure limitation). Using 14 days."
        $Days = 14
    }
    if ($Days -lt 1) {
        Write-Warning "Days parameter must be at least 1. Using 1 day."
        $Days = 1
    }
    
    $changes = [System.Collections.Generic.List[PSObject]]::new()
    
    # Check for Az.ResourceGraph module
    if (-not (Get-Module -ListAvailable -Name Az.ResourceGraph)) {
        Write-Warning "Az.ResourceGraph module is not available. Change Analysis will be skipped."
        return @()
    }
    
    Import-Module Az.ResourceGraph -ErrorAction SilentlyContinue | Out-Null
    
    try {
        Write-Host "  Retrieving Change Analysis for $($SubscriptionIds.Count) subscription(s)..." -ForegroundColor Cyan
        
        # Build Resource Graph query
        # Note: resourcechanges table uses nested properties structure
        $kqlQuery = @"
resourcechanges
| extend changeTime = todatetime(properties.changeAttributes.timestamp)
| extend changeType = properties.changeType
| extend resourceId = properties.targetResourceId
| extend targetResourceType = properties.targetResourceType
| extend changes = properties.changes
| extend changedBy = tostring(properties.changeAttributes.changedBy)
| extend changedByType = tostring(properties.changeAttributes.changedByType)
| extend clientType = tostring(properties.changeAttributes.clientType)
| extend operation = tostring(properties.changeAttributes.operation)
| where changeTime > ago(${Days}d)
| where changeType in ('Create', 'Update', 'Delete')
| extend resourceName = tostring(split(resourceId, '/')[-1])
| extend resourceGroup = tostring(split(resourceId, '/')[4])
| extend subscriptionId = tostring(split(resourceId, '/')[2])
| project changeTime, changeType, resourceId, targetResourceType, resourceName, resourceGroup, subscriptionId, changes, changedBy, changedByType, clientType, operation
| order by changeTime desc
"@
        
        # Execute cross-subscription query with pagination
        Write-Verbose "Executing Resource Graph query for Change Analysis..."
        $allQueryResults = [System.Collections.Generic.List[PSObject]]::new()
        $skipToken = $null
        $pageCount = 0
        $batchSize = 1000  # Maximum batch size per Azure Resource Graph query
        $maxPages = 100    # Safety limit to prevent infinite loops
        
        try {
            do {
                $pageCount++
                Write-Verbose "Fetching Change Analysis page $pageCount..."
                
                if ($skipToken) {
                    $graphResult = Search-AzGraph -Query $kqlQuery -Subscription $SubscriptionIds -First $batchSize -SkipToken $skipToken -ErrorAction Stop
                } else {
                    $graphResult = Search-AzGraph -Query $kqlQuery -Subscription $SubscriptionIds -First $batchSize -ErrorAction Stop
                }
                
                # Handle PSResourceGraphResponse object (standard return type)
                # Check if it's a PSResourceGraphResponse by checking for Data property
                if ($graphResult.PSObject.Properties['Data']) {
                    # Standard PSResourceGraphResponse object
                    $data = $graphResult.Data
                    if ($data) {
                        foreach ($item in $data) {
                            $allQueryResults.Add($item)
                        }
                        $itemCount = $data.Count
                    } else {
                        $itemCount = 0
                    }
                    
                    # Check for SkipToken property
                    if ($graphResult.PSObject.Properties['SkipToken']) {
                        $skipToken = $graphResult.SkipToken
                    } else {
                        $skipToken = $null
                    }
                    
                    Write-Verbose "Retrieved $itemCount changes (page $pageCount, total: $($allQueryResults.Count))"
                    if ($pageCount % 10 -eq 0 -and $itemCount -gt 0) {
                        Write-Host "    Progress: $pageCount pages, $($allQueryResults.Count) changes collected..." -ForegroundColor Gray
                    }
                } elseif ($graphResult -is [Array]) {
                    # Direct array return (backward compatibility)
                    foreach ($item in $graphResult) {
                        $allQueryResults.Add($item)
                    }
                    $skipToken = $null  # Arrays don't have SkipToken
                    Write-Verbose "Retrieved $($graphResult.Count) changes (page $pageCount, total: $($allQueryResults.Count))"
                } else {
                    Write-Warning "Unexpected result format from Search-AzGraph. Result type: $($graphResult.GetType().FullName)"
                    Write-Verbose "Result properties: $($graphResult.PSObject.Properties.Name -join ', ')"
                    break
                }
                
                if ($pageCount -ge $maxPages) {
                    Write-Warning "Reached maximum page limit ($maxPages). Stopping pagination. Total changes collected: $($allQueryResults.Count)"
                    break
                }
            } while ($skipToken)
            
            Write-Verbose "Finished pagination. Total changes from Resource Graph: $($allQueryResults.Count)"
        }
        catch {
            Write-Warning "Resource Graph query failed: $_"
            return @()
        }
        
        $queryResult = $allQueryResults
        
        if ($null -eq $queryResult -or $queryResult.Count -eq 0) {
            Write-Host "    No changes found in Resource Graph" -ForegroundColor Yellow
        }
        else {
            Write-Host "    Found $($queryResult.Count) changes from Resource Graph" -ForegroundColor Green
        }
        
        # Build subscription ID to name mapping
        # Suppress warnings for subscriptions in other tenants
        $subscriptionNameMap = @{}
        foreach ($subId in $SubscriptionIds) {
            try {
                # Suppress warnings about other tenants
                $sub = Invoke-WithSuppressedWarnings {
                    Get-AzSubscription -SubscriptionId $subId -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                }
                if ($sub) {
                    $subName = Get-SubscriptionDisplayName -Subscription $sub
                    $subscriptionNameMap[$subId] = $subName
                }
                else {
                    $subscriptionNameMap[$subId] = $subId
                }
            }
            catch {
                # If we can't get subscription name, just use the ID
                $subscriptionNameMap[$subId] = $subId
            }
        }
        
        # Process each change
        foreach ($change in $queryResult) {
            try {
                # Parse change time
                $changeTime = $null
                if ($change.changeTime) {
                    try {
                        $changeTime = [DateTime]$change.changeTime
                    }
                    catch {
                        $changeTime = Get-Date
                    }
                }
                else {
                    $changeTime = Get-Date
                }
                
                # Get basic properties
                $changeType = $change.changeType
                $resourceId = $change.resourceId
                $targetResourceType = $change.targetResourceType
                $resourceName = $change.resourceName
                $resourceGroup = $change.resourceGroup
                $subscriptionId = $change.subscriptionId
                
                # Get caller information
                $changedBy = $change.changedBy
                $changedByType = $change.changedByType
                $clientType = $change.clientType
                $operation = if ($change.operation) { $change.operation } else { $null }
                
                # Debug: Log if operation is missing
                if (-not $operation -and $changeType -eq 'Update') {
                    Write-Verbose "Operation field is missing for Update change: ResourceId=$resourceId"
                }
                
                # Get subscription name
                $subscriptionName = if ($subscriptionNameMap.ContainsKey($subscriptionId)) {
                    $subscriptionNameMap[$subscriptionId]
                }
                else {
                    $subscriptionId
                }
                
                # Map resource type to category
                $resourceCategory = Get-ResourceCategory -ResourceType $targetResourceType
                
                # Parse changed properties for Update operations
                $changedProperties = @()
                $hasChangeDetails = $false
                if ($changeType -eq 'Update') {
                    if ($change.changes) {
                        try {
                            $changesJson = $change.changes
                            if ($changesJson -is [string]) {
                                $changesObj = $changesJson | ConvertFrom-Json
                            }
                            else {
                                $changesObj = $changesJson
                            }
                            
                            if ($changesObj) {
                                # Check if changes object has any properties
                                $propertyCount = ($changesObj.PSObject.Properties | Measure-Object).Count
                                if ($propertyCount -gt 0) {
                                    $hasChangeDetails = $true
                                    foreach ($prop in $changesObj.PSObject.Properties) {
                                        $propValue = $prop.Value
                                        $changedProperties += [PSCustomObject]@{
                                            PropertyPath = $prop.Name
                                            PreviousValue = if ($propValue.previousValue) { $propValue.previousValue.ToString() } else { $null }
                                            NewValue = if ($propValue.newValue) { $propValue.newValue.ToString() } else { $null }
                                            ChangeCategory = if ($propValue.changeCategory) { $propValue.changeCategory } else { 'User' }
                                        }
                                    }
                                }
                            }
                        }
                        catch {
                            Write-Verbose "Failed to parse changes JSON for $resourceId : $_"
                        }
                    }
                    # If no changes field or empty, mark that change details aren't available
                    if (-not $hasChangeDetails) {
                        $changedProperties = $null  # Use null to indicate no details available
                    }
                }
                
                # Create change object
                $changeObj = [PSCustomObject]@{
                    ChangeTime          = $changeTime
                    ChangeType          = $changeType
                    ResourceType        = $targetResourceType
                    ResourceCategory   = $resourceCategory
                    ResourceName       = $resourceName
                    ResourceGroup      = $resourceGroup
                    SubscriptionId      = $subscriptionId
                    SubscriptionName   = $subscriptionName
                    ResourceId          = $resourceId
                    ChangedProperties  = $changedProperties
                    HasChangeDetails   = $hasChangeDetails
                    ChangeSource        = 'ChangeAnalysis'
                    SecurityFlag        = $null
                    SecurityReason      = $null
                    Caller              = $changedBy
                    CallerType          = $changedByType
                    ClientType          = $clientType
                    Operation           = $operation
                }
                
                $changes.Add($changeObj)
            }
            catch {
                Write-Warning "Failed to process change entry: $_"
                Write-Verbose "Change details: ResourceId=$($change.resourceId), Error=$($_.Exception.Message)"
            }
        }
        
        # Add security events from Activity Log if requested
        # Note: Only RBAC role assignments are queried from Activity Log, as they are not tracked in Resource Graph Change Analysis
        if ($IncludeSecurityEvents) {
            Write-Host "  Retrieving RBAC role assignment events from Activity Log (filtered at API level)..." -ForegroundColor Cyan
            $securityChanges = Get-SecurityEventsFromActivityLog -SubscriptionIds $SubscriptionIds -Days $Days
            if ($securityChanges -and $securityChanges.Count -gt 0) {
                Write-Host "    Found $($securityChanges.Count) security events" -ForegroundColor Green
                foreach ($secChange in $securityChanges) {
                    $changes.Add($secChange)
                }
            }
            else {
                Write-Host "    No security events found" -ForegroundColor Yellow
            }
        }
        
        Write-Host "    Total changes collected: $($changes.Count)" -ForegroundColor $(if ($changes.Count -gt 0) { 'Green' } else { 'Yellow' })
    }
    catch {
        Write-Warning "Failed to retrieve Change Analysis: $_"
    }
    
    return @($changes)
}

<#
.SYNOPSIS
    Maps resource type to category.

.DESCRIPTION
    Maps Azure resource types (e.g., microsoft.compute/virtualmachines) to
    high-level categories (e.g., Compute).

.PARAMETER ResourceType
    The resource type to map (e.g., "microsoft.compute/virtualmachines").
#>
function Get-ResourceCategory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceType
    )
    
    if ([string]::IsNullOrWhiteSpace($ResourceType)) {
        return 'Other'
    }
    
    $resourceTypeLower = $ResourceType.ToLower()
    
    # Compute
    if ($resourceTypeLower -like 'microsoft.compute/*' -or 
        $resourceTypeLower -like 'microsoft.containerservice/*') {
        return 'Compute'
    }
    
    # Storage
    if ($resourceTypeLower -like 'microsoft.storage/*' -or 
        $resourceTypeLower -like 'microsoft.recoveryservices/*') {
        return 'Storage'
    }
    
    # Networking
    if ($resourceTypeLower -like 'microsoft.network/*') {
        return 'Networking'
    }
    
    # Databases
    if ($resourceTypeLower -like 'microsoft.sql/*' -or 
        $resourceTypeLower -like 'microsoft.documentdb/*' -or 
        $resourceTypeLower -like 'microsoft.dbformysql/*' -or 
        $resourceTypeLower -like 'microsoft.dbforpostgresql/*') {
        return 'Databases'
    }
    
    # Web
    if ($resourceTypeLower -like 'microsoft.web/*') {
        return 'Web'
    }
    
    # Security
    if ($resourceTypeLower -like 'microsoft.keyvault/*' -or 
        $resourceTypeLower -like 'microsoft.authorization/*') {
        return 'Security'
    }
    
    # Identity
    if ($resourceTypeLower -like 'microsoft.managedidentity/*' -or 
        $resourceTypeLower -like 'microsoft.aad/*') {
        return 'Identity'
    }
    
    # Monitoring
    if ($resourceTypeLower -like 'microsoft.insights/*' -or 
        $resourceTypeLower -like 'microsoft.operationalinsights/*') {
        return 'Monitoring'
    }
    
    # Other
    return 'Other'
}

<#
.SYNOPSIS
    Retrieves RBAC role assignment events from Activity Log.

.DESCRIPTION
    Queries Activity Log for RBAC role assignment operations (write/delete) only.
    These are NOT tracked in Resource Graph Change Analysis, so we need Activity Log.
    Other security operations (NSG rules, Key Vault policies, etc.) are already tracked
    in Resource Graph Change Analysis via the resourcechanges table.

.PARAMETER SubscriptionIds
    Array of subscription IDs to query.

.PARAMETER Days
    Number of days to look back.
#>
function Get-SecurityEventsFromActivityLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$SubscriptionIds,
        
        [Parameter(Mandatory = $true)]
        [int]$Days
    )
    
    $securityChanges = [System.Collections.Generic.List[PSObject]]::new()
    
    # Security operations to track from Activity Log
    # Note: Only RBAC role assignments are tracked here because they are NOT included in Resource Graph Change Analysis.
    # Other security operations (NSG rules, Key Vault policies, Public IPs, Policy Exemptions) are already
    # tracked in Resource Graph Change Analysis via the resourcechanges table, so we don't need Activity Log for those.
    $securityOperations = @{
        'Microsoft.Authorization/roleAssignments/write' = @{ Priority = 'high'; Reason = 'RBAC role assignment - verify permissions' }
        'Microsoft.Authorization/roleAssignments/delete' = @{ Priority = 'high'; Reason = 'RBAC role removal - verify access control' }
    }
    
    # Check if Get-AzureActivityLogViaRestApi exists (from Get-AzureChangeTracking.ps1)
    if (-not (Get-Command -Name Get-AzureActivityLogViaRestApi -ErrorAction SilentlyContinue)) {
        Write-Verbose "Get-AzureActivityLogViaRestApi function not found. Loading from Get-AzureChangeTracking.ps1..."
        $collectorPath = Join-Path $PSScriptRoot "Get-AzureChangeTracking.ps1"
        if (Test-Path $collectorPath) {
            . $collectorPath
        }
        else {
            Write-Warning "Cannot load Get-AzureActivityLogViaRestApi. Security events will be skipped."
            return @()
        }
    }
    
    $startTime = (Get-Date).AddDays(-$Days)
    $endTime = Get-Date
    
    # Build OData filter for security operations (filter at API level for efficiency)
    # Azure Activity Log API supports filtering on operationName.value
    $operationFilters = @()
    foreach ($secOp in $securityOperations.Keys) {
        # Escape single quotes in operation name for OData
        $escapedOp = $secOp.Replace("'", "''")
        $operationFilters += "operationName.value eq '$escapedOp'"
    }
    $operationFilter = "($($operationFilters -join ' or '))"
    
    # Query each subscription with API-level filtering
    foreach ($subId in $SubscriptionIds) {
        try {
            Write-Verbose "Querying Activity Log for RBAC role assignment events in subscription $subId (filtered at API level)..."
            
            # Build OData filter with time, status, and operation filters
            $apiVersion = '2015-04-01'
            $timeFilter = "eventTimestamp ge '$($startTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"))' and eventTimestamp le '$($endTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"))'"
            $statusFilter = "status.value eq 'Succeeded'"
            $fullFilter = "$timeFilter and $statusFilter and $operationFilter"
            
            # URL encode filter
            $encodedFilter = [System.Uri]::EscapeDataString($fullFilter)
            $uri = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.Insights/eventtypes/management/values?api-version=$apiVersion&`$filter=$encodedFilter"
            
            Write-Verbose "Activity Log API filter: $fullFilter"
            
            # Fetch with pagination (should be much smaller now with filtering)
            $allLogs = [System.Collections.Generic.List[PSObject]]::new()
            $nextLink = $uri
            $pageCount = 0
            $maxPages = 50  # Much lower since we're filtering
            
            do {
                try {
                    $response = Invoke-AzRestMethod -Method GET -Uri $nextLink -ErrorAction Stop
                    
                    if ($response.StatusCode -eq 200 -and $response.Content) {
                        $responseData = $response.Content | ConvertFrom-Json
                        
                        if ($responseData.value) {
                            foreach ($item in $responseData.value) {
                                $allLogs.Add($item)
                            }
                            Write-Verbose "Retrieved $($responseData.value.Count) RBAC events (page $($pageCount + 1), total: $($allLogs.Count))"
                        }
                        
                        $nextLink = $responseData.nextLink
                        $pageCount++
                        
                        if ($pageCount -ge $maxPages) {
                            Write-Verbose "Reached maximum page limit ($maxPages). Stopping pagination."
                            break
                        }
                    }
                    else {
                        break
                    }
                }
                catch {
                    # If filter fails, try without operation filter (fallback)
                    if ($pageCount -eq 0) {
                        Write-Verbose "API filter failed, trying fallback with time/status only: $_"
                        $fallbackFilter = "$timeFilter and $statusFilter"
                        $encodedFallback = [System.Uri]::EscapeDataString($fallbackFilter)
                        $nextLink = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.Insights/eventtypes/management/values?api-version=$apiVersion&`$filter=$encodedFallback"
                        continue
                    }
                    else {
                        Write-Warning "Failed to fetch Activity Log page $($pageCount + 1) for subscription $subId : $_"
                        break
                    }
                }
            } while ($nextLink)
            
            Write-Verbose "Retrieved $($allLogs.Count) total Activity Log entries for RBAC filtering"
            
            if ($allLogs.Count -eq 0) {
                continue
            }
            
            # Filter for RBAC role assignment operations (double-check, but should already be filtered at API level)
            $filteredLogs = $allLogs | Where-Object {
                $opName = $null
                if ($_.Properties -and $_.Properties.OperationName) {
                    $opName = $_.Properties.OperationName
                }
                elseif ($_.Authorization -and $_.Authorization.Action) {
                    $opName = $_.Authorization.Action
                }
                elseif ($_.OperationName) {
                    if ($_.OperationName.Value) {
                        $opName = $_.OperationName.Value
                    }
                    else {
                        $opName = $_.OperationName
                    }
                }
                
                if ($opName) {
                    foreach ($secOp in $securityOperations.Keys) {
                        if ($opName -like "*$secOp*") {
                            return $true
                        }
                    }
                }
                return $false
            }
            
            Write-Verbose "Filtered to $($filteredLogs.Count) RBAC role assignment events"
            
            # Get subscription name (suppress warnings for other tenants)
            $sub = Invoke-WithSuppressedWarnings {
                Get-AzSubscription -SubscriptionId $subId -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            }
            $subscriptionName = if ($sub) { Get-SubscriptionDisplayName -Subscription $sub } else { $subId }
            
            # Convert to change objects
            foreach ($logEntry in $filteredLogs) {
                try {
                    # Get operation name
                    $opName = $null
                    if ($logEntry.Properties -and $logEntry.Properties.OperationName) {
                        $opName = $logEntry.Properties.OperationName
                    }
                    elseif ($logEntry.Authorization -and $logEntry.Authorization.Action) {
                        $opName = $logEntry.Authorization.Action
                    }
                    elseif ($logEntry.OperationName) {
                        if ($logEntry.OperationName.Value) {
                            $opName = $logEntry.OperationName.Value
                        }
                        else {
                            $opName = $logEntry.OperationName
                        }
                    }
                    
                    # Find matching security operation
                    $secOpInfo = $null
                    foreach ($secOp in $securityOperations.Keys) {
                        if ($opName -like "*$secOp*") {
                            $secOpInfo = $securityOperations[$secOp]
                            break
                        }
                    }
                    
                    if (-not $secOpInfo) {
                        continue
                    }
                    
                    # Get resource information
                    $resourceId = $null
                    if ($logEntry.ResourceId) {
                        $resourceId = $logEntry.ResourceId
                    }
                    elseif ($logEntry.ResourceIdValue) {
                        $resourceId = $logEntry.ResourceIdValue
                    }
                    elseif ($logEntry.Properties -and $logEntry.Properties.ResourceId) {
                        $resourceId = $logEntry.Properties.ResourceId
                    }
                    
                    $resourceType = $null
                    if ($logEntry.ResourceType) {
                        if ($logEntry.ResourceType.Value) {
                            $resourceType = $logEntry.ResourceType.Value
                        }
                        else {
                            $resourceType = $logEntry.ResourceType
                        }
                    }
                    
                    # Extract resource name and group from ResourceId
                    $resourceName = $null
                    $resourceGroup = $null
                    if ($resourceId) {
                        if ($resourceId -match '/resourceGroups/([^/]+)/') {
                            $resourceGroup = $matches[1]
                        }
                        if ($resourceId -match '/([^/]+)$') {
                            $resourceName = $matches[1]
                        }
                    }
                    
                    # Determine change type
                    $changeType = 'Update'
                    if ($opName -match '/delete$') {
                        $changeType = 'Delete'
                    }
                    elseif ($opName -match '/write$') {
                        $changeType = 'Create'
                        # Check status code for Create
                        if ($logEntry.Properties) {
                            $statusCode = $null
                            if ($logEntry.Properties.statusCode) {
                                $statusCode = $logEntry.Properties.statusCode
                            }
                            if ($statusCode -eq 'Created' -or $statusCode -eq 201 -or $statusCode -eq '201') {
                                $changeType = 'Create'
                            }
                        }
                    }
                    
                    # Get timestamp
                    $eventTimestamp = $null
                    if ($logEntry.EventTimestamp) {
                        $eventTimestamp = $logEntry.EventTimestamp
                    }
                    elseif ($logEntry.SubmissionTimestamp) {
                        $eventTimestamp = $logEntry.SubmissionTimestamp
                    }
                    else {
                        $eventTimestamp = Get-Date
                    }
                    
                    if ($eventTimestamp -isnot [DateTime]) {
                        try {
                            $eventTimestamp = [DateTime]$eventTimestamp
                        }
                        catch {
                            $eventTimestamp = Get-Date
                        }
                    }
                    
                    # Map resource category
                    $resourceCategory = Get-ResourceCategory -ResourceType $resourceType
                    
                    # Create security change object
                    $changeObj = [PSCustomObject]@{
                        ChangeTime          = $eventTimestamp
                        ChangeType          = $changeType
                        ResourceType        = $resourceType
                        ResourceCategory    = $resourceCategory
                        ResourceName        = if ($resourceName) { $resourceName } else { 'Unknown' }
                        ResourceGroup       = $resourceGroup
                        SubscriptionId      = $subId
                        SubscriptionName   = $subscriptionName
                        ResourceId          = $resourceId
                        ChangedProperties   = @()
                        ChangeSource        = 'ActivityLog'
                        SecurityFlag        = $secOpInfo.Priority
                        SecurityReason      = $secOpInfo.Reason
                    }
                    
                    $securityChanges.Add($changeObj)
                }
                catch {
                    Write-Verbose "Failed to process security log entry: $_"
                }
            }
        }
        catch {
            Write-Warning "Failed to query Activity Log for subscription $subId : $_"
        }
    }
    
    return @($securityChanges)
}



