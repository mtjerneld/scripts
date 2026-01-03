<#
.SYNOPSIS
    Consolidated test function for generating reports with test or live data.

.DESCRIPTION
    Generates reports using either mock test data or real Azure API data.
    All output goes to timestamped folders in output-test/.

.PARAMETER ReportType
    Type of report to generate: Security, VMBackup, ChangeTracking, CostTracking, EOL, NetworkInventory, RBAC, Advisor, Dashboard, All

.PARAMETER Mode
    Data source mode: 'Test' (mock data) or 'Live' (Azure API data). Default: Test

.PARAMETER SaveJson
    Save the raw dataset to JSON file alongside the HTML report.

.PARAMETER SubscriptionIds
    (Live mode only) Array of subscription IDs to scan. If not specified, scans all enabled subscriptions.

.PARAMETER DaysToInclude
    (CostTracking only) Number of days to include in cost analysis. Default: 30

.PARAMETER Help
    Display help information.

.EXAMPLE
    Test-SingleReport -Help

.EXAMPLE
    Test-SingleReport -ReportType CostTracking

.EXAMPLE
    Test-SingleReport -ReportType CostTracking -Mode Live

.EXAMPLE
    Test-SingleReport -ReportType All -Mode Test -SaveJson

.EXAMPLE
    Test-SingleReport -ReportType Security -Mode Live -SubscriptionIds "sub-123"
#>
function Test-SingleReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [ValidateSet('Security','VMBackup','ChangeTracking','CostTracking','EOL','NetworkInventory','RBAC','Advisor','Dashboard','All')]
        [string]$ReportType,

        [Parameter(Mandatory=$false)]
        [ValidateSet('Test','Live')]
        [string]$Mode = 'Test',

        [Parameter(Mandatory=$false)]
        [switch]$SaveJson,

        [Parameter(Mandatory=$false)]
        [string[]]$SubscriptionIds,

        [Parameter(Mandatory=$false)]
        [int]$DaysToInclude = 30,

        [Parameter(Mandatory=$false)]
        [switch]$Help
    )

    # Show help if requested
    if ($Help) {
        Write-Host "`n=== Test-SingleReport - Help ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "SYNOPSIS" -ForegroundColor Yellow
        Write-Host "  Generate reports using test data or live Azure API data." -ForegroundColor White
        Write-Host ""
        Write-Host "PARAMETERS" -ForegroundColor Yellow
        Write-Host "  -ReportType <String>  Required. Type of report to generate." -ForegroundColor White
        Write-Host "  -Mode <String>        'Test' (default) or 'Live'" -ForegroundColor White
        Write-Host "  -SaveJson             Save raw dataset to JSON file" -ForegroundColor White
        Write-Host "  -SubscriptionIds      (Live mode) Filter to specific subscriptions" -ForegroundColor White
        Write-Host "  -DaysToInclude        (CostTracking) Days to include. Default: 30" -ForegroundColor White
        Write-Host "  -Help                 Display this help" -ForegroundColor White
        Write-Host ""
        Write-Host "REPORT TYPES" -ForegroundColor Yellow
        Write-Host "  Security, VMBackup, ChangeTracking, CostTracking, EOL," -ForegroundColor White
        Write-Host "  NetworkInventory, RBAC, Advisor, Dashboard, All" -ForegroundColor White
        Write-Host ""
        Write-Host "EXAMPLES" -ForegroundColor Yellow
        Write-Host "  Test-SingleReport -ReportType CostTracking" -ForegroundColor Gray
        Write-Host "  Test-SingleReport -ReportType CostTracking -Mode Live" -ForegroundColor Gray
        Write-Host "  Test-SingleReport -ReportType All -SaveJson" -ForegroundColor Gray
        Write-Host "  Test-SingleReport -ReportType Security -Mode Live -SubscriptionIds 'sub-123'" -ForegroundColor Gray
        Write-Host ""
        return
    }

    # Require ReportType
    if (-not $ReportType) {
        Write-Host "`nError: -ReportType is required. Use -Help to see options." -ForegroundColor Red
        return
    }

    # Validate required export functions
    $exportFunctions = @{
        'Security' = 'Export-SecurityReport'
        'VMBackup' = 'Export-VMBackupReport'
        'ChangeTracking' = 'Export-ChangeTrackingReport'
        'CostTracking' = 'Export-CostTrackingReport'
        'EOL' = 'Export-EOLReport'
        'NetworkInventory' = 'Export-NetworkInventoryReport'
        'RBAC' = 'Export-RBACReport'
        'Advisor' = 'Export-AdvisorReport'
        'Dashboard' = 'Export-DashboardReport'
    }

    $requiredFunctions = if ($ReportType -eq 'All') { $exportFunctions.Values } else { @($exportFunctions[$ReportType]) }
    $missingFunctions = @()
    foreach ($func in $requiredFunctions) {
        if (-not (Get-Command $func -ErrorAction SilentlyContinue)) {
            $missingFunctions += $func
        }
    }
    if ($missingFunctions.Count -gt 0) {
        Write-Error "Required functions not available: $($missingFunctions -join ', '). Run Init-Local.ps1 first."
        return
    }

    # For Live mode, validate Azure connection
    if ($Mode -eq 'Live') {
        $context = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $context) {
            Write-Error "Live mode requires Azure connection. Run Connect-AuditEnvironment first."
            return
        }
        $tenantId = $context.Tenant.Id
        Write-Host "Connected to tenant: $tenantId" -ForegroundColor Gray
    } else {
        $tenantId = "test-tenant-00000"
    }

    # Create output folder: output-test/{timestamp}/
    $projectRoot = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { Get-Location }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outputFolder = Join-Path (Join-Path $projectRoot "output-test") $timestamp

    if (-not (Test-Path $outputFolder)) {
        New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null
    }

    Write-Host "`n=== Test-SingleReport ===" -ForegroundColor Cyan
    Write-Host "Mode: $Mode" -ForegroundColor $(if ($Mode -eq 'Live') { 'Green' } else { 'Yellow' })
    Write-Host "Report: $ReportType" -ForegroundColor White
    Write-Host "Output: $outputFolder" -ForegroundColor Gray
    Write-Host ""

    # Define report types to generate
    $reportTypes = if ($ReportType -eq 'All') {
        @('Security','VMBackup','ChangeTracking','CostTracking','EOL','NetworkInventory','RBAC','Advisor','Dashboard')
    } else {
        @($ReportType)
    }

    # Collect all data first (needed for Dashboard)
    $allData = @{}

    foreach ($type in $reportTypes) {
        if ($type -eq 'Dashboard') { continue }  # Dashboard uses collected data

        Write-Host "Collecting $type data..." -ForegroundColor Yellow

        $data = $null

        if ($Mode -eq 'Test') {
            # Use test data generators from New-TestData.ps1
            $data = switch ($type) {
                'Security' { New-TestSecurityData }
                'VMBackup' { New-TestVMBackupData }
                'ChangeTracking' { New-TestChangeTrackingData -ChangeCount 75 }
                'CostTracking' { New-TestCostTrackingData -DayCount $DaysToInclude }
                'EOL' { New-TestEOLData }
                'NetworkInventory' { New-TestNetworkInventoryData }
                'RBAC' { New-TestRBACData }
                'Advisor' { New-TestAdvisorData }
            }
        } else {
            # Use live data collectors
            $data = switch ($type) {
                'Security' { Get-LiveSecurityData -SubscriptionIds $SubscriptionIds }
                'VMBackup' { Get-LiveVMBackupData -SubscriptionIds $SubscriptionIds }
                'ChangeTracking' { Get-LiveChangeTrackingData -SubscriptionIds $SubscriptionIds }
                'CostTracking' { Get-LiveCostTrackingData -SubscriptionIds $SubscriptionIds -DaysToInclude $DaysToInclude }
                'EOL' { Get-LiveEOLData -SubscriptionIds $SubscriptionIds }
                'NetworkInventory' { Get-LiveNetworkInventoryData -SubscriptionIds $SubscriptionIds }
                'RBAC' { Get-LiveRBACData -SubscriptionIds $SubscriptionIds }
                'Advisor' { Get-LiveAdvisorData -SubscriptionIds $SubscriptionIds }
            }
        }

        if ($null -eq $data) {
            Write-Warning "No data collected for $type"
            continue
        }

        $allData[$type] = $data

        # Save JSON if requested
        if ($SaveJson) {
            $jsonPath = Join-Path $outputFolder "$($type.ToLower())-data.json"
            $data | ConvertTo-Json -Depth 20 | Out-File -FilePath $jsonPath -Encoding UTF8
            Write-Host "  Saved: $($type.ToLower())-data.json" -ForegroundColor Gray
        }
    }

    # Generate reports
    Write-Host "`nGenerating reports..." -ForegroundColor Cyan

    foreach ($type in $reportTypes) {
        $outputPath = Join-Path $outputFolder "$($type.ToLower()).html"

        Write-Host "  $type..." -NoNewline

        try {
            switch ($type) {
                'Security' {
                    Export-SecurityReport -AuditResult $allData['Security'] -OutputPath $outputPath | Out-Null
                }
                'VMBackup' {
                    Export-VMBackupReport -VMInventory $allData['VMBackup'] -OutputPath $outputPath -TenantId $tenantId | Out-Null
                }
                'ChangeTracking' {
                    Export-ChangeTrackingReport -ChangeTrackingData $allData['ChangeTracking'] -OutputPath $outputPath -TenantId $tenantId | Out-Null
                }
                'CostTracking' {
                    Export-CostTrackingReport -CostTrackingData $allData['CostTracking'] -OutputPath $outputPath -TenantId $tenantId | Out-Null
                }
                'EOL' {
                    Export-EOLReport -EOLFindings $allData['EOL'] -OutputPath $outputPath -TenantId $tenantId | Out-Null
                }
                'NetworkInventory' {
                    Export-NetworkInventoryReport -NetworkInventory $allData['NetworkInventory'] -OutputPath $outputPath -TenantId $tenantId | Out-Null
                }
                'RBAC' {
                    Export-RBACReport -RBACData $allData['RBAC'] -OutputPath $outputPath -TenantId $tenantId | Out-Null
                }
                'Advisor' {
                    Export-AdvisorReport -AdvisorRecommendations $allData['Advisor'] -OutputPath $outputPath -TenantId $tenantId | Out-Null
                }
                'Dashboard' {
                    # Dashboard needs compiled AuditResult
                    $auditResult = Build-DashboardAuditResult -AllData $allData -TenantId $tenantId
                    Export-DashboardReport -AuditResult $auditResult -OutputPath $outputPath | Out-Null
                }
            }
            Write-Host " OK" -ForegroundColor Green
        }
        catch {
            Write-Host " FAILED" -ForegroundColor Red
            Write-Host "    Error: $_" -ForegroundColor Red
        }
    }

    Write-Host "`n[OK] Reports generated in: $outputFolder" -ForegroundColor Green

    # Return summary
    return [PSCustomObject]@{
        OutputFolder = $outputFolder
        Mode = $Mode
        ReportTypes = $reportTypes
        Timestamp = $timestamp
    }
}

#region Live Data Collectors

function Get-LiveSecurityData {
    param([string[]]$SubscriptionIds)

    # Check required functions
    foreach ($fn in @('Get-SubscriptionsToScan','Invoke-ScannerForSubscription')) {
        if (-not (Get-Command -Name $fn -ErrorAction SilentlyContinue)) {
            Write-Error "$fn function not found."
            return $null
        }
    }

    $context = Get-AzContext
    $errors = [System.Collections.Generic.List[string]]::new()
    $subscriptionResult = Get-SubscriptionsToScan -SubscriptionIds $SubscriptionIds -Errors $errors
    $subscriptions = $subscriptionResult.Subscriptions

    if ($subscriptions.Count -eq 0) {
        Write-Warning "No subscriptions found for Security scan."
        return $null
    }

    $scanners = @{
        'Storage'    = { param($subId, $subName, $includeL2) Get-AzureStorageFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$false -CriticalStorageAccounts @() }
        'AppService' = { param($subId, $subName, $includeL2) Get-AzureAppServiceFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$false }
        'VM'         = { param($subId, $subName, $includeL2) Get-AzureVirtualMachineFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$false }
        'ARC'        = { param($subId, $subName, $includeL2) Get-AzureArcFindings -SubscriptionId $subId -SubscriptionName $subName }
        'Monitor'    = { param($subId, $subName, $includeL2) Get-AzureMonitorFindings -SubscriptionId $subId -SubscriptionName $subName }
        'Network'    = { param($subId, $subName, $includeL2) Get-AzureNetworkFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$false }
        'SQL'        = { param($subId, $subName, $includeL2) Get-AzureSqlDatabaseFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$false }
        'KeyVault'   = { param($subId, $subName, $includeL2) Get-AzureKeyVaultFindings -SubscriptionId $subId -SubscriptionName $subName -IncludeLevel2:$false }
    }

    $allFindings = [System.Collections.Generic.List[PSObject]]::new()
    $categoriesToScan = @('Storage','AppService','VM','ARC','Monitor','Network','SQL','KeyVault')

    foreach ($sub in $subscriptions) {
        Write-Host "    Scanning $($sub.Name)..." -ForegroundColor Gray
        $findings = Invoke-ScannerForSubscription -Subscription $sub -Categories $categoriesToScan -Scanners $scanners -IncludeLevel2 $false
        if ($findings) {
            foreach ($f in $findings) { $allFindings.Add($f) }
        }
    }

    return [PSCustomObject]@{
        TenantId = $context.Tenant.Id
        TotalResources = ($allFindings | Select-Object -ExpandProperty ResourceId -Unique).Count
        SubscriptionsScanned = $subscriptions
        Findings = $allFindings
        ScanDuration = "N/A"
    }
}

function Get-LiveVMBackupData {
    param([string[]]$SubscriptionIds)

    if (-not (Get-Command -Name Collect-VMBackupData -ErrorAction SilentlyContinue)) {
        Write-Error "Collect-VMBackupData function not found."
        return $null
    }

    $context = Get-AzContext
    $errors = [System.Collections.Generic.List[string]]::new()
    $subscriptionResult = Get-SubscriptionsToScan -SubscriptionIds $SubscriptionIds -Errors $errors
    $subscriptions = $subscriptionResult.Subscriptions

    if ($subscriptions.Count -eq 0) {
        Write-Warning "No subscriptions found for VMBackup scan."
        return $null
    }

    return Collect-VMBackupData -Subscriptions $subscriptions
}

function Get-LiveChangeTrackingData {
    param([string[]]$SubscriptionIds)

    if (-not (Get-Command -Name Collect-ChangeTrackingData -ErrorAction SilentlyContinue)) {
        Write-Error "Collect-ChangeTrackingData function not found."
        return $null
    }

    $context = Get-AzContext
    $errors = [System.Collections.Generic.List[string]]::new()
    $subscriptionResult = Get-SubscriptionsToScan -SubscriptionIds $SubscriptionIds -Errors $errors
    $subscriptions = $subscriptionResult.Subscriptions

    if ($subscriptions.Count -eq 0) {
        Write-Warning "No subscriptions found for ChangeTracking scan."
        return $null
    }

    return Collect-ChangeTrackingData -Subscriptions $subscriptions
}

function Get-LiveCostTrackingData {
    param(
        [string[]]$SubscriptionIds,
        [int]$DaysToInclude = 30
    )

    if (-not (Get-Command -Name Collect-CostData -ErrorAction SilentlyContinue)) {
        Write-Error "Collect-CostData function not found."
        return $null
    }

    $context = Get-AzContext
    $errors = [System.Collections.Generic.List[string]]::new()
    $subscriptionResult = Get-SubscriptionsToScan -SubscriptionIds $SubscriptionIds -Errors $errors
    $subscriptions = $subscriptionResult.Subscriptions

    if ($subscriptions.Count -eq 0) {
        Write-Warning "No subscriptions found for CostTracking scan."
        return $null
    }

    return Collect-CostData -Subscriptions $subscriptions -DaysToInclude $DaysToInclude
}

function Get-LiveEOLData {
    param([string[]]$SubscriptionIds)

    if (-not (Get-Command -Name Collect-EOLData -ErrorAction SilentlyContinue)) {
        Write-Error "Collect-EOLData function not found."
        return $null
    }

    $context = Get-AzContext
    $errors = [System.Collections.Generic.List[string]]::new()
    $subscriptionResult = Get-SubscriptionsToScan -SubscriptionIds $SubscriptionIds -Errors $errors
    $subscriptions = $subscriptionResult.Subscriptions

    if ($subscriptions.Count -eq 0) {
        Write-Warning "No subscriptions found for EOL scan."
        return $null
    }

    return Collect-EOLData -Subscriptions $subscriptions
}

function Get-LiveNetworkInventoryData {
    param([string[]]$SubscriptionIds)

    if (-not (Get-Command -Name Collect-NetworkInventory -ErrorAction SilentlyContinue)) {
        Write-Error "Collect-NetworkInventory function not found."
        return $null
    }

    $context = Get-AzContext
    $errors = [System.Collections.Generic.List[string]]::new()
    $subscriptionResult = Get-SubscriptionsToScan -SubscriptionIds $SubscriptionIds -Errors $errors
    $subscriptions = $subscriptionResult.Subscriptions

    if ($subscriptions.Count -eq 0) {
        Write-Warning "No subscriptions found for NetworkInventory scan."
        return $null
    }

    return Collect-NetworkInventory -Subscriptions $subscriptions
}

function Get-LiveRBACData {
    param([string[]]$SubscriptionIds)

    if (-not (Get-Command -Name Collect-RBACData -ErrorAction SilentlyContinue)) {
        Write-Error "Collect-RBACData function not found."
        return $null
    }

    $context = Get-AzContext
    $errors = [System.Collections.Generic.List[string]]::new()
    $subscriptionResult = Get-SubscriptionsToScan -SubscriptionIds $SubscriptionIds -Errors $errors
    $subscriptions = $subscriptionResult.Subscriptions

    if ($subscriptions.Count -eq 0) {
        Write-Warning "No subscriptions found for RBAC scan."
        return $null
    }

    return Collect-RBACData -Subscriptions $subscriptions
}

function Get-LiveAdvisorData {
    param([string[]]$SubscriptionIds)

    if (-not (Get-Command -Name Collect-AdvisorRecommendations -ErrorAction SilentlyContinue)) {
        Write-Error "Collect-AdvisorRecommendations function not found."
        return $null
    }

    $context = Get-AzContext
    $errors = [System.Collections.Generic.List[string]]::new()
    $subscriptionResult = Get-SubscriptionsToScan -SubscriptionIds $SubscriptionIds -Errors $errors
    $subscriptions = $subscriptionResult.Subscriptions

    if ($subscriptions.Count -eq 0) {
        Write-Warning "No subscriptions found for Advisor scan."
        return $null
    }

    return Collect-AdvisorRecommendations -Subscriptions $subscriptions
}

#endregion

#region Helper Functions

function Build-DashboardAuditResult {
    param(
        [hashtable]$AllData,
        [string]$TenantId
    )

    # Build subscriptions list from available data
    $subscriptions = @()
    if ($AllData['Security'] -and $AllData['Security'].SubscriptionsScanned) {
        $subscriptions = $AllData['Security'].SubscriptionsScanned
    }

    # Build EOL summary
    $eolData = $AllData['EOL']
    $eolSummary = if ($eolData) {
        [PSCustomObject]@{
            TotalFindings = $eolData.Count
            ComponentCount = @($eolData | Select-Object -ExpandProperty Component -Unique -ErrorAction SilentlyContinue).Count
            CriticalCount = @($eolData | Where-Object { $_.Severity -eq 'Critical' }).Count
            HighCount = @($eolData | Where-Object { $_.Severity -eq 'High' }).Count
            MediumCount = @($eolData | Where-Object { $_.Severity -eq 'Medium' }).Count
            LowCount = @($eolData | Where-Object { $_.Severity -eq 'Low' }).Count
            SoonestDeadline = ($eolData | Sort-Object EOLDate -ErrorAction SilentlyContinue | Select-Object -First 1).EOLDate
        }
    } else { $null }

    return [PSCustomObject]@{
        TenantId = $TenantId
        TotalResources = 100
        SubscriptionsScanned = $subscriptions
        Findings = if ($AllData['Security']) { $AllData['Security'].Findings } else { @() }
        VMInventory = $AllData['VMBackup']
        AdvisorRecommendations = $AllData['Advisor']
        ChangeTrackingData = $AllData['ChangeTracking']
        NetworkInventory = $AllData['NetworkInventory']
        CostTrackingData = $AllData['CostTracking']
        RBACInventory = $AllData['RBAC']
        EOLSummary = $eolSummary
        EOLData = $eolData
    }
}

#endregion

# Export the main function
Export-ModuleMember -Function Test-SingleReport -ErrorAction SilentlyContinue
