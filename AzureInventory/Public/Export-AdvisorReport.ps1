<#
.SYNOPSIS
    Collects Azure Advisor recommendations for a subscription.

.DESCRIPTION
    Retrieves all Azure Advisor recommendations across categories:
    - Cost: Cost optimization recommendations
    - Security: Security recommendations  
    - Reliability: High availability recommendations
    - OperationalExcellence: Operational best practices
    - Performance: Performance optimization recommendations

    This version uses REST API for more complete data and robust metadata parsing.

.PARAMETER SubscriptionId
    Azure subscription ID to scan.

.PARAMETER SubscriptionName
    Human-readable subscription name.

.PARAMETER UseRestApi
    Force use of REST API instead of Az.Advisor module (recommended for better data).

.OUTPUTS
    Array of recommendation objects with complete metadata.
#>
function Get-AzureAdvisorRecommendations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionName,
        
        [Parameter(Mandatory = $false)]
        [switch]$UseRestApi = $true
    )
    
    $recommendations = [System.Collections.Generic.List[PSObject]]::new()
    
    try {
        Write-Host "  Retrieving Advisor recommendations for $SubscriptionName..." -ForegroundColor Cyan
        
        $advisorRecs = $null
        
        # Try REST API first (more complete data)
        if ($UseRestApi) {
            try {
                $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Advisor/recommendations?api-version=2023-01-01"
                $response = Invoke-AzRestMethod -Method GET -Uri $uri -ErrorAction Stop
                
                if ($response.StatusCode -eq 200 -and $response.Content) {
                    $advisorData = $response.Content | ConvertFrom-Json
                    if ($advisorData.value) {
                        $advisorRecs = $advisorData.value
                        Write-Host "    Found $($advisorRecs.Count) recommendations via REST API" -ForegroundColor Green
                    }
                }
            }
            catch {
                Write-Warning "REST API failed, falling back to Az.Advisor module: $_"
            }
        }
        
        # Fallback to Az.Advisor module
        if (-not $advisorRecs) {
            if (Get-Command -Name Get-AzAdvisorRecommendation -ErrorAction SilentlyContinue) {
                $advisorRecs = Get-AzAdvisorRecommendation -ErrorAction Stop
                Write-Host "    Found $($advisorRecs.Count) recommendations via Az.Advisor" -ForegroundColor Green
            }
        }
        
        if (-not $advisorRecs -or $advisorRecs.Count -eq 0) {
            Write-Host "    No recommendations found" -ForegroundColor Yellow
            return $recommendations
        }
        
        # Process each recommendation
        foreach ($rec in $advisorRecs) {
            try {
                $recObj = Convert-AdvisorRecommendation -RawRec $rec -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName
                if ($recObj) {
                    $recommendations.Add($recObj)
                }
            }
            catch {
                Write-Verbose "Failed to parse recommendation: $_"
            }
        }
        
        Write-Host "    Processed $($recommendations.Count) recommendations" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to retrieve Advisor recommendations for $SubscriptionName : $_"
    }
    
    return $recommendations
}

<#
.SYNOPSIS
    Safely extracts a value from a dictionary/hashtable/object.
#>
function Get-DictionaryValue {
    param(
        $Dict,
        [string]$Key
    )
    
    if ($null -eq $Dict) { return $null }
    
    # Try hashtable/dictionary access
    if ($Dict -is [System.Collections.IDictionary]) {
        if ($Dict.ContainsKey($Key)) {
            return $Dict[$Key]
        }
        return $null
    }
    
    # Try as PSObject with properties
    if ($Dict.PSObject.Properties[$Key]) {
        return $Dict.PSObject.Properties[$Key].Value
    }
    
    # Try direct property access
    try {
        $value = $Dict.$Key
        if ($null -ne $value) {
            return $value
        }
    }
    catch { }
    
    return $null
}

<#
.SYNOPSIS
    Converts a raw Advisor recommendation to a standardized object.
#>
function Convert-AdvisorRecommendation {
    param(
        [Parameter(Mandatory = $true)]
        $RawRec,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionName
    )
    
    # Determine if this is REST API response or Az.Advisor object
    $isRestApi = $null -ne $RawRec.properties
    
    # Helper function to get property from either format
    function Get-RecProperty {
        param([string]$RestPath, [string]$ModulePath)
        
        if ($isRestApi) {
            $value = $RawRec
            foreach ($part in $RestPath.Split('.')) {
                if ($null -eq $value) { return $null }
                $value = $value.$part
            }
            return $value
        }
        else {
            $value = $RawRec
            foreach ($part in $ModulePath.Split('.')) {
                if ($null -eq $value) { return $null }
                $value = $value.$part
            }
            return $value
        }
    }
    
    # Extract basic properties
    $recId = if ($RawRec.id) { $RawRec.id } elseif ($RawRec.Id) { $RawRec.Id } else { [guid]::NewGuid().ToString() }
    
    # Category - map HighAvailability to Reliability
    $rawCategory = Get-RecProperty -RestPath "properties.category" -ModulePath "Category"
    $category = switch ($rawCategory) {
        "HighAvailability" { "Reliability" }
        default { $rawCategory }
    }
    
    $impact = Get-RecProperty -RestPath "properties.impact" -ModulePath "Impact"
    
    # Resource identification
    $resourceId = Get-RecProperty -RestPath "properties.resourceMetadata.resourceId" -ModulePath "ResourceMetadataResourceId"
    if (-not $resourceId) {
        $resourceId = Get-RecProperty -RestPath "properties.impactedValue" -ModulePath "ImpactedValue"
    }
    
    $impactedValue = Get-RecProperty -RestPath "properties.impactedValue" -ModulePath "ImpactedValue"
    $impactedField = Get-RecProperty -RestPath "properties.impactedField" -ModulePath "ImpactedField"
    
    # Parse resource name and group from ResourceId
    $resourceName = $impactedValue
    $resourceGroup = "N/A"
    
    if ($resourceId -and $resourceId -match '/resourceGroups/([^/]+)/') {
        $resourceGroup = $Matches[1]
    }
    if ($resourceId -and $resourceId -match '/([^/]+)$') {
        $resourceName = $Matches[1]
    }
    if (-not $resourceName) {
        $resourceName = $impactedValue
    }
    
    # Short description (Problem/Solution)
    $problem = $null
    $solution = $null
    
    if ($isRestApi) {
        $shortDesc = $RawRec.properties.shortDescription
        if ($shortDesc) {
            $problem = $shortDesc.problem
            $solution = $shortDesc.solution
        }
    }
    else {
        $problem = $RawRec.ShortDescriptionProblem
        $solution = $RawRec.ShortDescriptionSolution
    }
    
    # Fallback for problem/solution
    if (-not $problem) {
        $problem = Get-RecProperty -RestPath "properties.description" -ModulePath "Description"
    }
    if (-not $solution) {
        $solution = "See Azure Portal for remediation steps"
    }
    
    # Long description - extract from multiple sources
    $longDescription = $null
    $description = Get-RecProperty -RestPath "properties.description" -ModulePath "Description"
    
    # Try to get extended description from extendedProperties
    $extendedProps = Get-RecProperty -RestPath "properties.extendedProperties" -ModulePath "ExtendedProperty"
    if (-not $extendedProps) {
        $extendedProps = $RawRec.ExtendedProperties
    }
    
    if ($extendedProps) {
        # Extract long description from various possible locations
        $longDescription = Get-DictionaryValue -Dict $extendedProps -Key "recommendationDescription"
        if (-not $longDescription) {
            $longDescription = Get-DictionaryValue -Dict $extendedProps -Key "longDescription"
        }
        if (-not $longDescription) {
            $longDescription = Get-DictionaryValue -Dict $extendedProps -Key "description"
        }
    }
    
    if (-not $longDescription) {
        $longDescription = $description
    }
    
    # Potential benefits
    $potentialBenefits = Get-DictionaryValue -Dict $extendedProps -Key "potentialBenefits"
    if (-not $potentialBenefits) {
        $potentialBenefits = Get-DictionaryValue -Dict $extendedProps -Key "benefits"
    }
    if (-not $potentialBenefits) {
        $potentialBenefits = Get-RecProperty -RestPath "properties.potentialBenefits" -ModulePath "PotentialBenefit"
    }
    
    # Learn more link
    $learnMoreLink = Get-RecProperty -RestPath "properties.learnMoreLink" -ModulePath "LearnMoreLink"
    if (-not $learnMoreLink) {
        $learnMoreLink = Get-DictionaryValue -Dict $extendedProps -Key "learnMoreLink"
    }
    
    # Recommendation type ID - critical for grouping
    $recommendationTypeId = Get-RecProperty -RestPath "properties.recommendationTypeId" -ModulePath "RecommendationTypeId"
    if (-not $recommendationTypeId) {
        # Try to extract from the recommendation ID
        if ($recId -match '/recommendations/([^/]+)$') {
            $recommendationTypeId = $Matches[1]
        }
    }
    
    # Cost savings - robust extraction
    $potentialSavings = $null
    $savingsCurrency = "USD"
    
    if ($category -eq 'Cost') {
        # Try metadata first
        $metadata = Get-RecProperty -RestPath "properties.metadata" -ModulePath "Metadata"
        
        # Method 1: Direct from extendedProperties (most common)
        $potentialSavings = Get-DictionaryValue -Dict $extendedProps -Key "annualSavingsAmount"
        $currencyValue = Get-DictionaryValue -Dict $extendedProps -Key "savingsCurrency"
        if ($currencyValue) { $savingsCurrency = $currencyValue }
        
        # Method 2: From metadata.AdditionalProperties
        if (-not $potentialSavings -and $metadata) {
            if ($metadata.AdditionalProperties) {
                $potentialSavings = Get-DictionaryValue -Dict $metadata.AdditionalProperties -Key "annualSavingsAmount"
                $currencyValue = Get-DictionaryValue -Dict $metadata.AdditionalProperties -Key "savingsCurrency"
                if ($currencyValue) { $savingsCurrency = $currencyValue }
            }
            
            # Method 3: Metadata with Keys/Values arrays
            if (-not $potentialSavings -and $metadata.Keys -and $metadata.Values) {
                $keysArray = @($metadata.Keys)
                $valuesArray = @($metadata.Values)
                
                for ($i = 0; $i -lt $keysArray.Count; $i++) {
                    if ($keysArray[$i] -eq 'annualSavingsAmount' -and $i -lt $valuesArray.Count) {
                        $potentialSavings = $valuesArray[$i]
                    }
                    if ($keysArray[$i] -eq 'savingsCurrency' -and $i -lt $valuesArray.Count) {
                        $savingsCurrency = $valuesArray[$i]
                    }
                }
            }
        }
        
        # Method 4: REST API format with direct properties
        if (-not $potentialSavings -and $isRestApi -and $RawRec.properties.extendedProperties) {
            $restExtProps = $RawRec.properties.extendedProperties
            if ($restExtProps.annualSavingsAmount) {
                $potentialSavings = $restExtProps.annualSavingsAmount
            }
            if ($restExtProps.savingsCurrency) {
                $savingsCurrency = $restExtProps.savingsCurrency
            }
        }
        
        # Convert to decimal if found
        if ($potentialSavings) {
            try {
                $potentialSavings = [decimal]$potentialSavings
            }
            catch {
                Write-Verbose "Failed to parse savings amount: $potentialSavings"
                $potentialSavings = $null
            }
        }
    }
    
    # Last updated
    $lastUpdated = Get-RecProperty -RestPath "properties.lastUpdated" -ModulePath "LastUpdated"
    
    # Remediation info
    $remediation = Get-RecProperty -RestPath "properties.remediation" -ModulePath "Remediation"
    $remediationSteps = $null
    
    if ($remediation) {
        if ($remediation -is [string]) {
            $remediationSteps = $remediation
        }
        elseif ($remediation.details) {
            $remediationSteps = $remediation.details
        }
    }
    
    # Action
    $action = Get-RecProperty -RestPath "properties.actions" -ModulePath "Action"
    
    # Build the recommendation object
    return [PSCustomObject]@{
        SubscriptionId       = $SubscriptionId
        SubscriptionName     = $SubscriptionName
        RecommendationId     = $recId
        RecommendationTypeId = $recommendationTypeId
        Category             = $category
        Impact               = $impact
        ImpactedField        = $impactedField
        ResourceId           = $resourceId
        ResourceName         = $resourceName
        ResourceGroup        = $resourceGroup
        ResourceType         = $impactedField
        Problem              = $problem
        Solution             = $solution
        Description          = $description
        LongDescription      = $longDescription
        PotentialBenefits    = $potentialBenefits
        LearnMoreLink        = $learnMoreLink
        PotentialSavings     = $potentialSavings
        SavingsCurrency      = $savingsCurrency
        LastUpdated          = $lastUpdated
        Remediation          = $remediationSteps
        Action               = $action
        ExtendedProperties   = $extendedProps
    }
}

<#
.SYNOPSIS
    Groups recommendations by RecommendationType for consolidated reporting.

.DESCRIPTION
    Takes a list of recommendations and groups them by RecommendationTypeId,
    aggregating affected resources and summing cost savings.

.PARAMETER Recommendations
    Array of recommendation objects from Get-AzureAdvisorRecommendations.

.OUTPUTS
    Array of grouped recommendation objects with AffectedResources property.
#>
function Group-AdvisorRecommendations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Recommendations
    )
    
    if ($Recommendations.Count -eq 0) {
        return @()
    }
    
    $grouped = [System.Collections.Generic.List[PSObject]]::new()
    
    # Group by RecommendationTypeId and Category
    $groups = $Recommendations | Group-Object -Property { 
        $typeId = if ($_.RecommendationTypeId) { $_.RecommendationTypeId } else { $_.Problem }
        $cat = $_.Category
        "$cat|$typeId"
    }
    
    foreach ($group in $groups) {
        $firstRec = $group.Group[0]
        $affectedResources = $group.Group | ForEach-Object {
            [PSCustomObject]@{
                SubscriptionId   = $_.SubscriptionId
                SubscriptionName = $_.SubscriptionName
                ResourceId       = $_.ResourceId
                ResourceName     = $_.ResourceName
                ResourceGroup    = $_.ResourceGroup
                ResourceType     = $_.ResourceType
                PotentialSavings = $_.PotentialSavings
                SavingsCurrency  = $_.SavingsCurrency
            }
        }
        
        # Sum savings for cost recommendations
        $totalSavings = $null
        $savingsCurrency = "USD"
        
        if ($firstRec.Category -eq 'Cost') {
            $savingsItems = $group.Group | Where-Object { $_.PotentialSavings -and $_.PotentialSavings -gt 0 }
            if ($savingsItems) {
                $totalSavings = ($savingsItems | Measure-Object -Property PotentialSavings -Sum).Sum
                $savingsCurrency = ($savingsItems | Select-Object -First 1).SavingsCurrency
                if (-not $savingsCurrency) { $savingsCurrency = "USD" }
            }
        }
        
        # Calculate impact distribution
        $highCount = @($group.Group | Where-Object { $_.Impact -eq 'High' }).Count
        $mediumCount = @($group.Group | Where-Object { $_.Impact -eq 'Medium' }).Count
        $lowCount = @($group.Group | Where-Object { $_.Impact -eq 'Low' }).Count
        
        # Determine highest impact level
        $highestImpact = if ($highCount -gt 0) { 'High' } elseif ($mediumCount -gt 0) { 'Medium' } else { 'Low' }
        
        $groupedRec = [PSCustomObject]@{
            RecommendationTypeId  = $firstRec.RecommendationTypeId
            Category              = $firstRec.Category
            Impact                = $highestImpact
            ImpactDistribution    = @{
                High   = $highCount
                Medium = $mediumCount
                Low    = $lowCount
            }
            Problem               = $firstRec.Problem
            Solution              = $firstRec.Solution
            Description           = $firstRec.Description
            LongDescription       = $firstRec.LongDescription
            PotentialBenefits     = $firstRec.PotentialBenefits
            LearnMoreLink         = $firstRec.LearnMoreLink
            TotalSavings          = $totalSavings
            SavingsCurrency       = $savingsCurrency
            Remediation           = $firstRec.Remediation
            Action                = $firstRec.Action
            AffectedResourceCount = $group.Group.Count
            AffectedResources     = $affectedResources
            AffectedSubscriptions = @($group.Group | Select-Object -ExpandProperty SubscriptionName -Unique)
        }
        
        $grouped.Add($groupedRec)
    }
    
    # Sort by impact (High first) then by resource count
    return $grouped | Sort-Object -Property @(
        @{ Expression = { switch ($_.Impact) { 'High' { 1 } 'Medium' { 2 } 'Low' { 3 } default { 4 } } } },
        @{ Expression = { $_.AffectedResourceCount }; Descending = $true }
    )
}
