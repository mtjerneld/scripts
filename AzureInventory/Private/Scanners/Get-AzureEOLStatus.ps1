<#
.SYNOPSIS
    Scans Azure resources for End-of-Life (EOL) / deprecated services using Microsoft's official EOL data.

.DESCRIPTION
    Uses Microsoft's official resource_list.kql query and service_list.json from Azure/EOL GitHub repository
    to identify EOL resources across subscriptions. Automatically downloads and caches data with fallback
    to bundled copies.

    Resultatet används för EOL-sektionen i Security-rapporten.

.PARAMETER SubscriptionIds
    List of subscription IDs to scan.

.PARAMETER ForceRefresh
    Force refresh of cached EOL data from GitHub.

.OUTPUTS
    Array of PSCustomObject:
        Component, ResourceType, Status, Deadline, DaysUntilDeadline, Severity,
        AffectedResourceCount, AffectedResources (array),
        ActionRequired, MigrationGuide
#>
function Get-AzureEOLStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$SubscriptionIds,

        [switch]$ForceRefresh
    )

    # Check for Az.ResourceGraph module
    if (-not (Get-Module -ListAvailable -Name Az.ResourceGraph)) {
        Write-Warning "Az.ResourceGraph module is not available. EOL tracking will be skipped."
        return @()
    }

    Import-Module Az.ResourceGraph -ErrorAction SilentlyContinue | Out-Null

    # Get Microsoft EOL data (with caching and fallback)
    $eolData = Get-MicrosoftEOLData -ForceRefresh:$ForceRefresh
    if (-not $eolData) {
        Write-Warning "Failed to load Microsoft EOL data. EOL tracking will be skipped."
        return @()
    }

    Write-Verbose "Using EOL data from: $($eolData.Source)"

    $serviceList = $eolData.ServiceList
    $kqlQuery = $eolData.ResourceListKQL

    if (-not $serviceList -or $serviceList.Count -eq 0) {
        Write-Warning "EOL service list is empty or missing"
        return @()
    }

    if ([string]::IsNullOrWhiteSpace($kqlQuery)) {
        Write-Warning "EOL KQL query is empty or missing"
        return @()
    }

    Write-Verbose "Loaded $($serviceList.Count) EOL service definitions from service_list.json"
    Write-Verbose "KQL query length: $($kqlQuery.Length) characters"

    # Create a lookup dictionary for ServiceID -> ServiceInfo
    # IMPORTANT: Always use [int] for keys to ensure type consistency (JSON may have mixed string/int Ids)
    $serviceLookup = @{}
    $loadedCount = 0
    $skippedCount = 0
    foreach ($service in $serviceList) {
        $serviceId = $null
        try {
            # Convert Id to int regardless of original type (JSON may have "328" as string or 593 as int)
            if ($null -eq $service.Id) {
                Write-Verbose "Skipping service with null Id"
                $skippedCount++
                continue
            }
            
            # Try to convert to int - handle both string and numeric types
            $serviceId = [int]$service.Id
            
            if ($serviceId -gt 0) {
                # Always use int as key type for consistency
                $serviceLookup[[int]$serviceId] = $service
                $loadedCount++
            } else {
                Write-Verbose "Skipping service with Id <= 0: $serviceId"
                $skippedCount++
            }
        }
        catch {
            Write-Verbose "Error processing service Id '$($service.Id)' (type: $($service.Id.GetType().Name)): $_"
            $skippedCount++
        }
    }

    Write-Verbose "Loaded $loadedCount EOL service definitions (skipped $skippedCount)"
    $sampleIds = $serviceLookup.Keys | Sort-Object | Select-Object -First 10
    Write-Verbose "Sample ServiceIDs in lookup: $($sampleIds -join ', ')..."
    
    # Debug: Check if specific ServiceIDs are in the lookup
    $testServiceIds = @(503, 345, 43507, 83, 14)
    foreach ($testId in $testServiceIds) {
        if ($serviceLookup.ContainsKey([int]$testId)) {
            Write-Verbose "ServiceID $testId found in lookup: $($serviceLookup[[int]$testId].ServiceName)"
        } else {
            Write-Verbose "ServiceID $testId NOT found in lookup"
        }
    }

    # Use Search-AzGraph's -Subscription parameter instead of modifying the KQL query
    # This is cleaner and more reliable than injecting subscription filters into the query
    Write-Verbose "KQL query (first 500 chars): $($kqlQuery.Substring(0, [Math]::Min(500, $kqlQuery.Length)))"
    
    # Check if we have Resource Graph access
    try {
        Write-Verbose "Checking Resource Graph module availability..."
        $rgModule = Get-Module -Name Az.ResourceGraph -ListAvailable
        if (-not $rgModule) {
            Write-Warning "Az.ResourceGraph module is not installed. Install it with: Install-Module Az.ResourceGraph"
            return @()
        }
        Write-Verbose "Resource Graph module found: $($rgModule.Version)"
    }
    catch {
        Write-Warning "Failed to check Resource Graph module: $_"
    }
    
    $queryStartTime = Get-Date
    try {
        # Use -Subscription parameter to filter by subscriptions (cleaner than modifying KQL)
        Write-Verbose "Calling Search-AzGraph with query length: $($kqlQuery.Length) characters"
        $queryResult = Search-AzGraph -Query $kqlQuery -Subscription $SubscriptionIds -ErrorAction Stop
        $queryDuration = (Get-Date) - $queryStartTime
        Write-Verbose "Found $($queryResult.Count) resource(s) with EOL components"
        if ($queryResult.Count -gt 0) {
            Write-Verbose "First result sample: $($queryResult[0] | ConvertTo-Json -Depth 2 -Compress)"
        }
    }
    catch {
        $queryDuration = (Get-Date) - $queryStartTime
        Write-Warning "Resource Graph query failed after $([math]::Round($queryDuration.TotalSeconds, 2)) seconds: $_"
        Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) {
            Write-Host "Inner exception: $($_.Exception.InnerException.Message)" -ForegroundColor Red
        }
        Write-Host "  Troubleshooting:" -ForegroundColor Yellow
        Write-Host "  - Ensure you have 'Reader' role on the subscriptions" -ForegroundColor Yellow
        Write-Host "  - Check that Resource Graph queries are enabled for your tenant" -ForegroundColor Yellow
        Write-Verbose "  - Subscription IDs: $($SubscriptionIds -join ', ')"
        return @()
    }

    if (-not $queryResult -or $queryResult.Count -eq 0) {
        Write-Host "No EOL resources found in selected subscriptions" -ForegroundColor Yellow
        Write-Host "  This could mean:" -ForegroundColor Yellow
        Write-Host "  - No deprecated resources exist in these subscriptions" -ForegroundColor Yellow
        Write-Host "  - The EOL data doesn't cover resources in these subscriptions" -ForegroundColor Yellow
        Write-Host "  - Resource Graph query permissions may be insufficient" -ForegroundColor Yellow
        return @()
    }

    # Group results by ServiceID
    $resultsByServiceId = @{}
    foreach ($res in $queryResult) {
        $serviceId = $null
        if ($res.ServiceID -is [string]) {
            try {
                $serviceId = [int]$res.ServiceID
            }
            catch {
                Write-Verbose "Invalid ServiceID format: $($res.ServiceID)"
                continue
            }
        }
        else {
            $serviceId = $res.ServiceID
        }

        if ($null -eq $serviceId -or $serviceId -le 0) {
            continue
        }

        if (-not $resultsByServiceId.ContainsKey($serviceId)) {
            $resultsByServiceId[$serviceId] = [System.Collections.Generic.List[pscustomobject]]::new()
        }

        $resultsByServiceId[$serviceId].Add($res)
    }

    Write-Verbose "Grouped results into $($resultsByServiceId.Keys.Count) unique ServiceIDs"
    
    # Diagnostic: Show which ServiceIDs were found vs which are in service_list.json
    $foundServiceIds = $resultsByServiceId.Keys | Sort-Object
    $availableServiceIds = $serviceLookup.Keys | Sort-Object
    $missingServiceIds = $foundServiceIds | Where-Object { -not $availableServiceIds.Contains($_) }
    
    if ($missingServiceIds.Count -gt 0) {
        Write-Host "  WARNING: Found $($missingServiceIds.Count) ServiceID(s) in Resource Graph that are not in service_list.json:" -ForegroundColor Yellow
        Write-Host "    Missing ServiceIDs: $($missingServiceIds -join ', ')" -ForegroundColor Yellow
        Write-Host "    This usually means service_list.json is outdated. Try: Get-AzureEOLStatus -SubscriptionIds @('...') -ForceRefresh" -ForegroundColor Yellow
        Write-Host "    Or manually refresh EOL data cache" -ForegroundColor Yellow
    }

    # Convert to our output format
    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($serviceIdKey in $resultsByServiceId.Keys) {
        $affectedResources = $resultsByServiceId[$serviceIdKey]
        
        # Ensure serviceId is an integer for lookup (hashtable keys must match type exactly)
        $serviceId = [int]$serviceIdKey
        
        # Get service info from lookup
        $serviceInfo = $null
        $useFallback = $false
        
        # Use ContainsKey with int key (hashtable keys are type-sensitive)
        if (-not $serviceLookup.ContainsKey([int]$serviceId)) {
            Write-Verbose "ServiceID $serviceId (type: $($serviceId.GetType().Name)) not found in service_list.json, using fallback metadata"
            $sampleKeys = $serviceLookup.Keys | Select-Object -First 5 | ForEach-Object { "$_($($_.GetType().Name))" }
            Write-Verbose "  Available ServiceID types in lookup: $($sampleKeys -join ', ')"
            Write-Host "  ServiceID $serviceId ($($affectedResources.Count) resource(s)) not in service_list.json - using fallback" -ForegroundColor Yellow
            
            # Create fallback service info from resource metadata
            $useFallback = $true
            $firstResource = $affectedResources[0]
            $resourceTypeName = if ($firstResource.type) { 
                $firstResource.type -replace '.*/', '' 
            } else { 
                "Unknown Resource" 
            }
            
            # Determine component name from resource type
            $componentName = switch -Wildcard ($firstResource.type) {
                "*compute/disks*" { "Standard LRS Disks (Deprecated)" }
                "*compute/virtualmachines*" { "Legacy VM Sizes (Deprecated)" }
                "*web/sites*" { "Deprecated App Service Configuration" }
                "*storage/storageaccounts*" { "Storage Accounts with TLS 1.0/1.1" }
                default { "$resourceTypeName (Deprecated)" }
            }
            
            $serviceInfo = [PSCustomObject]@{
                ServiceName = $componentName
                RetiringFeature = ""
                RetirementDate = ""  # Unknown - will be set to a far future date
                Link = "https://github.com/Azure/EOL"
                Id = $serviceId
            }
        } else {
            # Lookup using int key (hashtable keys are type-sensitive)
            $serviceInfo = $serviceLookup[[int]$serviceId]
        }
        
        # Build component name
        $component = if ($serviceInfo.RetiringFeature) {
            "$($serviceInfo.ServiceName) - $($serviceInfo.RetiringFeature)"
        } else {
            $serviceInfo.ServiceName
        }

        # Parse retirement date
        $deadlineDate = $null
        $daysUntil = $null
        $deadlineStr = $serviceInfo.RetirementDate

        if ([string]::IsNullOrWhiteSpace($deadlineStr)) {
            if ($useFallback) {
                # For fallback entries, use "TBD" (To Be Determined) since we don't have actual dates
                # The report will handle "TBD" as a special case
                $deadlineStr = "TBD"
                $deadlineDate = $null
                $daysUntil = $null
            } else {
                Write-Verbose "ServiceID $serviceId has no RetirementDate, skipping"
                continue
            }
        } else {
            try {
                $deadlineDate = [DateTime]::Parse($deadlineStr)
                $daysUntil = ($deadlineDate - (Get-Date)).TotalDays
                # Ensure deadline string is in YYYY-MM-DD format for consistent display
                $deadlineStr = $deadlineDate.ToString("yyyy-MM-dd")
            }
            catch {
                Write-Verbose "Failed to parse RetirementDate '$deadlineStr' for ServiceID $serviceId : $_"
                if ($useFallback) {
                    # Use "TBD" for fallback entries when date parsing fails
                    $deadlineStr = "TBD"
                    $deadlineDate = $null
                    $daysUntil = $null
                } else {
                    continue
                }
            }
        }

        # Calculate status
        if ($useFallback) {
            # For fallback entries, mark as DEPRECATED since we don't have real dates
            $status = "DEPRECATED"
            $severity = "Medium"  # Default to Medium for unknown deprecation dates
        } else {
            $status = "ANNOUNCED"
            if ($deadlineDate -lt (Get-Date)) {
                $status = "RETIRED"
            }
            elseif ($daysUntil -lt 90) {
                $status = "DEPRECATED"
            }

            # Calculate severity
            $severity = "Low"
            if ($daysUntil -lt 0) {
                $severity = "Critical"
            }
            elseif ($daysUntil -lt 30) {
                $severity = "Critical"
            }
            elseif ($daysUntil -lt 90) {
                $severity = "High"
            }
            elseif ($daysUntil -lt 180) {
                $severity = "Medium"
            }
        }

        # Determine resource type (try to get from first resource, or use common type)
        $resourceType = "Unknown"
        if ($affectedResources.Count -gt 0) {
            $firstRes = $affectedResources[0]
            if ($null -ne $firstRes.type) {
                $resourceType = $firstRes.type
            }
        }

        # Build action required and migration guide from Link
        if ($useFallback) {
            $actionRequired = "⚠️ PLACEHOLDER DATE - Review resource configuration and check Microsoft documentation for actual retirement dates"
            $migrationGuide = "This resource matches a deprecated configuration pattern identified by Microsoft's EOL KQL query, but the ServiceID ($serviceId) is not in the official service_list.json. The deadline date shown is a placeholder (90 days from scan date). Please verify the actual retirement date at https://github.com/Azure/EOL or Microsoft's official documentation."
        } else {
            $actionRequired = "Review retirement notice and plan migration"
            $migrationGuide = ""
            if ($serviceInfo.Link) {
                $migrationGuide = "See: $($serviceInfo.Link)"
                $actionRequired = "Review retirement notice: $($serviceInfo.Link)"
            }
        }

        # Convert affected resources to our format
        $affected = [System.Collections.Generic.List[pscustomobject]]::new()
        foreach ($res in $affectedResources) {
            # Extract resource name from ID if name property is missing
            $resourceName = $res.name
            if ([string]::IsNullOrWhiteSpace($resourceName) -and $res.id) {
                # Extract name from resource ID (last segment after final '/')
                $resourceName = $res.id.Split('/')[-1]
            }
            if ([string]::IsNullOrWhiteSpace($resourceName)) {
                # Fallback: use a generic name
                $resourceName = "Unknown"
            }
            
            $affected.Add([pscustomobject]@{
                ResourceId     = $res.id
                ResourceGroup  = $res.resourceGroup
                Location       = $res.location
                SubscriptionId = $res.subscriptionId
                SubscriptionName = Get-SubscriptionDisplayName -SubscriptionId $res.subscriptionId
                Name           = $resourceName
                ResourceName   = $resourceName
                Type           = $res.type
                Properties     = $res.properties
                Sku            = $res.sku
                Tags           = $res.tags
            })
        }

        $result = [pscustomobject]@{
            Component            = $component
            ResourceType         = $resourceType
            Status               = $status
            Deadline             = $deadlineStr
            DaysUntilDeadline    = [math]::Round($daysUntil, 0)
            Severity             = $severity
            AffectedResourceCount= $affected.Count
            AffectedResources    = $affected
            ActionRequired       = $actionRequired
            MigrationGuide       = $migrationGuide
        }

        $results.Add($result)
    }

    Write-Verbose "Generated $($results.Count) EOL component results"
    return $results
}

