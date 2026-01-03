<#
.SYNOPSIS
    Unified Azure Governance Audit - supports both live and test data modes.

.DESCRIPTION
    Consolidated function for running Azure governance audits. Replaces both
    Invoke-AzureSecurityAudit (production) and Test-SingleReport (development).

    Supports:
    - All report types (Security, VMBackup, CostTracking, etc.)
    - Live mode (real Azure API data) and Test mode (mock data)
    - AI analysis integration
    - Flexible output options

.PARAMETER ReportType
    Type(s) of report to generate. Default: All
    Valid: Security, VMBackup, ChangeTracking, CostTracking, EOL, NetworkInventory, RBAC, Advisor, Dashboard, All

.PARAMETER Mode
    Data source mode. Default: Live
    - Live: Collect real data from Azure APIs
    - Test: Use generated mock data for development/testing

.PARAMETER SubscriptionIds
    (Live mode) Array of subscription IDs to scan. If not specified, scans all enabled subscriptions.

.PARAMETER OutputPath
    Custom output folder path. If not specified:
    - Live mode: output/{tenantId}-{timestamp}
    - Test mode: output-test/{timestamp}

.PARAMETER SaveDataPayload
    Save the collected/generated dataset as JSON file alongside reports.

.PARAMETER PassThru
    Return the AuditResult object instead of just generating reports.

.PARAMETER IncludeLevel2
    (Security) Include Level 2 CIS controls in the scan.

.PARAMETER CriticalStorageAccounts
    (Security) Array of storage account names for Level 2 CMK control.

.PARAMETER SecurityCategories
    (Security) Filter to specific security categories.
    Valid: All, Storage, AppService, VM, ARC, Monitor, Network, SQL, KeyVault

.PARAMETER SkipChangeTracking
    Skip collecting change tracking data.

.PARAMETER DaysToInclude
    (CostTracking) Number of days to include. Default: 30

.PARAMETER AI
    Enable AI-powered analysis. Requires OPENAI_API_KEY in environment/.env file.

.PARAMETER Help
    Display help information.

.EXAMPLE
    Start-AzureGovernanceAudit
    # Full audit with live data, all reports

.EXAMPLE
    Start-AzureGovernanceAudit -Mode Test
    # Full audit with mock data for testing

.EXAMPLE
    Start-AzureGovernanceAudit -ReportType CostTracking -Mode Test -SaveDataPayload
    # Generate only CostTracking report with test data, save dataset as JSON

.EXAMPLE
    Start-AzureGovernanceAudit -ReportType Security, RBAC -AI
    # Security and RBAC reports with AI analysis

.EXAMPLE
    Start-AzureGovernanceAudit -Mode Test -ReportType CostTracking -DaysToInclude 14
    # Test CostTracking with 14 days of mock data
#>
function Start-AzureGovernanceAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet('All', 'Security', 'VMBackup', 'ChangeTracking', 'CostTracking', 'EOL', 'NetworkInventory', 'RBAC', 'Advisor', 'Dashboard')]
        [string[]]$ReportType = @('All'),

        [Parameter(Mandatory = $false)]
        [ValidateSet('Live', 'Test')]
        [string]$Mode = 'Live',

        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionIds,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath,

        [Parameter(Mandatory = $false)]
        [switch]$SaveDataPayload,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeLevel2,

        [Parameter(Mandatory = $false)]
        [string[]]$CriticalStorageAccounts = @(),

        [Parameter(Mandatory = $false)]
        [ValidateSet('All', 'Storage', 'AppService', 'VM', 'ARC', 'Monitor', 'Network', 'SQL', 'KeyVault')]
        [string[]]$SecurityCategories = @('All'),

        [Parameter(Mandatory = $false)]
        [switch]$SkipChangeTracking,

        [Parameter(Mandatory = $false)]
        [int]$DaysToInclude = 30,

        [Parameter(Mandatory = $false)]
        [switch]$AI,

        [Parameter(Mandatory = $false)]
        [switch]$NoOpen,

        [Parameter(Mandatory = $false)]
        [switch]$Help
    )

    # Suppress progress bars to keep console output clean
    $ProgressPreference = 'SilentlyContinue'

    #region Help
    if ($Help) {
        Write-Host "`n=== Start-AzureGovernanceAudit ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "SYNOPSIS" -ForegroundColor Yellow
        Write-Host "  Unified Azure Governance Audit with live or test data support." -ForegroundColor White
        Write-Host ""
        Write-Host "USAGE" -ForegroundColor Yellow
        Write-Host "  Start-AzureGovernanceAudit [options]" -ForegroundColor White
        Write-Host ""
        Write-Host "PARAMETERS" -ForegroundColor Yellow
        Write-Host "  -ReportType <String[]>   Reports to generate (default: All)" -ForegroundColor White
        Write-Host "  -Mode <String>           'Live' (default) or 'Test'" -ForegroundColor White
        Write-Host "  -SubscriptionIds         Filter to specific subscriptions" -ForegroundColor White
        Write-Host "  -OutputPath              Custom output folder" -ForegroundColor White
        Write-Host "  -SaveDataPayload         Save dataset as JSON" -ForegroundColor White
        Write-Host "  -PassThru                Return result object" -ForegroundColor White
        Write-Host "  -IncludeLevel2           Include L2 CIS controls" -ForegroundColor White
        Write-Host "  -SecurityCategories      Filter security categories" -ForegroundColor White
        Write-Host "  -SkipChangeTracking      Skip change tracking" -ForegroundColor White
        Write-Host "  -DaysToInclude           Days for cost data (default: 30)" -ForegroundColor White
        Write-Host "  -AI                      Enable AI analysis" -ForegroundColor White
        Write-Host ""
        Write-Host "REPORT TYPES" -ForegroundColor Yellow
        Write-Host "  Security, VMBackup, ChangeTracking, CostTracking, EOL," -ForegroundColor White
        Write-Host "  NetworkInventory, RBAC, Advisor, Dashboard, All" -ForegroundColor White
        Write-Host ""
        Write-Host "EXAMPLES" -ForegroundColor Yellow
        Write-Host "  Start-AzureGovernanceAudit" -ForegroundColor Gray
        Write-Host "  Start-AzureGovernanceAudit -Mode Test" -ForegroundColor Gray
        Write-Host "  Start-AzureGovernanceAudit -ReportType CostTracking -Mode Test" -ForegroundColor Gray
        Write-Host "  Start-AzureGovernanceAudit -ReportType Security -AI" -ForegroundColor Gray
        Write-Host ""
        return
    }
    #endregion

    $scanStart = Get-Date
    $errors = [System.Collections.Generic.List[string]]::new()

    #region Validate Environment
    if ($Mode -eq 'Live') {
        $context = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $context) {
            Write-Error "Live mode requires Azure connection. Run Connect-AuditEnvironment first."
            return
        }
        $tenantId = $context.Tenant.Id
    }
    else {
        $tenantId = "test-tenant-00000"
    }
    #endregion

    #region Determine Report Types
    $allReportTypes = @('Security', 'VMBackup', 'ChangeTracking', 'CostTracking', 'EOL', 'NetworkInventory', 'RBAC', 'Advisor', 'Dashboard')

    if ('All' -in $ReportType) {
        $reportsToGenerate = $allReportTypes
    }
    else {
        $reportsToGenerate = $ReportType
    }
    #endregion

    #region Setup Output Folder
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    if ($OutputPath) {
        $outputFolder = $OutputPath
    }
    elseif ($Mode -eq 'Test') {
        $outputFolder = Join-Path $moduleRoot "output-test\$timestamp"
    }
    else {
        $outputFolder = Join-Path $moduleRoot "output\$tenantId-$timestamp"
    }

    if (-not (Test-Path $outputFolder)) {
        New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null
    }
    #endregion

    #region Header
    Write-Host "`n=== Azure Governance Audit ===" -ForegroundColor Cyan
    Write-Host "Mode: $Mode | Reports: $($reportsToGenerate.Count) | Output: $outputFolder" -ForegroundColor Gray
    Write-Host ""
    #endregion

    #region Get Subscriptions (Live mode)
    $subscriptions = @()
    $subscriptionNames = @{}

    if ($Mode -eq 'Live') {
        $subscriptionResult = Get-SubscriptionsToScan -SubscriptionIds $SubscriptionIds -Errors $errors
        $subscriptions = $subscriptionResult.Subscriptions

        if ($subscriptions.Count -eq 0) {
            Write-Warning "No subscriptions found to scan."
            return
        }

        foreach ($sub in $subscriptions) {
            $subName = Get-SubscriptionDisplayName -Subscription $sub
            $subscriptionNames[$sub.Id] = $subName
        }

        Write-Host "Scanning $($subscriptions.Count) subscription(s)..." -ForegroundColor Gray
    }
    else {
        # Test mode - create mock subscription info
        $subscriptions = @(
            [PSCustomObject]@{ Id = "sub-prod-001"; Name = "Sub-Prod-001"; TenantId = $tenantId }
            [PSCustomObject]@{ Id = "sub-dev-002"; Name = "Sub-Dev-002"; TenantId = $tenantId }
            [PSCustomObject]@{ Id = "sub-test-003"; Name = "Sub-Test-003"; TenantId = $tenantId }
        )
        foreach ($sub in $subscriptions) {
            $subscriptionNames[$sub.Id] = $sub.Name
        }
        Write-Host "Using mock data for $($subscriptions.Count) test subscription(s)..." -ForegroundColor Yellow
    }
    #endregion

    #region Initialize Data Collections
    $collectedData = @{
        Security         = $null
        VMBackup         = $null
        ChangeTracking   = $null
        CostTracking     = $null
        EOL              = $null
        NetworkInventory = $null
        RBAC             = $null
        Advisor          = $null
    }
    #endregion

    #region Collect Data
    Write-Host "`nCollecting Data..." -ForegroundColor Cyan

    # Determine which data to collect based on requested reports
    $dataToCollect = @()
    foreach ($report in $reportsToGenerate) {
        if ($report -eq 'Dashboard') {
            # Dashboard needs all data
            $dataToCollect = @('Security', 'VMBackup', 'ChangeTracking', 'CostTracking', 'EOL', 'NetworkInventory', 'RBAC', 'Advisor')
            break
        }
        elseif ($report -notin $dataToCollect) {
            $dataToCollect += $report
        }
    }

    foreach ($dataType in $dataToCollect) {
        # Skip change tracking if requested
        if ($dataType -eq 'ChangeTracking' -and $SkipChangeTracking) {
            Write-Host "  ChangeTracking: SKIPPED" -ForegroundColor Gray
            continue
        }

        # Security is special - it outputs categories, so handle it separately
        if ($dataType -eq 'Security') {
            Write-Host "  Security" -ForegroundColor Cyan
        }
        else {
            Write-Host "  $dataType..." -ForegroundColor Cyan
        }

        try {
            if ($Mode -eq 'Test') {
                $collectedData[$dataType] = Get-TestData -DataType $dataType -DaysToInclude $DaysToInclude
            }
            else {
                $collectedData[$dataType] = Get-LiveData -DataType $dataType -Subscriptions $subscriptions -DaysToInclude $DaysToInclude -IncludeLevel2:$IncludeLevel2 -CriticalStorageAccounts $CriticalStorageAccounts -SecurityCategories $SecurityCategories -Errors $errors
            }
            
            # Print OK on new line, aligned with data type name
            Write-Host "    OK" -ForegroundColor Green
        }
        catch {
            if ($dataType -eq 'Security') {
                Write-Host "    FAILED" -ForegroundColor Red
            }
            else {
                Write-Host "FAILED" -ForegroundColor Red
            }
            Write-Host "    Error: $_" -ForegroundColor Red
            $errors.Add("$dataType collection failed: $_")
        }
    }
    #endregion

    #region Save Data Payload
    if ($SaveDataPayload) {
        Write-Host "`n=== Saving Data Payload ===" -ForegroundColor Cyan
        foreach ($dataType in $dataToCollect) {
            if ($null -ne $collectedData[$dataType]) {
                $jsonPath = Join-Path $outputFolder "$($dataType.ToLower())-data.json"
                $collectedData[$dataType] | ConvertTo-Json -Depth 20 | Out-File -FilePath $jsonPath -Encoding UTF8
                Write-Host "  Saved: $($dataType.ToLower())-data.json" -ForegroundColor Gray
            }
        }
    }
    #endregion

    #region Build AuditResult Object
    $auditResult = New-AuditResult -CollectedData $collectedData -Subscriptions $subscriptions -SubscriptionNames $subscriptionNames -TenantId $tenantId -ScanStart $scanStart -IncludeLevel2:$IncludeLevel2 -Errors $errors
    #endregion

    #region Generate Reports
    Write-Host "`nGenerating Reports..." -ForegroundColor Cyan

    # Map report types to file names (must match navigation links in reports)
    $reportFileNames = @{
        'Security'         = 'security.html'
        'VMBackup'         = 'vm-backup.html'
        'ChangeTracking'   = 'change-tracking.html'
        'CostTracking'     = 'cost-tracking.html'
        'EOL'              = 'eol.html'
        'NetworkInventory' = 'network.html'
        'RBAC'             = 'rbac.html'
        'Advisor'          = 'advisor.html'
        'Dashboard'        = 'index.html'
    }

    # Initialize report data containers for Dashboard
    $securityReportData = $null
    $vmBackupReportData = $null
    $changeTrackingReportData = $null
    $costTrackingReportData = $null
    $eolReportData = $null
    $networkInventoryReportData = $null
    $rbacReportData = $null
    $advisorReportData = $null

    foreach ($report in $reportsToGenerate) {
        $fileName = $reportFileNames[$report]
        $outputPath = Join-Path $outputFolder $fileName
        Write-Host "  $report... " -NoNewline

        try {
            switch ($report) {
                'Security' {
                    if ($collectedData['Security']) {
                        $securityReportData = Export-SecurityReport -AuditResult $auditResult -OutputPath $outputPath
                        Write-Host "OK" -ForegroundColor Green
                    }
                    else {
                        Write-Host "SKIPPED (no data)" -ForegroundColor Gray
                    }
                }
                'VMBackup' {
                    if ($collectedData['VMBackup']) {
                        $vmBackupReportData = Export-VMBackupReport -VMInventory $collectedData['VMBackup'] -OutputPath $outputPath -TenantId $tenantId
                        Write-Host "OK" -ForegroundColor Green
                    }
                    else {
                        Write-Host "SKIPPED (no data)" -ForegroundColor Gray
                    }
                }
                'ChangeTracking' {
                    if ($collectedData['ChangeTracking']) {
                        $changeTrackingReportData = Export-ChangeTrackingReport -ChangeTrackingData $collectedData['ChangeTracking'] -OutputPath $outputPath -TenantId $tenantId
                        Write-Host "OK" -ForegroundColor Green
                    }
                    else {
                        Write-Host "SKIPPED (no data)" -ForegroundColor Gray
                    }
                }
                'CostTracking' {
                    if ($collectedData['CostTracking']) {
                        $costTrackingReportData = Export-CostTrackingReport -CostTrackingData $collectedData['CostTracking'] -OutputPath $outputPath -TenantId $tenantId
                        Write-Host "OK" -ForegroundColor Green
                    }
                    else {
                        Write-Host "SKIPPED (no data)" -ForegroundColor Gray
                    }
                }
                'EOL' {
                    if ($collectedData['EOL']) {
                        $eolReportData = Export-EOLReport -EOLFindings $collectedData['EOL'] -OutputPath $outputPath -TenantId $tenantId
                        Write-Host "OK" -ForegroundColor Green
                    }
                    else {
                        Write-Host "SKIPPED (no data)" -ForegroundColor Gray
                    }
                }
                'NetworkInventory' {
                    if ($collectedData['NetworkInventory']) {
                        $networkInventoryReportData = Export-NetworkInventoryReport -NetworkInventory $collectedData['NetworkInventory'] -OutputPath $outputPath -TenantId $tenantId
                        Write-Host "OK" -ForegroundColor Green
                    }
                    else {
                        Write-Host "SKIPPED (no data)" -ForegroundColor Gray
                    }
                }
                'RBAC' {
                    if ($collectedData['RBAC']) {
                        $rbacReportData = Export-RBACReport -RBACData $collectedData['RBAC'] -OutputPath $outputPath -TenantId $tenantId
                        Write-Host "OK" -ForegroundColor Green
                    }
                    else {
                        Write-Host "SKIPPED (no data)" -ForegroundColor Gray
                    }
                }
                'Advisor' {
                    if ($collectedData['Advisor']) {
                        $advisorReportData = Export-AdvisorReport -AdvisorRecommendations $collectedData['Advisor'] -OutputPath $outputPath -TenantId $tenantId
                        Write-Host "OK" -ForegroundColor Green
                    }
                    else {
                        Write-Host "SKIPPED (no data)" -ForegroundColor Gray
                    }
                }
                'Dashboard' {
                    # Convert VMInventory to List for Export-DashboardReport
                    $vmList = [System.Collections.Generic.List[PSObject]]::new()
                    if ($auditResult.VMInventory) {
                        foreach ($vm in $auditResult.VMInventory) {
                            $vmList.Add($vm)
                        }
                    }
                    
                    Export-DashboardReport `
                        -AuditResult $auditResult `
                        -VMInventory $vmList `
                        -OutputPath $outputPath `
                        -TenantId $tenantId `
                        -SecurityReportData $securityReportData `
                        -VMBackupReportData $vmBackupReportData `
                        -AdvisorReportData $advisorReportData `
                        -ChangeTrackingReportData $changeTrackingReportData `
                        -NetworkInventoryReportData $networkInventoryReportData `
                        -CostTrackingReportData $costTrackingReportData `
                        -RBACReportData $rbacReportData `
                        -EOLReportData $eolReportData | Out-Null
                        
                    Write-Host "OK" -ForegroundColor Green
                }
            }
        }
        catch {
            Write-Host "FAILED" -ForegroundColor Red
            Write-Host "    Error: $_" -ForegroundColor Red
        }
    }
    #endregion

    #region AI Analysis
    if ($AI) {
        Write-Host "`n=== AI Analysis ===" -ForegroundColor Cyan
        Invoke-AIAnalysis -AuditResult $auditResult -CollectedData $collectedData -OutputFolder $outputFolder -Errors $errors
    }
    #endregion

    #region Summary
    $scanEnd = Get-Date
    $duration = $scanEnd - $scanStart

    Write-Host "`n=== Scan Complete ===" -ForegroundColor Green
    Write-Host "Duration: $($duration.ToString('mm\:ss')) | Output: $outputFolder" -ForegroundColor Gray

    if ($errors.Count -gt 0) {
        Write-Host "`nErrors: $($errors.Count)" -ForegroundColor Yellow
        foreach ($err in $errors | Select-Object -First 5) {
            Write-Host "  - $err" -ForegroundColor Red
        }
        if ($errors.Count -gt 5) {
            Write-Host "  ... and $($errors.Count - 5) more" -ForegroundColor Gray
        }
    }

    # Clickable link
    $dashboardUri = "file:///$($outputFolder.Replace('\', '/'))/index.html"
    Write-Host "`nOpen: " -NoNewline
    Write-Host $dashboardUri -ForegroundColor Cyan
    
    # Open report automatically (unless -NoOpen specified)
    if (-not $NoOpen) {
        $dashboardPath = Join-Path $outputFolder "index.html"
        
        if (($reportsToGenerate -contains 'Dashboard' -or 'All' -in $ReportType) -and (Test-Path $dashboardPath)) {
            Invoke-Item $dashboardPath
        }
        elseif ($reportsToGenerate.Count -eq 1) {
            # Open the single report generated
            $singleReport = $reportsToGenerate[0]
            if ($reportFileNames.ContainsKey($singleReport)) {
                $singlePath = Join-Path $outputFolder $reportFileNames[$singleReport]
                if (Test-Path $singlePath) {
                    Invoke-Item $singlePath
                }
            }
        }
        else {
            # Multiple reports but no dashboard, open folder
            Invoke-Item $outputFolder
        }
    }
    #endregion

    #region Return
    if ($PassThru) {
        return $auditResult
    }

    return [PSCustomObject]@{
        OutputFolder = $outputFolder
        Mode         = $Mode
        ReportTypes  = $reportsToGenerate
        Duration     = $duration
        Errors       = $errors
    }
    #endregion
}

#region Helper Functions

function Get-TestData {
    param(
        [string]$DataType,
        [int]$DaysToInclude
    )

    switch ($DataType) {
        'Security' { return New-TestSecurityData }
        'VMBackup' { return New-TestVMBackupData }
        'ChangeTracking' { return New-TestChangeTrackingData -ChangeCount 75 }
        'CostTracking' { return New-TestCostTrackingData -DayCount $DaysToInclude }
        'EOL' { return New-TestEOLData }
        'NetworkInventory' { return New-TestNetworkInventoryData }
        'RBAC' { return New-TestRBACData }
        'Advisor' { return New-TestAdvisorData }
        default { return $null }
    }
}

function Get-LiveData {
    param(
        [string]$DataType,
        [array]$Subscriptions,
        [int]$DaysToInclude,
        [switch]$IncludeLevel2,
        [string[]]$CriticalStorageAccounts,
        [string[]]$SecurityCategories,
        [System.Collections.Generic.List[string]]$Errors
    )

    switch ($DataType) {
        'Security' {
            return Get-LiveSecurityData -Subscriptions $Subscriptions -IncludeLevel2:$IncludeLevel2 -CriticalStorageAccounts $CriticalStorageAccounts -SecurityCategories $SecurityCategories -Errors $Errors
        }
        'VMBackup' {
            return Collect-VMBackupData -Subscriptions $Subscriptions
        }
        'ChangeTracking' {
            $changeData = [System.Collections.Generic.List[PSObject]]::new()
            Collect-ChangeTrackingData -Subscriptions $Subscriptions -ChangeTrackingData $changeData -Errors $Errors
            return @($changeData)
        }
        'CostTracking' {
            return Collect-CostData -Subscriptions $Subscriptions -DaysToInclude $DaysToInclude -Errors $Errors
        }
        'EOL' {
            $subIds = @($Subscriptions.Id)
            $eolResults = Get-AzureEOLStatus -SubscriptionIds $subIds
            $eolFindings = [System.Collections.Generic.List[PSObject]]::new()
            
            if ($eolResults) {
                Convert-EOLResultsToFindings -EOLResults $eolResults -EOLFindings $eolFindings
            }
            
            Write-Host "    $($eolFindings.Count) EOL findings" -ForegroundColor $(if ($eolFindings.Count -gt 0) { 'Green' } else { 'Gray' })
            return $eolFindings
        }
        'NetworkInventory' {
            $networkData = [System.Collections.Generic.List[PSObject]]::new()
            Collect-NetworkInventory -Subscriptions $Subscriptions -NetworkInventory $networkData -Errors $Errors
            return @($networkData)
        }
        'RBAC' {
            $tenantId = (Get-AzContext).Tenant.Id
            $subIds = @($Subscriptions.Id)
            return Get-AzureRBACInventory -SubscriptionIds $subIds -TenantId $tenantId
        }
        'Advisor' {
            $advisorData = [System.Collections.Generic.List[PSObject]]::new()
            Collect-AdvisorRecommendations -Subscriptions $Subscriptions -AdvisorRecommendations $advisorData -Errors $Errors
            return @($advisorData)
        }
        default { return $null }
    }
}

function Get-LiveSecurityData {
    param(
        [array]$Subscriptions,
        [switch]$IncludeLevel2,
        [string[]]$CriticalStorageAccounts,
        [string[]]$SecurityCategories,
        [System.Collections.Generic.List[string]]$Errors
    )

    $allFindings = [System.Collections.Generic.List[PSObject]]::new()
    $allEOLFindings = [System.Collections.Generic.List[PSObject]]::new()
    $vmInventory = [System.Collections.Generic.List[PSObject]]::new()

    $scanners = @{
        'Storage'    = { param($subId, $subName) Get-AzureStorageFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$IncludeLevel2 -CriticalStorageAccounts $CriticalStorageAccounts }
        'AppService' = { param($subId, $subName, $includeL2) Get-AzureAppServiceFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 }
        'VM'         = { param($subId, $subName, $includeL2) Get-AzureVirtualMachineFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 }
        'ARC'        = { param($subId, $subName) Get-AzureArcFindings -SubscriptionId $subId -SubscriptionName $subName }
        'Monitor'    = { param($subId, $subName) Get-AzureMonitorFindings -SubscriptionId $subId -SubscriptionName $subName }
        'Network'    = { param($subId, $subName, $includeL2) Get-AzureNetworkFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 }
        'SQL'        = { param($subId, $subName, $includeL2) Get-AzureSqlDatabaseFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 }
        'KeyVault'   = { param($subId, $subName, $includeL2) Get-AzureKeyVaultFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$includeL2 }
    }

    if ('All' -in $SecurityCategories) {
        $categoriesToScan = $scanners.Keys
    }
    else {
        $categoriesToScan = $SecurityCategories
    }

    $currentTenantId = (Get-AzContext).Tenant.Id

    foreach ($sub in $Subscriptions) {
        if ($currentTenantId -and $sub.TenantId -ne $currentTenantId) {
            continue
        }

        Write-Host "  Scanning $($sub.Name)..." -ForegroundColor Yellow

        Invoke-ScannerForSubscription `
            -Subscription $sub `
            -CategoriesToScan $categoriesToScan `
            -Scanners $scanners `
            -IncludeLevel2:$IncludeLevel2 `
            -AllFindings $allFindings `
            -AllEOLFindings $allEOLFindings `
            -VMInventory $vmInventory `
            -Errors $Errors `
            -SuppressOutput
    }

    # Calculate aggregated summary
    if ($allFindings.Count -gt 0) {
        $uniqueResources = $allFindings | Select-Object -ExpandProperty ResourceId -Unique | Measure-Object | Select-Object -ExpandProperty Count
        $uniqueChecks = $allFindings | Select-Object -Property Category, ControlId -Unique | Measure-Object | Select-Object -ExpandProperty Count
        $failureCount = ($allFindings | Where-Object { $_.Status -eq 'FAIL' }).Count
        
        $color = if ($failureCount -gt 0) { 'Red' } else { 'Green' }
        Write-Host "    $uniqueResources unique resources evaluated against $uniqueChecks checks ($failureCount failures)" -ForegroundColor $color
    }

    return [PSCustomObject]@{
        Findings    = $allFindings
        EOLFindings = $allEOLFindings
        VMInventory = $vmInventory
    }
}

function New-AuditResult {
    param(
        [hashtable]$CollectedData,
        [array]$Subscriptions,
        [hashtable]$SubscriptionNames,
        [string]$TenantId,
        [datetime]$ScanStart,
        [switch]$IncludeLevel2,
        [System.Collections.Generic.List[string]]$Errors
    )

    # Extract security data
    $findings = @()
    $eolFindings = @()
    $vmInventory = @()

    if ($CollectedData['Security']) {
        $secData = $CollectedData['Security']
        if ($secData.Findings) { $findings = @($secData.Findings) }
        if ($secData.EOLFindings) { $eolFindings = @($secData.EOLFindings) }
        if ($secData.VMInventory) { $vmInventory = @($secData.VMInventory) }
    }

    # If VMBackup collected separately, use that
    if ($CollectedData['VMBackup'] -and $CollectedData['VMBackup'].Count -gt 0) {
        $vmInventory = @($CollectedData['VMBackup'])
    }

    # If EOL collected separately, use that
    if ($CollectedData['EOL'] -and $CollectedData['EOL'].Count -gt 0) {
        $eolFindings = @($CollectedData['EOL'])
    }

    # Count unique resources
    $uniqueResourceIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($finding in $findings) {
        if ($finding.ResourceId) {
            [void]$uniqueResourceIds.Add($finding.ResourceId)
        }
    }

    # Count findings by severity (FAIL only)
    $findingsBySeverity = @{
        Critical = 0
        High     = 0
        Medium   = 0
        Low      = 0
    }
    $findingsByCategory = @{}

    foreach ($finding in $findings) {
        if ($finding.Status -eq 'FAIL') {
            $sev = $finding.Severity
            if ($findingsBySeverity.ContainsKey($sev)) {
                $findingsBySeverity[$sev]++
            }
            $cat = if ($finding.Category) { $finding.Category } else { "Unknown" }
            if (-not $findingsByCategory.ContainsKey($cat)) {
                $findingsByCategory[$cat] = 0
            }
            $findingsByCategory[$cat]++
        }
    }

    # Calculate compliance score if we have security data
    $complianceScores = $null
    if ($findings.Count -gt 0 -and (Get-Command -Name Get-SeverityWeights -ErrorAction SilentlyContinue)) {
        $complianceScores = Measure-CisComplianceScoreInternal -Findings $findings -IncludeLevel2:$IncludeLevel2
    }

    return [PSCustomObject]@{
        ScanStartTime          = $ScanStart
        ScanEndTime            = Get-Date
        TenantId               = $TenantId
        SubscriptionsScanned   = @($Subscriptions.Id)
        SubscriptionNames      = $SubscriptionNames
        TotalResources         = $uniqueResourceIds.Count
        FindingsBySeverity     = $findingsBySeverity
        FindingsByCategory     = $findingsByCategory
        Findings               = $findings
        EOLFindings            = $eolFindings
        VMInventory            = $vmInventory
        AdvisorRecommendations = @($CollectedData['Advisor'])
        ChangeTrackingData     = @($CollectedData['ChangeTracking'])
        NetworkInventory       = @($CollectedData['NetworkInventory'])
        CostTrackingData       = $CollectedData['CostTracking']
        RBACInventory          = $CollectedData['RBAC']
        ComplianceScores       = $complianceScores
        EOLStatus              = @()
        Errors                 = $Errors
        ToolVersion            = "3.0.0"
        AIAnalysis             = $null
    }
}

function Measure-CisComplianceScoreInternal {
    param(
        [array]$Findings,
        [switch]$IncludeLevel2
    )

    $severityWeights = Get-SeverityWeights
    $levelMultipliers = Get-LevelMultipliers

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
            OverallScore     = 100
            L1Score          = 100
            L2Score          = $null
            ScoresByCategory = @{}
            TotalChecks      = 0
            PassedChecks     = 0
        }
    }

    $totalWeight = 0
    $passedWeight = 0

    foreach ($finding in $scoredFindings) {
        # Handle null Severity/CisLevel with defaults
        $sev = if ($finding.Severity) { $finding.Severity } else { 'Low' }
        $level = if ($finding.CisLevel) { $finding.CisLevel } else { 'L1' }

        $severityWeight = if ($severityWeights.ContainsKey($sev)) { $severityWeights[$sev] } else { 1 }
        $levelMultiplier = if ($levelMultipliers.ContainsKey($level)) { $levelMultipliers[$level] } else { 1 }
        $weight = $severityWeight * $levelMultiplier

        $totalWeight += $weight
        if ($finding.Status -eq 'PASS') {
            $passedWeight += $weight
        }
    }

    $overallScore = if ($totalWeight -gt 0) { [math]::Round(($passedWeight / $totalWeight) * 100, 2) } else { 100 }
    $passedChecks = @($scoredFindings | Where-Object { $_.Status -eq 'PASS' }).Count

    return @{
        OverallScore     = $overallScore
        L1Score          = $overallScore
        L2Score          = $null
        ScoresByCategory = @{}
        TotalChecks      = $scoredFindings.Count
        PassedChecks     = $passedChecks
    }
}

function Invoke-AIAnalysis {
    param(
        [PSCustomObject]$AuditResult,
        [hashtable]$CollectedData,
        [string]$OutputFolder,
        [System.Collections.Generic.List[string]]$Errors
    )

    $openAIKey = $env:OPENAI_API_KEY
    if ([string]::IsNullOrWhiteSpace($openAIKey)) {
        Write-Warning "OPENAI_API_KEY not set. Skipping AI analysis."
        return
    }

    try {
        # Load converter functions if needed
        $moduleRoot = Split-Path -Parent $PSScriptRoot
        $converterFunctions = @(
            "ConvertTo-AdvisorAIInsights",
            "ConvertTo-SecurityAIInsights",
            "ConvertTo-RBACAIInsights",
            "ConvertTo-NetworkAIInsights",
            "ConvertTo-EOLAIInsights",
            "ConvertTo-ChangeTrackingAIInsights",
            "ConvertTo-VMBackupAIInsights",
            "ConvertTo-CostTrackingAIInsights",
            "ConvertTo-CombinedPayload"
        )

        foreach ($funcName in $converterFunctions) {
            if (-not (Get-Command -Name $funcName -ErrorAction SilentlyContinue)) {
                $funcPath = Join-Path $moduleRoot "Private\Helpers\$funcName.ps1"
                if (Test-Path $funcPath) {
                    . $funcPath
                }
            }
        }

        # Generate insights
        $insights = @{}

        if ($AuditResult.AdvisorRecommendations.Count -gt 0) {
            Write-Host "  Advisor insights..." -ForegroundColor Gray
            $insights['Advisor'] = ConvertTo-AdvisorAIInsights -AdvisorRecommendations $AuditResult.AdvisorRecommendations -TopN 15
        }

        if ($AuditResult.Findings.Count -gt 0) {
            Write-Host "  Security insights..." -ForegroundColor Gray
            $insights['Security'] = ConvertTo-SecurityAIInsights -Findings $AuditResult.Findings -TopN 20
        }

        if ($AuditResult.RBACInventory) {
            Write-Host "  RBAC insights..." -ForegroundColor Gray
            $insights['RBAC'] = ConvertTo-RBACAIInsights -RBACData $AuditResult.RBACInventory -TopN 20
        }

        if ($AuditResult.NetworkInventory.Count -gt 0) {
            Write-Host "  Network insights..." -ForegroundColor Gray
            $insights['Network'] = ConvertTo-NetworkAIInsights -NetworkInventory $AuditResult.NetworkInventory -TopN 20
        }

        if ($AuditResult.EOLFindings.Count -gt 0) {
            Write-Host "  EOL insights..." -ForegroundColor Gray
            $insights['EOL'] = ConvertTo-EOLAIInsights -EOLFindings $AuditResult.EOLFindings -TopN 20
        }

        if ($AuditResult.ChangeTrackingData.Count -gt 0) {
            Write-Host "  ChangeTracking insights..." -ForegroundColor Gray
            $insights['ChangeTracking'] = ConvertTo-ChangeTrackingAIInsights -ChangeTrackingData $AuditResult.ChangeTrackingData -TopN 20
        }

        if ($AuditResult.VMInventory.Count -gt 0) {
            Write-Host "  VMBackup insights..." -ForegroundColor Gray
            $insights['VMBackup'] = ConvertTo-VMBackupAIInsights -VMInventory $AuditResult.VMInventory -TopN 20
        }

        if ($AuditResult.CostTrackingData) {
            Write-Host "  CostTracking insights..." -ForegroundColor Gray
            $insights['CostTracking'] = ConvertTo-CostTrackingAIInsights -CostTrackingData $AuditResult.CostTrackingData -TopN 20
        }

        if ($insights.Count -gt 0) {
            Write-Host "  Building combined payload..." -ForegroundColor Gray
            $combinedPayload = ConvertTo-CombinedPayload `
                -AdvisorInsights $insights['Advisor'] `
                -SecurityInsights $insights['Security'] `
                -RBACInsights $insights['RBAC'] `
                -NetworkInsights $insights['Network'] `
                -EOLInsights $insights['EOL'] `
                -ChangeTrackingInsights $insights['ChangeTracking'] `
                -VMBackupInsights $insights['VMBackup'] `
                -CostTrackingInsights $insights['CostTracking'] `
                -SubscriptionCount $AuditResult.SubscriptionsScanned.Count

            $jsonPayload = $combinedPayload | ConvertTo-Json -Depth 10

            # Save payload
            $payloadFile = Join-Path $OutputFolder "ai-payload.json"
            $jsonPayload | Out-File $payloadFile -Encoding UTF8

            # Call AI agent
            Write-Host "  Calling AI agent..." -ForegroundColor Gray
            if (Get-Command -Name Invoke-AzureArchitectAgent -ErrorAction SilentlyContinue) {
                $aiResult = Invoke-AzureArchitectAgent `
                    -GovernanceDataJson $jsonPayload `
                    -ApiKey $openAIKey `
                    -OutputPath $OutputFolder

                if ($aiResult.Success) {
                    Write-Host "  AI analysis complete" -ForegroundColor Green
                    $AuditResult.AIAnalysis = $aiResult
                }
                else {
                    Write-Warning "AI analysis failed: $($aiResult.Error)"
                }
            }
        }
    }
    catch {
        Write-Warning "AI analysis error: $_"
        $Errors.Add("AI analysis failed: $_")
    }
}

#endregion

# Alias for backward compatibility
Set-Alias -Name Invoke-AzureSecurityAudit -Value Start-AzureGovernanceAudit -Scope Global -ErrorAction SilentlyContinue
