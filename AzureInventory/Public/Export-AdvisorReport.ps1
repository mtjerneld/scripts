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
        [bool]$UseRestApi = $true
    )
    
    $recommendations = [System.Collections.Generic.List[PSObject]]::new()
    
    try {
        Write-Host "  Retrieving Advisor recommendations for $SubscriptionName..." -ForegroundColor Cyan
        
        $advisorRecs = $null
        
        # Try REST API first (more complete data)
        if ($UseRestApi) {
            try {
                $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Advisor/recommendations?api-version=2025-01-01"
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

# Get-DictionaryValue is now imported from Private/Helpers/Get-DictionaryValue.ps1

<#
.SYNOPSIS
    Formats extended properties into human-readable technical details based on resource type.
#>
function Format-ExtendedPropertiesDetails {
    param(
        $ExtendedProps,
        [string]$ImpactedField,
        [string]$Category
    )
    
    if ($null -eq $ExtendedProps) { return $null }
    
    $details = [System.Collections.Generic.List[string]]::new()
    
    # VM Rightsizing details
    if ($ImpactedField -like "*virtualMachines*" -or $ImpactedField -like "*virtualMachineScaleSets*") {
        $currentSku = Get-DictionaryValue -Dict $ExtendedProps -Key "currentSku"
        $recommendedSku = Get-DictionaryValue -Dict $ExtendedProps -Key "targetSku"
        if (-not $recommendedSku) { $recommendedSku = Get-DictionaryValue -Dict $ExtendedProps -Key "recommendedSku" }
        
        if ($currentSku) { $details.Add("Current SKU: $currentSku") }
        if ($recommendedSku) { $details.Add("Recommended SKU: $recommendedSku") }
        
        $cpuP95 = Get-DictionaryValue -Dict $ExtendedProps -Key "MaxCpuP95"
        if (-not $cpuP95) { $cpuP95 = Get-DictionaryValue -Dict $ExtendedProps -Key "percentageCpuP95" }
        $memP95 = Get-DictionaryValue -Dict $ExtendedProps -Key "MaxMemoryP95"
        if (-not $memP95) { $memP95 = Get-DictionaryValue -Dict $ExtendedProps -Key "percentageMemoryP95" }
        
        if ($cpuP95) { $details.Add("CPU P95: $cpuP95%") }
        if ($memP95) { $details.Add("Memory P95: $memP95%") }
        
        $region = Get-DictionaryValue -Dict $ExtendedProps -Key "region"
        if ($region) { $details.Add("Region: $region") }
    }
    
    # SQL Database details
    if ($ImpactedField -like "*sql*databases*" -or $ImpactedField -like "*sql*servers*") {
        $serverName = Get-DictionaryValue -Dict $ExtendedProps -Key "ServerName"
        $dbName = Get-DictionaryValue -Dict $ExtendedProps -Key "DatabaseName"
        $currentSku = Get-DictionaryValue -Dict $ExtendedProps -Key "Current_SKU"
        $recommendedSku = Get-DictionaryValue -Dict $ExtendedProps -Key "Recommended_SKU"
        $currentDtu = Get-DictionaryValue -Dict $ExtendedProps -Key "Current_DTU"
        $recommendedDtu = Get-DictionaryValue -Dict $ExtendedProps -Key "Recommended_DTU"
        $dbSize = Get-DictionaryValue -Dict $ExtendedProps -Key "DatabaseSize"
        
        if ($serverName) { $details.Add("Server: $serverName") }
        if ($dbName) { $details.Add("Database: $dbName") }
        if ($currentSku -and $recommendedSku) { $details.Add("SKU: $currentSku → $recommendedSku") }
        if ($currentDtu -and $recommendedDtu) { $details.Add("DTU: $currentDtu → $recommendedDtu") }
        if ($dbSize) { $details.Add("Size: $dbSize MB") }
    }
    
    # Storage Account details
    if ($ImpactedField -like "*storageAccounts*") {
        $currentTier = Get-DictionaryValue -Dict $ExtendedProps -Key "currentAccessTier"
        $recommendedTier = Get-DictionaryValue -Dict $ExtendedProps -Key "recommendedAccessTier"
        $blobCount = Get-DictionaryValue -Dict $ExtendedProps -Key "blobCount"
        $totalSize = Get-DictionaryValue -Dict $ExtendedProps -Key "totalSizeInGB"
        
        if ($currentTier -and $recommendedTier) { $details.Add("Tier: $currentTier → $recommendedTier") }
        if ($blobCount) { $details.Add("Blobs: $blobCount") }
        if ($totalSize) { $details.Add("Size: $totalSize GB") }
    }
    
    # Reserved Instances details
    if ($ImpactedField -like "*reservedInstances*" -or $Category -eq "Cost") {
        $term = Get-DictionaryValue -Dict $ExtendedProps -Key "term"
        $scope = Get-DictionaryValue -Dict $ExtendedProps -Key "scope"
        $lookback = Get-DictionaryValue -Dict $ExtendedProps -Key "lookbackPeriod"
        $qty = Get-DictionaryValue -Dict $ExtendedProps -Key "recommendedQuantity"
        $vmSize = Get-DictionaryValue -Dict $ExtendedProps -Key "vmSize"
        
        if ($term) { $details.Add("Term: $term") }
        if ($scope) { $details.Add("Scope: $scope") }
        if ($vmSize) { $details.Add("VM Size: $vmSize") }
        if ($qty) { $details.Add("Recommended Quantity: $qty") }
        if ($lookback) { $details.Add("Lookback: $lookback days") }
    }
    
    # App Service details
    if ($ImpactedField -like "*sites*" -or $ImpactedField -like "*serverFarms*") {
        $currentSku = Get-DictionaryValue -Dict $ExtendedProps -Key "currentSku"
        $recommendedSku = Get-DictionaryValue -Dict $ExtendedProps -Key "recommendedSku"
        $currentWorkers = Get-DictionaryValue -Dict $ExtendedProps -Key "currentNumberOfWorkers"
        $recommendedWorkers = Get-DictionaryValue -Dict $ExtendedProps -Key "recommendedNumberOfWorkers"
        
        if ($currentSku -and $recommendedSku) { $details.Add("SKU: $currentSku → $recommendedSku") }
        if ($currentWorkers -and $recommendedWorkers) { $details.Add("Workers: $currentWorkers → $recommendedWorkers") }
    }
    
    # Cosmos DB details
    if ($ImpactedField -like "*documentdb*" -or $ImpactedField -like "*cosmosdb*") {
        $currentRu = Get-DictionaryValue -Dict $ExtendedProps -Key "currentProvisionedThroughput"
        $recommendedRu = Get-DictionaryValue -Dict $ExtendedProps -Key "recommendedProvisionedThroughput"
        
        if ($currentRu -and $recommendedRu) { $details.Add("RU/s: $currentRu → $recommendedRu") }
    }
    
    # Observation period (common across many types)
    $obsStart = Get-DictionaryValue -Dict $ExtendedProps -Key "ObservationPeriodStartDate"
    $obsEnd = Get-DictionaryValue -Dict $ExtendedProps -Key "ObservationPeriodEndDate"
    if ($obsStart -and $obsEnd) {
        $startDate = if ($obsStart -is [datetime]) { $obsStart.ToString("yyyy-MM-dd") } else { $obsStart.Substring(0,10) }
        $endDate = if ($obsEnd -is [datetime]) { $obsEnd.ToString("yyyy-MM-dd") } else { $obsEnd.Substring(0,10) }
        $details.Add("Observation: $startDate to $endDate")
    }
    
    if ($details.Count -eq 0) { return $null }
    
    return $details -join " | "
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
    
    # Potential benefits - check direct property FIRST (this is where API puts it)
    $potentialBenefits = Get-RecProperty -RestPath "properties.potentialBenefits" -ModulePath "PotentialBenefit"
    if (-not $potentialBenefits) {
        $potentialBenefits = Get-DictionaryValue -Dict $extendedProps -Key "potentialBenefits"
    }
    if (-not $potentialBenefits) {
        $potentialBenefits = Get-DictionaryValue -Dict $extendedProps -Key "benefits"
    }
    
    # Learn more link - check direct property FIRST
    $learnMoreLink = Get-RecProperty -RestPath "properties.learnMoreLink" -ModulePath "LearnMoreLink"
    if (-not $learnMoreLink) {
        $learnMoreLink = Get-DictionaryValue -Dict $extendedProps -Key "learnMoreLink"
    }
    
    # Label (short title for the recommendation)
    $label = Get-RecProperty -RestPath "properties.label" -ModulePath "Label"
    
    # Risk level (Warning, Error, None)
    $risk = Get-RecProperty -RestPath "properties.risk" -ModulePath "Risk"
    
    # Control/SubCategory (ServiceUpgradeAndRetirement, HighAvailability, etc.)
    $control = Get-RecProperty -RestPath "properties.control" -ModulePath "Control"
    
    # Actions array (contains actionable links and steps)
    $actions = Get-RecProperty -RestPath "properties.actions" -ModulePath "Actions"
    
    # Recommendation type ID - critical for grouping
    $recommendationTypeId = Get-RecProperty -RestPath "properties.recommendationTypeId" -ModulePath "RecommendationTypeId"
    if (-not $recommendationTypeId) {
        # Try to extract from the recommendation ID
        if ($recId -match '/recommendations/([^/]+)$') {
            $recommendationTypeId = $Matches[1]
        }
    }
    
    # Cost savings - robust extraction (both monthly and annual)
    $potentialSavings = $null
    $monthlySavings = $null
    $savingsCurrency = "USD"
    
    if ($category -eq 'Cost') {
        # Try metadata first
        $metadata = Get-RecProperty -RestPath "properties.metadata" -ModulePath "Metadata"
        
        # Method 1: Direct from extendedProperties (most common)
        # Try annual first, then monthly
        $potentialSavings = Get-DictionaryValue -Dict $extendedProps -Key "annualSavingsAmount"
        $monthlySavings = Get-DictionaryValue -Dict $extendedProps -Key "savingsAmount"
        $currencyValue = Get-DictionaryValue -Dict $extendedProps -Key "savingsCurrency"
        if ($currencyValue) { $savingsCurrency = $currencyValue }
        
        # If we only have monthly, calculate annual
        if (-not $potentialSavings -and $monthlySavings) {
            try {
                $potentialSavings = [decimal]$monthlySavings * 12
            } catch { }
        }
        
        # Method 2: From metadata.AdditionalProperties
        if (-not $potentialSavings -and $metadata) {
            if ($metadata.AdditionalProperties) {
                if (-not $potentialSavings) {
                    $potentialSavings = Get-DictionaryValue -Dict $metadata.AdditionalProperties -Key "annualSavingsAmount"
                }
                if (-not $monthlySavings) {
                    $monthlySavings = Get-DictionaryValue -Dict $metadata.AdditionalProperties -Key "savingsAmount"
                }
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
                    if ($keysArray[$i] -eq 'savingsAmount' -and $i -lt $valuesArray.Count) {
                        $monthlySavings = $valuesArray[$i]
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
            if ($restExtProps.savingsAmount) {
                $monthlySavings = $restExtProps.savingsAmount
            }
            if ($restExtProps.savingsCurrency) {
                $savingsCurrency = $restExtProps.savingsCurrency
            }
        }
        
        # If we only have monthly, calculate annual
        if (-not $potentialSavings -and $monthlySavings) {
            try {
                $potentialSavings = [decimal]$monthlySavings * 12
            } catch { }
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
        
        # Convert monthly to decimal if found
        if ($monthlySavings) {
            try {
                $monthlySavings = [decimal]$monthlySavings
            }
            catch {
                Write-Verbose "Failed to parse monthly savings amount: $monthlySavings"
                $monthlySavings = $null
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
    
    # Format technical details from extended properties
    $technicalDetails = Format-ExtendedPropertiesDetails -ExtendedProps $extendedProps -ImpactedField $impactedField -Category $category
    
    # Build the recommendation object with all available fields
    return [PSCustomObject]@{
        SubscriptionId       = $SubscriptionId
        SubscriptionName     = $SubscriptionName
        RecommendationId     = $recId
        RecommendationTypeId = $recommendationTypeId
        Category             = $category
        Impact               = $impact
        Risk                 = $risk
        Control              = $control
        Label                = $label
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
        MonthlySavings       = if ($monthlySavings) { [decimal]$monthlySavings } else { $null }
        SavingsCurrency      = $savingsCurrency
        LastUpdated          = $lastUpdated
        Remediation          = $remediationSteps
        Actions              = $actions
        TechnicalDetails     = $technicalDetails
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
                SubscriptionId    = $_.SubscriptionId
                SubscriptionName  = $_.SubscriptionName
                ResourceId        = $_.ResourceId
                ResourceName      = $_.ResourceName
                ResourceGroup     = $_.ResourceGroup
                ResourceType      = $_.ResourceType
                PotentialSavings  = $_.PotentialSavings
                MonthlySavings    = $_.MonthlySavings
                SavingsCurrency   = $_.SavingsCurrency
                TechnicalDetails  = $_.TechnicalDetails
                Impact            = $_.Impact
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
        $highCount = 0
        $mediumCount = 0
        $lowCount = 0
        foreach ($rec in $group.Group) {
            if ($rec.Impact -eq 'High') { $highCount++ }
            elseif ($rec.Impact -eq 'Medium') { $mediumCount++ }
            elseif ($rec.Impact -eq 'Low') { $lowCount++ }
        }
        
        # Determine highest impact level
        $highestImpact = if ($highCount -gt 0) { 'High' } elseif ($mediumCount -gt 0) { 'Medium' } else { 'Low' }
        
        # Calculate monthly savings total
        $totalMonthlySavings = $null
        if ($firstRec.Category -eq 'Cost') {
            $monthlyItems = $group.Group | Where-Object { $_.MonthlySavings -and $_.MonthlySavings -gt 0 }
            if ($monthlyItems) {
                $totalMonthlySavings = ($monthlyItems | Measure-Object -Property MonthlySavings -Sum).Sum
            }
        }
        
        $groupedRec = [PSCustomObject]@{
            RecommendationTypeId  = $firstRec.RecommendationTypeId
            Category              = $firstRec.Category
            Impact                = $highestImpact
            Risk                  = $firstRec.Risk
            Control               = $firstRec.Control
            Label                 = $firstRec.Label
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
            TotalMonthlySavings   = $totalMonthlySavings
            SavingsCurrency       = $savingsCurrency
            Remediation           = $firstRec.Remediation
            Actions               = $firstRec.Actions
            AffectedResourceCount = $group.Group.Count
            AffectedResources     = $affectedResources
            AffectedSubscriptions = @()
        }
        
        $grouped.Add($groupedRec)
    }
    
    # Sort by impact (High first) then by resource count
    return $grouped | Sort-Object -Property @(
        @{ Expression = { switch ($_.Impact) { 'High' { 1 } 'Medium' { 2 } 'Low' { 3 } default { 4 } } } },
        @{ Expression = { $_.AffectedResourceCount }; Descending = $true }
    )
}
