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
    
    # Encode-Html is now imported from Private/Helpers/Encode-Html.ps1
    
    # Prepare data
    $findings = if ($AuditResult.Findings) { @($AuditResult.Findings) } else { @() }
    $failedFindings = @($findings | Where-Object { $_.Status -eq 'FAIL' })
    
    # Create output directory if needed
    $outputDir = Split-Path -Parent $OutputPath
    if ($outputDir -and -not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    
    # Generate HTML report
    try {
        # Calculate summary values - count FAIL findings by severity directly from findings
        # This ensures accuracy even if FindingsBySeverity object has issues
        # Note: $failedFindings already contains only FAIL status findings
        # Convert to array to ensure proper counting
        $failedArray = @($failedFindings)
        
        # Count by severity using helper function
        $severityCounts = Get-FindingsBySeverity -Findings $failedArray -StatusFilter "FAIL"
        $criticalValue = $severityCounts.Critical
        $highValue = $severityCounts.High
        $mediumValue = $severityCounts.Medium
        $lowValue = $severityCounts.Low
        
        Write-Verbose "Summary counts - Critical: $criticalValue, High: $highValue, Medium: $mediumValue, Low: $lowValue (Total failed: $($failedArray.Count))"
        
        $totalFindings = $findings.Count
        
        # Calculate compliance score
        if ($AuditResult.ComplianceScores) {
            $securityScore = [math]::Round($AuditResult.ComplianceScores.OverallScore, 1)
            $totalChecks = $AuditResult.ComplianceScores.TotalChecks
            $passedChecks = $AuditResult.ComplianceScores.PassedChecks
        } else {
            # Fallback to simple calculation if ComplianceScores not available
            $totalChecks = $findings.Count
            $passedChecks = @($findings | Where-Object { $_.Status -eq 'PASS' }).Count
            $securityScore = if ($totalChecks -gt 0) { [math]::Round(($passedChecks / $totalChecks) * 100, 1) } else { 0 }
        }
        
        # Deprecated components are now tracked on the dedicated EOL report, not on the Security page
        $deprecatedCount = 0
        $pastDueCount = 0
        
        # Build HTML
        $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Security Audit</title>
    <style type="text/css">
$(Get-ReportStylesheet -IncludeReportSpecific)
    </style>
</head>
<body>
$(Get-ReportNavigation -ActivePage "Security")
    
    <div class="container">
        <div class="page-header">
            <h1>Security Audit</h1>
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
            
            # Get subscription names for score cards
            $allSubscriptionNames = ($findings | Select-Object -ExpandProperty SubscriptionName -Unique | Sort-Object) -join "|"
            $l1SubscriptionNames = ($findings | Where-Object { $_.CisLevel -eq "L1" } | Select-Object -ExpandProperty SubscriptionName -Unique | Sort-Object) -join "|"
            $l2SubscriptionNames = ($findings | Where-Object { $_.CisLevel -eq "L2" } | Select-Object -ExpandProperty SubscriptionName -Unique | Sort-Object) -join "|"
            
            # Determine score color
            $scoreColor = if ($overallScore -ge 90) { "score-excellent" } 
                         elseif ($overallScore -ge 75) { "score-good" } 
                         elseif ($overallScore -ge 50) { "score-fair" } 
                         else { "score-poor" }
            
            $html += @"
        <div class="compliance-scores-section">
            <h3>Security Compliance Score</h3>
            <div class="score-grid">
                <div class="score-card overall-score $scoreColor" data-subscription="$allSubscriptionNames">
                    <div class="score-label">All Controls</div>
                    <div class="score-value">$overallScore%</div>
                    <div class="score-details">$passedChecks / $totalChecks checks passed</div>
                </div>
                <div class="score-card l1-score" data-subscription="$l1SubscriptionNames">
                    <div class="score-label">CIS Level 1 (L1) Controls</div>
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
                <div class="score-card l2-score $l2ScoreColor" data-subscription="$l2SubscriptionNames">
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
                    # Get subscription names for this category
                    $categorySubscriptionNames = ($findings | Where-Object { $_.Category -eq $category } | Select-Object -ExpandProperty SubscriptionName -Unique | Sort-Object) -join "|"
                    $html += @"
                <div class="category-score-card $catScoreColor" data-subscription="$categorySubscriptionNames">
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
        
        # Get unique categories for filter dropdowns
        # Use all findings, not just failed ones, to populate category filter
        $allCategories = ($findings | Select-Object -ExpandProperty Category -Unique | Sort-Object)
        $categories = if ($allCategories.Count -gt 0) { $allCategories } else { @() }
        
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
        # Add script using helper function
        $html += @"
    <script>
$(Get-ReportScript -ScriptType "SecurityReport")
    </script>
</body>
</html>
"@
        
        # Write HTML to file
        [System.IO.File]::WriteAllText($OutputPath, $html, [System.Text.Encoding]::UTF8)
        
        # Return metadata for Dashboard consumption
        # Note: Dashboard will calculate TotalFailedFindings by summing severity counts
        return @{
            OutputPath = $OutputPath
            SecurityScore = $securityScore
            TotalChecks = $totalChecks
            PassedChecks = $passedChecks
            CriticalCount = $criticalValue
            HighCount = $highValue
            MediumCount = $mediumValue
            LowCount = $lowValue
            DeprecatedCount = $deprecatedCount
            PastDueCount = $pastDueCount
        }
    }
    catch {
        Write-Error "Failed to generate HTML report: $_"
        throw
    }
}
