<#
.SYNOPSIS
    Generates an HTML dashboard summarizing all audit reports.

.DESCRIPTION
    Creates an interactive HTML dashboard with key metrics from security audit,
    VM backup, and Azure Advisor reports, with navigation to detailed reports.

.PARAMETER AuditResult
    The audit result object from Invoke-AzureSecurityAudit.

.PARAMETER VMInventory
    Array of VM inventory objects from Get-VirtualMachineFindings.

.PARAMETER AdvisorRecommendations
    Array of Azure Advisor recommendation objects.

.PARAMETER OutputPath
    Path for the HTML report output.

.PARAMETER TenantId
    Azure Tenant ID for display in report.

.OUTPUTS
    String path to the generated HTML report.
#>
function Export-DashboardReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$AuditResult,
        
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[PSObject]]$VMInventory,
        
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[PSObject]]$AdvisorRecommendations = $null,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$SecurityReportData = $null,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$VMBackupReportData = $null,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$AdvisorReportData = $null,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$ChangeTrackingReportData = $null,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$NetworkInventoryReportData = $null,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        
        [string]$TenantId = "Unknown"
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    
    # Security metrics - MUST come from Security Report (no inventory/calculation of counts)
    if ($SecurityReportData) {
        $securityScore = $SecurityReportData.SecurityScore
        $totalChecks = $SecurityReportData.TotalChecks
        $passedChecks = $SecurityReportData.PassedChecks
        $criticalCount = $SecurityReportData.CriticalCount
        $highCount = $SecurityReportData.HighCount
        $mediumCount = $SecurityReportData.MediumCount
        $lowCount = $SecurityReportData.LowCount
        $deprecatedCount = $SecurityReportData.DeprecatedCount
        $pastDueCount = $SecurityReportData.PastDueCount
        # Simple sum calculation (allowed - not inventoring, just summing provided values)
        $totalFailedFindings = $criticalCount + $highCount + $mediumCount + $lowCount
    } else {
        # Fallback: Set defaults if Security Report data not available
        $securityScore = 0
        $totalChecks = 0
        $passedChecks = 0
        $criticalCount = 0
        $highCount = 0
        $mediumCount = 0
        $lowCount = 0
        $totalFailedFindings = 0
        $deprecatedCount = 0
        $pastDueCount = 0
    }
    
    # VM Backup metrics - use pre-calculated data from VM Backup Report if available
    if ($VMBackupReportData) {
        $totalVMs = $VMBackupReportData.TotalVMs
        $protectedVMs = $VMBackupReportData.ProtectedVMs
        $unprotectedVMs = $VMBackupReportData.UnprotectedVMs
        $backupRate = $VMBackupReportData.BackupRate
        $runningVMs = $VMBackupReportData.RunningVMs
    } else {
        # Fallback: Calculate from VMInventory
        $totalVMs = $VMInventory.Count
        $protectedVMs = @($VMInventory | Where-Object { $_.BackupEnabled }).Count
        $unprotectedVMs = $totalVMs - $protectedVMs
        $backupRate = if ($totalVMs -gt 0) { [math]::Round(($protectedVMs / $totalVMs) * 100, 1) } else { 0 }
        $runningVMs = @($VMInventory | Where-Object { $_.PowerState -eq 'running' }).Count
    }
    
    # Advisor metrics - use pre-calculated data from Advisor Report if available
    if ($AdvisorReportData) {
        $advisorCount = $AdvisorReportData.AdvisorCount
        $advisorHighCount = $AdvisorReportData.AdvisorHighCount
        $advisorSavings = $AdvisorReportData.TotalSavings
        $advisorCurrency = $AdvisorReportData.SavingsCurrency
    } else {
        # Fallback: Calculate from AdvisorRecommendations
        $advisorCount = 0
        $advisorHighCount = 0
        $advisorSavings = 0
        $advisorCurrency = "USD"
        if ($AdvisorRecommendations -and $AdvisorRecommendations.Count -gt 0) {
            $advisorCount = $AdvisorRecommendations.Count
            $advisorHighCount = @($AdvisorRecommendations | Where-Object { $_.Impact -eq 'High' }).Count
            $savingsData = Get-CostSavingsFromRecommendations -Recommendations $AdvisorRecommendations
            $advisorSavings = $savingsData.TotalSavings
            $advisorCurrency = $savingsData.Currency
        }
    }
    
    # Change Tracking metrics - use pre-calculated data from Change Tracking Report if available
    if ($ChangeTrackingReportData) {
        $changeTrackingTotal = $ChangeTrackingReportData.TotalChanges
        $changeTrackingSecurityAlerts = $ChangeTrackingReportData.HighSecurityFlags + $ChangeTrackingReportData.MediumSecurityFlags
    } else {
        # Fallback: Calculate from ChangeTrackingData
        $changeTrackingTotal = 0
        $changeTrackingSecurityAlerts = 0
        if ($AuditResult.ChangeTrackingData -and $AuditResult.ChangeTrackingData.Count -gt 0) {
            $changeTrackingTotal = $AuditResult.ChangeTrackingData.Count
            $changeTrackingSecurityAlerts = @($AuditResult.ChangeTrackingData | Where-Object { $_.SecurityFlag -in @('high', 'medium') }).Count
        }
    }

    # Network Inventory metrics
    if ($NetworkInventoryReportData) {
        $networkVNetCount = $NetworkInventoryReportData.VNetCount
        $networkDeviceCount = $NetworkInventoryReportData.DeviceCount
    } else {
        $networkVNetCount = if ($AuditResult.NetworkInventory) { $AuditResult.NetworkInventory.Count } else { 0 }
        $networkDeviceCount = 0
        if ($AuditResult.NetworkInventory) {
            foreach ($vnet in $AuditResult.NetworkInventory) {
                foreach ($subnet in $vnet.Subnets) {
                    $networkDeviceCount += $subnet.ConnectedDevices.Count
                }
            }
        }
    }
    
    # Subscription count
    $subscriptionCount = ($AuditResult.SubscriptionsScanned | Measure-Object).Count
    
    # Resources scanned by category
    $resourcesByCategory = $failedFindings | Group-Object Category | ForEach-Object {
        [PSCustomObject]@{
            Category = $_.Name
            FailCount = $_.Count
        }
    } | Sort-Object FailCount -Descending
    
    # Determine overall health color
    $healthColor = if ($criticalCount -gt 0) { '#ff6b6b' } 
                   elseif ($highCount -gt 0) { '#feca57' }
                   elseif ($mediumCount -gt 0) { '#54a0ff' }
                   else { '#00d26a' }
    
    $healthText = if ($criticalCount -gt 0) { 'Critical Issues Found' }
                  elseif ($highCount -gt 0) { 'High Risk Items Present' }
                  elseif ($mediumCount -gt 0) { 'Medium Risk Items' }
                  else { 'Environment Healthy' }
    
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure Audit Dashboard</title>
    <style>
$(Get-ReportStylesheet)
    </style>
</head>
<body>
$(Get-ReportNavigation -ActivePage "Dashboard")
    
    <div class="container">
        <div class="hero">
            <h1>Azure Audit Dashboard</h1>
            <p class="subtitle">Generated: $timestamp | Tenant: $TenantId | $subscriptionCount Subscription(s)</p>
            <div class="health-indicator">
                <span class="health-dot" style="background-color: $healthColor;"></span>
                <span>$healthText</span>
            </div>
        </div>
        
        <div class="quick-stats">
            <div class="quick-stat">
                <div class="value">$subscriptionCount</div>
                <div class="label">Subscriptions Scanned</div>
            </div>
            <div class="quick-stat" style="$(if ($deprecatedCount -gt 0) { 'border-color: var(--accent-red);' })">
                <div class="value" style="$(if ($deprecatedCount -gt 0) { 'color: var(--accent-red);' })">$(if ($deprecatedCount) { $deprecatedCount } else { 0 })</div>
                <div class="label">Deprecated Components</div>
            </div>
            <div class="quick-stat">
                <div class="value">$totalFailedFindings</div>
                <div class="label">Security Issues</div>
            </div>
            <div class="quick-stat" style="$(if ($advisorHighCount -gt 0) { 'border-color: var(--accent-yellow);' })">
                <div class="value" style="$(if ($advisorHighCount -gt 0) { 'color: var(--accent-yellow);' })">$advisorCount</div>
                <div class="label">Advisor Recommendations</div>
            </div>
        </div>
        
        <div class="dashboard-grid">
            <div class="card">
                <div class="card-header">
                    <span class="card-title">Security Compliance</span>
                    <a href="security.html" class="card-link">View Details &rarr;</a>
                </div>
                <div class="card-body">
                    <div class="score-display">
                        <div class="score-circle" style="--score: $securityScore;">
                            <span class="score-value">$securityScore%</span>
                            <span class="score-label">Compliance</span>
                        </div>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Critical Issues</span>
                        <span class="metric-value critical">$criticalCount</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">High Severity</span>
                        <span class="metric-value high">$highCount</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Medium Severity</span>
                        <span class="metric-value medium">$mediumCount</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Low Severity</span>
                        <span class="metric-value low">$lowCount</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Passed Checks</span>
                        <span class="metric-value green">$passedChecks</span>
                    </div>
                </div>
            </div>
            
            <div class="card">
                <div class="card-header">
                    <span class="card-title">VM Backup Coverage</span>
                    <a href="vm-backup.html" class="card-link">View Details &rarr;</a>
                </div>
                <div class="card-body">
                    <div class="score-display">
                        <div class="score-circle" style="--score: $backupRate; --accent-green: #54a0ff;">
                            <span class="score-value" style="color: var(--accent-blue);">$backupRate%</span>
                            <span class="score-label">Protected</span>
                        </div>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Total VMs</span>
                        <span class="metric-value">$totalVMs</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Backup Protected</span>
                        <span class="metric-value green">$protectedVMs</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Unprotected</span>
                        <span class="metric-value red">$unprotectedVMs</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Running VMs</span>
                        <span class="metric-value">$runningVMs</span>
                    </div>
                </div>
            </div>
            
            <div class="card">
                <div class="card-header">
                    <span class="card-title">Azure Advisor</span>
                    <a href="advisor.html" class="card-link">View Details &rarr;</a>
                </div>
                <div class="card-body">
                    <div class="score-display">
                        <div class="score-circle" style="--score: 0; background: linear-gradient(135deg, var(--bg-surface), var(--bg-hover));">
                            <span class="score-value" style="color: var(--accent-yellow); font-size: 2rem;">$advisorCount</span>
                            <span class="score-label">Recommendations</span>
                        </div>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">High Impact</span>
                        <span class="metric-value red">$advisorHighCount</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Potential Savings</span>
                        <span class="metric-value green">$($advisorCurrency) $([math]::Round($advisorSavings, 0))/yr</span>
                    </div>
                </div>
            </div>
            <div class="card">
                <div class="card-header">
                    <span class="card-title">Network Inventory</span>
                    <a href="network.html" class="card-link">View Details &rarr;</a>
                </div>
                <div class="card-body">
                    <div class="score-display">
                        <div class="score-circle" style="--score: 0; background: linear-gradient(135deg, var(--bg-surface), var(--bg-hover));">
                            <span class="score-value" style="color: #3498db; font-size: 2rem;">$networkVNetCount</span>
                            <span class="score-label">VNets</span>
                        </div>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Connected Devices</span>
                        <span class="metric-value">$networkDeviceCount</span>
                    </div>
                </div>
            </div>
        </div>
        
        <h2 style="margin-bottom: 20px; font-size: 1.3rem;">Detailed Reports</h2>
        <div class="report-links">
            <a href="security.html" class="report-link">
                <div class="report-icon security">&sect;</div>
                <div class="report-info">
                    <h3>Security Audit Report</h3>
                    <p>$($failedFindings.Count) issues across $(@($failedFindings | Select-Object -ExpandProperty Category -Unique).Count) categories</p>
                </div>
            </a>
            <a href="vm-backup.html" class="report-link">
                <div class="report-icon backup">&equiv;</div>
                <div class="report-info">
                    <h3>VM Backup Overview</h3>
                    <p>$totalVMs VMs | $protectedVMs protected | $unprotectedVMs unprotected</p>
                </div>
            </a>
            <a href="network.html" class="report-link">
                <div class="report-icon" style="background: rgba(52, 152, 219, 0.15); color: #3498db;">&infin;</div>
                <div class="report-info">
                    <h3>Network Inventory</h3>
                    <p>$networkVNetCount Virtual Networks | $networkDeviceCount Connected Devices</p>
                </div>
            </a>
            <a href="advisor.html" class="report-link">
                <div class="report-icon advisor" style="background: rgba(254, 202, 87, 0.15); color: var(--accent-yellow);">&loz;</div>
                <div class="report-info">
                    <h3>Azure Advisor</h3>
                    <p>$advisorCount recommendations | $advisorHighCount high impact</p>
                </div>
            </a>
            <a href="change-tracking.html" class="report-link">
                <div class="report-icon" style="background: rgba(84, 160, 255, 0.15); color: var(--accent-blue);">&crarr;</div>
                <div class="report-info">
                    <h3>Change Tracking</h3>
                    <p>$changeTrackingTotal changes | $changeTrackingSecurityAlerts security alerts</p>
                </div>
            </a>
        </div>
        
        <div class="footer">
            <p>Azure Security Audit Tool v$($AuditResult.ToolVersion) | Scan completed: $($AuditResult.ScanEndTime.ToString('yyyy-MM-dd HH:mm:ss'))</p>
        </div>
    </div>
</body>
</html>
"@
    
    # Write to file with UTF-8 encoding (no BOM for better browser compatibility)
    [System.IO.File]::WriteAllText($OutputPath, $html, [System.Text.UTF8Encoding]::new($false))
    
    return $OutputPath
}

