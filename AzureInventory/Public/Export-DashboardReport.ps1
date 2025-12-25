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
        
        [Parameter(Mandatory = $false)]
        [hashtable]$CostTrackingReportData = $null,

        [Parameter(Mandatory = $false)]
        [hashtable]$RBACReportData = $null,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        
        [string]$TenantId = "Unknown"
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    
    # Security metrics - MUST come from Security Report (no additional inventory)
    if ($SecurityReportData) {
        $securityScore   = $SecurityReportData.SecurityScore
        $passedChecks    = $SecurityReportData.PassedChecks
        $criticalCount   = $SecurityReportData.CriticalCount
        $highCount       = $SecurityReportData.HighCount
        $mediumCount     = $SecurityReportData.MediumCount
        $lowCount        = $SecurityReportData.LowCount
        $totalFailedFindings = $criticalCount + $highCount + $mediumCount + $lowCount
    } else {
        # Fallback: Set defaults if Security Report data not available
        $securityScore   = 0
        $passedChecks    = 0
        $criticalCount   = 0
        $highCount       = 0
        $mediumCount     = 0
        $lowCount        = 0
        $totalFailedFindings = 0
    }
    
    # Get failed findings for display in report links
    $findings = if ($AuditResult.Findings) { @($AuditResult.Findings) } else { @() }
    $failedFindings = @($findings | Where-Object { $_.Status -eq 'FAIL' })

    # EOL / Deprecated components metrics (from EOLSummary on AuditResult or defaults)
    $eolTotalFindings   = 0
    $eolComponentCount  = 0
    $eolCriticalCount   = 0
    $eolHighCount       = 0
    $eolMediumCount     = 0
    $eolLowCount        = 0
    $eolSoonestDeadline = $null
    
    if ($AuditResult.PSObject.Properties.Name -contains 'EOLSummary' -and $AuditResult.EOLSummary) {
        $eolSummary = $AuditResult.EOLSummary
        if ($eolSummary.TotalFindings)   { $eolTotalFindings  = $eolSummary.TotalFindings }
        if ($eolSummary.ComponentCount)  { $eolComponentCount = $eolSummary.ComponentCount }
        if ($eolSummary.CriticalCount)   { $eolCriticalCount  = $eolSummary.CriticalCount }
        if ($eolSummary.HighCount)       { $eolHighCount      = $eolSummary.HighCount }
        if ($eolSummary.MediumCount)     { $eolMediumCount    = $eolSummary.MediumCount }
        if ($eolSummary.LowCount)        { $eolLowCount       = $eolSummary.LowCount }
        if ($eolSummary.SoonestDeadline) { $eolSoonestDeadline = $eolSummary.SoonestDeadline }
    }
    $eolSoonestDeadlineText = if ($eolSoonestDeadline) { $eolSoonestDeadline } else { "N/A" }
    
    # Determine highest EOL severity for color coding
    $eolHighestSeverityColor = if ($eolCriticalCount -gt 0) { 'var(--accent-red)' }
                               elseif ($eolHighCount -gt 0) { 'var(--accent-yellow)' }
                               elseif ($eolMediumCount -gt 0) { 'var(--accent-blue)' }
                               elseif ($eolLowCount -gt 0) { 'var(--accent-green)' }
                               else { '#888' }
    
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
        $advisorMediumCount = if ($AdvisorReportData.AdvisorMediumCount) { $AdvisorReportData.AdvisorMediumCount } else { 0 }
        $advisorLowCount = if ($AdvisorReportData.AdvisorLowCount) { $AdvisorReportData.AdvisorLowCount } else { 0 }
        $advisorSavings = $AdvisorReportData.TotalSavings
        $advisorCurrency = $AdvisorReportData.SavingsCurrency
    } else {
        # Fallback: Calculate from AdvisorRecommendations
        $advisorCount = 0
        $advisorHighCount = 0
        $advisorMediumCount = 0
        $advisorLowCount = 0
        $advisorSavings = 0
        $advisorCurrency = "USD"
        if ($AdvisorRecommendations -and $AdvisorRecommendations.Count -gt 0) {
            $advisorCount = $AdvisorRecommendations.Count
            $advisorHighCount = @($AdvisorRecommendations | Where-Object { $_.Impact -eq 'High' }).Count
            $advisorMediumCount = @($AdvisorRecommendations | Where-Object { $_.Impact -eq 'Medium' }).Count
            $advisorLowCount = @($AdvisorRecommendations | Where-Object { $_.Impact -eq 'Low' }).Count
            $savingsData = Get-CostSavingsFromRecommendations -Recommendations $AdvisorRecommendations
            $advisorSavings = $savingsData.TotalSavings
            $advisorCurrency = $savingsData.Currency
        }
    }
    
    # Determine highest severity for Advisor card color
    $advisorHighestSeverityColor = if ($advisorHighCount -gt 0) { 'var(--accent-red)' }
                                   elseif ($advisorMediumCount -gt 0) { 'var(--accent-blue)' }
                                   elseif ($advisorLowCount -gt 0) { 'var(--accent-green)' }
                                   else { '#888' }
    
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
        $networkPeeringCount = if ($NetworkInventoryReportData.PeeringCount) { $NetworkInventoryReportData.PeeringCount } else { 0 }
        $networkS2SConnections = if ($NetworkInventoryReportData.S2SConnectionCount) { $NetworkInventoryReportData.S2SConnectionCount } else { 0 }
        $networkERConnections = if ($NetworkInventoryReportData.ERConnectionCount) { $NetworkInventoryReportData.ERConnectionCount } else { 0 }
        $networkDisconnectedConnections = if ($NetworkInventoryReportData.DisconnectedConnections) { $NetworkInventoryReportData.DisconnectedConnections } else { 0 }
        $networkSubnetsMissingNSG = if ($NetworkInventoryReportData.SubnetsMissingNSG) { $NetworkInventoryReportData.SubnetsMissingNSG } else { 0 }
        $networkSecurityRisks = if ($NetworkInventoryReportData.SecurityRisks) { $NetworkInventoryReportData.SecurityRisks } else { 0 }
        $networkVirtualWANHubs = if ($NetworkInventoryReportData.VirtualWANHubCount) { $NetworkInventoryReportData.VirtualWANHubCount } else { 0 }
        $networkAzureFirewalls = if ($NetworkInventoryReportData.AzureFirewallCount) { $NetworkInventoryReportData.AzureFirewallCount } else { 0 }
    } else {
        $networkVNetCount = if ($AuditResult.NetworkInventory) { $AuditResult.NetworkInventory.Count } else { 0 }
        $networkDeviceCount = 0
        $networkPeeringCount = 0
        $networkS2SConnections = 0
        $networkERConnections = 0
        $networkDisconnectedConnections = 0
        $networkSubnetsMissingNSG = 0
        $networkSecurityRisks = 0
        if ($AuditResult.NetworkInventory) {
            $uniquePeerings = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($vnet in $AuditResult.NetworkInventory) {
                foreach ($subnet in $vnet.Subnets) {
                    $networkDeviceCount += $subnet.ConnectedDevices.Count
                    if (-not $subnet.NsgId) {
                        # Exclude legitimate exceptions: GatewaySubnet, AzureBastionSubnet, AzureFirewallSubnet
                        $subnetName = $subnet.Name
                        $isExceptionSubnet = ($subnetName -eq "GatewaySubnet" -or 
                                             $subnetName -eq "AzureBastionSubnet" -or 
                                             $subnetName -eq "AzureFirewallSubnet")
                        
                        if (-not $isExceptionSubnet) {
                            $networkSubnetsMissingNSG++
                        }
                    }
                    # Count NSG risks
                    if ($subnet.NsgRisks) {
                        $networkSecurityRisks += $subnet.NsgRisks.Count
                    }
                }
                # Count peerings
                foreach ($peering in $vnet.Peerings) {
                    $vnetPair = @($vnet.Name, $peering.RemoteVnetName) | Sort-Object
                    $peeringKey = "$($vnetPair[0])|$($vnetPair[1])"
                    [void]$uniquePeerings.Add($peeringKey)
                }
                # Count connections
                foreach ($gateway in $vnet.Gateways) {
                    if ($gateway.Type -eq "ExpressRoute") {
                        $networkERConnections++
                    }
                    elseif ($gateway.Connections) {
                        foreach ($conn in $gateway.Connections) {
                            if ($conn.ConnectionType -eq "IPsec") {
                                $networkS2SConnections++
                            }
                            elseif ($conn.ConnectionType -eq "ExpressRoute") {
                                $networkERConnections++
                            }
                            if ($conn.ConnectionStatus -and $conn.ConnectionStatus -ne "Connected") {
                                $networkDisconnectedConnections++
                            }
                        }
                    }
                }
            }
            $networkPeeringCount = $uniquePeerings.Count
        }
    }
    
    # Cost Tracking metrics
    if ($CostTrackingReportData) {
        $costTotalLocal = $CostTrackingReportData.TotalCostLocal
        $costTotalUSD = $CostTrackingReportData.TotalCostUSD
        $costCurrency = $CostTrackingReportData.Currency
        $costSubscriptionCount = $CostTrackingReportData.SubscriptionCount
        $costCategoryCount = $CostTrackingReportData.CategoryCount
        $costDays = $CostTrackingReportData.DaysIncluded
    } else {
        # Fallback: Try to get from AuditResult.CostTrackingData
        $costTotalLocal = 0
        $costTotalUSD = 0
        $costCurrency = "SEK"
        $costSubscriptionCount = 0
        $costCategoryCount = 0
        $costDays = 30
        if ($AuditResult.CostTrackingData -and $AuditResult.CostTrackingData.TotalCostLocal) {
            $costTotalLocal = $AuditResult.CostTrackingData.TotalCostLocal
            $costTotalUSD = $AuditResult.CostTrackingData.TotalCostUSD
            $costCurrency = if ($AuditResult.CostTrackingData.Currency) { $AuditResult.CostTrackingData.Currency } else { "SEK" }
            $costSubscriptionCount = if ($AuditResult.CostTrackingData.SubscriptionCount) { $AuditResult.CostTrackingData.SubscriptionCount } else { 0 }
            $costCategoryCount = if ($AuditResult.CostTrackingData.ByMeterCategory) { $AuditResult.CostTrackingData.ByMeterCategory.Count } else { 0 }
            $costDays = if ($AuditResult.CostTrackingData.DaysToInclude) { $AuditResult.CostTrackingData.DaysToInclude } else { 30 }
        }
    }
    
    # Format cost for display
    $costTotalLocalFormatted = [math]::Round($costTotalLocal, 0).ToString("N0") -replace ',', ' '
    $costTotalUSDFormatted = [math]::Round($costTotalUSD, 0).ToString("N0") -replace ',', ' '
    
    # RBAC/IAM metrics
    $rbacTotalPrincipals = 0
    $rbacFullControl = 0
    $rbacAccessManagers = 0
    if ($AuditResult.RBACInventory) {
        $rbacStats = $AuditResult.RBACInventory.Statistics
        $rbacTotalPrincipals = $rbacStats.TotalPrincipals
        $rbacFullControl = $rbacStats.ByAccessTier.FullControl
        $rbacAccessManagers = $rbacStats.ByAccessTier.AccessManager
    }
    
    # Subscription count
    $subscriptionCount = ($AuditResult.SubscriptionsScanned | Measure-Object).Count
    
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
            <div class="metadata">
                <p><strong>Tenant:</strong> $TenantId</p>
                <p><strong>Scanned:</strong> $timestamp</p>
                <p><strong>Subscriptions:</strong> $subscriptionCount</p>
                <p><strong>Resources:</strong> $($AuditResult.TotalResources)</p>
                <p><strong>Total Findings:</strong> $totalFailedFindings</p>
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
                            <span class="score-value" style="color: $advisorHighestSeverityColor; font-size: 2rem;">$advisorCount</span>
                            <span class="score-label">Recommendations</span>
                        </div>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">High Impact</span>
                        <span class="metric-value red">$advisorHighCount</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Medium Impact</span>
                        <span class="metric-value medium">$advisorMediumCount</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Low Impact</span>
                        <span class="metric-value low">$advisorLowCount</span>
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
                    <div class="metric-row">
                        <span class="metric-label">Peerings</span>
                        <span class="metric-value">$networkPeeringCount</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Connections</span>
                        <span class="metric-value">$($networkS2SConnections + $networkERConnections) ($networkS2SConnections S2S, $networkERConnections ER)</span>
                    </div>
                    $(if ($networkVirtualWANHubs -gt 0) {
                        "<div class='metric-row'><span class='metric-label'>Virtual WAN Hubs</span><span class='metric-value'>$networkVirtualWANHubs</span></div>"
                    })
                    $(if ($networkAzureFirewalls -gt 0) {
                        "<div class='metric-row'><span class='metric-label'>Azure Firewalls</span><span class='metric-value'>$networkAzureFirewalls</span></div>"
                    })
                    $(if ($networkSecurityRisks -gt 0) {
@"
                    <div class="metric-row">
                        <span class="metric-label">Security Risks</span>
                        <span class="metric-value red">$networkSecurityRisks</span>
                    </div>
"@
})
$(if ($networkDisconnectedConnections -gt 0) {
@"
                    <div class="metric-row">
                        <span class="metric-label">Disconnected Links</span>
                        <span class="metric-value red">$networkDisconnectedConnections</span>
                    </div>
"@
})
$(if ($networkSubnetsMissingNSG -gt 0) {
@"
                    <div class="metric-row">
                        <span class="metric-label">Subnets Missing NSG</span>
                        <span class="metric-value red">$networkSubnetsMissingNSG</span>
                    </div>
"@
})
                </div>
            </div>
            <div class="card">
                <div class="card-header">
                    <span class="card-title">Cost Tracking ($costDays days)</span>
                    <a href="cost-tracking.html" class="card-link">View Details &rarr;</a>
                </div>
                <div class="card-body">
                    <div class="score-display">
                        <div class="score-circle" style="--score: 0; background: linear-gradient(135deg, var(--bg-surface), var(--bg-hover));">
                            <span class="score-value" style="color: var(--accent-green); font-size: 1.4rem;">$costCurrency $costTotalLocalFormatted</span>
                            <span class="score-label">Total Cost</span>
                        </div>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">USD Equivalent</span>
                        <span class="metric-value">`$$costTotalUSDFormatted</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Subscriptions</span>
                        <span class="metric-value">$costSubscriptionCount</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Cost Categories</span>
                        <span class="metric-value">$costCategoryCount</span>
                    </div>
                </div>
            </div>
            <div class="card">
                <div class="card-header">
                    <span class="card-title">EOL / Deprecated Components</span>
                    <a href="eol.html" class="card-link">View Details &rarr;</a>
                </div>
                <div class="card-body">
                    <div class="score-display">
                        <div class="score-circle" style="--score: 0; background: linear-gradient(135deg, var(--bg-surface), var(--bg-hover));">
                            <span class="score-value" style="color: $eolHighestSeverityColor; font-size: 2rem;">$eolTotalFindings</span>
                            <span class="score-label">Total Findings</span>
                        </div>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Components</span>
                        <span class="metric-value">$eolComponentCount</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Critical</span>
                        <span class="metric-value critical">$eolCriticalCount</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">High</span>
                        <span class="metric-value high">$eolHighCount</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Medium</span>
                        <span class="metric-value medium">$eolMediumCount</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Low</span>
                        <span class="metric-value low">$eolLowCount</span>
                    </div>
                    <div class="metric-row">
                        <span class="metric-label">Next Deadline</span>
                        <span class="metric-value">$eolSoonestDeadlineText</span>
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
            <a href="eol.html" class="report-link">
                <div class="report-icon" style="background: rgba(231, 76, 60, 0.15); color: #ff6b6b;">&#9888;</div>
                <div class="report-info">
                    <h3>EOL / Deprecated Components</h3>
                    <p>$eolTotalFindings resources | $eolComponentCount components | Next deadline: $eolSoonestDeadlineText</p>
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
            <a href="cost-tracking.html" class="report-link">
                <div class="report-icon" style="background: rgba(46, 204, 113, 0.15); color: var(--accent-green);">&curren;</div>
                <div class="report-info">
                    <h3>Cost Tracking</h3>
                    <p>$costCurrency $costTotalLocalFormatted ($costDays days) | $costSubscriptionCount subscriptions</p>
                </div>
            </a>
            <a href="rbac.html" class="report-link">
                <div class="report-icon" style="background: rgba(155, 89, 182, 0.15); color: var(--accent-purple);">🔐</div>
                <div class="report-info">
                    <h3>RBAC/IAM Inventory</h3>
                    <p>$rbacTotalPrincipals principals | $rbacFullControl full control | $rbacAccessManagers access managers</p>
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

