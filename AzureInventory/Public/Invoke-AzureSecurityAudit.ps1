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
        
        [switch]$SkipChangeTracking
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
    $eolFindingsArray = @()
    if ($allEOLFindings -and $allEOLFindings.Count -gt 0) {
        if ($allEOLFindings -is [System.Collections.Generic.List[PSObject]]) {
            # Convert List to array by iterating
            foreach ($finding in $allEOLFindings) {
                if ($null -ne $finding) {
                    $eolFindingsArray += $finding
                }
            }
        } elseif ($allEOLFindings -is [System.Array]) {
            $eolFindingsArray = $allEOLFindings
        } elseif ($allEOLFindings -is [System.Collections.IEnumerable] -and $allEOLFindings -isnot [string]) {
            foreach ($finding in $allEOLFindings) {
                if ($null -ne $finding) {
                    $eolFindingsArray += $finding
                }
            }
        } else {
            $eolFindingsArray = @($allEOLFindings)
        }
    }
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
        CostTrackingData        = $null
        ComplianceScores        = $complianceScores
        EOLStatus               = @()
        Errors                  = $errors
        ToolVersion             = "2.0.0"
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
        $result.CostTrackingData = @{}
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
            $eolFindingsArrayUpdated = @()
            if ($allEOLFindings -and $allEOLFindings.Count -gt 0) {
                if ($allEOLFindings -is [System.Collections.Generic.List[PSObject]]) {
                    foreach ($finding in $allEOLFindings) {
                        if ($null -ne $finding) {
                            $eolFindingsArrayUpdated += $finding
                        }
                    }
                } elseif ($allEOLFindings -is [System.Array]) {
                    $eolFindingsArrayUpdated = $allEOLFindings
                } elseif ($allEOLFindings -is [System.Collections.IEnumerable] -and $allEOLFindings -isnot [string]) {
                    foreach ($finding in $allEOLFindings) {
                        if ($null -ne $finding) {
                            $eolFindingsArrayUpdated += $finding
                        }
                    }
                } else {
                    $eolFindingsArrayUpdated = @($allEOLFindings)
                }
            }
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
    
    if ($PassThru) {
        return $result
    }
}
