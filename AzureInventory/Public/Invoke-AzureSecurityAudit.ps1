<#
.SYNOPSIS
    Performs comprehensive Azure security audit across multiple subscriptions.

.DESCRIPTION
    Scans Azure resources across specified subscriptions for CIS security compliance.
    Generates HTML and optionally JSON reports with findings.

.PARAMETER SubscriptionIds
    Array of subscription IDs to scan. If not specified, scans all enabled subscriptions.

.PARAMETER Categories
    Array of categories to scan: All, Storage, AppService, VM, ARC, Monitor, Network, SQL.
    Default: All

.PARAMETER OutputPath
    Path for HTML report output. Default: timestamped file in current directory.

.PARAMETER ExportJson
    Also export findings as JSON file.

.PARAMETER PassThru
    Return AuditResult object instead of just generating report.

.PARAMETER IncludeLevel2
    Include Level 2 (L2) CIS controls in the scan. Level 2 controls are recommended only for critical data or high-security environments.

.PARAMETER CriticalStorageAccounts
    Array of storage account names that contain critical data. Used for Level 2 CMK control (3.12).

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
        
        [ValidateSet('All', 'Storage', 'AppService', 'VM', 'ARC', 'Monitor', 'Network', 'SQL')]
        [string[]]$Categories = @('All'),
        
        [string]$OutputPath,
        
        [switch]$ExportJson,
        
        [switch]$PassThru,
        
        [switch]$IncludeLevel2,
        
        [string[]]$CriticalStorageAccounts = @()
    )
    
    $scanStart = Get-Date
    $allFindings = [System.Collections.Generic.List[PSObject]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    
    # Get subscriptions
    if (-not $SubscriptionIds -or $SubscriptionIds.Count -eq 0) {
        try {
            # Get current tenant from context to avoid cross-tenant authentication issues
            $currentContext = Get-AzContext
            if (-not $currentContext) {
                Write-Error "No Azure context found. Please run Connect-AuditEnvironment first."
                return
            }
            
            if ($currentContext.Tenant) {
                $currentTenantId = $currentContext.Tenant.Id
                Write-Verbose "Filtering subscriptions to current tenant: $currentTenantId"
                
                # Suppress warnings about other tenants during subscription retrieval
                $originalWarningPreference = $WarningPreference
                $WarningPreference = 'SilentlyContinue'
                
                try {
                    # Use -TenantId parameter to only query the current tenant (avoids MFA prompts for other tenants)
                    $allSubscriptions = Get-AzSubscription -TenantId $currentTenantId -ErrorAction Stop
                    $subscriptions = $allSubscriptions | Where-Object { 
                        $_.State -eq 'Enabled' -and $_.TenantId -eq $currentTenantId
                    }
                }
                finally {
                    $WarningPreference = $originalWarningPreference
                }
            }
            else {
                Write-Warning "No tenant information found in context. Attempting to get all enabled subscriptions..."
                $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
            }
        }
        catch {
            Write-Error "Failed to retrieve subscriptions. Ensure you are connected to Azure: $_"
            return
        }
    }
    else {
        $subscriptions = @()
        foreach ($subId in $SubscriptionIds) {
            try {
                $sub = Get-AzSubscription -SubscriptionId $subId -ErrorAction Stop
                if ($sub) {
                    $subscriptions += $sub
                }
            }
            catch {
                $errors.Add("Failed to retrieve subscription $subId : $_")
            }
        }
    }
    
    if ($subscriptions.Count -eq 0) {
        Write-Warning "No subscriptions found to scan."
        return
    }
    
    Write-Host "`nStarting Azure Security Audit across $($subscriptions.Count) subscription(s)..." -ForegroundColor Cyan
    
    # Define scanner functions
    $scanners = @{
        'Storage'    = { 
            param($subId, $subName) 
            Get-StorageAccountFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$IncludeLevel2 -CriticalStorageAccounts $CriticalStorageAccounts
        }
        'AppService' = { param($subId, $subName, $includeL2) Get-AppServiceFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 }
        'VM'         = { param($subId, $subName, $includeL2) Get-VirtualMachineFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 }
        'ARC'        = { param($subId, $subName) Get-AzureArcFindings -SubscriptionId $subId -SubscriptionName $subName }
        'Monitor'    = { param($subId, $subName) Get-AzureMonitorFindings -SubscriptionId $subId -SubscriptionName $subName }
        'Network'    = { param($subId, $subName, $includeL2) Get-NetworkSecurityFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 }
        'SQL'        = { param($subId, $subName, $includeL2) Get-SqlDatabaseFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 }
    }
    
    # Determine categories to scan
    if ('All' -in $Categories) {
        $categoriesToScan = $scanners.Keys
    }
    else {
        $categoriesToScan = $Categories
    }
    
    # Scan each subscription
    $total = $subscriptions.Count
    $current = 0
    
    # Get current tenant ID once to filter subscriptions
    $currentContext = Get-AzContext
    $currentTenantId = if ($currentContext -and $currentContext.Tenant) { $currentContext.Tenant.Id } else { $null }
    
    # Build subscription ID to Name mapping for report generation
    $subscriptionNames = @{}
    foreach ($sub in $subscriptions) {
        $subName = if ([string]::IsNullOrWhiteSpace($sub.Name)) { $sub.Id } else { $sub.Name }
        $subscriptionNames[$sub.Id] = $subName
        Write-Verbose "Mapped subscription: $($sub.Id) -> '$subName'"
    }
    Write-Verbose "SubscriptionNames hashtable has $($subscriptionNames.Count) entries"
    
    # Suppress warnings about other tenants during scanning
    $originalWarningPreference = $WarningPreference
    
    foreach ($sub in $subscriptions) {
        $current++
        
        # Skip subscriptions that don't belong to the current tenant
        if ($currentTenantId -and $sub.TenantId -ne $currentTenantId) {
            Write-Verbose "Skipping subscription $($sub.Name) ($($sub.Id)) - belongs to different tenant ($($sub.TenantId))"
            continue
        }
        
        # Get subscription display name (use ID as fallback if name is empty)
        $subDisplayName = if ([string]::IsNullOrWhiteSpace($sub.Name)) { $sub.Id } else { $sub.Name }
        Write-Host "`n[$current/$total] Scanning: $subDisplayName ($($sub.Id))" -ForegroundColor Yellow
        
        # Suppress warnings during context switching
        $WarningPreference = 'SilentlyContinue'
        $subscriptionNameToUse = $null
        try {
            if (-not (Get-SubscriptionContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue)) {
                Write-Warning "Failed to set context for subscription $subDisplayName ($($sub.Id)) - skipping"
                $errors.Add("Failed to set context for subscription $subDisplayName ($($sub.Id))")
                continue
            }
            
            # Verify context was set correctly and get subscription name from context
            $verifyContext = Get-AzContext
            if ($verifyContext.Subscription.Id -ne $sub.Id) {
                Write-Warning "Context verification failed: Expected $($sub.Id), got $($verifyContext.Subscription.Id) - skipping"
                $errors.Add("Context verification failed for subscription $subDisplayName ($($sub.Id))")
                continue
            }
            
            # Use subscription name from verified context (more reliable than $sub.Name)
            $subscriptionNameToUse = if ($verifyContext.Subscription.Name) { 
                $verifyContext.Subscription.Name 
            } elseif ($sub.Name) { 
                $sub.Name 
            } else { 
                $sub.Id 
            }
            
            # Update subscription name mapping with verified name
            $subscriptionNames[$sub.Id] = $subscriptionNameToUse
            Write-Verbose "Context verified: $subscriptionNameToUse ($($verifyContext.Subscription.Id))"
            
            # Verify we can actually read resources in this subscription
            try {
                $testResource = Get-AzResource -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($null -eq $testResource) {
                    Write-Verbose "No resources found or unable to read resources in subscription $subscriptionNameToUse"
                }
            }
            catch {
                Write-Verbose "Warning: May have limited permissions in subscription ${subscriptionNameToUse}: $_"
            }
        }
        catch {
            Write-Warning "Failed to set context for subscription $subDisplayName ($($sub.Id)): $_ - skipping"
            $errors.Add("Failed to set context for subscription $subDisplayName ($($sub.Id)): $_")
            continue
        }
        finally {
            $WarningPreference = $originalWarningPreference
        }
        
        foreach ($category in $categoriesToScan) {
            if (-not $scanners.ContainsKey($category)) {
                Write-Warning "Unknown category: $category"
                continue
            }
            
            Write-Host "  - $category..." -NoNewline
            try {
                # Pass IncludeLevel2 parameter to scanner functions
                # Use subscriptionNameToUse which comes from verified context
                $findings = & $scanners[$category] -subId $sub.Id -subName $subscriptionNameToUse -includeL2:$IncludeLevel2
                
                # Handle null or empty results
                if ($null -eq $findings) {
                    $findings = @()
                }
                
                # AddRange requires IEnumerable, so convert array to list if needed
                if ($findings -is [System.Array]) {
                    foreach ($finding in $findings) {
                        if ($null -ne $finding) {
                            $allFindings.Add($finding)
                        }
                    }
                } elseif ($findings -is [System.Collections.Generic.List[PSObject]]) {
                    $allFindings.AddRange($findings)
                } else {
                    # Fallback: try to enumerate
                    foreach ($finding in $findings) {
                        if ($null -ne $finding) {
                            $allFindings.Add($finding)
                        }
                    }
                }
                # Filter out null findings
                $validFindings = @($findings | Where-Object { $null -ne $_ })
                
                # Debug: show first finding's properties
                if ($validFindings.Count -gt 0) {
                    $firstFinding = $validFindings[0]
                    Write-Verbose "$category - First finding ResourceId: '$($firstFinding.ResourceId)', ResourceName: '$($firstFinding.ResourceName)'"
                }
                
                # Count unique resources using hashtable (reliable method)
                $uniqueResourceIds = @{}
                $failCount = 0
                
                foreach ($finding in $validFindings) {
                    # Count unique resources by ResourceId or ResourceName+ResourceGroup
                    $resourceKey = $null
                    if ($finding.PSObject.Properties.Name -contains 'ResourceId' -and -not [string]::IsNullOrWhiteSpace($finding.ResourceId)) {
                        $resourceKey = $finding.ResourceId
                    }
                    elseif ($finding.PSObject.Properties.Name -contains 'ResourceName' -and -not [string]::IsNullOrWhiteSpace($finding.ResourceName)) {
                        $rg = if ($finding.PSObject.Properties.Name -contains 'ResourceGroup') { $finding.ResourceGroup } else { "" }
                        $resourceKey = "$($finding.ResourceName)|$rg"
                    }
                    
                    if ($resourceKey -and -not $uniqueResourceIds.ContainsKey($resourceKey)) {
                        $uniqueResourceIds[$resourceKey] = $true
                    }
                    
                    # Count failures
                    if ($finding.PSObject.Properties.Name -contains 'Status' -and $finding.Status -eq 'FAIL') {
                        $failCount++
                    }
                }
                
                $uniqueResources = $uniqueResourceIds.Count
                $totalChecks = $validFindings.Count
                
                # Format output message
                $color = if ($failCount -gt 0) { 'Red' } else { 'Green' }
                if ($totalChecks -eq 0) {
                    Write-Host " 0 resources (0 checks)" -ForegroundColor Gray
                }
                else {
                    $resourceWord = if ($uniqueResources -eq 1) { "resource" } else { "resources" }
                    $checkWord = if ($totalChecks -eq 1) { "check" } else { "checks" }
                    Write-Host " $uniqueResources $resourceWord evaluated against $totalChecks $checkWord ($failCount failures)" -ForegroundColor $color
                }
            }
            catch {
                Write-Host " ERROR: $_" -ForegroundColor Red
                $errors.Add("$category scan failed for ${subscriptionNameToUse}: $_")
                
                # Check if it's a permissions error
                if ($_.Exception.Message -match 'authorization|permission|access|forbidden|unauthorized' -or 
                    $_.Exception.Message -match '403|401') {
                    Write-Host "    [WARNING] This may be a permissions issue. Ensure you have Reader role on subscription ${subscriptionNameToUse}" -ForegroundColor Yellow
                }
            }
        }
    }
    
    # Build result object
    $tenantId = (Get-AzContext).Tenant.Id
    $uniqueResources = ($allFindings | Select-Object -Unique ResourceId).Count
    
    # Count findings by severity (only FAIL status)
    # Use explicit count to ensure we always get a number, not null
    $criticalCount = ($allFindings | Where-Object { $_.Severity -eq 'Critical' -and $_.Status -eq 'FAIL' }).Count
    $highCount = ($allFindings | Where-Object { $_.Severity -eq 'High' -and $_.Status -eq 'FAIL' }).Count
    $mediumCount = ($allFindings | Where-Object { $_.Severity -eq 'Medium' -and $_.Status -eq 'FAIL' }).Count
    $lowCount = ($allFindings | Where-Object { $_.Severity -eq 'Low' -and $_.Status -eq 'FAIL' }).Count
    
    # Ensure all values are integers (handle null/empty cases)
    $findingsBySeverity = @{
        Critical = if ($null -eq $criticalCount -or $criticalCount -eq '') { 0 } else { [int]$criticalCount }
        High     = if ($null -eq $highCount -or $highCount -eq '') { 0 } else { [int]$highCount }
        Medium   = if ($null -eq $mediumCount -or $mediumCount -eq '') { 0 } else { [int]$mediumCount }
        Low      = if ($null -eq $lowCount -or $lowCount -eq '') { 0 } else { [int]$lowCount }
    }
    
    $findingsByCategory = @{}
    $failedFindings = $allFindings | Where-Object { $_.Status -eq 'FAIL' }
    foreach ($category in ($failedFindings | Select-Object -ExpandProperty Category -Unique)) {
        $findingsByCategory[$category] = ($failedFindings | Where-Object { $_.Category -eq $category }).Count
    }
    
    # Calculate CIS Compliance Score
    function Calculate-CisComplianceScore {
        param(
            [array]$Findings,
            [switch]$IncludeLevel2
        )
        
        # Severity weights (Critical issues are more important)
        $severityWeights = @{
            'Critical' = 4
            'High'     = 3
            'Medium'   = 2
            'Low'      = 1
        }
        
        # CIS Level multipliers (L1 is mandatory, L2 is optional)
        $levelMultipliers = @{
            'L1'  = 2.0
            'L2'  = 1.0
            'N/A' = 1.0
        }
        
        # Filter findings (exclude ERROR and SKIPPED from score calculation)
        $scoredFindings = $Findings | Where-Object { 
            $_.Status -in @('PASS', 'FAIL') -and
            ($IncludeLevel2 -or $_.CisLevel -ne 'L2')
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
        
        # Track scores by category
        $categoryScores = @{}
        $categories = $scoredFindings | Select-Object -ExpandProperty Category -Unique
        
        foreach ($category in $categories) {
            $categoryFindings = $scoredFindings | Where-Object { $_.Category -eq $category }
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
        
        return @{
            OverallScore = $overallScore
            L1Score = $l1Score
            L2Score = $l2Score
            ScoresByCategory = $categoryScores
            TotalChecks = $scoredFindings.Count
            PassedChecks = ($scoredFindings | Where-Object { $_.Status -eq 'PASS' }).Count
            FailedChecks = ($scoredFindings | Where-Object { $_.Status -eq 'FAIL' }).Count
        }
    }
    
    # Calculate compliance scores
    $complianceScores = Calculate-CisComplianceScore -Findings $allFindings -IncludeLevel2:$IncludeLevel2
    
    $result = [PSCustomObject]@{
        ScanStartTime        = $scanStart
        ScanEndTime          = Get-Date
        TenantId             = $tenantId
        SubscriptionsScanned = $subscriptions.Id
        SubscriptionNames    = $subscriptionNames
        TotalResources       = $uniqueResources
        FindingsBySeverity   = $findingsBySeverity
        FindingsByCategory   = $findingsByCategory
        Findings             = $allFindings
        ComplianceScores     = $complianceScores
        Errors               = $errors
        ToolVersion          = "1.0.0"
    }
    
    # Generate reports
    if (-not $OutputPath) {
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $OutputPath = Join-Path (Get-Location).Path "AzureSecurityAudit_$timestamp.html"
    }
    else {
        # Ensure OutputPath is absolute
        if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
            $OutputPath = Join-Path (Get-Location).Path $OutputPath
        }
    }
    
    try {
        $reportPath = Export-SecurityReport -AuditResult $result -OutputPath $OutputPath
        Write-Host "`nHTML Report: $reportPath" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to generate HTML report: $_"
    }
    
    if ($ExportJson) {
        $jsonPath = $OutputPath -replace '\.html$', '.json'
        try {
            $result | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
            Write-Host "JSON Export: $jsonPath" -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to export JSON: $_"
        }
    }
    
    # Summary
    Write-Host "`n=== Scan Summary ===" -ForegroundColor Cyan
    Write-Host "Total Findings: $($allFindings.Count)" -ForegroundColor White
    Write-Host "  Critical: $($findingsBySeverity.Critical)" -ForegroundColor $(if ($findingsBySeverity.Critical -gt 0) { 'Red' } else { 'Green' })
    Write-Host "  High:     $($findingsBySeverity.High)" -ForegroundColor $(if ($findingsBySeverity.High -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host "  Medium:   $($findingsBySeverity.Medium)" -ForegroundColor White
    Write-Host "  Low:      $($findingsBySeverity.Low)" -ForegroundColor White
    
    if ($errors.Count -gt 0) {
        Write-Host "`nErrors encountered: $($errors.Count)" -ForegroundColor Yellow
        foreach ($error in $errors) {
            Write-Host "  - $error" -ForegroundColor Red
        }
    }
    
    if ($PassThru) {
        return $result
    }
}


