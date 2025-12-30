<#
.SYNOPSIS
    Performs comprehensive Azure security audit across multiple subscriptions.

.DESCRIPTION
    Scans Azure resources across specified subscriptions for CIS security compliance.
    Generates HTML reports including dashboard, security findings, and VM backup status.

.PARAMETER SubscriptionIds
    Array of subscription IDs to scan. If not specified, scans all enabled subscriptions.

.PARAMETER Categories
    Array of categories to scan: All, Storage, AppService, VM, ARC, Monitor, Network, SQL, KeyVault.
    Default: All

.PARAMETER OutputPath
    Path for report output folder. Default: output/{tenantId}-{timestamp} in module directory.

.PARAMETER ExportJson
    Also export findings as JSON file.

.PARAMETER PassThru
    Return AuditResult object instead of just generating report.

.PARAMETER IncludeLevel2
    Include Level 2 (L2) CIS controls in the scan. Level 2 controls are recommended only for critical data or high-security environments.

.PARAMETER CriticalStorageAccounts
    Array of storage account names that contain critical data. Used for Level 2 CMK control (3.12).

.PARAMETER SkipChangeTracking
    Skip collecting change tracking data. This can speed up the audit process.

.EXAMPLE
    Invoke-AzureSecurityAudit -Categories Storage, SQL

.EXAMPLE
    Invoke-AzureSecurityAudit -SubscriptionIds "sub-123", "sub-456" -ExportJson

.EXAMPLE
    Invoke-AzureSecurityAudit -Categories Storage -IncludeLevel2

.EXAMPLE
    Invoke-AzureSecurityAudit -Categories Storage -IncludeLevel2 -CriticalStorageAccounts "critical-storage-1", "critical-storage-2"
#>
function Invoke-AzureSecurityAudit {
    [CmdletBinding()]
    param(
        [string[]]$SubscriptionIds,
        
        [ValidateSet('All', 'Storage', 'AppService', 'VM', 'ARC', 'Monitor', 'Network', 'SQL', 'KeyVault')]
        [string[]]$Categories = @('All'),
        
        [string]$OutputPath,
        
        [switch]$ExportJson,
        
        [switch]$PassThru,
        
        [switch]$IncludeLevel2,
        
        [string[]]$CriticalStorageAccounts = @(),
        
        [switch]$SkipChangeTracking,
        
        [Parameter(Mandatory = $false)]
        [switch]$AI,
        
        [Parameter(Mandatory = $false)]
        [string]$OpenAIKey = $env:OPENAI_API_KEY,
        
        [Parameter(Mandatory = $false)]
        [string]$OpenAIModel = "gpt-4o-mini",
        
        [Parameter(Mandatory = $false)]
        [int]$AICostTopN = 15,
        
        [Parameter(Mandatory = $false)]
        [int]$AISecurityTopN = 20,
        
        [Parameter(Mandatory = $false)]
        [int]$AIAdvisorTopN = 15,
        
        [Parameter(Mandatory = $false)]
        [int]$AIRBACTopN = 20,
        
        [Parameter(Mandatory = $false)]
        [int]$AINetworkTopN = 20,
        
        [Parameter(Mandatory = $false)]
        [int]$AIEOLTopN = 20,
        
        [Parameter(Mandatory = $false)]
        [int]$AIChangeTrackingTopN = 20,
        
        [Parameter(Mandatory = $false)]
        [int]$AIVMBackupTopN = 20,
        
        [Parameter(Mandatory = $false)]
        [int]$AICostTrackingTopN = 20
    )
    
    $scanStart = Get-Date
    $allFindings = [System.Collections.Generic.List[PSObject]]::new()
    $allEOLFindings = [System.Collections.Generic.List[PSObject]]::new()
    $vmInventory = [System.Collections.Generic.List[PSObject]]::new()
    $advisorRecommendations = [System.Collections.Generic.List[PSObject]]::new()
    $changeTrackingData = [System.Collections.Generic.List[PSObject]]::new()
    $networkInventory = [System.Collections.Generic.List[PSObject]]::new()
    $costTrackingData = $null
    $eolStatus = [System.Collections.Generic.List[PSObject]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    
    # Get subscriptions
    $subscriptionResult = Get-SubscriptionsToScan -SubscriptionIds $SubscriptionIds -Errors $errors
    $subscriptions = $subscriptionResult.Subscriptions
    $errors = $subscriptionResult.Errors
    
    if ($subscriptions.Count -eq 0) {
        Write-Warning "No subscriptions found to scan."
        return
    }
    
    Write-Host "`n=== Starting Azure Governance Audit across $($subscriptions.Count) subscription(s) ===" -ForegroundColor Cyan
    
    # Define scanner functions
    $scanners = @{
        'Storage'    = { 
            param($subId, $subName) 
            Get-AzureStorageFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$IncludeLevel2 -CriticalStorageAccounts $CriticalStorageAccounts
        }
        'AppService' = { param($subId, $subName, $includeL2) Get-AzureAppServiceFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 }
        'VM'         = { param($subId, $subName, $includeL2) Get-AzureVirtualMachineFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 }
        'ARC'        = { param($subId, $subName) Get-AzureArcFindings -SubscriptionId $subId -SubscriptionName $subName }
        'Monitor'    = { param($subId, $subName) Get-AzureMonitorFindings -SubscriptionId $subId -SubscriptionName $subName }
        'Network'    = { param($subId, $subName, $includeL2) Get-AzureNetworkFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 }
        'SQL'        = { param($subId, $subName, $includeL2) Get-AzureSqlDatabaseFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 }
        'KeyVault'   = { param($subId, $subName, $includeL2) Get-AzureKeyVaultFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 }
    }
    
    # Determine categories to scan
    if ('All' -in $Categories) {
        $categoriesToScan = $scanners.Keys
    }
    else {
        $categoriesToScan = $Categories
    }
    
    # Get current tenant ID once to filter subscriptions
    $currentContext = Get-AzContext
    $currentTenantId = if ($currentContext -and $currentContext.Tenant) { $currentContext.Tenant.Id } else { $null }
    
    # Build subscription ID to Name mapping for report generation
    $subscriptionNames = @{}
    foreach ($sub in $subscriptions) {
        $subName = Get-SubscriptionDisplayName -Subscription $sub
        $subscriptionNames[$sub.Id] = $subName
        Write-Verbose "Mapped subscription: $($sub.Id) -> '$subName'"
    }
    Write-Verbose "SubscriptionNames hashtable has $($subscriptionNames.Count) entries"
    
    # Scan Security Findings
    Write-Host "`n=== Scanning Security Findings ===" -ForegroundColor Cyan
    $total = $subscriptions.Count
    $current = 0
    
    foreach ($sub in $subscriptions) {
        $current++
        
        # Skip subscriptions that don't belong to the current tenant
        if ($currentTenantId -and $sub.TenantId -ne $currentTenantId) {
            Write-Verbose "Skipping subscription $($sub.Name) ($($sub.Id)) - belongs to different tenant ($($sub.TenantId))"
            continue
        }
        
        $subDisplayName = Get-SubscriptionDisplayName -Subscription $sub
        Write-Host "`n  [$current/$total] Scanning: $subDisplayName" -ForegroundColor Gray
        
        # Run scanners for this subscription
        Invoke-ScannerForSubscription `
            -Subscription $sub `
            -CategoriesToScan $categoriesToScan `
            -Scanners $scanners `
            -IncludeLevel2:$IncludeLevel2 `
            -AllFindings $allFindings `
            -AllEOLFindings $allEOLFindings `
            -VMInventory $vmInventory `
            -Errors $errors
        
        # Update subscription name mapping after scanning (in case it was updated during context verification)
        $verifyContext = Get-AzContext
        if ($verifyContext -and $verifyContext.Subscription.Id -eq $sub.Id) {
            $subscriptionNameToUse = Get-SubscriptionDisplayName -Subscription $verifyContext.Subscription
            if (-not [string]::IsNullOrWhiteSpace($subscriptionNameToUse) -and $subscriptionNameToUse -ne "Unknown Subscription") {
                $subscriptionNames[$sub.Id] = $subscriptionNameToUse
            }
        }
    }
    
    # Build result object
    $tenantId = (Get-AzContext).Tenant.Id
    # Use HashSet for efficient unique resource counting
    $uniqueResourceIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($finding in $allFindings) {
        if ($finding.ResourceId) {
            [void]$uniqueResourceIds.Add($finding.ResourceId)
        }
    }
    $uniqueResources = $uniqueResourceIds.Count
    
    # Count findings by severity (only FAIL status) using helper function
    $findingsBySeverity = Get-FindingsBySeverity -Findings $allFindings -StatusFilter "FAIL"
    
    # Use dictionary for efficient category counting
    $findingsByCategory = @{}
    $failedFindingsList = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($finding in $allFindings) {
        if ($finding.Status -eq 'FAIL') {
            $failedFindingsList.Add($finding)
            $category = if ($finding.Category) { $finding.Category } else { "Unknown" }
            if (-not $findingsByCategory.ContainsKey($category)) {
                $findingsByCategory[$category] = 0
            }
            $findingsByCategory[$category]++
        }
    }
    
    # Calculate CIS Compliance Score
    # Note: Calculate is an approved PowerShell verb - PSScriptAnalyzer warning is a false positive
    function Calculate-CisComplianceScore {
        param(
            [array]$Findings,
            [switch]$IncludeLevel2
        )
        
        # Get severity weights and level multipliers from constants
        $severityWeights = Get-SeverityWeights
        $levelMultipliers = Get-LevelMultipliers
        
        # Filter findings (exclude ERROR and SKIPPED from score calculation) - use List for efficiency
        $scoredFindings = [System.Collections.Generic.List[PSObject]]::new()
        $statusValues = Get-StatusValues
        foreach ($finding in $Findings) {
            if (($finding.Status -eq $statusValues.PASS -or $finding.Status -eq $statusValues.FAIL) -and
                ($IncludeLevel2 -or $finding.CisLevel -ne (Get-CisLevels).LEVEL_2)) {
                $scoredFindings.Add($finding)
            }
        }
        
        if ($scoredFindings.Count -eq 0) {
            return @{
                OverallScore = 100
                L1Score = 100
                L2Score = $null
                ScoresByCategory = @{}
                TotalChecks = 0
                PassedChecks = 0
            }
        }
        
        $totalWeight = 0
        $passedWeight = 0
        $l1TotalWeight = 0
        $l1PassedWeight = 0
        $l2TotalWeight = 0
        $l2PassedWeight = 0
        
        # Track scores by category - use HashSet for unique categories
        $categoryScores = @{}
        $uniqueCategories = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($finding in $scoredFindings) {
            $cat = if ($finding.Category) { $finding.Category } else { "Unknown" }
            [void]$uniqueCategories.Add($cat)
        }
        
        foreach ($category in $uniqueCategories) {
            $categoryFindings = [System.Collections.Generic.List[PSObject]]::new()
            foreach ($finding in $scoredFindings) {
                $cat = if ($finding.Category) { $finding.Category } else { "Unknown" }
                if ($cat -eq $category) {
                    $categoryFindings.Add($finding)
                }
            }
            $catTotalWeight = 0
            $catPassedWeight = 0
            
            foreach ($finding in $categoryFindings) {
                $severityWeight = $severityWeights[$finding.Severity]
                $levelMultiplier = $levelMultipliers[$finding.CisLevel]
                $weight = $severityWeight * $levelMultiplier
                
                $catTotalWeight += $weight
                if ($finding.Status -eq 'PASS') {
                    $catPassedWeight += $weight
                }
            }
            
            $categoryScores[$category] = if ($catTotalWeight -gt 0) { 
                [math]::Round(($catPassedWeight / $catTotalWeight) * 100, 2) 
            } else { 
                100 
            }
        }
        
        foreach ($finding in $scoredFindings) {
            $severityWeight = $severityWeights[$finding.Severity]
            $levelMultiplier = $levelMultipliers[$finding.CisLevel]
            $weight = $severityWeight * $levelMultiplier
            
            $totalWeight += $weight
            if ($finding.Status -eq 'PASS') {
                $passedWeight += $weight
            }
            
            # Track L1 and L2 separately
            if ($finding.CisLevel -eq 'L1') {
                $l1TotalWeight += $weight
                if ($finding.Status -eq 'PASS') {
                    $l1PassedWeight += $weight
                }
            }
            elseif ($finding.CisLevel -eq 'L2') {
                $l2TotalWeight += $weight
                if ($finding.Status -eq 'PASS') {
                    $l2PassedWeight += $weight
                }
            }
        }
        
        $overallScore = if ($totalWeight -gt 0) { 
            [math]::Round(($passedWeight / $totalWeight) * 100, 2) 
        } else { 
            100 
        }
        
        $l1Score = if ($l1TotalWeight -gt 0) { 
            [math]::Round(($l1PassedWeight / $l1TotalWeight) * 100, 2) 
        } else { 
            100 
        }
        
        $l2Score = if ($l2TotalWeight -gt 0) { 
            [math]::Round(($l2PassedWeight / $l2TotalWeight) * 100, 2) 
        } else { 
            $null 
        }
        
        # Count passed and failed checks
        $statusValues = Get-StatusValues
        $passedChecks = 0
        $failedChecks = 0
        foreach ($finding in $scoredFindings) {
            if ($finding.Status -eq $statusValues.PASS) {
                $passedChecks++
            } elseif ($finding.Status -eq $statusValues.FAIL) {
                $failedChecks++
            }
        }
        
        return @{
            OverallScore = $overallScore
            L1Score = $l1Score
            L2Score = $l2Score
            ScoresByCategory = $categoryScores
            TotalChecks = $scoredFindings.Count
            PassedChecks = $passedChecks
            FailedChecks = $failedChecks
        }
    }
    
    # Calculate compliance scores
    $complianceScores = Calculate-CisComplianceScore -Findings $allFindings -IncludeLevel2:$IncludeLevel2
    
    # Ensure EOLFindings is converted to array for proper serialization
    $eolFindingsArray = @($allEOLFindings | Where-Object { $null -ne $_ })
    Write-Verbose "Converting EOLFindings: List count=$($allEOLFindings.Count), Array count=$($eolFindingsArray.Count)"
    
    # Debug: Log first finding if available
    if ($eolFindingsArray.Count -gt 0) {
        $firstFinding = $eolFindingsArray[0]
        Write-Verbose "Invoke-AzureSecurityAudit: First EOL finding - Component: $($firstFinding.Component), Severity: $($firstFinding.Severity), ResourceName: $($firstFinding.ResourceName)"
    }
    
    $result = [PSCustomObject]@{
        ScanStartTime           = $scanStart
        ScanEndTime             = Get-Date
        TenantId                = $tenantId
        SubscriptionsScanned    = $subscriptions.Id
        SubscriptionNames       = $subscriptionNames
        TotalResources          = $uniqueResources
        FindingsBySeverity      = $findingsBySeverity
        FindingsByCategory      = $findingsByCategory
        Findings                = $allFindings
        EOLFindings             = $eolFindingsArray
        VMInventory             = $vmInventory
        AdvisorRecommendations  = $advisorRecommendations
        ChangeTrackingData      = $changeTrackingData
        NetworkInventory        = $networkInventory
        CostTrackingData        = $costTrackingData
        RBACInventory           = $rbacInventory
        ComplianceScores        = $complianceScores
        EOLStatus               = @()
        Errors                  = $errors
        ToolVersion             = "2.0.0"
        AIAnalysis              = $null
    }
    
    # Collect Azure Advisor Recommendations
    Write-Host "`n=== Collecting Azure Advisor Recommendations ===" -ForegroundColor Cyan
    Collect-AdvisorRecommendations -Subscriptions $subscriptions -AdvisorRecommendations $advisorRecommendations -Errors $errors
    
    # Update result with latest advisor recommendations (ensure it's an array)
    $result.AdvisorRecommendations = @($advisorRecommendations)
    Write-Verbose "Updated result.AdvisorRecommendations with $($advisorRecommendations.Count) recommendations"
    
    # Collect Change Tracking Data (unless skipped)
    if (-not $SkipChangeTracking) {
        Write-Host "`n=== Collecting Change Tracking Data ===" -ForegroundColor Cyan
        Collect-ChangeTrackingData -Subscriptions $subscriptions -ChangeTrackingData $changeTrackingData -Errors $errors
        
        # Update result with latest change tracking data (ensure it's an array)
        $result.ChangeTrackingData = @($changeTrackingData)
        Write-Verbose "Updated result.ChangeTrackingData with $($changeTrackingData.Count) changes"
    } else {
        Write-Verbose "Skipping change tracking data collection as requested"
        $result.ChangeTrackingData = @()
    }

    # Collect Network Inventory
    Write-Host "`n=== Collecting Network Inventory ===" -ForegroundColor Cyan
    Collect-NetworkInventory -Subscriptions $subscriptions -NetworkInventory $networkInventory -Errors $errors
    
    # Update result with latest network inventory (ensure it's an array)
    $result.NetworkInventory = @($networkInventory)
    Write-Verbose "Updated result.NetworkInventory with $($networkInventory.Count) VNets"
    
    # Collect Cost Tracking Data
    try {
        Write-Host "`n=== Collecting Cost Data ===" -ForegroundColor Cyan
        $costTrackingData = Collect-CostData -Subscriptions $subscriptions -DaysToInclude 30 -Errors $errors
        $result.CostTrackingData = $costTrackingData
        Write-Verbose "Updated result.CostTrackingData with cost data for $($costTrackingData.SubscriptionCount) subscriptions"
    }
    catch {
        Write-Warning "Failed to collect cost tracking data: $_"
        $costTrackingData = @{}
        $result.CostTrackingData = $costTrackingData
    }

    # Collect RBAC Inventory
    $rbacInventory = $null
    try {
        Write-Host "`n=== Collecting RBAC/IAM Inventory ===" -ForegroundColor Cyan
        # Check if function exists, if not try to load it
        if (-not (Get-Command -Name Get-AzureRBACInventory -ErrorAction SilentlyContinue)) {
            $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $collectorPath = Join-Path $moduleRoot "Private\Collectors\Get-AzureRBACInventory.ps1"
            if (Test-Path $collectorPath) {
                try {
                    . $collectorPath
                }
                catch {
                    Write-Warning "Failed to load Get-AzureRBACInventory: $_"
                }
            }
        }
        
        if (Get-Command -Name Get-AzureRBACInventory -ErrorAction SilentlyContinue) {
            $subIdsForRBAC = @($subscriptions.Id)
            $rbacInventory = Get-AzureRBACInventory -SubscriptionIds $subIdsForRBAC -TenantId $tenantId
            Write-Host "  Found $($rbacInventory.Statistics.TotalAssignments) role assignments" -ForegroundColor Green
            # Update result with RBAC inventory
            $result.RBACInventory = $rbacInventory
            Write-Verbose "Updated result.RBACInventory with $($rbacInventory.Statistics.TotalAssignments) assignments"
        } else {
            Write-Warning "Get-AzureRBACInventory function not available"
        }
    }
    catch {
        Write-Warning "RBAC inventory collection failed: $_"
        Write-Verbose "RBAC collection error details: $($_.Exception.Message)"
    }

    # Collect EOL Status (using Microsoft's official EOL lists)
    try {
        $subIdsForEol = @($subscriptions.Id)
        if ($subIdsForEol.Count -gt 0) {
            Write-Host "`n=== Collecting EOL Status ===" -ForegroundColor Cyan
            Write-Verbose "Running EOL tracking across $($subIdsForEol.Count) subscription(s)"
            $eolResults = Get-AzureEOLStatus -SubscriptionIds $subIdsForEol
            if ($eolResults) {
                Write-Host "  Found $($eolResults.Count) EOL component(s)" -ForegroundColor Green
                foreach ($eolComponent in $eolResults) {
                    $eolStatus.Add($eolComponent)
                }
                
                # Convert EOL results to findings using shared helper function
                Convert-EOLResultsToFindings -EOLResults $eolResults -EOLFindings $allEOLFindings
                
                $result.EOLStatus = @($eolStatus)
                Write-Host "  Found $($allEOLFindings.Count) EOL findings" -ForegroundColor Green
                Write-Verbose "EOLTracking: Found $($eolStatus.Count) EOL component(s), created $($allEOLFindings.Count) total EOL findings"
            } else {
                Write-Host "  No EOL components found" -ForegroundColor Gray
            }
            
            # Update result.EOLFindings AFTER EOL tracking completes (it was set to empty array earlier)
            $eolFindingsArrayUpdated = @($allEOLFindings | Where-Object { $null -ne $_ })
            $result.EOLFindings = $eolFindingsArrayUpdated
            Write-Verbose "EOLTracking: Updated result.EOLFindings with $($eolFindingsArrayUpdated.Count) findings"
        }
    }
    catch {
        Write-Warning "EOL tracking failed: $_"
        Write-Verbose "EOL tracking error details: $($_.Exception.Message)"
        if ($_.Exception.InnerException) {
            Write-Verbose "EOL tracking inner exception: $($_.Exception.InnerException.Message)"
        }
    }
    
    # Generate reports
    $outputFolder = Generate-AuditReports -AuditResult $result -OutputPath $OutputPath -ExportJson:$ExportJson
    $dashboardPath = Join-Path $outputFolder "index.html"
    
    # Summary
    Write-Host "`n=== Scan Summary ===" -ForegroundColor Cyan
    Write-Host "Total Findings: $($allFindings.Count)" -ForegroundColor White
    Write-Host "  Critical: $($findingsBySeverity.Critical)" -ForegroundColor $(if ($findingsBySeverity.Critical -gt 0) { 'Red' } else { 'Green' })
    Write-Host "  High:     $($findingsBySeverity.High)" -ForegroundColor $(if ($findingsBySeverity.High -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host "  Medium:   $($findingsBySeverity.Medium)" -ForegroundColor White
    Write-Host "  Low:      $($findingsBySeverity.Low)" -ForegroundColor White
    Write-Host "Total EOL Findings: $($allEOLFindings.Count)" -ForegroundColor White
    if ($allEOLFindings.Count -gt 0) {
        $eolBySeverity = @{
            Critical = @($allEOLFindings | Where-Object { $_.Severity -eq 'Critical' }).Count
            High = @($allEOLFindings | Where-Object { $_.Severity -eq 'High' }).Count
            Medium = @($allEOLFindings | Where-Object { $_.Severity -eq 'Medium' }).Count
            Low = @($allEOLFindings | Where-Object { $_.Severity -eq 'Low' }).Count
        }
        Write-Host "  Critical: $($eolBySeverity.Critical)" -ForegroundColor $(if ($eolBySeverity.Critical -gt 0) { 'Red' } else { 'Green' })
        Write-Host "  High:     $($eolBySeverity.High)" -ForegroundColor $(if ($eolBySeverity.High -gt 0) { 'Yellow' } else { 'Green' })
        Write-Host "  Medium:   $($eolBySeverity.Medium)" -ForegroundColor $(if ($eolBySeverity.Medium -gt 0) { 'Yellow' } else { 'Green' })
        Write-Host "  Low:      $($eolBySeverity.Low)" -ForegroundColor $(if ($eolBySeverity.Low -gt 0) { 'Yellow' } else { 'Green' })
    }
    
    # VM Backup summary - use efficient counting
    if ($vmInventory.Count -gt 0) {
        $protectedVMs = 0
        foreach ($vm in $vmInventory) {
            if ($vm.BackupEnabled) {
                $protectedVMs++
            }
        }
        $unprotectedVMs = $vmInventory.Count - $protectedVMs
        Write-Host "`nVM Backup Status:" -ForegroundColor Cyan
        Write-Host "  Total VMs: $($vmInventory.Count)" -ForegroundColor White
        Write-Host "  Protected: $protectedVMs" -ForegroundColor Green
        Write-Host "  Unprotected: $unprotectedVMs" -ForegroundColor $(if ($unprotectedVMs -gt 0) { 'Yellow' } else { 'Green' })
    }
    
    # Advisor summary - use efficient counting
    if ($advisorRecommendations.Count -gt 0) {
        $advisorHighImpact = 0
        $advisorCostRecs = [System.Collections.Generic.List[PSObject]]::new()
        foreach ($rec in $advisorRecommendations) {
            if ($rec.Impact -eq 'High') {
                $advisorHighImpact++
            }
            if ($rec.Category -eq 'Cost') {
                $advisorCostRecs.Add($rec)
            }
        }
        $potentialSavings = 0
        foreach ($rec in $advisorCostRecs) {
            if ($rec.PotentialSavings) {
                $potentialSavings += $rec.PotentialSavings
            }
        }
        Write-Host "`nAzure Advisor:" -ForegroundColor Cyan
        Write-Host "  Recommendations: $($advisorRecommendations.Count)" -ForegroundColor White
        Write-Host "  High Impact: $advisorHighImpact" -ForegroundColor $(if ($advisorHighImpact -gt 0) { 'Yellow' } else { 'Green' })
        if ($potentialSavings -and $potentialSavings -gt 0) {
            Write-Host "  Potential Savings: `$$([math]::Round($potentialSavings, 0))/yr" -ForegroundColor Green
        }
    }
    
    # Change Tracking summary
    if ($changeTrackingData.Count -gt 0) {
        $highSecurityFlags = 0
        $mediumSecurityFlags = 0
        foreach ($change in $changeTrackingData) {
            if ($change.SecurityFlag -eq 'high') {
                $highSecurityFlags++
            } elseif ($change.SecurityFlag -eq 'medium') {
                $mediumSecurityFlags++
            }
        }
        Write-Host "`nChange Tracking:" -ForegroundColor Cyan
        Write-Host "  Total Changes: $($changeTrackingData.Count)" -ForegroundColor White
        Write-Host "  Security Alerts: $($highSecurityFlags + $mediumSecurityFlags) ($highSecurityFlags high, $mediumSecurityFlags medium)" -ForegroundColor $(if (($highSecurityFlags + $mediumSecurityFlags) -gt 0) { 'Yellow' } else { 'Green' })
    }

    # Network Inventory summary
    if ($networkInventory.Count -gt 0) {
        Write-Host "`nNetwork Inventory:" -ForegroundColor Cyan
        Write-Host "  Virtual Networks: $($networkInventory.Count)" -ForegroundColor White
        $subnetCount = 0
        foreach ($vnet in $networkInventory) {
            $subnetCount += $vnet.Subnets.Count
        }
        Write-Host "  Subnets: $subnetCount" -ForegroundColor White
    }
    
    # EOL Status summary
    if ($allEOLFindings.Count -gt 0) {
        $eolCritical = @($allEOLFindings | Where-Object { $_.Severity -eq 'Critical' }).Count
        $eolHigh = @($allEOLFindings | Where-Object { $_.Severity -eq 'High' }).Count
        $eolMedium = @($allEOLFindings | Where-Object { $_.Severity -eq 'Medium' }).Count
        $eolLow = @($allEOLFindings | Where-Object { $_.Severity -eq 'Low' }).Count
        $eolComponentCount = ($allEOLFindings | Select-Object -ExpandProperty Component -Unique).Count
        Write-Host "`nEOL Status:" -ForegroundColor Cyan
        Write-Host "  Components: $eolComponentCount" -ForegroundColor White
        Write-Host "  Total Findings: $($allEOLFindings.Count)" -ForegroundColor White
        Write-Host "  Critical: $eolCritical  High: $eolHigh  Medium: $eolMedium  Low: $eolLow" -ForegroundColor White
    }
    
    if ($errors.Count -gt 0) {
        Write-Host "`nErrors encountered: $($errors.Count)" -ForegroundColor Yellow
        foreach ($err in $errors) {
            Write-Host "  - $err" -ForegroundColor Red
        }
    }
    
    # Make dashboard link clickable (file:// URI format works in modern terminals)
    $dashboardUri = "file:///$($dashboardPath.Replace('\', '/'))"
    Write-Host "`nOpen dashboard: " -NoNewline
    Write-Host $dashboardUri -ForegroundColor Cyan
    
    # AI Analysis (if requested)
    if ($AI) {
        Write-Host "`n=== AI Analysis ===" -ForegroundColor Cyan
        
        if ([string]::IsNullOrWhiteSpace($OpenAIKey)) {
            Write-Warning "OpenAI API key not provided. Set via -OpenAIKey or OPENAI_API_KEY environment variable."
            Write-Warning "Skipping AI analysis."
        }
        else {
            try {
                # Ensure helper functions are loaded
                $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
                
                # Load all converter functions
                $converterFunctions = @(
                    @{ Name = "ConvertTo-AdvisorAIInsights"; Path = "Private\Helpers\ConvertTo-AdvisorAIInsights.ps1" }
                    @{ Name = "ConvertTo-SecurityAIInsights"; Path = "Private\Helpers\ConvertTo-SecurityAIInsights.ps1" }
                    @{ Name = "ConvertTo-RBACAIInsights"; Path = "Private\Helpers\ConvertTo-RBACAIInsights.ps1" }
                    @{ Name = "ConvertTo-NetworkAIInsights"; Path = "Private\Helpers\ConvertTo-NetworkAIInsights.ps1" }
                    @{ Name = "ConvertTo-EOLAIInsights"; Path = "Private\Helpers\ConvertTo-EOLAIInsights.ps1" }
                    @{ Name = "ConvertTo-ChangeTrackingAIInsights"; Path = "Private\Helpers\ConvertTo-ChangeTrackingAIInsights.ps1" }
                    @{ Name = "ConvertTo-VMBackupAIInsights"; Path = "Private\Helpers\ConvertTo-VMBackupAIInsights.ps1" }
                    @{ Name = "ConvertTo-CostTrackingAIInsights"; Path = "Private\Helpers\ConvertTo-CostTrackingAIInsights.ps1" }
                    @{ Name = "ConvertTo-CombinedPayload"; Path = "Private\Helpers\ConvertTo-CombinedPayload.ps1" }
                )
                
                foreach ($func in $converterFunctions) {
                    if (-not (Get-Command -Name $func.Name -ErrorAction SilentlyContinue)) {
                        $funcPath = Join-Path $moduleRoot $func.Path
                        if (Test-Path $funcPath) {
                            . $funcPath
                        }
                    }
                }
                
                # Load AI agent
                if (-not (Get-Command -Name Invoke-AzureArchitectAgent -ErrorAction SilentlyContinue)) {
                    $agentPath = Join-Path $moduleRoot "Public\Invoke-AzureArchitectAgent.ps1"
                    if (Test-Path $agentPath) {
                        . $agentPath
                    }
                }
                
                # Generate insights for each module
                $advisorInsights = $null
                $securityInsights = $null
                $rbacInsights = $null
                $networkInsights = $null
                $eolInsights = $null
                $changeTrackingInsights = $null
                $vmBackupInsights = $null
                $costTrackingInsights = $null
                
                # Advisor insights (comprehensive - all categories)
                if ($advisorRecommendations.Count -gt 0) {
                    Write-Host "  Generating Advisor insights..." -ForegroundColor Gray
                    if (Get-Command -Name ConvertTo-AdvisorAIInsights -ErrorAction SilentlyContinue) {
                        $advisorInsights = ConvertTo-AdvisorAIInsights -AdvisorRecommendations $advisorRecommendations -TopN $AIAdvisorTopN
                        Write-Host "    Advisor insights: $($advisorInsights.summary.total_recommendations) recommendations across all categories" -ForegroundColor Green
                    }
                }
                
                # Security insights
                if ($allFindings.Count -gt 0) {
                    Write-Host "  Generating security insights..." -ForegroundColor Gray
                    if (Get-Command -Name ConvertTo-SecurityAIInsights -ErrorAction SilentlyContinue) {
                        $securityInsights = ConvertTo-SecurityAIInsights -Findings $allFindings -TopN $AISecurityTopN
                        Write-Host "    Security insights: $($securityInsights.summary.total_findings) findings" -ForegroundColor Green
                    }
                }
                
                # RBAC insights
                if ($rbacInventory) {
                    Write-Host "  Generating RBAC insights..." -ForegroundColor Gray
                    if (Get-Command -Name ConvertTo-RBACAIInsights -ErrorAction SilentlyContinue) {
                        $rbacInsights = ConvertTo-RBACAIInsights -RBACData $rbacInventory -TopN $AIRBACTopN
                        Write-Host "    RBAC insights: $($rbacInsights.summary.total_assignments) assignments analyzed" -ForegroundColor Green
                    }
                }
                
                # Network insights
                if ($networkInventory.Count -gt 0) {
                    Write-Host "  Generating network insights..." -ForegroundColor Gray
                    if (Get-Command -Name ConvertTo-NetworkAIInsights -ErrorAction SilentlyContinue) {
                        $networkInsights = ConvertTo-NetworkAIInsights -NetworkInventory $networkInventory -TopN $AINetworkTopN
                        Write-Host "    Network insights: $($networkInsights.summary.total_vnets) VNets, $($networkInsights.summary.total_nsg_risks) NSG risks" -ForegroundColor Green
                    }
                }
                
                # EOL insights (always generate, even if empty, so AI knows EOL was checked)
                Write-Host "  Generating EOL insights..." -ForegroundColor Gray
                if (Get-Command -Name ConvertTo-EOLAIInsights -ErrorAction SilentlyContinue) {
                    # Ensure we always pass a valid array (even if empty)
                    $eolFindingsForAI = if ($eolFindingsArray -and $eolFindingsArray.Count -gt 0) {
                        @($eolFindingsArray)
                    } else {
                        @()
                    }
                    $eolInsights = ConvertTo-EOLAIInsights -EOLFindings $eolFindingsForAI -TopN $AIEOLTopN
                    if ($eolInsights.summary.total_findings -gt 0) {
                        Write-Host "    EOL insights: $($eolInsights.summary.total_findings) findings" -ForegroundColor Green
                    } else {
                        Write-Host "    EOL insights: No findings (EOL data checked)" -ForegroundColor Gray
                    }
                }
                
                # Change tracking insights
                if ($changeTrackingData.Count -gt 0) {
                    Write-Host "  Generating change tracking insights..." -ForegroundColor Gray
                    if (Get-Command -Name ConvertTo-ChangeTrackingAIInsights -ErrorAction SilentlyContinue) {
                        $changeTrackingInsights = ConvertTo-ChangeTrackingAIInsights -ChangeTrackingData $changeTrackingData -TopN $AIChangeTrackingTopN
                        Write-Host "    Change tracking insights: $($changeTrackingInsights.summary.total_changes) changes, $($changeTrackingInsights.summary.security_alerts) security alerts" -ForegroundColor Green
                    }
                }
                
                # VM Backup insights
                if ($vmInventory.Count -gt 0) {
                    Write-Host "  Generating VM backup insights..." -ForegroundColor Gray
                    if (Get-Command -Name ConvertTo-VMBackupAIInsights -ErrorAction SilentlyContinue) {
                        $vmBackupInsights = ConvertTo-VMBackupAIInsights -VMInventory $vmInventory -TopN $AIVMBackupTopN
                        Write-Host "    VM backup insights: $($vmBackupInsights.summary.total_vms) VMs, $($vmBackupInsights.summary.unprotected_vms) unprotected" -ForegroundColor Green
                    }
                }
                
                # Cost tracking insights (actual spending data)
                if ($costTrackingData) {
                    Write-Host "  Generating cost tracking insights..." -ForegroundColor Gray
                    if (Get-Command -Name ConvertTo-CostTrackingAIInsights -ErrorAction SilentlyContinue) {
                        $costTrackingInsights = ConvertTo-CostTrackingAIInsights -CostTrackingData $costTrackingData -TopN $AICostTrackingTopN
                        $costValue = $costTrackingInsights.summary.total_cost
                        $currency = $costTrackingInsights.summary.currency
                        Write-Host "    Cost tracking insights: $currency $([math]::Round($costValue, 2)) total spending" -ForegroundColor Green
                    }
                }
                
                # Build combined payload
                if ($advisorInsights -or $securityInsights -or $rbacInsights -or $networkInsights -or $eolInsights -or $changeTrackingInsights -or $vmBackupInsights -or $costTrackingInsights) {
                    Write-Host "  Building combined payload..." -ForegroundColor Gray
                    if (Get-Command -Name ConvertTo-CombinedPayload -ErrorAction SilentlyContinue) {
                        $combinedPayload = ConvertTo-CombinedPayload `
                            -AdvisorInsights $advisorInsights `
                            -SecurityInsights $securityInsights `
                            -RBACInsights $rbacInsights `
                            -NetworkInsights $networkInsights `
                            -EOLInsights $eolInsights `
                            -ChangeTrackingInsights $changeTrackingInsights `
                            -VMBackupInsights $vmBackupInsights `
                            -CostTrackingInsights $costTrackingInsights `
                            -SubscriptionCount $subscriptions.Count
                        
                        $jsonPayload = $combinedPayload | ConvertTo-Json -Depth 10
                        
                        # Save payload if requested
                        $payloadFile = Join-Path $outputFolder "AI_Insights_Payload_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').json"
                        $jsonPayload | Out-File $payloadFile -Encoding UTF8
                        Write-Host "    Payload saved: $payloadFile" -ForegroundColor Gray
                        
                        # Call AI agent
                        Write-Host "  Calling AI agent..." -ForegroundColor Gray
                        if (Get-Command -Name Invoke-AzureArchitectAgent -ErrorAction SilentlyContinue) {
                            $aiResult = Invoke-AzureArchitectAgent `
                                -GovernanceDataJson $jsonPayload `
                                -ApiKey $OpenAIKey `
                                -Model $OpenAIModel `
                                -OutputPath $outputFolder
                            
                            if ($aiResult.Success) {
                                Write-Host "    AI analysis complete" -ForegroundColor Green
                                if ($aiResult.Metadata.Cost) {
                                    $cost = $aiResult.Metadata.Cost
                                    Write-Host "      Cost: `$$($cost.Total.ToString('F4')) total" -ForegroundColor Gray
                                    Write-Host "        Input: `$$($cost.Input.ToString('F4'))" -ForegroundColor Gray
                                    Write-Host "        Output: `$$($cost.Output.ToString('F4'))" -ForegroundColor Gray
                                } else {
                                    # Fallback to EstimatedCost for backward compatibility
                                    Write-Host "      Estimated cost: `$$($aiResult.Metadata.EstimatedCost.ToString('F4'))" -ForegroundColor Gray
                                }
                                
                                # Add AI results to return object
                                $result.AIAnalysis = $aiResult
                            } else {
                                Write-Warning "AI analysis failed: $($aiResult.Error)"
                            }
                        } else {
                            Write-Warning "Invoke-AzureArchitectAgent function not available."
                        }
                    } else {
                        Write-Warning "ConvertTo-CombinedPayload function not available."
                    }
                } else {
                    Write-Warning "No insights generated. Skipping AI analysis."
                }
            }
            catch {
                Write-Warning "AI analysis failed: $_"
                Write-Verbose "AI analysis error details: $($_.Exception.Message)"
            }
        }
    }
    
    if ($PassThru) {
        return $result
    }
}
