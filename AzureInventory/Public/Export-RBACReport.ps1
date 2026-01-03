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
            'Critical' { return 'badge badge--critical' }
            'High' { return 'badge badge--high' }
            'Medium' { return 'badge badge--medium' }
            'Low' { return 'badge badge--low' }
            default { return 'badge badge--low' }
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

    function New-PrincipalCardHtml {
        param([object]$Principal)
        
        # Icon based on type
        $icon = switch ($Principal.PrincipalType) {
            'User' { '&#128100;' }
            'Group' { '&#128101;' }
            'ServicePrincipal' { '&#129302;' }
            'ManagedIdentity' { '&#9881;' }
            default { '&#10067;' }
        }
        
        # Border color class
        $borderClass = if ($Principal.IsOrphaned) { 
            'border-purple' 
        } elseif ($Principal.IsExternal) { 
            'border-orange' 
        } else { 
            'border-blue' 
        }
        
        # Display name and subtitle
        $displayName = Encode-Html -Text $Principal.PrincipalDisplayName
        $subtitle = if ($Principal.PrincipalUPN) {
            "<div class='principal-view-subtitle'>$(Encode-Html -Text $Principal.PrincipalUPN)</div>"
        } elseif ($Principal.AppId) {
            "<div class='principal-view-subtitle'>AppId: $($Principal.AppId.Substring(0,8))...</div>"
        } else { "" }
        
        # Badges
        $badges = ""
        if ($Principal.IsOrphaned) { $badges += '<span class="badge badge--orphaned">Orphaned</span>' }
        if ($Principal.IsExternal) { $badges += '<span class="badge badge--external">External</span>' }
        $badges += "<span class='badge badge--neutral'>$($Principal.PrincipalType)</span>"
        if ($Principal.HasPrivilegedRoles) { $badges += '<span class="badge badge--critical">Privileged</span>' }
        
        # Stats line - formatted with spans for better spacing
        $statsLine = @(
            "<span>&#128193; $($Principal.AssignmentCount) assignments</span>",
            "<span>&#127894; $($Principal.RoleCount) roles</span>",
            "<span>&#128273; $($Principal.SubscriptionCount) subscriptions</span>"
        ) -join ''
        
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
                    $reasonEncoded = Encode-Html -Text $a.RedundantReason
                    "<span class='redundant-yes' title='$reasonEncoded'>Yes &#9432;</span>"
                } else {
                    '<span class="redundant-yes">Yes</span>'
                }
            } else { 
                '-' 
            }
            
            $privilegedHtml = if ($a.IsPrivileged) {
                '<span class="badge badge--critical">Privileged</span>'
            } else {
                '-'
            }
            
            @"
        <tr>
            <td>$(Encode-Html -Text $a.Role)</td>
            <td>$scopeIcon $(Encode-Html -Text $a.ScopeType)</td>
            <td>$(Encode-Html -Text $a.ScopeName)</td>
            <td>$subsHtml</td>
            <td>$privilegedHtml</td>
            <td>$redundantHtml</td>
        </tr>
"@
        }
        
        # Get unique scope types for this principal
        $uniqueScopeTypes = $Principal.Assignments | ForEach-Object { $_.ScopeType } | Select-Object -Unique | Sort-Object
        
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
<div class="principal-view-row $borderClass" 
     id="principal-$principalId"
     data-type="$($Principal.PrincipalType)"
     data-orphaned="$($Principal.IsOrphaned)"
     data-external="$($Principal.IsExternal)"
     data-privileged="$($Principal.HasPrivilegedRoles)"
     data-roles="$($Principal.UniqueRoles -join ',')"
     data-scopes="$($uniqueScopeTypes -join ',')"
     data-search="$($searchData.ToLower())">
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
            <table class="data-table data-table--compact">
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
    # $assignments = $RBACData.Assignments # Unused
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

        # Get base stylesheet (report-specific CSS from _reports folder is automatically included)

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>RBAC/IAM Inventory Report</title>
    <style>
$(Get-ReportStylesheet)
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
        <div class="warning-banner">
            <span class="banner-icon">&#9888;</span>
            <div class="banner-content">
                <strong>Limited Entra ID Access</strong>
                <p>
                    Unable to resolve $unresolvedCount principal name(s). The audit account lacks Directory Reader access to Entra ID. Principal IDs are shown instead of display names.
                </p>
            </div>
        </div>
"@
        } elseif ($RBACData.Metadata.UnresolvedPrincipalCount -gt 0) {
            $unresolvedCount = $RBACData.Metadata.UnresolvedPrincipalCount
            @"
        <!-- External Principals Info -->
        <div class="info-banner">
            <span class="banner-icon">&#8505;</span>
            <div class="banner-content">
                <strong>External Principals</strong>
                <p>
                    $unresolvedCount external principal(s) could not be resolved (B2B guests or groups from external tenants).
                </p>
            </div>
        </div>
"@
        })
        
        <!-- Summary Cards -->
        <div class="section-box">
            <h2>Overview</h2>
            <div class="summary-grid">
                <div class="summary-card blue-border">
                    <div class="summary-card-value">$($stats.TotalPrincipals)</div>
                    <div class="summary-card-label">Principals</div>
                </div>
                <div class="summary-card red-border">
                    <div class="summary-card-value">$($stats.ByRiskTier.Privileged)</div>
                    <div class="summary-card-label">Privileged Assignments</div>
                </div>
                <div class="summary-card purple-border">
                    <div class="summary-card-value">$($stats.OrphanedCount)</div>
                    <div class="summary-card-label">Orphaned</div>
                </div>
                <div class="summary-card orange-border">
                    <div class="summary-card-value">$($stats.RedundantCount)</div>
                    <div class="summary-card-label">Redundant</div>
                </div>
            </div>
        </div>
        
        <!-- Access Matrix -->
        <div class="section-box">
            <h2>Access Distribution</h2>
            <div class="table-container">
            <table class="data-table data-table--sticky-header data-table--compact">
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
                            '<span class="badge badge--critical">Privileged</span>'
                        } else {
                            '-'
                        }
                        @"
                    <tr>
                        <td>$(Encode-Html -Text $roleName)</td>
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
        </div>
        
        <!-- Filters -->
        <div class="section-box">
            <h2>Filters</h2>
            <div class="filter-section">
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
                                $roleValue = Encode-Html -Text $role
                                "<option value='$roleValue'>$roleValue</option>"
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
            </div>
            <div class="filter-stats">
                Showing <span id="visibleCount">0</span> of <span id="totalCount">0</span> principals
            </div>
        </div>
"@

    # Principal Access Section (principal cards)
    $principalsHtml = if ($RBACData.Principals) {
        foreach ($principal in $RBACData.Principals) {
            New-PrincipalCardHtml -Principal $principal
        } -join "`n"
    } else {
        "<p>No principals found.</p>"
    }

    $html += @"
        
        <!-- Principal Access -->
        <div class="section-box">
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
        <div class="section-box">
            <div class="expandable expandable--collapsed">
                <div class="expandable__header" onclick="toggleSection(this)">
                    <div class="expandable__title">
                        <span class="expand-icon"></span>
                        <h2>&#128123; Orphaned Assignments</h2>
                    </div>
                    <div class="expandable__badges">
                        <span class="badge badge--critical">$orphanedCount assignments ($($orphanedGroupList.Count) deleted principals)</span>
                    </div>
                </div>
                <div class="expandable__content">
                    <p class="section-description">
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
                <div class="principal-view-row border-purple" id="$orphanedPrincipalId">
                    <div class="principal-view-header" data-principal-id="$orphanedPrincipalId" onclick="togglePrincipalDetails(this)">
                        <div class="principal-view-info">
                            <div class="principal-view-name">
                                $icon $principalNameEncoded
                                <span class="badge badge--orphaned">$($orphanedPrincipal.PrincipalType)</span>
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
                        <div class="orphaned-principal-info">
                            <strong>Principal ID:</strong> <code>$principalIdEncoded</code>
                        </div>
                        <div class="orphaned-principal-info">
                            <strong>Subscriptions:</strong> $subscriptionsListEncoded
                        </div>
                        <div class="orphaned-principal-info orphaned-principal-info--last">
                            <strong>Roles:</strong> $rolesListEncoded
                        </div>
                        <div class="table-container">
                            <table class="data-table data-table--compact">
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
                                                '<span class="subscription-na">N/A</span>'
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
        <div class="section-box">
            <div class="expandable expandable--collapsed">
                <div class="expandable__header" onclick="toggleSection(this)">
                    <div class="expandable__title">
                        <span class="expand-icon"></span>
                        <h2>&#127912; Custom Role Definitions</h2>
                    </div>
                    <div class="expandable__badges">
                        <span class="badge badge--neutral">$($customRoles.Count)</span>
                    </div>
                </div>
                <div class="expandable__content">
                    <p class="section-description">
                        Tenant-specific custom roles. Click on any role to expand and see detailed permissions and usage.
                    </p>
"@

        foreach ($role in $customRoles) {
            $actionsCount = if ($role.Actions) { $role.Actions.Count } else { 0 }
            $dataActionsCount = if ($role.DataActions) { $role.DataActions.Count } else { 0 }
            $assignmentCount = if ($role.AssignmentCount) { $role.AssignmentCount } else { 0 }
            $safeRoleId = ($role.Id -replace '[^a-zA-Z0-9\-]', '-')
            $roleCardId = "role-$safeRoleId"
            
            $roleNameEncoded = Encode-Html $role.Name
            $roleDescEncoded = Encode-Html $role.Description
            
            $html += @"
                <div class="custom-role-card" id="$roleCardId">
                    <div class="expandable__header custom-role-header" onclick="toggleCustomRole(this)">
                        <div class="custom-role-info">
                            <div class="custom-role-name-block">
                                <span class="custom-role-name">$roleNameEncoded</span>
                                $(if ($roleDescEncoded) { "<span class='custom-role-desc'>$roleDescEncoded</span>" })
                            </div>
                            <div class="custom-role-summary">
                                <span class="badge badge--neutral">$actionsCount Actions</span>
                                <span class="badge badge--neutral">$dataActionsCount Data Actions</span>
                                <span class="badge $(if ($assignmentCount -gt 0) { 'badge--critical' } else { 'badge--low' })">$assignmentCount Assignments</span>
                            </div>
                        </div>
                        <span class="toggle-icon">&#9660;</span>
                    </div>
                    <div class="custom-role-details">
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
            const expandable = header.closest('.expandable');
            if (expandable) {
                expandable.classList.toggle('expandable--collapsed');
            }
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
            const card = header.closest('.custom-role-card');
            if (card) {
                card.classList.toggle('expanded');
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

    # Return metadata for Dashboard consumption
    return @{
        OutputPath = $OutputPath
        Statistics = $RBACData.Statistics
    }
}

