<#
.SYNOPSIS
    Generates an interactive HTML report from RBAC inventory data.

.DESCRIPTION
    Creates a comprehensive RBAC/IAM report with summary cards, risk analysis,
    expandable sections, and filtering capabilities. Follows the standard
    governance report styling and structure.

.PARAMETER RBACData
    RBAC inventory object from Get-AzureRBACInventory.ps1

.PARAMETER OutputPath
    Path for the HTML report output.

.OUTPUTS
    String path to the generated HTML report.

.EXAMPLE
    $rbacData = .\Get-AzureRBACInventory.ps1
    .\Export-RBACReport.ps1 -RBACData $rbacData -OutputPath "./reports/rbac.html"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$RBACData,
    
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

#region Helper Functions

function Escape-Html {
    param([string]$text)
    if ([string]::IsNullOrEmpty($text)) { return "" }
    return $text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&#39;')
}

function Get-RiskBadgeClass {
    param([string]$Risk)
    switch ($Risk) {
        'Critical' { return 'badge-critical' }
        'High' { return 'badge-high' }
        'Medium' { return 'badge-medium' }
        'Low' { return 'badge-low' }
        default { return 'badge-low' }
    }
}

function Get-PrincipalTypeIcon {
    param([string]$Type)
    switch ($Type) {
        'User' { return '👤' }
        'Group' { return '👥' }
        'ServicePrincipal' { return '🤖' }
        'ManagedIdentity' { return '🔐' }
        default { return '❓' }
    }
}

function Get-ScopeIcon {
    param([string]$Type)
    switch ($Type) {
        'ManagementGroup' { return '🏢' }
        'Subscription' { return '📁' }
        'ResourceGroup' { return '📂' }
        'Resource' { return '📄' }
        default { return '📍' }
    }
}

#endregion

#region Build HTML

$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$stats = $RBACData.Statistics
$metadata = $RBACData.Metadata

# Pre-calculate subscription options for filter
$subscriptionOptions = $RBACData.RoleAssignments | 
    Select-Object -ExpandProperty SubscriptionName -Unique | 
    Sort-Object |
    ForEach-Object { "<option value=`"$(Escape-Html $_)`">$(Escape-Html $_)</option>" }

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>RBAC/IAM Inventory Report</title>
    <style>
        :root {
            --bg-primary: #1a1a2e;
            --bg-secondary: #16213e;
            --bg-card: #1f2937;
            --bg-hover: #374151;
            --text-primary: #f3f4f6;
            --text-secondary: #9ca3af;
            --text-muted: #6b7280;
            --border-color: #374151;
            --accent-blue: #3b82f6;
            --accent-green: #10b981;
            --accent-yellow: #f59e0b;
            --accent-red: #ef4444;
            --accent-purple: #8b5cf6;
            --accent-cyan: #06b6d4;
        }
        
        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            line-height: 1.6;
            padding: 20px;
        }
        
        .container {
            max-width: 1600px;
            margin: 0 auto;
        }
        
        /* Header */
        .header {
            text-align: center;
            margin-bottom: 30px;
            padding-bottom: 20px;
            border-bottom: 1px solid var(--border-color);
        }
        
        .header h1 {
            font-size: 2rem;
            margin-bottom: 10px;
            color: var(--text-primary);
        }
        
        .header .subtitle {
            color: var(--text-secondary);
            font-size: 0.95rem;
        }
        
        /* Summary Cards */
        .summary-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-bottom: 30px;
        }
        
        .summary-card {
            background: var(--bg-card);
            border-radius: 10px;
            padding: 20px;
            border: 1px solid var(--border-color);
        }
        
        .summary-card .label {
            font-size: 0.85rem;
            color: var(--text-secondary);
            text-transform: uppercase;
            letter-spacing: 0.5px;
            margin-bottom: 8px;
        }
        
        .summary-card .value {
            font-size: 2rem;
            font-weight: 700;
        }
        
        .summary-card .subtext {
            font-size: 0.8rem;
            color: var(--text-muted);
            margin-top: 5px;
        }
        
        .value-critical { color: var(--accent-red); }
        .value-high { color: var(--accent-yellow); }
        .value-medium { color: var(--accent-blue); }
        .value-low { color: var(--accent-green); }
        .value-neutral { color: var(--text-primary); }
        
        /* Filters */
        .filters {
            background: var(--bg-card);
            border-radius: 10px;
            padding: 20px;
            margin-bottom: 20px;
            border: 1px solid var(--border-color);
        }
        
        .filters-row {
            display: flex;
            flex-wrap: wrap;
            gap: 15px;
            align-items: center;
        }
        
        .filter-group {
            display: flex;
            flex-direction: column;
            gap: 5px;
        }
        
        .filter-group label {
            font-size: 0.8rem;
            color: var(--text-secondary);
            text-transform: uppercase;
        }
        
        .filter-group input,
        .filter-group select {
            padding: 8px 12px;
            border-radius: 6px;
            border: 1px solid var(--border-color);
            background: var(--bg-secondary);
            color: var(--text-primary);
            font-size: 0.9rem;
            min-width: 180px;
        }
        
        .filter-group input:focus,
        .filter-group select:focus {
            outline: none;
            border-color: var(--accent-blue);
        }
        
        .filter-stats {
            margin-left: auto;
            color: var(--text-secondary);
            font-size: 0.9rem;
        }
        
        /* Sections */
        .section {
            background: var(--bg-card);
            border-radius: 10px;
            margin-bottom: 20px;
            border: 1px solid var(--border-color);
            overflow: hidden;
        }
        
        .section-header {
            padding: 15px 20px;
            background: var(--bg-secondary);
            display: flex;
            justify-content: space-between;
            align-items: center;
            cursor: pointer;
            user-select: none;
        }
        
        .section-header:hover {
            background: var(--bg-hover);
        }
        
        .section-title {
            font-size: 1.1rem;
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 10px;
        }
        
        .section-count {
            background: var(--accent-blue);
            color: white;
            padding: 2px 10px;
            border-radius: 12px;
            font-size: 0.8rem;
            font-weight: 500;
        }
        
        .section-count.critical { background: var(--accent-red); }
        .section-count.warning { background: var(--accent-yellow); color: #1a1a2e; }
        
        .section-toggle {
            font-size: 1.2rem;
            transition: transform 0.2s;
        }
        
        .section.collapsed .section-toggle {
            transform: rotate(-90deg);
        }
        
        .section.collapsed .section-content {
            display: none;
        }
        
        .section-content {
            padding: 20px;
        }
        
        /* Tables */
        .table-container {
            overflow-x: auto;
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
            font-size: 0.9rem;
        }
        
        th {
            text-align: left;
            padding: 12px 15px;
            background: var(--bg-secondary);
            color: var(--text-secondary);
            font-weight: 600;
            text-transform: uppercase;
            font-size: 0.75rem;
            letter-spacing: 0.5px;
            border-bottom: 2px solid var(--border-color);
            white-space: nowrap;
        }
        
        td {
            padding: 12px 15px;
            border-bottom: 1px solid var(--border-color);
            vertical-align: top;
        }
        
        tr:hover td {
            background: var(--bg-hover);
        }
        
        tr.filtered-out {
            display: none;
        }
        
        /* Badges */
        .badge {
            display: inline-block;
            padding: 3px 10px;
            border-radius: 12px;
            font-size: 0.75rem;
            font-weight: 600;
            text-transform: uppercase;
        }
        
        .badge-critical {
            background: rgba(239, 68, 68, 0.2);
            color: var(--accent-red);
            border: 1px solid var(--accent-red);
        }
        
        .badge-high {
            background: rgba(245, 158, 11, 0.2);
            color: var(--accent-yellow);
            border: 1px solid var(--accent-yellow);
        }
        
        .badge-medium {
            background: rgba(59, 130, 246, 0.2);
            color: var(--accent-blue);
            border: 1px solid var(--accent-blue);
        }
        
        .badge-low {
            background: rgba(16, 185, 129, 0.2);
            color: var(--accent-green);
            border: 1px solid var(--accent-green);
        }
        
        .badge-orphaned {
            background: rgba(139, 92, 246, 0.2);
            color: var(--accent-purple);
            border: 1px solid var(--accent-purple);
        }
        
        .badge-external {
            background: rgba(6, 182, 212, 0.2);
            color: var(--accent-cyan);
            border: 1px solid var(--accent-cyan);
        }
        
        .badge-type {
            background: var(--bg-secondary);
            color: var(--text-secondary);
            border: 1px solid var(--border-color);
        }
        
        /* Principal/Scope display */
        .principal-cell {
            display: flex;
            flex-direction: column;
            gap: 3px;
        }
        
        .principal-name {
            font-weight: 500;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        
        .principal-upn {
            font-size: 0.8rem;
            color: var(--text-muted);
        }
        
        .scope-cell {
            max-width: 400px;
        }
        
        .scope-path {
            font-family: 'Consolas', 'Monaco', monospace;
            font-size: 0.8rem;
            color: var(--text-secondary);
            word-break: break-all;
        }
        
        /* Distribution bar */
        .distribution-bar {
            display: flex;
            height: 8px;
            border-radius: 4px;
            overflow: hidden;
            margin-top: 10px;
            background: var(--bg-secondary);
        }
        
        .distribution-segment {
            height: 100%;
            transition: width 0.3s;
        }
        
        .segment-critical { background: var(--accent-red); }
        .segment-high { background: var(--accent-yellow); }
        .segment-medium { background: var(--accent-blue); }
        .segment-low { background: var(--accent-green); }
        
        /* Role usage chart */
        .role-bar {
            display: flex;
            align-items: center;
            gap: 10px;
            margin-bottom: 8px;
        }
        
        .role-name {
            width: 200px;
            font-size: 0.85rem;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }
        
        .role-bar-fill {
            height: 20px;
            background: var(--accent-blue);
            border-radius: 4px;
            min-width: 2px;
        }
        
        .role-count {
            font-size: 0.85rem;
            color: var(--text-secondary);
            min-width: 40px;
        }
        
        /* Cross-sub analysis */
        .cross-sub-card {
            background: var(--bg-secondary);
            border-radius: 8px;
            padding: 15px;
            margin-bottom: 10px;
            border-left: 4px solid var(--accent-purple);
        }
        
        .cross-sub-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 10px;
        }
        
        .cross-sub-principal {
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        
        .cross-sub-stats {
            display: flex;
            gap: 15px;
            font-size: 0.85rem;
            color: var(--text-secondary);
        }
        
        .cross-sub-subs {
            font-size: 0.85rem;
            color: var(--text-muted);
        }
        
        .cross-sub-subs span {
            display: inline-block;
            background: var(--bg-card);
            padding: 2px 8px;
            border-radius: 4px;
            margin: 2px;
        }
        
        /* Responsive */
        @media (max-width: 768px) {
            .summary-grid {
                grid-template-columns: repeat(2, 1fr);
            }
            
            .filters-row {
                flex-direction: column;
                align-items: stretch;
            }
            
            .filter-stats {
                margin-left: 0;
                margin-top: 10px;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🔐 RBAC/IAM Inventory Report</h1>
            <div class="subtitle">
                Tenant: $($metadata.TenantId) | 
                Generated: $timestamp | 
                Subscriptions Scanned: $($metadata.SubscriptionsScanned)
            </div>
        </div>
        
        <!-- Summary Cards -->
        <div class="summary-grid">
            <div class="summary-card">
                <div class="label">Total Assignments</div>
                <div class="value value-neutral">$($stats.TotalAssignments)</div>
                <div class="subtext">Across all subscriptions</div>
            </div>
            <div class="summary-card">
                <div class="label">Critical Risk</div>
                <div class="value value-critical">$($stats.ByRiskLevel.Critical)</div>
                <div class="subtext">High privilege at broad scope</div>
            </div>
            <div class="summary-card">
                <div class="label">High Risk</div>
                <div class="value value-high">$($stats.ByRiskLevel.High)</div>
                <div class="subtext">Needs review</div>
            </div>
            <div class="summary-card">
                <div class="label">Orphaned</div>
                <div class="value value-critical">$($stats.OrphanedCount)</div>
                <div class="subtext">Deleted principals</div>
            </div>
            <div class="summary-card">
                <div class="label">External/Guest</div>
                <div class="value value-medium">$($stats.ExternalCount)</div>
                <div class="subtext">B2B guest access</div>
            </div>
            <div class="summary-card">
                <div class="label">Non-Human</div>
                <div class="value value-neutral">$($stats.ByPrincipalType.ServicePrincipal + $stats.ByPrincipalType.ManagedIdentity)</div>
                <div class="subtext">SPs and Managed Identities</div>
            </div>
            <div class="summary-card">
                <div class="label">Custom Roles</div>
                <div class="value value-neutral">$($stats.CustomRoleCount)</div>
                <div class="subtext">Tenant-specific definitions</div>
            </div>
            <div class="summary-card">
                <div class="label">Users</div>
                <div class="value value-neutral">$($stats.ByPrincipalType.User)</div>
                <div class="subtext">Direct user assignments</div>
            </div>
        </div>
        
        <!-- Risk Distribution -->
        <div class="summary-card" style="margin-bottom: 20px;">
            <div class="label">Risk Distribution</div>
            <div class="distribution-bar">
"@

# Calculate percentages for distribution bar
$total = [Math]::Max(1, $stats.TotalAssignments)
$criticalPct = [Math]::Round(($stats.ByRiskLevel.Critical / $total) * 100, 1)
$highPct = [Math]::Round(($stats.ByRiskLevel.High / $total) * 100, 1)
$mediumPct = [Math]::Round(($stats.ByRiskLevel.Medium / $total) * 100, 1)
$lowPct = [Math]::Round(($stats.ByRiskLevel.Low / $total) * 100, 1)

$html += @"
                <div class="distribution-segment segment-critical" style="width: $criticalPct%;" title="Critical: $($stats.ByRiskLevel.Critical)"></div>
                <div class="distribution-segment segment-high" style="width: $highPct%;" title="High: $($stats.ByRiskLevel.High)"></div>
                <div class="distribution-segment segment-medium" style="width: $mediumPct%;" title="Medium: $($stats.ByRiskLevel.Medium)"></div>
                <div class="distribution-segment segment-low" style="width: $lowPct%;" title="Low: $($stats.ByRiskLevel.Low)"></div>
            </div>
            <div class="subtext" style="margin-top: 8px;">
                <span style="color: var(--accent-red);">● Critical: $($stats.ByRiskLevel.Critical)</span> |
                <span style="color: var(--accent-yellow);">● High: $($stats.ByRiskLevel.High)</span> |
                <span style="color: var(--accent-blue);">● Medium: $($stats.ByRiskLevel.Medium)</span> |
                <span style="color: var(--accent-green);">● Low: $($stats.ByRiskLevel.Low)</span>
            </div>
        </div>
        
        <!-- Filters -->
        <div class="filters">
            <div class="filters-row">
                <div class="filter-group">
                    <label>Search</label>
                    <input type="text" id="searchInput" placeholder="Principal, role, scope...">
                </div>
                <div class="filter-group">
                    <label>Risk Level</label>
                    <select id="riskFilter">
                        <option value="">All Risks</option>
                        <option value="Critical">Critical</option>
                        <option value="High">High</option>
                        <option value="Medium">Medium</option>
                        <option value="Low">Low</option>
                    </select>
                </div>
                <div class="filter-group">
                    <label>Principal Type</label>
                    <select id="typeFilter">
                        <option value="">All Types</option>
                        <option value="User">Users</option>
                        <option value="Group">Groups</option>
                        <option value="ServicePrincipal">Service Principals</option>
                        <option value="ManagedIdentity">Managed Identities</option>
                    </select>
                </div>
                <div class="filter-group">
                    <label>Subscription</label>
                    <select id="subFilter">
                        <option value="">All Subscriptions</option>
                        $($subscriptionOptions -join "`n                        ")
                    </select>
                </div>
                <div class="filter-stats">
                    Showing <span id="visibleCount">$($stats.TotalAssignments)</span> of $($stats.TotalAssignments) assignments
                </div>
            </div>
        </div>
"@

# Cross-Subscription Analysis Section
$crossSubCount = $RBACData.Analysis.CrossSubscriptionPrincipals.Count
if ($crossSubCount -gt 0) {
    $html += @"
        
        <!-- Cross-Subscription Access -->
        <div class="section">
            <div class="section-header" onclick="toggleSection(this)">
                <div class="section-title">
                    🌐 Cross-Subscription Access
                    <span class="section-count warning">$crossSubCount principals</span>
                </div>
                <span class="section-toggle">▼</span>
            </div>
            <div class="section-content">
                <p style="color: var(--text-secondary); margin-bottom: 15px;">
                    Principals with access to multiple subscriptions. Review for least-privilege compliance.
                </p>
"@
    
    foreach ($principal in $RBACData.Analysis.CrossSubscriptionPrincipals | Select-Object -First 20) {
        $icon = Get-PrincipalTypeIcon -Type $principal.PrincipalType
        $riskBadge = Get-RiskBadgeClass -Risk $principal.HighestRiskLevel
        $subsHtml = ($principal.Subscriptions | ForEach-Object { "<span>$(Escape-Html $_)</span>" }) -join ""
        $rolesHtml = (Escape-Html (($principal.Roles | Select-Object -First 5) -join ", "))
        
        $html += @"
                <div class="cross-sub-card">
                    <div class="cross-sub-header">
                        <div class="cross-sub-principal">
                            $icon $(Escape-Html $principal.PrincipalDisplayName)
                            <span class="badge badge-type">$($principal.PrincipalType)</span>
                        </div>
                        <span class="badge $riskBadge">$($principal.HighestRiskLevel)</span>
                    </div>
                    <div class="cross-sub-stats">
                        <span>📁 $($principal.SubscriptionCount) subscriptions</span>
                        <span>🔑 $($principal.AssignmentCount) assignments</span>
                        <span>Roles: $rolesHtml</span>
                    </div>
                    <div class="cross-sub-subs">$subsHtml</div>
                </div>
"@
    }
    
    $html += @"
            </div>
        </div>
"@
}

# Privileged Assignments Section
$privilegedCount = $RBACData.Analysis.PrivilegedAssignments.Count
$html += @"

        <!-- Privileged Assignments -->
        <div class="section">
            <div class="section-header" onclick="toggleSection(this)">
                <div class="section-title">
                    ⚠️ Privileged Assignments
                    <span class="section-count critical">$privilegedCount</span>
                </div>
                <span class="section-toggle">▼</span>
            </div>
            <div class="section-content">
                <p style="color: var(--text-secondary); margin-bottom: 15px;">
                    Critical and High risk assignments requiring periodic review.
                </p>
                <div class="table-container">
                    <table>
                        <thead>
                            <tr>
                                <th>Risk</th>
                                <th>Principal</th>
                                <th>Role</th>
                                <th>Scope</th>
                                <th>Subscription</th>
                            </tr>
                        </thead>
                        <tbody>
"@

foreach ($assignment in $RBACData.Analysis.PrivilegedAssignments | Select-Object -First 100) {
    $icon = Get-PrincipalTypeIcon -Type $assignment.PrincipalType
    $riskBadge = Get-RiskBadgeClass -Risk $assignment.RiskLevel
    $scopeIcon = Get-ScopeIcon -Type $assignment.ScopeType
    
    $html += @"
                            <tr class="assignment-row" 
                                data-search="$(Escape-Html "$($assignment.PrincipalDisplayName) $($assignment.RoleDefinitionName) $($assignment.Scope)".ToLower())"
                                data-risk="$($assignment.RiskLevel)"
                                data-type="$($assignment.PrincipalType)"
                                data-sub="$(Escape-Html $assignment.SubscriptionName)">
                                <td><span class="badge $riskBadge">$($assignment.RiskLevel)</span></td>
                                <td>
                                    <div class="principal-cell">
                                        <div class="principal-name">$icon $(Escape-Html $assignment.PrincipalDisplayName)</div>
                                        $(if ($assignment.PrincipalUPN) { "<div class='principal-upn'>$(Escape-Html $assignment.PrincipalUPN)</div>" })
                                    </div>
                                </td>
                                <td>$(Escape-Html $assignment.RoleDefinitionName)</td>
                                <td class="scope-cell">
                                    $scopeIcon $($assignment.ScopeType)
                                    <div class="scope-path">$(Escape-Html $assignment.Scope)</div>
                                </td>
                                <td>$(Escape-Html $assignment.SubscriptionName)</td>
                            </tr>
"@
}

$html += @"
                        </tbody>
                    </table>
                </div>
            </div>
        </div>
"@

# Orphaned Assignments Section
$orphanedCount = $RBACData.Analysis.OrphanedAssignments.Count
if ($orphanedCount -gt 0) {
    $html += @"

        <!-- Orphaned Assignments -->
        <div class="section">
            <div class="section-header" onclick="toggleSection(this)">
                <div class="section-title">
                    👻 Orphaned Assignments
                    <span class="section-count critical">$orphanedCount</span>
                </div>
                <span class="section-toggle">▼</span>
            </div>
            <div class="section-content">
                <p style="color: var(--text-secondary); margin-bottom: 15px;">
                    Role assignments pointing to deleted principals. These should be removed.
                </p>
                <div class="table-container">
                    <table>
                        <thead>
                            <tr>
                                <th>Principal ID</th>
                                <th>Original Type</th>
                                <th>Role</th>
                                <th>Scope</th>
                                <th>Subscription</th>
                            </tr>
                        </thead>
                        <tbody>
"@

    foreach ($assignment in $RBACData.Analysis.OrphanedAssignments) {
        $html += @"
                            <tr class="assignment-row"
                                data-search="$(Escape-Html "$($assignment.PrincipalId) $($assignment.RoleDefinitionName)".ToLower())"
                                data-risk="Critical"
                                data-type="$($assignment.PrincipalType)"
                                data-sub="$(Escape-Html $assignment.SubscriptionName)">
                                <td><code style="color: var(--accent-purple);">$($assignment.PrincipalId)</code></td>
                                <td><span class="badge badge-orphaned">$($assignment.PrincipalType)</span></td>
                                <td>$(Escape-Html $assignment.RoleDefinitionName)</td>
                                <td class="scope-cell">
                                    <div class="scope-path">$(Escape-Html $assignment.Scope)</div>
                                </td>
                                <td>$(Escape-Html $assignment.SubscriptionName)</td>
                            </tr>
"@
    }

    $html += @"
                        </tbody>
                    </table>
                </div>
            </div>
        </div>
"@
}

# Non-Human Identities Section
$nonHumanCount = $RBACData.Analysis.NonHumanIdentities.Count
$html += @"

        <!-- Non-Human Identities -->
        <div class="section collapsed">
            <div class="section-header" onclick="toggleSection(this)">
                <div class="section-title">
                    🤖 Service Principals & Managed Identities
                    <span class="section-count">$nonHumanCount</span>
                </div>
                <span class="section-toggle">▼</span>
            </div>
            <div class="section-content">
                <p style="color: var(--text-secondary); margin-bottom: 15px;">
                    Non-human identities with Azure RBAC permissions.
                </p>
                <div class="table-container">
                    <table>
                        <thead>
                            <tr>
                                <th>Risk</th>
                                <th>Identity</th>
                                <th>Type</th>
                                <th>Role</th>
                                <th>Scope</th>
                                <th>Subscription</th>
                            </tr>
                        </thead>
                        <tbody>
"@

foreach ($assignment in $RBACData.Analysis.NonHumanIdentities | Select-Object -First 100) {
    $icon = Get-PrincipalTypeIcon -Type $assignment.PrincipalType
    $riskBadge = Get-RiskBadgeClass -Risk $assignment.RiskLevel
    $typeBadge = if ($assignment.PrincipalType -eq 'ManagedIdentity') { 'badge-low' } else { 'badge-type' }
    
    $html += @"
                            <tr class="assignment-row"
                                data-search="$(Escape-Html "$($assignment.PrincipalDisplayName) $($assignment.RoleDefinitionName)".ToLower())"
                                data-risk="$($assignment.RiskLevel)"
                                data-type="$($assignment.PrincipalType)"
                                data-sub="$(Escape-Html $assignment.SubscriptionName)">
                                <td><span class="badge $riskBadge">$($assignment.RiskLevel)</span></td>
                                <td>
                                    <div class="principal-cell">
                                        <div class="principal-name">$icon $(Escape-Html $assignment.PrincipalDisplayName)</div>
                                        $(if ($assignment.AppId) { "<div class='principal-upn'>AppId: $($assignment.AppId)</div>" })
                                    </div>
                                </td>
                                <td><span class="badge $typeBadge">$($assignment.PrincipalType)</span></td>
                                <td>$(Escape-Html $assignment.RoleDefinitionName)</td>
                                <td class="scope-cell">
                                    <div class="scope-path">$(Escape-Html $assignment.Scope)</div>
                                </td>
                                <td>$(Escape-Html $assignment.SubscriptionName)</td>
                            </tr>
"@
}

$html += @"
                        </tbody>
                    </table>
                </div>
            </div>
        </div>
"@

# Role Usage Section
$html += @"

        <!-- Role Usage Analysis -->
        <div class="section collapsed">
            <div class="section-header" onclick="toggleSection(this)">
                <div class="section-title">
                    📊 Role Usage Analysis
                    <span class="section-count">$($RBACData.Analysis.RoleUsage.Count) roles</span>
                </div>
                <span class="section-toggle">▼</span>
            </div>
            <div class="section-content">
                <p style="color: var(--text-secondary); margin-bottom: 15px;">
                    Most frequently assigned roles across all subscriptions.
                </p>
"@

$maxCount = ($RBACData.Analysis.RoleUsage | Measure-Object -Property AssignmentCount -Maximum).Maximum
if (-not $maxCount) { $maxCount = 1 }

foreach ($role in $RBACData.Analysis.RoleUsage | Select-Object -First 20) {
    $barWidth = [Math]::Round(($role.AssignmentCount / $maxCount) * 300)
    $html += @"
                <div class="role-bar">
                    <div class="role-name" title="$(Escape-Html $role.RoleName)">$(Escape-Html $role.RoleName)</div>
                    <div class="role-bar-fill" style="width: ${barWidth}px;"></div>
                    <div class="role-count">$($role.AssignmentCount)</div>
                </div>
"@
}

$html += @"
            </div>
        </div>
"@

# Custom Roles Section
if ($RBACData.CustomRoles.Count -gt 0) {
    $html += @"

        <!-- Custom Role Definitions -->
        <div class="section collapsed">
            <div class="section-header" onclick="toggleSection(this)">
                <div class="section-title">
                    🎨 Custom Role Definitions
                    <span class="section-count">$($RBACData.CustomRoles.Count)</span>
                </div>
                <span class="section-toggle">▼</span>
            </div>
            <div class="section-content">
                <p style="color: var(--text-secondary); margin-bottom: 15px;">
                    Tenant-specific custom roles. Review periodically for least-privilege compliance.
                </p>
                <div class="table-container">
                    <table>
                        <thead>
                            <tr>
                                <th>Role Name</th>
                                <th>Description</th>
                                <th>Actions</th>
                                <th>Data Actions</th>
                            </tr>
                        </thead>
                        <tbody>
"@

    foreach ($role in $RBACData.CustomRoles) {
        $actionsCount = if ($role.Actions) { $role.Actions.Count } else { 0 }
        $dataActionsCount = if ($role.DataActions) { $role.DataActions.Count } else { 0 }
        
        $html += @"
                            <tr>
                                <td><strong>$(Escape-Html $role.Name)</strong></td>
                                <td>$(Escape-Html $role.Description)</td>
                                <td>$actionsCount actions</td>
                                <td>$dataActionsCount data actions</td>
                            </tr>
"@
    }

    $html += @"
                        </tbody>
                    </table>
                </div>
            </div>
        </div>
"@
}

# All Assignments Section (collapsed by default)
$html += @"

        <!-- All Role Assignments -->
        <div class="section collapsed">
            <div class="section-header" onclick="toggleSection(this)">
                <div class="section-title">
                    📋 All Role Assignments
                    <span class="section-count">$($stats.TotalAssignments)</span>
                </div>
                <span class="section-toggle">▼</span>
            </div>
            <div class="section-content">
                <div class="table-container">
                    <table id="allAssignmentsTable">
                        <thead>
                            <tr>
                                <th>Risk</th>
                                <th>Principal</th>
                                <th>Type</th>
                                <th>Role</th>
                                <th>Scope Type</th>
                                <th>Subscription</th>
                            </tr>
                        </thead>
                        <tbody>
"@

foreach ($assignment in $RBACData.RoleAssignments) {
    $icon = Get-PrincipalTypeIcon -Type $assignment.PrincipalType
    $riskBadge = Get-RiskBadgeClass -Risk $assignment.RiskLevel
    $scopeIcon = Get-ScopeIcon -Type $assignment.ScopeType
    
    $extraBadges = ""
    if ($assignment.IsOrphaned) { $extraBadges += '<span class="badge badge-orphaned">Orphaned</span> ' }
    if ($assignment.IsExternal) { $extraBadges += '<span class="badge badge-external">External</span> ' }
    
    $html += @"
                            <tr class="assignment-row"
                                data-search="$(Escape-Html "$($assignment.PrincipalDisplayName) $($assignment.RoleDefinitionName) $($assignment.Scope) $($assignment.SubscriptionName)".ToLower())"
                                data-risk="$($assignment.RiskLevel)"
                                data-type="$($assignment.PrincipalType)"
                                data-sub="$(Escape-Html $assignment.SubscriptionName)">
                                <td><span class="badge $riskBadge">$($assignment.RiskLevel)</span></td>
                                <td>
                                    <div class="principal-cell">
                                        <div class="principal-name">$icon $(Escape-Html $assignment.PrincipalDisplayName) $extraBadges</div>
                                        $(if ($assignment.PrincipalUPN) { "<div class='principal-upn'>$(Escape-Html $assignment.PrincipalUPN)</div>" })
                                    </div>
                                </td>
                                <td><span class="badge badge-type">$($assignment.PrincipalType)</span></td>
                                <td>$(Escape-Html $assignment.RoleDefinitionName)</td>
                                <td>$scopeIcon $($assignment.ScopeType)</td>
                                <td>$(Escape-Html $assignment.SubscriptionName)</td>
                            </tr>
"@
}

$html += @"
                        </tbody>
                    </table>
                </div>
            </div>
        </div>
    </div>
    
    <script>
        // Toggle section expand/collapse
        function toggleSection(header) {
            const section = header.parentElement;
            section.classList.toggle('collapsed');
        }
        
        // Filtering logic
        const searchInput = document.getElementById('searchInput');
        const riskFilter = document.getElementById('riskFilter');
        const typeFilter = document.getElementById('typeFilter');
        const subFilter = document.getElementById('subFilter');
        const visibleCount = document.getElementById('visibleCount');
        
        function applyFilters() {
            const searchTerm = searchInput.value.toLowerCase();
            const riskValue = riskFilter.value;
            const typeValue = typeFilter.value;
            const subValue = subFilter.value;
            
            const rows = document.querySelectorAll('.assignment-row');
            let visible = 0;
            
            rows.forEach(row => {
                const matchesSearch = !searchTerm || row.dataset.search.includes(searchTerm);
                const matchesRisk = !riskValue || row.dataset.risk === riskValue;
                const matchesType = !typeValue || row.dataset.type === typeValue;
                const matchesSub = !subValue || row.dataset.sub === subValue;
                
                if (matchesSearch && matchesRisk && matchesType && matchesSub) {
                    row.classList.remove('filtered-out');
                    visible++;
                } else {
                    row.classList.add('filtered-out');
                }
            });
            
            visibleCount.textContent = visible;
        }
        
        searchInput.addEventListener('input', applyFilters);
        riskFilter.addEventListener('change', applyFilters);
        typeFilter.addEventListener('change', applyFilters);
        subFilter.addEventListener('change', applyFilters);
    </script>
</body>
</html>
"@

#endregion

# Write output
$html | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
Write-Host "Report generated: $OutputPath" -ForegroundColor Green

return $OutputPath
