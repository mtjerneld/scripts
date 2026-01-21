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
        Write-Verbose "Retrieving Advisor recommendations for $SubscriptionName..."
        
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
                        Write-Verbose "Found $($advisorRecs.Count) recommendations via REST API"
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
                Write-Verbose "Found $($advisorRecs.Count) recommendations via Az.Advisor"
            }
        }
        
        if (-not $advisorRecs -or $advisorRecs.Count -eq 0) {
            Write-Verbose "No recommendations found"
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
        
        Write-Verbose "Processed $($recommendations.Count) recommendations"
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
        $qty = Get-DictionaryValue -Dict $ExtendedProps -Key "targetResourceCount"
        if (-not $qty) { $qty = Get-DictionaryValue -Dict $ExtendedProps -Key "recommendedQuantity" }
        $vmSize = Get-DictionaryValue -Dict $ExtendedProps -Key "vmSize"
        
        if ($term) { 
            $termDisplay = if ($term -eq 'P1Y') { 'P1Y' } 
                           elseif ($term -eq 'P3Y') { 'P3Y' } 
                           else { $term }
            $details.Add("Term: $termDisplay") 
        }
        if ($scope) { $details.Add("Scope: $scope") }
        if ($vmSize) { $details.Add("VM Size: $vmSize") }
        if ($qty) { $details.Add("Quantity: $qty") }
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
    
    # CRITICAL FIX: Parse ExtendedProperty if it's a JSON string
    # Az.Advisor cmdlet returns ExtendedProperty as JSON, not as object
    if ($extendedProps -and $extendedProps -is [string]) {
        try {
            $extendedProps = $extendedProps | ConvertFrom-Json
            Write-Verbose "Successfully parsed ExtendedProperty JSON"
        }
        catch {
            Write-Verbose "Failed to parse ExtendedProperty as JSON: $_"
            $extendedProps = $null
        }
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
    
    # DEDUPLICATION FIX: Filter Reserved Instance recommendations to avoid duplicates
    # Each VM size should appear once (60-day lookback, best term)
    $riRecs = $Recommendations | Where-Object { 
        $_.Problem -like "*reserved instance*" -or 
        $_.Solution -like "*reserved instance*"
    }
    
    if ($riRecs.Count -gt 0) {
        Write-Verbose "Processing $($riRecs.Count) Reserved Instance recommendations"
        
        # Extract metadata from TechnicalDetails for filtering
        foreach ($rec in $riRecs) {
            if ($rec.TechnicalDetails -match 'Lookback:\s*(\d+)') {
                $rec | Add-Member -NotePropertyName '_Lookback' -NotePropertyValue $Matches[1] -Force
            }
            if ($rec.TechnicalDetails -match 'Term:\s*(\w+)') {
                $rec | Add-Member -NotePropertyName '_Term' -NotePropertyValue $Matches[1] -Force
            }
            if ($rec.TechnicalDetails -match 'VM Size:\s*([^\|]+)') {
                $rec | Add-Member -NotePropertyName '_VMSize' -NotePropertyValue $Matches[1].Trim() -Force
            }
            
            # Also try to extract from ExtendedProperties if TechnicalDetails doesn't have it
            if (-not $rec._VMSize -and $rec.ExtendedProperties) {
                $extProps = $rec.ExtendedProperties
                if ($extProps -is [string]) {
                    try {
                        $extProps = $extProps | ConvertFrom-Json
                    } catch {
                        Write-Verbose "Could not parse ExtendedProperties JSON for lookback/term extraction"
                    }
                }
                if ($extProps) {
                    if ($extProps.vmSize -and -not $rec._VMSize) {
                        $rec | Add-Member -NotePropertyName '_VMSize' -NotePropertyValue $extProps.vmSize -Force
                    }
                    if ($extProps.lookbackPeriod -and -not $rec._Lookback) {
                        $rec | Add-Member -NotePropertyName '_Lookback' -NotePropertyValue $extProps.lookbackPeriod -Force
                    }
                    if ($extProps.term -and -not $rec._Term) {
                        $rec | Add-Member -NotePropertyName '_Term' -NotePropertyValue $extProps.term -Force
                    }
                }
            }
        }
        
        # Filter to 60-day lookback (most reliable)
        $riFiltered = $riRecs | Where-Object { $_._Lookback -eq '60' }
        
        if ($riFiltered.Count -eq 0) {
            Write-Verbose "No 60-day lookback found, using all lookback periods"
            $riFiltered = $riRecs
        }
        
        # Group by (Subscription + VMSize) and keep best term per group
        $riGroups = $riFiltered | Group-Object -Property { 
            "$($_.SubscriptionName)|$($_._VMSize)" 
        }
        
        $optimizedRi = foreach ($group in $riGroups) {
            # Prefer P3Y (better savings) if available, otherwise P1Y
            $p3y = $group.Group | Where-Object { $_._Term -eq 'P3Y' } | Select-Object -First 1
            $p1y = $group.Group | Where-Object { $_._Term -eq 'P1Y' } | Select-Object -First 1
            
            if ($p3y) { 
                Write-Verbose "Using P3Y for $($group.Name)"
                $p3y 
            } elseif ($p1y) { 
                Write-Verbose "Using P1Y for $($group.Name)"
                $p1y 
            } else {
                # Fallback: use first item if no term match
                Write-Verbose "Using first item for $($group.Name) (no P1Y/P3Y match)"
                $group.Group | Select-Object -First 1
            }
        }
        
        # Replace RI recommendations with deduplicated versions
        $nonRiRecs = $Recommendations | Where-Object { 
            $_.Problem -notlike "*reserved instance*" -and 
            $_.Solution -notlike "*reserved instance*"
        }
        
        $Recommendations = @($nonRiRecs) + @($optimizedRi)
        
        Write-Verbose "RI recommendations: $($riRecs.Count) → $($optimizedRi.Count) (deduplicated to 60-day lookback)"
    }
    
    # SAVINGS PLAN DEDUPLICATION - Choose best savings per subscription
    # Savings Plans are ALTERNATIVE to Reserved Instances, not additive
    $savingsPlanRecs = $Recommendations | Where-Object { 
        $_.Problem -like "*savings plan*" -or 
        $_.Solution -like "*savings plan*"
    }
    
    if ($savingsPlanRecs.Count -gt 0) {
        Write-Verbose "Processing $($savingsPlanRecs.Count) Savings Plan recommendations"
        
        # Extract metadata from TechnicalDetails
        foreach ($rec in $savingsPlanRecs) {
            if ($rec.TechnicalDetails -match 'Lookback:\s*(\d+)') {
                $rec | Add-Member -NotePropertyName '_Lookback' -NotePropertyValue $Matches[1] -Force
            }
            if ($rec.TechnicalDetails -match 'Term:\s*(\w+)') {
                $rec | Add-Member -NotePropertyName '_Term' -NotePropertyValue $Matches[1] -Force
            }
            
            # Also try to extract from ExtendedProperties if TechnicalDetails doesn't have it
            if (-not $rec._Term -and $rec.ExtendedProperties) {
                $extProps = $rec.ExtendedProperties
                if ($extProps -is [string]) {
                    try {
                        $extProps = $extProps | ConvertFrom-Json
                    } catch {
                        Write-Verbose "Could not parse ExtendedProperties JSON for Savings Plan term extraction"
                    }
                }
                if ($extProps) {
                    if ($extProps.lookbackPeriod -and -not $rec._Lookback) {
                        $rec | Add-Member -NotePropertyName '_Lookback' -NotePropertyValue $extProps.lookbackPeriod -Force
                    }
                    if ($extProps.term -and -not $rec._Term) {
                        $rec | Add-Member -NotePropertyName '_Term' -NotePropertyValue $extProps.term -Force
                    }
                }
            }
        }
        
        # Group by Subscription (Savings Plans apply per subscription)
        $spGroups = $savingsPlanRecs | Group-Object -Property SubscriptionName
        
        $optimizedSp = foreach ($group in $spGroups) {
            # Select option with HIGHEST annual savings
            $bestOption = $group.Group | 
                Where-Object { $_.PotentialSavings -and $_.PotentialSavings -gt 0 } |
                Sort-Object -Property PotentialSavings -Descending |
                Select-Object -First 1
            
            if ($bestOption) {
                $term = if ($bestOption._Term -eq 'P1Y') { '1-year' } elseif ($bestOption._Term -eq 'P3Y') { '3-year' } else { $bestOption._Term }
                Write-Verbose "Best Savings Plan for $($group.Name): $term ($($bestOption.PotentialSavings) $($bestOption.SavingsCurrency))"
                $bestOption
            }
        }
        
        # Replace with optimized versions
        $nonSpRecs = $Recommendations | Where-Object { 
            $_.Problem -notlike "*savings plan*" -and 
            $_.Solution -notlike "*savings plan*"
        }
        
        $Recommendations = @($nonSpRecs) + @($optimizedSp)
        
        Write-Verbose "Savings Plan recommendations: $($savingsPlanRecs.Count) → $($optimizedSp.Count) (optimized for max savings)"
    }
    
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
        
        # Calculate per-subscription breakdown
        $subBreakdown = @{}
        foreach ($res in $group.Group) {
            $subName = $res.SubscriptionName
            if (-not $subName) { continue }
            $subNameLower = $subName.ToLower()
            if (-not $subBreakdown.ContainsKey($subNameLower)) {
                $subBreakdown[$subNameLower] = @{ resources = 0; savings = 0 }
            }
            $subBreakdown[$subNameLower].resources++
            if ($res.PotentialSavings) {
                $subBreakdown[$subNameLower].savings += $res.PotentialSavings
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
            AffectedSubscriptions = @($group.Group | Select-Object -ExpandProperty SubscriptionName -Unique | Where-Object { $_ })
            SubBreakdown          = $subBreakdown
        }
        
        $grouped.Add($groupedRec)
    }
    
    # Sort by impact (High first) then by resource count
    return $grouped | Sort-Object -Property @(
        @{ Expression = { switch ($_.Impact) { 'High' { 1 } 'Medium' { 2 } 'Low' { 3 } default { 4 } } } },
        @{ Expression = { $_.AffectedResourceCount }; Descending = $true }
    )
}

<#
.SYNOPSIS
    Generates a consolidated HTML report for Azure Advisor recommendations.

.DESCRIPTION
    Creates an interactive HTML report showing Azure Advisor recommendations
    grouped by recommendation type (not by resource), with expandable sections
    showing affected resources. This dramatically reduces report size when
    many resources have the same recommendation.

.PARAMETER AdvisorRecommendations
    Array of Advisor recommendation objects from Get-AzureAdvisorRecommendations.

.PARAMETER OutputPath
    Path for the HTML report output.

.PARAMETER TenantId
    Azure Tenant ID for display in report.

.OUTPUTS
    String path to the generated HTML report.
#>
function Export-AdvisorReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$AdvisorRecommendations,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        
        [string]$TenantId = "Unknown",
        
        [Parameter(Mandatory = $false)]
        [switch]$AI,
        
        [Parameter(Mandatory = $false)]
        [int]$AITopN = 15,
        
        [Parameter(Mandatory = $false)]
        [double]$AIMinSavings = 100
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    
    # Ensure AdvisorRecommendations is an array (handle null/empty cases)
    if ($null -eq $AdvisorRecommendations) {
        $AdvisorRecommendations = @()
    } else {
        $AdvisorRecommendations = @($AdvisorRecommendations)
    }
    
    Write-Verbose "Export-AdvisorReport: Processing $($AdvisorRecommendations.Count) recommendations"
    
    # Group recommendations by type
    $groupedRecs = Group-AdvisorRecommendations -Recommendations $AdvisorRecommendations
    
    # Calculate statistics
    $totalRecs = $groupedRecs.Count
    $totalResources = ($groupedRecs | Measure-Object -Property AffectedResourceCount -Sum).Sum
    if (-not $totalResources) { $totalResources = 0 }
    
    # Group by category
    $costRecs = @($groupedRecs | Where-Object { $_.Category -eq 'Cost' })
    $securityRecs = @($groupedRecs | Where-Object { $_.Category -eq 'Security' })
    $reliabilityRecs = @($groupedRecs | Where-Object { $_.Category -eq 'Reliability' -or $_.Category -eq 'HighAvailability' })
    $operationalRecs = @($groupedRecs | Where-Object { $_.Category -eq 'OperationalExcellence' })
    $performanceRecs = @($groupedRecs | Where-Object { $_.Category -eq 'Performance' })
    
    # Calculate savings by strategy (RI and SP are ALTERNATIVE strategies, not additive)
    $riRecs = @($costRecs | Where-Object { 
        $_.Problem -like "*reserved instance*" -or 
        $_.Solution -like "*reserved instance*"
    })
    $spRecs = @($costRecs | Where-Object { 
        $_.Problem -like "*savings plan*" -or 
        $_.Solution -like "*savings plan*"
    })
    $otherCostRecs = @($costRecs | Where-Object { 
        $_.Problem -notlike "*reserved instance*" -and 
        $_.Solution -notlike "*reserved instance*" -and
        $_.Problem -notlike "*savings plan*" -and 
        $_.Solution -notlike "*savings plan*"
    })
    
    # Calculate totals for each strategy
    $riTotal = ($riRecs | Where-Object { $_.TotalSavings } | Measure-Object -Property TotalSavings -Sum).Sum
    if (-not $riTotal) { $riTotal = 0 }
    
    $spTotal = ($spRecs | Where-Object { $_.TotalSavings } | Measure-Object -Property TotalSavings -Sum).Sum
    if (-not $spTotal) { $spTotal = 0 }
    
    $otherCostTotal = ($otherCostRecs | Where-Object { $_.TotalSavings } | Measure-Object -Property TotalSavings -Sum).Sum
    if (-not $otherCostTotal) { $otherCostTotal = 0 }
    
    # Total savings = max(RI, SP) + other cost savings (RI and SP are alternatives)
    $totalSavings = [Math]::Max($riTotal, $spTotal) + $otherCostTotal
    
    $savingsCurrency = ($costRecs | Where-Object { $_.SavingsCurrency } | Select-Object -First 1).SavingsCurrency
    if (-not $savingsCurrency) { $savingsCurrency = "USD" }
    
    # Determine recommended strategy
    $recommendedStrategy = if ($spTotal -gt $riTotal) { "Savings Plans" } elseif ($riTotal -gt 0) { "Reserved Instances" } else { $null }
    $recommendedSavings = [Math]::Max($riTotal, $spTotal)
    
    # Get unique subscriptions for filter
    $allSubscriptions = @($AdvisorRecommendations | Select-Object -ExpandProperty SubscriptionName -Unique | Sort-Object)
    
    # Calculate subscriptions for each category and summary cards
    # Flatten AffectedSubscriptions arrays from grouped recommendations (they're already arrays)
    $allSubsLower = ($allSubscriptions | ForEach-Object { $_.ToLower() }) -join ','
    
    # Extract and flatten subscriptions from grouped recommendations
    # AffectedSubscriptions is an array, so we need to flatten arrays of arrays properly
    $costSubsList = [System.Collections.ArrayList]::new()
    foreach ($rec in $costRecs) {
        if ($rec.AffectedSubscriptions) {
            foreach ($sub in $rec.AffectedSubscriptions) {
                if ($sub -and $costSubsList -notcontains $sub) {
                    $null = $costSubsList.Add($sub)
                }
            }
        }
    }
    $costSubs = $costSubsList | Sort-Object
    $costSubsLower = if ($costSubs.Count -gt 0) { ($costSubs | ForEach-Object { $_.ToLower() }) -join ',' } else { '' }
    
    $securitySubsList = [System.Collections.ArrayList]::new()
    foreach ($rec in $securityRecs) {
        if ($rec.AffectedSubscriptions) {
            foreach ($sub in $rec.AffectedSubscriptions) {
                if ($sub -and $securitySubsList -notcontains $sub) {
                    $null = $securitySubsList.Add($sub)
                }
            }
        }
    }
    $securitySubs = $securitySubsList | Sort-Object
    $securitySubsLower = if ($securitySubs.Count -gt 0) { ($securitySubs | ForEach-Object { $_.ToLower() }) -join ',' } else { '' }
    
    $reliabilitySubsList = [System.Collections.ArrayList]::new()
    foreach ($rec in $reliabilityRecs) {
        if ($rec.AffectedSubscriptions) {
            foreach ($sub in $rec.AffectedSubscriptions) {
                if ($sub -and $reliabilitySubsList -notcontains $sub) {
                    $null = $reliabilitySubsList.Add($sub)
                }
            }
        }
    }
    $reliabilitySubs = $reliabilitySubsList | Sort-Object
    $reliabilitySubsLower = if ($reliabilitySubs.Count -gt 0) { ($reliabilitySubs | ForEach-Object { $_.ToLower() }) -join ',' } else { '' }
    
    $operationalSubsList = [System.Collections.ArrayList]::new()
    foreach ($rec in $operationalRecs) {
        if ($rec.AffectedSubscriptions) {
            foreach ($sub in $rec.AffectedSubscriptions) {
                if ($sub -and $operationalSubsList -notcontains $sub) {
                    $null = $operationalSubsList.Add($sub)
                }
            }
        }
    }
    $operationalSubs = $operationalSubsList | Sort-Object
    $operationalSubsLower = if ($operationalSubs.Count -gt 0) { ($operationalSubs | ForEach-Object { $_.ToLower() }) -join ',' } else { '' }
    
    $performanceSubsList = [System.Collections.ArrayList]::new()
    foreach ($rec in $performanceRecs) {
        if ($rec.AffectedSubscriptions) {
            foreach ($sub in $rec.AffectedSubscriptions) {
                if ($sub -and $performanceSubsList -notcontains $sub) {
                    $null = $performanceSubsList.Add($sub)
                }
            }
        }
    }
    $performanceSubs = $performanceSubsList | Sort-Object
    $performanceSubsLower = if ($performanceSubs.Count -gt 0) { ($performanceSubs | ForEach-Object { $_.ToLower() }) -join ',' } else { '' }
    
    # Calculate subscriptions for cost strategies
    $riSubsList = [System.Collections.ArrayList]::new()
    foreach ($rec in $riRecs) {
        if ($rec.AffectedSubscriptions) {
            foreach ($sub in $rec.AffectedSubscriptions) {
                if ($sub -and $riSubsList -notcontains $sub) {
                    $null = $riSubsList.Add($sub)
                }
            }
        }
    }
    $riSubs = $riSubsList | Sort-Object
    $riSubsLower = if ($riSubs.Count -gt 0) { ($riSubs | ForEach-Object { $_.ToLower() }) -join ',' } else { '' }
    
    $spSubsList = [System.Collections.ArrayList]::new()
    foreach ($rec in $spRecs) {
        if ($rec.AffectedSubscriptions) {
            foreach ($sub in $rec.AffectedSubscriptions) {
                if ($sub -and $spSubsList -notcontains $sub) {
                    $null = $spSubsList.Add($sub)
                }
            }
        }
    }
    $spSubs = $spSubsList | Sort-Object
    $spSubsLower = if ($spSubs.Count -gt 0) { ($spSubs | ForEach-Object { $_.ToLower() }) -join ',' } else { '' }
    
    $costStrategiesSubs = @($riSubs + $spSubs | Select-Object -Unique | Sort-Object)
    $costStrategiesSubsLower = if ($costStrategiesSubs.Count -gt 0) { ($costStrategiesSubs | ForEach-Object { $_.ToLower() }) -join ',' } else { '' }
    
    # Encode-Html is now imported from Private/Helpers/Encode-Html.ps1
    
    # Start building HTML
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure Advisor Recommendations Report</title>
    <style>
$(Get-ReportStylesheet)
    </style>
</head>
<body>
$(Get-ReportNavigation -ActivePage "Advisor")
    
    <div class="container">
        <div class="page-header">
            <h1>&#128161; Advisor Recommendations</h1>
            <p class="subtitle">Consolidated view - $totalRecs unique recommendations affecting $totalResources resources</p>
        </div>
        
        <div class="section-box">
            <h2>Overview</h2>
            <div class="summary-grid">
                <div class="summary-card blue-border" data-subscriptions="$allSubsLower">
                    <div class="summary-card-value" id="summary-total-recs">$totalRecs</div>
                    <div class="summary-card-label">Recommendations</div>
                </div>
                <div class="summary-card gray-border" data-subscriptions="$allSubsLower">
                    <div class="summary-card-value" id="summary-total-resources">$totalResources</div>
                    <div class="summary-card-label">Affected Resources</div>
                </div>
                <div class="summary-card green-border" data-subscriptions="$costSubsLower">
                    <div class="summary-card-value" id="summary-cost-count">$($costRecs.Count)</div>
                    <div class="summary-card-label">Cost</div>
                </div>
                <div class="summary-card red-border" data-subscriptions="$securitySubsLower">
                    <div class="summary-card-value" id="summary-security-count">$($securityRecs.Count)</div>
                    <div class="summary-card-label">Security</div>
                </div>
                <div class="summary-card orange-border" data-subscriptions="$reliabilitySubsLower">
                    <div class="summary-card-value" id="summary-reliability-count">$($reliabilityRecs.Count)</div>
                    <div class="summary-card-label">Reliability</div>
                </div>
                <div class="summary-card teal-border" data-subscriptions="$operationalSubsLower">
                    <div class="summary-card-value" id="summary-operational-count">$($operationalRecs.Count)</div>
                    <div class="summary-card-label">Operational Excellence</div>
                </div>
                <div class="summary-card purple-border" data-subscriptions="$performanceSubsLower">
                    <div class="summary-card-value" id="summary-performance-count">$($performanceRecs.Count)</div>
                    <div class="summary-card-label">Performance</div>
                </div>
                <div class="summary-card green-border" data-subscriptions="$costSubsLower">
                    <div class="summary-card-value savings-value" id="summary-total-savings">$(if ($savingsCurrency -eq 'USD') { '$' } else { $savingsCurrency }) $([math]::Round($totalSavings, 0).ToString('N0').Replace(',', ' '))</div>
                    <div class="summary-card-label">Potential Annual Savings</div>
                </div>
            </div>
        </div>
        
        $(if ($riTotal -gt 0 -or $spTotal -gt 0) {
            $strategyHtml = @"
        <div class="section-box cost-strategies-section" data-subscriptions="$costStrategiesSubsLower">
            <h2>Cost Optimization Strategies</h2>
            <p>Reserved Instances and Savings Plans are <strong>alternative strategies</strong>, not cumulative. Choose the approach that best fits your workload patterns.</p>
            
            <div class="cost-strategies-grid">
                $(if ($riTotal -gt 0) {
                    $riRecommended = if ($recommendedStrategy -eq "Reserved Instances") { '<span class="strategy-card__recommended">&#10003; RECOMMENDED</span>' } else { '' }
                    @"
                <div class="strategy-card">
                    <h3>Strategy A: Reserved Instances$riRecommended</h3>
                    <div class="strategy-card__savings">$(if ($savingsCurrency -eq 'USD') { '$' } else { $savingsCurrency }) $([math]::Round($riTotal, 0).ToString('N0').Replace(',', ' ')) <span class="strategy-card__period">per year</span></div>
                    <p>Purchase RIs for specific VM sizes. Best for stable, predictable workloads.</p>
                </div>
"@
                })
                
                $(if ($spTotal -gt 0) {
                    $spRecommended = if ($recommendedStrategy -eq "Savings Plans") { '<span class="strategy-card__recommended">&#10003; RECOMMENDED</span>' } else { '' }
                    @"
                <div class="strategy-card">
                    <h3>Strategy B: Savings Plans$spRecommended</h3>
                    <div class="strategy-card__savings">$(if ($savingsCurrency -eq 'USD') { '$' } else { $savingsCurrency }) $([math]::Round($spTotal, 0).ToString('N0').Replace(',', ' ')) <span class="strategy-card__period">per year</span></div>
                    <p>Commitment on compute spend. Best for dynamic, mixed workloads.</p>
                </div>
"@
                })
            </div>
            
            $(if ($recommendedStrategy) {
                $savingsDiff = [Math]::Abs($spTotal - $riTotal)
                if ($savingsDiff -gt 0) {
                    @"
            <div class="strategy-recommendation">
                <strong>Recommendation:</strong> 
                <span>$recommendedStrategy provides $(if ($savingsCurrency -eq 'USD') { '$' } else { $savingsCurrency }) $([math]::Round($savingsDiff, 0).ToString('N0').Replace(',', ' ')) more annual savings compared to the alternative strategy.</span>
            </div>
"@
                }
            })
            
            <p class="strategy-note">Note: These strategies are alternatives, not cumulative. You can also use a hybrid approach (RIs for stable VMs + Savings Plan for dynamic workloads) with detailed analysis.</p>
        </div>
"@
            $strategyHtml
        } else { '' })
        
        <div class="section-box">
            <h2>Filter Recommendations</h2>
            <div class="filter-section">
                <div class="filter-group">
                    <label>Search:</label>
                    <input type="text" id="searchFilter" placeholder="Search recommendations...">
                </div>
                <div class="filter-group">
                    <label>Impact:</label>
                    <select id="impactFilter">
                        <option value="all">All Impacts</option>
                        <option value="high">High</option>
                        <option value="medium">Medium</option>
                        <option value="low">Low</option>
                    </select>
                </div>
                <div class="filter-group">
                    <label>Subscription:</label>
                    <select id="subscriptionFilter">
                        <option value="all">All Subscriptions</option>
"@

    # Add subscription options
    foreach ($sub in $allSubscriptions) {
        $html += "                    <option value=`"$(($sub).ToLower())`">$sub</option>`n"
    }

    $html += @"
                    </select>
                </div>
            </div>
            <div class="filter-stats">
                Showing <span id="visibleCount">$totalRecs</span> of <span id="totalCount">$totalRecs</span> recommendations
            </div>
        </div>
"@

    if ($totalRecs -eq 0) {
        $html += @"
        <div class="no-data">
            <h2>No Recommendations Found</h2>
            <p>Azure Advisor has no recommendations for your subscriptions. Great job!</p>
        </div>
"@
    }
    else {
        $html += @"
        <div class="section-box">
            <h2>Recommendations by Area</h2>
"@
        
        # Generate sections for each category
        $categories = @(
            @{ Name = "Cost"; Icon = "cost"; Recs = $costRecs; Label = "Cost Optimization" }
            @{ Name = "Security"; Icon = "security"; Recs = $securityRecs; Label = "Security" }
            @{ Name = "Reliability"; Icon = "reliability"; Recs = $reliabilityRecs; Label = "Reliability" }
            @{ Name = "OperationalExcellence"; Icon = "operational"; Recs = $operationalRecs; Label = "Operational Excellence" }
            @{ Name = "Performance"; Icon = "performance"; Recs = $performanceRecs; Label = "Performance" }
        )
        
        foreach ($cat in $categories) {
            if ($cat.Recs.Count -eq 0) { continue }
            
            $catResourceCount = ($cat.Recs | Measure-Object -Property AffectedResourceCount -Sum).Sum
            $catHighCount = ($cat.Recs | ForEach-Object { $_.ImpactDistribution.High } | Measure-Object -Sum).Sum
            $catMediumCount = ($cat.Recs | ForEach-Object { $_.ImpactDistribution.Medium } | Measure-Object -Sum).Sum
            $catLowCount = ($cat.Recs | ForEach-Object { $_.ImpactDistribution.Low } | Measure-Object -Sum).Sum
            
            $html += @"
        
        <div class="expandable expandable--collapsed category-section" data-category="$($cat.Name.ToLower())">
            <div class="expandable__header" onclick="toggleCategory(this)">
                <div class="expandable__title">
                    <span class="expand-icon"></span>
                    <span class="category-icon $($cat.Icon)">$($cat.Recs.Count)</span>
                    <span>$($cat.Label)</span>
                    <span class="category-resource-count">($catResourceCount resources)</span>
                </div>
                <div class="expandable__badges">
                    <span class="badge badge--high">$catHighCount High</span>
                    <span class="badge badge--warning">$catMediumCount Med</span>
                    <span class="badge badge--info">$catLowCount Low</span>
                </div>
            </div>
            <div class="expandable__content">
"@
            
            # Create table for all recommendations in this category
            $html += @"
                        <table class="data-table data-table--sticky-header data-table--compact rec-table">
                            <thead>
                                <tr>
                                    <th></th>
                                    <th>Problem</th>
                                    <th>Savings</th>
                                    <th>Resources</th>
                                    <th>Severity</th>
                                </tr>
                            </thead>
                            <tbody>
"@
            
            foreach ($rec in $cat.Recs) {
                $impactClass = $rec.Impact.ToLower()
                $escapedProblem = Encode-Html $rec.Problem
                $escapedSolution = Encode-Html $rec.Solution
                $escapedDescription = Encode-Html $rec.Description
                $escapedLongDescription = Encode-Html $rec.LongDescription
                $escapedBenefits = Encode-Html $rec.PotentialBenefits
                $escapedRemediation = Encode-Html $rec.Remediation
                
                # Subscriptions as data attribute for filtering
                $subsLower = ($rec.AffectedSubscriptions | ForEach-Object { $_.ToLower() }) -join ','
                $searchable = "$escapedProblem $escapedSolution $escapedDescription".ToLower()
                
                $savingsDisplay = ""
                if ($rec.TotalSavings -and $rec.TotalSavings -gt 0) {
                    $currencySymbol = if ($rec.SavingsCurrency -eq 'USD') { '$' } else { $rec.SavingsCurrency }
                    $savingsDisplay = "$currencySymbol $([math]::Round($rec.TotalSavings, 0).ToString('N0').Replace(',', ' '))"
                } else {
                    $savingsDisplay = "-"
                }
                
                $recId = "rec-$([Guid]::NewGuid().ToString().Substring(0, 8))"
                
                # Description text for detail section
                $descriptionText = if ($escapedLongDescription -and $escapedLongDescription -ne $escapedProblem) {
                    $escapedLongDescription
                } elseif ($escapedDescription -and $escapedDescription -ne $escapedProblem) {
                    $escapedDescription
                } else {
                    $escapedProblem
                }
                
                # Main table row
                $categoryLower = $rec.Category.ToLower()
                $resourcesCount = $rec.AffectedResourceCount
                $savingsValue = if ($rec.TotalSavings) { $rec.TotalSavings } else { 0 }
                
                # Convert SubBreakdown to JSON for data attribute
                $subBreakdownJson = ''
                if ($rec.SubBreakdown) {
                    $subBreakdownJson = ($rec.SubBreakdown | ConvertTo-Json -Compress) -replace '"', '&quot;'
                }
                
                $html += @"
                                <tr class="rec-row" 
                                    data-impact="$impactClass" 
                                    data-subscriptions="$subsLower"
                                    data-category="$categoryLower"
                                    data-resources="$resourcesCount"
                                    data-savings="$savingsValue"
                                    data-sub-breakdown="$subBreakdownJson"
                                    data-searchable="$searchable"
                                    data-detail-id="$recId"
                                    onclick="toggleRecRow(this, '$recId')">
                                    <td><span class="expand-icon" id="icon-$recId"></span></td>
                                    <td class="rec-problem-cell">$escapedProblem</td>
                                    <td class="text-right">$savingsDisplay</td>
                                    <td class="text-right">$($rec.AffectedResourceCount)</td>
                                    <td><span class="badge $(if ($impactClass -eq 'high') { 'badge--high' } elseif ($impactClass -eq 'medium') { 'badge--warning' } else { 'badge--info' })">$($rec.Impact)</span></td>
                                </tr>
                                <tr class="rec-detail-row" id="$recId" style="display: none;">
                                    <td colspan="5" class="rec-detail-cell">
                                        <div class="rec-details">
"@
                
                # Description section (plain text)
                $html += @"
                                            <div class="detail-section">
                                                <div class="detail-title">Description</div>
                                                <div class="detail-content">$descriptionText</div>
                                            </div>
"@
                
                # Technical Details section (L3 - expandable, if available)
                if ($rec.AffectedResources -and ($rec.AffectedResources | Where-Object { $_.TechnicalDetails })) {
                    $techId = "$recId-tech"
                    $html += @"
                                            <div class="expandable expandable--collapsed detail-section">
                                                <div class="expandable__header" onclick="toggleL3Section('$techId', event)">
                                                    <div class="expandable__title">
                                                        <span class="expand-icon" id="icon-$techId"></span>
                                                        <span class="detail-title">Technical Details</span>
                                                    </div>
                                                </div>
                                                <div class="expandable__content technical-details" id="$techId" style="display: none;">
"@
                    foreach ($resource in ($rec.AffectedResources | Where-Object { $_.TechnicalDetails })) {
                        $escapedDetails = Encode-Html $resource.TechnicalDetails
                        $escapedResName = Encode-Html $resource.ResourceName
                        $html += "                                                    <div><strong>${escapedResName}:</strong> $escapedDetails</div>`n"
                    }
                    $html += @"
                                                </div>
                                            </div>
"@
                }
                
                # Solution section (plain text)
                if ($escapedSolution -and $escapedSolution -ne "See Azure Portal for remediation steps") {
                    $html += @"
                                            <div class="detail-section">
                                                <div class="detail-title">Recommended Action</div>
                                                <div class="detail-content">$escapedSolution</div>
                                            </div>
"@
                }
                
                # Benefits section (plain text)
                if ($escapedBenefits) {
                    $html += @"
                                            <div class="detail-section">
                                                <div class="detail-title">Potential Benefits</div>
                                                <div class="detail-content">$escapedBenefits</div>
                                            </div>
"@
                }
                
                # Remediation section (plain text)
                if ($escapedRemediation -and $escapedRemediation -ne $escapedSolution) {
                    $html += @"
                                            <div class="detail-section">
                                                <div class="detail-title">Remediation Steps</div>
                                                <div class="detail-content">$escapedRemediation</div>
                                            </div>
"@
                }
                
                # Learn more link (plain text)
                if ($rec.LearnMoreLink) {
                    $escapedLink = Encode-Html $rec.LearnMoreLink
                    $html += @"
                                            <div class="detail-section">
                                                <div class="detail-title">Learn More</div>
                                                <div class="detail-content">
                                                    <a href="$escapedLink" target="_blank">Learn more &rarr;</a>
                                                </div>
                                            </div>
"@
                }
                
                # Affected resources table (L4 - expandable)
                $resourcesId = "$recId-resources"
                $html += @"
                                            <div class="expandable expandable--collapsed detail-section">
                                                <div class="expandable__header" onclick="toggleL3Section('$resourcesId', event)">
                                                    <div class="expandable__title">
                                                        <span class="expand-icon" id="icon-$resourcesId"></span>
                                                        <span class="detail-title">Affected Resources ($($rec.AffectedResourceCount))</span>
                                                    </div>
                                                </div>
                                                <div class="expandable__content" id="$resourcesId" style="display: none;">
                                                    <table class="data-table data-table--sticky-header data-table--compact">
                                                    <thead>
                                                        <tr>
                                                            <th>Resource Name</th>
                                                            <th>Resource Group</th>
                                                            <th>Subscription</th>
                                                            <th>Technical Details</th>
"@
                if ($cat.Name -eq "Cost") {
                    $html += "                                                            <th>Monthly</th>`n"
                    $html += "                                                            <th>Annual</th>`n"
                }
                $html += @"
                                                        </tr>
                                                    </thead>
                                                    <tbody>
"@
                
                foreach ($resource in ($rec.AffectedResources | Sort-Object SubscriptionName, ResourceGroup, ResourceName)) {
                    $escapedResName = Encode-Html $resource.ResourceName
                    $escapedResGroup = Encode-Html $resource.ResourceGroup
                    $escapedSubName = Encode-Html $resource.SubscriptionName
                    $escapedTechDetails = Encode-Html $resource.TechnicalDetails
                    $resourceSubLower = if ($resource.SubscriptionName) { $resource.SubscriptionName.ToLower() } else { '' }
                    
                    $html += @"
                                                        <tr data-subscription="$resourceSubLower">
                                                            <td class="resource-name">$escapedResName</td>
                                                            <td>$escapedResGroup</td>
                                                            <td>$escapedSubName</td>
                                                            <td class="technical-details">$escapedTechDetails</td>
"@
                    if ($cat.Name -eq "Cost") {
                        $resourceCurrency = if ($resource.SavingsCurrency) { $resource.SavingsCurrency } else { $savingsCurrency }
                        $currencySymbol = if ($resourceCurrency -eq 'USD') { '$' } else { $resourceCurrency }
                        $resMonthlySavings = if ($resource.MonthlySavings -and $resource.MonthlySavings -gt 0) {
                            "$currencySymbol $([math]::Round($resource.MonthlySavings, 0).ToString('N0').Replace(',', ' '))"
                        } else { "-" }
                        $resAnnualSavings = if ($resource.PotentialSavings -and $resource.PotentialSavings -gt 0) {
                            "$currencySymbol $([math]::Round($resource.PotentialSavings, 0).ToString('N0').Replace(',', ' '))"
                        } else { "-" }
                        $html += "                                                            <td class='savings-amount'>$resMonthlySavings</td>`n"
                        $html += "                                                            <td class='savings-amount'>$resAnnualSavings</td>`n"
                    }
                    $html += "                                                        </tr>`n"
                }
                
                $html += @"
                                                    </tbody>
                                                </table>
                                                </div>
                                            </div>
                                        </div>
                                    </td>
                                </tr>
"@
            }
            
            $html += @"
                            </tbody>
                        </table>
"@
            
            $html += @"
            </div>
        </div>
"@
        }
        
        $html += @"
        </div>
"@
    }
    
    # JavaScript - using placeholder for && to avoid PowerShell issues
    $jsCode = @'
    </div>
    
    <script>
        function toggleCategory(header) {
            const parent = header.closest('.expandable');
            if (parent) {
                parent.classList.toggle('expandable--collapsed');
            }
        }
        
        function toggleRecRow(row, detailId) {
            const detailRow = document.getElementById(detailId);
            const icon = document.getElementById('icon-' + detailId);
            
            if (detailRow) {
                if (detailRow.style.display === 'none') {
                    detailRow.style.display = 'table-row';
                    if (icon) icon.style.transform = 'rotate(90deg)';
                    row.classList.add('expanded');
                } else {
                    detailRow.style.display = 'none';
                    if (icon) icon.style.transform = 'rotate(0deg)';
                    row.classList.remove('expanded');
                }
            }
        }
        
        function toggleL3Section(id, event) {
            if (event) {
                event.stopPropagation();
                event.preventDefault();
            }
            
            const content = document.getElementById(id);
            if (!content) {
                console.error('toggleL3Section: Content element not found:', id);
                return;
            }
            
            const expandable = content.closest('.expandable');
            if (!expandable) {
                console.error('toggleL3Section: Expandable parent not found for:', id);
                return;
            }
            
            const icon = document.getElementById('icon-' + id);
            
            const isCollapsed = expandable.classList.contains('expandable--collapsed');
            
            if (isCollapsed) {
                // Expanding: remove collapsed class and show content
                expandable.classList.remove('expandable--collapsed');
                // Use setProperty with !important to ensure content is visible
                content.style.setProperty('display', 'block', 'important');
                if (icon) icon.style.transform = 'rotate(90deg)';
            } else {
                // Collapsing: add collapsed class and hide content
                expandable.classList.add('expandable--collapsed');
                content.style.setProperty('display', 'none', 'important');
                if (icon) icon.style.transform = 'rotate(0deg)';
            }
        }
        
        // Filtering
        const searchFilter = document.getElementById('searchFilter');
        const impactFilter = document.getElementById('impactFilter');
        const subscriptionFilter = document.getElementById('subscriptionFilter');
        
        function applyFilters() {
            const searchText = searchFilter.value.toLowerCase();
            const impactValue = impactFilter.value;
            const subscriptionValue = subscriptionFilter.value.toLowerCase();
            const filterBySubscription = subscriptionValue !== 'all' && subscriptionValue !== '';
            
            // Track totals for recalculation
            let totalRecs = 0;
            let totalResources = 0;
            let riSavings = 0;
            let spSavings = 0;
            let otherCostSavings = 0;
            let categoryCounts = {
                cost: 0,
                security: 0,
                reliability: 0,
                operationalexcellence: 0,
                performance: 0
            };
            
            // Filter recommendation rows and count visible
            document.querySelectorAll('.category-section').forEach(section => {
                let visibleCards = 0;
                
                section.querySelectorAll('.rec-row').forEach(recRow => {
                    const searchable = recRow.getAttribute('data-searchable') || '';
                    const impact = recRow.getAttribute('data-impact');
                    const subs = (recRow.getAttribute('data-subscriptions') || '').toLowerCase();
                    const detailId = recRow.getAttribute('data-detail-id');
                    const rowCategory = recRow.getAttribute('data-category') || '';
                    const problemText = (recRow.querySelector('.rec-problem-cell')?.textContent || '').toLowerCase();
                    
                    // Get values - either from breakdown or total
                    let resources = parseInt(recRow.getAttribute('data-resources')) || 0;
                    let savings = parseFloat(recRow.getAttribute('data-savings')) || 0;
                    
                    // If filtering by subscription, use per-subscription breakdown
                    if (filterBySubscription) {
                        const breakdownStr = recRow.getAttribute('data-sub-breakdown');
                        if (breakdownStr) {
                            try {
                                const breakdown = JSON.parse(breakdownStr.replace(/&quot;/g, '"'));
                                if (breakdown[subscriptionValue]) {
                                    resources = breakdown[subscriptionValue].resources || 0;
                                    savings = breakdown[subscriptionValue].savings || 0;
                                } else {
                                    resources = 0;
                                    savings = 0;
                                }
                            } catch (e) {
                                console.error('Failed to parse breakdown:', e);
                            }
                        }
                    }
                    
                    const searchMatch = searchText === '' || searchable.includes(searchText);
                    const impactMatch = impactValue === 'all' || impact === impactValue;
                    const subMatch = !filterBySubscription || (subs && subs.includes(subscriptionValue));
                    
                    if (searchMatch PLACEHOLDER_AND impactMatch PLACEHOLDER_AND subMatch) {
                        recRow.classList.remove('hidden');
                        visibleCards++;
                        
                        // Accumulate totals using subscription-specific values
                        totalRecs++;
                        totalResources += resources;
                        
                        // Categorize savings: RI and SP are alternatives, not cumulative
                        if (rowCategory === 'cost' && savings > 0) {
                            if (problemText.includes('reserved instance')) {
                                riSavings += savings;
                            } else if (problemText.includes('savings plan')) {
                                spSavings += savings;
                            } else {
                                otherCostSavings += savings;
                            }
                        }
                        
                        if (categoryCounts.hasOwnProperty(rowCategory)) {
                            categoryCounts[rowCategory]++;
                        }
                        
                        // Update the visible resource count in the row
                        const resourceCell = recRow.querySelector('td:nth-child(4)');
                        if (resourceCell) resourceCell.textContent = resources;
                        
                        // Update savings cell if present
                        const savingsCell = recRow.querySelector('td:nth-child(3)');
                        if (savingsCell && savings > 0) {
                            const formatNumber = (n) => n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
                            const formatted = formatNumber(Math.round(savings));
                            savingsCell.textContent = '$ ' + formatted;
                        } else if (savingsCell && savings === 0) {
                            savingsCell.textContent = '-';
                        }
                        
                        // Filter L3 resource table rows by subscription
                        if (detailId) {
                            const detailRow = document.getElementById(detailId);
                            if (detailRow) {
                                // Show/hide individual resource rows
                                let visibleResourceCount = 0;
                                detailRow.querySelectorAll('tbody tr[data-subscription]').forEach(resourceRow => {
                                    const resSub = (resourceRow.getAttribute('data-subscription') || '').toLowerCase();
                                    if (!filterBySubscription || resSub === subscriptionValue) {
                                        resourceRow.classList.remove('hidden');
                                        visibleResourceCount++;
                                    } else {
                                        resourceRow.classList.add('hidden');
                                    }
                                });
                                
                                // Update the "Affected Resources (X)" count
                                const resourcesHeader = detailRow.querySelector('.detail-title');
                                if (resourcesHeader && resourcesHeader.textContent.includes('Affected Resources')) {
                                    resourcesHeader.textContent = `Affected Resources (${visibleResourceCount})`;
                                }
                                
                                // Handle detail row visibility
                                if (recRow.classList.contains('expanded')) {
                                    detailRow.style.display = 'table-row';
                                } else {
                                    detailRow.style.display = 'none';
                                }
                            }
                        }
                    } else {
                        recRow.classList.add('hidden');
                        // Hide detail row too
                        if (detailId) {
                            const detailRow = document.getElementById(detailId);
                            if (detailRow) {
                                detailRow.style.display = 'none';
                                recRow.classList.remove('expanded');
                            }
                        }
                    }
                });
                
                // Hide empty sections
                if (visibleCards === 0) {
                    section.classList.add('hidden');
                } else {
                    section.classList.remove('hidden');
                }
            });
            
            // Hide cost strategies section when filtering by subscription (data isn't recalculated)
            const costStrategiesSection = document.querySelector('.cost-strategies-section');
            if (costStrategiesSection) {
                if (subscriptionValue === 'all' || subscriptionValue === '') {
                    costStrategiesSection.classList.remove('hidden');
                } else {
                    costStrategiesSection.classList.add('hidden');
                }
            }
            
            // Calculate total savings: max(RI, SP) + other (RI and SP are alternatives, not cumulative)
            const totalSavings = Math.max(riSavings, spSavings) + otherCostSavings;
            
            // Update summary cards with recalculated values
            const formatNumber = (n) => n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
            
            const updateEl = (id, value) => {
                const el = document.getElementById(id);
                if (el) el.textContent = value;
            };
            
            updateEl('summary-total-recs', totalRecs);
            updateEl('summary-total-resources', totalResources);
            updateEl('summary-cost-count', categoryCounts.cost);
            updateEl('summary-security-count', categoryCounts.security);
            updateEl('summary-reliability-count', categoryCounts.reliability);
            updateEl('summary-operational-count', categoryCounts.operationalexcellence);
            updateEl('summary-performance-count', categoryCounts.performance);
            
            const savingsEl = document.getElementById('summary-total-savings');
            if (savingsEl) {
                savingsEl.textContent = '$ ' + formatNumber(Math.round(totalSavings));
            }
        }
        
        searchFilter.addEventListener('input', applyFilters);
        impactFilter.addEventListener('change', applyFilters);
        subscriptionFilter.addEventListener('change', applyFilters);
    </script>
</body>
</html>
'@
    $jsCode = $jsCode -replace 'PLACEHOLDER_AND', '&&'
    $html += $jsCode
    
    # Write to file
    $html | Out-File -FilePath $OutputPath -Encoding UTF8
    
    # Calculate advisor counts
    $advisorCount = $totalRecs
    $advisorHighCount = @($groupedRecs | Where-Object { $_.Impact -eq 'High' }).Count
    $advisorMediumCount = @($groupedRecs | Where-Object { $_.Impact -eq 'Medium' }).Count
    $advisorLowCount = @($groupedRecs | Where-Object { $_.Impact -eq 'Low' }).Count
    
    # Generate AI insights if requested
    $aiInsights = $null
    if ($AI) {
        Write-Verbose "Generating AI insights for cost analysis..."
        try {
            # Ensure ConvertTo-CostAIInsights is available
            if (-not (Get-Command -Name ConvertTo-CostAIInsights -ErrorAction SilentlyContinue)) {
                $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
                $helperPath = Join-Path $moduleRoot "Private\Helpers\ConvertTo-CostAIInsights.ps1"
                if (Test-Path $helperPath) {
                    . $helperPath
                }
            }
            
            if (Get-Command -Name ConvertTo-CostAIInsights -ErrorAction SilentlyContinue) {
                $aiInsights = ConvertTo-CostAIInsights -AdvisorRecommendations $AdvisorRecommendations -TopN $AITopN -MinSavings $AIMinSavings
                Write-Verbose "AI insights generated: $($aiInsights.summary.recommendation_count) recommendations"
            } else {
                Write-Warning "ConvertTo-CostAIInsights function not available. AI insights not generated."
            }
        }
        catch {
            Write-Warning "Failed to generate AI insights: $_"
        }
    }
    
    # Return both path and calculated savings data for reuse in Dashboard
    $result = @{
        OutputPath = $OutputPath
        AdvisorCount = $advisorCount
        AdvisorHighCount = $advisorHighCount
        AdvisorMediumCount = $advisorMediumCount
        AdvisorLowCount = $advisorLowCount
        TotalSavings = $totalSavings
        SavingsCurrency = $savingsCurrency
        RiTotal = $riTotal
        SpTotal = $spTotal
        OtherCostTotal = $otherCostTotal
        RecommendedStrategy = $recommendedStrategy
    }
    
    # Add AI insights if generated
    if ($aiInsights) {
        $result.AIInsights = $aiInsights
    }
    
    return $result
}