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
function Get-EOLStatus {
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

    # Create a lookup dictionary for ServiceID -> ServiceInfo
    $serviceLookup = @{}
    foreach ($service in $serviceList) {
        $serviceId = if ($service.Id -is [string]) { [int]$service.Id } else { $service.Id }
        if ($serviceId -gt 0) {
            $serviceLookup[$serviceId] = $service
        }
    }

    Write-Verbose "Loaded $($serviceLookup.Keys.Count) EOL service definitions"

    # Modify KQL query to filter by our subscriptions
    # Microsoft's query starts with "resources" followed by "| extend ServiceID = case(...)"
    # We need to inject our subscription filter right after "resources"
    $subSetJson = ($SubscriptionIds | Sort-Object -Unique | ConvertTo-Json -Compress)
    
    $modifiedKql = $kqlQuery
    
    # Microsoft's query structure: "resources\n| extend ServiceID = case(...)"
    # We need to insert subscription filter right after "resources"
    # Use multiline regex to match "resources" followed by newline and pipe
    if ($modifiedKql -match '(?s)^(resources\s*\r?\n\s*\|)') {
        # Insert subscription filter after "resources" and before the first pipe
        $modifiedKql = $modifiedKql -replace '(?s)^(resources\s*\r?\n\s*\|)', "resources`n| where subscriptionId in (dynamic($subSetJson))`n|"
    }
    else {
        # Fallback: just prepend subscription filter
        $modifiedKql = "resources`n| where subscriptionId in (dynamic($subSetJson))`n$modifiedKql"
    }

    # Execute the modified KQL query
    Write-Verbose "Executing Microsoft EOL KQL query against Azure Resource Graph..."
    try {
        $queryResult = Search-AzGraph -Query $modifiedKql -ErrorAction Stop
        Write-Verbose "Found $($queryResult.Count) EOL resources across selected subscriptions"
    }
    catch {
        Write-Warning "Resource Graph query failed: $_"
        return @()
    }

    if (-not $queryResult -or $queryResult.Count -eq 0) {
        Write-Verbose "No EOL resources found in selected subscriptions"
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

    # Convert to our output format
    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($serviceId in $resultsByServiceId.Keys) {
        $affectedResources = $resultsByServiceId[$serviceId]
        
        # Get service info from lookup
        if (-not $serviceLookup.ContainsKey($serviceId)) {
            Write-Verbose "ServiceID $serviceId not found in service_list.json, skipping"
            continue
        }

        $serviceInfo = $serviceLookup[$serviceId]
        
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
            Write-Verbose "ServiceID $serviceId has no RetirementDate, skipping"
            continue
        }

        try {
            $deadlineDate = [DateTime]::Parse($deadlineStr)
            $daysUntil = ($deadlineDate - (Get-Date)).TotalDays
        }
        catch {
            Write-Verbose "Failed to parse RetirementDate '$deadlineStr' for ServiceID $serviceId : $_"
            continue
        }

        # Calculate status
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

        # Determine resource type (try to get from first resource, or use common type)
        $resourceType = "Unknown"
        if ($affectedResources.Count -gt 0) {
            $firstRes = $affectedResources[0]
            if ($null -ne $firstRes.type) {
                $resourceType = $firstRes.type
            }
        }

        # Build action required and migration guide from Link
        $actionRequired = "Review retirement notice and plan migration"
        $migrationGuide = ""
        if ($serviceInfo.Link) {
            $migrationGuide = "See: $($serviceInfo.Link)"
            $actionRequired = "Review retirement notice: $($serviceInfo.Link)"
        }

        # Convert affected resources to our format
        $affected = [System.Collections.Generic.List[pscustomobject]]::new()
        foreach ($res in $affectedResources) {
            $affected.Add([pscustomobject]@{
                ResourceId     = $res.id
                ResourceGroup  = $res.resourceGroup
                Location       = $res.location
                SubscriptionId = $res.subscriptionId
                Name           = $res.name
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
