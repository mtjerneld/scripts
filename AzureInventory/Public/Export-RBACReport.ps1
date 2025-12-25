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
    $displayTenantId = if ($TenantId -ne "Unknown") { $TenantId } else { $metadata.TenantId }

    # Pre-calculate subscription options for filter
    $subscriptionOptions = $RBACData.RoleAssignments | 
        Select-Object -ExpandProperty SubscriptionName -Unique | 
        Sort-Object |
        ForEach-Object { 
            $encoded = Encode-Html $_
            "<option value=`"$encoded`">$encoded</option>" 
        }

    # Group assignments by principal for Principal View
    $riskOrder = @{ "Critical" = 4; "High" = 3; "Medium" = 2; "Low" = 1 }
    $principalGroups = @{}
    foreach ($assignment in $RBACData.RoleAssignments) {
        # Use PrincipalId (not PrincipalObjectId) and include UPN in key for uniqueness
        # This ensures users with same display name but different UPNs are separated
        $principalId = $assignment.PrincipalId
        $principalUpn = if ($assignment.PrincipalUPN) { $assignment.PrincipalUPN } else { "" }
        $key = "$principalId|$($assignment.PrincipalType)|$principalUpn"
        
        if (-not $principalGroups.ContainsKey($key)) {
            # Initialize principal group
            $principalGroups[$key] = @{
                PrincipalId = $principalId
                PrincipalType = $assignment.PrincipalType
                PrincipalDisplayName = $assignment.PrincipalDisplayName
                PrincipalUPN = $assignment.PrincipalUPN
                Assignments = [System.Collections.Generic.List[object]]::new()
                Subscriptions = @()
                Roles = @()
                HighestRiskLevel = "Low"
                IsOrphaned = $false
                IsExternal = $false
            }
        }
        
        $group = $principalGroups[$key]
        $group.Assignments.Add($assignment) | Out-Null
        
        # Add unique subscription
        if ($group.Subscriptions -notcontains $assignment.SubscriptionName) {
            $group.Subscriptions += $assignment.SubscriptionName
        }
        
        # Add unique role
        if ($group.Roles -notcontains $assignment.RoleDefinitionName) {
            $group.Roles += $assignment.RoleDefinitionName
        }
        
        # Update highest risk level
        if ($riskOrder[$assignment.RiskLevel] -gt $riskOrder[$group.HighestRiskLevel]) {
            $group.HighestRiskLevel = $assignment.RiskLevel
        }
        
        if ($assignment.IsOrphaned) { $group.IsOrphaned = $true }
        if ($assignment.IsExternal) { $group.IsExternal = $true }
    }
    
    # Convert to sorted array for display
    $principalViewList = $principalGroups.Values | 
        Sort-Object -Property @{ Expression = { $riskOrder[$_.HighestRiskLevel] }; Descending = $true }, PrincipalDisplayName

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
        
        /* Principal View */
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
                <span style="color: var(--accent-red);"><span class="risk-dot" style="background: var(--accent-red);"></span> Critical: $($stats.ByRiskLevel.Critical)</span> |
                <span style="color: var(--accent-yellow);"><span class="risk-dot" style="background: var(--accent-yellow);"></span> High: $($stats.ByRiskLevel.High)</span> |
                <span style="color: var(--accent-blue);"><span class="risk-dot" style="background: var(--accent-blue);"></span> Medium: $($stats.ByRiskLevel.Medium)</span> |
                <span style="color: var(--accent-green);"><span class="risk-dot" style="background: var(--accent-green);"></span> Low: $($stats.ByRiskLevel.Low)</span>
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
                    &#127760; Cross-Subscription Access
                    <span class="section-count warning">$crossSubCount principals</span>
                </div>
                <span class="section-toggle">&#9660;</span>
            </div>
            <div class="section-content">
                <p style="color: var(--text-secondary); margin-bottom: 15px;">
                    Principals with access to multiple subscriptions. Review for least-privilege compliance.
                </p>
"@
        
        foreach ($principal in $RBACData.Analysis.CrossSubscriptionPrincipals | Select-Object -First 20) {
            $icon = Get-PrincipalTypeIcon -Type $principal.PrincipalType
            $riskBadge = Get-RiskBadgeClass -Risk $principal.HighestRiskLevel
            $principalNameEncoded = Encode-Html $principal.PrincipalDisplayName
            $principalUpnEncoded = if ($principal.PrincipalUPN) { Encode-Html $principal.PrincipalUPN } else { "" }
            $safePrincipalId = "$($principal.PrincipalId)-$($principal.PrincipalType)" -replace '[^a-zA-Z0-9\-]', '-'
            $crossSubPrincipalId = "crosssub-$safePrincipalId"
            
            # Group assignments by subscription for detailed view
            $assignmentsBySub = $principal.Assignments | Group-Object SubscriptionName | Sort-Object Name
            
            $html += @"
                <div class="principal-view-row" id="$crossSubPrincipalId" style="border-left-color: var(--accent-purple);">
                    <div class="principal-view-header" data-principal-id="$crossSubPrincipalId" onclick="togglePrincipalDetails(this)">
                        <div class="principal-view-info">
                            <div class="principal-view-name">
                                $icon $principalNameEncoded
                                $(if ($principalUpnEncoded) { "<div style='font-size: 0.85rem; color: var(--text-secondary); font-weight: normal; margin-top: 2px;'>$principalUpnEncoded</div>" })
                                <span class="badge badge-type">$($principal.PrincipalType)</span>
                                <span class="badge $riskBadge risk-level-badge" data-original-risk="$($principal.HighestRiskLevel)">$($principal.HighestRiskLevel)</span>
                            </div>
                            <div class="principal-view-stats">
                                <span>&#128193; $($principal.SubscriptionCount) subscriptions</span>
                                <span>&#128273; $($principal.AssignmentCount) assignments</span>
                                <span>&#128203; $($principal.Roles.Count) unique roles</span>
                            </div>
                        </div>
                        <span class="principal-view-toggle">&#9660;</span>
                    </div>
                    <div class="principal-view-details">
                        <p style="color: var(--text-secondary); margin-bottom: 15px; font-size: 0.9rem;">
                            Detailed role assignments per subscription:
                        </p>
"@
            
            # Show breakdown by subscription
            foreach ($subGroup in $assignmentsBySub) {
                $subName = $subGroup.Name
                $subAssignments = $subGroup.Group | Sort-Object -Property RiskLevel, RoleDefinitionName
                $subRoles = ($subAssignments | Select-Object -ExpandProperty RoleDefinitionName -Unique) -join ", "
                $subRolesEncoded = Encode-Html $subRoles
                $subNameEncoded = Encode-Html $subName
                $subHighestRisk = ($subAssignments | Sort-Object { 
                    switch ($_.RiskLevel) { 'Critical' { 0 } 'High' { 1 } 'Medium' { 2 } 'Low' { 3 } }
                } | Select-Object -First 1).RiskLevel
                $subRiskBadge = Get-RiskBadgeClass -Risk $subHighestRisk
                
                $html += @"
                        <div style="margin-bottom: 20px; padding: 12px; background: var(--bg-surface); border-radius: var(--radius-sm); border-left: 3px solid var(--accent-purple);">
                            <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px;">
                                <div style="font-weight: 600; font-size: 1rem;">&#128193; $subNameEncoded</div>
                                <span class="badge $subRiskBadge subscription-risk-badge" data-original-risk="$subHighestRisk">$subHighestRisk</span>
                            </div>
                            <div style="color: var(--text-secondary); margin-bottom: 10px; font-size: 0.85rem;">
                                <strong>Roles ($($subAssignments.Count) assignments):</strong> $subRolesEncoded
                            </div>
                            <div class="table-container">
                                <table>
                                    <thead>
                                        <tr>
                                            <th>Risk</th>
                                            <th>Role</th>
                                            <th>Scope Type</th>
                                            <th>Scope</th>
                                        </tr>
                                    </thead>
                                    <tbody>
"@
                
                foreach ($assignment in $subAssignments) {
                    $assignmentRiskBadge = Get-RiskBadgeClass -Risk $assignment.RiskLevel
                    $scopeIcon = Get-ScopeIcon -Type $assignment.ScopeType
                    $roleNameEncoded = Encode-Html $assignment.RoleDefinitionName
                    $scopeEncoded = Encode-Html $assignment.Scope
                    $searchData = "$principalNameEncoded $roleNameEncoded $scopeEncoded $subName".ToLower()
                    $searchDataEncoded = Encode-Html $searchData
                    
                    $html += @"
                                        <tr class="assignment-row"
                                            data-search="$searchDataEncoded"
                                            data-risk="$($assignment.RiskLevel)"
                                            data-type="$($principal.PrincipalType)"
                                            data-sub="$subNameEncoded">
                                            <td><span class="badge $assignmentRiskBadge">$($assignment.RiskLevel)</span></td>
                                            <td>$roleNameEncoded</td>
                                            <td>$scopeIcon $($assignment.ScopeType)</td>
                                            <td class="scope-cell">
                                                <div class="scope-path">$scopeEncoded</div>
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
            
            $html += @"
                    </div>
                </div>
"@
        }
        
        $html += @"
            </div>
        </div>
"@
    }

    # Principal View Section (grouped by user/principal)
    $principalViewCount = $principalViewList.Count
    $html += @"
    
        <!-- Principal View -->
        <div class="section">
            <div class="section-header" onclick="toggleSection(this)">
                <div class="section-title">
                    &#128100; Principal View
                    <span class="section-count">$principalViewCount principals</span>
                </div>
                <span class="section-toggle">&#9660;</span>
            </div>
            <div class="section-content">
                <p style="color: var(--text-secondary); margin-bottom: 15px;">
                    View all access grouped by principal. Click on any principal to expand and see their detailed role assignments.
                </p>
"@

    foreach ($principal in $principalViewList) {
        $icon = Get-PrincipalTypeIcon -Type $principal.PrincipalType
        $riskBadge = Get-RiskBadgeClass -Risk $principal.HighestRiskLevel
        $safePrincipalId = "$($principal.PrincipalId)-$($principal.PrincipalType)" -replace '[^a-zA-Z0-9\-]', '-'
        $principalId = "principal-$safePrincipalId"
        
        $extraBadges = ""
        if ($principal.IsOrphaned) { $extraBadges += '<span class="badge badge-orphaned">Orphaned</span> ' }
        if ($principal.IsExternal) { $extraBadges += '<span class="badge badge-external">External</span> ' }
        
        $assignmentText = if ($principal.Assignments.Count -eq 1) { "assignment" } else { "assignments" }
        $subscriptionText = if ($principal.Subscriptions.Count -eq 1) { "subscription" } else { "subscriptions" }
        $roleText = if ($principal.Roles.Count -eq 1) { "role" } else { "roles" }
        
        # Build UPN div if exists
        $upnDiv = ""
        if ($principal.PrincipalUPN) {
            $upnEncoded = Encode-Html $principal.PrincipalUPN
            $upnDiv = "<div style='color: var(--text-secondary); margin-bottom: 10px; font-size: 0.85rem;'>UPN: $upnEncoded</div>"
        }
        
        $subscriptionsList = ($principal.Subscriptions | Sort-Object) -join ", "
        $subscriptionsListEncoded = Encode-Html $subscriptionsList
        
        $rolesList = ($principal.Roles | Sort-Object) -join ", "
        $rolesListEncoded = Encode-Html $rolesList
        
        $principalNameEncoded = Encode-Html $principal.PrincipalDisplayName
        
        $html += @"
                <div class="principal-view-row" id="$principalId">
                    <div class="principal-view-header" data-principal-id="$principalId" onclick="togglePrincipalDetails(this)">
                        <div class="principal-view-info">
                            <div class="principal-view-name">
                                $icon $principalNameEncoded
                                <span class="badge badge-type">$($principal.PrincipalType)</span>
                                $extraBadges
                                <span class="badge $riskBadge risk-level-badge" data-original-risk="$($principal.HighestRiskLevel)">$($principal.HighestRiskLevel)</span>
                            </div>
                            <div class="principal-view-stats">
                                <span>&#128273; $($principal.Assignments.Count) $assignmentText</span>
                                <span>&#128193; $($principal.Subscriptions.Count) $subscriptionText</span>
                                <span>&#128203; $($principal.Roles.Count) $roleText</span>
                            </div>
                        </div>
                        <span class="principal-view-toggle">&#9660;</span>
                    </div>
                    <div class="principal-view-details">
                        $upnDiv
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
                                        <th>Risk</th>
                                        <th>Role</th>
                                        <th>Type</th>
                                        <th>Scope Type</th>
                                        <th>Scope</th>
                                        <th>Subscription<sup style="font-size: 0.7em; color: var(--text-muted);" title="Not applicable for Management Group or Root scope assignments">*</sup></th>
                                    </tr>
                                </thead>
                                <tbody>
"@
        
        # Group assignments for Root/MG to show once with all affected subscriptions
        # Track which subscriptions are covered by MG/Root assignments to avoid duplicates
        $mgRootAssignments = @{}
        $subscriptionAssignments = @()
        $coveredByMgRoot = @{}  # Track (SubscriptionName, Role) combinations covered by MG/Root
        
        foreach ($assignment in $principal.Assignments) {
            if ($assignment.ScopeType -in @('ManagementGroup', 'Root')) {
                # Group by Scope + Role for MG/Root assignments
                $key = "$($assignment.Scope)|$($assignment.RoleDefinitionName)"
                if (-not $mgRootAssignments.ContainsKey($key)) {
                    $mgRootAssignments[$key] = @{
                        Assignment = $assignment
                        AffectedSubscriptions = [System.Collections.Generic.List[string]]::new()
                    }
                }
                # Add subscription name - for MG/Root assignments, each subscription context gives us one subscription
                # We collect all unique subscription names where this assignment is effective
                if ($mgRootAssignments[$key].AffectedSubscriptions -notcontains $assignment.SubscriptionName) {
                    $mgRootAssignments[$key].AffectedSubscriptions.Add($assignment.SubscriptionName) | Out-Null
                }
                # Mark this subscription+role as covered by MG/Root assignment
                $coveredKey = "$($assignment.SubscriptionName)|$($assignment.RoleDefinitionName)"
                $coveredByMgRoot[$coveredKey] = $true
            } else {
                # Subscription-level assignments - show all of them
                # The IsInherited flag tells us if it was assigned at subscription level (false) or inherited from parent (true)
                # We show all subscription-level assignments, whether direct or inherited
                $subscriptionAssignments += $assignment
            }
        }
        
        # Sort subscriptions alphabetically for display
        foreach ($key in $mgRootAssignments.Keys) {
            $mgRootAssignments[$key].AffectedSubscriptions = $mgRootAssignments[$key].AffectedSubscriptions | Sort-Object
        }
        
        # Display MG/Root assignments first (one row per unique scope+role with all subscriptions)
        foreach ($key in ($mgRootAssignments.Keys | Sort-Object)) {
            $mgAssignment = $mgRootAssignments[$key]
            $assignment = $mgAssignment.Assignment
            $assignmentRiskBadge = Get-RiskBadgeClass -Risk $assignment.RiskLevel
            $scopeIcon = Get-ScopeIcon -Type $assignment.ScopeType
            $roleNameEncoded = Encode-Html $assignment.RoleDefinitionName
            $scopeEncoded = Encode-Html $assignment.Scope
            $principalNameForSearch = ($principal.PrincipalDisplayName -replace '<[^>]+>', '').ToLower()
            
            # For Root/MG assignments, mark as "Assigned" at that level (not inherited)
            $assignmentType = "Assigned"
            $assignmentTypeBadge = "badge-low"
            
            # Build list of affected subscriptions
            $subscriptionsList = ($mgAssignment.AffectedSubscriptions | Sort-Object) -join ", "
            $subscriptionsListEncoded = Encode-Html $subscriptionsList
            $searchData = "$principalNameForSearch $($assignment.RoleDefinitionName) $($assignment.Scope) $subscriptionsList".ToLower()
            $searchDataEncoded = Encode-Html $searchData
            
            # Get highest risk for this assignment
            $highestRisk = $assignment.RiskLevel
            
            $html += @"
                                    <tr class="assignment-row"
                                        data-search="$searchDataEncoded"
                                        data-risk="$highestRisk"
                                        data-type="$($principal.PrincipalType)"
                                        data-sub="$subscriptionsListEncoded">
                                        <td><span class="badge $assignmentRiskBadge">$highestRisk</span></td>
                                        <td>$roleNameEncoded</td>
                                        <td><span class="badge $assignmentTypeBadge" title="$assignmentType">$assignmentType</span></td>
                                        <td>$scopeIcon $($assignment.ScopeType)</td>
                                        <td class="scope-cell">
                                            <div class="scope-path">$scopeEncoded</div>
                                        </td>
                                        <td>
                                            <div style="color: var(--text-primary);">$subscriptionsListEncoded</div>
                                            <div style="color: var(--text-secondary); font-size: 0.8rem; margin-top: 2px;">
                                                ($($mgAssignment.AffectedSubscriptions.Count) subscription$(if ($mgAssignment.AffectedSubscriptions.Count -ne 1) { 's' }))
                                            </div>
                                        </td>
                                    </tr>
"@
        }
        
        # Display subscription-level assignments (individual rows)
        foreach ($assignment in ($subscriptionAssignments | Sort-Object -Property RiskLevel, RoleDefinitionName)) {
            $assignmentRiskBadge = Get-RiskBadgeClass -Risk $assignment.RiskLevel
            $scopeIcon = Get-ScopeIcon -Type $assignment.ScopeType
            $roleNameEncoded = Encode-Html $assignment.RoleDefinitionName
            $scopeEncoded = Encode-Html $assignment.Scope
            $subNameEncoded = Encode-Html $assignment.SubscriptionName
            $principalNameForSearch = ($principal.PrincipalDisplayName -replace '<[^>]+>', '').ToLower()
            $searchData = "$principalNameForSearch $($assignment.RoleDefinitionName) $($assignment.Scope) $($assignment.SubscriptionName)".ToLower()
            $searchDataEncoded = Encode-Html $searchData
            
            # Subscription-level assignments are "Assigned" (direct assignment)
            $assignmentType = "Assigned"
            $assignmentTypeBadge = "badge-low"
            
            $html += @"
                                    <tr class="assignment-row"
                                        data-search="$searchDataEncoded"
                                        data-risk="$($assignment.RiskLevel)"
                                        data-type="$($principal.PrincipalType)"
                                        data-sub="$(Encode-Html $assignment.SubscriptionName)">
                                        <td><span class="badge $assignmentRiskBadge">$($assignment.RiskLevel)</span></td>
                                        <td>$roleNameEncoded</td>
                                        <td><span class="badge $assignmentTypeBadge" title="$assignmentType">$assignmentType</span></td>
                                        <td>$scopeIcon $($assignment.ScopeType)</td>
                                        <td class="scope-cell">
                                            <div class="scope-path">$scopeEncoded</div>
                                        </td>
                                        <td>$subNameEncoded</td>
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

    # Privileged Assignments Section
    $privilegedCount = $RBACData.Analysis.PrivilegedAssignments.Count
    $html += @"

        <!-- Privileged Assignments -->
        <div class="section">
            <div class="section-header" onclick="toggleSection(this)">
                <div class="section-title">
                    &#9888;&#65039; Privileged Assignments
                    <span class="section-count critical">$privilegedCount</span>
                </div>
                <span class="section-toggle">&#9660;</span>
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
                                data-search="$(Encode-Html "$($assignment.PrincipalDisplayName) $($assignment.RoleDefinitionName) $($assignment.Scope)".ToLower())"
                                data-risk="$($assignment.RiskLevel)"
                                data-type="$($assignment.PrincipalType)"
                                data-sub="$(Encode-Html $assignment.SubscriptionName)">
                                <td><span class="badge $riskBadge">$($assignment.RiskLevel)</span></td>
                                <td>
                                    <div class="principal-cell">
                                        <div class="principal-name">$icon $(Encode-Html $assignment.PrincipalDisplayName)</div>
                                        $(if ($assignment.PrincipalUPN) { "<div class='principal-upn'>$(Encode-Html $assignment.PrincipalUPN)</div>" })
                                    </div>
                                </td>
                                <td>$(Encode-Html $assignment.RoleDefinitionName)</td>
                                <td class="scope-cell">
                                    $scopeIcon $($assignment.ScopeType)
                                    <div class="scope-path">$(Encode-Html $assignment.Scope)</div>
                                </td>
                                <td>$(Encode-Html $assignment.SubscriptionName)</td>
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

    # Orphaned Assignments Section - Group by Principal ID
    $orphanedCount = $RBACData.Analysis.OrphanedAssignments.Count
    if ($orphanedCount -gt 0) {
        # Group orphaned assignments by Principal ID
        $orphanedGroups = @{}
        foreach ($assignment in $RBACData.Analysis.OrphanedAssignments) {
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

    # Non-Human Identities Section
    $nonHumanCount = $RBACData.Analysis.NonHumanIdentities.Count
    $html += @"

        <!-- Non-Human Identities -->
        <div class="section collapsed">
            <div class="section-header" onclick="toggleSection(this)">
                <div class="section-title">
                    &#129302; Service Principals & Managed Identities
                    <span class="section-count">$nonHumanCount</span>
                </div>
                <span class="section-toggle">&#9660;</span>
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
                                data-search="$(Encode-Html "$($assignment.PrincipalDisplayName) $($assignment.RoleDefinitionName)".ToLower())"
                                data-risk="$($assignment.RiskLevel)"
                                data-type="$($assignment.PrincipalType)"
                                data-sub="$(Encode-Html $assignment.SubscriptionName)">
                                <td><span class="badge $riskBadge">$($assignment.RiskLevel)</span></td>
                                <td>
                                    <div class="principal-cell">
                                        <div class="principal-name">$icon $(Encode-Html $assignment.PrincipalDisplayName)</div>
                                        $(if ($assignment.AppId) { "<div class='principal-upn'>AppId: $($assignment.AppId)</div>" })
                                    </div>
                                </td>
                                <td><span class="badge $typeBadge">$($assignment.PrincipalType)</span></td>
                                <td>$(Encode-Html $assignment.RoleDefinitionName)</td>
                                <td class="scope-cell">
                                    <div class="scope-path">$(Encode-Html $assignment.Scope)</div>
                                </td>
                                <td>$(Encode-Html $assignment.SubscriptionName)</td>
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
                    &#128202; Role Usage Analysis
                    <span class="section-count">$($RBACData.Analysis.RoleUsage.Count) roles</span>
                </div>
                <span class="section-toggle">&#9660;</span>
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
                    <div class="role-name" title="$(Encode-Html $role.RoleName)">$(Encode-Html $role.RoleName)</div>
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
                    &#127912; Custom Role Definitions
                    <span class="section-count">$($RBACData.CustomRoles.Count)</span>
                </div>
                <span class="section-toggle">&#9660;</span>
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
                                <td><strong>$(Encode-Html $role.Name)</strong></td>
                                <td>$(Encode-Html $role.Description)</td>
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
                    &#128203; All Role Assignments
                    <span class="section-count">$($stats.TotalAssignments)</span>
                </div>
                <span class="section-toggle">&#9660;</span>
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
                                data-search="$(Encode-Html "$($assignment.PrincipalDisplayName) $($assignment.RoleDefinitionName) $($assignment.Scope) $($assignment.SubscriptionName)".ToLower())"
                                data-risk="$($assignment.RiskLevel)"
                                data-type="$($assignment.PrincipalType)"
                                data-sub="$(Encode-Html $assignment.SubscriptionName)">
                                <td><span class="badge $riskBadge">$($assignment.RiskLevel)</span></td>
                                <td>
                                    <div class="principal-cell">
                                        <div class="principal-name">$icon $(Encode-Html $assignment.PrincipalDisplayName) $extraBadges</div>
                                        $(if ($assignment.PrincipalUPN) { "<div class='principal-upn'>$(Encode-Html $assignment.PrincipalUPN)</div>" })
                                    </div>
                                </td>
                                <td><span class="badge badge-type">$($assignment.PrincipalType)</span></td>
                                <td>$(Encode-Html $assignment.RoleDefinitionName)</td>
                                <td>$scopeIcon $($assignment.ScopeType)</td>
                                <td>$(Encode-Html $assignment.SubscriptionName)</td>
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
        
        // Toggle principal details expand/collapse
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
            
            const rows = document.querySelectorAll('.assignment-row');
            let visible = 0;
            
            // Filter all assignment rows
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
            
            // Cross-subscription principals now use the same principal-view-row structure
            // So they're already handled by the principal-view-row hiding logic above
            
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

