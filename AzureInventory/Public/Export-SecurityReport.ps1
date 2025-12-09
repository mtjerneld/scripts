<#
.SYNOPSIS
    Generates HTML security audit report with modern responsive design.

.DESCRIPTION
    Creates a comprehensive HTML report with executive summary, detailed findings with expandable rows,
    and interactive filtering. Uses custom HTML generation for full control over design.

.PARAMETER AuditResult
    AuditResult object from Invoke-AzureSecurityAudit.

.PARAMETER OutputPath
    Path for HTML report output.

.EXAMPLE
    Export-SecurityReport -AuditResult $result -OutputPath ".\report.html"
#>
function Export-SecurityReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$AuditResult,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )
    
    # Helper function for HTML encoding
    function Encode-Html {
        param([string]$Text)
        if ($Text) {
            # Use System.Web.HttpUtility if available, otherwise manual encoding
            try {
                Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
                return [System.Web.HttpUtility]::HtmlEncode($Text)
            }
            catch {
                # Manual HTML encoding fallback
                return $Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace "'", '&#39;'
            }
        }
        return ""
    }
    
    # Prepare data
    $findings = $AuditResult.Findings
    $failedFindings = $findings | Where-Object { $_.Status -eq 'FAIL' }
    # Include all findings with EOLDate, regardless of status (deprecated components should be shown even if currently compliant)
    $eolFindings = $findings | Where-Object { 
        $eolDate = $_.EOLDate
        $eolDate -and -not [string]::IsNullOrWhiteSpace($eolDate) -and $eolDate -ne "N/A"
    }
    
    # Debug: Log EOL findings count
    Write-Verbose "EOL Findings count: $($eolFindings.Count)"
    if ($eolFindings.Count -gt 0) {
        Write-Verbose "EOL Findings sample: $($eolFindings[0] | ConvertTo-Json -Depth 2)"
    }
    
    # Create output directory if needed
    $outputDir = Split-Path -Parent $OutputPath
    if ($outputDir -and -not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    
    # Note: We no longer use external CSS files - all styles are inline for dark mode consistency
    $cssContent = ""
    
    # Generate HTML report
    try {
        # Calculate summary values - count FAIL findings by severity directly from findings
        # This ensures accuracy even if FindingsBySeverity object has issues
        # Note: $failedFindings already contains only FAIL status findings
        # Convert to array to ensure proper counting
        $failedArray = @($failedFindings)
        
        # Count by severity - use simpler comparison that handles all cases
        $criticalValue = 0
        $highValue = 0
        $mediumValue = 0
        $lowValue = 0
        
        foreach ($finding in $failedArray) {
            if ($finding.Severity) {
                $severity = $finding.Severity.ToString().Trim()
                switch ($severity) {
                    'Critical' { $criticalValue++ }
                    'High' { $highValue++ }
                    'Medium' { $mediumValue++ }
                    'Low' { $lowValue++ }
                }
            }
        }
        
        Write-Verbose "Summary counts - Critical: $criticalValue, High: $highValue, Medium: $mediumValue, Low: $lowValue (Total failed: $($failedArray.Count))"
        if ($failedArray.Count -gt 0) {
            $uniqueSeverities = $failedArray | Select-Object -ExpandProperty Severity -Unique | Sort-Object
            Write-Verbose "Unique severities found: $($uniqueSeverities -join ', ')"
            Write-Verbose "Severity breakdown: Critical=$criticalValue, High=$highValue, Medium=$mediumValue, Low=$lowValue"
        }
        
        $totalFindings = $findings.Count
        
        # Build HTML
        $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure Security Audit Report</title>
    <style type="text/css">
/* Dark Mode Theme - matching dashboard and VM backup reports */
:root {
    --bg-primary: #0f0f1a;
    --bg-secondary: #1a1a2e;
    --surface: #252542;
    --bg: #1f1f35;
    --bg-hover: #2d2d4a;
    --text: #e8e8e8;
    --text-secondary: #b8b8b8;
    --text-muted: #888;
    --border: #3d3d5c;
    --pri-600: #54a0ff;
    --pri-700: #2e86de;
    --info: #54a0ff;
    --success: #00d26a;
    --warning: #feca57;
    --danger: #ff6b6b;
    --radius-sm: 8px;
    --radius-md: 12px;
    --shadow-sm: 0 2px 4px rgba(0, 0, 0, 0.3);
    --shadow-md: 0 4px 12px rgba(0, 0, 0, 0.4);
    --shadow-lg: 0 8px 24px rgba(0, 0, 0, 0.5);
    --background: #1a1a2e;
}

* {
    box-sizing: border-box;
}

body {
    font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif;
    background-color: var(--bg-primary);
    color: var(--text);
    margin: 0;
    padding: 0;
    line-height: 1.6;
}

.container {
    max-width: 1600px;
    margin: 0 auto;
    padding: 30px;
}

/* Page Header */
.page-header {
    margin-bottom: 30px;
}

.page-header h1 {
    font-size: 2rem;
    font-weight: 600;
    margin: 0 0 15px 0;
    color: var(--text);
}

.metadata {
    display: flex;
    flex-wrap: wrap;
    gap: 20px;
    color: var(--text-muted);
    font-size: 0.9rem;
}

.metadata p {
    margin: 0;
}

.metadata strong {
    color: var(--text-secondary);
}

/* Summary Grid */
h2 {
    color: var(--text);
    font-size: 1.3rem;
    margin: 30px 0 20px 0;
    font-weight: 600;
}

.summary-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
    gap: 20px;
    margin-bottom: 30px;
}

.summary-card {
    background: var(--surface);
    border-radius: var(--radius-md);
    padding: 24px;
    text-align: center;
    border: 1px solid var(--border);
    transition: transform 0.2s ease, box-shadow 0.2s ease;
}

.summary-card:hover {
    transform: translateY(-2px);
    box-shadow: var(--shadow-md);
}

.summary-card-label {
    font-size: 0.85rem;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.5px;
    margin-bottom: 8px;
}

.summary-card-value {
    font-size: 2.5rem;
    font-weight: 700;
    line-height: 1.2;
}

.summary-card.critical .summary-card-value { color: var(--danger); }
.summary-card.high .summary-card-value { color: #ff9f43; }
.summary-card.medium .summary-card-value { color: var(--warning); }
.summary-card.low .summary-card-value { color: var(--info); }

/* Status badges */
.status-badge {
    display: inline-block;
    padding: 4px 12px;
    border-radius: 4px;
    font-size: 0.8rem;
    font-weight: 600;
}

.status-badge.critical {
    background: rgba(255, 107, 107, 0.15);
    color: var(--danger);
}

.status-badge.high {
    background: rgba(255, 159, 67, 0.15);
    color: #ff9f43;
}

.status-badge.medium {
    background: rgba(254, 202, 87, 0.15);
    color: var(--warning);
}

.status-badge.low {
    background: rgba(84, 160, 255, 0.15);
    color: var(--info);
}

/* Category Box styling */
.category-box {
    background: var(--surface);
    border-radius: var(--radius-md);
    margin-bottom: 20px;
    border: 1px solid var(--border);
    overflow: hidden;
}

.category-header {
    background: var(--bg-secondary);
    padding: 16px 24px;
    cursor: pointer;
    display: flex;
    align-items: center;
    gap: 12px;
    transition: background 0.2s ease;
}

.category-header:hover {
    background: var(--bg-hover);
}

.category-header h3 {
    margin: 0;
    font-size: 1.1rem;
    font-weight: 600;
    color: var(--text);
    flex: 1;
}

.category-content {
    padding: 0;
}

/* Filter Controls */
.filter-controls {
    display: flex;
    flex-wrap: wrap;
    gap: 1rem;
    align-items: center;
    margin-bottom: 1.5rem;
    padding: 1rem;
    background-color: var(--bg);
    border-radius: var(--radius-sm);
    border: 1px solid var(--border);
}

.filter-group {
    display: flex;
    align-items: center;
    gap: 0.5rem;
}

.filter-group label {
    font-weight: 500;
    color: var(--text);
    white-space: nowrap;
}

.filter-select,
.filter-input {
    padding: 0.5rem 1rem;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background-color: var(--surface);
    color: var(--text);
    font-size: 0.9rem;
    transition: all 0.2s;
}

.filter-input {
    min-width: 200px;
    cursor: text;
}

.filter-select {
    cursor: pointer;
}

.filter-select:hover,
.filter-input:hover {
    border-color: var(--pri-600);
}

.filter-select:focus,
.filter-input:focus {
    outline: none;
    border-color: var(--pri-600);
    box-shadow: 0 0 0 3px rgba(0, 120, 212, 0.1);
}

.btn-clear {
    padding: 0.5rem 1rem;
    background-color: var(--text-muted);
    color: white;
    border: none;
    border-radius: var(--radius-sm);
    cursor: pointer;
    font-size: 0.9rem;
    transition: background-color 0.2s;
}

.btn-clear:hover {
    background-color: var(--text);
}

.result-count {
    font-weight: 500;
    color: var(--text-muted);
    padding: 0.5rem 1rem;
    background-color: var(--surface);
    border-radius: var(--radius-sm);
    border: 1px solid var(--border);
}

/* Controls Table */
.controls-table {
    width: 100%;
    border-collapse: collapse;
    margin-top: 1rem;
}

.controls-table thead {
    background-color: var(--bg);
    position: sticky;
    top: 0;
    z-index: 10;
}

.controls-table th {
    padding: 0.75rem;
    text-align: left;
    font-weight: 600;
    color: var(--text);
    border-bottom: 2px solid var(--border);
}

.controls-table td {
    padding: 0.75rem;
    border-bottom: 1px solid var(--border);
}

.control-row {
    transition: opacity 0.2s, transform 0.2s;
}

.control-row.hidden {
    display: none;
}

.control-row:hover {
    background-color: var(--bg);
}

.control-resources-row {
    background-color: var(--surface);
}

.control-resources-row.hidden {
    display: none;
}

.resource-detail-control-row.hidden {
    display: none;
}

.control-resources-table {
    width: 100%;
    border-collapse: collapse;
    margin-left: 1rem;
    background-color: var(--bg);
}

.control-resources-table th {
    padding: 0.5rem 0.75rem;
    text-align: left;
    font-weight: 600;
    font-size: 0.9rem;
    color: var(--text);
    border-bottom: 1px solid var(--border);
    background-color: var(--surface);
}

.control-resources-table td {
    padding: 0.5rem 0.75rem;
    border-bottom: 1px solid var(--border);
    font-size: 0.9rem;
}

.expand-cell {
    width: 2rem;
    text-align: center;
}

.control-expand-icon {
    width: 0;
    height: 0;
    border-left: 6px solid var(--text-muted);
    border-top: 5px solid transparent;
    border-bottom: 5px solid transparent;
    border-right: none;
    display: inline-block;
    transition: transform 0.2s;
    vertical-align: middle;
}

.control-row.expanded .control-expand-icon,
.resource-detail-control-row.expanded .control-expand-icon,
.control-detail-row.expanded .control-expand-icon {
    border-left: 5px solid transparent;
    border-right: 5px solid transparent;
    border-top: 6px solid var(--text-muted);
    border-bottom: none;
}

/* Remediation Content */
.remediation-content {
    padding: 1rem;
    background-color: var(--bg);
}

.remediation-section {
    margin-bottom: 1rem;
}

.remediation-section h4 {
    margin: 0 0 0.5rem 0;
    color: var(--pri-600);
    font-size: 0.9rem;
    font-weight: 600;
}

.remediation-section p {
    margin: 0;
    color: var(--text-muted);
    line-height: 1.6;
}

.remediation-section pre {
    background-color: var(--surface);
    padding: 0.75rem;
    border-radius: var(--radius-sm);
    border: 1px solid var(--border);
    overflow-x: auto;
    margin: 0;
}

.remediation-section code {
    font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
    font-size: 0.85rem;
    color: var(--text);
}

.reference-links {
    list-style: none;
    padding: 0;
    margin: 0.5rem 0 0 0;
}

.reference-links li {
    margin-bottom: 0.5rem;
}

.reference-links a {
    color: var(--pri-600);
    text-decoration: none;
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
}

.reference-links a:hover {
    color: var(--pri-700);
    text-decoration: underline;
}

.reference-links a::before {
    content: "\2192";
    font-size: 0.9rem;
}

.remediation-row {
    background-color: var(--bg);
}

.remediation-row.hidden {
    display: none;
}

@keyframes fadeIn {
    from {
        opacity: 0;
        transform: translateY(-5px);
    }
    to {
        opacity: 1;
        transform: translateY(0);
    }
}

/* Clickable summary cards */
.summary-card[data-severity] {
    transition: transform 0.2s, box-shadow 0.2s, opacity 0.2s;
    user-select: none;
}

.summary-card[data-severity]:hover {
    transform: translateY(-3px);
    box-shadow: var(--shadow-lg);
}

.summary-card[data-severity]:active {
    transform: translateY(-1px);
    opacity: 0.9;
}


/* Status classes for PASS/FAIL */
.status-ok {
    color: var(--success);
    font-weight: 600;
}

.status-fail {
    color: var(--danger);
    font-weight: 600;
}

.status-warn {
    color: var(--warning);
    font-weight: 600;
}

/* Compliance Scores */
.compliance-scores-section {
    margin: 2rem 0;
    padding: 1.5rem;
    background-color: var(--surface);
    border-radius: var(--radius-sm);
    border: 1px solid var(--border);
}

.compliance-scores-section h3 {
    margin-top: 0;
    margin-bottom: 1.5rem;
    color: var(--text);
    font-size: 1.3rem;
}

.compliance-scores-section h4 {
    margin-top: 2rem;
    margin-bottom: 1rem;
    color: var(--text);
    font-size: 1.1rem;
}

.score-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 1rem;
    margin-bottom: 2rem;
}

.score-card {
    padding: 1.5rem;
    border-radius: var(--radius-sm);
    border: 2px solid var(--border);
    text-align: center;
    background-color: var(--bg);
}

.score-card.overall-score {
    border-width: 3px;
    font-weight: 600;
}

.score-label {
    font-size: 0.9rem;
    color: var(--text-muted);
    margin-bottom: 0.5rem;
    font-weight: 600;
}

.score-value {
    font-size: 2.5rem;
    font-weight: 700;
    margin: 0.5rem 0;
    line-height: 1;
}

.score-details {
    font-size: 0.85rem;
    color: var(--text-muted);
    margin-top: 0.5rem;
}

.score-excellent {
    border-color: var(--success);
    color: var(--success);
}

.score-good {
    border-color: var(--warning);
    color: var(--warning);
}

.score-fair {
    border-color: #ff9f43;
    color: #ff9f43;
}

.score-poor {
    border-color: var(--danger);
    color: var(--danger);
}

.category-scores-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
    gap: 1rem;
}

.category-score-card {
    padding: 1rem;
    border-radius: var(--radius-sm);
    border: 2px solid var(--border);
    text-align: center;
    background-color: var(--bg);
}

.category-score-label {
    font-size: 0.85rem;
    color: var(--text-muted);
    margin-bottom: 0.5rem;
    font-weight: 600;
}

.category-score-value {
    font-size: 1.8rem;
    font-weight: 700;
    line-height: 1;
}

.page-numbers {
    display: flex;
    gap: 0.25rem;
    align-items: center;
}

.page-number {
    padding: 0.5rem 0.75rem;
    background-color: var(--surface);
    color: var(--text);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    cursor: pointer;
    font-size: 0.9rem;
    transition: all 0.2s;
    min-width: 2.5rem;
    text-align: center;
}

.page-number:hover {
    background-color: var(--bg);
    border-color: var(--pri-600);
}

.page-number.active {
    background-color: var(--pri-600);
    color: white;
    border-color: var(--pri-600);
}

/* Subscription Details */
.subscription-box {
    margin-bottom: 1.5rem;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background-color: var(--surface);
    overflow: hidden;
}

.subscription-header {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 1rem;
    background-color: var(--bg);
    border-bottom: 1px solid var(--border);
    transition: background-color 0.2s;
    border-radius: var(--radius-sm) var(--radius-sm) 0 0;
}

.subscription-header.collapsed {
    border-bottom: none;
    border-radius: var(--radius-sm);
}

.subscription-header:hover {
    background-color: var(--surface);
}

.subscription-header h3 {
    margin: 0;
    flex: 1;
}

.header-severity-summary {
    display: flex;
    gap: 0.75rem;
    margin-left: auto;
    font-size: 0.85rem;
    font-weight: 500;
}

.severity-count {
    padding: 0.2rem 0.5rem;
    border-radius: 4px;
    font-size: 0.8rem;
}

.severity-count.critical {
    background-color: rgba(220, 53, 69, 0.15);
    color: #dc3545;
}

.severity-count.high {
    background-color: rgba(253, 126, 20, 0.15);
    color: #fd7e14;
}

.severity-count.medium {
    background-color: rgba(255, 193, 7, 0.15);
    color: #ffc107;
}

.severity-count.low {
    background-color: rgba(100, 149, 237, 0.15);
    color: #6495ed;
}

.expand-icon {
    width: 0;
    height: 0;
    border-left: 6px solid var(--text-muted);
    border-top: 5px solid transparent;
    border-bottom: 5px solid transparent;
    border-right: none;
    display: inline-block;
    transition: transform 0.2s;
    margin-right: 0.5rem;
    vertical-align: middle;
    flex-shrink: 0;
}

.subscription-header:not(.collapsed) .expand-icon {
    border-left: 5px solid transparent;
    border-right: 5px solid transparent;
    border-top: 6px solid var(--text-muted);
    border-bottom: none;
}

.subscription-content {
    padding: 1rem;
    border-radius: 0 0 var(--radius-sm) var(--radius-sm);
}

.resource-summary-table {
    width: 100%;
    border-collapse: collapse;
}

.resource-summary-table th {
    padding: 0.75rem;
    text-align: left;
    font-weight: 600;
    color: var(--text);
    border-bottom: 2px solid var(--border);
    background-color: var(--bg);
}

.resource-summary-table td {
    padding: 0.75rem;
    border-bottom: 1px solid var(--border);
}

.resource-row:hover {
    background-color: var(--bg);
}

.resource-detail-row {
    background-color: var(--surface);
}

.resource-detail-row.hidden {
    display: none;
}

.resource-issues-table {
    width: 100%;
    border-collapse: collapse;
    margin-left: 1rem;
    background-color: var(--bg);
}

.resource-issues-table th {
    padding: 0.5rem 0.75rem;
    text-align: left;
    font-weight: 600;
    font-size: 0.9rem;
    color: var(--text);
    border-bottom: 1px solid var(--border);
    background-color: var(--surface);
}

.resource-issues-table td {
    padding: 0.5rem 0.75rem;
    border-bottom: 1px solid var(--border);
    font-size: 0.9rem;
}

/* Responsive */
@media (max-width: 768px) {
    .filter-controls {
        flex-direction: column;
        align-items: stretch;
    }
    
    .filter-group {
        flex-direction: column;
        align-items: stretch;
    }
    
    .filter-select,
    .btn-clear {
        width: 100%;
    }
    
    .controls-table,
    .resource-summary-table {
        font-size: 0.85rem;
    }
    
    .controls-table th,
    .controls-table td,
    .resource-summary-table th,
    .resource-summary-table td {
        padding: 0.5rem;
    }
}
        /* Navigation */
        .report-nav {
            background: var(--surface);
            padding: 15px 30px;
            display: flex;
            gap: 10px;
            align-items: center;
            border-bottom: 1px solid var(--border);
            position: sticky;
            top: 0;
            z-index: 100;
        }
        
        .nav-brand {
            font-weight: 600;
            font-size: 1.1rem;
            color: var(--info);
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
            background: var(--background);
            color: var(--text);
        }
        
        .nav-link.active {
            background: var(--info);
            color: white;
        }
    </style>
</head>
<body>
    <nav class="report-nav">
        <span class="nav-brand">Azure Audit Reports</span>
        <a href="index.html" class="nav-link">Dashboard</a>
        <a href="security.html" class="nav-link active">Security Audit</a>
        <a href="vm-backup.html" class="nav-link">VM Backup</a>
        <a href="advisor.html" class="nav-link">Advisor</a>
    </nav>
    
    <div class="container">
        <div class="page-header">
            <h1>Azure Security Audit Report</h1>
            <div class="metadata">
                <p><strong>Tenant:</strong> $($AuditResult.TenantId)</p>
                <p><strong>Scanned:</strong> $($AuditResult.ScanStartTime.ToString('yyyy-MM-dd HH:mm:ss'))</p>
                <p><strong>Subscriptions:</strong> $($AuditResult.SubscriptionsScanned.Count)</p>
                <p><strong>Resources:</strong> $($AuditResult.TotalResources)</p>
                <p><strong>Total Findings:</strong> $totalFindings</p>
            </div>
        </div>
        
        <h2>Executive Summary</h2>
        <div class="summary-grid">
            <div class="summary-card critical" id="summaryCritical" data-severity="Critical" style="cursor: pointer;">
                <div class="summary-card-label">Critical</div>
                <div class="summary-card-value">$criticalValue</div>
            </div>
            <div class="summary-card high" id="summaryHigh" data-severity="High" style="cursor: pointer;">
                <div class="summary-card-label">High</div>
                <div class="summary-card-value">$highValue</div>
            </div>
            <div class="summary-card medium" id="summaryMedium" data-severity="Medium" style="cursor: pointer;">
                <div class="summary-card-label">Medium</div>
                <div class="summary-card-value">$mediumValue</div>
            </div>
            <div class="summary-card low" id="summaryLow" data-severity="Low" style="cursor: pointer;">
                <div class="summary-card-label">Low</div>
                <div class="summary-card-value">$lowValue</div>
            </div>
        </div>
"@
        
        # Compliance Scores Section
        if ($AuditResult.ComplianceScores) {
            $overallScore = $AuditResult.ComplianceScores.OverallScore
            $l1Score = $AuditResult.ComplianceScores.L1Score
            $l2Score = $AuditResult.ComplianceScores.L2Score
            $scoresByCategory = $AuditResult.ComplianceScores.ScoresByCategory
            $passedChecks = $AuditResult.ComplianceScores.PassedChecks
            $totalChecks = $AuditResult.ComplianceScores.TotalChecks
            
            # Determine score color
            $scoreColor = if ($overallScore -ge 90) { "score-excellent" } 
                         elseif ($overallScore -ge 75) { "score-good" } 
                         elseif ($overallScore -ge 50) { "score-fair" } 
                         else { "score-poor" }
            
            $html += @"
        <div class="compliance-scores-section">
            <h3>Security Compliance Score</h3>
            <div class="score-grid">
                <div class="score-card overall-score $scoreColor">
                    <div class="score-label">Overall Score</div>
                    <div class="score-value">$overallScore%</div>
                    <div class="score-details">$passedChecks / $totalChecks checks passed</div>
                </div>
                <div class="score-card l1-score">
                    <div class="score-label">Level 1 (L1)</div>
                    <div class="score-value">$l1Score%</div>
                    <div class="score-details">CIS v4.0.0 Mandatory controls</div>
                </div>
"@
            if ($null -ne $l2Score) {
                $l2ScoreColor = if ($l2Score -ge 90) { "score-excellent" } 
                               elseif ($l2Score -ge 75) { "score-good" } 
                               elseif ($l2Score -ge 50) { "score-fair" } 
                               else { "score-poor" }
                $html += @"
                <div class="score-card l2-score $l2ScoreColor">
                    <div class="score-label">Level 2 (L2)</div>
                    <div class="score-value">$l2Score%</div>
                    <div class="score-details">Enhanced controls</div>
                </div>
"@
            }
            $html += @"
            </div>
            
            <h4 style="margin-top: 2rem; margin-bottom: 1rem;">Scores by Category</h4>
            <div class="category-scores-grid">
"@
            if ($scoresByCategory -and $scoresByCategory.Count -gt 0) {
                foreach ($category in ($scoresByCategory.Keys | Sort-Object)) {
                    $catScore = $scoresByCategory[$category]
                    $catScoreColor = if ($catScore -ge 90) { "score-excellent" } 
                                    elseif ($catScore -ge 75) { "score-good" } 
                                    elseif ($catScore -ge 50) { "score-fair" } 
                                    else { "score-poor" }
                    $html += @"
                <div class="category-score-card $catScoreColor">
                    <div class="category-score-label">$(Encode-Html $category)</div>
                    <div class="category-score-value">$catScore%</div>
                </div>
"@
                }
            }
            $html += @"
            </div>
        </div>
"@
        }
        
        # EOL/Deprecated Components Alert
        if ($eolFindings.Count -gt 0) {
            $eolCount = $eolFindings.Count
            $pastDueCount = ($eolFindings | Where-Object { 
                try { [DateTime]::Parse($_.EOLDate) -lt (Get-Date) } catch { $false }
            }).Count
            $upcomingCount = $eolCount - $pastDueCount
            
            $html += @"
        <h2>Deprecated Components Requiring Action</h2>
        <div class="subscription-box" id="deprecated-components-box" data-always-visible="true" style="border-color: var(--danger); display: block !important; visibility: visible !important;">
            <div class="subscription-header collapsed" data-subscription-id="deprecated-components" style="cursor: pointer; background-color: rgba(255, 107, 107, 0.1); display: flex !important;">
                <span class="expand-icon"></span>
                <h3 style="color: var(--danger); margin: 0;">Deprecated Components Found ($eolCount items)</h3>
                <span class="header-severity-summary">
                    <span class="severity-count critical">$pastDueCount Past Due</span>
                    <span class="severity-count medium">$upcomingCount Upcoming</span>
                </span>
            </div>
            <div class="subscription-content" id="deprecated-components" style="display: none;">
                <table class="resource-summary-table">
                    <thead>
                        <tr>
                            <th>Subscription</th>
                            <th>Resource Group</th>
                            <th>Resource</th>
                            <th>Category</th>
                            <th>Control</th>
                            <th>EOL Date</th>
                            <th>Status</th>
                        </tr>
                    </thead>
                    <tbody>
"@
            foreach ($finding in $eolFindings) {
                $eolDate = [DateTime]::Parse($finding.EOLDate)
                $status = if ($eolDate -lt (Get-Date)) { "PAST DUE" } else { "Upcoming" }
                $statusClass = if ($status -eq "PAST DUE") { "status-fail" } else { "status-warn" }
                $subscriptionName = if ($finding.SubscriptionName) { $finding.SubscriptionName } else { $finding.SubscriptionId }
                $resourceGroup = if ($finding.ResourceGroup) { $finding.ResourceGroup } else { "N/A" }
                $html += @"
                        <tr>
                            <td>$(Encode-Html $subscriptionName)</td>
                            <td>$(Encode-Html $resourceGroup)</td>
                            <td>$(Encode-Html $finding.ResourceName)</td>
                            <td>$(Encode-Html $finding.Category)</td>
                            <td>$(Encode-Html $finding.ControlName)</td>
                            <td>$(Encode-Html $finding.EOLDate)</td>
                            <td class="$statusClass">$status</td>
                        </tr>
"@
            }
            $html += @"
                    </tbody>
                </table>
            </div>
        </div>
"@
        }
        
        # Get unique categories and severities for filter dropdowns
        # Use all findings, not just failed ones, to populate category filter
        $allCategories = ($findings | Select-Object -ExpandProperty Category -Unique | Sort-Object)
        $categories = if ($allCategories.Count -gt 0) { $allCategories } else { @() }
        $severities = @("All", "Critical", "High", "Medium", "Low")
        
        # Get unique subscription names for subscription filter
        $allSubscriptions = ($failedFindings | Select-Object -ExpandProperty SubscriptionName -Unique | Sort-Object)
        $subscriptions = if ($allSubscriptions.Count -gt 0) { $allSubscriptions } else { @() }
        
        # Calculate total items for result count (resources + controls)
        $totalResources = ($failedFindings | Group-Object -Property @{Expression={$_.ResourceName + '|' + $_.ResourceGroup}}).Count
        # Include ControlName to differentiate controls with same ControlId (e.g., "N/A")
        $totalControls = ($failedFindings | Group-Object -Property @{Expression={$_.Category + '|' + $_.ControlId + '|' + $_.ControlName}}).Count
        $totalItems = $totalResources + $totalControls
        
        # Filters Section
        $html += @"
        <h2>Filters</h2>
        <div class="filter-controls">
            <div class="filter-group">
                <label for="searchFilter">Search:</label>
                <input type="text" id="searchFilter" class="filter-input" placeholder="Search resources, controls...">
            </div>
            <div class="filter-group">
                <label for="severityFilter">Severity:</label>
                <select id="severityFilter" class="filter-select">
                    <option value="all">All Severities</option>
                    <option value="Critical">Critical</option>
                    <option value="High">High</option>
                    <option value="Medium">Medium</option>
                    <option value="Low">Low</option>
                </select>
            </div>
            <div class="filter-group">
                <label for="categoryFilter">Category:</label>
                <select id="categoryFilter" class="filter-select">
                    <option value="all">All Categories</option>
"@
        foreach ($cat in $categories) {
            $html += @"
                    <option value="$(Encode-Html $cat)">$(Encode-Html $cat)</option>
"@
        }
        $html += @"
                </select>
            </div>
            <div class="filter-group">
                <label for="frameworkFilter">Framework:</label>
                <select id="frameworkFilter" class="filter-select">
                    <option value="all">All Frameworks</option>
                    <option value="cis">CIS</option>
                    <option value="asb">ASB</option>
                    <option value="wellarchitected">Well-Architected</option>
                </select>
            </div>
            <div class="filter-group">
                <label for="subscriptionFilter">Subscription:</label>
                <select id="subscriptionFilter" class="filter-select">
                    <option value="all">All Subscriptions</option>
"@
        foreach ($sub in $subscriptions) {
            $html += @"
                    <option value="$(Encode-Html $sub)">$(Encode-Html $sub)</option>
"@
        }
        $html += @"
                </select>
            </div>
            <div class="filter-group">
                <button id="clearFilters" class="btn-clear">Clear All</button>
            </div>
            <div class="filter-group">
                <span id="resultCount" class="result-count">Showing $totalItems items</span>
            </div>
        </div>
"@
        
        # Helper function for severity sort order
        function Get-SeverityOrder {
            param([string]$Severity)
            switch ($Severity) {
                "Critical" { return 0 }
                "High" { return 1 }
                "Medium" { return 2 }
                "Low" { return 3 }
                default { return 4 }
            }
        }
        
        # Category & Control Table
        # Group findings by Category + Control ID + Control Name (only controls with failures)
        # Use ControlName to differentiate controls with same ControlId (e.g., "N/A")
        $controlGroups = $failedFindings | Group-Object -Property @{Expression={$_.Category + '|' + $_.ControlId + '|' + $_.ControlName}} | Sort-Object Name
        
        if ($controlGroups.Count -gt 0) {
            $html += @"
        <h2>Failed Controls by Category</h2>
"@
            # Group controls by Category first
            # Extract category from each control group's first finding
            $categoryGroups = $controlGroups | Group-Object -Property @{Expression={($_.Group | Select-Object -First 1).Category}} | Sort-Object Name
            
            foreach ($categoryGroup in $categoryGroups) {
                $category = $categoryGroup.Name
                $categoryControls = $categoryGroup.Group
                
                # Count total failed findings (resources) for this category
                # Flatten all findings from all controls in this category
                $allCategoryFindings = @()
                foreach ($controlGroup in $categoryControls) {
                    $allCategoryFindings += $controlGroup.Group
                }
                $categoryFailedCount = $allCategoryFindings.Count
                
                # Count per severity for this category (use @() to ensure array for .Count)
                $catCritical = @($allCategoryFindings | Where-Object { $_.Severity -eq 'Critical' }).Count
                $catHigh = @($allCategoryFindings | Where-Object { $_.Severity -eq 'High' }).Count
                $catMedium = @($allCategoryFindings | Where-Object { $_.Severity -eq 'Medium' }).Count
                $catLow = @($allCategoryFindings | Where-Object { $_.Severity -eq 'Low' }).Count
                
                # Build severity summary string (only show non-zero)
                $catSeveritySummary = @()
                if ($catCritical -gt 0) { $catSeveritySummary += "<span class='severity-count critical'>$catCritical Critical</span>" }
                if ($catHigh -gt 0) { $catSeveritySummary += "<span class='severity-count high'>$catHigh High</span>" }
                if ($catMedium -gt 0) { $catSeveritySummary += "<span class='severity-count medium'>$catMedium Medium</span>" }
                if ($catLow -gt 0) { $catSeveritySummary += "<span class='severity-count low'>$catLow Low</span>" }
                $catSeverityDisplay = if ($catSeveritySummary.Count -gt 0) { $catSeveritySummary -join " " } else { "0 findings" }
                
                # Get highest severity for this category
                $categorySeverities = $allCategoryFindings | Select-Object -ExpandProperty Severity
                $categoryHighestSeverity = "Low"
                if ($categorySeverities -contains "Critical") { $categoryHighestSeverity = "Critical" }
                elseif ($categorySeverities -contains "High") { $categoryHighestSeverity = "High" }
                elseif ($categorySeverities -contains "Medium") { $categoryHighestSeverity = "Medium" }
                
                $categorySeverityClass = switch ($categoryHighestSeverity) {
                    "Critical" { "status-badge critical" }
                    "High" { "status-badge high" }
                    "Medium" { "status-badge medium" }
                    "Low" { "status-badge low" }
                    default { "" }
                }
                
                $categoryLower = ($category -replace '\s+', '-').ToLower()
                $categorySeverityLower = $categoryHighestSeverity.ToLower()
                
                # Build searchable text including all resource names, control names, and subscriptions
                $categoryResourceNames = ($allCategoryFindings | Select-Object -ExpandProperty ResourceName -Unique) -join " "
                $categoryControlNames = ($allCategoryFindings | Select-Object -ExpandProperty ControlName -Unique) -join " "
                $categorySubscriptions = ($allCategoryFindings | Select-Object -ExpandProperty SubscriptionName -Unique) -join " "
                $categorySearchableText = "$category $categoryHighestSeverity $categoryResourceNames $categoryControlNames $categorySubscriptions".ToLower()
                $categoryId = "cat-$(Encode-Html $category)"
                
                $html += @"
        <div class="subscription-box category-box" 
            data-category="$(Encode-Html $category)"
            data-severity="$(Encode-Html $categoryHighestSeverity)"
            data-category-lower="$categoryLower"
            data-severity-lower="$categorySeverityLower"
            data-searchable="$categorySearchableText">
            <div class="subscription-header category-header collapsed" data-category-id="$categoryId" style="cursor: pointer;">
                <span class="expand-icon"></span>
                <h3>$(Encode-Html $category)</h3>
                <span class="header-severity-summary">$catSeverityDisplay</span>
            </div>
            <div class="subscription-content category-content" id="$categoryId" style="display: none;">
                <table id="controlsTable" class="controls-table">
                    <thead>
                        <tr>
                            <th>Control ID</th>
                            <th>Control Name</th>
                            <th>Severity</th>
                            <th>Failed Resources</th>
                        </tr>
                    </thead>
                    <tbody>
"@
                # Sort controls by severity (Critical first)
                $sortedCategoryControls = $categoryControls | ForEach-Object {
                    $ctrlFindings = $_.Group
                    $ctrlSeverities = $ctrlFindings | Select-Object -ExpandProperty Severity
                    $ctrlHighest = "Low"
                    if ($ctrlSeverities -contains "Critical") { $ctrlHighest = "Critical" }
                    elseif ($ctrlSeverities -contains "High") { $ctrlHighest = "High" }
                    elseif ($ctrlSeverities -contains "Medium") { $ctrlHighest = "Medium" }
                    [PSCustomObject]@{
                        Group = $_.Group
                        Name = $_.Name
                        HighestSeverity = $ctrlHighest
                        SeverityOrder = (Get-SeverityOrder $ctrlHighest)
                    }
                } | Sort-Object SeverityOrder, Name
                
                foreach ($controlGroup in $sortedCategoryControls) {
                $controlFindings = $controlGroup.Group
                $firstFinding = $controlFindings[0]
                $category = $firstFinding.Category
                $controlId = $firstFinding.ControlId
                $controlName = $firstFinding.ControlName
                # Include ControlName in controlKey to differentiate controls with same ControlId
                $controlKey = "$category|$controlId|$controlName"
                $controlFrameworks = if ($firstFinding.Frameworks) { $firstFinding.Frameworks -join " " } else { "CIS" }
                $controlFrameworksLower = $controlFrameworks.ToLower()
                
                # Get highest severity (already calculated in sort)
                $highestSeverity = $controlGroup.HighestSeverity
                
                $severityClass = switch ($highestSeverity) {
                    "Critical" { "status-badge critical" }
                    "High" { "status-badge high" }
                    "Medium" { "status-badge medium" }
                    "Low" { "status-badge low" }
                    default { "" }
                }
                
                $failedCount = @($controlFindings).Count
                
                # Count findings by severity for this control
                $ctrlCritical = @($controlFindings | Where-Object { $_.Severity -eq 'Critical' }).Count
                $ctrlHigh = @($controlFindings | Where-Object { $_.Severity -eq 'High' }).Count
                $ctrlMedium = @($controlFindings | Where-Object { $_.Severity -eq 'Medium' }).Count
                $ctrlLow = @($controlFindings | Where-Object { $_.Severity -eq 'Low' }).Count
                
                # Build severity breakdown string (show all non-zero severities)
                $ctrlSeverityBreakdown = @()
                if ($ctrlCritical -gt 0) { $ctrlSeverityBreakdown += "<span class='severity-count critical'>$ctrlCritical Critical</span>" }
                if ($ctrlHigh -gt 0) { $ctrlSeverityBreakdown += "<span class='severity-count high'>$ctrlHigh High</span>" }
                if ($ctrlMedium -gt 0) { $ctrlSeverityBreakdown += "<span class='severity-count medium'>$ctrlMedium Medium</span>" }
                if ($ctrlLow -gt 0) { $ctrlSeverityBreakdown += "<span class='severity-count low'>$ctrlLow Low</span>" }
                $ctrlSeverityDisplay = if ($ctrlSeverityBreakdown.Count -gt 0) { $ctrlSeverityBreakdown -join " " } else { "<span class='$severityClass'>$(Encode-Html $highestSeverity)</span>" }
                
                $categoryLower = ($category -replace '\s+', '-').ToLower()
                $severityLower = $highestSeverity.ToLower()
                
                # Build searchable text including all resource names, resource groups, and subscriptions
                $resourceNames = ($controlFindings | Select-Object -ExpandProperty ResourceName -Unique) -join " "
                $resourceGroups = ($controlFindings | Select-Object -ExpandProperty ResourceGroup -Unique) -join " "
                $subscriptionNames = ($controlFindings | Select-Object -ExpandProperty SubscriptionName -Unique) -join " "
                $searchableText = "$category $controlId $controlName $highestSeverity $controlFrameworks $resourceNames $resourceGroups $subscriptionNames".ToLower()
                
                $html += @"
                <tr class="control-row" 
                    data-category="$(Encode-Html $category)" 
                    data-severity="$(Encode-Html $highestSeverity)"
                    data-frameworks="$controlFrameworksLower"
                    data-category-lower="$categoryLower"
                    data-severity-lower="$severityLower"
                    data-searchable="$searchableText"
                    data-control-key="$(Encode-Html $controlKey)"
                    style="cursor: pointer;">
                    <td>$(Encode-Html $controlId)</td>
                    <td>$(Encode-Html $controlName)</td>
                    <td>$ctrlSeverityDisplay</td>
                    <td>$failedCount</td>
                </tr>
                <tr class="control-resources-row hidden" data-control-key="$(Encode-Html $controlKey)">
                    <td colspan="4">
                        <table class="control-resources-table">
                            <thead>
                                <tr>
                                    <th>Subscription</th>
                                    <th>Resource Group</th>
                                    <th>Resource</th>
                                    <th>Current Value</th>
                                    <th>Expected Value</th>
                                </tr>
                            </thead>
                            <tbody>
"@
                # Sort control findings by severity
                $severityOrder = @{ "Critical" = 1; "High" = 2; "Medium" = 3; "Low" = 4 }
                $sortedControlFindings = $controlFindings | Sort-Object { $severityOrder[$_.Severity] }
                
                foreach ($finding in $sortedControlFindings) {
                    $findingSeverityClass = switch ($finding.Severity) {
                        "Critical" { "status-badge critical" }
                        "High" { "status-badge high" }
                        "Medium" { "status-badge medium" }
                        "Low" { "status-badge low" }
                        default { "" }
                    }
                    
                    $remediationSteps = if ($finding.RemediationSteps) { Encode-Html $finding.RemediationSteps } else { "No remediation steps provided." }
                    $remediationCommand = if ($finding.RemediationCommand) { Encode-Html $finding.RemediationCommand } else { "N/A" }
                    $note = if ($finding.Note) { Encode-Html $finding.Note } else { "" }
                    $cisLevel = if ($finding.CisLevel) { Encode-Html $finding.CisLevel } else { "N/A" }
                    $resourceDetailKey = "$($finding.ResourceName)|$($finding.ResourceGroup)|$($finding.ControlId)"
                    
                    # Build searchable string for this resource row
                    $resourceRowSearchable = @(
                        $finding.SubscriptionName,
                        $finding.ResourceGroup,
                        $finding.ResourceName,
                        $finding.CurrentValue,
                        $finding.ExpectedValue
                    ) -join ' ' | ForEach-Object { $_.ToLower() }
                    
                    $html += @"
                                <tr class="resource-detail-control-row" 
                                    data-resource-detail-key="$(Encode-Html $resourceDetailKey)" 
                                    data-searchable="$resourceRowSearchable"
                                    style="cursor: pointer;">
                                    <td>$(Encode-Html $finding.SubscriptionName)</td>
                                    <td>$(Encode-Html $finding.ResourceGroup)</td>
                                    <td>$(Encode-Html $finding.ResourceName)</td>
                                    <td>$(Encode-Html $finding.CurrentValue)</td>
                                    <td>$(Encode-Html $finding.ExpectedValue)</td>
                                </tr>
                                <tr class="remediation-row hidden" data-parent-resource-detail-key="$(Encode-Html $resourceDetailKey)">
                                    <td colspan="5">
                                        <div class="remediation-content">
                                            <div class="remediation-section">
                                                <h4>Description</h4>
                                                <p>$remediationSteps</p>
                                            </div>
                                            <div class="remediation-section">
                                                <h4>Remediation Command</h4>
                                                <pre><code>$remediationCommand</code></pre>
                                            </div>
"@
                            if ($finding.References -and $finding.References.Count -gt 0) {
                                $html += @"
                                            <div class="remediation-section">
                                                <h4>More Information</h4>
                                                <ul class="reference-links">
"@
                                foreach ($ref in $finding.References) {
                                    $refText = $ref
                                    # Extract readable text from Tenable URLs
                                    if ($ref -match 'tenable\.com') {
                                        $refText = "Tenable Audit Item"
                                    } elseif ($ref -match 'learn\.microsoft\.com') {
                                        $refText = "Microsoft Learn Documentation"
                                    } elseif ($ref -match 'workbench\.cisecurity\.org') {
                                        $refText = "CIS Workbench"
                                    }
                                    $html += @"
                                                    <li><a href="$(Encode-Html $ref)" target="_blank" rel="noopener noreferrer">$(Encode-Html $refText)</a></li>
"@
                                }
                                $html += @"
                                                </ul>
                                            </div>
"@
                            }
                            $html += @"
"@
                    if ($note) {
                        $html += @"
                                            <div class="remediation-section">
                                                <h4>Note</h4>
                                                <p>$note</p>
                                            </div>
"@
                    }
                    $html += @"
                                            <div class="remediation-section">
                                                <h4>Additional Information</h4>
                                                <p><strong>CIS Level:</strong> $cisLevel | <strong>Severity:</strong> <span class="$findingSeverityClass">$(Encode-Html $finding.Severity)</span> | <strong>Resource ID:</strong> $(Encode-Html $finding.ResourceId)</p>
                                            </div>
                                        </div>
                                    </td>
                                </tr>
"@
                }
                $html += @"
                            </tbody>
                        </table>
                    </td>
                </tr>
"@
                }
                $html += @"
                    </tbody>
                </table>
            </div>
        </div>
"@
            }
        }
        
        # Failed Controls by Subscription
        if ($AuditResult.SubscriptionsScanned.Count -gt 0) {
            $html += @"
        <h2>Failed Controls by Subscription</h2>
"@
            foreach ($subId in $AuditResult.SubscriptionsScanned) {
                # Get all findings for this subscription (both PASS and FAIL)
                $subAllFindings = $findings | Where-Object { $_.SubscriptionId -eq $subId }
                $subFailedFindings = $failedFindings | Where-Object { $_.SubscriptionId -eq $subId }
                
                # Get subscription name from SubscriptionNames mapping (preferred) or from findings
                $subName = $null
                
                # Debug: Check if SubscriptionNames exists and has this key
                Write-Verbose "Looking up name for subscription: $subId"
                Write-Verbose "  SubscriptionNames exists: $($null -ne $AuditResult.SubscriptionNames)"
                if ($AuditResult.SubscriptionNames) {
                    Write-Verbose "  SubscriptionNames type: $($AuditResult.SubscriptionNames.GetType().Name)"
                    Write-Verbose "  SubscriptionNames count: $($AuditResult.SubscriptionNames.Count)"
                    Write-Verbose "  Has key '$subId': $($AuditResult.SubscriptionNames.ContainsKey($subId))"
                    if ($AuditResult.SubscriptionNames.ContainsKey($subId)) {
                        $subName = $AuditResult.SubscriptionNames[$subId]
                        Write-Verbose "  Found name: '$subName'"
                    }
                }
                if (-not $subName) {
                    $subName = ($subAllFindings | Select-Object -First 1 -ExpandProperty SubscriptionName)
                    Write-Verbose "  Fallback to findings name: '$subName'"
                }
                if (-not $subName) {
                    $subName = $subId
                    Write-Verbose "  Fallback to ID: '$subName'"
                }
                
                # Group findings by resource (ResourceName + ResourceGroup)
                # Use only FAIL findings for grouping, sort by severity
                $resourceGroupsUnsorted = $subFailedFindings | Group-Object -Property @{Expression={$_.ResourceName + '|' + $_.ResourceGroup}}
                $resourceGroups = $resourceGroupsUnsorted | ForEach-Object {
                    $rgFindings = $_.Group
                    $rgSeverities = $rgFindings | Select-Object -ExpandProperty Severity
                    $rgHighest = "Low"
                    if ($rgSeverities -contains "Critical") { $rgHighest = "Critical" }
                    elseif ($rgSeverities -contains "High") { $rgHighest = "High" }
                    elseif ($rgSeverities -contains "Medium") { $rgHighest = "Medium" }
                    [PSCustomObject]@{
                        Group = $_.Group
                        Name = $_.Name
                        HighestSeverity = $rgHighest
                        SeverityOrder = (Get-SeverityOrder $rgHighest)
                    }
                } | Sort-Object SeverityOrder, Name
                
                # Count per severity for this subscription (use @() to ensure array for .Count)
                $subCritical = @($subFailedFindings | Where-Object { $_.Severity -eq 'Critical' }).Count
                $subHigh = @($subFailedFindings | Where-Object { $_.Severity -eq 'High' }).Count
                $subMedium = @($subFailedFindings | Where-Object { $_.Severity -eq 'Medium' }).Count
                $subLow = @($subFailedFindings | Where-Object { $_.Severity -eq 'Low' }).Count
                
                # Build severity summary string (only show non-zero)
                $subSeveritySummary = @()
                if ($subCritical -gt 0) { $subSeveritySummary += "<span class='severity-count critical'>$subCritical Critical</span>" }
                if ($subHigh -gt 0) { $subSeveritySummary += "<span class='severity-count high'>$subHigh High</span>" }
                if ($subMedium -gt 0) { $subSeveritySummary += "<span class='severity-count medium'>$subMedium Medium</span>" }
                if ($subLow -gt 0) { $subSeveritySummary += "<span class='severity-count low'>$subLow Low</span>" }
                $subSeverityDisplay = if ($subSeveritySummary.Count -gt 0) { $subSeveritySummary -join " " } else { "0 findings" }
                
                # Get highest severity for this subscription
                $subSeverities = $subFailedFindings | Select-Object -ExpandProperty Severity
                $subHighestSeverity = "Low"
                if ($subSeverities -contains "Critical") { $subHighestSeverity = "Critical" }
                elseif ($subSeverities -contains "High") { $subHighestSeverity = "High" }
                elseif ($subSeverities -contains "Medium") { $subHighestSeverity = "Medium" }
                
                $subSeverityLower = $subHighestSeverity.ToLower()
                $subscriptionLower = ($subName -replace '\s+', '-').ToLower()
                
                # Build searchable text including all resource names and resource groups
                $subResourceNames = ($subFailedFindings | Select-Object -ExpandProperty ResourceName -Unique) -join " "
                $subResourceGroups = ($subFailedFindings | Select-Object -ExpandProperty ResourceGroup -Unique) -join " "
                $subSearchableText = "$subName $subHighestSeverity $subResourceNames $subResourceGroups".ToLower()
                
                $html += @"
        <div class="subscription-box"
            data-subscription="$(Encode-Html $subName)"
            data-severity="$(Encode-Html $subHighestSeverity)"
            data-subscription-lower="$subscriptionLower"
            data-severity-lower="$subSeverityLower"
            data-searchable="$subSearchableText">
            <div class="subscription-header collapsed" data-subscription-id="sub-$(Encode-Html $subId)" style="cursor: pointer;">
                <span class="expand-icon"></span>
                <h3>$(Encode-Html $subName)</h3>
                <span class="header-severity-summary">$subSeverityDisplay</span>
            </div>
            <div class="subscription-content" id="sub-$(Encode-Html $subId)" style="display: none;">
"@
                if ($subFailedFindings.Count -gt 0) {
                    $html += @"
                <table class="resource-summary-table">
                    <thead>
                        <tr>
                            <th>Resource Group</th>
                            <th>Resource</th>
                            <th>Category</th>
                            <th>Control ID</th>
                            <th>Issues</th>
                            <th>Severity</th>
                        </tr>
                    </thead>
                    <tbody>
"@
                    foreach ($resourceGroup in $resourceGroups) {
                        $resourceFindings = $resourceGroup.Group
                        $firstFinding = $resourceFindings[0]
                        $resourceName = $firstFinding.ResourceName
                        $resourceGroupName = $firstFinding.ResourceGroup
                        $resourceKey = "$resourceName|$resourceGroupName"
                        
                        # Get primary category (first category found)
                        $primaryCategory = ($resourceFindings | Select-Object -First 1 -ExpandProperty Category)
                        
                        # Count only FAIL findings for issues count (use @() for reliable count)
                        $failedResourceFindings = @($resourceFindings | Where-Object { $_.Status -eq 'FAIL' })
                        $issuesCount = $failedResourceFindings.Count
                        
                        # Skip resources with no issues
                        if ($issuesCount -eq 0) {
                            continue
                        }
                        
                        # Use pre-calculated highest severity from sort
                        $highestSeverity = $resourceGroup.HighestSeverity
                        
                        $severityClass = switch ($highestSeverity) {
                            "Critical" { "status-badge critical" }
                            "High" { "status-badge high" }
                            "Medium" { "status-badge medium" }
                            "Low" { "status-badge low" }
                            default { "" }
                        }
                        
                        # Get unique control IDs and names for this resource
                        $uniqueControlIds = ($failedResourceFindings | Select-Object -ExpandProperty ControlId -Unique | Sort-Object)
                        $controlIdsDisplay = if ($uniqueControlIds.Count -gt 0) { ($uniqueControlIds -join ', ') } else { "N/A" }
                        $uniqueControlNames = ($failedResourceFindings | Select-Object -ExpandProperty ControlName -Unique) -join " "
                        
                        $categoryLower = ($primaryCategory -replace '\s+', '-').ToLower()
                        $severityLower = $highestSeverity.ToLower()
                        $subscriptionLower = $subName.ToLower()
                        $searchableText = "$subName $resourceGroupName $resourceName $primaryCategory $controlIdsDisplay $uniqueControlNames $highestSeverity".ToLower()
                        
                        $html += @"
                        <tr class="resource-row" 
                            data-resource-key="$(Encode-Html $resourceKey)" 
                            data-category="$(Encode-Html $primaryCategory)"
                            data-severity="$(Encode-Html $highestSeverity)"
                            data-subscription="$(Encode-Html $subName)"
                            data-category-lower="$categoryLower"
                            data-severity-lower="$severityLower"
                            data-subscription-lower="$subscriptionLower"
                            data-searchable="$searchableText"
                            style="cursor: pointer;">
                            <td>$(Encode-Html $resourceGroupName)</td>
                            <td>$(Encode-Html $resourceName)</td>
                            <td>$(Encode-Html $primaryCategory)</td>
                            <td>$(Encode-Html $controlIdsDisplay)</td>
                            <td>$(if ($issuesCount -gt 0) { $issuesCount } else { 0 })</td>
                            <td><span class="$severityClass">$(Encode-Html $highestSeverity)</span></td>
                        </tr>
                        <tr class="resource-detail-row hidden" data-resource-key="$(Encode-Html $resourceKey)">
                            <td colspan="6">
                                <table class="resource-issues-table">
                                    <thead>
                                        <tr>
                                            <th>Control ID</th>
                                            <th>Control</th>
                                            <th>Severity</th>
                                            <th>Current Value</th>
                                            <th>Expected Value</th>
                                        </tr>
                                    </thead>
                                    <tbody>
"@
                        # Sort findings by severity: Critical > High > Medium > Low
                        $severityOrder = @{ "Critical" = 1; "High" = 2; "Medium" = 3; "Low" = 4 }
                        $sortedFindings = $failedResourceFindings | Sort-Object {
                            $severityOrder[$_.Severity]
                        }
                        
                        foreach ($finding in $sortedFindings) {
                            $findingSeverityClass = switch ($finding.Severity) {
                                "Critical" { "status-badge critical" }
                                "High" { "status-badge high" }
                                "Medium" { "status-badge medium" }
                                "Low" { "status-badge low" }
                                default { "" }
                            }
                            
                            $remediationSteps = if ($finding.RemediationSteps) { Encode-Html $finding.RemediationSteps } else { "No remediation steps provided." }
                            $remediationCommand = if ($finding.RemediationCommand) { Encode-Html $finding.RemediationCommand } else { "N/A" }
                            $note = if ($finding.Note) { Encode-Html $finding.Note } else { "" }
                            $cisLevel = if ($finding.CisLevel) { Encode-Html $finding.CisLevel } else { "N/A" }
                            $controlDetailKey = "$resourceKey|$($finding.ControlId)"
                            $findingFrameworks = if ($finding.Frameworks) { $finding.Frameworks -join " " } else { "CIS" }
                            
                            $findingSeverityLower = $finding.Severity.ToLower()
                            $findingCategoryLower = $finding.Category.ToLower()
                            $findingFrameworksLower = $findingFrameworks.ToLower()
                            $findingSearchable = "$($finding.ControlId) $($finding.ControlName) $($finding.Severity) $($finding.Category) $findingFrameworks $($finding.ResourceName) $($finding.ResourceGroup)".ToLower()
                            
                            $html += @"
                                        <tr class="control-detail-row" 
                                            data-control-detail-key="$(Encode-Html $controlDetailKey)" 
                                            data-severity-lower="$findingSeverityLower"
                                            data-category-lower="$findingCategoryLower"
                                            data-frameworks="$findingFrameworksLower"
                                            data-searchable="$findingSearchable"
                                            style="cursor: pointer;">
                                            <td>$(Encode-Html $finding.ControlId)</td>
                                            <td>$(Encode-Html $finding.ControlName)</td>
                                            <td><span class="$findingSeverityClass">$(Encode-Html $finding.Severity)</span></td>
                                            <td>$(Encode-Html $finding.CurrentValue)</td>
                                            <td>$(Encode-Html $finding.ExpectedValue)</td>
                                        </tr>
                                        <tr class="remediation-row hidden" data-parent-control-detail-key="$(Encode-Html $controlDetailKey)">
                                            <td colspan="5">
                                                <div class="remediation-content">
                                                    <div class="remediation-section">
                                                        <h4>Description</h4>
                                                        <p>$remediationSteps</p>
                                                    </div>
                                                    <div class="remediation-section">
                                                        <h4>Remediation Command</h4>
                                                        <pre><code>$remediationCommand</code></pre>
                                                    </div>
"@
                            if ($finding.References -and $finding.References.Count -gt 0) {
                                $html += @"
                                                    <div class="remediation-section">
                                                        <h4>More Information</h4>
                                                        <ul class="reference-links">
"@
                                foreach ($ref in $finding.References) {
                                    $refText = $ref
                                    # Extract readable text from Tenable URLs
                                    if ($ref -match 'tenable\.com') {
                                        $refText = "Tenable Audit Item"
                                    } elseif ($ref -match 'learn\.microsoft\.com') {
                                        $refText = "Microsoft Learn Documentation"
                                    } elseif ($ref -match 'workbench\.cisecurity\.org') {
                                        $refText = "CIS Workbench"
                                    }
                                    $html += @"
                                                            <li><a href="$(Encode-Html $ref)" target="_blank" rel="noopener noreferrer">$(Encode-Html $refText)</a></li>
"@
                                }
                                $html += @"
                                                        </ul>
                                                    </div>
"@
                            }
                            $html += @"
"@
                            if ($note) {
                                $html += @"
                                                    <div class="remediation-section">
                                                        <h4>Note</h4>
                                                        <p>$note</p>
                                                    </div>
"@
                            }
                            $html += @"
                                                    <div class="remediation-section">
                                                        <h4>Additional Information</h4>
                                                        <p><strong>Frameworks:</strong> $(Encode-Html $findingFrameworks) | <strong>CIS Level:</strong> $cisLevel | <strong>Resource ID:</strong> $(Encode-Html $finding.ResourceId)</p>
                                                    </div>
                                                </div>
                                            </td>
                                        </tr>
"@
                        }
                        $html += @"
                                    </tbody>
                                </table>
                            </td>
                        </tr>
"@
                    }
                    $html += @"
                    </tbody>
                </table>
"@
                }
                else {
                    $html += @"
                <p>No findings for this subscription.</p>
"@
                }
                $html += @"
            </div>
        </div>
"@
            }
        }
        
        # Footer - Close main HTML string before adding script
        $html += @"
        <div class="footer">
            <p>Report generated: $($AuditResult.ScanEndTime.ToString('yyyy-MM-dd HH:mm:ss')) | Tool Version: $($AuditResult.ToolVersion)</p>
        </div>
    </div>
"@
        # Add script in separate here-string
        $html += @"
    <script>
        // Interactive filtering and row expansion
        (function() {
            // Wait for DOM to be fully loaded
            function initFilters() {
                const severityFilter = document.getElementById('severityFilter');
                const categoryFilter = document.getElementById('categoryFilter');
                const frameworkFilter = document.getElementById('frameworkFilter');
                const subscriptionFilter = document.getElementById('subscriptionFilter');
                const searchFilter = document.getElementById('searchFilter');
                const clearFiltersBtn = document.getElementById('clearFilters');
                const resultCount = document.getElementById('resultCount');
                
                // Get all filterable elements
                const subscriptionBoxes = document.querySelectorAll('.subscription-box:not(.category-box)');
                const categoryBoxes = document.querySelectorAll('.category-box');
                const controlRows = document.querySelectorAll('.control-row');
                const resourceRows = document.querySelectorAll('.resource-row');
                
                console.log('Initializing filters...', {
                    severityFilter: !!severityFilter,
                    categoryFilter: !!categoryFilter,
                    frameworkFilter: !!frameworkFilter,
                    subscriptionFilter: !!subscriptionFilter,
                    searchFilter: !!searchFilter,
                    clearFiltersBtn: !!clearFiltersBtn,
                    resultCount: !!resultCount,
                    subscriptionBoxes: subscriptionBoxes.length,
                    categoryBoxes: categoryBoxes.length,
                    controlRows: controlRows.length,
                    resourceRows: resourceRows.length
                });
                
                if (!severityFilter || !categoryFilter || !frameworkFilter || !subscriptionFilter || !searchFilter || !clearFiltersBtn || !resultCount) {
                    console.error('Filter elements not found');
                    return;
                }
                
                function updateFilters() {
                    const selectedSeverity = severityFilter.value.toLowerCase();
                    const selectedCategory = categoryFilter.value.toLowerCase();
                    const selectedFramework = frameworkFilter.value.toLowerCase();
                    const selectedSubscription = subscriptionFilter.value.toLowerCase();
                    const searchText = searchFilter.value.toLowerCase().trim();
                    
                    let visibleCount = 0;
                    
                    // Filter subscription boxes (Failed Controls by Subscription)
                    subscriptionBoxes.forEach(box => {
                        // Always show deprecated-components box (special section) - check multiple ways
                        const deprecatedHeader = box.querySelector('[data-subscription-id="deprecated-components"]');
                        const isDeprecatedBox = deprecatedHeader !== null || 
                                               box.hasAttribute('data-always-visible') ||
                                               box.id === 'deprecated-components';
                        if (isDeprecatedBox) {
                            box.style.display = 'block';
                            box.style.visibility = 'visible';
                            box.style.opacity = '1';
                            return;
                        }
                        
                        const boxSubscription = box.getAttribute('data-subscription-lower') || '';
                        const searchableText = box.getAttribute('data-searchable') || '';
                        
                        const subscriptionMatch = selectedSubscription === 'all' || boxSubscription === selectedSubscription;
                        const searchMatch = searchText === '' || searchableText.includes(searchText);
                        
                        // Check if any resource rows inside match ALL active filters
                        const resourceRowsInBox = box.querySelectorAll('.resource-row');
                        let hasMatchingResource = false;
                        let visibleResourceCount = 0;
                        
                        // First pass: determine which resource rows match
                        resourceRowsInBox.forEach(row => {
                            const resourceKey = row.getAttribute('data-resource-key');
                            const rowCategory = row.getAttribute('data-category-lower') || '';
                            const rowSearchable = row.getAttribute('data-searchable') || '';
                            
                            // Filter control-detail-row elements inside this resource's detail row FIRST
                            let visibleControlCount = 0;
                            if (resourceKey) {
                                const detailRow = document.querySelector('.resource-detail-row[data-resource-key="' + resourceKey + '"]');
                                if (detailRow) {
                                    const controlDetailRows = detailRow.querySelectorAll('.control-detail-row');
                                    
                                    controlDetailRows.forEach(controlRow => {
                                        const controlSeverity = controlRow.getAttribute('data-severity-lower') || '';
                                        const controlCategory = controlRow.getAttribute('data-category-lower') || '';
                                        const controlFrameworks = controlRow.getAttribute('data-frameworks') || '';
                                        const controlSearchable = controlRow.getAttribute('data-searchable') || '';
                                        
                                        const controlSeverityMatch = selectedSeverity === 'all' || controlSeverity === selectedSeverity;
                                        const controlCategoryMatch = selectedCategory === 'all' || controlCategory === selectedCategory;
                                        const controlFrameworkMatch = selectedFramework === 'all' || controlFrameworks.includes(selectedFramework);
                                        const controlSearchMatch = searchText === '' || controlSearchable.includes(searchText);
                                        
                                        if (controlSeverityMatch && controlCategoryMatch && controlFrameworkMatch && controlSearchMatch) {
                                            controlRow.classList.remove('hidden');
                                            visibleControlCount++;
                                        } else {
                                            controlRow.classList.add('hidden');
                                            // Hide associated remediation row
                                            const controlDetailKey = controlRow.getAttribute('data-control-detail-key');
                                            if (controlDetailKey) {
                                                const remediationRow = document.querySelector('.remediation-row[data-parent-control-detail-key="' + controlDetailKey + '"]');
                                                if (remediationRow) {
                                                    remediationRow.classList.add('hidden');
                                                }
                                            }
                                        }
                                    });
                                    
                                    // Hide detail row if no controls are visible
                                    if (visibleControlCount === 0) {
                                        detailRow.classList.add('hidden');
                                    } else {
                                        detailRow.classList.remove('hidden');
                                    }
                                }
                            }
                            
                            // Only show resource row if it has visible controls AND matches search
                            const rowSearchMatch = searchText === '' || rowSearchable.includes(searchText);
                            const rowShouldShow = visibleControlCount > 0 && rowSearchMatch;
                            
                            if (rowShouldShow) {
                                hasMatchingResource = true;
                                row.classList.remove('hidden');
                                visibleResourceCount++;
                                visibleCount++;
                            } else {
                                row.classList.add('hidden');
                                row.classList.remove('expanded');
                                // Hide associated detail row
                                if (resourceKey) {
                                    const detailRow = document.querySelector('.resource-detail-row[data-resource-key="' + resourceKey + '"]');
                                    if (detailRow) {
                                        detailRow.classList.add('hidden');
                                    }
                                }
                            }
                        });
                        
                        // Show/hide subscription box based on whether it has matching resources
                        if (subscriptionMatch && searchMatch && hasMatchingResource) {
                            box.style.display = 'block';
                        } else {
                            box.style.display = 'none';
                        }
                    });
                    
                    // Filter category boxes (Failed Controls by Category)
                    categoryBoxes.forEach(box => {
                        const boxSeverity = box.getAttribute('data-severity-lower') || '';
                        const boxCategory = box.getAttribute('data-category-lower') || '';
                        const searchableText = box.getAttribute('data-searchable') || '';
                        
                        const severityMatch = selectedSeverity === 'all' || boxSeverity === selectedSeverity;
                        const categoryMatch = selectedCategory === 'all' || boxCategory === selectedCategory;
                        const searchMatch = searchText === '' || searchableText.includes(searchText);
                        
                        // Check if any control rows inside match filters
                        const controlRowsInBox = box.querySelectorAll('.control-row');
                        let hasMatchingControl = false;
                        controlRowsInBox.forEach(row => {
                            const rowSeverity = row.getAttribute('data-severity-lower') || '';
                            const rowCategory = row.getAttribute('data-category-lower') || '';
                            const rowFrameworks = row.getAttribute('data-frameworks') || '';
                            const rowSearchable = row.getAttribute('data-searchable') || '';
                            
                            const rowSeverityMatch = selectedSeverity === 'all' || rowSeverity === selectedSeverity;
                            const rowCategoryMatch = selectedCategory === 'all' || rowCategory === selectedCategory;
                            const rowFrameworkMatch = selectedFramework === 'all' || rowFrameworks.includes(selectedFramework);
                            const rowSearchMatch = searchText === '' || rowSearchable.includes(searchText);
                            
                            if (rowSeverityMatch && rowCategoryMatch && rowFrameworkMatch && rowSearchMatch) {
                                hasMatchingControl = true;
                            }
                        });
                        
                        if (severityMatch && categoryMatch && searchMatch && hasMatchingControl) {
                            box.style.display = 'block';
                            // Filter control rows inside this category box
                            controlRowsInBox.forEach(row => {
                                const rowSeverity = row.getAttribute('data-severity-lower') || '';
                                const rowCategory = row.getAttribute('data-category-lower') || '';
                                const rowFrameworks = row.getAttribute('data-frameworks') || '';
                                const rowSearchable = row.getAttribute('data-searchable') || '';
                                
                                const rowSeverityMatch = selectedSeverity === 'all' || rowSeverity === selectedSeverity;
                                const rowCategoryMatch = selectedCategory === 'all' || rowCategory === selectedCategory;
                                const rowFrameworkMatch = selectedFramework === 'all' || rowFrameworks.includes(selectedFramework);
                                const rowSearchMatch = searchText === '' || rowSearchable.includes(searchText);
                                
                                if (rowSeverityMatch && rowCategoryMatch && rowFrameworkMatch && rowSearchMatch) {
                                    row.classList.remove('hidden');
                                    visibleCount++;
                                    // Keep resources row collapsed - only expand on click
                                    // But filter the individual resource rows inside
                                    const controlKey = row.getAttribute('data-control-key');
                                    if (controlKey && searchText !== '') {
                                        const resourcesRow = document.querySelector('.control-resources-row[data-control-key="' + controlKey + '"]');
                                        if (resourcesRow) {
                                            const resourceDetailRows = resourcesRow.querySelectorAll('.resource-detail-control-row');
                                            resourceDetailRows.forEach(resourceRow => {
                                                const resourceSearchable = resourceRow.getAttribute('data-searchable') || '';
                                                const resourceSearchMatch = resourceSearchable.includes(searchText);
                                                if (resourceSearchMatch) {
                                                    resourceRow.classList.remove('hidden');
                                                } else {
                                                    resourceRow.classList.add('hidden');
                                                    // Hide associated remediation row
                                                    const resourceDetailKey = resourceRow.getAttribute('data-resource-detail-key');
                                                    if (resourceDetailKey) {
                                                        const remediationRow = document.querySelector('.remediation-row[data-parent-resource-detail-key="' + resourceDetailKey + '"]');
                                                        if (remediationRow) {
                                                            remediationRow.classList.add('hidden');
                                                        }
                                                    }
                                                }
                                            });
                                        }
                                    } else if (controlKey) {
                                        // No search text - show all resource rows
                                        const resourcesRow = document.querySelector('.control-resources-row[data-control-key="' + controlKey + '"]');
                                        if (resourcesRow) {
                                            const resourceDetailRows = resourcesRow.querySelectorAll('.resource-detail-control-row');
                                            resourceDetailRows.forEach(resourceRow => {
                                                resourceRow.classList.remove('hidden');
                                            });
                                        }
                                    }
                                } else {
                                    row.classList.add('hidden');
                                    // Also hide associated resources row when filtering
                                    const controlKey = row.getAttribute('data-control-key');
                                    if (controlKey) {
                                        const resourcesRow = document.querySelector('.control-resources-row[data-control-key="' + controlKey + '"]');
                                        if (resourcesRow) {
                                            resourcesRow.classList.add('hidden');
                                        }
                                    }
                                    // Collapse the control row
                                    row.classList.remove('expanded');
                                }
                            });
                        } else {
                            box.style.display = 'none';
                        }
                    });
                    
                    // Update result count
                    resultCount.textContent = 'Showing ' + visibleCount + ' items';
                }
                
                function clearFilters() {
                    severityFilter.value = 'all';
                    categoryFilter.value = 'all';
                    frameworkFilter.value = 'all';
                    subscriptionFilter.value = 'all';
                    searchFilter.value = '';
                    updateFilters();
                }
                
                // Event listeners
                severityFilter.addEventListener('change', updateFilters);
                categoryFilter.addEventListener('change', updateFilters);
                frameworkFilter.addEventListener('change', updateFilters);
                subscriptionFilter.addEventListener('change', updateFilters);
                searchFilter.addEventListener('input', updateFilters);
                clearFiltersBtn.addEventListener('click', clearFilters);
                
                // Make summary cards clickable to filter by severity
                const summaryCards = document.querySelectorAll('.summary-card[data-severity]');
                summaryCards.forEach(card => {
                    card.style.cursor = 'pointer';
                    card.addEventListener('click', function() {
                        const severity = this.getAttribute('data-severity');
                        if (severity) {
                            severityFilter.value = severity;
                            updateFilters();
                            // Scroll to filters section
                            const filtersSection = document.querySelector('h2');
                            if (filtersSection) {
                                filtersSection.scrollIntoView({ behavior: 'smooth', block: 'start' });
                            }
                        }
                    });
                });
                
                // Initialize - all rows visible initially
                updateFilters();
                console.log('Filters initialized successfully');
                
                // Subscription expand/collapse handlers
                const subscriptionHeaders = document.querySelectorAll('.subscription-header:not(.category-header)');
                subscriptionHeaders.forEach(header => {
                    header.addEventListener('click', function() {
                        const subscriptionId = this.getAttribute('data-subscription-id');
                        const content = document.getElementById(subscriptionId);
                        if (content) {
                            const isHidden = content.style.display === 'none' || content.style.display === '';
                            content.style.display = isHidden ? 'block' : 'none';
                            this.classList.toggle('collapsed', !isHidden);
                        }
                    });
                });
                
                // Ensure deprecated-components header is always clickable and visible
                const deprecatedHeader = document.querySelector('[data-subscription-id="deprecated-components"]');
                if (deprecatedHeader) {
                    deprecatedHeader.style.display = 'flex';
                    deprecatedHeader.style.cursor = 'pointer';
                    const deprecatedBox = deprecatedHeader.closest('.subscription-box');
                    if (deprecatedBox) {
                        deprecatedBox.style.display = 'block';
                        deprecatedBox.style.visibility = 'visible';
                        deprecatedBox.style.opacity = '1';
                    }
                }
                
                // Also ensure deprecated-components box is excluded from filter hiding
                const deprecatedBoxElement = document.querySelector('.subscription-box [data-subscription-id="deprecated-components"]')?.closest('.subscription-box');
                if (deprecatedBoxElement) {
                    deprecatedBoxElement.setAttribute('data-always-visible', 'true');
                }
                
                // Category expand/collapse handlers
                const categoryHeaders = document.querySelectorAll('.category-header');
                categoryHeaders.forEach(header => {
                    header.addEventListener('click', function() {
                        const categoryId = this.getAttribute('data-category-id');
                        const content = document.getElementById(categoryId);
                        if (content) {
                            const isHidden = content.style.display === 'none';
                            content.style.display = isHidden ? 'block' : 'none';
                            this.classList.toggle('collapsed', !isHidden);
                        }
                    });
                });
                
                // Resource row click handlers
                resourceRows.forEach(row => {
                    row.addEventListener('click', function() {
                        const resourceKey = this.getAttribute('data-resource-key');
                        const detailRow = document.querySelector('.resource-detail-row[data-resource-key="' + resourceKey + '"]');
                        if (detailRow) {
                            detailRow.classList.toggle('hidden');
                            this.classList.toggle('expanded');
                        }
                    });
                });
                
                // Control row click handlers (Category & Control table) - expand/collapse resources
                controlRows.forEach(row => {
                    row.addEventListener('click', function() {
                        const controlKey = this.getAttribute('data-control-key');
                        if (controlKey) {
                            const resourcesRow = document.querySelector('.control-resources-row[data-control-key="' + controlKey + '"]');
                            if (resourcesRow) {
                                resourcesRow.classList.toggle('hidden');
                                this.classList.toggle('expanded');
                            }
                        }
                    });
                });
                
                // Control detail row click handlers (Subscription Details table) - expand/collapse remediation
                const controlDetailRows = document.querySelectorAll('.control-detail-row');
                controlDetailRows.forEach(row => {
                    row.addEventListener('click', function() {
                        const controlDetailKey = this.getAttribute('data-control-detail-key');
                        const remediationRow = document.querySelector('.remediation-row[data-parent-control-detail-key="' + controlDetailKey + '"]');
                        if (remediationRow) {
                            remediationRow.classList.toggle('hidden');
                            this.classList.toggle('expanded');
                        }
                    });
                });
                
                // Resource detail control row click handlers (Failed Controls by Category table) - expand/collapse remediation
                const resourceDetailControlRows = document.querySelectorAll('.resource-detail-control-row');
                resourceDetailControlRows.forEach(row => {
                    row.addEventListener('click', function() {
                        const resourceDetailKey = this.getAttribute('data-resource-detail-key');
                        const remediationRow = document.querySelector('.remediation-row[data-parent-resource-detail-key="' + resourceDetailKey + '"]');
                        if (remediationRow) {
                            remediationRow.classList.toggle('hidden');
                            this.classList.toggle('expanded');
                        }
                    });
                });
            }
            
            // Run when DOM is ready
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', initFilters);
            } else {
                // DOM already loaded
                initFilters();
            }
        })();
    </script>
</body>
</html>
"@
        
        # Write HTML to file
        [System.IO.File]::WriteAllText($OutputPath, $html, [System.Text.Encoding]::UTF8)
        
        Write-Host "[OK] HTML report generated: $OutputPath" -ForegroundColor Green
        return $OutputPath
    }
    catch {
        Write-Error "Failed to generate HTML report: $_"
        throw
    }
}
