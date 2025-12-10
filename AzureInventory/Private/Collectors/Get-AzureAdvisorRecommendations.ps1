<#
.SYNOPSIS
    Generates a consolidated HTML report for Azure Advisor recommendations.

.DESCRIPTION
    Creates an interactive HTML report showing Azure Advisor recommendations
    grouped by recommendation type (not by resource), with expandable sections
    showing affected resources. This dramatically reduces report size when
    many resources have the same recommendation.

.PARAMETER AdvisorRecommendations
    Array of Advisor recommendation objects from Get-AzureAdvisorRecommendations.

.PARAMETER OutputPath
    Path for the HTML report output.

.PARAMETER TenantId
    Azure Tenant ID for display in report.

.OUTPUTS
    String path to the generated HTML report.
#>
function Export-AdvisorReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$AdvisorRecommendations,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        
        [string]$TenantId = "Unknown"
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    
    # Ensure AdvisorRecommendations is an array (handle null/empty cases)
    if ($null -eq $AdvisorRecommendations) {
        $AdvisorRecommendations = @()
    } else {
        $AdvisorRecommendations = @($AdvisorRecommendations)
    }
    
    Write-Verbose "Export-AdvisorReport: Processing $($AdvisorRecommendations.Count) recommendations"
    
    # Group recommendations by type
    $groupedRecs = Group-AdvisorRecommendations -Recommendations $AdvisorRecommendations
    
    # Calculate statistics
    $totalRecs = $groupedRecs.Count
    $totalResources = ($groupedRecs | Measure-Object -Property AffectedResourceCount -Sum).Sum
    if (-not $totalResources) { $totalResources = 0 }
    
    # Group by category
    $costRecs = @($groupedRecs | Where-Object { $_.Category -eq 'Cost' })
    $securityRecs = @($groupedRecs | Where-Object { $_.Category -eq 'Security' })
    $reliabilityRecs = @($groupedRecs | Where-Object { $_.Category -eq 'Reliability' -or $_.Category -eq 'HighAvailability' })
    $operationalRecs = @($groupedRecs | Where-Object { $_.Category -eq 'OperationalExcellence' })
    $performanceRecs = @($groupedRecs | Where-Object { $_.Category -eq 'Performance' })
    
    # Calculate total savings
    $totalSavings = ($costRecs | Where-Object { $_.TotalSavings } | Measure-Object -Property TotalSavings -Sum).Sum
    if (-not $totalSavings) { $totalSavings = 0 }
    $savingsCurrency = ($costRecs | Where-Object { $_.SavingsCurrency } | Select-Object -First 1).SavingsCurrency
    if (-not $savingsCurrency) { $savingsCurrency = "USD" }
    
    # Get unique subscriptions for filter
    $allSubscriptions = @($AdvisorRecommendations | Select-Object -ExpandProperty SubscriptionName -Unique | Sort-Object)
    
    # Encode-Html is now imported from Private/Helpers/Encode-Html.ps1
    
    # Start building HTML
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure Advisor Recommendations Report</title>
    <style>
        :root {
            --bg-primary: #0f0f1a;
            --bg-secondary: #1a1a2e;
            --bg-surface: #252542;
            --bg-hover: #2d2d4a;
            --bg-resource: #1e1e36;
            --text-primary: #e8e8e8;
            --text-secondary: #b8b8b8;
            --text-muted: #888;
            --accent-green: #00d26a;
            --accent-red: #ff6b6b;
            --accent-yellow: #feca57;
            --accent-blue: #54a0ff;
            --accent-purple: #9b59b6;
            --accent-orange: #ff9f43;
            --border-color: #3d3d5c;
        }
        
        * { box-sizing: border-box; margin: 0; padding: 0; }
        
        body {
            font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            line-height: 1.6;
        }
        
        .report-nav {
            background: var(--bg-secondary);
            padding: 15px 30px;
            display: flex;
            gap: 10px;
            align-items: center;
            border-bottom: 1px solid var(--border-color);
            position: sticky;
            top: 0;
            z-index: 100;
        }
        
        .nav-brand {
            font-weight: 600;
            font-size: 1.1rem;
            color: var(--accent-blue);
            margin-right: 30px;
        }
        
        .container {
            max-width: 1400px;
            margin: 0 auto;
            padding: 30px;
        }
        
        .page-header {
            margin-bottom: 30px;
        }
        
        .page-header h1 {
            font-size: 2rem;
            font-weight: 600;
            margin-bottom: 8px;
        }
        
        .page-header .subtitle {
            color: var(--text-muted);
            font-size: 0.9rem;
        }
        
        /* Summary Cards */
        .summary-cards {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
            gap: 16px;
            margin-bottom: 30px;
        }
        
        .summary-card {
            background: var(--bg-surface);
            padding: 20px;
            border-radius: 10px;
            text-align: center;
            border: 1px solid var(--border-color);
        }
        
        .summary-card .value {
            font-size: 1.8rem;
            font-weight: 700;
            line-height: 1.2;
        }
        
        .summary-card .label {
            color: var(--text-muted);
            font-size: 0.75rem;
            margin-top: 6px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        
        .summary-card.total .value { color: var(--accent-blue); }
        .summary-card.resources .value { color: var(--text-secondary); }
        .summary-card.cost .value { color: var(--accent-green); }
        .summary-card.security .value { color: var(--accent-red); }
        .summary-card.reliability .value { color: var(--accent-orange); }
        .summary-card.performance .value { color: var(--accent-purple); }
        .summary-card.savings .value { color: var(--accent-green); }
        
        /* Filter Section */
        .filter-section {
            background: var(--bg-surface);
            padding: 16px 20px;
            border-radius: 10px;
            margin-bottom: 24px;
            border: 1px solid var(--border-color);
            display: flex;
            gap: 20px;
            flex-wrap: wrap;
            align-items: center;
        }
        
        .filter-group {
            display: flex;
            align-items: center;
            gap: 8px;
        }
        
        .filter-group label {
            color: var(--text-muted);
            font-size: 0.85rem;
        }
        
        .filter-group input, .filter-group select {
            background: var(--bg-primary);
            border: 1px solid var(--border-color);
            color: var(--text-primary);
            padding: 8px 12px;
            border-radius: 6px;
            font-size: 0.9rem;
        }
        
        .filter-group input { width: 200px; }
        .filter-group select { min-width: 150px; }
        
        /* Category Sections */
        .category-section {
            background: var(--bg-surface);
            border-radius: 10px;
            margin-bottom: 16px;
            border: 1px solid var(--border-color);
            overflow: hidden;
        }
        
        .category-header {
            background: var(--bg-secondary);
            padding: 14px 20px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            cursor: pointer;
            transition: background 0.2s ease;
        }
        
        .category-header:hover {
            background: var(--bg-hover);
        }
        
        .category-header.collapsed + .category-content {
            display: none;
        }
        
        .category-title {
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 10px;
        }
        
        .category-icon {
            width: 28px;
            height: 28px;
            border-radius: 6px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 0.85rem;
            font-weight: 700;
        }
        
        .category-icon.cost { background: rgba(0, 210, 106, 0.2); color: var(--accent-green); }
        .category-icon.security { background: rgba(255, 107, 107, 0.2); color: var(--accent-red); }
        .category-icon.reliability { background: rgba(255, 159, 67, 0.2); color: var(--accent-orange); }
        .category-icon.operational { background: rgba(84, 160, 255, 0.2); color: var(--accent-blue); }
        .category-icon.performance { background: rgba(155, 89, 182, 0.2); color: var(--accent-purple); }
        
        .category-stats {
            display: flex;
            gap: 12px;
            font-size: 0.8rem;
        }
        
        .expand-icon {
            width: 0;
            height: 0;
            border-left: 5px solid var(--text-muted);
            border-top: 4px solid transparent;
            border-bottom: 4px solid transparent;
            transition: transform 0.2s;
            margin-right: 8px;
        }
        
        .category-header:not(.collapsed) .expand-icon {
            transform: rotate(90deg);
        }
        
        /* Impact Badges */
        .impact-badge {
            display: inline-block;
            padding: 3px 8px;
            border-radius: 4px;
            font-size: 0.75rem;
            font-weight: 500;
        }
        
        .impact-badge.high { background: rgba(255, 107, 107, 0.15); color: var(--accent-red); }
        .impact-badge.medium { background: rgba(254, 202, 87, 0.15); color: var(--accent-yellow); }
        .impact-badge.low { background: rgba(84, 160, 255, 0.15); color: var(--accent-blue); }
        
        /* Recommendation Cards */
        .rec-card {
            border-bottom: 1px solid var(--border-color);
            transition: background 0.2s;
        }
        
        .rec-card:last-child {
            border-bottom: none;
        }
        
        .rec-header {
            padding: 16px 20px;
            cursor: pointer;
            display: grid;
            grid-template-columns: 24px 1fr auto;
            gap: 12px;
            align-items: start;
        }
        
        .rec-header:hover {
            background: var(--bg-hover);
        }
        
        .rec-expand {
            width: 0;
            height: 0;
            border-left: 5px solid var(--text-muted);
            border-top: 4px solid transparent;
            border-bottom: 4px solid transparent;
            transition: transform 0.2s;
            margin-top: 6px;
        }
        
        .rec-card.expanded .rec-expand {
            transform: rotate(90deg);
        }
        
        .rec-main {
            min-width: 0;
        }
        
        .rec-problem {
            font-weight: 500;
            margin-bottom: 4px;
            color: var(--text-primary);
        }
        
        .rec-meta {
            display: flex;
            gap: 16px;
            flex-wrap: wrap;
            font-size: 0.85rem;
            color: var(--text-muted);
        }
        
        .rec-meta-item {
            display: flex;
            align-items: center;
            gap: 4px;
        }
        
        .rec-stats {
            display: flex;
            gap: 12px;
            align-items: center;
            flex-shrink: 0;
        }
        
        .resource-count {
            background: var(--bg-primary);
            padding: 4px 10px;
            border-radius: 12px;
            font-size: 0.8rem;
            color: var(--text-secondary);
        }
        
        .savings-badge {
            color: var(--accent-green);
            font-weight: 600;
            font-size: 0.9rem;
        }
        
        /* Recommendation Details */
        .rec-details {
            display: none;
            background: var(--bg-hover);
            padding: 0 20px 20px 56px;
        }
        
        .rec-card.expanded .rec-details {
            display: block;
        }
        
        .detail-section {
            margin-bottom: 20px;
        }
        
        .detail-section:last-child {
            margin-bottom: 0;
        }
        
        .detail-title {
            color: var(--accent-blue);
            font-weight: 600;
            font-size: 0.9rem;
            margin-bottom: 8px;
        }
        
        .detail-content {
            color: var(--text-secondary);
            font-size: 0.9rem;
            line-height: 1.6;
        }
        
        .detail-content a {
            color: var(--accent-blue);
            text-decoration: none;
        }
        
        .detail-content a:hover {
            text-decoration: underline;
        }
        
        /* Resources Table */
        .resources-section {
            margin-top: 20px;
            background: var(--bg-resource);
            border-radius: 8px;
            overflow: hidden;
        }
        
        .resources-header {
            padding: 12px 16px;
            background: var(--bg-secondary);
            cursor: pointer;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        
        .resources-header:hover {
            background: var(--bg-hover);
        }
        
        .resources-title {
            font-weight: 500;
            font-size: 0.9rem;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        
        .resources-table-wrapper {
            display: none;
            max-height: 400px;
            overflow-y: auto;
        }
        
        .resources-section.expanded .resources-table-wrapper {
            display: block;
        }
        
        .resources-table {
            width: 100%;
            border-collapse: collapse;
            font-size: 0.85rem;
        }
        
        .resources-table th {
            background: var(--bg-surface);
            padding: 10px 12px;
            text-align: left;
            font-weight: 600;
            color: var(--text-muted);
            text-transform: uppercase;
            font-size: 0.75rem;
            letter-spacing: 0.5px;
            position: sticky;
            top: 0;
        }
        
        .resources-table td {
            padding: 10px 12px;
            border-bottom: 1px solid var(--border-color);
            color: var(--text-secondary);
        }
        
        .resources-table tr:last-child td {
            border-bottom: none;
        }
        
        .resources-table tr:hover td {
            background: var(--bg-surface);
        }
        
        .resource-name {
            color: var(--text-primary);
            font-weight: 500;
        }
        
        /* No data */
        .no-data {
            text-align: center;
            padding: 60px 20px;
            color: var(--text-muted);
        }
        
        .no-data h2 {
            color: var(--accent-green);
            margin-bottom: 10px;
        }
        
        /* Scrollbar */
        ::-webkit-scrollbar {
            width: 8px;
            height: 8px;
        }
        
        ::-webkit-scrollbar-track {
            background: var(--bg-primary);
        }
        
        ::-webkit-scrollbar-thumb {
            background: var(--border-color);
            border-radius: 4px;
        }
        
        ::-webkit-scrollbar-thumb:hover {
            background: var(--text-muted);
        }
    </style>
</head>
<body>
    <nav class="report-nav">
        <span class="nav-brand">Azure Advisor Report</span>
        <span style="color: var(--text-muted); font-size: 0.85rem;">Generated: $timestamp | Tenant: $TenantId</span>
    </nav>
    
    <div class="container">
        <div class="page-header">
            <h1>Advisor Recommendations</h1>
            <p class="subtitle">Consolidated view - $totalRecs unique recommendations affecting $totalResources resources</p>
        </div>
        
        <div class="summary-cards">
            <div class="summary-card total">
                <div class="value">$totalRecs</div>
                <div class="label">Recommendations</div>
            </div>
            <div class="summary-card resources">
                <div class="value">$totalResources</div>
                <div class="label">Affected Resources</div>
            </div>
            <div class="summary-card cost">
                <div class="value">$($costRecs.Count)</div>
                <div class="label">Cost</div>
            </div>
            <div class="summary-card security">
                <div class="value">$($securityRecs.Count)</div>
                <div class="label">Security</div>
            </div>
            <div class="summary-card reliability">
                <div class="value">$($reliabilityRecs.Count)</div>
                <div class="label">Reliability</div>
            </div>
            <div class="summary-card performance">
                <div class="value">$($performanceRecs.Count)</div>
                <div class="label">Performance</div>
            </div>
            <div class="summary-card savings">
                <div class="value">$savingsCurrency $([math]::Round($totalSavings, 0))</div>
                <div class="label">Potential Savings/yr</div>
            </div>
        </div>
        
        <div class="filter-section">
            <div class="filter-group">
                <label>Search:</label>
                <input type="text" id="searchFilter" placeholder="Search recommendations...">
            </div>
            <div class="filter-group">
                <label>Impact:</label>
                <select id="impactFilter">
                    <option value="all">All Impacts</option>
                    <option value="high">High</option>
                    <option value="medium">Medium</option>
                    <option value="low">Low</option>
                </select>
            </div>
            <div class="filter-group">
                <label>Subscription:</label>
                <select id="subscriptionFilter">
                    <option value="all">All Subscriptions</option>
"@

    # Add subscription options
    foreach ($sub in $allSubscriptions) {
        $html += "                    <option value=`"$(($sub).ToLower())`">$sub</option>`n"
    }

    $html += @"
                </select>
            </div>
        </div>
"@

    if ($totalRecs -eq 0) {
        $html += @"
        <div class="no-data">
            <h2>No Recommendations Found</h2>
            <p>Azure Advisor has no recommendations for your subscriptions. Great job!</p>
        </div>
"@
    }
    else {
        # Generate sections for each category
        $categories = @(
            @{ Name = "Cost"; Icon = "cost"; Recs = $costRecs; Label = "Cost Optimization" }
            @{ Name = "Security"; Icon = "security"; Recs = $securityRecs; Label = "Security" }
            @{ Name = "Reliability"; Icon = "reliability"; Recs = $reliabilityRecs; Label = "Reliability" }
            @{ Name = "OperationalExcellence"; Icon = "operational"; Recs = $operationalRecs; Label = "Operational Excellence" }
            @{ Name = "Performance"; Icon = "performance"; Recs = $performanceRecs; Label = "Performance" }
        )
        
        foreach ($cat in $categories) {
            if ($cat.Recs.Count -eq 0) { continue }
            
            $catResourceCount = ($cat.Recs | Measure-Object -Property AffectedResourceCount -Sum).Sum
            $catHighCount = ($cat.Recs | ForEach-Object { $_.ImpactDistribution.High } | Measure-Object -Sum).Sum
            $catMediumCount = ($cat.Recs | ForEach-Object { $_.ImpactDistribution.Medium } | Measure-Object -Sum).Sum
            $catLowCount = ($cat.Recs | ForEach-Object { $_.ImpactDistribution.Low } | Measure-Object -Sum).Sum
            
            $html += @"
        
        <div class="category-section" data-category="$($cat.Name.ToLower())">
            <div class="category-header" onclick="toggleCategory(this)">
                <div class="category-title">
                    <span class="expand-icon"></span>
                    <span class="category-icon $($cat.Icon)">$($cat.Recs.Count)</span>
                    <span>$($cat.Label)</span>
                    <span style="color: var(--text-muted); font-weight: normal; font-size: 0.85rem;">($catResourceCount resources)</span>
                </div>
                <div class="category-stats">
                    <span class="impact-badge high">$catHighCount High</span>
                    <span class="impact-badge medium">$catMediumCount Med</span>
                    <span class="impact-badge low">$catLowCount Low</span>
                </div>
            </div>
            <div class="category-content">
"@
            
            foreach ($rec in $cat.Recs) {
                $impactClass = $rec.Impact.ToLower()
                $escapedProblem = Encode-Html $rec.Problem
                $escapedSolution = Encode-Html $rec.Solution
                $escapedDescription = Encode-Html $rec.Description
                $escapedLongDescription = Encode-Html $rec.LongDescription
                $escapedBenefits = Encode-Html $rec.PotentialBenefits
                $escapedRemediation = Encode-Html $rec.Remediation
                
                # Subscriptions as data attribute for filtering
                $subsLower = ($rec.AffectedSubscriptions | ForEach-Object { $_.ToLower() }) -join ','
                $searchable = "$escapedProblem $escapedSolution $escapedDescription".ToLower()
                
                $savingsDisplay = ""
                if ($rec.TotalSavings -and $rec.TotalSavings -gt 0) {
                    $savingsDisplay = "$($rec.SavingsCurrency) $([math]::Round($rec.TotalSavings, 0))/yr"
                }
                
                $html += @"
                <div class="rec-card" 
                     data-impact="$impactClass" 
                     data-subscriptions="$subsLower"
                     data-searchable="$searchable">
                    <div class="rec-header" onclick="toggleRec(this.parentElement)">
                        <span class="rec-expand"></span>
                        <div class="rec-main">
                            <div class="rec-problem">$escapedProblem</div>
                            <div class="rec-meta">
                                <span class="rec-meta-item">
                                    <span class="impact-badge $impactClass">$($rec.Impact)</span>
                                </span>
"@
                if ($rec.AffectedSubscriptions.Count -gt 1) {
                    $html += @"
                                <span class="rec-meta-item">$($rec.AffectedSubscriptions.Count) subscriptions</span>
"@
                }
                elseif ($rec.AffectedSubscriptions.Count -eq 1) {
                    $html += @"
                                <span class="rec-meta-item">$($rec.AffectedSubscriptions[0])</span>
"@
                }
                $html += @"
                            </div>
                        </div>
                        <div class="rec-stats">
"@
                if ($savingsDisplay) {
                    $html += "                            <span class='savings-badge'>$savingsDisplay</span>`n"
                }
                $html += @"
                            <span class="resource-count">$($rec.AffectedResourceCount) resource$(if ($rec.AffectedResourceCount -ne 1) { 's' })</span>
                        </div>
                    </div>
                    <div class="rec-details">
"@
                
                # Description section
                $descriptionText = if ($escapedLongDescription -and $escapedLongDescription -ne $escapedProblem) {
                    $escapedLongDescription
                } elseif ($escapedDescription -and $escapedDescription -ne $escapedProblem) {
                    $escapedDescription
                } else {
                    $escapedProblem
                }
                
                $html += @"
                        <div class="detail-section">
                            <div class="detail-title">Description</div>
                            <div class="detail-content">$descriptionText</div>
                        </div>
"@
                
                # Technical Details section (if available)
                if ($rec.AffectedResources -and ($rec.AffectedResources | Where-Object { $_.TechnicalDetails })) {
                    $html += @"
                        <div class="detail-section">
                            <div class="detail-title">Technical Details</div>
                            <div class="detail-content" style="font-family: 'Consolas', monospace; font-size: 0.9em;">
"@
                    foreach ($resource in ($rec.AffectedResources | Where-Object { $_.TechnicalDetails })) {
                    $escapedDetails = Encode-Html $resource.TechnicalDetails
                    $escapedResName = Encode-Html $resource.ResourceName
                        $html += "                                <div><strong>${escapedResName}:</strong> $escapedDetails</div>`n"
                    }
                    $html += @"
                            </div>
                        </div>
"@
                }
                
                # Solution section
                if ($escapedSolution -and $escapedSolution -ne "See Azure Portal for remediation steps") {
                    $html += @"
                        <div class="detail-section">
                            <div class="detail-title">Recommended Action</div>
                            <div class="detail-content">$escapedSolution</div>
                        </div>
"@
                }
                
                # Benefits section
                if ($escapedBenefits) {
                    $html += @"
                        <div class="detail-section">
                            <div class="detail-title">Potential Benefits</div>
                            <div class="detail-content">$escapedBenefits</div>
                        </div>
"@
                }
                
                # Remediation section
                if ($escapedRemediation -and $escapedRemediation -ne $escapedSolution) {
                    $html += @"
                        <div class="detail-section">
                            <div class="detail-title">Remediation Steps</div>
                            <div class="detail-content">$escapedRemediation</div>
                        </div>
"@
                }
                
                # Learn more link
                if ($rec.LearnMoreLink) {
                    $escapedLink = Encode-Html $rec.LearnMoreLink
                    $html += @"
                        <div class="detail-section">
                            <div class="detail-content">
                                <a href="$escapedLink" target="_blank">Learn more →</a>
                            </div>
                        </div>
"@
                }
                
                # Affected resources table
                $html += @"
                        <div class="resources-section" onclick="toggleResources(event, this)">
                            <div class="resources-header">
                                <span class="resources-title">
                                    <span class="rec-expand"></span>
                                    Affected Resources ($($rec.AffectedResourceCount))
                                </span>
                            </div>
                            <div class="resources-table-wrapper">
                                <table class="resources-table">
                                    <thead>
                                        <tr>
                                            <th>Resource Name</th>
                                            <th>Resource Group</th>
                                            <th>Subscription</th>
                                            <th>Technical Details</th>
"@
                if ($cat.Name -eq "Cost") {
                    $html += "                                            <th>Monthly</th>`n"
                    $html += "                                            <th>Annual</th>`n"
                }
                $html += @"
                                        </tr>
                                    </thead>
                                    <tbody>
"@
                
                foreach ($resource in ($rec.AffectedResources | Sort-Object SubscriptionName, ResourceGroup, ResourceName)) {
                    $escapedResName = Encode-Html $resource.ResourceName
                    $escapedResGroup = Encode-Html $resource.ResourceGroup
                    $escapedSubName = Encode-Html $resource.SubscriptionName
                    $escapedTechDetails = Encode-Html $resource.TechnicalDetails
                    
                    $html += @"
                                        <tr>
                                            <td class="resource-name">$escapedResName</td>
                                            <td>$escapedResGroup</td>
                                            <td>$escapedSubName</td>
                                            <td style="font-family: 'Consolas', monospace; font-size: 0.85em;">$escapedTechDetails</td>
"@
                    if ($cat.Name -eq "Cost") {
                        $resMonthlySavings = if ($resource.MonthlySavings -and $resource.MonthlySavings -gt 0) {
                            "$($resource.SavingsCurrency) $([math]::Round($resource.MonthlySavings, 0))/mo"
                        } else { "-" }
                        $resAnnualSavings = if ($resource.PotentialSavings -and $resource.PotentialSavings -gt 0) {
                            "$($resource.SavingsCurrency) $([math]::Round($resource.PotentialSavings, 0))/yr"
                        } else { "-" }
                        $html += "                                            <td style='color: var(--accent-green);'>$resMonthlySavings</td>`n"
                        $html += "                                            <td style='color: var(--accent-green);'>$resAnnualSavings</td>`n"
                    }
                    $html += "                                        </tr>`n"
                }
                
                $html += @"
                                    </tbody>
                                </table>
                            </div>
                        </div>
                    </div>
                </div>
"@
            }
            
            $html += @"
            </div>
        </div>
"@
        }
    }
    
    # JavaScript - using placeholder for && to avoid PowerShell issues
    $jsCode = @'
    </div>
    
    <script>
        function toggleCategory(header) {
            header.classList.toggle('collapsed');
        }
        
        function toggleRec(card) {
            card.classList.toggle('expanded');
        }
        
        function toggleResources(event, section) {
            event.stopPropagation();
            section.classList.toggle('expanded');
        }
        
        // Filtering
        const searchFilter = document.getElementById('searchFilter');
        const impactFilter = document.getElementById('impactFilter');
        const subscriptionFilter = document.getElementById('subscriptionFilter');
        
        function applyFilters() {
            const searchText = searchFilter.value.toLowerCase();
            const impactValue = impactFilter.value;
            const subscriptionValue = subscriptionFilter.value;
            
            document.querySelectorAll('.category-section').forEach(section => {
                let visibleCards = 0;
                
                section.querySelectorAll('.rec-card').forEach(card => {
                    const searchable = card.getAttribute('data-searchable');
                    const impact = card.getAttribute('data-impact');
                    const subs = card.getAttribute('data-subscriptions');
                    
                    const searchMatch = searchText === '' || searchable.includes(searchText);
                    const impactMatch = impactValue === 'all' || impact === impactValue;
                    const subMatch = subscriptionValue === 'all' || subs.includes(subscriptionValue);
                    
                    if (searchMatch PLACEHOLDER_AND impactMatch PLACEHOLDER_AND subMatch) {
                        card.style.display = '';
                        visibleCards++;
                    } else {
                        card.style.display = 'none';
                        card.classList.remove('expanded');
                    }
                });
                
                section.style.display = visibleCards === 0 ? 'none' : '';
            });
        }
        
        searchFilter.addEventListener('input', applyFilters);
        impactFilter.addEventListener('change', applyFilters);
        subscriptionFilter.addEventListener('change', applyFilters);
        
        // Expand all categories by default
        document.querySelectorAll('.category-header.collapsed').forEach(h => h.classList.remove('collapsed'));
    </script>
</body>
</html>
'@
    $jsCode = $jsCode -replace 'PLACEHOLDER_AND', '&&'
    $html += $jsCode
    
    # Write to file
    $html | Out-File -FilePath $OutputPath -Encoding UTF8
    
    return $OutputPath
}

