# Init-Local.ps1 - Initiera och ladda alla modulfunktioner
# Kör detta skript för att ladda alla funktioner direkt utan att behöva installera modulen
# Laddar automatiskt om funktioner om de redan finns
# 
# VIKTIGT: Du MÅSTE köra med punkt och mellanslag:
#   . .\Init-Local.ps1
# 
# Om du kör .\Init-Local.ps1 (utan punkt) fungerar det INTE!

param()

$ModuleRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }

# Load .env file if it exists (to get OPENAI_MODEL, OPENAI_API_KEY, AZURE_*, etc.)
$envFilePath = Join-Path $ModuleRoot ".env"
if (Test-Path $envFilePath) {
    Write-Verbose "Loading .env file: $envFilePath"
    $envVarsLoaded = 0
    Get-Content $envFilePath -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
        $line = $_.Trim() -replace '^["\x27](.*)["\x27]$', '$1'
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { return }
        
        if ($line -match '^([^=]+)=(.*)$') {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            $value = $value -replace '^["\x27](.*)["\x27]$', '$1'
            
            # Load Azure and OpenAI environment variables
            if ($key -match '^(AZURE_|OPENAI_)') {
                Set-Item -Path "env:$key" -Value $value -ErrorAction SilentlyContinue
                $envVarsLoaded++
                Write-Verbose "Loaded $key from .env file"
            }
        }
    }
    if ($envVarsLoaded -gt 0) {
        Write-Verbose "Loaded $envVarsLoaded environment variable(s) from .env file"
    }
}

# Varna om skriptet körs utan dot-source
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.Line -notmatch '^\s*\.\s+') {
    Write-Host "`n[ERROR] Script must be run with dot-source!" -ForegroundColor Red
    Write-Host "Use: . .\Init-Local.ps1" -ForegroundColor Yellow
    Write-Host "(Note the dot and space before the script name)`n" -ForegroundColor Yellow
    Write-Host "Current command: $($MyInvocation.Line)" -ForegroundColor Gray
    return
}

Write-Host "Initializing module - loading all functions..." -ForegroundColor Cyan

# Ta bort alla befintliga funktioner från modulen först
Write-Host "  Removing existing functions..." -ForegroundColor Gray
$functionsToRemove = @(
    # Public functions
    'Connect-AuditEnvironment',
    'Invoke-AzureSecurityAudit',
    'Export-SecurityReport',
    'Export-DashboardReport',
    'Export-VMBackupReport',
    'Export-AdvisorReport',
    'Export-ChangeTrackingReport',
    'Export-NetworkInventoryReport',
    'Export-CostTrackingReport',
    'Export-EOLReport',
    'Export-RBACReport',
    'Invoke-AzureArchitectAgent',
    # Helper functions
    'Get-SubscriptionContext',
    'Invoke-AzureApiWithRetry',
    'Invoke-WithSuppressedWarnings',
    'Invoke-WithErrorHandling',
    'New-SecurityFinding',
    'New-EOLFinding',
    'Get-SubscriptionDisplayName',
    'Get-FindingsBySeverity',
    'Parse-ResourceId',
    'Encode-Html',
    'Get-CostSavingsFromRecommendations',
    'Get-DictionaryValue',
    'Get-ReportStylesheet',
    'Get-ReportNavigation',
    'Get-ReportScript',
    'Get-SubscriptionsToScan',
    'Invoke-ScannerForSubscription',
    'Collect-AdvisorRecommendations',
    'Collect-ChangeTrackingData',
    'Collect-NetworkInventory',
    'Collect-CostData',
    'Get-NsgRiskAnalysis',
    'Generate-AuditReports',
    # AI helper functions
    'Invoke-OpenAIAnalysis',
    'ConvertFrom-OpenAIResponseJson',
    'Get-FirstResponsesOutputText',
    'ConvertTo-AdvisorAIInsights',
    'ConvertTo-CostAIInsights',
    'ConvertTo-SecurityAIInsights',
    'ConvertTo-RBACAIInsights',
    'ConvertTo-NetworkAIInsights',
    'ConvertTo-EOLAIInsights',
    'ConvertTo-ChangeTrackingAIInsights',
    'ConvertTo-VMBackupAIInsights',
    'ConvertTo-CostTrackingAIInsights',
    'ConvertTo-CombinedPayload',
    'Get-ImplementationComplexity',
    'Get-RemediationEffort',
    # Config functions
    'Get-ControlDefinitions',
    # Scanner functions
    'Get-AzureStorageFindings',
    'Get-AzureAppServiceFindings',
    'Get-AzureVirtualMachineFindings',
    'Get-AzureArcFindings',
    'Get-AzureMonitorFindings',
    'Get-AzureNetworkFindings',
    'Get-AzureSqlDatabaseFindings',
    'Get-AzureKeyVaultFindings',
    'Get-AzureEOLStatus',
    # Collector functions
    'Get-AzureAdvisorRecommendations',
    'Get-AzureChangeAnalysis',
    'Get-AzureChangeTracking',  # Deprecated - kept for Get-AzureActivityLogViaRestApi
    'Get-AzureActivityLogViaRestApi',
    'Convert-AdvisorRecommendation',
    'Group-AdvisorRecommendations',
    'Format-ExtendedPropertiesDetails',
    'Get-AzureNetworkInventory',
    'Get-AzureCostData',
    'Get-AzureRBACInventory',
    # Test functions
    'Test-ChangeTracking',
    'Test-EOLTracking',
    'Test-CostTracking',
    'Test-SecurityReport',
    'Test-Advisor',
    'Test-VMBackup',
    'Test-RBAC'
)

foreach ($funcName in $functionsToRemove) {
    if (Get-Command $funcName -ErrorAction SilentlyContinue) {
        Remove-Item "Function:\$funcName" -ErrorAction SilentlyContinue
        Write-Verbose "Removed: $funcName"
    }
}

# Ta bort modulen också om den är laddad
Get-Module AzureSecurityAudit | Remove-Module -Force -ErrorAction SilentlyContinue

Write-Host "  Loading functions..." -ForegroundColor Gray

# Ladda alla dependencies i rätt ordning
# 1. Config först (konstanter och definitioner som används av andra)
Write-Host "  Loading Private Config..." -ForegroundColor Gray
Get-ChildItem -Path "$ModuleRoot\Private\Config\*.ps1" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { 
    $file = $_  # Capture file reference BEFORE try/catch
    try {
        . $file.FullName
        Write-Verbose "Loaded: $($file.Name)"
    }
    catch {
        Write-Warning "Failed to load $($file.Name): $_"
    }
}

# 2. Helpers (grundläggande helper-funktioner)
Write-Host "  Loading Private Helpers..." -ForegroundColor Gray
Get-ChildItem -Path "$ModuleRoot\Private\Helpers\*.ps1" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { 
    $file = $_  # Capture file reference BEFORE try/catch
    try {
        . $file.FullName
        Write-Verbose "Loaded: $($file.Name)"
    }
    catch {
        Write-Warning "Failed to load $($file.Name): $_"
    }
}

# 3. Scanners (använder helpers)
Write-Host "  Loading Private Scanners..." -ForegroundColor Gray
Get-ChildItem -Path "$ModuleRoot\Private\Scanners\*.ps1" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { 
    $file = $_  # Capture file reference BEFORE try/catch
    try {
        . $file.FullName
        Write-Verbose "Loaded: $($file.Name)"
    }
    catch {
        Write-Warning "Failed to load $($file.Name): $_"
    }
}

# 4. Collectors (använder helpers)
Write-Host "  Loading Private Collectors..." -ForegroundColor Gray
Get-ChildItem -Path "$ModuleRoot\Private\Collectors\*.ps1" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { 
    $file = $_  # Capture file reference BEFORE try/catch
    Write-Verbose "    Attempting: $($file.Name)"
    try {
        # Load by reading content and creating scriptblock (bypasses execution policy issues)
        $content = Get-Content $file.FullName -Raw -ErrorAction Stop
        $scriptBlock = [scriptblock]::Create($content)
        . $scriptBlock
        Write-Verbose "Loaded: $($file.Name)"
    }
    catch {
        # Fallback to direct dot-sourcing
        try {
            . $file.FullName -ErrorAction Stop
            Write-Verbose "Loaded: $($file.Name)"
        }
        catch {
            Write-Warning "Failed to load $($file.Name): $_"
        }
    }
}

# 5. Public Functions (använder allt ovanstående)
Write-Host "  Loading Public Functions..." -ForegroundColor Gray
Get-ChildItem -Path "$ModuleRoot\Public\*.ps1" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { 
    $file = $_  # Capture file reference BEFORE try/catch
    try {
        . $file.FullName
        Write-Verbose "Loaded: $($file.Name)"
    }
    catch {
        Write-Warning "Failed to load $($file.Name): $_"
    }
}

Write-Host "`n[OK] All functions loaded! Module initialized and ready to use." -ForegroundColor Green
# Add Test-ChangeTracking function for quick testing
function Test-ChangeTracking {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionIds,
        
        [Parameter(Mandatory = $false)]
        [string]$OutputPath = "change-tracking-test.html"
    )
    
    Write-Host "`n=== Testing Change Tracking ===" -ForegroundColor Cyan
    
    # Check if connected to Azure
    $context = Get-AzContext
    if (-not $context) {
        Write-Error "Not connected to Azure. Run Connect-AzAccount first."
        return
    }
    
    # Check if functions are loaded
    if (-not (Get-Command -Name Get-AzureChangeAnalysis -ErrorAction SilentlyContinue)) {
        Write-Error "Get-AzureChangeAnalysis function not found. Make sure Init-Local.ps1 has loaded all functions."
        return
    }
    
    if (-not (Get-Command -Name Export-ChangeTrackingReport -ErrorAction SilentlyContinue)) {
        Write-Error "Export-ChangeTrackingReport function not found. Make sure Init-Local.ps1 has loaded all functions."
        return
    }
    
    # Get current tenant ID to filter subscriptions
    $currentTenantId = if ($context -and $context.Tenant) { $context.Tenant.Id } else { $null }
    
    if (-not $currentTenantId) {
        Write-Error "Could not determine current tenant ID. Make sure you are connected to Azure."
        return
    }
    
    # Get subscriptions
    $subscriptions = @()
    if ($SubscriptionIds) {
        foreach ($subId in $SubscriptionIds) {
            try {
                $sub = Get-AzSubscription -SubscriptionId $subId -ErrorAction Stop
                
                # Filter out subscriptions from other tenants BEFORE trying to use them
                if ($sub.TenantId -ne $currentTenantId) {
                    Write-Warning "Skipping subscription $($sub.Name) ($subId) - belongs to different tenant ($($sub.TenantId)). Current tenant: $currentTenantId"
                    continue
                }
                
                # Only include enabled subscriptions
                if ($sub.State -ne 'Enabled') {
                    Write-Verbose "Skipping subscription $($sub.Name) ($subId) - state is $($sub.State)"
                    continue
                }
                
                $subscriptions += $sub
            }
            catch {
                Write-Warning "Could not find subscription $subId : $_"
            }
        }
    } else {
        # Get all subscriptions and filter by tenant
        # Suppress warnings about other tenants - we'll filter them out anyway
        $allSubs = Get-AzSubscription -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Where-Object {
            $_.TenantId -eq $currentTenantId -and $_.State -eq 'Enabled'
        }
        
        $subscriptions = @($allSubs)
        
        # If no subscriptions found, use current subscription if it's in the right tenant
        if ($subscriptions.Count -eq 0) {
            try {
                $currentSub = Get-AzSubscription -SubscriptionId $context.Subscription.Id -ErrorAction Stop -WarningAction SilentlyContinue
                if ($currentSub.State -eq 'Enabled' -and $currentSub.TenantId -eq $currentTenantId) {
                    $subscriptions = @($currentSub)
                }
            }
            catch {
                Write-Verbose "Could not get current subscription: $_"
            }
        }
    }
    
    if ($subscriptions.Count -eq 0) {
        Write-Error "No enabled subscriptions found in current tenant ($currentTenantId) to test."
        return
    }
    
    Write-Host "Testing with $($subscriptions.Count) subscription(s) in tenant $currentTenantId" -ForegroundColor Cyan
    
    # Collect change tracking data using new Change Analysis (cross-subscription query)
    $changeTrackingData = [System.Collections.Generic.List[PSObject]]::new()
    $tenantId = $context.Tenant.Id
    
    try {
        # Use new Change Analysis function with cross-subscription query
        $subscriptionIds = @($subscriptions | ForEach-Object { $_.Id })
        Write-Host "`nQuerying Change Analysis for $($subscriptionIds.Count) subscription(s)..." -ForegroundColor Yellow
        
        $changes = Get-AzureChangeAnalysis -SubscriptionIds $subscriptionIds -Days 14 -IncludeSecurityEvents
        
        # Ensure changes is an array (handle null safely)
        if ($null -eq $changes) {
            $changes = @()
        } else {
            $changes = @($changes)
        }
        
        Write-Verbose "Get-AzureChangeAnalysis returned: Type=$($changes.GetType().FullName), Count=$($changes.Count)"
        
        if ($changes.Count -gt 0) {
            $addedCount = 0
            foreach ($change in $changes) {
                if ($null -ne $change) {
                    $changeTrackingData.Add($change)
                    $addedCount++
                }
            }
            Write-Host "  Added $addedCount changes" -ForegroundColor Green
        } else {
            Write-Host "  No changes found" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Warning "Failed to get changes: $_"
        Write-Verbose "Error details: $($_.Exception.Message)"
    }
    
    Write-Host "`nTotal changes collected: $($changeTrackingData.Count)" -ForegroundColor $(if ($changeTrackingData.Count -gt 0) { 'Green' } else { 'Yellow' })
    
    # Generate HTML report
    if ($changeTrackingData.Count -gt 0) {
        Write-Host "`nGenerating HTML report..." -ForegroundColor Cyan
        try {
            $result = Export-ChangeTrackingReport -ChangeTrackingData $changeTrackingData -OutputPath $OutputPath -TenantId $tenantId
            
            Write-Host "`n[SUCCESS] Report generated: $OutputPath" -ForegroundColor Green
            Write-Host "  Total Changes: $($result.TotalChanges)" -ForegroundColor Gray
            Write-Host "  Creates: $($result.Creates)" -ForegroundColor Gray
            Write-Host "  Updates: $($result.Updates)" -ForegroundColor Gray
            Write-Host "  Deletes: $($result.Deletes)" -ForegroundColor Gray
            Write-Host "  Security Alerts: $($result.HighSecurityFlags + $result.MediumSecurityFlags)" -ForegroundColor Gray
            
            # Try to open the report
            if (Test-Path $OutputPath) {
                $fullPath = (Resolve-Path $OutputPath).Path
                Write-Host "`nOpening report..." -ForegroundColor Cyan
                Start-Process $fullPath -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Error "Failed to generate report: $_"
        }
    } else {
        Write-Host "`nNo changes to report. Skipping HTML generation." -ForegroundColor Yellow
    }
}

function Test-EOLTracking {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionIds,

        [Parameter(Mandatory = $false)]
        [string]$OutputFolder = "eol-test",
        
        [switch]$ForceRefresh
    )

    Write-Host "`n=== Testing EOL Tracking (EOL page only) ===" -ForegroundColor Cyan

    $context = Get-AzContext
    if (-not $context) {
        Write-Error "Not connected to Azure. Run Connect-AzAccount first."
        return
    }

    # Check required core functions
    foreach ($fn in @('Get-SubscriptionsToScan','Get-AzureEOLStatus','Export-EOLReport','New-EOLFinding','Get-SubscriptionDisplayName','Convert-EOLResultsToFindings')) {
        if (-not (Get-Command -Name $fn -ErrorAction SilentlyContinue)) {
            Write-Error "$fn function not found. Make sure Init-Local.ps1 has loaded all functions."
            return
        }
    }

    # Resolve output folder to absolute path
    if (-not [System.IO.Path]::IsPathRooted($OutputFolder)) {
        $OutputFolder = Join-Path (Get-Location).Path $OutputFolder
    }
    if (-not (Test-Path $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    }
    Write-Host "Output folder: $OutputFolder" -ForegroundColor Gray

    $errors = [System.Collections.Generic.List[string]]::new()

    # Get subscriptions in scope
    $subscriptionResult = Get-SubscriptionsToScan -SubscriptionIds $SubscriptionIds -Errors $errors
    $subscriptions = $subscriptionResult.Subscriptions

    if ($subscriptions.Count -eq 0) {
        Write-Error "No enabled subscriptions found to test EOL report."
        return
    }

    # Collect EOL Status using Microsoft's official EOL lists (same as Invoke-AzureSecurityAudit)
    Write-Host "`nCollecting EOL status from Microsoft's official EOL lists..." -ForegroundColor Cyan
    Write-Host "  Note: This queries Azure Resource Graph directly - no inventory scan required" -ForegroundColor Gray
    $allEOLFindings = [System.Collections.Generic.List[PSObject]]::new()
    $eolStatus = [System.Collections.Generic.List[PSObject]]::new()
    
    try {
        $subIdsForEol = @($subscriptions.Id)
        if ($subIdsForEol.Count -gt 0) {
            Write-Host "Running EOL tracking across $($subIdsForEol.Count) subscription(s)..." -ForegroundColor Gray
            Write-Host "  Subscription IDs: $($subIdsForEol -join ', ')" -ForegroundColor Gray
            Write-Host "  Tip: If ServiceIDs are missing from service_list.json, try -ForceRefresh to update EOL data" -ForegroundColor Gray
            
            $eolStartTime = Get-Date
            $eolResults = Get-AzureEOLStatus -SubscriptionIds $subIdsForEol -ForceRefresh:$ForceRefresh -Verbose
            $eolDuration = (Get-Date) - $eolStartTime
            Write-Host "  EOL query completed in $([math]::Round($eolDuration.TotalSeconds, 2)) seconds" -ForegroundColor Gray
            if ($eolResults) {
                Write-Host "Found $($eolResults.Count) EOL component(s)" -ForegroundColor Green
                foreach ($eolComponent in $eolResults) {
                    $eolStatus.Add($eolComponent)
                }
                
                # Convert EOL results to findings using shared helper function
                try {
                    Convert-EOLResultsToFindings -EOLResults $eolResults -EOLFindings $allEOLFindings
                }
                catch {
                    Write-Warning "Failed to convert EOL results to findings: $_"
                    Write-Verbose "Error details: $($_.Exception.Message)"
                    if ($_.Exception.InnerException) {
                        Write-Verbose "Inner exception: $($_.Exception.InnerException.Message)"
                    }
                }
                
                Write-Host "Total EOL findings created: $($allEOLFindings.Count)" -ForegroundColor Green
            } else {
                Write-Host "No EOL components found in selected subscriptions." -ForegroundColor Yellow
                Write-Host "  This means the Resource Graph query completed but found no deprecated resources." -ForegroundColor Gray
                Write-Host "  The query checks against Microsoft's official EOL lists from Azure/EOL GitHub repo." -ForegroundColor Gray
            }
        } else {
            Write-Host "  No subscription IDs provided for EOL tracking" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Warning "EOL tracking failed: $_"
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) {
            Write-Host "  Inner exception: $($_.Exception.InnerException.Message)" -ForegroundColor Red
        }
    }

    # Convert List to array for Export-EOLReport (same as Invoke-AzureSecurityAudit)
    $eolFindingsArray = @($allEOLFindings | Where-Object { $null -ne $_ })
    
    Write-Host "`nTotal EOL findings to export: $($eolFindingsArray.Count)" -ForegroundColor Cyan

    $eolOutputPath = Join-Path $OutputFolder "eol.html"

    try {
        # Handle empty array case - Export-EOLReport will show "No EOL findings" message
        if ($eolFindingsArray.Count -eq 0) {
            Write-Host "No EOL findings found. Generating empty report..." -ForegroundColor Yellow
        }
        
        $summary = Export-EOLReport -EOLFindings $eolFindingsArray -OutputPath $eolOutputPath -TenantId $context.Tenant.Id

        if (Test-Path $eolOutputPath) {
            $fullPath = (Resolve-Path $eolOutputPath).Path
            Write-Host "`n[SUCCESS] EOL report generated: $fullPath" -ForegroundColor Green
            if ($summary -is [hashtable]) {
                Write-Host "  Components: $($summary.ComponentCount)  |  Critical: $($summary.CriticalCount)  High: $($summary.HighCount)  Medium: $($summary.MediumCount)  Low: $($summary.LowCount)" -ForegroundColor Gray
            }
            Write-Host "Opening EOL report..." -ForegroundColor Cyan
            Start-Process $fullPath -ErrorAction SilentlyContinue
        }
        else {
            Write-Warning "EOL report not found at: $eolOutputPath"
        }
    }
    catch {
        Write-Error "Failed to generate EOL report: $_"
        if ($_.Exception.InnerException) {
            Write-Host "Inner exception: $($_.Exception.InnerException.Message)" -ForegroundColor Red
        }
    }
}

# Quick test wrapper for Security report (only security scanners + EOL, then Export-SecurityReport)
function Test-SecurityReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionIds,

        [Parameter(Mandatory = $false)]
        [string[]]$Categories = @('All'),

        [Parameter(Mandatory = $false)]
        [switch]$IncludeLevel2,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeEOLTracking,

        [Parameter(Mandatory = $false)]
        [string]$OutputFolder = "security-audit-test"
    )

    Write-Host "`n=== Testing Security Report (Security page only) ===" -ForegroundColor Cyan

    $context = Get-AzContext
    if (-not $context) {
        Write-Error "Not connected to Azure. Run Connect-AzAccount first."
        return
    }

    # Validate required helpers
    foreach ($fn in @('Get-SubscriptionsToScan','Invoke-ScannerForSubscription','Export-SecurityReport')) {
        if (-not (Get-Command -Name $fn -ErrorAction SilentlyContinue)) {
            Write-Error "$fn function not found. Make sure Init-Local.ps1 has loaded all functions."
            return
        }
    }

    # Resolve output folder to absolute path
    if (-not [System.IO.Path]::IsPathRooted($OutputFolder)) {
        $OutputFolder = Join-Path (Get-Location).Path $OutputFolder
    }
    if (-not (Test-Path $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    }

    Write-Host "Output folder: $OutputFolder" -ForegroundColor Gray

    # Get subscriptions in scope (reuse standard helper)
    $errors = [System.Collections.Generic.List[string]]::new()
    $subscriptionResult = Get-SubscriptionsToScan -SubscriptionIds $SubscriptionIds -Errors $errors
    $subscriptions = $subscriptionResult.Subscriptions

    if ($subscriptions.Count -eq 0) {
        Write-Error "No subscriptions found to scan for Security report."
        return
    }

    # Map categories like Invoke-AzureSecurityAudit
    $allScannerCategories = @('Storage','AppService','VM','ARC','Monitor','Network','SQL','KeyVault')
    if ('All' -in $Categories) {
        $categoriesToScan = $allScannerCategories
    } else {
        $categoriesToScan = $Categories
    }

    # Define scanners hashtable compatible with Invoke-ScannerForSubscription
    $scanners = @{
        'Storage'    = { 
            param($subId, $subName, $includeL2) 
            Get-AzureStorageFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 -CriticalStorageAccounts @()
        }
        'AppService' = { param($subId, $subName, $includeL2) Get-AzureAppServiceFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 }
        'VM'         = { param($subId, $subName, $includeL2) Get-AzureVirtualMachineFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 }
        'ARC'        = { param($subId, $subName, $includeL2) Get-AzureArcFindings -SubscriptionId $subId -SubscriptionName $subName }
        'Monitor'    = { param($subId, $subName, $includeL2) Get-AzureMonitorFindings -SubscriptionId $subId -SubscriptionName $subName }
        'Network'    = { param($subId, $subName, $includeL2) Get-AzureNetworkFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 }
        'SQL'        = { param($subId, $subName, $includeL2) Get-AzureSqlDatabaseFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 }
        'KeyVault'   = { param($subId, $subName, $includeL2) Get-AzureKeyVaultFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 }
    }

    # Collections just like Invoke-AzureSecurityAudit
    $allFindings    = [System.Collections.Generic.List[PSObject]]::new()
    $allEOLFindings = [System.Collections.Generic.List[PSObject]]::new()
    $vmInventory    = [System.Collections.Generic.List[PSObject]]::new()

    # Track scan timing and subscription summary for metadata
    $scanStartTime = Get-Date

    # Scan each subscription (security scanners only)
    $total = $subscriptions.Count
    $current = 0

    foreach ($sub in $subscriptions) {
        $current++
        $subDisplayName = Get-SubscriptionDisplayName -Subscription $sub
        Write-Host "`n[$current/$total] Scanning for Security: $subDisplayName ($($sub.Id))" -ForegroundColor Yellow

        Invoke-ScannerForSubscription `
            -Subscription $sub `
            -CategoriesToScan $categoriesToScan `
            -Scanners $scanners `
            -IncludeLevel2:$IncludeLevel2 `
            -AllFindings $allFindings `
            -AllEOLFindings $allEOLFindings `
            -VMInventory $vmInventory `
            -Errors $errors
    }

    $scanEndTime = Get-Date

    # Build subscription summary similar to Invoke-AzureSecurityAudit
    $subscriptionsScanned = @()
    foreach ($sub in $subscriptions) {
        $subName = Get-SubscriptionDisplayName -Subscription $sub
        $subscriptionsScanned += [PSCustomObject]@{
            Id   = $sub.Id
            Name = $subName
        }
    }

    # Compute unique resource count from findings
    $uniqueResourceIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($finding in $allFindings) {
        if ($finding.ResourceId) {
            [void]$uniqueResourceIds.Add($finding.ResourceId)
        }
    }
    $totalResources = $uniqueResourceIds.Count

    # Build minimal AuditResult object for Export-SecurityReport
    $tenantId = $context.Tenant.Id
    $auditResult = [PSCustomObject]@{
        TenantId             = $tenantId
        Findings             = @($allFindings)
        EOLFindings          = @($allEOLFindings)
        VMInventory          = $vmInventory
        AdvisorRecommendations = @()   # not used by Security page
        ChangeTrackingData   = @()
        NetworkInventory     = [System.Collections.Generic.List[PSObject]]::new()
        CostTrackingData     = @{}     # empty
        ScanStartTime        = $scanStartTime
        ScanEndTime          = $scanEndTime
        SubscriptionsScanned = $subscriptionsScanned
        TotalResources       = $totalResources
        Errors               = $errors
    }

    # Security report output path
    $securityPath = Join-Path $OutputFolder "security.html"

    Write-Host "`nGenerating Security HTML report..." -ForegroundColor Cyan
    try {
        $null = Export-SecurityReport -AuditResult $auditResult -OutputPath $securityPath

        if (Test-Path $securityPath) {
            $fullPath = (Resolve-Path $securityPath).Path
            Write-Host "`n[SUCCESS] Security report generated: $fullPath" -ForegroundColor Green
            Write-Host "Opening security report..." -ForegroundColor Cyan
            Start-Process $fullPath -ErrorAction SilentlyContinue
        } else {
            Write-Warning "Security report not found at: $securityPath"
            Write-Host "Check the output in: $OutputFolder" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Error "Security report test failed: $_"
        if ($_.Exception.InnerException) {
            Write-Host "Inner exception: $($_.Exception.InnerException.Message)" -ForegroundColor Red
        }
    }
}

# Quick test wrapper for Advisor report
function Test-Advisor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionIds,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath = "advisor-test.html"
    )

    Write-Host "`n=== Testing Advisor Report ===" -ForegroundColor Cyan

    $context = Get-AzContext
    if (-not $context) {
        Write-Error "Not connected to Azure. Run Connect-AzAccount first."
        return
    }

    if (-not (Get-Command -Name Collect-AdvisorRecommendations -ErrorAction SilentlyContinue)) {
        Write-Error "Collect-AdvisorRecommendations function not found. Make sure Init-Local.ps1 has loaded all functions."
        return
    }

    if (-not (Get-Command -Name Export-AdvisorReport -ErrorAction SilentlyContinue)) {
        Write-Error "Export-AdvisorReport function not found. Make sure Init-Local.ps1 has loaded all functions."
        return
    }

    # Get subscriptions in scope
    $errors = [System.Collections.Generic.List[string]]::new()
    $subscriptionResult = Get-SubscriptionsToScan -SubscriptionIds $SubscriptionIds -Errors $errors
    $subscriptions = $subscriptionResult.Subscriptions

    if ($subscriptions.Count -eq 0) {
        Write-Error "No subscriptions found to scan for Advisor recommendations."
        return
    }

    Write-Host "Collecting Advisor recommendations from $($subscriptions.Count) subscription(s)..." -ForegroundColor Cyan

    $advisorRecs = [System.Collections.Generic.List[PSObject]]::new()
    Collect-AdvisorRecommendations -Subscriptions $subscriptions -AdvisorRecommendations $advisorRecs -Errors $errors

    Write-Host "`nTotal Advisor recommendations collected: $($advisorRecs.Count)" -ForegroundColor $(if ($advisorRecs.Count -gt 0) { 'Green' } else { 'Yellow' })

    # Resolve full path
    if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath = Join-Path (Get-Location).Path $OutputPath
    }
    Write-Host "Generating Advisor HTML report at: $OutputPath" -ForegroundColor Gray

    $tenantId = if ($context.Tenant) { $context.Tenant.Id } else { "Unknown" }

    try {
        $null = Export-AdvisorReport -AdvisorRecommendations $advisorRecs -OutputPath $OutputPath -TenantId $tenantId

        Write-Host "`n[SUCCESS] Advisor report generated: $OutputPath" -ForegroundColor Green

        if (Test-Path $OutputPath) {
            $fullPath = (Resolve-Path $OutputPath).Path
            Write-Host "Opening Advisor report..." -ForegroundColor Cyan
            Start-Process $fullPath -ErrorAction SilentlyContinue
        } else {
            Write-Warning "Advisor report file not found at: $OutputPath"
        }
    }
    catch {
        Write-Error "Failed to generate Advisor report: $_"
        Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) {
            Write-Host "Inner exception: $($_.Exception.InnerException.Message)" -ForegroundColor Red
        }
    }
}

# Quick test wrapper for VM Backup report
function Test-VMBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionIds,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeLevel2,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath = "vm-backup-test.html"
    )

    Write-Host "`n=== Testing VM Backup Report ===" -ForegroundColor Cyan

    $context = Get-AzContext
    if (-not $context) {
        Write-Error "Not connected to Azure. Run Connect-AzAccount first."
        return
    }

    if (-not (Get-Command -Name Get-AzureVirtualMachineFindings -ErrorAction SilentlyContinue)) {
        Write-Error "Get-AzureVirtualMachineFindings function not found. Make sure Init-Local.ps1 has loaded all functions."
        return
    }

    if (-not (Get-Command -Name Export-VMBackupReport -ErrorAction SilentlyContinue)) {
        Write-Error "Export-VMBackupReport function not found. Make sure Init-Local.ps1 has loaded all functions."
        return
    }

    # Get subscriptions in scope
    $errors = [System.Collections.Generic.List[string]]::new()
    $subscriptionResult = Get-SubscriptionsToScan -SubscriptionIds $SubscriptionIds -Errors $errors
    $subscriptions = $subscriptionResult.Subscriptions

    if ($subscriptions.Count -eq 0) {
        Write-Error "No subscriptions found to scan for VM backup."
        return
    }

    $vmInventory = [System.Collections.Generic.List[PSObject]]::new()
    $tenantId = if ($context.Tenant) { $context.Tenant.Id } else { "Unknown" }

    Write-Host "Collecting VM inventory from $($subscriptions.Count) subscription(s)..." -ForegroundColor Cyan

    foreach ($sub in $subscriptions) {
        $subName = Get-SubscriptionDisplayName -Subscription $sub
        Write-Host "`nCollecting from: $subName ($($sub.Id))" -ForegroundColor Yellow

        try {
            # Ensure correct context
            $currentTenantId = if ($context.Tenant) { $context.Tenant.Id } else { $null }
            Invoke-WithSuppressedWarnings {
                if ($currentTenantId) {
                    Set-AzContext -SubscriptionId $sub.Id -TenantId $currentTenantId -ErrorAction Stop | Out-Null
                } else {
                    Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
                }
            }

            $result = Get-AzureVirtualMachineFindings -SubscriptionId $sub.Id -SubscriptionName $subName -IncludeLevel2:$IncludeLevel2

            if ($result -and $result.Inventory) {
                $added = 0
                foreach ($vm in $result.Inventory) {
                    if ($null -ne $vm) {
                        $vmInventory.Add($vm)
                        $added++
                    }
                }
                Write-Host "  Added $added VM(s) to inventory" -ForegroundColor Green
            } else {
                Write-Host "  No VMs found in this subscription" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Warning "Failed to collect VM inventory from $subName : $_"
        }
    }

    Write-Host "`nTotal VMs in inventory: $($vmInventory.Count)" -ForegroundColor $(if ($vmInventory.Count -gt 0) { 'Green' } else { 'Yellow' })

    # Resolve full path
    if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath = Join-Path (Get-Location).Path $OutputPath
    }
    Write-Host "Generating VM Backup HTML report at: $OutputPath" -ForegroundColor Gray

    try {
        $null = Export-VMBackupReport -VMInventory $vmInventory -OutputPath $OutputPath -TenantId $tenantId

        Write-Host "`n[SUCCESS] VM Backup report generated: $OutputPath" -ForegroundColor Green

        if (Test-Path $OutputPath) {
            $fullPath = (Resolve-Path $OutputPath).Path
            Write-Host "Opening VM Backup report..." -ForegroundColor Cyan
            Start-Process $fullPath -ErrorAction SilentlyContinue
        } else {
            Write-Warning "VM Backup report file not found at: $OutputPath"
        }
    }
    catch {
        Write-Error "Failed to generate VM Backup report: $_"
        Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) {
            Write-Host "Inner exception: $($_.Exception.InnerException.Message)" -ForegroundColor Red
        }
    }
}

# Add Test-NetworkInventory function for quick testing
function Test-NetworkInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionIds,
        
        [Parameter(Mandatory = $false)]
        [string]$OutputPath = "network-inventory-test.html"
    )
    
    Write-Host "`n=== Testing Network Inventory ===" -ForegroundColor Cyan
    
    # Check if connected to Azure
    $context = Get-AzContext
    if (-not $context) {
        Write-Error "Not connected to Azure. Run Connect-AzAccount first."
        return
    }
    
    # Check if functions are loaded
    if (-not (Get-Command -Name Get-AzureNetworkInventory -ErrorAction SilentlyContinue)) {
        Write-Error "Get-AzureNetworkInventory function not found. Make sure Init-Local.ps1 has loaded all functions."
        return
    }
    
    if (-not (Get-Command -Name Export-NetworkInventoryReport -ErrorAction SilentlyContinue)) {
        Write-Error "Export-NetworkInventoryReport function not found. Make sure Init-Local.ps1 has loaded all functions."
        return
    }
    
    # Get current tenant ID to filter subscriptions
    $currentTenantId = if ($context -and $context.Tenant) { $context.Tenant.Id } else { $null }
    
    if (-not $currentTenantId) {
        Write-Error "Could not determine current tenant ID. Make sure you are connected to Azure."
        return
    }
    
    # Get subscriptions
    $subscriptions = @()
    if ($SubscriptionIds) {
        foreach ($subId in $SubscriptionIds) {
            try {
                $sub = Get-AzSubscription -SubscriptionId $subId -ErrorAction Stop
                
                # Filter out subscriptions from other tenants
                if ($sub.TenantId -ne $currentTenantId) {
                    Write-Warning "Skipping subscription $($sub.Name) ($subId) - belongs to different tenant. Current tenant: $currentTenantId"
                    continue
                }
                
                if ($sub.State -ne 'Enabled') {
                    continue
                }
                
                $subscriptions += $sub
            }
            catch {
                Write-Warning "Could not find subscription $subId : $_"
            }
        }
    } else {
        # Get all subscriptions and filter by tenant
        # Suppress warnings about other tenants - we'll filter them out anyway
        $allSubs = Get-AzSubscription -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Where-Object {
            $_.TenantId -eq $currentTenantId -and $_.State -eq 'Enabled'
        }
        $subscriptions = @($allSubs)
        
        # If no subscriptions found, use current subscription if it's in the right tenant
        if ($subscriptions.Count -eq 0) {
            try {
                $currentSub = Get-AzSubscription -SubscriptionId $context.Subscription.Id -ErrorAction Stop -WarningAction SilentlyContinue
                if ($currentSub.State -eq 'Enabled' -and $currentSub.TenantId -eq $currentTenantId) {
                    $subscriptions = @($currentSub)
                }
            }
            catch {
                Write-Verbose "Could not get current subscription: $_"
            }
        }
    }
    
    if ($subscriptions.Count -eq 0) {
        Write-Error "No enabled subscriptions found in current tenant ($currentTenantId) to test."
        return
    }
    
    Write-Host "Testing with $($subscriptions.Count) subscription(s) in tenant $currentTenantId" -ForegroundColor Cyan
    
    # Collect data
    $networkInventory = [System.Collections.Generic.List[PSObject]]::new()
    $tenantId = $context.Tenant.Id
    
    Collect-NetworkInventory -Subscriptions $subscriptions -NetworkInventory $networkInventory
    
    Write-Host "`nTotal VNets collected: $($networkInventory.Count)" -ForegroundColor $(if ($networkInventory.Count -gt 0) { 'Green' } else { 'Yellow' })
    
    # Generate HTML report
    # Always generate report even if empty to verify function
    Write-Host "`nGenerating HTML report..." -ForegroundColor Cyan
    
    # Resolve full path
    if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath = Join-Path (Get-Location).Path $OutputPath
    }
    Write-Host "  Output path: $OutputPath" -ForegroundColor Gray
    
    try {
        $result = Export-NetworkInventoryReport -NetworkInventory $networkInventory -OutputPath $OutputPath -TenantId $tenantId
        
        Write-Host "`n[SUCCESS] Report generated: $OutputPath" -ForegroundColor Green
        Write-Host "  VNets: $($result.VNetCount)" -ForegroundColor Gray
        Write-Host "  Devices: $($result.DeviceCount)" -ForegroundColor Gray
        if ($result.SecurityRisks -and $result.SecurityRisks -gt 0) {
            Write-Host "  Security Risks: $($result.SecurityRisks)" -ForegroundColor Yellow
        } else {
            Write-Host "  Security Risks: 0" -ForegroundColor Green
        }
        
        # Verify file exists and try to open the report
        if (Test-Path $OutputPath) {
            $fullPath = (Resolve-Path $OutputPath).Path
            Write-Host "`nFile verified at: $fullPath" -ForegroundColor Green
            Write-Host "Opening report..." -ForegroundColor Cyan
            Start-Process $fullPath -ErrorAction SilentlyContinue
        } else {
            Write-Warning "Report file not found at: $OutputPath"
            Write-Host "Current directory: $(Get-Location)" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Error "Failed to generate report: $_"
        Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) {
            Write-Host "Inner exception: $($_.Exception.InnerException.Message)" -ForegroundColor Red
        }
    }
}

# Add Test-CostTracking function for quick testing
function Test-CostTracking {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionIds,
        
        [Parameter(Mandatory = $false)]
        [int]$DaysToInclude = 30,
        
        [Parameter(Mandatory = $false)]
        [string]$OutputPath = "cost-tracking-test.html"
    )
    
Write-Host \"`n=== Testing Cost Tracking ===\" -ForegroundColor Cyan
    
    # Check if connected to Azure
    $context = Get-AzContext
    if (-not $context) {
        Write-Error "Not connected to Azure. Run Connect-AzAccount first."
        return
    }
    
    # Check if functions are loaded
    if (-not (Get-Command -Name Collect-CostData -ErrorAction SilentlyContinue)) {
        Write-Error "Collect-CostData function not found. Make sure Init-Local.ps1 has loaded all functions."
        return
    }
    
    if (-not (Get-Command -Name Export-CostTrackingReport -ErrorAction SilentlyContinue)) {
        Write-Error "Export-CostTrackingReport function not found. Make sure Init-Local.ps1 has loaded all functions."
        return
    }
    
    # Get current tenant ID to filter subscriptions
    $currentTenantId = if ($context -and $context.Tenant) { $context.Tenant.Id } else { $null }
    
    if (-not $currentTenantId) {
        Write-Error "Could not determine current tenant ID. Make sure you are connected to Azure."
        return
    }
    
    # Get subscriptions
    $subscriptions = @()
    if ($SubscriptionIds) {
        foreach ($subId in $SubscriptionIds) {
            try {
                $sub = Get-AzSubscription -SubscriptionId $subId -ErrorAction Stop -WarningAction SilentlyContinue
                
                # Filter out subscriptions from other tenants
                if ($sub.TenantId -ne $currentTenantId) {
                    Write-Warning "Skipping subscription $($sub.Name) ($subId) - belongs to different tenant. Current tenant: $currentTenantId"
                    continue
                }
                
                if ($sub.State -ne 'Enabled') {
                    continue
                }
                
                $subscriptions += $sub
            }
            catch {
                Write-Warning "Could not find subscription $subId : $_"
            }
        }
    } else {
        # Get all subscriptions and filter by tenant
        $allSubs = Get-AzSubscription -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Where-Object {
            $_.TenantId -eq $currentTenantId -and $_.State -eq 'Enabled'
        }
        $subscriptions = @($allSubs)
        
        # If no subscriptions found, use current subscription if it's in the right tenant
        if ($subscriptions.Count -eq 0) {
            try {
                $currentSub = Get-AzSubscription -SubscriptionId $context.Subscription.Id -ErrorAction Stop -WarningAction SilentlyContinue
                if ($currentSub.State -eq 'Enabled' -and $currentSub.TenantId -eq $currentTenantId) {
                    $subscriptions = @($currentSub)
                }
            }
            catch {
                Write-Verbose "Could not get current subscription: $_"
            }
        }
    }
    
    if ($subscriptions.Count -eq 0) {
        Write-Error "No enabled subscriptions found in current tenant ($currentTenantId) to test."
        return
    }
    
    Write-Host "Testing with $($subscriptions.Count) subscription(s) in tenant $currentTenantId" -ForegroundColor Cyan
    Write-Host "Days to include: $DaysToInclude" -ForegroundColor Gray
    
    # Collect data
    $errors = [System.Collections.Generic.List[string]]::new()
    $tenantId = $context.Tenant.Id
    
    Write-Host "`nCollecting cost data..." -ForegroundColor Cyan
    $costData = Collect-CostData -Subscriptions $subscriptions -DaysToInclude $DaysToInclude -Errors $errors
    
    Write-Host "`nTotal cost records collected: $($costData.RawData.Count)" -ForegroundColor $(if ($costData.RawData.Count -gt 0) { 'Green' } else { 'Yellow' })
    Write-Host "Total cost: $($costData.Currency) $([math]::Round($costData.TotalCostLocal, 2)) ($([math]::Round($costData.TotalCostUSD, 2)) USD)" -ForegroundColor Green
    
    # Generate HTML report
    Write-Host "`nGenerating HTML report..." -ForegroundColor Cyan
    
    # Resolve full path
    if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath = Join-Path (Get-Location).Path $OutputPath
    }
    Write-Host "  Output path: $OutputPath" -ForegroundColor Gray
    
    try {
        $result = Export-CostTrackingReport -CostTrackingData $costData -OutputPath $OutputPath -TenantId $tenantId
        
        Write-Host "`n[SUCCESS] Report generated: $OutputPath" -ForegroundColor Green
        Write-Host "  Total Cost: $($result.TotalCostLocal) ($($result.TotalCostUSD) USD)" -ForegroundColor Gray
        Write-Host "  Subscriptions: $($result.SubscriptionCount)" -ForegroundColor Gray
        Write-Host "  Categories: $($result.CategoryCount)" -ForegroundColor Gray
        Write-Host "  Top Resources: $($result.ResourceCount)" -ForegroundColor Gray
        
        # Verify file exists and try to open the report
        if (Test-Path $OutputPath) {
            $fullPath = (Resolve-Path $OutputPath).Path
            Write-Host "`nFile verified at: $fullPath" -ForegroundColor Green
            Write-Host "Opening report..." -ForegroundColor Cyan
            Start-Process $fullPath -ErrorAction SilentlyContinue
        } else {
            Write-Warning "Report file not found at: $OutputPath"
            Write-Host "Current directory: $(Get-Location)" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Error "Failed to generate report: $_"
        Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) {
            Write-Host "Inner exception: $($_.Exception.InnerException.Message)" -ForegroundColor Red
        }
    }
}

# Quick test wrapper for RBAC/IAM Inventory report
function Test-RBAC {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionIds,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath = "rbac-test.html"
    )

    Write-Host "`n=== Testing RBAC/IAM Inventory Report ===" -ForegroundColor Cyan

    $context = Get-AzContext
    if (-not $context) {
        Write-Error "Not connected to Azure. Run Connect-AzAccount first."
        return
    }

    if (-not (Get-Command -Name Get-AzureRBACInventory -ErrorAction SilentlyContinue)) {
        Write-Error "Get-AzureRBACInventory function not found. Make sure Init-Local.ps1 has loaded all functions."
        return
    }

    if (-not (Get-Command -Name Export-RBACReport -ErrorAction SilentlyContinue)) {
        Write-Error "Export-RBACReport function not found. Make sure Init-Local.ps1 has loaded all functions."
        return
    }

    # Get subscriptions in scope
    $errors = [System.Collections.Generic.List[string]]::new()
    $subscriptionResult = Get-SubscriptionsToScan -SubscriptionIds $SubscriptionIds -Errors $errors
    $subscriptions = $subscriptionResult.Subscriptions

    if ($subscriptions.Count -eq 0) {
        Write-Error "No subscriptions found to scan for RBAC inventory."
        return
    }

    Write-Host "Collecting RBAC inventory from $($subscriptions.Count) subscription(s)..." -ForegroundColor Cyan

    $tenantId = if ($context.Tenant) { $context.Tenant.Id } else { "Unknown" }
    $subIdsForRBAC = @($subscriptions.Id)

    try {
        $rbacData = Get-AzureRBACInventory -SubscriptionIds $subIdsForRBAC -TenantId $tenantId

        Write-Host "`nRBAC Inventory Collection Summary:" -ForegroundColor Green
        Write-Host "  Total Principals: $($rbacData.Statistics.TotalPrincipals)" -ForegroundColor Gray
        Write-Host "  Privileged: $($rbacData.Statistics.ByRiskTier.Privileged)" -ForegroundColor $(if ($rbacData.Statistics.ByRiskTier.Privileged -gt 0) { 'Red' } else { 'Green' })
        Write-Host "  Write: $($rbacData.Statistics.ByRiskTier.Write)" -ForegroundColor Gray
        Write-Host "  Read: $($rbacData.Statistics.ByRiskTier.Read)" -ForegroundColor Gray
        Write-Host "  Orphaned: $($rbacData.Statistics.OrphanedCount)" -ForegroundColor $(if ($rbacData.Statistics.OrphanedCount -gt 0) { 'Red' } else { 'Green' })
        Write-Host "  External/Guest: $($rbacData.Statistics.ExternalCount)" -ForegroundColor Gray
        Write-Host "  Redundant: $($rbacData.Statistics.RedundantCount)" -ForegroundColor $(if ($rbacData.Statistics.RedundantCount -gt 0) { 'Yellow' } else { 'Green' })
        Write-Host "  Custom Roles: $($rbacData.Statistics.CustomRoleCount)" -ForegroundColor Gray

        # Resolve full path
        if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
            $OutputPath = Join-Path (Get-Location).Path $OutputPath
        }
        Write-Host "`nGenerating RBAC HTML report at: $OutputPath" -ForegroundColor Gray

        $null = Export-RBACReport -RBACData $rbacData -OutputPath $OutputPath -TenantId $tenantId

        Write-Host "`n[SUCCESS] RBAC report generated: $OutputPath" -ForegroundColor Green

        if (Test-Path $OutputPath) {
            $fullPath = (Resolve-Path $OutputPath).Path
            Write-Host "Opening RBAC report..." -ForegroundColor Cyan
            Start-Process $fullPath -ErrorAction SilentlyContinue
        } else {
            Write-Warning "RBAC report file not found at: $OutputPath"
        }
    }
    catch {
        Write-Error "Failed to generate RBAC report: $_"
        Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) {
            Write-Host "Inner exception: $($_.Exception.InnerException.Message)" -ForegroundColor Red
        }
    }
}

# Retry AI analysis with existing JSON payload
function Test-RetryAIAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$JsonFilePath,
        
        [Parameter(Mandatory = $false)]
        [string]$Model
    )
    
    Write-Host "`n=== Retry AI Analysis with Existing JSON ===" -ForegroundColor Cyan
    
    # Check if Invoke-AzureArchitectAgent is available
    if (-not (Get-Command -Name Invoke-AzureArchitectAgent -ErrorAction SilentlyContinue)) {
        Write-Error "Invoke-AzureArchitectAgent function not found. Make sure Init-Local.ps1 has loaded all functions."
        return
    }
    
    # If no JSON file path provided, find the latest one in output folder
    if ([string]::IsNullOrWhiteSpace($JsonFilePath)) {
        Write-Host "No JSON file specified, searching for latest AI_Insights_Payload JSON file..." -ForegroundColor Gray
        $outputFolder = Join-Path (Get-Location) "output"
        if (Test-Path $outputFolder) {
            $jsonFiles = Get-ChildItem -Path $outputFolder -Recurse -Filter "AI_Insights_Payload_*.json" -ErrorAction SilentlyContinue | 
                Sort-Object LastWriteTime -Descending
            if ($jsonFiles.Count -gt 0) {
                $JsonFilePath = $jsonFiles[0].FullName
                Write-Host "Found latest JSON file: $JsonFilePath" -ForegroundColor Green
            }
        }
        
        if ([string]::IsNullOrWhiteSpace($JsonFilePath)) {
            Write-Error "No AI_Insights_Payload JSON file found in output folder. Please specify -JsonFilePath parameter or run an audit first."
            return
        }
    }
    
    # Resolve the JSON file path
    if (-not [System.IO.Path]::IsPathRooted($JsonFilePath)) {
        $JsonFilePath = Join-Path (Get-Location) $JsonFilePath
    }
    
    if (-not (Test-Path $JsonFilePath)) {
        Write-Error "JSON file not found: $JsonFilePath"
        return
    }
    
    Write-Host "Loading JSON from: $JsonFilePath" -ForegroundColor Gray
    
    # Read the JSON file
    try {
        $json = Get-Content $JsonFilePath -Raw -Encoding UTF8
    }
    catch {
        Write-Error "Failed to read JSON file: $_"
        return
    }
    
    # Get the output folder (same folder as the JSON file)
    $outputFolder = Split-Path -Parent $JsonFilePath
    
    Write-Host "Output folder: $outputFolder" -ForegroundColor Gray
    
    # Determine model to use (parameter > env var > default)
    $modelToUse = if ($Model) { $Model } elseif ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { "gpt-4o-mini" }
    Write-Host "Model: $modelToUse" -ForegroundColor Gray
    
    # Call the AI agent
    Write-Host "`nInvoking AI analysis..." -ForegroundColor Cyan
    try {
        $result = Invoke-AzureArchitectAgent `
            -GovernanceDataJson $json `
            -Model $modelToUse `
            -OutputPath $outputFolder
        
        if ($result.Success) {
            Write-Host "`n[SUCCESS] AI Analysis completed successfully!" -ForegroundColor Green
            Write-Host "  Analysis saved to: $outputFolder" -ForegroundColor Gray
            if ($result.Metadata) {
                Write-Host "  Estimated cost: `$$($result.Metadata.EstimatedCost.ToString('F4'))" -ForegroundColor Gray
                Write-Host "  Duration: $([math]::Round($result.Metadata.Duration.TotalSeconds, 1)) seconds" -ForegroundColor Gray
            }
        }
        else {
            Write-Error "AI Analysis failed: $($result.Error)"
        }
    }
    catch {
        Write-Error "Failed to invoke AI analysis: $_"
        Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) {
            Write-Host "Inner exception: $($_.Exception.InnerException.Message)" -ForegroundColor Red
        }
    }
}

# Summary of loaded functions (backend + interactive) – printed last so that all Test-* are defined
Write-Host "`nBackend / core functions (auto-loaded):" -ForegroundColor Cyan
$backendFunctions = @()

# Public exports
Get-ChildItem -Path "$ModuleRoot\Public\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
    $funcName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
    $backendFunctions += $funcName
}

# Collector entrypoints
Get-ChildItem -Path "$ModuleRoot\Private\Collectors\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
    $funcName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
    $backendFunctions += $funcName
}

$backendFunctions = $backendFunctions | Sort-Object -Unique
foreach ($funcName in $backendFunctions) {
    if (Get-Command $funcName -ErrorAction SilentlyContinue) {
        Write-Host "  - $funcName [OK]" -ForegroundColor Green
    } else {
        Write-Host "  - $funcName [MISSING]" -ForegroundColor Red
    }
}

Write-Host "`nInteractive / test functions:" -ForegroundColor Cyan

$userFunctions = @(
    'Connect-AuditEnvironment',
    'Invoke-AzureSecurityAudit',
    'Invoke-AzureArchitectAgent',
    'Test-SecurityReport',
    'Test-ChangeTracking',
    'Test-NetworkInventory',
    'Test-VMBackup',
    'Test-Advisor',
    'Test-EOLTracking',
    'Test-CostTracking',
    'Test-RBAC',
    'Test-RetryAIAnalysis'
)

foreach ($funcName in $userFunctions) {
    if (Get-Command $funcName -ErrorAction SilentlyContinue) {
        Write-Host "  - $funcName [OK]" -ForegroundColor Green
    } else {
        Write-Host "  - $funcName [MISSING]" -ForegroundColor Red
    }
}

Write-Host "`nTip: Common test commands:" -ForegroundColor Cyan
Write-Host "  - Connect-AuditEnvironment            # Sign in to Azure and select tenant/subscription" -ForegroundColor Gray
Write-Host "  - Invoke-AzureSecurityAudit -AI       # Run full audit with AI analysis" -ForegroundColor Gray
Write-Host "  - Invoke-AzureArchitectAgent          # Run AI analysis on governance data" -ForegroundColor Gray
Write-Host "  - Test-RetryAIAnalysis                # Retry AI analysis with existing JSON payload" -ForegroundColor Gray
Write-Host "  - Test-SecurityReport                 # Run security report (can take -SubscriptionIds/-Categories)" -ForegroundColor Gray
Write-Host "  - Test-ChangeTracking                 # Generate Change Tracking report" -ForegroundColor Gray
Write-Host "  - Test-NetworkInventory               # Generate Network Inventory report" -ForegroundColor Gray
Write-Host "  - Test-VMBackup                       # Generate VM Backup report" -ForegroundColor Gray
Write-Host "  - Test-Advisor                        # Generate Advisor report" -ForegroundColor Gray
Write-Host "  - Test-RBAC                           # Generate RBAC/IAM Inventory report" -ForegroundColor Gray
Write-Host "  - Test-CostTracking                   # Generate Cost Tracking report" -ForegroundColor Gray

