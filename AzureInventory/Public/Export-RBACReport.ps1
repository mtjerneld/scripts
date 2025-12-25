<#
.SYNOPSIS
    Generates an interactive HTML report from RBAC inventory data.

.DESCRIPTION
    Creates a comprehensive RBAC/IAM report with summary cards, risk analysis,
    expandable sections, and filtering capabilities. Follows the standard
    governance report styling and structure.

.PARAMETER RBACData
    RBAC inventory object from Get-AzureRBACInventory.

.PARAMETER OutputPath
    Path for the HTML report output.

.PARAMETER TenantId
    Azure Tenant ID for display in report.

.OUTPUTS
    String path to the generated HTML report.

.EXAMPLE
    $rbacData = Get-AzureRBACInventory
    Export-RBACReport -RBACData $rbacData -OutputPath "./reports/rbac.html"
#>

function Export-RBACReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$RBACData,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        
        [string]$TenantId = "Unknown"
    )

    #region Helper Functions

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
            'User' { return "&#128100;" }
            'Group' { return "&#128101;" }
            'ServicePrincipal' { return "&#129302;" }
            'ManagedIdentity' { return "&#128272;" }
            default { return "&#10067;" }
        }
    }

    function Get-ScopeIcon {
        param([string]$Type)
        switch ($Type) {
            'ManagementGroup' { return "&#127970;" }
            'Subscription' { return "&#128193;" }
            'ResourceGroup' { return "&#128194;" }
            'Resource' { return "&#128196;" }
            default { return "&#128205;" }
        }
    }

    #endregion

    #region Build HTML

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $stats = $RBACData.Statistics
    $metadata = $RBACData.Metadata
    $principals = $RBACData.Principals
    $orphanedAssignments = $RBACData.OrphanedAssignments
    $customRoles = $RBACData.CustomRoles
    $displayTenantId = if ($TenantId -ne "Unknown") { $TenantId } else { $metadata.TenantId }

    # Pre-calculate subscription options for filter
    $allSubscriptions = @()
    foreach ($principal in $principals) {
        $allSubscriptions += $principal.AffectedSubscriptions
    }
    $subscriptionOptions = $allSubscriptions | 
        Select-Object -Unique | 
        Sort-Object |
        ForEach-Object { 
            $encoded = Encode-Html $_
            "<option value=`"$encoded`">$encoded</option>" 
        }

    # Get base stylesheet and add RBAC-specific styles
    $rbacSpecificStyles = @"
        /* RBAC-specific styles */
        .summary-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-bottom: 30px;
        }
        
        .summary-card {
            background: var(--bg-surface);
            border-radius: var(--radius-md);
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
            background: var(--bg-surface);
            border-radius: var(--radius-md);
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
            border-radius: var(--radius-sm);
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
        
        /* Risk Level Checkboxes */
        .risk-checkboxes {
            display: flex;
            flex-wrap: wrap;
            gap: 8px;
            align-items: center;
        }
        
        .checkbox-label {
            display: flex;
            align-items: center;
            gap: 6px;
            cursor: pointer;
            user-select: none;
        }
        
        .checkbox-label input[type="checkbox"] {
            cursor: pointer;
            width: 16px;
            height: 16px;
            margin: 0;
            accent-color: var(--accent-blue);
        }
        
        .checkbox-label .badge {
            font-size: 0.75rem;
            padding: 2px 8px;
            pointer-events: none;
        }
        
        /* Sections */
        .section {
            background: var(--bg-surface);
            border-radius: var(--radius-md);
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
        .section-count.warning { background: var(--accent-yellow); color: var(--bg-primary); }
        
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
            background: rgba(255, 107, 107, 0.2);
            color: var(--accent-red);
            border: 1px solid var(--accent-red);
        }
        
        .badge-high {
            background: rgba(254, 202, 87, 0.2);
            color: var(--accent-yellow);
            border: 1px solid var(--accent-yellow);
        }
        
        .badge-medium {
            background: rgba(84, 160, 255, 0.2);
            color: var(--accent-blue);
            border: 1px solid var(--accent-blue);
        }
        
        .badge-low {
            background: rgba(0, 210, 106, 0.2);
            color: var(--accent-green);
            border: 1px solid var(--accent-green);
        }
        
        .badge-orphaned {
            background: rgba(155, 89, 182, 0.2);
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
            border-radius: var(--radius-sm);
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
            background: var(--bg-surface);
            padding: 2px 8px;
            border-radius: 4px;
            margin: 2px;
        }
        
        /* Principal Card (new unified view) */
        .principal-card {
            background: var(--bg-surface);
            border: 1px solid var(--border-color);
            border-radius: var(--radius-md);
            margin-bottom: 12px;
            overflow: hidden;
        }
        
        .principal-card[data-risk="Critical"] {
            border-left: 4px solid var(--accent-red);
        }
        
        .principal-card[data-risk="High"] {
            border-left: 4px solid var(--accent-yellow);
        }
        
        .principal-card[data-risk="Medium"] {
            border-left: 4px solid var(--accent-blue);
        }
        
        .principal-card[data-risk="Low"] {
            border-left: 4px solid var(--accent-green);
        }
        
        .principal-header {
            padding: 16px 20px;
            display: flex;
            align-items: center;
            gap: 20px;
            cursor: pointer;
            user-select: none;
        }
        
        .principal-header:hover {
            background: var(--bg-hover);
        }
        
        .principal-info {
            display: flex;
            align-items: center;
            gap: 12px;
            min-width: 350px;
        }
        
        .principal-icon {
            font-size: 1.2rem;
        }
        
        .principal-name-block {
            display: flex;
            flex-direction: column;
            gap: 2px;
        }
        
        .principal-name {
            font-weight: 600;
            font-size: 1rem;
        }
        
        .principal-upn {
            font-size: 0.8rem;
            color: var(--text-muted);
        }
        
        .principal-summary {
            display: flex;
            gap: 20px;
            flex: 1;
            color: var(--text-secondary);
            font-size: 0.9rem;
        }
        
        .summary-item {
            display: flex;
            align-items: center;
            gap: 5px;
        }
        
        .toggle-icon {
            font-size: 0.8rem;
            color: var(--text-secondary);
            transition: transform 0.2s;
        }
        
        .principal-card.expanded .toggle-icon {
            transform: rotate(180deg);
        }
        
        .principal-details {
            padding: 0 20px 20px 20px;
            background: var(--bg-secondary);
        }
        
        .scope-table {
            width: 100%;
            font-size: 0.85rem;
        }
        
        .scope-table th {
            text-align: left;
            padding: 10px 12px;
            background: var(--bg-surface);
            font-weight: 600;
            color: var(--text-muted);
            text-transform: uppercase;
            font-size: 0.75rem;
        }
        
        .scope-table td {
            padding: 10px 12px;
            border-bottom: 1px solid var(--border-color);
        }
        
        .scope-type {
            display: inline-block;
            min-width: 60px;
        }
        
        .scope-name {
            margin-left: 5px;
        }
        
        .inheritance-badge {
            background: var(--bg-hover);
            padding: 2px 8px;
            border-radius: 4px;
            font-size: 0.8rem;
            color: var(--text-secondary);
        }
        
        /* Custom Role Card */
        .custom-role-card {
            background: var(--bg-surface);
            border: 1px solid var(--border-color);
            border-radius: var(--radius-md);
            margin-bottom: 12px;
            overflow: hidden;
        }
        
        .custom-role-header {
            padding: 16px 20px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            cursor: pointer;
            user-select: none;
        }
        
        .custom-role-header:hover {
            background: var(--bg-hover);
        }
        
        .custom-role-info {
            display: flex;
            align-items: center;
            gap: 15px;
            flex: 1;
        }
        
        .custom-role-name-block {
            display: flex;
            flex-direction: column;
            gap: 2px;
            flex: 1;
        }
        
        .custom-role-name {
            font-weight: 600;
            font-size: 1rem;
        }
        
        .custom-role-desc {
            font-size: 0.85rem;
            color: var(--text-secondary);
        }
        
        .custom-role-summary {
            display: flex;
            gap: 10px;
        }
        
        .custom-role-details {
            padding: 0 20px 20px 20px;
            background: var(--bg-secondary);
        }
        
        .custom-role-permissions,
        .custom-role-usage {
            margin-bottom: 20px;
        }
        
        .custom-role-permissions h4,
        .custom-role-usage h4 {
            margin: 0 0 10px 0;
            font-size: 0.95rem;
            color: var(--text-primary);
        }
        
        .permission-section {
            margin-bottom: 15px;
            padding: 10px;
            background: var(--bg-surface);
            border-radius: var(--radius-sm);
        }
        
        .permission-section strong {
            display: block;
            margin-bottom: 8px;
            color: var(--text-primary);
        }
        
        .permission-section ul {
            margin: 8px 0 0 20px;
            padding: 0;
        }
        
        .permission-section li {
            margin: 4px 0;
            font-size: 0.85rem;
        }
        
        .permission-section code {
            background: var(--bg-secondary);
            padding: 2px 6px;
            border-radius: 3px;
            font-family: 'Consolas', 'Monaco', monospace;
            font-size: 0.85rem;
            color: var(--accent-blue);
        }
        
        /* Principal View (for orphaned section) */
        .principal-view-row {
            background: var(--bg-secondary);
            border-radius: var(--radius-sm);
            margin-bottom: 10px;
            border-left: 4px solid var(--accent-blue);
        }
        
        .principal-view-header {
            padding: 15px;
            cursor: pointer;
            display: flex;
            justify-content: space-between;
            align-items: center;
            user-select: none;
        }
        
        .principal-view-header:hover {
            background: var(--bg-hover);
        }
        
        .principal-view-info {
            flex: 1;
            display: flex;
            align-items: center;
            gap: 15px;
        }
        
        .principal-view-name {
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        
        .principal-view-stats {
            display: flex;
            gap: 15px;
            font-size: 0.85rem;
            color: var(--text-secondary);
            margin-left: auto;
        }
        
        .principal-view-toggle {
            margin-left: 15px;
            font-size: 0.8rem;
            color: var(--text-secondary);
            transition: transform 0.2s;
        }
        
        .principal-view-row.expanded .principal-view-toggle {
            transform: rotate(180deg);
        }
        
        .principal-view-details {
            display: none;
            padding: 0 15px 15px 15px;
        }
        
        .principal-view-row.expanded .principal-view-details {
            display: block;
        }
        
        .principal-view-details table {
            margin-top: 10px;
            font-size: 0.85rem;
        }
        
        /* Risk indicator dots */
        .risk-dot {
            display: inline-block;
            width: 8px;
            height: 8px;
            border-radius: 50%;
            margin-right: 4px;
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
"@

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>RBAC/IAM Inventory Report</title>
    <style>
$(Get-ReportStylesheet)
$rbacSpecificStyles
    </style>
</head>
<body>
$(Get-ReportNavigation -ActivePage "RBAC")
    
    <div class="container">
        <div class="page-header">
            <h1>&#128272; RBAC/IAM Inventory Report</h1>
            <div class="metadata">
                <p><strong>Tenant:</strong> $displayTenantId</p>
                <p><strong>Generated:</strong> $timestamp</p>
                <p><strong>Subscriptions Scanned:</strong> $($metadata.SubscriptionsScanned)</p>
            </div>
        </div>
        
        <!-- Summary Cards -->
        <div class="summary-grid">
            <div class="summary-card">
                <div class="label">Principals</div>
                <div class="value value-neutral">$($stats.TotalPrincipals)</div>
                <div class="subtext">Unique principals</div>
            </div>
            <div class="summary-card">
                <div class="label">Critical Risk</div>
                <div class="value value-critical">$($stats.PrincipalsByRisk.Critical)</div>
                <div class="subtext">Principals with critical access</div>
            </div>
            <div class="summary-card">
                <div class="label">Orphaned</div>
                <div class="value value-critical">$($stats.OrphanedCount)</div>
                <div class="subtext">To clean up</div>
            </div>
            <div class="summary-card">
                <div class="label">External/Guest</div>
                <div class="value value-medium">$($stats.ExternalCount)</div>
                <div class="subtext">External identities</div>
            </div>
            <div class="summary-card">
                <div class="label">Custom Roles</div>
                <div class="value value-neutral">$($stats.CustomRoleCount)</div>
                <div class="subtext">Definitions</div>
            </div>
        </div>
        
        <!-- Risk Distribution -->
        <div class="summary-card" style="margin-bottom: 20px;">
            <div class="label">Risk Distribution</div>
            <div class="distribution-bar">
"@

    # Calculate percentages for distribution bar based on principals
    $total = [Math]::Max(1, $stats.TotalPrincipals)
    $criticalPct = [Math]::Round(($stats.PrincipalsByRisk.Critical / $total) * 100, 1)
    $highPct = [Math]::Round(($stats.PrincipalsByRisk.High / $total) * 100, 1)
    $mediumPct = [Math]::Round(($stats.PrincipalsByRisk.Medium / $total) * 100, 1)
    $lowPct = [Math]::Round(($stats.PrincipalsByRisk.Low / $total) * 100, 1)

    $html += @"
                <div class="distribution-segment segment-critical" style="width: $criticalPct%;" title="Critical: $($stats.PrincipalsByRisk.Critical)"></div>
                <div class="distribution-segment segment-high" style="width: $highPct%;" title="High: $($stats.PrincipalsByRisk.High)"></div>
                <div class="distribution-segment segment-medium" style="width: $mediumPct%;" title="Medium: $($stats.PrincipalsByRisk.Medium)"></div>
                <div class="distribution-segment segment-low" style="width: $lowPct%;" title="Low: $($stats.PrincipalsByRisk.Low)"></div>
            </div>
            <div class="subtext" style="margin-top: 8px;">
                <span style="color: var(--accent-red);"><span class="risk-dot" style="background: var(--accent-red);"></span> Critical: $($stats.PrincipalsByRisk.Critical)</span> |
                <span style="color: var(--accent-yellow);"><span class="risk-dot" style="background: var(--accent-yellow);"></span> High: $($stats.PrincipalsByRisk.High)</span> |
                <span style="color: var(--accent-blue);"><span class="risk-dot" style="background: var(--accent-blue);"></span> Medium: $($stats.PrincipalsByRisk.Medium)</span> |
                <span style="color: var(--accent-green);"><span class="risk-dot" style="background: var(--accent-green);"></span> Low: $($stats.PrincipalsByRisk.Low)</span>
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
                    <div class="risk-checkboxes">
                        <label class="checkbox-label">
                            <input type="checkbox" class="risk-checkbox" value="Critical" checked>
                            <span class="badge badge-critical">Critical</span>
                        </label>
                        <label class="checkbox-label">
                            <input type="checkbox" class="risk-checkbox" value="High" checked>
                            <span class="badge badge-high">High</span>
                        </label>
                        <label class="checkbox-label">
                            <input type="checkbox" class="risk-checkbox" value="Medium" checked>
                            <span class="badge badge-medium">Medium</span>
                        </label>
                        <label class="checkbox-label">
                            <input type="checkbox" class="risk-checkbox" value="Low" checked>
                            <span class="badge badge-low">Low</span>
                        </label>
                    </div>
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
                    Showing <span id="visibleCount">$($stats.TotalPrincipals)</span> of $($stats.TotalPrincipals) principals
                </div>
            </div>
        </div>
"@

    # Principal Access List Section (unified view)
    $html += @"
        
        <!-- Principal Access List -->
        <div class="section">
            <div class="section-header" onclick="toggleSection(this)">
                <div class="section-title">
                    &#128100; Principal Access List
                    <span class="section-count">$($principals.Count) principals</span>
                </div>
                <span class="section-toggle">&#9660;</span>
            </div>
            <div class="section-content">
                <p style="color: var(--text-secondary); margin-bottom: 15px;">
                    View all principals and their effective access. Click on any principal to expand and see detailed role assignments.
                </p>
"@

    foreach ($principal in $principals) {
        $icon = Get-PrincipalTypeIcon -Type $principal.PrincipalType
        $riskBadge = Get-RiskBadgeClass -Risk $principal.HighestRiskLevel
        $principalNameEncoded = Encode-Html $principal.PrincipalDisplayName
        $principalUpnEncoded = if ($principal.PrincipalUPN) { Encode-Html $principal.PrincipalUPN } else { "" }
        $safePrincipalId = "$($principal.PrincipalId)-$($principal.PrincipalType)" -replace '[^a-zA-Z0-9\-]', '-'
        $principalCardId = "principal-$safePrincipalId"
        
        # Build search data
        $rolesList = ($principal.Roles -join " ") -replace '<[^>]+>', ''
        $searchData = "$principalNameEncoded $principalUpnEncoded $rolesList".ToLower()
        $searchDataEncoded = Encode-Html $searchData
        
        # Build external badge if applicable
        $externalBadge = ""
        if ($principal.IsExternal) {
            $externalBadge = '<span class="badge badge-external">External</span>'
        }
        
        $html += @"
                <div class="principal-card" 
                     id="$principalCardId" 
                     data-risk="$($principal.HighestRiskLevel)" 
                     data-type="$($principal.PrincipalType)"
                     data-search="$searchDataEncoded">
                    <div class="principal-header" onclick="togglePrincipal(this)">
                        <div class="principal-info">
                            <span class="principal-icon">$icon</span>
                            <div class="principal-name-block">
                                <span class="principal-name">$principalNameEncoded</span>
                                $(if ($principalUpnEncoded) { "<span class='principal-upn'>$principalUpnEncoded</span>" })
                            </div>
                            <span class="badge badge-type">$($principal.PrincipalType)</span>
                            $externalBadge
                            <span class="badge $riskBadge risk-level-badge" data-original-risk="$($principal.HighestRiskLevel)">$($principal.HighestRiskLevel)</span>
                        </div>
                        <div class="principal-summary">
                            <span class="summary-item">&#128273; $($principal.Roles -join ', ')</span>
                            <span class="summary-item">&#128193; $($principal.ScopeCount) scopes</span>
                            <span class="summary-item">&#127760; $($principal.SubscriptionCount) subscriptions</span>
                        </div>
                        <span class="toggle-icon">&#9660;</span>
                    </div>
                    
                    <div class="principal-details" style="display: none;">
                        <table class="scope-table">
                            <thead>
                                <tr>
                                    <th>Risk</th>
                                    <th>Role</th>
                                    <th>Scope</th>
                                    <th>Applies To</th>
                                </tr>
                            </thead>
                            <tbody>
"@

        # Group scopes by type for better organization
        $scopesByType = $principal.Scopes | Group-Object ScopeType | Sort-Object @{ Expression = {
            switch ($_.Name) {
                'Root' { 0 }
                'ManagementGroup' { 1 }
                'Subscription' { 2 }
                'ResourceGroup' { 3 }
                'Resource' { 4 }
                default { 5 }
            }
        }}
        
        foreach ($scopeGroup in $scopesByType) {
            foreach ($scope in $scopeGroup.Group) {
                $scopeRiskBadge = Get-RiskBadgeClass -Risk $scope.RiskLevel
                $scopeIcon = Get-ScopeIcon -Type $scope.ScopeType
                $scopeDisplayEncoded = Encode-Html $scope.ScopeDisplayName
                $scopeEncoded = Encode-Html $scope.Scope
                $roleEncoded = Encode-Html $scope.Role
                
                # Build "Applies To" column
                $appliesTo = ""
                if ($scope.ScopeType -in @('Root', 'ManagementGroup')) {
                    if ($scope.InheritedBy -and $scope.InheritedBy.Count -gt 0) {
                        $inheritedList = ($scope.InheritedBy | Sort-Object) -join ", "
                        $inheritedListEncoded = Encode-Html $inheritedList
                        $count = $scope.InheritedBy.Count
                        $appliesTo = "<span class='inheritance-badge'>&rarr; $count subscription$(if($count -ne 1){'s'}): $inheritedListEncoded</span>"
                    } else {
                        $appliesTo = "<span class='inheritance-badge'>&rarr; All subscriptions</span>"
                    }
                } else {
                    # For subscription/RG/Resource scopes, show specific subscription
                    $appliesTo = Encode-Html ($scope.InheritedBy[0])
                }
                
                $html += @"
                                <tr class="assignment-row"
                                    data-search="$searchDataEncoded"
                                    data-risk="$($scope.RiskLevel)"
                                    data-type="$($principal.PrincipalType)"
                                    data-sub="">
                                    <td><span class="badge $scopeRiskBadge">$($scope.RiskLevel)</span></td>
                                    <td>$roleEncoded</td>
                                    <td>
                                        <span class="scope-type">$scopeIcon $($scope.ScopeType)</span>
                                        <span class="scope-name">$scopeDisplayEncoded</span>
                                        <div class="scope-path" style="font-size: 0.75rem; color: var(--text-muted); margin-top: 2px;">$scopeEncoded</div>
                                    </td>
                                    <td>$appliesTo</td>
                                </tr>
"@
            }
        }
        
        $html += @"
                            </tbody>
                        </table>
                    </div>
                </div>
"@
    }
        
    $html += @"
            </div>
        </div>
"@

    # Old Principal View section removed - now using unified Principal Access List above

    # Privileged Assignments section removed - now in unified Principal Access List above

    # Orphaned Assignments Section - Group by Principal ID
    $orphanedCount = $orphanedAssignments.Count
    if ($orphanedCount -gt 0) {
        # Group orphaned assignments by Principal ID
        $orphanedGroups = @{}
        foreach ($assignment in $orphanedAssignments) {
            $key = "$($assignment.PrincipalId)|$($assignment.PrincipalType)"
            if (-not $orphanedGroups.ContainsKey($key)) {
                $orphanedGroups[$key] = @{
                    PrincipalId = $assignment.PrincipalId
                    PrincipalType = $assignment.PrincipalType
                    PrincipalDisplayName = $assignment.PrincipalDisplayName
                    Assignments = [System.Collections.Generic.List[object]]::new()
                    Subscriptions = @()
                    Roles = @()
                    Scopes = @()
                }
            }
            
            $group = $orphanedGroups[$key]
            $group.Assignments.Add($assignment) | Out-Null
            
            if ($group.Subscriptions -notcontains $assignment.SubscriptionName) {
                $group.Subscriptions += $assignment.SubscriptionName
            }
            if ($group.Roles -notcontains $assignment.RoleDefinitionName) {
                $group.Roles += $assignment.RoleDefinitionName
            }
            if ($group.Scopes -notcontains $assignment.Scope) {
                $group.Scopes += $assignment.Scope
            }
        }
        
        $orphanedGroupList = $orphanedGroups.Values | 
            Sort-Object -Property @{ Expression = { $_.Assignments.Count } }, PrincipalId -Descending
        
        $html += @"

        <!-- Orphaned Assignments -->
        <div class="section">
            <div class="section-header" onclick="toggleSection(this)">
                <div class="section-title">
                    &#128123; Orphaned Assignments
                    <span class="section-count critical">$orphanedCount assignments ($($orphanedGroupList.Count) deleted principals)</span>
                </div>
                <span class="section-toggle">&#9660;</span>
            </div>
            <div class="section-content">
                <p style="color: var(--text-secondary); margin-bottom: 15px;">
                    Role assignments pointing to deleted principals. Grouped by Principal ID. Click to expand and see all assignments. These should be removed.
                </p>
"@

        foreach ($orphanedPrincipal in $orphanedGroupList) {
            $icon = Get-PrincipalTypeIcon -Type $orphanedPrincipal.PrincipalType
            $safePrincipalId = "$($orphanedPrincipal.PrincipalId)-$($orphanedPrincipal.PrincipalType)" -replace '[^a-zA-Z0-9\-]', '-'
            $orphanedPrincipalId = "orphaned-$safePrincipalId"
            
            $assignmentText = if ($orphanedPrincipal.Assignments.Count -eq 1) { "assignment" } else { "assignments" }
            $subscriptionText = if ($orphanedPrincipal.Subscriptions.Count -eq 1) { "subscription" } else { "subscriptions" }
            $roleText = if ($orphanedPrincipal.Roles.Count -eq 1) { "role" } else { "roles" }
            
            $principalIdEncoded = Encode-Html $orphanedPrincipal.PrincipalId
            $principalNameEncoded = Encode-Html $orphanedPrincipal.PrincipalDisplayName
            
            $rolesList = ($orphanedPrincipal.Roles | Sort-Object) -join ", "
            $rolesListEncoded = Encode-Html $rolesList
            
            $subscriptionsList = ($orphanedPrincipal.Subscriptions | Sort-Object) -join ", "
            $subscriptionsListEncoded = Encode-Html $subscriptionsList
            
            $html += @"
                <div class="principal-view-row" id="$orphanedPrincipalId" style="border-left-color: var(--accent-purple);">
                    <div class="principal-view-header" data-principal-id="$orphanedPrincipalId" onclick="togglePrincipalDetails(this)">
                        <div class="principal-view-info">
                            <div class="principal-view-name">
                                $icon $principalNameEncoded
                                <span class="badge badge-orphaned">$($orphanedPrincipal.PrincipalType)</span>
                            </div>
                            <div class="principal-view-stats">
                                <span>&#128273; $($orphanedPrincipal.Assignments.Count) $assignmentText</span>
                                <span>&#128193; $($orphanedPrincipal.Subscriptions.Count) $subscriptionText</span>
                                <span>&#128203; $($orphanedPrincipal.Roles.Count) $roleText</span>
                            </div>
                        </div>
                        <span class="principal-view-toggle">&#9660;</span>
                    </div>
                    <div class="principal-view-details">
                        <div style="color: var(--text-secondary); margin-bottom: 10px; font-size: 0.85rem;">
                            <strong>Principal ID:</strong> <code style="color: var(--accent-purple);">$principalIdEncoded</code>
                        </div>
                        <div style="color: var(--text-secondary); margin-bottom: 10px; font-size: 0.85rem;">
                            <strong>Subscriptions:</strong> $subscriptionsListEncoded
                        </div>
                        <div style="color: var(--text-secondary); margin-bottom: 15px; font-size: 0.85rem;">
                            <strong>Roles:</strong> $rolesListEncoded
                        </div>
                        <div class="table-container">
                            <table>
                                <thead>
                                    <tr>
                                        <th>Role</th>
                                        <th>Scope Type</th>
                                        <th>Scope</th>
                                        <th>Subscription</th>
                                    </tr>
                                </thead>
                                <tbody>
"@
            
            foreach ($assignment in ($orphanedPrincipal.Assignments | Sort-Object -Property SubscriptionName, RoleDefinitionName, Scope)) {
                $scopeIcon = Get-ScopeIcon -Type $assignment.ScopeType
                $roleNameEncoded = Encode-Html $assignment.RoleDefinitionName
                $scopeEncoded = Encode-Html $assignment.Scope
                $subNameEncoded = Encode-Html $assignment.SubscriptionName
                $principalIdForSearch = ($orphanedPrincipal.PrincipalId -replace '<[^>]+>', '').ToLower()
                $principalNameForSearch = ($orphanedPrincipal.PrincipalDisplayName -replace '<[^>]+>', '').ToLower()
                $searchData = "$principalIdForSearch $principalNameForSearch $($assignment.RoleDefinitionName) $($assignment.Scope) $($assignment.SubscriptionName)".ToLower()
                $searchDataEncoded = Encode-Html $searchData
                
                $html += @"
                                    <tr class="assignment-row"
                                        data-search="$searchDataEncoded"
                                        data-risk="Critical"
                                        data-type="$($orphanedPrincipal.PrincipalType)"
                                        data-sub="$(Encode-Html $assignment.SubscriptionName)">
                                        <td>$roleNameEncoded</td>
                                        <td>$scopeIcon $($assignment.ScopeType)</td>
                                        <td class="scope-cell">
                                            <div class="scope-path">$scopeEncoded</div>
                                        </td>
                                        <td>$(
                                            if ($assignment.ScopeType -in @('ManagementGroup', 'Root')) {
                                                '<span style="color: var(--text-muted); font-style: italic;">N/A</span>'
                                            } else {
                                                $subNameEncoded
                                            }
                                        )</td>
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
        
        $html += @"
            </div>
        </div>
"@
    }

    # Non-Human Identities section removed - use Principal Access List filter by type instead
    # Role Usage Analysis section removed - not needed in new design

    # Custom Roles Section (Enhanced with expandable details)
    if ($customRoles.Count -gt 0) {
        $html += @"

        <!-- Custom Role Definitions -->
        <div class="section collapsed">
            <div class="section-header" onclick="toggleSection(this)">
                <div class="section-title">
                    &#127912; Custom Role Definitions
                    <span class="section-count">$($customRoles.Count)</span>
                </div>
                <span class="section-toggle">&#9660;</span>
            </div>
            <div class="section-content">
                <p style="color: var(--text-secondary); margin-bottom: 15px;">
                    Tenant-specific custom roles. Click on any role to expand and see detailed permissions and usage.
                </p>
"@

        foreach ($role in $customRoles) {
            $actionsCount = if ($role.Actions) { $role.Actions.Count } else { 0 }
            $dataActionsCount = if ($role.DataActions) { $role.DataActions.Count } else { 0 }
            $notActionsCount = if ($role.NotActions) { $role.NotActions.Count } else { 0 }
            $notDataActionsCount = if ($role.NotDataActions) { $role.NotDataActions.Count } else { 0 }
            $assignmentCount = if ($role.AssignmentCount) { $role.AssignmentCount } else { 0 }
            $safeRoleId = ($role.Id -replace '[^a-zA-Z0-9\-]', '-')
            $roleCardId = "role-$safeRoleId"
            
            $roleNameEncoded = Encode-Html $role.Name
            $roleDescEncoded = Encode-Html $role.Description
            
            $html += @"
                <div class="custom-role-card" id="$roleCardId">
                    <div class="custom-role-header" onclick="toggleCustomRole(this)">
                        <div class="custom-role-info">
                            <div class="custom-role-name-block">
                                <span class="custom-role-name">$roleNameEncoded</span>
                                $(if ($roleDescEncoded) { "<span class='custom-role-desc'>$roleDescEncoded</span>" })
                            </div>
                            <div class="custom-role-summary">
                                <span class="badge badge-type">$actionsCount Actions</span>
                                <span class="badge badge-type">$dataActionsCount Data Actions</span>
                                <span class="badge badge-$(if ($assignmentCount -gt 0) { 'critical' } else { 'low' })">$assignmentCount Assignments</span>
                            </div>
                        </div>
                        <span class="toggle-icon">&#9660;</span>
                    </div>
                    <div class="custom-role-details" style="display: none;">
                        <div class="custom-role-permissions">
                            <h4>Permissions</h4>
                            $(if ($role.Actions -and $role.Actions.Count -gt 0) {
                                "<div class='permission-section'><strong>Actions ($($role.Actions.Count)):</strong><ul>" + 
                                (($role.Actions | ForEach-Object { "<li><code>$(Encode-Html $_)</code></li>" }) -join '') + 
                                "</ul></div>"
                            } else {
                                "<div class='permission-section'><em>No Actions defined</em></div>"
                            })
                            $(if ($role.DataActions -and $role.DataActions.Count -gt 0) {
                                "<div class='permission-section'><strong>Data Actions ($($role.DataActions.Count)):</strong><ul>" + 
                                (($role.DataActions | ForEach-Object { "<li><code>$(Encode-Html $_)</code></li>" }) -join '') + 
                                "</ul></div>"
                            } else {
                                "<div class='permission-section'><em>No Data Actions defined</em></div>"
                            })
                            $(if ($role.NotActions -and $role.NotActions.Count -gt 0) {
                                "<div class='permission-section'><strong>Not Actions ($($role.NotActions.Count)):</strong><ul>" + 
                                (($role.NotActions | ForEach-Object { "<li><code>$(Encode-Html $_)</code></li>" }) -join '') + 
                                "</ul></div>"
                            })
                            $(if ($role.NotDataActions -and $role.NotDataActions.Count -gt 0) {
                                "<div class='permission-section'><strong>Not Data Actions ($($role.NotDataActions.Count)):</strong><ul>" + 
                                (($role.NotDataActions | ForEach-Object { "<li><code>$(Encode-Html $_)</code></li>" }) -join '') + 
                                "</ul></div>"
                            })
                            $(if ($role.AssignableScopes -and $role.AssignableScopes.Count -gt 0) {
                                "<div class='permission-section'><strong>Assignable Scopes ($($role.AssignableScopes.Count)):</strong><ul>" + 
                                (($role.AssignableScopes | ForEach-Object { "<li><code>$(Encode-Html $_)</code></li>" }) -join '') + 
                                "</ul></div>"
                            })
                        </div>
                        $(if ($assignmentCount -gt 0) {
                            $usedByList = if ($role.UsedByPrincipals) { 
                                ($role.UsedByPrincipals | ForEach-Object { "<li>$(Encode-Html $_)</li>" }) -join '' 
                            } else { "" }
                            $assignedScopesList = if ($role.AssignedScopes) { 
                                ($role.AssignedScopes | ForEach-Object { "<li>$(Encode-Html $_)</li>" }) -join '' 
                            } else { "" }
                            "<div class='custom-role-usage'><h4>Usage</h4><div class='permission-section'><strong>Assignment Count:</strong> $assignmentCount</div>" +
                            $(if ($usedByList) { "<div class='permission-section'><strong>Used By Principals:</strong><ul>$usedByList</ul></div>" }) +
                            $(if ($assignedScopesList) { "<div class='permission-section'><strong>Assigned At Scope Types:</strong><ul>$assignedScopesList</ul></div>" }) +
                            "</div>"
                        } else {
                            "<div class='custom-role-usage'><em>This role is not currently assigned to any principals.</em></div>"
                        })
                    </div>
                </div>
"@
        }

        $html += @"
            </div>
        </div>
"@
    }

    # All Role Assignments section removed - replaced by unified Principal Access List
    
    $html += @"
    </div>
    
    <script>
        // Toggle section expand/collapse
        function toggleSection(header) {
            const section = header.parentElement;
            section.classList.toggle('collapsed');
        }
        
        // Toggle principal card (new unified view)
        function togglePrincipal(header) {
            const card = header.parentElement;
            const details = card.querySelector('.principal-details');
            const icon = header.querySelector('.toggle-icon');
            
            if (details.style.display === 'none' || !details.style.display) {
                details.style.display = 'block';
                card.classList.add('expanded');
                icon.textContent = '▲';
            } else {
                details.style.display = 'none';
                card.classList.remove('expanded');
                icon.textContent = '▼';
            }
        }
        
        // Toggle custom role card
        function toggleCustomRole(header) {
            const card = header.parentElement;
            const details = card.querySelector('.custom-role-details');
            const icon = header.querySelector('.toggle-icon');
            
            if (details.style.display === 'none' || !details.style.display) {
                details.style.display = 'block';
                card.classList.add('expanded');
                icon.textContent = '▲';
            } else {
                details.style.display = 'none';
                card.classList.remove('expanded');
                icon.textContent = '▼';
            }
        }
        
        // Toggle principal details (for orphaned section)
        function togglePrincipalDetails(principalIdOrElement) {
            let principalId;
            if (typeof principalIdOrElement === 'string') {
                principalId = principalIdOrElement;
            } else {
                // If called with element, get ID from dataset
                const header = principalIdOrElement;
                principalId = header.dataset.principalId;
            }
            const row = document.getElementById(principalId);
            if (row) {
                row.classList.toggle('expanded');
            }
        }
        
        // Filtering logic
        const searchInput = document.getElementById('searchInput');
        const riskCheckboxes = document.querySelectorAll('.risk-checkbox');
        const typeFilter = document.getElementById('typeFilter');
        const subFilter = document.getElementById('subFilter');
        const visibleCount = document.getElementById('visibleCount');
        
        function getSelectedRiskLevels() {
            const selected = [];
            riskCheckboxes.forEach(checkbox => {
                if (checkbox.checked) {
                    selected.push(checkbox.value);
                }
            });
            return selected;
        }
        
        function applyFilters() {
            const searchTerm = searchInput.value.toLowerCase();
            const selectedRisks = getSelectedRiskLevels();
            const typeValue = typeFilter.value;
            const subValue = subFilter.value;
            
            // Filter principal cards
            const cards = document.querySelectorAll('.principal-card');
            let visible = 0;
            
            cards.forEach(card => {
                const matchesSearch = !searchTerm || card.dataset.search.includes(searchTerm);
                const matchesType = !typeValue || card.dataset.type === typeValue;
                const matchesRisk = selectedRisks.length === 0 || selectedRisks.includes(card.dataset.risk);
                
                if (matchesSearch && matchesType && matchesRisk) {
                    card.style.display = 'block';
                    visible++;
                    
                    // Update risk badge based on visible assignments within this card
                    const visibleRows = card.querySelectorAll('.assignment-row:not([style*="display: none"])');
                    if (visibleRows.length > 0) {
                        const risks = Array.from(visibleRows).map(row => row.dataset.risk);
                        const riskOrder = { 'Critical': 0, 'High': 1, 'Medium': 2, 'Low': 3 };
                        const highestRisk = risks.sort((a, b) => riskOrder[a] - riskOrder[b])[0];
                        const badge = card.querySelector('.risk-level-badge');
                        if (badge && badge.dataset.originalRisk !== highestRisk) {
                            badge.className = 'badge badge-' + highestRisk.toLowerCase() + ' risk-level-badge';
                            badge.textContent = highestRisk;
                        }
                    }
                } else {
                    card.style.display = 'none';
                }
            });
            
            // Also filter assignment rows (for nested tables in orphaned section, etc.)
            const rows = document.querySelectorAll('.assignment-row');
            
            rows.forEach(row => {
                const matchesSearch = !searchTerm || row.dataset.search.includes(searchTerm);
                const matchesRisk = selectedRisks.length === 0 || selectedRisks.includes(row.dataset.risk);
                const matchesType = !typeValue || row.dataset.type === typeValue;
                const matchesSub = !subValue || row.dataset.sub === subValue;
                
                if (matchesSearch && matchesRisk && matchesType && matchesSub) {
                    row.classList.remove('filtered-out');
                    visible++;
                } else {
                    row.classList.add('filtered-out');
                }
            });
            
            // Risk level priority for sorting (lower = higher priority)
            function getRiskPriority(risk) {
                switch(risk) {
                    case 'Critical': return 0;
                    case 'High': return 1;
                    case 'Medium': return 2;
                    case 'Low': return 3;
                    default: return 4;
                }
            }
            
            function getRiskClass(risk) {
                switch(risk) {
                    case 'Critical': return 'badge-critical';
                    case 'High': return 'badge-high';
                    case 'Medium': return 'badge-medium';
                    case 'Low': return 'badge-low';
                    default: return 'badge-low';
                }
            }
            
            // Hide/show parent principal-view-row cards and update risk badges based on visible assignments
            const principalRows = document.querySelectorAll('.principal-view-row');
            principalRows.forEach(principalRow => {
                const childRows = principalRow.querySelectorAll('.assignment-row');
                const visibleChildRows = Array.from(childRows).filter(row => !row.classList.contains('filtered-out'));
                
                if (visibleChildRows.length === 0 && childRows.length > 0) {
                    // All child rows are filtered out, hide the parent card
                    principalRow.style.display = 'none';
                } else {
                    // Show the parent card if it has visible child rows or no child rows (for cards without nested tables)
                    principalRow.style.display = '';
                    
                    // Update risk badge in header based on visible assignments
                    if (visibleChildRows.length > 0) {
                        // Find highest risk level among visible assignments
                        const visibleRisks = visibleChildRows.map(row => row.dataset.risk).filter(r => r);
                        if (visibleRisks.length > 0) {
                            visibleRisks.sort((a, b) => getRiskPriority(a) - getRiskPriority(b));
                            const highestVisibleRisk = visibleRisks[0];
                            
                            // Update the risk badge in the header
                            const header = principalRow.querySelector('.principal-view-header');
                            if (header) {
                                // Find the risk level badge specifically
                                const riskBadge = header.querySelector('.risk-level-badge');
                                if (riskBadge) {
                                    // Update class and text
                                    riskBadge.className = 'badge ' + getRiskClass(highestVisibleRisk) + ' risk-level-badge';
                                    riskBadge.textContent = highestVisibleRisk;
                                }
                            }
                        }
                    }
                }
            });
            
            // Also update subscription-level risk badges in cross-sub section
            document.querySelectorAll('.principal-view-details > div[style*="margin-bottom: 20px"]').forEach(subSection => {
                const subTable = subSection.querySelector('table');
                if (subTable) {
                    const visibleSubRows = Array.from(subTable.querySelectorAll('.assignment-row')).filter(row => !row.classList.contains('filtered-out'));
                    if (visibleSubRows.length > 0) {
                        const visibleSubRisks = visibleSubRows.map(row => row.dataset.risk).filter(r => r);
                        if (visibleSubRisks.length > 0) {
                            visibleSubRisks.sort((a, b) => getRiskPriority(a) - getRiskPriority(b));
                            const highestSubRisk = visibleSubRisks[0];
                            
                            // Update the subscription-level risk badge
                            const subRiskBadge = subSection.querySelector('.subscription-risk-badge');
                            if (subRiskBadge) {
                                subRiskBadge.className = 'badge ' + getRiskClass(highestSubRisk) + ' subscription-risk-badge';
                                subRiskBadge.textContent = highestSubRisk;
                            }
                        }
                    }
                }
            });
            
            // Update visible count for principal cards
            visibleCount.textContent = visible;
        }
        
        searchInput.addEventListener('input', applyFilters);
        riskCheckboxes.forEach(checkbox => {
            checkbox.addEventListener('change', applyFilters);
        });
        typeFilter.addEventListener('change', applyFilters);
        subFilter.addEventListener('change', applyFilters);
    </script>
</body>
</html>
"@

    #endregion

    # Write output
    [System.IO.File]::WriteAllText($OutputPath, $html, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Report generated: $OutputPath" -ForegroundColor Green

    return $OutputPath
}

