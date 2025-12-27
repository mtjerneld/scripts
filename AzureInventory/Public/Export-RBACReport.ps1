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
            'Root' { return "&#127760;" }
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

    function Format-AffectedSubscriptions {
        param(
            [array]$Subscriptions,
            [int]$Count = 0,
            [int]$InlineThreshold = 2
        )
        
        if (-not $Subscriptions -or $Subscriptions.Count -eq 0) {
            return '<span class="text-muted">-</span>'
        }
        
        $actualCount = if ($Count -gt 0) { $Count } else { $Subscriptions.Count }
        
        if ($actualCount -le $InlineThreshold) {
            $escaped = $Subscriptions | ForEach-Object { Encode-Html $_ }
            return "<span class='affects-inline'>$($escaped -join ', ')</span>"
        }
        else {
            $escaped = $Subscriptions | ForEach-Object { Encode-Html $_ }
            $listItems = ($escaped | ForEach-Object { "<li>$_</li>" }) -join ''
            return @"
<span class="affects-expandable" onclick="toggleAffects(this); event.stopPropagation();">
    <span class="affects-summary">$actualCount subs <span class="expand-arrow">&#9660;</span></span>
    <ul class="affects-dropdown">$listItems</ul>
</span>
"@
        }
    }

    function Build-PrincipalCard {
        param([object]$Principal)
        
        # Icon based on type
        $icon = switch ($Principal.PrincipalType) {
            'User' { '&#128100;' }
            'Group' { '&#128101;' }
            'ServicePrincipal' { '&#129302;' }
            'ManagedIdentity' { '&#9881;' }
            default { '&#10067;' }
        }
        
        # Border color
        $borderColor = if ($Principal.IsOrphaned) { 
            'var(--accent-purple)' 
        } elseif ($Principal.IsExternal) { 
            'var(--accent-orange)' 
        } else { 
            'var(--accent-blue)' 
        }
        
        # Display name and subtitle
        $displayName = [System.Web.HttpUtility]::HtmlEncode($Principal.PrincipalDisplayName)
        $subtitle = if ($Principal.PrincipalUPN) {
            "<div class='principal-view-subtitle'>$([System.Web.HttpUtility]::HtmlEncode($Principal.PrincipalUPN))</div>"
        } elseif ($Principal.AppId) {
            "<div class='principal-view-subtitle'>AppId: $($Principal.AppId.Substring(0,8))...</div>"
        } else { "" }
        
        # Badges
        $badges = ""
        if ($Principal.IsOrphaned) { $badges += '<span class="badge badge-orphaned">Orphaned</span>' }
        if ($Principal.IsExternal) { $badges += '<span class="badge badge-external">External</span>' }
        $badges += "<span class='badge badge-type'>$($Principal.PrincipalType)</span>"
        if ($Principal.HasPrivilegedRoles) { $badges += '<span class="badge badge-critical">Privileged</span>' }
        
        # Stats line
        $statsLine = @(
            "&#128193; $($Principal.AssignmentCount) assignments",
            "&#127894; $($Principal.RoleCount) roles",
            "&#128273; $($Principal.SubscriptionCount) subscriptions"
        ) -join ' | '
        
        # Build assignments table rows
        $tableRows = foreach ($a in $Principal.Assignments) {
            $scopeIcon = switch ($a.ScopeType) {
                'Tenant Root' { '&#127760;' }
                'Management Group' { '&#127970;' }
                'Subscription' { '&#128273;' }
                'Resource Group' { '&#128194;' }
                'Resource' { '&#128196;' }
                default { '' }
            }
            
            $subsHtml = Format-AffectedSubscriptions -Subscriptions $a.Subscriptions -Count $a.SubscriptionCount
            $redundantHtml = if ($a.IsRedundant) {
                if ($a.RedundantReason) {
                    $reasonEncoded = [System.Web.HttpUtility]::HtmlEncode($a.RedundantReason)
                    "<span class='redundant-yes' title='$reasonEncoded'>Yes &#9432;</span>"
                } else {
                    '<span class="redundant-yes">Yes</span>'
                }
            } else { 
                '-' 
            }
            
            $privilegedHtml = if ($a.IsPrivileged) {
                '<span class="badge badge-critical">Privileged</span>'
            } else {
                '-'
            }
            
            @"
        <tr>
            <td>$([System.Web.HttpUtility]::HtmlEncode($a.Role))</td>
            <td>$scopeIcon $([System.Web.HttpUtility]::HtmlEncode($a.ScopeType))</td>
            <td>$([System.Web.HttpUtility]::HtmlEncode($a.ScopeName))</td>
            <td>$subsHtml</td>
            <td>$privilegedHtml</td>
            <td>$redundantHtml</td>
        </tr>
"@
        }
        
        # Get unique scope types for this principal
        $uniqueScopeTypes = $Principal.Assignments | Select-Object -ExpandProperty ScopeType -Unique | Sort-Object
        
        # Search data
        $searchData = @(
            $Principal.PrincipalDisplayName,
            $Principal.PrincipalUPN,
            ($Principal.UniqueRoles -join ' '),
            ($Principal.UniqueSubscriptions -join ' ')
        ) -join ' '
        
        # Build card
        $principalId = $Principal.PrincipalId -replace '[^a-zA-Z0-9-]', '-'
        return @"
<div class="principal-view-row" 
     id="principal-$principalId"
     data-type="$($Principal.PrincipalType)"
     data-orphaned="$($Principal.IsOrphaned)"
     data-external="$($Principal.IsExternal)"
     data-privileged="$($Principal.HasPrivilegedRoles)"
     data-roles="$($Principal.UniqueRoles -join ',')"
     data-scopes="$($uniqueScopeTypes -join ',')"
     data-search="$($searchData.ToLower())"
     style="border-left-color: $borderColor;">
    <div class="principal-view-header" onclick="togglePrincipalDetails(this)">
        <div class="principal-view-info">
            <div class="principal-view-name">
                $icon $displayName $badges
            </div>
            $subtitle
            <div class="principal-view-stats">$statsLine</div>
        </div>
        <span class="principal-view-toggle">&#9660;</span>
    </div>
    <div class="principal-view-details">
        <div class="table-container">
            <table>
                <thead>
                    <tr>
                        <th>Role</th>
                        <th>Scope Type</th>
                        <th>Scope Name</th>
                        <th>Subscriptions</th>
                        <th>Privileged</th>
                        <th>Redundant</th>
                    </tr>
                </thead>
                <tbody>
                    $($tableRows -join "`n")
                </tbody>
            </table>
        </div>
    </div>
</div>
"@
    }

    #endregion

    #region Build HTML

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $stats = $RBACData.Statistics
    $metadata = $RBACData.Metadata
    $assignments = $RBACData.Assignments
    $orphanedAssignments = $RBACData.OrphanedAssignments
    $customRoles = $RBACData.CustomRoles
    $displayTenantId = if ($TenantId -ne "Unknown") { $TenantId } else { $metadata.TenantId }
    
    # Sort AccessMatrix roles: privileged first, then by total descending
    $sortedRoleNames = $RBACData.AccessMatrix.Keys | Sort-Object {
        $roleData = $RBACData.AccessMatrix[$_]
        $isPriv = if ($roleData.IsPrivileged) { $roleData.IsPrivileged } else { $false }
        $total = $roleData.Total
        # Create sort key: "0-{total}" for privileged (sorts first), "1-{total}" for non-privileged
        # Use inverted total (100000 - total) so higher totals sort first within each group
        $sortKey = if ($isPriv) {
            "0-{0:D6}" -f (1000000 - $total)
        } else {
            "1-{0:D6}" -f (1000000 - $total)
        }
        $sortKey
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
        
        .summary-card .card-value {
            font-size: 2rem;
            font-weight: 700;
            color: var(--text-primary);
        }
        
        .summary-card .card-label {
            font-size: 0.9rem;
            color: var(--text-secondary);
            margin-top: 5px;
        }
        
        .summary-card .card-sublabel {
            font-size: 0.75rem;
            color: var(--text-muted);
            margin-top: 3px;
        }
        
        .summary-card.card-critical .card-value { color: var(--accent-red); }
        .summary-card.card-warning .card-value { color: var(--accent-yellow); }
        
        /* Filters */
        .filters {
            background: var(--bg-surface);
            border-radius: var(--radius-md);
            margin-bottom: 16px;
            border: 1px solid var(--border-color);
            overflow: hidden;
        }
        
        .filters-header {
            padding: 12px 16px;
            background: var(--bg-secondary);
            border-bottom: 1px solid var(--border-color);
            font-weight: 600;
            font-size: 0.95rem;
            color: var(--text-primary);
        }
        
        .filters-content {
            display: flex;
            flex-wrap: nowrap;
            gap: 12px;
            align-items: center;
            padding: 12px 16px;
        }

        .filter-group {
            display: flex;
            align-items: center;
            gap: 8px;
        }

        .filter-group input[type="text"] {
            padding: 6px 10px;
            border: 1px solid var(--border-color);
            border-radius: 4px;
            background: var(--bg-primary);
            color: var(--text-primary);
            min-width: 200px;
            font-size: 0.9rem;
        }

        .filter-group select {
            padding: 6px 10px;
            border: 1px solid var(--border-color);
            border-radius: 4px;
            background: var(--bg-primary);
            color: var(--text-primary);
            font-size: 0.9rem;
        }

        .filter-group label {
            display: flex;
            align-items: center;
            gap: 4px;
            cursor: pointer;
            font-size: 0.9rem;
        }

        .filter-stats {
            margin-left: auto;
            color: var(--text-muted);
            font-size: 0.9rem;
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
        
        /* Risk badges */
        .risk-badge {
            display: inline-block;
            width: 24px;
            text-align: center;
        }

        .risk-red { color: #ff6b6b; }
        .risk-yellow { color: #feca57; }
        .risk-green { color: #1dd1a1; }

        /* Type badges */
        .badge {
            display: inline-block;
            padding: 2px 8px;
            border-radius: 4px;
            font-size: 0.75rem;
            font-weight: 500;
            background: var(--bg-hover);
        }

        .badge-user { background: #3498db22; color: #3498db; }
        .badge-group { background: #9b59b622; color: #9b59b6; }
        .badge-sp { background: #e67e2222; color: #e67e22; }
        .badge-mi { background: #1abc9c22; color: #1abc9c; }

        /* Redundant indicator */
        .redundant-yes {
            color: #feca57;
            font-weight: 500;
        }

        /* Affects dropdown */
        .affects-expandable {
            position: relative;
            cursor: pointer;
        }

        .affects-summary {
            color: var(--accent-blue);
            text-decoration: underline dotted;
        }

        .expand-arrow {
            font-size: 0.7rem;
            transition: transform 0.2s;
        }

        .affects-expandable.expanded .expand-arrow {
            transform: rotate(180deg);
        }

        .affects-dropdown {
            display: none;
            position: absolute;
            left: 0;
            top: 100%;
            background: var(--bg-surface);
            border: 1px solid var(--border-color);
            border-radius: 4px;
            padding: 8px 12px;
            margin-top: 4px;
            list-style: none;
            z-index: 100;
            min-width: 180px;
            max-height: 200px;
            overflow-y: auto;
            box-shadow: 0 4px 12px rgba(0,0,0,0.3);
        }

        .affects-expandable.expanded .affects-dropdown {
            display: block;
        }

        .affects-dropdown li {
            padding: 4px 0;
            font-size: 0.85rem;
            border-bottom: 1px solid var(--border-color);
        }

        .affects-dropdown li:last-child {
            border-bottom: none;
        }

        /* Matrix table */
        .matrix-table td:not(:first-child) {
            text-align: center;
            font-weight: 500;
        }
        
        /* Sections */
        .section {
            background: var(--bg-surface);
            border-radius: var(--radius-md);
            margin-bottom: 20px;
            border: 1px solid var(--border-color);
            overflow: hidden;
        }
        
        .section h2 {
            padding: 15px 20px;
            margin: 0;
            font-size: 1.2rem;
            font-weight: 600;
            color: var(--text-primary);
            border-bottom: 1px solid var(--border-color);
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
        
        .access-table th:nth-child(1) { width: 18%; } /* Role */
        .access-table th:nth-child(2) { width: 18%; } /* Assigned At */
        .access-table th:nth-child(3) { width: 22%; } /* Scope Name */
        .access-table th:nth-child(4) { width: 32%; } /* Affects */
        .access-table th:nth-child(5) { width: 10%; } /* Redundant */
        
        .access-table td {
            padding: 10px 12px;
            border-bottom: 1px solid var(--border-color);
            word-wrap: break-word;
            overflow-wrap: break-word;
        }
        
        .affects-badge {
            display: inline-flex;
            align-items: center;
            gap: 6px;
            flex-wrap: wrap;
        }
        
        .affects-toggle {
            color: var(--accent-blue);
            cursor: pointer;
            user-select: none;
            font-size: 0.85rem;
            text-decoration: underline;
        }
        
        .affects-toggle:hover {
            color: var(--accent-blue);
            opacity: 0.8;
        }
        
        .affects-dropdown {
            list-style: none;
            margin: 5px 0 0 20px;
            padding: 0;
            background: var(--bg-secondary);
            border-radius: var(--radius-sm);
            padding: 8px 12px;
            border: 1px solid var(--border-color);
        }
        
        .affects-dropdown li {
            padding: 2px 0;
            font-size: 0.85rem;
            color: var(--text-secondary);
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
            flex-direction: column;
            gap: 4px;
        }
        
        .principal-view-name {
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        
        .principal-view-subtitle {
            color: var(--text-muted);
            font-size: 0.8rem;
            margin-top: 2px;
        }
        
        .principal-view-stats {
            display: flex;
            gap: 15px;
            font-size: 0.85rem;
            color: var(--text-secondary);
            margin-top: 4px;
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
        
        .principal-view-details table th:nth-child(1) { width: 18%; } /* Role */
        .principal-view-details table th:nth-child(2) { width: 15%; } /* Scope Type */
        .principal-view-details table th:nth-child(3) { width: 22%; } /* Scope Name */
        .principal-view-details table th:nth-child(4) { width: 20%; } /* Subscriptions */
        .principal-view-details table th:nth-child(5) { width: 10%; } /* Privileged */
        .principal-view-details table th:nth-child(6) { width: 15%; } /* Redundant */
        
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
        
        .access-matrix table th:nth-child(1) { width: 16%; } /* Role */
        .access-matrix table th:nth-child(2) { width: 10%; } /* Privileged */
        .access-matrix table th:nth-child(3) { width: 10%; } /* Root */
        .access-matrix table th:nth-child(4) { width: 12%; } /* Mgmt Groups */
        .access-matrix table th:nth-child(5) { width: 12%; } /* Subscriptions */
        .access-matrix table th:nth-child(6) { width: 12%; } /* Resource Groups */
        .access-matrix table th:nth-child(7) { width: 12%; } /* Resources */
        .access-matrix table th:nth-child(8) { width: 8%; }  /* Total */
        .access-matrix table th:nth-child(9) { width: 8%; }  /* Unique */
        
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
        @media (max-width: 1200px) {
            .filters-content {
                flex-wrap: wrap;
            }
            
            .filter-stats {
                margin-left: 0;
                width: 100%;
            }
        }
        
        @media (max-width: 768px) {
            .summary-grid {
                grid-template-columns: repeat(2, 1fr);
            }
            
            .filters-content {
                flex-direction: column;
                align-items: stretch;
            }
            
            .filter-group {
                width: 100%;
            }
            
            .filter-group input[type="text"] {
                width: 100%;
            }
            
            .filter-group select {
                width: 100%;
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
        
        $(if ($RBACData.Metadata.LacksEntraIdAccess) {
            $unresolvedCount = $RBACData.Metadata.UnresolvedPrincipalCount
            @"
        <!-- Entra ID Access Warning -->
        <div class="warning-banner" style="background: rgba(254, 202, 87, 0.15); border: 1px solid var(--accent-yellow); border-radius: var(--radius-sm); padding: 12px 16px; margin-bottom: 20px; display: flex; align-items: center; gap: 10px;">
            <span style="font-size: 1.2rem;">&#9888;</span>
            <div>
                <strong style="color: var(--accent-yellow);">Limited Entra ID Access</strong>
                <p style="margin: 4px 0 0 0; color: var(--text-secondary); font-size: 0.9rem;">
                    Unable to resolve $unresolvedCount principal name(s). The audit account lacks Directory Reader access to Entra ID. Principal IDs are shown instead of display names.
                </p>
            </div>
        </div>
"@
        } elseif ($RBACData.Metadata.UnresolvedPrincipalCount -gt 0) {
            $unresolvedCount = $RBACData.Metadata.UnresolvedPrincipalCount
            @"
        <!-- External Principals Info -->
        <div class="info-banner" style="background: rgba(84, 160, 255, 0.1); border: 1px solid var(--accent-blue); border-radius: var(--radius-sm); padding: 12px 16px; margin-bottom: 20px; display: flex; align-items: center; gap: 10px;">
            <span style="font-size: 1.2rem;">&#8505;</span>
            <div>
                <strong style="color: var(--accent-blue);">External Principals</strong>
                <p style="margin: 4px 0 0 0; color: var(--text-secondary); font-size: 0.9rem;">
                    $unresolvedCount external principal(s) could not be resolved (B2B guests or groups from external tenants).
                </p>
            </div>
        </div>
"@
        })
        
        <!-- Summary Cards -->
        <div class="summary-grid">
            <div class="summary-card">
                <div class="card-value">$($stats.TotalPrincipals)</div>
                <div class="card-label">Principals</div>
            </div>
            <div class="summary-card card-critical">
                <div class="card-value">$($stats.ByRiskTier.Privileged)</div>
                <div class="card-label">Privileged Assignments</div>
                <div class="card-sublabel">Owner, Contributor, UAA, RBAC Admin, Access Review Operator</div>
            </div>
            <div class="summary-card card-warning">
                <div class="card-value">$($stats.OrphanedCount)</div>
                <div class="card-label">Orphaned</div>
                <div class="card-sublabel">Needs cleanup</div>
            </div>
            <div class="summary-card">
                <div class="card-value">$($stats.RedundantCount)</div>
                <div class="card-label">Redundant</div>
                <div class="card-sublabel">Can be removed</div>
            </div>
        </div>
        
        <!-- Access Matrix -->
        <div class="section">
            <h2>Access Distribution</h2>
            <table class="data-table matrix-table">
                <thead>
                    <tr>
                        <th>Role</th>
                        <th>Privileged</th>
                        <th>&#127760; Root</th>
                        <th>&#127970; Mgmt Groups</th>
                        <th>&#128273; Subscriptions</th>
                        <th>&#128194; Resource Groups</th>
                        <th>&#128196; Resources</th>
                        <th>Total</th>
                        <th>Unique</th>
                    </tr>
                </thead>
                <tbody>
                    $(foreach ($roleName in $sortedRoleNames) {
                        $roleData = $RBACData.AccessMatrix[$roleName]
                        $total = $roleData.Total
                        $unique = if ($roleData.Unique) { $roleData.Unique } else { 0 }
                        $isPrivileged = if ($roleData.IsPrivileged) { $roleData.IsPrivileged } else { $false }
                        $privilegedBadge = if ($isPrivileged) {
                            '<span class="badge badge-critical">Privileged</span>'
                        } else {
                            '-'
                        }
                        @"
                    <tr>
                        <td>$([System.Web.HttpUtility]::HtmlEncode($roleName))</td>
                        <td>$privilegedBadge</td>
                        <td>$($roleData['Tenant Root'])</td>
                        <td>$($roleData['Management Group'])</td>
                        <td>$($roleData['Subscription'])</td>
                        <td>$($roleData['Resource Group'])</td>
                        <td>$($roleData['Resource'])</td>
                        <td><strong>$total</strong></td>
                        <td><strong>$unique</strong></td>
                    </tr>
"@
                    } -join "`n")
                </tbody>
            </table>
        </div>
        
        <!-- Filters -->
        <div class="filters">
            <div class="filters-header">Filters</div>
            <div class="filters-content">
                <div class="filter-group">
                    <input type="text" id="searchInput" placeholder="Search principal, role, scope..." onkeyup="applyFilters()">
                </div>
                <div class="filter-group">
                    <select id="typeFilter" onchange="applyFilters()">
                        <option value="">All Types</option>
                        <option value="User">Users</option>
                        <option value="Group">Groups</option>
                        <option value="ServicePrincipal">Service Principals</option>
                        <option value="ManagedIdentity">Managed Identities</option>
                    </select>
                </div>
                <div class="filter-group">
                    <select id="roleFilter" onchange="applyFilters()">
                        <option value="">All Roles</option>
                        $(if ($RBACData.Principals) {
                            $uniqueRoles = $RBACData.Principals | ForEach-Object { $_.UniqueRoles } | Select-Object -Unique | Sort-Object
                            foreach ($role in $uniqueRoles) {
                                "<option value='$([System.Web.HttpUtility]::HtmlAttributeEncode($role))'>$([System.Web.HttpUtility]::HtmlEncode($role))</option>"
                            } -join "`n"
                        })
                    </select>
                </div>
                <div class="filter-group">
                    <select id="scopeTypeFilter" onchange="applyFilters()">
                        <option value="">All Scope Types</option>
                        <option value="Tenant Root">Tenant Root</option>
                        <option value="Management Group">Management Group</option>
                        <option value="Subscription">Subscription</option>
                        <option value="Resource Group">Resource Group</option>
                        <option value="Resource">Resource</option>
                    </select>
                </div>
                <div class="filter-group">
                    <label><input type="checkbox" id="redundantOnly" onchange="applyFilters()"> Redundant only</label>
                </div>
                <div class="filter-group">
                    <label><input type="checkbox" id="privilegedOnly" onchange="applyFilters()"> Privileged only</label>
                </div>
                <div class="filter-stats">
                    Showing <span id="visibleCount">0</span> of <span id="totalCount">0</span> principals
                </div>
            </div>
        </div>
"@

    # Principal Access Section (principal cards)
    $principalsHtml = if ($RBACData.Principals) {
        foreach ($principal in $RBACData.Principals) {
            Build-PrincipalCard -Principal $principal
        } -join "`n"
    } else {
        "<p>No principals found.</p>"
    }

    $html += @"
        
        <!-- Principal Access -->
        <div class="section">
            <h2>Principal Access</h2>
            <div class="section-content">
                $principalsHtml
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
        
        // Toggle affects dropdown
        function toggleAffects(toggle) {
            const targetId = toggle.getAttribute('data-target');
            const dropdown = document.getElementById(targetId);
            if (!dropdown) return;
            
            const arrow = toggle.querySelector('.affects-arrow');
            if (!arrow) return;
            
            const isExpanded = dropdown.style.display !== 'none';
            
            if (isExpanded) {
                dropdown.style.display = 'none';
                arrow.innerHTML = '&#9660;';
            } else {
                dropdown.style.display = 'block';
                arrow.innerHTML = '▲';
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
        function applyFilters() {
            const search = document.getElementById('searchInput').value.toLowerCase();
            const typeFilter = document.getElementById('typeFilter').value;
            const roleFilter = document.getElementById('roleFilter').value;
            const scopeTypeFilter = document.getElementById('scopeTypeFilter').value;
            const redundantOnly = document.getElementById('redundantOnly').checked;
            const privilegedOnly = document.getElementById('privilegedOnly').checked;
            
            const rows = document.querySelectorAll('.principal-view-row');
            let visible = 0;
            
            rows.forEach(row => {
                const matchesSearch = !search || row.dataset.search.includes(search);
                const matchesType = !typeFilter || row.dataset.type === typeFilter;
                const matchesRole = !roleFilter || row.dataset.roles.includes(roleFilter);
                const matchesScopeType = !scopeTypeFilter || row.dataset.scopes.includes(scopeTypeFilter);
                
                // For redundant filter, check if any assignment in the card is redundant
                let matchesRedundant = true;
                if (redundantOnly) {
                    const redundantCells = row.querySelectorAll('.redundant-yes');
                    matchesRedundant = redundantCells.length > 0;
                }
                
                // For privileged filter, check if principal has privileged roles
                let matchesPrivileged = true;
                if (privilegedOnly) {
                    matchesPrivileged = row.dataset.privileged === 'True';
                }
                
                if (matchesSearch && matchesType && matchesRole && matchesScopeType && matchesRedundant && matchesPrivileged) {
                    row.style.display = '';
                    visible++;
                } else {
                    row.style.display = 'none';
                }
            });
            
            document.getElementById('visibleCount').textContent = visible;
        }

        function togglePrincipalDetails(header) {
            const row = header.closest('.principal-view-row');
            row.classList.toggle('expanded');
        }

        function toggleAffects(el) {
            el.classList.toggle('expanded');
            event.stopPropagation();
        }

        // Close dropdowns when clicking outside
        document.addEventListener('click', function(e) {
            if (!e.target.closest('.affects-expandable')) {
                document.querySelectorAll('.affects-expandable.expanded').forEach(el => {
                    el.classList.remove('expanded');
                });
            }
        });

        // Initialize
        document.addEventListener('DOMContentLoaded', function() {
            const total = document.querySelectorAll('.principal-view-row').length;
            document.getElementById('totalCount').textContent = total;
            document.getElementById('visibleCount').textContent = total;
            applyFilters();
        });
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

