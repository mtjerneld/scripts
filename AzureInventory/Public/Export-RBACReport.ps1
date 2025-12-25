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
            'Subscription' { return "&#128273;" }
            'ResourceGroup' { return "&#128194;" }
            'Resource' { return "&#128196;" }
            default { return "&#128205;" }
        }
    }

    function Get-ScopeTypeDisplay {
        param([string]$Type)
        switch ($Type) {
            'Root' { return "Tenant Root" }
            'ManagementGroup' { return "Management Group" }
            'Subscription' { return "Subscription" }
            'ResourceGroup' { return "Resource Group" }
            'Resource' { return "Resource" }
            default { return $Type }
        }
    }

    function Parse-ScopeName {
        param([string]$ScopeFriendlyName)
        # ScopeFriendlyName format: "MG: name", "Sub: name", "RG: name", "Resource: name", "Tenant Root"
        if ($ScopeFriendlyName -match '^MG:\s*(.+)$') {
            return $Matches[1]
        }
        elseif ($ScopeFriendlyName -match '^Sub:\s*(.+)$') {
            return $Matches[1]
        }
        elseif ($ScopeFriendlyName -match '^RG:\s*(.+)$') {
            return $Matches[1]
        }
        elseif ($ScopeFriendlyName -match '^Resource:\s*(.+)$') {
            return $Matches[1]
        }
        elseif ($ScopeFriendlyName -eq 'Tenant Root') {
            return 'Tenant Root'
        }
        return $ScopeFriendlyName
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
            padding: 16px;
            margin-bottom: 20px;
            border: 1px solid var(--border-color);
        }
        
        .filters-title {
            font-size: 1.1rem;
            font-weight: 600;
            color: var(--text-primary);
            margin-bottom: 12px;
        }
        
        .filters-row {
            display: flex;
            flex-wrap: wrap;
            gap: 20px;
            align-items: flex-start;
        }
        
        
        .filter-group {
            display: flex;
            flex-direction: column;
            gap: 6px;
            flex: 0 0 auto;
        }
        
        .filter-group label {
            font-size: 0.75rem;
            color: var(--text-secondary);
            text-transform: uppercase;
            font-weight: 600;
            letter-spacing: 0.5px;
        }
        
        .filter-group input[type="text"],
        .filter-group select {
            padding: 6px 10px;
            border-radius: var(--radius-sm);
            border: 1px solid var(--border-color);
            background: var(--bg-secondary);
            color: var(--text-primary);
            font-size: 0.9rem;
            min-width: 200px;
        }
        
        .filter-group input[type="text"]:focus,
        .filter-group select:focus {
            outline: none;
            border-color: var(--accent-blue);
        }
        
        .filter-options {
            display: flex;
            flex-wrap: wrap;
            gap: 12px;
            align-items: center;
        }
        
        .filter-stats {
            margin-left: auto;
            color: var(--text-secondary);
            font-size: 0.85rem;
            padding-top: 24px;
            white-space: nowrap;
        }
        
        /* Tier Checkboxes */
        .tier-checkboxes {
            display: flex;
            flex-wrap: wrap;
            gap: 10px;
            align-items: center;
        }
        
        .checkbox-label {
            display: flex;
            align-items: center;
            gap: 6px;
            cursor: pointer;
            user-select: none;
            font-size: 0.85rem;
        }
        
        .checkbox-label input[type="checkbox"] {
            cursor: pointer;
            width: 16px;
            height: 16px;
            margin: 0;
            accent-color: var(--accent-blue);
            flex-shrink: 0;
        }
        
        .checkbox-label span:not(.badge) {
            color: var(--text-primary);
        }
        
        .tier-badge {
            font-size: 0.75rem;
            padding: 2px 8px;
            pointer-events: none;
            border-radius: 10px;
            font-weight: 600;
        }
        
        .tier-badge.tier-red {
            color: var(--accent-red);
        }
        
        .tier-badge.tier-orange {
            color: var(--accent-orange);
        }
        
        .tier-badge.tier-yellow {
            color: var(--accent-yellow);
        }
        
        .tier-badge.tier-purple {
            color: var(--accent-purple);
        }
        
        .tier-badge.tier-blue {
            color: var(--accent-blue);
        }
        
        .tier-badge.tier-green {
            color: var(--accent-green);
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
            table-layout: fixed;
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
            word-wrap: break-word;
            overflow-wrap: break-word;
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
            padding: 2px 8px;
            border-radius: 10px;
            font-size: 0.7rem;
            font-weight: 600;
            text-transform: uppercase;
            line-height: 1.3;
        }
        
        .tier-indicator {
            font-size: 0.85rem;
            font-weight: 600;
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
        
        /* Access Tier Colors */
        .tier-red { color: var(--accent-red); }
        .tier-orange { color: var(--accent-orange); }
        .tier-yellow { color: var(--accent-yellow); }
        .tier-purple { color: var(--accent-purple); }
        .tier-blue { color: var(--accent-blue); }
        .tier-green { color: var(--accent-green); }
        
        .principal-card[data-tier="FullControl"] {
            border-left: 4px solid var(--accent-red);
        }
        
        .principal-card[data-tier="AccessManager"] {
            border-left: 4px solid var(--accent-orange);
        }
        
        .principal-card[data-tier="Administrative"] {
            border-left: 4px solid var(--accent-yellow);
        }
        
        .principal-card[data-tier="PrivilegedOps"] {
            border-left: 4px solid var(--accent-purple);
        }
        
        .principal-card[data-tier="Write"] {
            border-left: 4px solid var(--accent-blue);
        }
        
        .principal-card[data-tier="ReadOnly"] {
            border-left: 4px solid var(--accent-green);
        }
        
        .principal-header {
            padding: 12px 16px;
            cursor: pointer;
            user-select: none;
        }
        
        .principal-header:hover {
            background: var(--bg-hover);
        }
        
        .principal-header-row {
            display: flex;
            align-items: center;
            gap: 12px;
            flex-wrap: wrap;
        }
        
        .principal-header-row:first-child {
            margin-bottom: 4px;
        }
        
        .principal-identity {
            display: flex;
            align-items: center;
            gap: 10px;
            flex: 0 0 auto;
        }
        
        .principal-icon {
            font-size: 1.1rem;
            flex-shrink: 0;
        }
        
        .principal-name {
            font-weight: 600;
            font-size: 0.95rem;
            white-space: nowrap;
        }
        
        .principal-name-block {
            display: flex;
            flex-direction: column;
            gap: 2px;
        }
        
        .principal-upn-row {
            display: flex;
            align-items: center;
            padding-left: 28px; /* Align with name above (icon width + gap) */
            font-size: 0.8rem;
            color: var(--text-muted);
            margin-top: 2px;
        }
        
        .principal-upn {
            font-size: 0.8rem;
            color: var(--text-muted);
        }
        
        .principal-badges {
            display: flex;
            align-items: center;
            gap: 6px;
            flex-shrink: 0;
        }
        
        .principal-summary {
            display: flex;
            align-items: center;
            gap: 16px;
            flex: 1;
            color: var(--text-secondary);
            font-size: 0.85rem;
            margin-left: auto;
            flex-wrap: wrap;
        }
        
        .summary-stat {
            white-space: nowrap;
        }
        
        .summary-item {
            display: flex;
            align-items: center;
            gap: 4px;
        }
        
        .principal-insights {
            display: flex;
            align-items: center;
            gap: 8px;
            flex-wrap: wrap;
            margin-left: 12px;
            padding-left: 12px;
            border-left: 1px solid var(--border-color);
        }
        
        .insight-badge {
            display: inline-flex;
            align-items: center;
            gap: 4px;
            padding: 2px 8px;
            border-radius: 10px;
            font-size: 0.75rem;
            font-weight: 500;
            white-space: nowrap;
        }
        
        .insight-badge.insight-critical {
            background: rgba(255, 107, 107, 0.15);
            color: var(--accent-red);
            border: 1px solid rgba(255, 107, 107, 0.3);
        }
        
        .insight-badge.insight-high {
            background: rgba(254, 202, 87, 0.15);
            color: var(--accent-yellow);
            border: 1px solid rgba(254, 202, 87, 0.3);
        }
        
        .insight-badge.insight-medium {
            background: rgba(84, 160, 255, 0.15);
            color: var(--accent-blue);
            border: 1px solid rgba(84, 160, 255, 0.3);
        }
        
        .insight-badge.insight-info {
            background: rgba(155, 89, 182, 0.15);
            color: var(--accent-purple);
            border: 1px solid rgba(155, 89, 182, 0.3);
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
        
        /* Access Tier Groups */
        .access-tier-group {
            margin-bottom: 20px;
        }
        
        .tier-header {
            padding: 10px 12px;
            font-weight: 600;
            font-size: 0.9rem;
            color: var(--text-primary);
            background: var(--bg-secondary);
            border-bottom: 2px solid var(--border-color);
        }
        
        .access-table {
            width: 100%;
            font-size: 0.85rem;
            table-layout: fixed;
        }
        
        .access-table th {
            text-align: left;
            padding: 10px 12px;
            background: var(--bg-surface);
            font-weight: 600;
            color: var(--text-muted);
            text-transform: uppercase;
            font-size: 0.75rem;
        }
        
        .access-table th:nth-child(1) { width: 18%; } /* Scope */
        .access-table th:nth-child(2) { width: 22%; } /* Name */
        .access-table th:nth-child(3) { width: 18%; } /* Role */
        .access-table th:nth-child(4) { width: 32%; } /* Affects */
        .access-table th:nth-child(5) { width: 10%; } /* Redundant */
        
        .access-table td {
            padding: 10px 12px;
            border-bottom: 1px solid var(--border-color);
            word-wrap: break-word;
            overflow-wrap: break-word;
        }
        
        .scope-table {
            width: 100%;
            font-size: 0.85rem;
            table-layout: fixed;
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
        
        .scope-table th:nth-child(1) { width: 20%; } /* Role */
        .scope-table th:nth-child(2) { width: 15%; } /* Type */
        .scope-table th:nth-child(3) { width: 45%; } /* Scope */
        .scope-table th:nth-child(4) { width: 20%; } /* Subscription */
        
        .scope-table td {
            padding: 10px 12px;
            border-bottom: 1px solid var(--border-color);
            word-wrap: break-word;
            overflow-wrap: break-word;
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
            table-layout: fixed;
            width: 100%;
        }
        
        .principal-view-details table th:nth-child(1) { width: 20%; } /* Role */
        .principal-view-details table th:nth-child(2) { width: 15%; } /* Type */
        .principal-view-details table th:nth-child(3) { width: 45%; } /* Scope */
        .principal-view-details table th:nth-child(4) { width: 20%; } /* Subscription */
        
        .principal-view-details table td {
            word-wrap: break-word;
            overflow-wrap: break-word;
        }
        
        /* Access Matrix */
        .access-matrix {
            background: var(--bg-surface);
            border-radius: var(--radius-md);
            padding: 20px;
            margin-bottom: 20px;
            border: 1px solid var(--border-color);
        }
        
        .access-matrix table {
            table-layout: fixed;
        }
        
        .access-matrix table th:nth-child(1) { width: 18%; } /* Access Level */
        .access-matrix table th:nth-child(2) { width: 14%; } /* Root */
        .access-matrix table th:nth-child(3) { width: 18%; } /* Mgmt Groups */
        .access-matrix table th:nth-child(4) { width: 18%; } /* Subscriptions */
        .access-matrix table th:nth-child(5) { width: 16%; } /* Resource Groups */
        .access-matrix table th:nth-child(6) { width: 16%; } /* Resources */
        
        .access-matrix table td {
            word-wrap: break-word;
            overflow-wrap: break-word;
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
                <div class="subtext">with Azure access</div>
            </div>
            <div class="summary-card">
                <div class="label">Full Control</div>
                <div class="value value-critical">$($stats.ByAccessTier.FullControl)</div>
                <div class="subtext">Owners</div>
            </div>
            <div class="summary-card">
                <div class="label">Access Managers</div>
                <div class="value value-high">$($stats.ByAccessTier.AccessManager)</div>
                <div class="subtext">can grant access</div>
            </div>
            <div class="summary-card">
                <div class="label">Orphaned Assignments</div>
                <div class="value value-critical">$($stats.OrphanedCount)</div>
                <div class="subtext">needs cleanup</div>
            </div>
            <div class="summary-card">
                <div class="label">Redundant Assignments</div>
                <div class="value value-critical">$($stats.RedundantCount)</div>
                <div class="subtext">needs cleanup</div>
            </div>
        </div>
        
        <!-- Access Matrix -->
        <div class="access-matrix">
            <h3 style="margin-top: 0; margin-bottom: 15px;">Access Distribution by Tier and Scope</h3>
            <table>
                <thead>
                    <tr>
                        <th>Access Level</th>
                        <th>&#127760; Root</th>
                        <th>&#127970; Mgmt Groups</th>
                        <th>&#128194; Subscriptions</th>
                        <th>&#128194; Resource Groups</th>
                        <th>&#128196; Resources</th>
                    </tr>
                </thead>
                <tbody>
"@

    # Build access matrix rows safely
    $accessMatrix = $RBACData.AccessMatrix
    $tierMatrixMap = @{
        'FullControl' = 'FullControl'
        'AccessManager' = 'AccessManager'
        'Administrative' = 'Administrative'
        'PrivilegedOps' = 'PrivilegedOps'
        'Write' = 'Write'
        'ReadOnly' = 'ReadOnly'
    }
    
    $tierDisplayMap = @{
        'FullControl' = @{ Badge = '&#128308; Full Control'; Class = 'tier-fullcontrol tier-red' }
        'AccessManager' = @{ Badge = '&#128992; Access Manager'; Class = 'tier-accessmanager tier-orange' }
        'Administrative' = @{ Badge = '&#128993; Administrative'; Class = 'tier-administrative tier-yellow' }
        'PrivilegedOps' = @{ Badge = '&#128995; Privileged Ops'; Class = 'tier-privilegedops tier-purple' }
        'Write' = @{ Badge = '&#128998; Write'; Class = 'tier-write tier-blue' }
        'ReadOnly' = @{ Badge = '&#129001; Read Only'; Class = 'tier-readonly tier-green' }
    }
    
    foreach ($tierKey in @('FullControl', 'AccessManager', 'Administrative', 'PrivilegedOps', 'Write', 'ReadOnly')) {
        $tierData = $tierDisplayMap[$tierKey]
        $matrixRow = $accessMatrix[$tierKey]
        $rootCount = if ($matrixRow -and $matrixRow['Root']) { $matrixRow['Root'] } else { 0 }
        $mgCount = if ($matrixRow -and $matrixRow['ManagementGroup']) { $matrixRow['ManagementGroup'] } else { 0 }
        $subCount = if ($matrixRow -and $matrixRow['Subscription']) { $matrixRow['Subscription'] } else { 0 }
        $rgCount = if ($matrixRow -and $matrixRow['ResourceGroup']) { $matrixRow['ResourceGroup'] } else { 0 }
        $resCount = if ($matrixRow -and $matrixRow['Resource']) { $matrixRow['Resource'] } else { 0 }
        
        $html += @"
                    <tr class="$($tierData.Class)">
                        <td><span class="tier-badge $($tierData.Class.Split(' ')[1])">$($tierData.Badge)</span></td>
                        <td>$rootCount</td>
                        <td>$mgCount</td>
                        <td>$subCount</td>
                        <td>$rgCount</td>
                        <td>$resCount</td>
                    </tr>
"@
    }
    
    $html += @"
                </tbody>
            </table>
        </div>
        
        <!-- Filters -->
        <div class="filters">
            <div class="filters-title">Filters</div>
            <div class="filters-row">
                <div class="filter-group">
                    <label>Search</label>
                    <input type="text" id="searchInput" placeholder="Name, UPN, role...">
                </div>
                <div class="filter-group">
                    <label>Access Level</label>
                    <div style="display: flex; align-items: center; gap: 12px; flex-wrap: wrap;">
                        <div class="tier-checkboxes">
                            <label class="checkbox-label">
                                <input type="checkbox" class="tier-checkbox" value="FullControl" checked>
                                <span class="tier-badge tier-red">&#128308; Full Control</span>
                            </label>
                            <label class="checkbox-label">
                                <input type="checkbox" class="tier-checkbox" value="AccessManager" checked>
                                <span class="tier-badge tier-orange">&#128992; Access Mgr</span>
                            </label>
                            <label class="checkbox-label">
                                <input type="checkbox" class="tier-checkbox" value="Administrative" checked>
                                <span class="tier-badge tier-yellow">&#128993; Admin</span>
                            </label>
                            <label class="checkbox-label">
                                <input type="checkbox" class="tier-checkbox" value="PrivilegedOps">
                                <span class="tier-badge tier-purple">&#128995; Privileged</span>
                            </label>
                            <label class="checkbox-label">
                                <input type="checkbox" class="tier-checkbox" value="Write">
                                <span class="tier-badge tier-blue">&#128998; Write</span>
                            </label>
                            <label class="checkbox-label">
                                <input type="checkbox" class="tier-checkbox" value="ReadOnly">
                                <span class="tier-badge tier-green">&#129001; Read Only</span>
                            </label>
                        </div>
                        <div style="display: flex; gap: 8px;">
                            <button type="button" id="selectAllTiers" style="padding: 4px 12px; font-size: 0.8rem; background: var(--bg-secondary); border: 1px solid var(--border-color); color: var(--text-primary); border-radius: var(--radius-sm); cursor: pointer;">Select All</button>
                            <button type="button" id="deselectAllTiers" style="padding: 4px 12px; font-size: 0.8rem; background: var(--bg-secondary); border: 1px solid var(--border-color); color: var(--text-primary); border-radius: var(--radius-sm); cursor: pointer;">Deselect All</button>
                        </div>
                    </div>
                </div>
                <div class="filter-group">
                    <label>Type</label>
                    <select id="typeFilter">
                        <option value="">All Types</option>
                        <option value="User">Users</option>
                        <option value="Group">Groups</option>
                        <option value="ServicePrincipal">Service Principals</option>
                        <option value="ManagedIdentity">Managed Identities</option>
                    </select>
                </div>
                <div class="filter-group">
                    <label>Options</label>
                    <div class="filter-options">
                        <label class="checkbox-label">
                            <input type="checkbox" id="showExternal">
                            <span>External only</span>
                        </label>
                        <label class="checkbox-label">
                            <input type="checkbox" id="showOrphaned">
                            <span>Orphaned only</span>
                        </label>
                        <label class="checkbox-label">
                            <input type="checkbox" id="showRedundant">
                            <span>Redundant only</span>
                        </label>
                    </div>
                </div>
                <div class="filter-stats">
                    <span id="visibleCount">$($stats.TotalPrincipals)</span> / $($stats.TotalPrincipals)
                </div>
            </div>
        </div>
"@

    # Principal Access List Section (unified view with access tiers)
    $html += @"
        
        <!-- Principal Access List -->
        <div class="principals-section">
            <h2>Principal Access <span class="count">$($principals.Count) principals</span></h2>
"@

    # Tier display names and colors
    $tierInfo = @{
        'FullControl' = @{ Display = 'Full Control'; Emoji = '&#128308;'; Color = 'red'; Class = 'tier-red' }
        'AccessManager' = @{ Display = 'Access Manager'; Emoji = '&#128992;'; Color = 'orange'; Class = 'tier-orange' }
        'Administrative' = @{ Display = 'Administrative'; Emoji = '&#128993;'; Color = 'yellow'; Class = 'tier-yellow' }
        'PrivilegedOps' = @{ Display = 'Privileged Ops'; Emoji = '&#128995;'; Color = 'purple'; Class = 'tier-purple' }
        'Write' = @{ Display = 'Write'; Emoji = '&#128998;'; Color = 'blue'; Class = 'tier-blue' }
        'ReadOnly' = @{ Display = 'Read Only'; Emoji = '&#129001;'; Color = 'green'; Class = 'tier-green' }
    }

    foreach ($principal in $principals) {
        $icon = Get-PrincipalTypeIcon -Type $principal.PrincipalType
        $principalNameEncoded = Encode-Html $principal.PrincipalDisplayName
        $principalUpnEncoded = if ($principal.PrincipalUPN) { Encode-Html $principal.PrincipalUPN } else { "" }
        $safePrincipalId = "$($principal.PrincipalId)-$($principal.PrincipalType)" -replace '[^a-zA-Z0-9\-]', '-'
        $principalCardId = "principal-$safePrincipalId"
        
        # Get tier info
        $tier = $tierInfo[$principal.HighestAccessTier]
        $tierDisplay = $tier.Display
        $tierEmoji = $tier.Emoji
        $tierClass = $tier.Class
        
        # Build search data
        $rolesList = ($principal.RolesSummary -join " ") -replace '<[^>]+>', ''
        $searchData = "$principalNameEncoded $principalUpnEncoded $rolesList $tierDisplay".ToLower()
        $searchDataEncoded = Encode-Html $searchData
        
        # Build external badge if applicable
        $externalBadge = ""
        if ($principal.IsExternal) {
            $externalBadge = '<span class="badge badge-external">External</span>'
        }
        
        # Check if principal has any redundant assignments
        $hasRedundant = $false
        foreach ($tierName in @('FullControl', 'AccessManager', 'Administrative', 'PrivilegedOps', 'Write', 'ReadOnly')) {
            if ($principal.AccessByTier -and $principal.AccessByTier.ContainsKey($tierName)) {
                $redundantEntries = $principal.AccessByTier[$tierName] | Where-Object { $_.IsRedundant }
                if ($redundantEntries -and $redundantEntries.Count -gt 0) {
                    $hasRedundant = $true
                    break
                }
            }
        }
        
        # Build insights for header
        $insightsHeaderHtml = ""
        if ($principal.Insights -and $principal.Insights.Count -gt 0) {
            # Map ASCII icon codes to HTML entities for display
            $iconMap = @{
                '[!!]' = '&#128680;'  # 🚨
                '[!]' = '&#9888;&#65039;'  # ⚠️
                '[EXT]' = '&#128123;'  # 👻
                '[SP]' = '&#129302;'  # 🤖
                '[i]' = '&#8505;&#65039;'  # ℹ️
                '[~]' = '&#129529;'  # 🧹
            }
            
            $insightsHeaderHtml = '<div class="principal-insights">'
            foreach ($insight in $principal.Insights) {
                $severityClass = $insight.Severity.ToLower()
                $messageEncoded = Encode-Html $insight.Message
                $iconHtml = if ($iconMap.ContainsKey($insight.Icon)) { $iconMap[$insight.Icon] } else { $insight.Icon }
                $insightsHeaderHtml += "<span class='insight-badge insight-$severityClass'>$iconHtml $messageEncoded</span>"
            }
            $insightsHeaderHtml += '</div>'
        }
        
        $html += @"
            <div class="principal-card" 
                 id="$principalCardId" 
                 data-tier="$($principal.HighestAccessTier)" 
                 data-type="$($principal.PrincipalType)"
                 data-external="$($principal.IsExternal.ToString().ToLower())"
                 data-orphaned="$($principal.IsOrphaned.ToString().ToLower())"
                 data-redundant="$($hasRedundant.ToString().ToLower())"
                 data-search="$searchDataEncoded">
                <div class="principal-header" onclick="togglePrincipal(this)">
                    <div class="principal-header-row">
                        <div class="principal-identity">
                            <span class="principal-icon">$icon</span>
                            <span class="principal-name">$principalNameEncoded</span>
                            <div class="principal-badges">
                                <span class="badge badge-type">$($principal.PrincipalType)</span>
                                $externalBadge
                            </div>
                        </div>
                        <div class="principal-summary">
                            <span class="tier-indicator $tierClass">$tierEmoji $tierDisplay</span>
                            <span class="summary-stat">&#127894; $($principal.RolesSummary.Count) roles</span>
                            <span class="summary-stat">&#128193; $($principal.ScopeCount) scopes</span>
                            <span class="summary-stat">&#128273; $($principal.AffectedSubscriptionCount) subs</span>
                            $insightsHeaderHtml
                        </div>
                        <span class="toggle-icon">&#9660;</span>
                    </div>
                    $(if ($principalUpnEncoded) { "<div class='principal-upn-row'><span class='principal-upn'>$principalUpnEncoded</span></div>" })
                </div>
                
                <div class="principal-details">
"@

        # Group access by tier
        $tierOrder = @('FullControl', 'AccessManager', 'Administrative', 'PrivilegedOps', 'Write', 'ReadOnly')
        foreach ($tierName in $tierOrder) {
            if ($principal.AccessByTier.ContainsKey($tierName) -and $principal.AccessByTier[$tierName].Count -gt 0) {
                $tier = $tierInfo[$tierName]
                $tierDisplay = $tier.Display
                $tierEmoji = $tier.Emoji
                $tierClass = $tier.Class
                
                # Sort entries by scope hierarchy: Root (0) → MG (1) → Subscription (2) → RG (3) → Resource (4)
                $sortedEntries = $principal.AccessByTier[$tierName] | Sort-Object ScopeLevel, ScopeFriendlyName
                
                $tierDisplayUpper = $tierDisplay.ToUpper()
                $html += @"
                    <div class="access-tier-group tier-$($tierName.ToLower())" data-tier-group="$tierName">
                        <div class="tier-header">$tierEmoji $tierDisplayUpper</div>
                        <table class="access-table">
                            <thead>
                                <tr>
                                    <th>Scope</th>
                                    <th>Name</th>
                                    <th>Role</th>
                                    <th>Affects</th>
                                    <th>Redundant</th>
                                </tr>
                            </thead>
                            <tbody>
"@
                
                foreach ($entry in $sortedEntries) {
                    $scopeIcon = Get-ScopeIcon -Type $entry.ScopeType
                    $scopeTypeDisplay = Get-ScopeTypeDisplay -Type $entry.ScopeType
                    $scopeTypeDisplayEncoded = Encode-Html $scopeTypeDisplay
                    $scopeName = Parse-ScopeName -ScopeFriendlyName $entry.ScopeFriendlyName
                    $scopeNameEncoded = Encode-Html $scopeName
                    $roleEncoded = Encode-Html $entry.Role
                    
                    # Build Affects column with key icon
                    $affectsHtml = ""
                    if ($entry.AffectedSubscriptions -and $entry.AffectedSubscriptions.Count -gt 0) {
                        if ($entry.AffectedSubscriptions[0] -match '^All \d+ subscriptions$') {
                            $affectsHtml = "<span class='affects-badge'>&#128273; $($entry.AffectedSubscriptions[0])</span>"
                        } else {
                            $subsList = ($entry.AffectedSubscriptions | ForEach-Object { Encode-Html $_ }) -join ", "
                            $count = $entry.AffectedSubscriptions.Count
                            if ($count -le 3) {
                                $affectsHtml = "<span class='affects-badge'>&#128273; $subsList</span>"
                            } else {
                                $firstSubEncoded = Encode-Html $entry.AffectedSubscriptions[0]
                                $affectsHtml = "<span class='affects-badge'>&#128273; $firstSubEncoded, ... ($count subscriptions)</span>"
                            }
                        }
                    }
                    
                    # Build Redundant column
                    $redundantDisplay = "No"
                    $redundantIcon = ""
                    if ($entry.IsRedundant) {
                        $redundantDisplay = "Yes"
                        $redundantReason = if ($entry.RedundantReason) { Encode-Html $entry.RedundantReason } else { "Redundant: Same role already assigned at a broader scope" }
                        $redundantIcon = " <span class='redundant-badge' title='$redundantReason'>&#129529;</span>"
                    }
                    $redundantDisplayEncoded = Encode-Html $redundantDisplay
                    
                    $rowClass = if ($entry.IsRedundant) { 'class="redundant"' } else { '' }
                    
                    $html += @"
                                <tr $rowClass>
                                    <td><span class="scope-type">$scopeIcon</span> $scopeTypeDisplayEncoded</td>
                                    <td>$scopeNameEncoded</td>
                                    <td>$roleEncoded</td>
                                    <td>$affectsHtml</td>
                                    <td>$redundantDisplayEncoded$redundantIcon</td>
                                </tr>
"@
                }
                
                $html += @"
                            </tbody>
                        </table>
                    </div>
"@
            }
        }
        
        # Add group note if it's a group
        if ($principal.PrincipalType -eq 'Group') {
            $html += @"
                    <div class="group-note">
                        &#8505; This is a group. All members inherit this access. Review membership in Entra ID → Groups.
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
                                <span>&#128193; $($orphanedPrincipal.Assignments.Count) $assignmentText</span>
                                <span>&#128273; $($orphanedPrincipal.Subscriptions.Count) $subscriptionText</span>
                                <span>&#127894; $($orphanedPrincipal.Roles.Count) $roleText</span>
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
        const tierCheckboxes = document.querySelectorAll('.tier-checkbox');
        const typeFilter = document.getElementById('typeFilter');
        const showExternal = document.getElementById('showExternal');
        const showOrphaned = document.getElementById('showOrphaned');
        const showRedundant = document.getElementById('showRedundant');
        const visibleCount = document.getElementById('visibleCount');
        
        function getSelectedTiers() {
            const selected = [];
            tierCheckboxes.forEach(checkbox => {
                if (checkbox.checked) {
                    selected.push(checkbox.value);
                }
            });
            return selected;
        }
        
        function applyFilters() {
            const searchTerm = searchInput.value.toLowerCase();
            const selectedTiers = getSelectedTiers();
            const typeValue = typeFilter.value;
            const externalOnly = showExternal.checked;
            const orphanedOnly = showOrphaned.checked;
            const redundantOnly = showRedundant.checked;
            
            // Filter principal cards
            const cards = document.querySelectorAll('.principal-card');
            let visible = 0;
            
            cards.forEach(card => {
                const matchesSearch = !searchTerm || card.dataset.search.includes(searchTerm);
                const matchesType = !typeValue || card.dataset.type === typeValue;
                const matchesExternal = !externalOnly || card.dataset.external === 'true';
                const matchesOrphaned = !orphanedOnly || card.dataset.orphaned === 'true';
                const matchesRedundant = !redundantOnly || card.dataset.redundant === 'true';
                
                // Check if principal has any of the selected tiers
                let matchesTier = false;
                if (selectedTiers.length === 0) {
                    matchesTier = true; // No filter = show all
                } else {
                    // Check if this principal has access at any of the selected tiers
                    const tierGroups = card.querySelectorAll('.access-tier-group[data-tier-group]');
                    tierGroups.forEach(group => {
                        if (selectedTiers.includes(group.dataset.tierGroup)) {
                            matchesTier = true;
                        }
                    });
                }
                
                if (matchesSearch && matchesType && matchesTier && matchesExternal && matchesOrphaned && matchesRedundant) {
                    card.style.display = 'block';
                    visible++;
                    
                    // Filter tier groups within this card
                    const tierGroups = card.querySelectorAll('.access-tier-group[data-tier-group]');
                    tierGroups.forEach(group => {
                        if (selectedTiers.length === 0 || selectedTiers.includes(group.dataset.tierGroup)) {
                            group.style.display = 'block';
                        } else {
                            group.style.display = 'none';
                        }
                    });
                } else {
                    card.style.display = 'none';
                }
            });
            
            // Update visible count
            visibleCount.textContent = visible;
        }
        
        // Select all / Deselect all buttons
        const selectAllTiers = document.getElementById('selectAllTiers');
        const deselectAllTiers = document.getElementById('deselectAllTiers');
        
        if (selectAllTiers) {
            selectAllTiers.addEventListener('click', () => {
                tierCheckboxes.forEach(checkbox => {
                    checkbox.checked = true;
                });
                applyFilters();
            });
        }
        
        if (deselectAllTiers) {
            deselectAllTiers.addEventListener('click', () => {
                tierCheckboxes.forEach(checkbox => {
                    checkbox.checked = false;
                });
                applyFilters();
            });
        }
        
        searchInput.addEventListener('input', applyFilters);
        tierCheckboxes.forEach(checkbox => {
            checkbox.addEventListener('change', applyFilters);
        });
        typeFilter.addEventListener('change', applyFilters);
        showExternal.addEventListener('change', applyFilters);
        showOrphaned.addEventListener('change', applyFilters);
        showRedundant.addEventListener('change', applyFilters);
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

