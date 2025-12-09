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
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        
        [string]$TenantId = "Unknown"
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    
    # Security metrics
    $findings = $AuditResult.Findings
    $failedFindings = @($findings | Where-Object { $_.Status -eq 'FAIL' })
    $passedFindings = @($findings | Where-Object { $_.Status -eq 'PASS' })
    
    # Use the same compliance score calculation as Security Report (weighted scoring)
    if ($AuditResult.ComplianceScores) {
        $securityScore = [math]::Round($AuditResult.ComplianceScores.OverallScore, 1)
        $totalChecks = $AuditResult.ComplianceScores.TotalChecks
        $passedChecks = $AuditResult.ComplianceScores.PassedChecks
    } else {
        # Fallback to simple calculation if ComplianceScores not available
        $totalChecks = $findings.Count
        $securityScore = if ($totalChecks -gt 0) { [math]::Round(($passedFindings.Count / $totalChecks) * 100, 1) } else { 0 }
        $passedChecks = $passedFindings.Count
    }
    
    $criticalCount = @($failedFindings | Where-Object { $_.Severity -eq 'Critical' }).Count
    $highCount = @($failedFindings | Where-Object { $_.Severity -eq 'High' }).Count
    $mediumCount = @($failedFindings | Where-Object { $_.Severity -eq 'Medium' }).Count
    $lowCount = @($failedFindings | Where-Object { $_.Severity -eq 'Low' }).Count
    
    # VM Backup metrics
    $totalVMs = $VMInventory.Count
    $protectedVMs = @($VMInventory | Where-Object { $_.BackupEnabled }).Count
    $unprotectedVMs = $totalVMs - $protectedVMs
    $backupRate = if ($totalVMs -gt 0) { [math]::Round(($protectedVMs / $totalVMs) * 100, 1) } else { 0 }
    $runningVMs = @($VMInventory | Where-Object { $_.PowerState -eq 'running' }).Count
    
    # Deprecated Components metrics
    $eolFindings = @($findings | Where-Object { $_.EOLDate -and $_.Status -eq 'FAIL' })
    $deprecatedCount = $eolFindings.Count
    $pastDueCount = @($eolFindings | Where-Object { 
        try { [DateTime]::Parse($_.EOLDate) -lt (Get-Date) } catch { $false }
    }).Count
    
    # Advisor metrics
    $advisorCount = 0
    $advisorHighCount = 0
    $advisorSavings = 0
    $advisorCurrency = "USD"
    if ($AdvisorRecommendations -and $AdvisorRecommendations.Count -gt 0) {
        $advisorCount = $AdvisorRecommendations.Count
        $advisorHighCount = @($AdvisorRecommendations | Where-Object { $_.Impact -eq 'High' }).Count
        
        # Group Cost recommendations to avoid double-counting duplicates
        $costRecsRaw = @($AdvisorRecommendations | Where-Object { $_.Category -eq 'Cost' })
        if ($costRecsRaw.Count -gt 0) {
            $groupedCostRecs = $costRecsRaw | Group-Object -Property @{
                Expression = {
                    $typeId = if ($_.RecommendationType) { $_.RecommendationType } else { "Unknown" }
                    $resId = if ($_.ResourceId) { $_.ResourceId } else { "Unknown" }
                    "$typeId|$resId"
                }
            } | ForEach-Object {
                $group = $_.Group
                if ($group.Count -gt 1) {
                    # Sum savings for duplicates
                    $totalSavings = ($group | Where-Object { $_.PotentialSavings } | Measure-Object -Property PotentialSavings -Sum).Sum
                    $currency = ($group | Where-Object { $_.SavingsCurrency } | Select-Object -First 1).SavingsCurrency
                    if (-not $currency) { $currency = "USD" }
                    
                    $firstRec = $group[0]
                    $firstRec.PotentialSavings = $totalSavings
                    $firstRec.SavingsCurrency = $currency
                    $firstRec
                } else {
                    $group[0]
                }
            }
            
            $costRecs = @($groupedCostRecs | Where-Object { $_.PotentialSavings })
            if ($costRecs.Count -gt 0) {
                $advisorSavings = ($costRecs | Measure-Object -Property PotentialSavings -Sum).Sum
                $advisorCurrency = ($costRecs | Where-Object { $_.SavingsCurrency } | Select-Object -First 1).SavingsCurrency
                if (-not $advisorCurrency) { $advisorCurrency = "USD" }
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
        :root {
            --bg-primary: #0f0f1a;
            --bg-secondary: #1a1a2e;
            --bg-surface: #252542;
            --bg-hover: #2d2d4a;
            --text-primary: #e8e8e8;
            --text-secondary: #b8b8b8;
            --text-muted: #888;
            --accent-green: #00d26a;
            --accent-red: #ff6b6b;
            --accent-yellow: #feca57;
            --accent-blue: #54a0ff;
            --accent-purple: #9b59b6;
            --border-color: #3d3d5c;
        }
        
        * { box-sizing: border-box; margin: 0; padding: 0; }
        
        body {
            font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            line-height: 1.6;
        }
        
        /* Navigation */
        .report-nav {
            background: var(--bg-secondary);
            padding: 15px 30px;
            display: flex;
            gap: 10px;
            align-items: center;
            border-bottom: 1px solid var(--border-color);
        }
        
        .nav-brand {
            font-weight: 600;
            font-size: 1.1rem;
            color: var(--accent-blue);
            margin-right: 30px;
        }
        
        .nav-link {
            color: var(--text-muted);
            text-decoration: none;
            padding: 8px 16px;
            border-radius: 6px;
            transition: all 0.2s ease;
            font-size: 0.9rem;
        }
        
        .nav-link:hover {
            background: var(--bg-surface);
            color: var(--text-primary);
        }
        
        .nav-link.active {
            background: var(--accent-blue);
            color: white;
        }
        
        /* Main content */
        .container {
            max-width: 1400px;
            margin: 0 auto;
            padding: 30px;
        }
        
        /* Hero section */
        .hero {
            background: linear-gradient(135deg, var(--bg-secondary) 0%, var(--bg-surface) 100%);
            border-radius: 16px;
            padding: 40px;
            margin-bottom: 30px;
            border: 1px solid var(--border-color);
            text-align: center;
        }
        
        .hero h1 {
            font-size: 2.5rem;
            font-weight: 700;
            margin-bottom: 10px;
        }
        
        .hero .subtitle {
            color: var(--text-muted);
            font-size: 1rem;
            margin-bottom: 20px;
        }
        
        .health-indicator {
            display: inline-flex;
            align-items: center;
            gap: 10px;
            background: var(--bg-hover);
            padding: 12px 24px;
            border-radius: 30px;
            font-weight: 600;
        }
        
        .health-dot {
            width: 12px;
            height: 12px;
            border-radius: 50%;
            animation: pulse 2s infinite;
        }
        
        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.5; }
        }
        
        /* Dashboard grid */
        .dashboard-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));
            gap: 24px;
            margin-bottom: 30px;
        }
        
        /* Cards */
        .card {
            background: var(--bg-surface);
            border-radius: 12px;
            border: 1px solid var(--border-color);
            overflow: hidden;
        }
        
        .card-header {
            padding: 20px 24px;
            border-bottom: 1px solid var(--border-color);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        
        .card-title {
            font-weight: 600;
            font-size: 1.1rem;
        }
        
        .card-link {
            color: var(--accent-blue);
            text-decoration: none;
            font-size: 0.85rem;
            display: flex;
            align-items: center;
            gap: 5px;
        }
        
        .card-link:hover {
            text-decoration: underline;
        }
        
        .card-body {
            padding: 24px;
        }
        
        /* Score display */
        .score-display {
            text-align: center;
            padding: 20px;
        }
        
        .score-circle {
            width: 150px;
            height: 150px;
            border-radius: 50%;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            margin: 0 auto 20px;
            position: relative;
        }
        
        .score-circle::before {
            content: '';
            position: absolute;
            inset: 0;
            border-radius: 50%;
            padding: 6px;
            background: conic-gradient(var(--accent-green) calc(var(--score) * 3.6deg), var(--bg-hover) 0);
            -webkit-mask: linear-gradient(#fff 0 0) content-box, linear-gradient(#fff 0 0);
            mask: linear-gradient(#fff 0 0) content-box, linear-gradient(#fff 0 0);
            -webkit-mask-composite: xor;
            mask-composite: exclude;
        }
        
        .score-value {
            font-size: 2.5rem;
            font-weight: 700;
            color: var(--accent-green);
        }
        
        .score-label {
            font-size: 0.85rem;
            color: var(--text-muted);
        }
        
        /* Metric rows */
        .metric-row {
            display: flex;
            justify-content: space-between;
            padding: 12px 0;
            border-bottom: 1px solid var(--border-color);
        }
        
        .metric-row:last-child {
            border-bottom: none;
        }
        
        .metric-label {
            color: var(--text-secondary);
        }
        
        .metric-value {
            font-weight: 600;
        }
        
        .metric-value.critical { color: var(--accent-red); }
        .metric-value.high { color: #ff9f43; }
        .metric-value.medium { color: var(--accent-yellow); }
        .metric-value.low { color: var(--accent-blue); }
        .metric-value.green { color: var(--accent-green); }
        .metric-value.red { color: var(--accent-red); }
        
        /* Quick stats */
        .quick-stats {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 20px;
            margin-bottom: 30px;
        }
        
        .quick-stat {
            background: var(--bg-surface);
            padding: 24px;
            border-radius: 12px;
            text-align: center;
            border: 1px solid var(--border-color);
        }
        
        .quick-stat .value {
            font-size: 2rem;
            font-weight: 700;
            color: var(--accent-blue);
        }
        
        .quick-stat .label {
            color: var(--text-muted);
            font-size: 0.85rem;
            margin-top: 5px;
        }
        
        /* Report links */
        .report-links {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 20px;
        }
        
        .report-link {
            background: var(--bg-surface);
            border: 1px solid var(--border-color);
            border-radius: 12px;
            padding: 24px;
            text-decoration: none;
            color: var(--text-primary);
            transition: all 0.2s ease;
            display: flex;
            align-items: center;
            gap: 20px;
        }
        
        .report-link:hover {
            transform: translateY(-3px);
            border-color: var(--accent-blue);
            box-shadow: 0 10px 30px rgba(0, 0, 0, 0.3);
        }
        
        .report-icon {
            width: 60px;
            height: 60px;
            border-radius: 12px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 1.5rem;
            flex-shrink: 0;
        }
        
        .report-icon.security {
            background: rgba(255, 107, 107, 0.15);
            color: var(--accent-red);
        }
        
        .report-icon.backup {
            background: rgba(0, 210, 106, 0.15);
            color: var(--accent-green);
        }
        
        .report-info h3 {
            font-size: 1.1rem;
            margin-bottom: 5px;
        }
        
        .report-info p {
            color: var(--text-muted);
            font-size: 0.9rem;
        }
        
        /* Footer */
        .footer {
            text-align: center;
            padding: 30px;
            color: var(--text-muted);
            font-size: 0.85rem;
        }
        
        @media (max-width: 768px) {
            .quick-stats { grid-template-columns: repeat(2, 1fr); }
            .dashboard-grid { grid-template-columns: 1fr; }
            .hero { padding: 30px 20px; }
            .hero h1 { font-size: 1.8rem; }
        }
    </style>
</head>
<body>
    <nav class="report-nav">
        <span class="nav-brand">Azure Audit Reports</span>
        <a href="index.html" class="nav-link active">Dashboard</a>
        <a href="security.html" class="nav-link">Security Audit</a>
        <a href="vm-backup.html" class="nav-link">VM Backup</a>
        <a href="advisor.html" class="nav-link">Advisor</a>
    </nav>
    
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
                <div class="value" style="$(if ($deprecatedCount -gt 0) { 'color: var(--accent-red);' })">$deprecatedCount</div>
                <div class="label">Deprecated Components</div>
            </div>
            <div class="quick-stat">
                <div class="value">$($failedFindings.Count)</div>
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
                        <span class="metric-value green">$($advisorCurrency)$([math]::Round($advisorSavings, 0))/yr</span>
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
            <a href="advisor.html" class="report-link">
                <div class="report-icon advisor" style="background: rgba(254, 202, 87, 0.15); color: var(--accent-yellow);">&loz;</div>
                <div class="report-info">
                    <h3>Azure Advisor</h3>
                    <p>$advisorCount recommendations | $advisorHighCount high impact</p>
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
    
    # Write to file
    $html | Out-File -FilePath $OutputPath -Encoding UTF8
    
    return $OutputPath
}

