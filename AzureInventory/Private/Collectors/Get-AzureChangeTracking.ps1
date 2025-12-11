<#
.SYNOPSIS
    Retrieves Azure Activity Log entries via REST API to avoid deprecated PowerShell cmdlet parameters.

.DESCRIPTION
    Uses Azure REST API to fetch Activity Log entries, avoiding the deprecated DetailedOutput
    parameter in Get-AzActivityLog. Provides better control and pagination support.

.PARAMETER SubscriptionId
    Azure subscription ID.

.PARAMETER StartTime
    Start time for the query.

.PARAMETER EndTime
    End time for the query.

.OUTPUTS
    Array of Activity Log entries.
#>
function Get-AzureActivityLogViaRestApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [DateTime]$StartTime,
        
        [Parameter(Mandatory = $true)]
        [DateTime]$EndTime
    )
    
    # Try REST API first using Invoke-AzRestMethod (handles auth automatically, gets more data)
    # Falls back to PowerShell cmdlet if REST API fails
    try {
        # Build REST API URL with optimized filtering
        # Azure Activity Log API supports OData filter syntax, but it's limited
        # We'll try filtering on status first to reduce data transfer
        # Use API version - Activity Log API is stable
        # Note: Activity Log API typically uses 2015-04-01 as the standard version
        # Newer versions may not be supported, so we start with the known working version
        $apiVersion = '2015-04-01'  # Standard version for Activity Log API
        
        # Base time filter
        $timeFilter = "eventTimestamp ge '$($StartTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"))' and eventTimestamp le '$($EndTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"))'"
        
        # Try filter with status - this should significantly reduce events
        # Azure API syntax: status/value eq 'Succeeded' (for nested properties)
        # If this fails, we'll fall back to time-only filter
        $statusFilter = "status/value eq 'Succeeded'"
        $filter = "$timeFilter and $statusFilter"
        
        # URL encode filter (PowerShell native method)
        $encodedFilter = [System.Uri]::EscapeDataString($filter)
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Insights/eventtypes/management/values?api-version=$apiVersion&`$filter=$encodedFilter"
        
        Write-Verbose "REST API filter (with status, API version $apiVersion): $filter"
        
        # Get Activity Log entries with pagination using Invoke-AzRestMethod
        # Limit pagination to avoid excessive API calls
        $maxEvents = 50000  # Increased significantly to handle noisy environments (e.g. Arc)
        $allLogs = [System.Collections.Generic.List[PSObject]]::new()
        $nextLink = $uri
        $pageCount = 0
        $maxPages = 500  # Increased to ensure we can dig through noise to find older events
        $hasRetriedWithSimpleFilter = $false
        
        do {
            Write-Verbose "Fetching Activity Log entries from REST API via Invoke-AzRestMethod (page $($pageCount + 1))..."
            
            if ($allLogs.Count -ge $maxEvents) {
                Write-Verbose "Reached maximum event limit ($maxEvents). Stopping pagination."
                break
            }
            
            try {
                $response = Invoke-AzRestMethod -Method GET -Uri $nextLink -ErrorAction Stop
            }
            catch {
                # If first request fails, try fallback approaches
                if ($pageCount -eq 0 -and -not $hasRetriedWithSimpleFilter) {
                    Write-Warning "First REST API request failed: $($_.Exception.Message)"
                    Write-Verbose "Trying fallback with simple time filter..."
                    
                    $hasRetriedWithSimpleFilter = $true
                    $simpleFilter = "eventTimestamp ge '$($StartTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"))' and eventTimestamp le '$($EndTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"))'"
                    $encodedSimpleFilter = [System.Uri]::EscapeDataString($simpleFilter)
                    $nextLink = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Insights/eventtypes/management/values?api-version=$apiVersion&`$filter=$encodedSimpleFilter"
                    
                    continue # Retry loop with new filter
                } else {
                    # Not first page or already retried, re-throw the error to outer catch
                    throw
                }
            }
            
            if ($response.StatusCode -eq 200 -and $response.Content) {
                $responseData = $response.Content | ConvertFrom-Json
                
                if ($responseData.value) {
                    # Convert array to list items (handle type conversion)
                    foreach ($item in $responseData.value) {
                        if ($allLogs.Count -ge $maxEvents) {
                            break
                        }
                        $allLogs.Add($item)
                    }
                    Write-Verbose "Retrieved $($responseData.value.Count) entries (total: $($allLogs.Count))"
                } else {
                    Write-Verbose "No 'value' property in response (empty result set)"
                }
                
                # Check for next page
                $nextLink = $responseData.nextLink
                $pageCount++
                
                if ($pageCount -ge $maxPages) {
                    Write-Verbose "Reached maximum page limit ($maxPages). Stopping pagination."
                    break
                }
            } elseif ($response.StatusCode -eq 400) {
                # Bad Request - filter or API version issue
                if ($pageCount -eq 0 -and -not $hasRetriedWithSimpleFilter) {
                    Write-Verbose "REST API returned 400 Bad Request with complex filter. Retrying with time-only filter..."
                    
                    $hasRetriedWithSimpleFilter = $true
                    $simpleFilter = "eventTimestamp ge '$($StartTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"))' and eventTimestamp le '$($EndTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"))'"
                    $encodedSimpleFilter = [System.Uri]::EscapeDataString($simpleFilter)
                    $nextLink = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Insights/eventtypes/management/values?api-version=$apiVersion&`$filter=$encodedSimpleFilter"
                    
                    continue # Retry loop with new filter
                }
                
                Write-Warning "REST API returned 400 Bad Request. Filter or API version may not be supported."
                Write-Verbose "URI was: $nextLink"
                if ($pageCount -eq 0) {
                    throw "REST API filter/version not supported (400 Bad Request)"
                } else {
                    break
                }
            } else {
                Write-Warning "Unexpected REST API response: StatusCode=$($response.StatusCode)"
                if ($response.Content) {
                    Write-Verbose "Response content: $($response.Content)"
                }
                if ($pageCount -eq 0) {
                    throw "REST API returned unexpected status code: $($response.StatusCode)"
                } else {
                    break
                }
            }
        } while ($nextLink)
        
        Write-Verbose "Total Activity Log entries retrieved via REST API: $($allLogs.Count)"
        return $allLogs
    }
    catch {
        # REST API failed - fall back to PowerShell cmdlet
        Write-Warning "REST API failed: $($_.Exception.Message). Using PowerShell cmdlet instead."
        
        # Fallback to PowerShell cmdlet (limited to 1000 events, suppresses deprecation warning)
        try {
            $allLogs = Get-AzActivityLog -StartTime $StartTime -EndTime $EndTime -WarningAction SilentlyContinue -ErrorAction Stop
            Write-Verbose "Retrieved $($allLogs.Count) entries via PowerShell cmdlet"
            return $allLogs
        }
        catch {
            Write-Warning "PowerShell cmdlet also failed: $($_.Exception.Message)"
            return @()  # Return empty array if both methods fail
        }
    }
}

<#
.SYNOPSIS
    Collects Azure Activity Log changes for a subscription.

.DESCRIPTION
    Retrieves Activity Log entries for the last 30 days, filtering for write/delete/action
    operations with Succeeded status. Categorizes changes by type and resource category,
    and flags security-sensitive operations.

.PARAMETER SubscriptionId
    Azure subscription ID to scan.

.PARAMETER SubscriptionName
    Human-readable subscription name.

.OUTPUTS
    Array of change tracking objects with complete metadata.
#>
function Get-AzureChangeTracking {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionName
    )
    
    $changes = [System.Collections.Generic.List[PSObject]]::new()
    
    try {
        Write-Host "  Retrieving Activity Log changes for $SubscriptionName..." -ForegroundColor Cyan
        
        # Calculate time range (last 30 days, fixed)
        $startTime = (Get-Date).AddDays(-30)
        $endTime = Get-Date
        
        # Get Activity Log entries using REST API to avoid deprecated DetailedOutput parameter
        # REST API provides better control and pagination support
        $activityLogs = $null
        try {
            # Use REST API instead of Get-AzActivityLog to avoid deprecated DetailedOutput warning
            # and get better control over data retrieval
            Write-Verbose "Attempting to retrieve Activity Log via REST API..."
            $allLogs = Get-AzureActivityLogViaRestApi -SubscriptionId $SubscriptionId -StartTime $startTime -EndTime $endTime -ErrorAction Stop
            
            if ($null -eq $allLogs) {
                Write-Warning "REST API returned null. Falling back to PowerShell cmdlet."
                throw "REST API returned null"
            }
            
            # Ensure $allLogs is iterable even if empty
            if ($allLogs.Count -eq 0) {
                Write-Verbose "REST API returned 0 results."
            } else {
                Write-Verbose "Retrieved $($allLogs.Count) total Activity Log entries from REST API"
            }
            
            # Filter for relevant operations
            $activityLogs = $allLogs | Where-Object {
                # Check EventCategory first (Health, Incident, ResourceHealth, and ServiceHealth are always included)
                $eventCategory = if ($_.EventCategory) {
                    if ($_.EventCategory.Value) { $_.EventCategory.Value } else { $_.EventCategory }
                } elseif ($_.Category) {
                    if ($_.Category.Value) { $_.Category.Value } else { $_.Category }
                } else { $null }
                
                # Include Health, Incident, ResourceHealth, and ServiceHealth events regardless of operation name or status
                if ($eventCategory -in @('Health', 'Incident', 'ResourceHealth', 'ServiceHealth')) {
                    return $true
                }
                
                # Check status (handle both object and string formats)
                $status = if ($_.Status) { 
                    if ($_.Status.Value) { $_.Status.Value } else { $_.Status } 
                } elseif ($_.Properties -and $_.Properties.Status) {
                    $_.Properties.Status
                } else { $null }
                
                # Only accept Succeeded status for regular operations (user confirmed Started can be skipped)
                if ($status -ne 'Succeeded') { return $false }
                
                # Get OperationName early to check for security-sensitive operations
                # Priority: Properties.OperationName > Authorization.Action > OperationName.Value > OperationName
                # Get-AzActivityLog returns localized text in OperationName, so we need to check Properties or Authorization
                $opName = $null
                if ($_.Properties -and $_.Properties.OperationName) {
                    $opName = $_.Properties.OperationName
                } elseif ($_.Authorization -and $_.Authorization.Action) {
                    $opName = $_.Authorization.Action
                } elseif ($_.OperationName) {
                    if ($_.OperationName.Value) {
                        $opName = $_.OperationName.Value
                    } else {
                        $opName = $_.OperationName
                    }
                }
                
                # Security-sensitive operations should always be included (even if they might be filtered as noise)
                $securitySensitivePatterns = @(
                    'Microsoft.Authorization/roleAssignments',         # Role assignments (high security)
                    'Microsoft.Network/networkSecurityGroups/securityRules', # NSG rules (high security)
                    'Microsoft.KeyVault/vaults/accessPolicies',       # Key Vault access (high security)
                    'Microsoft.KeyVault/vaults/secrets',              # Key Vault secrets (high security)
                    'Microsoft.Network/publicIPAddresses',            # Public IPs (high security)
                    'Microsoft.Authorization/policyExemptions',       # Policy exemptions (medium security)
                    'Microsoft.Management/managementGroups',          # Management groups (medium security)
                    'Microsoft.Insights/diagnosticSettings'           # Diagnostic settings (medium security)
                )
                
                $isSecuritySensitive = $false
                if ($opName) {
                    foreach ($pattern in $securitySensitivePatterns) {
                        if ($opName -match [regex]::Escape($pattern)) {
                            $isSecuritySensitive = $true
                            break
                        }
                    }
                }
                
                # If it's a security-sensitive operation, include it regardless of other filters
                if ($isSecuritySensitive) {
                    return $true
                }
                
                # Must have OperationName
                if (-not $opName) { return $false }
                
                # Include write, delete, action operations
                # Exclude read, list, get, show operations (even if they end with /action)
                if ($opName -notmatch '/(write|delete|action)$' -or 
                    $opName -match '/(read|list|get|show)$') {
                    return $false
                }
                
                # Filter out read-like action operations (these are not actual changes, just data retrieval)
                $readLikeActionPatterns = @(
                    '/listLogSasUrl/action',      # Get log URL (read operation)
                    '/listKeys/action',           # List keys (read operation)
                    '/listSecrets/action',        # List secrets (read operation)
                    '/listCredentials/action',   # List credentials (read operation)
                    '/listConnectionStrings/action', # List connection strings (read operation)
                    '/listAuthKeys/action',       # List auth keys (read operation)
                    '/getAccessToken/action',     # Get access token (read operation)
                    '/getStatus/action',          # Get status (read operation)
                    '/getProperties/action',      # Get properties (read operation)
                    '/show/action',              # Show (read operation)
                    '/read/action'               # Read (read operation)
                )
                
                foreach ($pattern in $readLikeActionPatterns) {
                    if ($opName -match [regex]::Escape($pattern)) {
                        Write-Verbose "Filtering out read-like action operation: $opName"
                        return $false
                    }
                }
                
                # Filter out noise operations (frequent but less meaningful changes)
                # BUT: Don't filter security-sensitive operations (already handled above)
                $noisePatterns = @(
                    'Microsoft.Resources/deployments/write',           # Deployment operations (often automated)
                    'Microsoft.Resources/subscriptions/resourceGroups/deployments/write',  # Resource group deployments
                    'Microsoft.Resources/tags/write',                  # Tag changes (often automated)
                    'Microsoft.Insights/components/ProactiveDetectionConfigurations/write', # Auto-detection configs
                    'Microsoft.Insights/alertRules/write',             # Alert rule updates (can be frequent)
                    'Microsoft.Insights/metricAlerts/write',           # Metric alert updates
                    'Microsoft.AzureArcData/*',                        # Filter ALL Azure Arc Data operations
                    'Microsoft.HybridCompute/*'                        # Filter ALL Azure Arc Machine operations
                )
                
                foreach ($pattern in $noisePatterns) {
                    if ($opName -like $pattern) {
                        Write-Verbose "Filtering out noise operation: $opName"
                        return $false
                    }
                }
                
                return $true
            }
            
            Write-Host "    Found $($activityLogs.Count) relevant activity log entries (from $($allLogs.Count) total)" -ForegroundColor Green
            
            # Debug: Show sample of filtered out operations if no results found
            if ($allLogs.Count -gt 0 -and $activityLogs.Count -eq 0) {
                Write-Host "    DEBUG: No matching events found. Analyzing first 3 events..." -ForegroundColor Yellow
                $allLogs | Select-Object -First 3 | ForEach-Object {
                    Write-Host "      Event properties:" -ForegroundColor Gray
                    Write-Host "        OperationName: $($_.OperationName | ConvertTo-Json -Compress)" -ForegroundColor DarkGray
                    Write-Host "        Status: $($_.Status | ConvertTo-Json -Compress)" -ForegroundColor DarkGray
                    Write-Host "        Category: $($_.Category | ConvertTo-Json -Compress)" -ForegroundColor DarkGray
                    Write-Host "        EventCategory: $($_.EventCategory | ConvertTo-Json -Compress)" -ForegroundColor DarkGray
                    Write-Host "        Authorization.Action: $($_.Authorization.Action | ConvertTo-Json -Compress)" -ForegroundColor DarkGray
                    Write-Host "        Properties.OperationName: $($_.Properties.OperationName | ConvertTo-Json -Compress)" -ForegroundColor DarkGray
                    Write-Host "        ResourceType: $($_.ResourceType | ConvertTo-Json -Compress)" -ForegroundColor DarkGray
                    Write-Host ""
                }
            }
            
            # Debug: Check for ResourceHealth events in all logs
            $resourceHealthCount = 0
            $healthCount = 0
            $incidentCount = 0
            $allLogs | ForEach-Object {
                $cat = if ($_.EventCategory) {
                    if ($_.EventCategory.Value) { $_.EventCategory.Value } else { $_.EventCategory }
                } elseif ($_.Category) {
                    if ($_.Category.Value) { $_.Category.Value } else { $_.Category }
                } else { $null }
                if ($cat -eq 'ResourceHealth') {
                    $resourceHealthCount++
                }
                elseif ($cat -eq 'Health') {
                    $healthCount++
                }
                elseif ($cat -eq 'Incident') {
                    $incidentCount++
                }
            }
            if ($resourceHealthCount -gt 0 -or $healthCount -gt 0 -or $incidentCount -gt 0) {
                Write-Host "    Found in total logs: $resourceHealthCount ResourceHealth, $healthCount Health, $incidentCount Incident events" -ForegroundColor Cyan
                $filteredResourceHealth = ($activityLogs | Where-Object {
                    $cat = if ($_.EventCategory) {
                        if ($_.EventCategory.Value) { $_.EventCategory.Value } else { $_.EventCategory }
                    } elseif ($_.Category) {
                        if ($_.Category.Value) { $_.Category.Value } else { $_.Category }
                    } else { $null }
                    $cat -eq 'ResourceHealth'
                }).Count
                $filteredHealth = ($activityLogs | Where-Object {
                    $cat = if ($_.EventCategory) {
                        if ($_.EventCategory.Value) { $_.EventCategory.Value } else { $_.EventCategory }
                    } elseif ($_.Category) {
                        if ($_.Category.Value) { $_.Category.Value } else { $_.Category }
                    } else { $null }
                    $cat -eq 'Health'
                }).Count
                $filteredIncident = ($activityLogs | Where-Object {
                    $cat = if ($_.EventCategory) {
                        if ($_.EventCategory.Value) { $_.EventCategory.Value } else { $_.EventCategory }
                    } elseif ($_.Category) {
                        if ($_.Category.Value) { $_.Category.Value } else { $_.Category }
                    } else { $null }
                    $cat -eq 'Incident'
                }).Count
                Write-Host "    After filtering: $filteredResourceHealth ResourceHealth, $filteredHealth Health, $filteredIncident Incident events" -ForegroundColor $(if ($filteredResourceHealth -gt 0 -or $filteredHealth -gt 0 -or $filteredIncident -gt 0) { 'Green' } else { 'Yellow' })
            }
        }
        catch {
            Write-Warning "Failed to retrieve Activity Log for $SubscriptionName : $_"
            return $changes
        }
        
        if ($null -eq $activityLogs -or $activityLogs.Count -eq 0) {
            Write-Host "    No changes found" -ForegroundColor Yellow
            return @()
        }
        
        # Resource category mapping
        $resourceCategoryMap = @{
            'Microsoft.Compute/virtualMachines' = 'Compute'
            'Microsoft.Compute/virtualMachineScaleSets' = 'Compute'
            'Microsoft.Compute/availabilitySets' = 'Compute'
            'Microsoft.Compute/disks' = 'Storage'
            'Microsoft.Storage/storageAccounts' = 'Storage'
            'Microsoft.Network/virtualNetworks' = 'Networking'
            'Microsoft.Network/networkSecurityGroups' = 'Networking'
            'Microsoft.Network/publicIPAddresses' = 'Networking'
            'Microsoft.Network/loadBalancers' = 'Networking'
            'Microsoft.Network/dnszones' = 'Networking'  # Added DNS Zones
            'Microsoft.Sql/servers' = 'Databases'
            'Microsoft.Sql/servers/firewallRules' = 'Databases'  # Sub-resource
            'Microsoft.Sql/databases' = 'Databases'
            'Microsoft.DocumentDB/databaseAccounts' = 'Databases'
            'Microsoft.Cache/redis' = 'Databases'
            'Microsoft.Authorization/roleAssignments' = 'Identity'
            'Microsoft.ManagedIdentity/userAssignedIdentities' = 'Identity'
            'Microsoft.KeyVault/vaults' = 'Security'
            'Microsoft.KeyVault/vaults/secrets' = 'Security'
            'Microsoft.Authorization/policyAssignments' = 'Security'
            'Microsoft.ContainerRegistry/registries' = 'Containers'
            'Microsoft.ContainerService/managedClusters' = 'Containers'
            'Microsoft.Web/sites' = 'Web'
            'Microsoft.Web/serverFarms' = 'Web'
        }
        
        # Security flagging rules
        $highPriorityPatterns = @(
            'Microsoft.Authorization/roleAssignments/write',
            'Microsoft.Authorization/roleAssignments/delete', # Role assignment removal (high security)
            'Microsoft.Network/networkSecurityGroups/securityRules/write',
            'Microsoft.KeyVault/vaults/accessPolicies/write',
            'Microsoft.KeyVault/vaults/secrets/delete',
            'Microsoft.Network/publicIPAddresses/write'
        )
        
        $mediumPriorityPatterns = @(
            'Microsoft.Authorization/policyExemptions/write',
            'Microsoft.Management/managementGroups/write',
            'Microsoft.Insights/diagnosticSettings/delete'
        )
        
        # Process each activity log entry
        $processedCount = 0
        $skippedCount = 0
        foreach ($logEntry in $activityLogs) {
            try {
                # Get EventCategory (Health and Incident events)
                $eventCategory = $null
                if ($logEntry.EventCategory) {
                    if ($logEntry.EventCategory.Value) {
                        $eventCategory = $logEntry.EventCategory.Value
                    } else {
                        $eventCategory = $logEntry.EventCategory
                    }
                } elseif ($logEntry.Category) {
                    if ($logEntry.Category.Value) {
                        $eventCategory = $logEntry.Category.Value
                    } else {
                        $eventCategory = $logEntry.Category
                    }
                }
                
                # Get OperationName (handle both object and string formats)
                # Priority: Properties.OperationName > Authorization.Action > OperationName.Value > OperationName
                # Get-AzActivityLog returns localized text in OperationName, so we need to check Properties or Authorization
                $operationName = $null
                $operationNameLocalized = $null
                
                if ($logEntry.Properties -and $logEntry.Properties.OperationName) {
                    $operationName = $logEntry.Properties.OperationName
                } elseif ($logEntry.Authorization -and $logEntry.Authorization.Action) {
                    $operationName = $logEntry.Authorization.Action
                } elseif ($logEntry.OperationName) {
                    if ($logEntry.OperationName.Value) {
                        $operationName = $logEntry.OperationName.Value
                        if ($logEntry.OperationName.localizedValue) {
                            $operationNameLocalized = $logEntry.OperationName.localizedValue
                        }
                    } else {
                        $operationName = $logEntry.OperationName
                    }
                }
                
                # If we have a localized operation name, use it as title if no other title exists
                if ($operationNameLocalized -and -not $changeTitle) {
                    $changeTitle = $operationNameLocalized
                }
                
                # For Health, Incident, and ResourceHealth events, use EventCategory as OperationName if missing
                if (-not $operationName -and $eventCategory -in @('Health', 'Incident', 'ResourceHealth', 'ServiceHealth')) {
                    $operationName = "EventCategory/$eventCategory"
                }
                
                # Skip if OperationName is still missing
                if (-not $operationName) {
                    Write-Verbose "Skipping entry with no OperationName"
                    $skippedCount++
                    continue
                }
                
                # Determine operation type
                # For Health, Incident, and ResourceHealth events, use EventCategory as operation type
                $operationType = 'Modify'
                
                if ($eventCategory -in @('Health', 'Incident', 'ResourceHealth', 'ServiceHealth')) {
                    $operationType = $eventCategory
                }
                elseif ($operationName -match '/delete$') {
                    $operationType = 'Delete'
                }
                elseif ($operationName -match '/action$') {
                    $operationType = 'Action'
                }
                elseif ($logEntry.Properties) {
                    # Check statusCode in Properties (handle both object and hashtable formats)
                    # Create operations typically return HTTP 201 (Created) status code
                    $statusCode = $null
                    try {
                        # Try different ways to get statusCode from Properties
                        if ($logEntry.Properties.statusCode) {
                            $statusCode = $logEntry.Properties.statusCode
                        } elseif ($logEntry.Properties['statusCode']) {
                            $statusCode = $logEntry.Properties['statusCode']
                        } elseif ($logEntry.Properties.PSObject.Properties['statusCode']) {
                            $statusCode = $logEntry.Properties.PSObject.Properties['statusCode'].Value
                        }
                        
                        # Also check for HTTP status code in httpRequest
                        if (-not $statusCode -and $logEntry.Properties.httpRequest) {
                            if ($logEntry.Properties.httpRequest.statusCode) {
                                $statusCode = $logEntry.Properties.httpRequest.statusCode
                            }
                        }
                        
                        # Check in nested structure
                        if (-not $statusCode -and $logEntry.Properties['httpRequest']) {
                            if ($logEntry.Properties['httpRequest'].statusCode) {
                                $statusCode = $logEntry.Properties['httpRequest'].statusCode
                            }
                        }
                    }
                    catch {
                        Write-Verbose "Could not read statusCode from Properties: $_"
                    }
                    
                    # Determine if this is a Create operation
                    # Create operations return HTTP 201 (Created)
                    if ($statusCode -eq 'Created' -or $statusCode -eq 201 -or $statusCode -eq '201') {
                        $operationType = 'Create'
                        Write-Verbose "Identified Create operation: OperationName=$operationName, statusCode=$statusCode"
                    }
                }
                
                # Extract resource information
                # Try to get ResourceId from different properties
                $resourceId = $null
                if ($logEntry.ResourceId) {
                    $resourceId = $logEntry.ResourceId
                } elseif ($logEntry.ResourceIdValue) {
                    $resourceId = $logEntry.ResourceIdValue
                } elseif ($logEntry.Properties -and $logEntry.Properties.ResourceId) {
                    $resourceId = $logEntry.Properties.ResourceId
                }
                
                # Get ResourceType (handle both object and string formats)
                $resourceType = $null
                if ($logEntry.ResourceType) {
                    if ($logEntry.ResourceType.Value) {
                        $resourceType = $logEntry.ResourceType.Value
                    } else {
                        $resourceType = $logEntry.ResourceType
                    }
                }
                
                # Normalize ResourceType (convert to proper case: Microsoft.Sql/servers instead of MICROSOFT.SQL/servers)
                if ($resourceType) {
                    # Convert to lowercase first to ensure consistent casing input (ensure string)
                    $resourceType = "$resourceType".ToLower()
                    
                    # Split by / and normalize each part
                    $parts = $resourceType -split '/'
                    if ($parts.Count -ge 2) {
                        # Normalize provider name (Microsoft.Sql instead of microsoft.sql)
                        $providerParts = $parts[0] -split '\.'
                        $normalizedProvider = ($providerParts | ForEach-Object { 
                            if ($_.Length -gt 0) {
                                $_.Substring(0,1).ToUpper() + $_.Substring(1)
                            } else {
                                $_
                            }
                        }) -join '.'
                        # Reconstruct with all parts (handles sub-resources like firewallRules)
                        $resourceType = "$normalizedProvider/$($parts[1..($parts.Count-1)] -join '/')"
                    }
                }
                $resourceName = $null
                $resourceGroup = $null
                
                if ($resourceId) {
                    # Parse resource ID to extract name and resource group
                    if ($resourceId -match '/resourceGroups/([^/]+)/') {
                        $resourceGroup = $matches[1]
                    }
                    if ($resourceId -match '/([^/]+)$') {
                        $resourceName = $matches[1]
                    }
                }
                
                # If ResourceType is missing, try to extract from ResourceId or OperationName
                if (-not $resourceType) {
                    if ($resourceId -and $resourceId -match '/providers/([^/]+)/([^/]+)') {
                        $resourceType = "$($matches[1])/$($matches[2])"
                    } elseif ($operationName -match '^([^/]+/[^/]+)/') {
                        $resourceType = $matches[1]
                    }
                }
                
                # Special handling for sub-resources (like firewall rules) to show parent resource context if useful
                $parentResourceName = $null
                if ($resourceId -and $resourceType -match '/.*/.*') {
                    # Check if it's a sub-resource (more than 2 segments in type or ID implies nesting)
                    # Example ID: .../providers/Microsoft.Sql/servers/mpsqlserver/firewallRules/Micke mobil
                    
                    # Try to extract parent name for known sub-resource types
                    if ($resourceType -like 'Microsoft.Sql/servers/firewallRules') {
                        if ($resourceId -match '/servers/([^/]+)/firewallRules/') {
                            $parentResourceName = $matches[1]
                        }
                    }
                    elseif ($resourceType -like 'Microsoft.Web/sites/slots') {
                        if ($resourceId -match '/sites/([^/]+)/slots/') {
                            $parentResourceName = $matches[1]
                        }
                    }
                    elseif ($resourceType -like 'Microsoft.Network/networkSecurityGroups/securityRules') {
                        if ($resourceId -match '/networkSecurityGroups/([^/]+)/securityRules/') {
                            $parentResourceName = $matches[1]
                        }
                    }
                }
                
                if ($parentResourceName) {
                    # Append parent context to resource name for clarity
                    if ($resourceName) {
                        $resourceName = "$resourceName (on $parentResourceName)"
                    }
                }
                
                # Determine resource category
                $resourceCategory = 'Other'
                if ($resourceCategoryMap.ContainsKey($resourceType)) {
                    $resourceCategory = $resourceCategoryMap[$resourceType]
                }
                elseif ($resourceType) {
                    # Try partial match for sub-resources
                    foreach ($key in $resourceCategoryMap.Keys) {
                        if ($resourceType -like "$key/*") {
                            $resourceCategory = $resourceCategoryMap[$key]
                            break
                        }
                    }
                }
                
                # Extract additional details from Properties (Title, Details, Description)
                $changeTitle = $null
                $changeDescription = $null
                
                if ($logEntry.Properties) {
                    # Helper function to get property value case-insensitively
                    $GetPropValue = { param($props, $name)
                        if ($props.PSObject.Properties[$name]) { return $props.PSObject.Properties[$name].Value }
                        if ($props[$name]) { return $props[$name] }
                        if ($props.ContainsKey -and $props.ContainsKey($name)) { return $props[$name] }
                        return $null
                    }
                    
                    # Try to get Title
                    $title = & $GetPropValue $logEntry.Properties 'title'
                    if (-not $title) { $title = & $GetPropValue $logEntry.Properties 'Title' }
                    if ($title) { $changeTitle = $title }
                    
                    # Try to get Details/Description/Message
                    $details = & $GetPropValue $logEntry.Properties 'details'
                    if (-not $details) { $details = & $GetPropValue $logEntry.Properties 'Details' }
                    if (-not $details) { $details = & $GetPropValue $logEntry.Properties 'description' }
                    if (-not $details) { $details = & $GetPropValue $logEntry.Properties 'Description' }
                    if (-not $details) { $details = & $GetPropValue $logEntry.Properties 'message' }
                    if (-not $details) { $details = & $GetPropValue $logEntry.Properties 'Message' }
                    
                    if ($details) { $changeDescription = $details }
                }

                # Special Handling for Role Assignments (RBAC)
                if ($resourceType -eq 'Microsoft.Authorization/roleAssignments') {
                    # Built-in Role Definitions Lookup
                    $roleDefinitions = @{
                        'acdd72a7-3385-48ef-bd42-f606fba81ae7' = 'Reader'
                        'b24988ac-6180-42a0-ab88-20f7382dd24c' = 'Contributor'
                        '8e3af657-a8ff-443c-a75c-2fe8c4bcb635' = 'Owner'
                        '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9' = 'User Access Administrator'
                        'ba92f5b4-2d11-453d-a403-e96b0029c9fe' = 'Blob Storage Data Contributor'
                        '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1' = 'Storage Blob Data Reader'
                        '974c5e8b-45b9-4653-ba55-5f855dd0fb88' = 'Storage Blob Data Owner'
                    }

                    if ($operationType -eq 'Create' -or $operationName -match '/write$') {
                        $requestBody = $null
                        # Try case-insensitive property access for requestbody
                        if ($logEntry.Properties) {
                            $requestBodyJson = & $GetPropValue $logEntry.Properties 'requestbody'
                            if ($requestBodyJson) {
                                try {
                                    $requestBody = $requestBodyJson | ConvertFrom-Json
                                } catch {
                                    Write-Verbose "Failed to parse requestbody for RBAC assignment: $_"
                                }
                            }
                        }

                        if ($requestBody -and $requestBody.Properties) {
                            $props = $requestBody.Properties
                            
                            # Extract Role ID
                            $roleDefId = $props.RoleDefinitionId
                            if ($roleDefId -match '/roleDefinitions/([^/]+)$') {
                                $roleDefId = $matches[1]
                            }
                            
                            $roleName = if ($roleDefinitions.ContainsKey($roleDefId)) { $roleDefinitions[$roleDefId] } else { "Role ($roleDefId)" }
                            
                            # Extract Principal
                            $principalId = $props.PrincipalId
                            $principalType = $props.PrincipalType
                            
                            $changeTitle = "Assigned '$roleName'"
                            $changeDescription = "Assigned role '$roleName' to Principal '$principalId' ($principalType)"
                            
                            # Set Resource Name to something meaningful
                            $resourceName = "$roleName Assignment"
                        } else {
                            $changeTitle = "Role Assignment Created"
                            $changeDescription = "Details could not be parsed from requestbody"
                            $resourceName = "Role Assignment"
                        }
                    } elseif ($operationType -eq 'Delete' -or $operationName -match '/delete$') {
                        $changeTitle = "Removed Role Assignment"
                        $changeDescription = "A role assignment was removed (details not available in deletion log)"
                        $resourceName = "Role Assignment"
                    }
                }
                
                # Special Handling for Recovery Services (Backup)
                if ($resourceType -like 'Microsoft.RecoveryServices/*') {
                    if ($operationName -like '*/backup/action') {
                        $changeTitle = "Triggered Backup"
                        $resourceName = "Backup Job"
                        
                        # Try to extract protected item from ResourceId
                        if ($resourceId -match '/protectedItems/([^/]+)') {
                            # Format often contains container info like "VM;iaasvmcontainerv2;RG;VMName"
                            $rawItem = $matches[1]
                            # Try to extract the actual VM/Item name (last part after semicolon)
                            $parts = $rawItem -split ';'
                            if ($parts.Count -gt 0) {
                                $resourceName = $parts[-1]
                            } else {
                                $resourceName = $rawItem
                            }
                            $changeDescription = "Manual backup triggered for '$resourceName'"
                        } else {
                            $changeDescription = "Manual backup triggered on vault"
                        }
                    }
                    elseif ($operationName -like '*/restore/action') {
                        $changeTitle = "Triggered Restore"
                        $resourceName = "Restore Job"
                        $changeDescription = "Restore operation initiated"
                    }
                }
                
                # Determine caller type
                # Get Caller from different sources
                $caller = $null
                if ($logEntry.Caller) {
                    $caller = $logEntry.Caller
                } elseif ($logEntry.Properties -and $logEntry.Properties.Caller) {
                    $caller = $logEntry.Properties.Caller
                }
                
                $callerType = 'User'
                if ($caller) {
                    if ($caller -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
                        $callerType = 'ServicePrincipal'
                    }
                    elseif ($caller -match 'systemAssignedIdentity|userAssignedIdentity') {
                        $callerType = 'ManagedIdentity'
                    }
                }
                
                # Check security flags
                $securityFlag = $null
                $securityReason = $null
                
                foreach ($pattern in $highPriorityPatterns) {
                    if ($operationName -like "*$pattern*") {
                        $securityFlag = 'high'
                        if ($operationName -like '*roleAssignments*') {
                            $securityReason = 'RBAC role assignment - verify permissions'
                        }
                        elseif ($operationName -like '*networkSecurityGroups*') {
                            $securityReason = 'NSG rule change - verify inbound rules'
                        }
                        elseif ($operationName -like '*KeyVault*') {
                            $securityReason = 'Key Vault access policy or secret change'
                        }
                        elseif ($operationName -like '*publicIPAddresses*') {
                            $securityReason = 'Public IP address created - verify exposure'
                        }
                        break
                    }
                }
                
                if (-not $securityFlag) {
                    foreach ($pattern in $mediumPriorityPatterns) {
                        if ($operationName -like "*$pattern*") {
                            $securityFlag = 'medium'
                            if ($operationName -like '*policyExemptions*') {
                                $securityReason = 'Policy exemption created - verify compliance'
                            }
                            elseif ($operationName -like '*managementGroups*') {
                                $securityReason = 'Management group change - verify governance'
                            }
                            elseif ($operationName -like '*diagnosticSettings*') {
                                $securityReason = 'Diagnostic settings deleted - verify logging'
                            }
                            break
                        }
                    }
                }
                
                # Create change object - ensure we have at least basic info
                if (-not $resourceName -and $resourceId) {
                    # Try to extract name from ResourceId if not found earlier
                    if ($resourceId -match '/([^/]+)$') {
                        $resourceName = $matches[1]
                    }
                }
                
                # Use OperationName as fallback for ResourceName if still missing
                if (-not $resourceName) {
                    # Try to extract from OperationName (e.g., "Microsoft.Sql/servers/write" -> "servers")
                    if ($operationName -match '/([^/]+)/(write|delete|action)$') {
                        $resourceName = "Unknown ($($matches[1]))"
                    } else {
                        $resourceName = "Unknown"
                    }
                }
                
                # Ensure we have a ResourceType
                if (-not $resourceType) {
                    # Try to extract from OperationName
                    if ($operationName -match '^([^/]+/[^/]+)/') {
                        $resourceType = $matches[1]
                    } else {
                        $resourceType = "Unknown"
                    }
                }
                
                # Get EventTimestamp (handle different formats)
                $eventTimestamp = $null
                if ($logEntry.EventTimestamp) {
                    $eventTimestamp = $logEntry.EventTimestamp
                } elseif ($logEntry.SubmissionTimestamp) {
                    $eventTimestamp = $logEntry.SubmissionTimestamp
                } else {
                    $eventTimestamp = Get-Date
                }
                
                # Convert to DateTime if needed
                if ($eventTimestamp -isnot [DateTime]) {
                    try {
                        $eventTimestamp = [DateTime]$eventTimestamp
                    } catch {
                        $eventTimestamp = Get-Date
                    }
                }
                
                # Create change object
                $changeObj = [PSCustomObject]@{
                    Timestamp        = $eventTimestamp
                    OperationType    = $operationType
                    ResourceType     = $resourceType
                    ResourceCategory = $resourceCategory
                    ResourceName     = $resourceName
                    ResourceGroup    = $resourceGroup
                    SubscriptionId   = $SubscriptionId
                    SubscriptionName = $SubscriptionName
                    Caller           = $caller
                    CallerType       = $callerType
                    OperationName    = $operationName
                    EventCategory    = $eventCategory
                    SecurityFlag     = $securityFlag
                    SecurityReason   = $securityReason
                    ResourceId       = $resourceId
                    ChangeTitle      = $changeTitle
                    ChangeDescription = $changeDescription
                }
                
                $changes.Add($changeObj)
                $processedCount++
            }
            catch {
                $skippedCount++
                Write-Warning "Failed to process activity log entry: $_"
                Write-Verbose "Entry details: OperationName=$($logEntry.OperationName), ResourceId=$($logEntry.ResourceId), Error=$($_.Exception.Message)"
                Write-Verbose "Stack Trace: $($_.ScriptStackTrace)"
                if ($_.Exception) {
                    Write-Verbose "Exception: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
                    if ($_.Exception.InnerException) {
                        Write-Verbose "Inner Exception: $($_.Exception.InnerException.Message)"
                    }
                }
            }
        }
        
        if ($skippedCount -gt 0) {
            Write-Host "    Processed $processedCount changes, skipped $skippedCount entries" -ForegroundColor $(if ($processedCount -gt 0) { 'Green' } else { 'Yellow' })
        } else {
            Write-Host "    Processed $($changes.Count) changes" -ForegroundColor Green
        }
        
        Write-Verbose "Returning $($changes.Count) changes (List count: $($changes.Count))"
    }
    catch {
        Write-Warning "Failed to retrieve change tracking data for $SubscriptionName : $_"
    }
    
    # Return as array (not List) to match pattern from Get-AzureAdvisorRecommendations
    $result = @($changes)
    Write-Verbose "Final return: Array count = $($result.Count), Type = $($result.GetType().FullName)"
    return $result
}

