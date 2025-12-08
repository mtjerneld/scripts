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
            $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
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
    
    foreach ($sub in $subscriptions) {
        $current++
        Write-Host "`n[$current/$total] Scanning: $($sub.Name) ($($sub.Id))" -ForegroundColor Yellow
        
        try {
            if (-not (Get-SubscriptionContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue)) {
                $errors.Add("Failed to set context for subscription $($sub.Name) ($($sub.Id))")
                continue
            }
        }
        catch {
            $errors.Add("Failed to set context for subscription $($sub.Name) ($($sub.Id)): $_")
            continue
        }
        
        foreach ($category in $categoriesToScan) {
            if (-not $scanners.ContainsKey($category)) {
                Write-Warning "Unknown category: $category"
                continue
            }
            
            Write-Host "  - $category..." -NoNewline
            try {
                # Pass IncludeLevel2 parameter to scanner functions
                $findings = & $scanners[$category] -subId $sub.Id -subName $sub.Name -includeL2:$IncludeLevel2
                
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
                # Filter out null findings and count failures
                $validFindings = $findings | Where-Object { $null -ne $_ }
                if ($null -eq $validFindings) { $validFindings = @() }
                
                # Count failures - ensure Status property exists
                $failCount = 0
                foreach ($finding in $validFindings) {
                    if ($finding.PSObject.Properties.Name -contains 'Status' -and $finding.Status -eq 'FAIL') {
                        $failCount++
                    }
                }
                
                $totalChecks = $validFindings.Count
                $color = if ($failCount -gt 0) { 'Red' } else { 'Green' }
                Write-Host " $totalChecks checks ($failCount failures)" -ForegroundColor $color
            }
            catch {
                Write-Host " ERROR: $_" -ForegroundColor Red
                $errors.Add("$category scan failed for $($sub.Name): $_")
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
    
    $result = [PSCustomObject]@{
        ScanStartTime       = $scanStart
        ScanEndTime         = Get-Date
        TenantId            = $tenantId
        SubscriptionsScanned = $subscriptions.Id
        TotalResources      = $uniqueResources
        FindingsBySeverity  = $findingsBySeverity
        FindingsByCategory  = $findingsByCategory
        Findings            = $allFindings
        Errors              = $errors
        ToolVersion         = "1.0.0"
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


