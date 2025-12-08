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
    $eolFindings = $findings | Where-Object { $_.EOLDate -and $_.Status -eq 'FAIL' }
    
    # Create output directory if needed
    $outputDir = Split-Path -Parent $OutputPath
    if ($outputDir -and -not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    
    # Copy assets if Templates directory exists
    $assetsDir = Join-Path (Split-Path -Parent $OutputPath) "assets"
    if (Test-Path "Templates\assets") {
        if (-not (Test-Path $assetsDir)) {
            New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null
        }
        Copy-Item -Path "Templates\assets\*" -Destination $assetsDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    # Read CSS file content
    $cssContent = ""
    $cssPath = Join-Path $assetsDir "style.css"
    if (Test-Path $cssPath) {
        $cssContent = Get-Content $cssPath -Raw -ErrorAction SilentlyContinue
    }
    elseif (Test-Path "Templates\assets\style.css") {
        $cssContent = Get-Content "Templates\assets\style.css" -Raw -ErrorAction SilentlyContinue
    }
    
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
$cssContent

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

.findings-table {
    width: 100%;
    border-collapse: collapse;
    margin-top: 1rem;
}

.findings-table thead {
    background-color: var(--bg);
    position: sticky;
    top: 0;
    z-index: 10;
}

.findings-table th {
    padding: 0.75rem;
    text-align: left;
    font-weight: 600;
    color: var(--text);
    border-bottom: 2px solid var(--border);
}

.findings-table td {
    padding: 0.75rem;
    border-bottom: 1px solid var(--border);
}

.finding-row {
    transition: opacity 0.2s, transform 0.2s;
}

.finding-row.hidden {
    display: none;
}

.finding-row:not(.hidden) {
    animation: fadeIn 0.3s ease-in;
}

.finding-row {
    cursor: pointer;
}

.finding-row:hover {
    background-color: var(--bg);
}

.detail-row {
    background-color: var(--bg);
}

.detail-row.hidden {
    display: none;
}

.detail-content {
    padding: 1rem;
}

.detail-section {
    margin-bottom: 1rem;
}

.detail-section h4 {
    margin: 0 0 0.5rem 0;
    color: var(--pri-600);
    font-size: 0.9rem;
    font-weight: 600;
}

.detail-section p {
    margin: 0;
    color: var(--text-muted);
    line-height: 1.6;
}

.detail-section pre {
    background-color: var(--surface);
    padding: 0.75rem;
    border-radius: var(--radius-sm);
    border: 1px solid var(--border);
    overflow-x: auto;
    margin: 0;
}

.detail-section code {
    font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
    font-size: 0.85rem;
    color: var(--text);
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

/* Pagination Controls */
.pagination-controls {
    display: flex;
    justify-content: center;
    align-items: center;
    gap: 0.5rem;
    margin: 1rem 0;
    padding: 1rem;
}

.pagination-btn {
    padding: 0.5rem 1rem;
    background-color: var(--surface);
    color: var(--text);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    cursor: pointer;
    font-size: 0.9rem;
    transition: all 0.2s;
}

.pagination-btn:hover:not(:disabled) {
    background-color: var(--pri-600);
    color: white;
    border-color: var(--pri-600);
}

.pagination-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
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
    
    .findings-table {
        font-size: 0.85rem;
    }
    
    .findings-table th,
    .findings-table td {
        padding: 0.5rem;
    }
}
    </style>
</head>
<body>
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
        
        # EOL/Deprecated Components Alert
        if ($eolFindings.Count -gt 0) {
            $html += @"
        <h2>⚠ Deprecated Components Requiring Action</h2>
        <div class="alert-box warning">
            <h3>Deprecated Components Found</h3>
            <table>
                <thead>
                    <tr>
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
                $html += @"
                    <tr>
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
        
        # Detailed Findings Table with Filters - Always show filters, even if no failures
        $html += @"
        <h2>All Findings</h2>
        
        <!-- Filter Controls -->
        <div class="filter-controls">
            <div class="filter-group">
                <label for="searchFilter">Search:</label>
                <input type="text" id="searchFilter" class="filter-input" placeholder="Search findings...">
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
                <span id="resultCount" class="result-count">Showing $($failedFindings.Count) of $($failedFindings.Count) findings</span>
            </div>
        </div>
        
        <!-- Pagination Controls -->
        <div id="paginationControls" class="pagination-controls" style="display: none;">
            <button id="prevPage" class="pagination-btn">Previous</button>
            <div id="pageNumbers" class="page-numbers"></div>
            <button id="nextPage" class="pagination-btn">Next</button>
        </div>
        
        <table id="findingsTable" class="findings-table">
            <thead>
                <tr>
                    <th>Subscription</th>
                    <th>Resource Group</th>
                    <th>Resource</th>
                    <th>Category</th>
                    <th>Control ID</th>
                    <th>Control</th>
                    <th>Severity</th>
                    <th>Status</th>
                    <th>Current Value</th>
                    <th>Expected Value</th>
                </tr>
            </thead>
            <tbody>
"@
        if ($failedFindings.Count -gt 0) {
            foreach ($finding in $failedFindings) {
                $severityClass = switch ($finding.Severity) {
                    "Critical" { "status-badge critical" }
                    "High" { "status-badge high" }
                    "Medium" { "status-badge medium" }
                    "Low" { "status-badge low" }
                    default { "" }
                }
                $statusClass = if ($finding.Status -eq "PASS") { "status-ok" } else { "status-fail" }
                $categoryLower = ($finding.Category -replace '\s+', '-').ToLower()
                $severityLower = $finding.Severity.ToLower()
                $searchableText = "$($finding.SubscriptionName) $($finding.ResourceGroup) $($finding.ResourceName) $($finding.Category) $($finding.ControlId) $($finding.ControlName) $($finding.Severity) $($finding.CurrentValue) $($finding.ExpectedValue)".ToLower()
                $subscriptionLower = $finding.SubscriptionName.ToLower()
                $remediationSteps = if ($finding.RemediationSteps) { Encode-Html $finding.RemediationSteps } else { "No remediation steps provided." }
                $remediationCommand = if ($finding.RemediationCommand) { Encode-Html $finding.RemediationCommand } else { "N/A" }
                $note = if ($finding.Note) { Encode-Html $finding.Note } else { "" }
                $cisLevel = if ($finding.CisLevel) { Encode-Html $finding.CisLevel } else { "N/A" }
                $html += @"
                <tr class="finding-row" 
                    data-category="$(Encode-Html $finding.Category)" 
                    data-severity="$(Encode-Html $finding.Severity)" 
                    data-subscription="$(Encode-Html $finding.SubscriptionName)"
                    data-category-lower="$categoryLower" 
                    data-severity-lower="$severityLower"
                    data-subscription-lower="$subscriptionLower"
                    data-searchable="$searchableText">
                    <td>$(Encode-Html $finding.SubscriptionName)</td>
                    <td>$(Encode-Html $finding.ResourceGroup)</td>
                    <td>$(Encode-Html $finding.ResourceName)</td>
                    <td>$(Encode-Html $finding.Category)</td>
                    <td>$(Encode-Html $finding.ControlId)</td>
                    <td>$(Encode-Html $finding.ControlName)</td>
                    <td><span class="$severityClass">$(Encode-Html $finding.Severity)</span></td>
                    <td class="$statusClass">$(Encode-Html $finding.Status)</td>
                    <td>$(Encode-Html $finding.CurrentValue)</td>
                    <td>$(Encode-Html $finding.ExpectedValue)</td>
                </tr>
                <tr class="detail-row hidden" data-parent-row>
                    <td colspan="10">
                        <div class="detail-content">
                            <div class="detail-section">
                                <h4>Description</h4>
                                <p>$remediationSteps</p>
                            </div>
                            <div class="detail-section">
                                <h4>Remediation Command</h4>
                                <pre><code>$remediationCommand</code></pre>
                            </div>
                            $(if ($note) { @"
                            <div class="detail-section">
                                <h4>Note</h4>
                                <p>$note</p>
                            </div>
"@ })
                            <div class="detail-section">
                                <h4>Additional Information</h4>
                                <p><strong>CIS Level:</strong> $cisLevel | <strong>Resource ID:</strong> $(Encode-Html $finding.ResourceId)</p>
                            </div>
                        </div>
                    </td>
                </tr>
"@
            }
        }
        else {
            $html += @"
                <tr>
                    <td colspan="10" style="text-align: center; padding: 2rem;">
                        <p>No failed findings found. All checks passed!</p>
                    </td>
                </tr>
"@
        }
        $html += @"
            </tbody>
        </table>
"@
        
        # Subscription Details
        if ($AuditResult.SubscriptionsScanned.Count -gt 0) {
            $html += @"
        <h2>Subscription Details</h2>
"@
            foreach ($subId in $AuditResult.SubscriptionsScanned) {
                $subFindings = $failedFindings | Where-Object { $_.SubscriptionId -eq $subId }
                $subName = ($subFindings | Select-Object -First 1 -ExpandProperty SubscriptionName)
                if (-not $subName) {
                    $subName = $subId
                }
                
                # Group findings by resource (ResourceName + ResourceGroup)
                $resourceGroups = $subFindings | Group-Object -Property @{Expression={$_.ResourceName + '|' + $_.ResourceGroup}} | Sort-Object Name
                
                $html += @"
        <div class="subscription-box">
            <div class="subscription-header collapsed" data-subscription-id="sub-$(Encode-Html $subId)" style="cursor: pointer;">
                <span class="expand-icon"></span>
                <h3>$(Encode-Html $subName) ($($subFindings.Count) findings)</h3>
            </div>
            <div class="subscription-content" id="sub-$(Encode-Html $subId)" style="display: none;">
"@
                if ($subFindings.Count -gt 0) {
                    $html += @"
                <table class="resource-summary-table">
                    <thead>
                        <tr>
                            <th>Resource Group</th>
                            <th>Resource</th>
                            <th>Category</th>
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
                        
                        # Count issues
                        $issuesCount = $resourceFindings.Count
                        
                        # Get highest severity (Critical > High > Medium > Low)
                        $severities = $resourceFindings | Select-Object -ExpandProperty Severity
                        $highestSeverity = "Low"
                        if ($severities -contains "Critical") { $highestSeverity = "Critical" }
                        elseif ($severities -contains "High") { $highestSeverity = "High" }
                        elseif ($severities -contains "Medium") { $highestSeverity = "Medium" }
                        
                        $severityClass = switch ($highestSeverity) {
                            "Critical" { "status-badge critical" }
                            "High" { "status-badge high" }
                            "Medium" { "status-badge medium" }
                            "Low" { "status-badge low" }
                            default { "" }
                        }
                        
                        $html += @"
                        <tr class="resource-row" data-resource-key="$(Encode-Html $resourceKey)" style="cursor: pointer;">
                            <td>$(Encode-Html $resourceGroupName)</td>
                            <td>$(Encode-Html $resourceName)</td>
                            <td>$(Encode-Html $primaryCategory)</td>
                            <td>$issuesCount</td>
                            <td><span class="$severityClass">$(Encode-Html $highestSeverity)</span></td>
                        </tr>
                        <tr class="resource-detail-row hidden" data-resource-key="$(Encode-Html $resourceKey)">
                            <td colspan="5">
                                <table class="resource-issues-table">
                                    <thead>
                                        <tr>
                                            <th>Control</th>
                                            <th>Severity</th>
                                            <th>Status</th>
                                            <th>Current Value</th>
                                            <th>Expected Value</th>
                                        </tr>
                                    </thead>
                                    <tbody>
"@
                        foreach ($finding in $resourceFindings) {
                            $findingSeverityClass = switch ($finding.Severity) {
                                "Critical" { "status-badge critical" }
                                "High" { "status-badge high" }
                                "Medium" { "status-badge medium" }
                                "Low" { "status-badge low" }
                                default { "" }
                            }
                            $statusClass = if ($finding.Status -eq "PASS") { "status-ok" } else { "status-fail" }
                            $html += @"
                                        <tr>
                                            <td>$(Encode-Html $finding.ControlName)</td>
                                            <td><span class="$findingSeverityClass">$(Encode-Html $finding.Severity)</span></td>
                                            <td class="$statusClass">$(Encode-Html $finding.Status)</td>
                                            <td>$(Encode-Html $finding.CurrentValue)</td>
                                            <td>$(Encode-Html $finding.ExpectedValue)</td>
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
        
        # Footer
        $html += @"
        <div class="footer">
            <p>Report generated: $($AuditResult.ScanEndTime.ToString('yyyy-MM-dd HH:mm:ss')) | Tool Version: $($AuditResult.ToolVersion)</p>
        </div>
    </div>
    <script>
        // Interactive filtering and row expansion
        (function() {
            // Wait for DOM to be fully loaded
            function initFilters() {
                const severityFilter = document.getElementById('severityFilter');
                const categoryFilter = document.getElementById('categoryFilter');
                const subscriptionFilter = document.getElementById('subscriptionFilter');
                const searchFilter = document.getElementById('searchFilter');
                const clearFiltersBtn = document.getElementById('clearFilters');
                const resultCount = document.getElementById('resultCount');
                const tableRows = document.querySelectorAll('.finding-row');
                const detailRows = document.querySelectorAll('.detail-row');
                const totalCount = tableRows.length;
                const itemsPerPage = 25;
                let currentPage = 1;
                
                // Pagination elements
                const paginationControls = document.getElementById('paginationControls');
                const prevPageBtn = document.getElementById('prevPage');
                const nextPageBtn = document.getElementById('nextPage');
                const pageNumbers = document.getElementById('pageNumbers');
                
                console.log('Initializing filters...', {
                    severityFilter: !!severityFilter,
                    categoryFilter: !!categoryFilter,
                    subscriptionFilter: !!subscriptionFilter,
                    searchFilter: !!searchFilter,
                    clearFiltersBtn: !!clearFiltersBtn,
                    resultCount: !!resultCount,
                    tableRows: tableRows.length,
                    detailRows: detailRows.length
                });
                
                if (!severityFilter || !categoryFilter || !subscriptionFilter || !searchFilter || !clearFiltersBtn || !resultCount) {
                    console.error('Filter elements not found:', {
                        severityFilter: !!severityFilter,
                        categoryFilter: !!categoryFilter,
                        subscriptionFilter: !!subscriptionFilter,
                        searchFilter: !!searchFilter,
                        clearFiltersBtn: !!clearFiltersBtn,
                        resultCount: !!resultCount
                    });
                    return;
                }
                
                if (tableRows.length === 0) {
                    console.warn('No table rows found');
                    return;
                }
                
                let visibleRowsArray = [];
                
                function updateFilters() {
                    const selectedSeverity = severityFilter.value.toLowerCase();
                    const selectedCategory = categoryFilter.value.toLowerCase();
                    const selectedSubscription = subscriptionFilter.value.toLowerCase();
                    const searchText = searchFilter.value.toLowerCase().trim();
                    
                    // First pass: determine which rows match filters
                    visibleRowsArray = [];
                    tableRows.forEach((row, index) => {
                        const rowSeverity = row.getAttribute('data-severity-lower');
                        const rowCategory = row.getAttribute('data-category-lower');
                        const rowSubscription = row.getAttribute('data-subscription-lower');
                        const searchableText = row.getAttribute('data-searchable') || '';
                        
                        const severityMatch = selectedSeverity === 'all' || rowSeverity === selectedSeverity;
                        const categoryMatch = selectedCategory === 'all' || rowCategory === selectedCategory;
                        const subscriptionMatch = selectedSubscription === 'all' || rowSubscription === selectedSubscription;
                        const searchMatch = searchText === '' || searchableText.includes(searchText);
                        
                        if (severityMatch && categoryMatch && subscriptionMatch && searchMatch) {
                            visibleRowsArray.push({ row: row, index: index });
                        }
                    });
                    
                    // Reset to page 1 when filters change
                    currentPage = 1;
                    updatePagination(visibleRowsArray);
                    updatePageDisplay(visibleRowsArray);
                }
                
                function updatePagination(visibleRows) {
                    const totalPages = Math.ceil(visibleRows.length / itemsPerPage);
                    
                    if (totalPages <= 1) {
                        paginationControls.style.display = 'none';
                        return;
                    }
                    
                    paginationControls.style.display = 'flex';
                    
                    // Update prev/next buttons
                    prevPageBtn.disabled = currentPage === 1;
                    nextPageBtn.disabled = currentPage === totalPages;
                    
                    // Update page numbers
                    pageNumbers.innerHTML = '';
                    const maxPagesToShow = 10;
                    let startPage = Math.max(1, currentPage - Math.floor(maxPagesToShow / 2));
                    let endPage = Math.min(totalPages, startPage + maxPagesToShow - 1);
                    
                    if (endPage - startPage < maxPagesToShow - 1) {
                        startPage = Math.max(1, endPage - maxPagesToShow + 1);
                    }
                    
                    if (startPage > 1) {
                        const firstBtn = document.createElement('button');
                        firstBtn.className = 'page-number';
                        firstBtn.textContent = '1';
                        firstBtn.addEventListener('click', () => goToPage(1, visibleRows));
                        pageNumbers.appendChild(firstBtn);
                        
                        if (startPage > 2) {
                            const ellipsis = document.createElement('span');
                            ellipsis.textContent = '...';
                            ellipsis.style.padding = '0 0.5rem';
                            pageNumbers.appendChild(ellipsis);
                        }
                    }
                    
                    for (let i = startPage; i <= endPage; i++) {
                        const pageBtn = document.createElement('button');
                        pageBtn.className = 'page-number' + (i === currentPage ? ' active' : '');
                        pageBtn.textContent = i;
                        pageBtn.addEventListener('click', () => goToPage(i, visibleRows));
                        pageNumbers.appendChild(pageBtn);
                    }
                    
                    if (endPage < totalPages) {
                        if (endPage < totalPages - 1) {
                            const ellipsis = document.createElement('span');
                            ellipsis.textContent = '...';
                            ellipsis.style.padding = '0 0.5rem';
                            pageNumbers.appendChild(ellipsis);
                        }
                        
                        const lastBtn = document.createElement('button');
                        lastBtn.className = 'page-number';
                        lastBtn.textContent = totalPages;
                        lastBtn.addEventListener('click', () => goToPage(totalPages, visibleRows));
                        pageNumbers.appendChild(lastBtn);
                    }
                }
                
                function updatePageDisplay(visibleRows) {
                    const totalPages = Math.ceil(visibleRows.length / itemsPerPage);
                    const startIndex = (currentPage - 1) * itemsPerPage;
                    const endIndex = Math.min(startIndex + itemsPerPage, visibleRows.length);
                    
                    // Hide all rows first
                    tableRows.forEach((row, index) => {
                        row.classList.add('hidden');
                        if (detailRows[index]) {
                            detailRows[index].classList.add('hidden');
                        }
                    });
                    
                    // Show rows for current page
                    for (let i = startIndex; i < endIndex; i++) {
                        if (visibleRows[i]) {
                            visibleRows[i].row.classList.remove('hidden');
                        }
                    }
                    
                    // Update result count
                    if (visibleRows.length > 0) {
                        resultCount.textContent = 'Showing ' + (startIndex + 1) + '-' + endIndex + ' of ' + visibleRows.length + ' findings';
                    } else {
                        resultCount.textContent = 'Showing 0 of 0 findings';
                    }
                }
                
                function goToPage(page, visibleRows) {
                    currentPage = page;
                    updatePagination(visibleRows);
                    updatePageDisplay(visibleRows);
                    
                    // Scroll to top of table
                    const findingsTable = document.getElementById('findingsTable');
                    if (findingsTable) {
                        findingsTable.scrollIntoView({ behavior: 'smooth', block: 'start' });
                    }
                }
                
                function clearFilters() {
                    severityFilter.value = 'all';
                    categoryFilter.value = 'all';
                    subscriptionFilter.value = 'all';
                    searchFilter.value = '';
                    updateFilters();
                }
                
                // Row click to expand/collapse details
                tableRows.forEach((row, index) => {
                    row.style.cursor = 'pointer';
                    row.addEventListener('click', function(e) {
                        // Don't trigger if clicking on a link or button
                        if (e.target.tagName === 'A' || e.target.tagName === 'BUTTON') {
                            return;
                        }
                        const detailRow = detailRows[index];
                        if (detailRow) {
                            detailRow.classList.toggle('hidden');
                            row.classList.toggle('expanded');
                        }
                    });
                });
                
                // Event listeners
                severityFilter.addEventListener('change', updateFilters);
                categoryFilter.addEventListener('change', updateFilters);
                subscriptionFilter.addEventListener('change', updateFilters);
                searchFilter.addEventListener('input', updateFilters);
                clearFiltersBtn.addEventListener('click', clearFilters);
                
                // Pagination event listeners
                prevPageBtn.addEventListener('click', () => {
                    if (currentPage > 1) {
                        goToPage(currentPage - 1, visibleRowsArray);
                    }
                });
                
                nextPageBtn.addEventListener('click', () => {
                    const totalPages = Math.ceil(visibleRowsArray.length / itemsPerPage);
                    if (currentPage < totalPages) {
                        goToPage(currentPage + 1, visibleRowsArray);
                    }
                });
                
                // Make summary cards clickable to filter by severity
                const summaryCards = document.querySelectorAll('.summary-card[data-severity]');
                summaryCards.forEach(card => {
                    card.style.cursor = 'pointer';
                    card.addEventListener('click', function() {
                        const severity = this.getAttribute('data-severity');
                        if (severity) {
                            // Set filter value to match dropdown option values (Capitalized)
                            severityFilter.value = severity;
                            updateFilters();
                            // Scroll to findings table smoothly
                            const findingsTable = document.getElementById('findingsTable');
                            if (findingsTable) {
                                findingsTable.scrollIntoView({ behavior: 'smooth', block: 'start' });
                            }
                        }
                    });
                });
                
                // Initialize - all rows visible initially
                visibleRowsArray = Array.from(tableRows).map((row, index) => ({ row: row, index: index }));
                updateFilters();
                console.log('Filters and pagination initialized successfully');
                
                // Subscription expand/collapse handlers
                const subscriptionHeaders = document.querySelectorAll('.subscription-header');
                subscriptionHeaders.forEach(header => {
                    header.addEventListener('click', function() {
                        const subscriptionId = this.getAttribute('data-subscription-id');
                        const content = document.getElementById(subscriptionId);
                        if (content) {
                            const isHidden = content.style.display === 'none';
                            content.style.display = isHidden ? 'block' : 'none';
                            this.classList.toggle('collapsed', !isHidden);
                        }
                    });
                });
                
                // Resource row click handlers
                const resourceRows = document.querySelectorAll('.resource-row');
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
