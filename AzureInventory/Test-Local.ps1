# Test-Local.ps1 - Snabb testning utan modul
# Kör detta skript för att ladda alla funktioner direkt för snabb testning
# Laddar automatiskt om funktioner om de redan finns
# 
# VIKTIGT: Du MÅSTE köra med punkt och mellanslag:
#   . .\Test-Local.ps1
# 
# Om du kör .\Test-Local.ps1 (utan punkt) fungerar det INTE!

param()

$ModuleRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }

# Varna om skriptet körs utan dot-source
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.Line -notmatch '^\s*\.\s+') {
    Write-Host "`n[ERROR] Script must be run with dot-source!" -ForegroundColor Red
    Write-Host "Use: . .\Test-Local.ps1" -ForegroundColor Yellow
    Write-Host "(Note the dot and space before the script name)`n" -ForegroundColor Yellow
    Write-Host "Current command: $($MyInvocation.Line)" -ForegroundColor Gray
    return
}

Write-Host "Reloading all functions for local testing..." -ForegroundColor Cyan

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
    # Helper functions
    'Get-SubscriptionContext',
    'Invoke-AzureApiWithRetry',
    'Invoke-WithSuppressedWarnings',
    'Invoke-WithErrorHandling',
    'New-SecurityFinding',
    'Get-SubscriptionDisplayName',
    'Get-EOLFindings',
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
    'Generate-AuditReports',
    # Config functions
    'Get-ControlDefinitions',
    # Scanner functions
    'Get-StorageAccountFindings',
    'Get-AppServiceFindings',
    'Get-VirtualMachineFindings',
    'Get-AzureArcFindings',
    'Get-AzureMonitorFindings',
    'Get-NetworkSecurityFindings',
    'Get-SqlDatabaseFindings',
    'Get-KeyVaultFindings',
    # Collector functions
    'Get-AzureAdvisorRecommendations',
    'Get-AzureChangeTracking',
    'Get-AzureActivityLogViaRestApi',
    'Convert-AdvisorRecommendation',
    'Group-AdvisorRecommendations',
    'Format-ExtendedPropertiesDetails',
    # Test functions
    'Test-ChangeTracking'
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
    try {
        . $_.FullName
        Write-Verbose "Loaded: $($_.Name)"
    }
    catch {
        Write-Warning "Failed to load $($_.Name): $_"
    }
}

# 2. Helpers (grundläggande helper-funktioner)
Write-Host "  Loading Private Helpers..." -ForegroundColor Gray
Get-ChildItem -Path "$ModuleRoot\Private\Helpers\*.ps1" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { 
    try {
        . $_.FullName
        Write-Verbose "Loaded: $($_.Name)"
    }
    catch {
        Write-Warning "Failed to load $($_.Name): $_"
    }
}

# 3. Scanners (använder helpers)
Write-Host "  Loading Private Scanners..." -ForegroundColor Gray
Get-ChildItem -Path "$ModuleRoot\Private\Scanners\*.ps1" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { 
    try {
        . $_.FullName
        Write-Verbose "Loaded: $($_.Name)"
    }
    catch {
        Write-Warning "Failed to load $($_.Name): $_"
    }
}

# 4. Collectors (använder helpers)
Write-Host "  Loading Private Collectors..." -ForegroundColor Gray
Get-ChildItem -Path "$ModuleRoot\Private\Collectors\*.ps1" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { 
    try {
        # Load by reading content and creating scriptblock (bypasses execution policy issues)
        $content = Get-Content $_.FullName -Raw -ErrorAction Stop
        $scriptBlock = [scriptblock]::Create($content)
        . $scriptBlock
        Write-Verbose "Loaded: $($_.Name)"
    }
    catch {
        # Fallback to direct dot-sourcing
        try {
            . $_.FullName -ErrorAction Stop
            Write-Verbose "Loaded: $($_.Name)"
        }
        catch {
            Write-Warning "Failed to load $($_.Name): $_"
        }
    }
}

# 5. Public Functions (använder allt ovanstående)
Write-Host "  Loading Public Functions..." -ForegroundColor Gray
Get-ChildItem -Path "$ModuleRoot\Public\*.ps1" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { 
    try {
        . $_.FullName
        Write-Verbose "Loaded: $($_.Name)"
    }
    catch {
        Write-Warning "Failed to load $($_.Name): $_"
    }
}

Write-Host "`n[OK] All functions loaded! Ready to test." -ForegroundColor Green
Write-Host "Available functions:" -ForegroundColor Cyan
$loadedFunctions = @()

# Check Public functions
Get-ChildItem -Path "$ModuleRoot\Public\*.ps1" | ForEach-Object {
    $funcName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
    if (Get-Command $funcName -ErrorAction SilentlyContinue) {
        Write-Host "  - $funcName [OK]" -ForegroundColor Green
        $loadedFunctions += $funcName
    } else {
        Write-Host "  - $funcName [MISSING]" -ForegroundColor Red
    }
}

# Check Collector functions (like Export-AdvisorReport)
Get-ChildItem -Path "$ModuleRoot\Private\Collectors\*.ps1" | ForEach-Object {
    $funcName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
    if (Get-Command $funcName -ErrorAction SilentlyContinue) {
        Write-Host "  - $funcName [OK]" -ForegroundColor Green
        $loadedFunctions += $funcName
    } else {
        Write-Host "  - $funcName [MISSING]" -ForegroundColor Red
    }
}

if ($loadedFunctions.Count -eq 0) {
    Write-Host "`n[WARNING] No functions were loaded!" -ForegroundColor Yellow
    Write-Host "Make sure you run this script with: . .\Test-Local.ps1" -ForegroundColor Yellow
    Write-Host "(Note the dot and space before the script name)" -ForegroundColor Yellow
} else {
    Write-Host "`nTip: You can also define this function in your PowerShell profile:" -ForegroundColor Cyan
    Write-Host '  function Reload-Audit { . .\Test-Local.ps1 }' -ForegroundColor Gray
    Write-Host "Then just run: Reload-Audit" -ForegroundColor Gray
}

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
    if (-not (Get-Command -Name Get-AzureChangeTracking -ErrorAction SilentlyContinue)) {
        Write-Error "Get-AzureChangeTracking function not found. Make sure Test-Local.ps1 has loaded all functions."
        return
    }
    
    if (-not (Get-Command -Name Export-ChangeTrackingReport -ErrorAction SilentlyContinue)) {
        Write-Error "Export-ChangeTrackingReport function not found. Make sure Test-Local.ps1 has loaded all functions."
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
    
    # Collect change tracking data
    $changeTrackingData = [System.Collections.Generic.List[PSObject]]::new()
    $tenantId = $context.Tenant.Id
    
    foreach ($sub in $subscriptions) {
        $subName = Get-SubscriptionDisplayName -Subscription $sub
        Write-Host "`nCollecting from: $subName ($($sub.Id))" -ForegroundColor Yellow
        
        # Double-check tenant ID before setting context
        if ($sub.TenantId -ne $currentTenantId) {
            Write-Warning "Skipping subscription $subName ($($sub.Id)) - tenant mismatch (expected $currentTenantId, got $($sub.TenantId))"
            continue
        }
        
        try {
            # Use TenantId parameter to ensure we stay in the correct tenant
            Set-AzContext -SubscriptionId $sub.Id -TenantId $currentTenantId -ErrorAction Stop | Out-Null
            
            try {
                $changes = Get-AzureChangeTracking -SubscriptionId $sub.Id -SubscriptionName $subName
                
                # Ensure changes is an array (handle null safely)
                if ($null -eq $changes) {
                    $changes = @()
                } else {
                    $changes = @($changes)
                }
                
                Write-Verbose "Get-AzureChangeTracking returned: Type=$($changes.GetType().FullName), Count=$($changes.Count)"
                
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
                Write-Warning "Failed to get changes from $subName : $_"
                Write-Verbose "Error details: $($_.Exception.Message)"
            }
        }
        catch {
            Write-Warning "Failed to collect from $subName : $_"
        }
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
            Write-Host "  Modifies: $($result.Modifies)" -ForegroundColor Gray
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

