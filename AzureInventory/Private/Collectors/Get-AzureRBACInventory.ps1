<#
.SYNOPSIS
    Collects RBAC/IAM inventory across Azure subscriptions.

.DESCRIPTION
    Inventories role assignments, custom role definitions, service principals,
    managed identities, and identifies orphaned assignments and privileged access
    patterns across all accessible subscriptions.

.PARAMETER TenantId
    Azure Tenant ID to scan. If not specified, uses current context.

.PARAMETER SubscriptionIds
    Optional array of subscription IDs to limit the scan.

.PARAMETER IncludePIM
    Include PIM eligible assignments (requires Azure AD P2).

.OUTPUTS
    PSCustomObject containing RBAC inventory data.

.EXAMPLE
    $rbacData = Get-AzureRBACInventory -TenantId "your-tenant-id"
    $rbacData | ConvertTo-Json -Depth 10 | Out-File "rbac-inventory.json"
#>

function Get-AzureRBACInventory {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$TenantId,
        
        [Parameter()]
        [string[]]$SubscriptionIds,
        
        [Parameter()]
        [switch]$IncludePIM
    )

    #region Helper Functions

    function Get-InsightId {
        param(
            [string]$TenantId,
            [string]$SubscriptionId,
            [string]$ResourceId,
            [string]$InsightType,
            [string]$RuleId = ""
        )
        
        $key = "$TenantId|$SubscriptionId|$ResourceId|$InsightType|$RuleId"
        $hash = [System.Security.Cryptography.SHA256]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($key)
        $hashBytes = $hash.ComputeHash($bytes)
        return [System.BitConverter]::ToString($hashBytes).Replace("-", "").Substring(0, 16)
    }

    function Get-PrincipalDisplayInfo {
        <#
        .SYNOPSIS
            Resolves principal details with caching to minimize Graph API calls.
        #>
        param(
            [string]$ObjectId,
            [string]$ObjectType,
            [hashtable]$Cache
        )
        
        if ($Cache.ContainsKey($ObjectId)) {
            return $Cache[$ObjectId]
        }
        
        $info = @{
            DisplayName = $null
            UserPrincipalName = $null
            ObjectType = $ObjectType
            IsOrphaned = $false
            IsExternal = $false
            AppId = $null
        }
        
        try {
            switch ($ObjectType) {
                'User' {
                    $user = Get-AzADUser -ObjectId $ObjectId -ErrorAction SilentlyContinue
                    if ($user) {
                        $info.DisplayName = $user.DisplayName
                        $info.UserPrincipalName = $user.UserPrincipalName
                        $info.IsExternal = $user.UserPrincipalName -match '#EXT#'
                    } else {
                        $info.IsOrphaned = $true
                        $info.DisplayName = "[Deleted User: $ObjectId]"
                    }
                }
                'Group' {
                    $group = Get-AzADGroup -ObjectId $ObjectId -ErrorAction SilentlyContinue
                    if ($group) {
                        $info.DisplayName = $group.DisplayName
                    } else {
                        $info.IsOrphaned = $true
                        $info.DisplayName = "[Deleted Group: $ObjectId]"
                    }
                }
                'ServicePrincipal' {
                    $sp = Get-AzADServicePrincipal -ObjectId $ObjectId -ErrorAction SilentlyContinue
                    if ($sp) {
                        $info.DisplayName = $sp.DisplayName
                        $info.AppId = $sp.AppId
                        $info.ObjectType = if ($sp.ServicePrincipalType -eq 'ManagedIdentity') { 'ManagedIdentity' } else { 'ServicePrincipal' }
                    } else {
                        $info.IsOrphaned = $true
                        $info.DisplayName = "[Deleted SP: $ObjectId]"
                    }
                }
                default {
                    # Unknown type - try to resolve
                    $info.DisplayName = "[Unknown: $ObjectId]"
                    $info.IsOrphaned = $true
                }
            }
        }
        catch {
            $info.DisplayName = "[Resolution Failed: $ObjectId]"
            $info.IsOrphaned = $true
        }
        
        $Cache[$ObjectId] = $info
        return $info
    }

    function Get-ScopeInfo {
        <#
        .SYNOPSIS
            Parses Azure scope string into structured components.
        #>
        param([string]$Scope)
        
        $info = @{
            Type = 'Unknown'
            Level = 0
            SubscriptionId = $null
            ResourceGroup = $null
            ResourceType = $null
            ResourceName = $null
            ManagementGroup = $null
            DisplayScope = $Scope
        }
        
        if ($Scope -eq '/') {
            $info.Type = 'Root'
            $info.Level = 0
            $info.DisplayScope = '/ (Root)'
        }
        elseif ($Scope -match '^/providers/Microsoft\.Management/managementGroups/(.+)$') {
            $info.Type = 'ManagementGroup'
            $info.Level = 1
            $info.ManagementGroup = $Matches[1]
            $info.DisplayScope = "MG: $($Matches[1])"
        }
        elseif ($Scope -match '^/subscriptions/([^/]+)$') {
            $info.Type = 'Subscription'
            $info.Level = 2
            $info.SubscriptionId = $Matches[1]
        }
        elseif ($Scope -match '^/subscriptions/([^/]+)/resourceGroups/([^/]+)$') {
            $info.Type = 'ResourceGroup'
            $info.Level = 3
            $info.SubscriptionId = $Matches[1]
            $info.ResourceGroup = $Matches[2]
        }
        elseif ($Scope -match '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/(.+)/([^/]+)$') {
            $info.Type = 'Resource'
            $info.Level = 4
            $info.SubscriptionId = $Matches[1]
            $info.ResourceGroup = $Matches[2]
            $info.ResourceType = $Matches[3]
            $info.ResourceName = $Matches[4]
        }
        elseif ($Scope -match '/providers/') {
            $info.Type = 'Resource'
            $info.Level = 4
        }
        
        return $info
    }

    function Test-ScopeContains {
        <#
        .SYNOPSIS
            Tests if a parent scope contains a child scope.
            For example, a subscription scope contains all resource groups and resources within that subscription.
        #>
        param(
            [string]$ParentScope,
            [string]$ChildScope
        )
        
        # Root contains everything
        if ($ParentScope -eq '/') {
            return $true
        }
        
        # Exact match is not containment (they're the same)
        if ($ParentScope -eq $ChildScope) {
            return $false
        }
        
        # Child scope must start with parent scope path
        # Add trailing slash to parent if it doesn't have one to ensure proper prefix matching
        $parentPrefix = if ($ParentScope.EndsWith('/')) { $ParentScope } else { "$ParentScope/" }
        
        # Check if child starts with parent prefix
        if ($ChildScope.StartsWith($parentPrefix)) {
            return $true
        }
        
        # For Management Group containment, we'd need to check MG hierarchy
        # But for now, just check if both are MGs and the parent MG path matches
        if ($ParentScope -match '^/providers/Microsoft\.Management/managementGroups/(.+)$' -and
            $ChildScope -match '^/providers/Microsoft\.Management/managementGroups/(.+)$') {
            # Without MG hierarchy info, we can't determine if one MG contains another
            # So we'll return false here - MG containment requires hierarchy knowledge
            return $false
        }
        
        # For subscription/child cases, check if parent scope path is a prefix of child
        # This handles: /subscriptions/xxx contains /subscriptions/xxx/resourceGroups/yyy
        if ($ChildScope.StartsWith($ParentScope)) {
            return $true
        }
        
        return $false
    }

    function Get-AccessTier {
        <#
        .SYNOPSIS
            Maps Azure role names to access tiers for governance clarity.
        #>
        param([string]$RoleName)
        
        # Exact matches first
        $exactMap = @{
            'Owner' = @{ Tier = 'FullControl'; Display = 'Full Control'; Order = 0; Color = 'red' }
            'User Access Administrator' = @{ Tier = 'AccessManager'; Display = 'Access Manager'; Order = 1; Color = 'orange' }
            'Role Based Access Control Administrator' = @{ Tier = 'AccessManager'; Display = 'Access Manager'; Order = 1; Color = 'orange' }
            'Contributor' = @{ Tier = 'Administrative'; Display = 'Administrative'; Order = 2; Color = 'yellow' }
            'Security Admin' = @{ Tier = 'PrivilegedOps'; Display = 'Privileged Ops'; Order = 3; Color = 'purple' }
            'Security Administrator' = @{ Tier = 'PrivilegedOps'; Display = 'Privileged Ops'; Order = 3; Color = 'purple' }
            'Key Vault Administrator' = @{ Tier = 'PrivilegedOps'; Display = 'Privileged Ops'; Order = 3; Color = 'purple' }
            'Storage Blob Data Owner' = @{ Tier = 'PrivilegedOps'; Display = 'Privileged Ops'; Order = 3; Color = 'purple' }
            'Reader' = @{ Tier = 'ReadOnly'; Display = 'Read Only'; Order = 5; Color = 'green' }
            'Cost Management Reader' = @{ Tier = 'ReadOnly'; Display = 'Read Only'; Order = 5; Color = 'green' }
        }
        
        if ($exactMap.ContainsKey($RoleName)) {
            return $exactMap[$RoleName]
        }
        
        # Pattern matching fallback
        if ($RoleName -match '^Owner$|Owner \(') { 
            return @{ Tier = 'FullControl'; Display = 'Full Control'; Order = 0; Color = 'red' } 
        }
        if ($RoleName -match 'Access.*Administrator|Administrator.*Access|RBAC.*Administrator') { 
            return @{ Tier = 'AccessManager'; Display = 'Access Manager'; Order = 1; Color = 'orange' } 
        }
        if ($RoleName -match '^Contributor$') { 
            return @{ Tier = 'Administrative'; Display = 'Administrative'; Order = 2; Color = 'yellow' } 
        }
        if ($RoleName -match 'Security|Key Vault|Privileged|Data Owner|Storage.*Owner') { 
            return @{ Tier = 'PrivilegedOps'; Display = 'Privileged Ops'; Order = 3; Color = 'purple' } 
        }
        if ($RoleName -match 'Contributor') { 
            return @{ Tier = 'Write'; Display = 'Write'; Order = 4; Color = 'blue' } 
        }
        if ($RoleName -match 'Reader|Viewer|Monitor') { 
            return @{ Tier = 'ReadOnly'; Display = 'Read Only'; Order = 5; Color = 'green' } 
        }
        
        # Default unknown roles to Write (conservative)
        return @{ Tier = 'Write'; Display = 'Write'; Order = 4; Color = 'blue' }
    }

    function Get-FriendlyScopeName {
        <#
        .SYNOPSIS
            Converts Azure scope paths to friendly display names.
        #>
        param(
            [string]$Scope,
            [hashtable]$SubscriptionNameMap = @{},
            [hashtable]$ManagementGroupNameMap = @{}
        )
        
        if ($Scope -eq '/') {
            return "Tenant Root"
        }
        elseif ($Scope -match '^/providers/Microsoft\.Management/managementGroups/(.+)$') {
            $mgId = $Matches[1]
            if ($ManagementGroupNameMap.ContainsKey($mgId)) {
                return "MG: $($ManagementGroupNameMap[$mgId])"
            }
            return "MG: $mgId"
        }
        elseif ($Scope -match '^/subscriptions/([^/]+)$') {
            $subId = $Matches[1]
            if ($SubscriptionNameMap.ContainsKey($subId)) {
                return "Sub: $($SubscriptionNameMap[$subId])"
            }
            return "Sub: $($subId.Substring(0,8))..."
        }
        elseif ($Scope -match '/subscriptions/([^/]+)/resourceGroups/([^/]+)$') {
            return "RG: $($Matches[2])"
        }
        elseif ($Scope -match '/providers/.+/([^/]+)$') {
            return "Resource: $($Matches[1])"
        }
        return $Scope
    }

    function Get-PrincipalInsights {
        <#
        .SYNOPSIS
            Generates actionable insights for a principal based on their access patterns.
        #>
        param(
            [object]$Principal,
            [array]$AccessEntries
        )
        
        $insights = [System.Collections.Generic.List[object]]::new()
        
        # Tenant root privileged access
        $rootPrivileged = $AccessEntries | Where-Object { 
            $_.ScopeType -eq 'Root' -and $_.AccessTier -in @('FullControl', 'AccessManager') 
        }
        if ($rootPrivileged) {
            $insights.Add([PSCustomObject]@{
                Severity = 'Critical'
                Message = 'Tenant-wide privileged access'
                Icon = '[!!]'
            })
        }
        
        # Both Full Control and Access Manager
        $hasFullControl = $AccessEntries | Where-Object { $_.AccessTier -eq 'FullControl' }
        $hasAccessMgr = $AccessEntries | Where-Object { $_.AccessTier -eq 'AccessManager' }
        if ($hasFullControl -and $hasAccessMgr) {
            $insights.Add([PSCustomObject]@{
                Severity = 'High'
                Message = 'Full Control + Access Manager combined'
                Icon = '[!]'
            })
        }
        
        # External with elevated access
        if ($Principal.IsExternal -and $Principal.HighestAccessTier -in @('FullControl', 'AccessManager', 'Administrative')) {
            $insights.Add([PSCustomObject]@{
                Severity = 'High'
                Message = 'External account with elevated privileges'
                Icon = '[EXT]'
            })
        }
        
        # Privileged Service Principal
        if ($Principal.PrincipalType -eq 'ServicePrincipal' -and $Principal.HighestAccessTier -in @('FullControl', 'AccessManager')) {
            $insights.Add([PSCustomObject]@{
                Severity = 'High'
                Message = 'Service Principal with privileged access'
                Icon = '[SP]'
            })
        }
        
        # Group with privileged access
        if ($Principal.PrincipalType -eq 'Group' -and $Principal.HighestAccessTier -in @('FullControl', 'AccessManager', 'Administrative')) {
            $insights.Add([PSCustomObject]@{
                Severity = 'Medium'
                Message = 'Review group membership in Entra ID'
                Icon = '[i]'
            })
        }
        
        # Redundant assignments
        $redundant = $AccessEntries | Where-Object { $_.IsRedundant }
        if ($redundant.Count -gt 0) {
            $insights.Add([PSCustomObject]@{
                Severity = 'Info'
                Message = "$($redundant.Count) redundant assignment(s)"
                Icon = '[~]'
            })
        }
        
        return $insights.ToArray()
    }

    function Get-RiskLevel {
        <#
        .SYNOPSIS
            Calculates risk level based on role and scope (kept for backward compatibility).
        #>
        param(
            [string]$RoleName,
            [string]$ScopeType,
            [int]$ScopeLevel
        )
        
        $highPrivilegeRoles = @(
            'Owner',
            'Contributor',
            'User Access Administrator',
            'Role Based Access Control Administrator',
            'Security Admin',
            'Key Vault Administrator',
            'Storage Blob Data Owner'
        )
        
        $mediumPrivilegeRoles = @(
            'Virtual Machine Contributor',
            'Network Contributor',
            'Storage Account Contributor',
            'SQL Server Contributor',
            'Key Vault Secrets Officer',
            'Key Vault Certificates Officer'
        )
        
        $isHighPrivilege = $highPrivilegeRoles -contains $RoleName
        $isMediumPrivilege = $mediumPrivilegeRoles -contains $RoleName
        
        # Broad scope (MG, Subscription) with high privilege = Critical
        if ($isHighPrivilege -and $ScopeLevel -le 2) {
            return 'Critical'
        }
        # High privilege at RG level = High
        elseif ($isHighPrivilege -and $ScopeLevel -eq 3) {
            return 'High'
        }
        # Medium privilege at broad scope = High
        elseif ($isMediumPrivilege -and $ScopeLevel -le 2) {
            return 'High'
        }
        # High privilege at resource level = Medium
        elseif ($isHighPrivilege -and $ScopeLevel -ge 4) {
            return 'Medium'
        }
        # Medium privilege = Medium
        elseif ($isMediumPrivilege) {
            return 'Medium'
        }
        # Everything else = Low
        else {
            return 'Low'
        }
    }

    #endregion

    #region Main Collection Logic

    Write-Host "Starting RBAC Inventory Collection..." -ForegroundColor Cyan
    $startTime = Get-Date

    # Get current context
    $context = Get-AzContext
    if (-not $context) {
        throw "Not connected to Azure. Please run Connect-AzAccount first."
    }

    $currentTenantId = if ($TenantId) { $TenantId } else { $context.Tenant.Id }
    Write-Host "Tenant: $currentTenantId" -ForegroundColor Gray

    # Get subscriptions
    $subscriptions = if ($SubscriptionIds) {
        $SubscriptionIds | ForEach-Object { Get-AzSubscription -SubscriptionId $_ -TenantId $currentTenantId }
    } else {
        Get-AzSubscription -TenantId $currentTenantId | Where-Object { $_.State -eq 'Enabled' }
    }

    Write-Host "Found $($subscriptions.Count) subscription(s) to scan" -ForegroundColor Gray

    # Build subscription name map for friendly scope names
    $subscriptionNameMap = @{}
    foreach ($sub in $subscriptions) {
        $subscriptionNameMap[$sub.Id] = $sub.Name
    }

    # Build Management Group name map for friendly scope names
    Write-Host "Collecting Management Groups..." -ForegroundColor Gray
    $managementGroupNameMap = @{}
    try {
        # Get all management groups
        $managementGroups = Get-AzManagementGroup -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        foreach ($mg in $managementGroups) {
            $mgId = $mg.Id -replace '.*/managementGroups/', ''
            $mgName = $mg.DisplayName
            if (-not $mgName) { $mgName = $mg.Name }
            if ($mgName) {
                $managementGroupNameMap[$mgId] = $mgName
            }
        }
        
        # Also try to explicitly get the Tenant Root Group (ID = Tenant ID)
        # The Tenant Root Group ID is the same as the Tenant ID
        try {
            $rootMg = Get-AzManagementGroup -GroupId $currentTenantId -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            if ($rootMg) {
                $rootMgId = $rootMg.Id -replace '.*/managementGroups/', ''
                $rootMgName = $rootMg.DisplayName
                if (-not $rootMgName) { $rootMgName = $rootMg.Name }
                if (-not $rootMgName) { $rootMgName = "Tenant Root Group" }  # Default name
                if ($rootMgName) {
                    $managementGroupNameMap[$rootMgId] = $rootMgName
                }
            }
        }
        catch {
            # If we can't get it, add a default entry for Tenant Root Group
            if (-not $managementGroupNameMap.ContainsKey($currentTenantId)) {
                $managementGroupNameMap[$currentTenantId] = "Tenant Root Group"
            }
            Write-Verbose "Could not retrieve Tenant Root Group explicitly: $_"
        }
        
        Write-Host "  Found $($managementGroupNameMap.Count) Management Group(s)" -ForegroundColor Gray
    }
    catch {
        Write-Verbose "Could not retrieve Management Groups: $_"
        # Even if we fail, add default Tenant Root Group entry
        if (-not $managementGroupNameMap.ContainsKey($currentTenantId)) {
            $managementGroupNameMap[$currentTenantId] = "Tenant Root Group"
        }
    }

    # Initialize collections
    $allAssignments = [System.Collections.Generic.List[object]]::new()
    $allCustomRoles = [System.Collections.Generic.List[object]]::new()
    $principalCache = @{}

    # Track statistics
    $stats = @{
        TotalAssignments = 0
        ByPrincipalType = @{
            User = 0
            Group = 0
            ServicePrincipal = 0
            ManagedIdentity = 0
            Unknown = 0
        }
        ByRiskLevel = @{
            Critical = 0
            High = 0
            Medium = 0
            Low = 0
        }
        ByScopeType = @{
            ManagementGroup = 0
            Subscription = 0
            ResourceGroup = 0
            Resource = 0
        }
        OrphanedCount = 0
        ExternalCount = 0
        CustomRoleCount = 0
    }

    # Collect role assignments per subscription
    foreach ($sub in $subscriptions) {
        Write-Host "`nProcessing subscription: $($sub.Name)" -ForegroundColor Yellow
        
        try {
            Set-AzContext -SubscriptionId $sub.Id -TenantId $currentTenantId -ErrorAction Stop | Out-Null
            
            # Get role assignments
            $assignments = Get-AzRoleAssignment -ErrorAction SilentlyContinue
            Write-Host "  Found $($assignments.Count) role assignments" -ForegroundColor Gray
            
            foreach ($assignment in $assignments) {
                # Resolve principal
                $principalInfo = Get-PrincipalDisplayInfo -ObjectId $assignment.ObjectId `
                    -ObjectType $assignment.ObjectType -Cache $principalCache
                
                # Parse scope
                $scopeInfo = Get-ScopeInfo -Scope $assignment.Scope
                
                # Determine if assignment is inherited or directly assigned
                # When collecting at subscription level:
                # - MG or Root scope = Inherited (assignment made at parent level)
                # - Subscription/RG/Resource scope within current sub = Assigned (direct assignment)
                # - Subscription scope in different sub = Inherited (shouldn't happen, but handle it)
                $isInherited = $false
                if ($scopeInfo.Type -eq 'ManagementGroup' -or $scopeInfo.Type -eq 'Root') {
                    # Assignment made at MG or Root level - inherited to this subscription
                    $isInherited = $true
                }
                elseif ($scopeInfo.SubscriptionId -and $scopeInfo.SubscriptionId -ne $sub.Id) {
                    # Scope is in a different subscription (shouldn't happen, but just in case)
                    $isInherited = $true
                }
                elseif ($scopeInfo.Type -eq 'Subscription' -and $scopeInfo.SubscriptionId -eq $sub.Id) {
                    # Direct assignment at this subscription level
                    $isInherited = $false
                }
                elseif ($scopeInfo.Type -in @('ResourceGroup', 'Resource') -and $scopeInfo.SubscriptionId -eq $sub.Id) {
                    # Direct assignment at RG or Resource level within this subscription
                    $isInherited = $false
                }
                else {
                    # Default: assume assigned if we can't determine (safety fallback)
                    $isInherited = $false
                }
                
                # For MG/Root assignments, keep the actual subscription name so we can aggregate later
                # The report will deduplicate and show all affected subscriptions
                $effectiveSubscriptionName = $sub.Name
                
                # Calculate risk
                $riskLevel = Get-RiskLevel -RoleName $assignment.RoleDefinitionName `
                    -ScopeType $scopeInfo.Type -ScopeLevel $scopeInfo.Level
                
                # Generate insight ID
                $insightId = Get-InsightId -TenantId $currentTenantId `
                    -SubscriptionId $sub.Id `
                    -ResourceId $assignment.RoleAssignmentId `
                    -InsightType "RBACAssignment"
                
                $record = [PSCustomObject]@{
                    InsightId = $insightId
                    
                    # Assignment details
                    RoleAssignmentId = $assignment.RoleAssignmentId
                    RoleDefinitionName = $assignment.RoleDefinitionName
                    RoleDefinitionId = $assignment.RoleDefinitionId
                    IsInherited = $isInherited
                    
                    # Principal details
                    PrincipalId = $assignment.ObjectId
                    PrincipalType = $principalInfo.ObjectType
                    PrincipalDisplayName = $principalInfo.DisplayName
                    PrincipalUPN = $principalInfo.UserPrincipalName
                    AppId = $principalInfo.AppId
                    IsOrphaned = $principalInfo.IsOrphaned
                    IsExternal = $principalInfo.IsExternal
                    
                    # Scope details
                    Scope = $assignment.Scope
                    ScopeType = $scopeInfo.Type
                    ScopeLevel = $scopeInfo.Level
                    ScopeDisplayName = $scopeInfo.DisplayScope
                    
                    # Subscription context
                    SubscriptionId = $sub.Id
                    SubscriptionName = $effectiveSubscriptionName
                    EffectiveInSubscriptions = if ($scopeInfo.Type -in @('ManagementGroup', 'Root')) { @($sub.Name) } else { @($sub.Name) }
                    
                    # Risk assessment
                    RiskLevel = $riskLevel
                    
                    # Metadata
                    CanDelegate = $assignment.CanDelegate
                    Description = $assignment.Description
                    Condition = $assignment.Condition
                    CreatedOn = $assignment.CreatedOn
                    UpdatedOn = $assignment.UpdatedOn
                }
                
                $allAssignments.Add($record)
                
                # Update stats - handle unknown types
                $stats.TotalAssignments++
                $principalTypeKey = $principalInfo.ObjectType
                if (-not $stats.ByPrincipalType.ContainsKey($principalTypeKey)) {
                    $principalTypeKey = 'Unknown'
                }
                $stats.ByPrincipalType[$principalTypeKey]++
                $stats.ByRiskLevel[$riskLevel]++
                if ($scopeInfo.Type -ne 'Unknown') {
                    $stats.ByScopeType[$scopeInfo.Type]++
                }
                if ($principalInfo.IsOrphaned) { $stats.OrphanedCount++ }
                if ($principalInfo.IsExternal) { $stats.ExternalCount++ }
            }
            
            # Get custom role definitions
            $customRoles = Get-AzRoleDefinition -Custom -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            foreach ($role in $customRoles) {
                # Avoid duplicates (custom roles can appear in multiple subscriptions)
                if (-not ($allCustomRoles | Where-Object { $_.Id -eq $role.Id })) {
                    $customRoleRecord = [PSCustomObject]@{
                        Id = $role.Id
                        Name = $role.Name
                        Description = $role.Description
                        IsCustom = $true
                        Actions = $role.Actions
                        NotActions = $role.NotActions
                        DataActions = $role.DataActions
                        NotDataActions = $role.NotDataActions
                        AssignableScopes = $role.AssignableScopes
                    }
                    $allCustomRoles.Add($customRoleRecord)
                    $stats.CustomRoleCount++
                }
            }
        }
        catch {
            Write-Warning "Failed to process subscription $($sub.Name): $_"
        }
    }

    # Deduplicate assignments by (PrincipalId, RoleDefinitionId, Scope)
    Write-Host "`nDeduplicating assignments..." -ForegroundColor Cyan
    $uniqueAssignments = $allAssignments | 
        Group-Object -Property PrincipalId, RoleDefinitionId, Scope |
        ForEach-Object {
            $first = $_.Group[0]
            $inheritedBy = $_.Group | 
                Where-Object { $_.SubscriptionName -ne "Multiple subscriptions" } |
                Select-Object -ExpandProperty SubscriptionName -Unique
            
            # Add inheritance tracking
            $first | Add-Member -NotePropertyName 'InheritedBySubscriptions' -NotePropertyValue $inheritedBy -Force
            $first | Add-Member -NotePropertyName 'InheritanceCount' -NotePropertyValue $inheritedBy.Count -Force
            $first
        }

    Write-Host "  Unique assignments: $($uniqueAssignments.Count) (from $($allAssignments.Count) total)" -ForegroundColor Gray

    # Build principal-centric view with access tiers
    Write-Host "`nBuilding principal-centric view with access tiers..." -ForegroundColor Cyan
    
    $principalView = $uniqueAssignments |
        Group-Object PrincipalId |
        ForEach-Object {
            $assignments = $_.Group
            $first = $assignments[0]
            
            # Map each assignment to access tier and build access entries
            $accessEntries = $assignments | ForEach-Object {
                $tierInfo = Get-AccessTier -RoleName $_.RoleDefinitionName
                $tierName = $tierInfo['Tier']
                $tierOrder = $tierInfo['Order']
                $scopeInfo = Get-ScopeInfo -Scope $_.Scope
                $scopeFriendlyName = Get-FriendlyScopeName -Scope $_.Scope -SubscriptionNameMap $subscriptionNameMap -ManagementGroupNameMap $managementGroupNameMap
                
                # Determine grant type
                # Every role assignment is "Direct" at its scope
                # "Inherited" only makes sense for group membership (which we can't see without Directory Reader)
                # The IsInherited flag from collection is about scope hierarchy, not assignment type
                $grantType = "Direct"
                $inheritedFrom = $null
                
                # Build affected subscriptions list
                $affectsSubs = @()
                if ($_.InheritedBySubscriptions -and $_.InheritedBySubscriptions.Count -gt 0) {
                    if ($scopeInfo.Type -eq 'Root') {
                        $affectsSubs = @("All $($_.InheritedBySubscriptions.Count) subscriptions")
                    } else {
                        $affectsSubs = $_.InheritedBySubscriptions
                    }
                } elseif ($scopeInfo.Type -eq 'Subscription' -and $_.SubscriptionName) {
                    $affectsSubs = @($_.SubscriptionName)
                } elseif ($scopeInfo.Type -in @('ResourceGroup', 'Resource') -and $_.SubscriptionName) {
                    $affectsSubs = @($_.SubscriptionName)
                }
                
                [PSCustomObject]@{
                    Role = $_.RoleDefinitionName
                    Scope = $_.Scope
                    ScopeType = $scopeInfo.Type
                    ScopeLevel = $scopeInfo.Level
                    ScopeFriendlyName = $scopeFriendlyName
                    AccessTier = $tierName
                    AccessTierOrder = $tierOrder
                    GrantType = $grantType
                    InheritedFrom = $inheritedFrom
                    AffectedSubscriptions = $affectsSubs
                    IsRedundant = $false  # Will be calculated below
                    RedundantReason = $null  # Will be populated below
                    AssignmentId = $_.RoleAssignmentId
                }
            }
            
            # Mark redundant assignments (same or higher tier at broader scope)
            # An assignment is redundant if the same role is assigned at a broader scope that contains this scope
            foreach ($entry in $accessEntries) {
                $dominated = $accessEntries | Where-Object {
                    $broaderEntry = $_
                    # Skip self
                    if ($broaderEntry.Scope -eq $entry.Scope -and $broaderEntry.Role -eq $entry.Role) { return $false }
                    
                    # Check tier, scope level, and role match
                    if ($broaderEntry.AccessTierOrder -gt $entry.AccessTierOrder) { return $false }
                    if ($broaderEntry.ScopeLevel -ge $entry.ScopeLevel) { return $false }
                    if ($broaderEntry.Role -ne $entry.Role) { return $false }
                    
                    # Check scope containment
                    # For MG/Root scopes containing Subscription/RG/Resource scopes, use AffectedSubscriptions
                    if ($broaderEntry.ScopeType -in @('ManagementGroup', 'Root')) {
                        # Root scope affects all subscriptions
                        if ($broaderEntry.ScopeType -eq 'Root') {
                            return $true
                        }
                        
                        # For MG scopes, check if the entry's subscription is in the MG's affected subscriptions
                        if ($entry.ScopeType -in @('Subscription', 'ResourceGroup', 'Resource') -and $entry.AffectedSubscriptions.Count -gt 0 -and $broaderEntry.AffectedSubscriptions.Count -gt 0) {
                            # Check each subscription in the entry against the broader entry's affected subscriptions
                            foreach ($entrySubName in $entry.AffectedSubscriptions) {
                                if ($broaderEntry.AffectedSubscriptions -contains $entrySubName) {
                                    return $true
                                }
                            }
                        }
                        return $false
                    }
                    
                    # For Subscription containing ResourceGroup/Resource, use path-based check
                    if ($broaderEntry.ScopeType -eq 'Subscription' -and $entry.ScopeType -in @('ResourceGroup', 'Resource')) {
                        return (Test-ScopeContains -ParentScope $broaderEntry.Scope -ChildScope $entry.Scope)
                    }
                    
                    # For ResourceGroup containing Resource, use path-based check
                    if ($broaderEntry.ScopeType -eq 'ResourceGroup' -and $entry.ScopeType -eq 'Resource') {
                        return (Test-ScopeContains -ParentScope $broaderEntry.Scope -ChildScope $entry.Scope)
                    }
                    
                    return $false
                }
                if ($dominated) {
                    $entry.IsRedundant = $true
                    # Find the dominating assignment and explain why
                    $dominatingEntry = $dominated | Sort-Object ScopeLevel | Select-Object -First 1
                    $entry.RedundantReason = "Redundant: Same role ($($entry.Role)) already assigned at $($dominatingEntry.ScopeFriendlyName) (broader scope)"
                }
            }
            
            # Group by access tier
            $accessByTier = @{}
            foreach ($tierName in @('FullControl', 'AccessManager', 'Administrative', 'PrivilegedOps', 'Write', 'ReadOnly')) {
                $tierEntries = $accessEntries | Where-Object { $_.AccessTier -eq $tierName }
                if ($tierEntries) {
                    $accessByTier[$tierName] = @($tierEntries)
                }
            }
            
            # Calculate highest tier
            $highestEntry = $accessEntries | Sort-Object AccessTierOrder | Select-Object -First 1
            
            # Get all affected subscriptions
            $allAffectedSubs = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($entry in $accessEntries) {
                foreach ($sub in $entry.AffectedSubscriptions) {
                    if ($sub -notmatch '^All \d+ subscriptions$') {
                        $null = $allAffectedSubs.Add($sub)
                    }
                }
            }
            $allAffectedSubsArray = [array]($allAffectedSubs | Sort-Object)
            
            # Get unique roles summary
            $rolesSummary = $accessEntries | Select-Object -ExpandProperty Role -Unique | Sort-Object
            
            # Build principal object
            $principal = [PSCustomObject]@{
                PrincipalId = $first.PrincipalId
                PrincipalDisplayName = $first.PrincipalDisplayName
                PrincipalType = $first.PrincipalType
                PrincipalUPN = $first.PrincipalUPN
                AppId = $first.AppId
                IsOrphaned = $first.IsOrphaned
                IsExternal = $first.IsExternal
                
                HighestAccessTier = $highestEntry.AccessTier
                HighestAccessTierOrder = $highestEntry.AccessTierOrder
                RolesSummary = $rolesSummary
                ScopeCount = $accessEntries.Count
                AffectedSubscriptions = $allAffectedSubsArray
                AffectedSubscriptionCount = $allAffectedSubsArray.Count
                
                AccessByTier = $accessByTier
                
                Insights = @()  # Will be populated below
            }
            
            # Generate insights
            $principal.Insights = Get-PrincipalInsights -Principal $principal -AccessEntries $accessEntries
            
            $principal
        } | Sort-Object HighestAccessTierOrder, PrincipalDisplayName

    Write-Host "  Unique principals: $($principalView.Count)" -ForegroundColor Gray

    # Enhance custom roles with usage tracking
    Write-Host "`nTracking custom role usage..." -ForegroundColor Cyan
    $customRoleUsage = $uniqueAssignments |
        Where-Object { $_.RoleDefinitionId } |
        Group-Object RoleDefinitionId
    
    $customRoleIdMap = @{}
    foreach ($role in $allCustomRoles) {
        $customRoleIdMap[$role.Id] = $role
    }
    
    foreach ($customRole in $allCustomRoles) {
        $usage = $customRoleUsage | Where-Object { $_.Name -eq $customRole.Id }
        if ($usage) {
            $assignments = $usage.Group
            $usedByPrincipals = $assignments | Select-Object -ExpandProperty PrincipalDisplayName -Unique | Sort-Object
            $assignedScopes = $assignments | Select-Object -ExpandProperty ScopeType -Unique
            
            $customRole | Add-Member -NotePropertyName 'AssignmentCount' -NotePropertyValue $assignments.Count -Force
            $customRole | Add-Member -NotePropertyName 'UsedByPrincipals' -NotePropertyValue [array]$usedByPrincipals -Force
            $customRole | Add-Member -NotePropertyName 'AssignedScopes' -NotePropertyValue [array]$assignedScopes -Force
        } else {
            $customRole | Add-Member -NotePropertyName 'AssignmentCount' -NotePropertyValue 0 -Force
            $customRole | Add-Member -NotePropertyName 'UsedByPrincipals' -NotePropertyValue @() -Force
            $customRole | Add-Member -NotePropertyName 'AssignedScopes' -NotePropertyValue @() -Force
        }
    }

    # Get orphaned assignments (from unique assignments)
    $orphanedAssignments = $uniqueAssignments | Where-Object { $_.IsOrphaned }

    $endTime = Get-Date
    $duration = $endTime - $startTime

    # Build access matrix data
    Write-Host "`nBuilding access matrix..." -ForegroundColor Cyan
    $accessMatrix = @{}
    $scopeLevels = @('Root', 'ManagementGroup', 'Subscription', 'ResourceGroup', 'Resource')
    $tierNames = @('FullControl', 'AccessManager', 'Administrative', 'PrivilegedOps', 'Write', 'ReadOnly')
    
    foreach ($tierName in $tierNames) {
        $accessMatrix[$tierName] = @{}
        foreach ($scopeLevel in $scopeLevels) {
            $count = 0
            foreach ($principal in $principalView) {
                if ($principal.AccessByTier -and $principal.AccessByTier.ContainsKey($tierName)) {
                    $tierEntries = $principal.AccessByTier[$tierName]
                    $matchingEntries = $tierEntries | Where-Object { $_.ScopeType -eq $scopeLevel }
                    if ($matchingEntries) {
                        $count++  # Count this principal once per tier/scope combination
                    }
                }
            }
            $accessMatrix[$tierName][$scopeLevel] = $count
        }
    }
    
    # Recalculate statistics based on unique assignments and principals
    $newStats = @{
        TotalUniqueAssignments = $uniqueAssignments.Count
        TotalPrincipals = $principalView.Count
        PrincipalsByType = @{
            User = @($principalView | Where-Object { $_.PrincipalType -eq 'User' }).Count
            Group = @($principalView | Where-Object { $_.PrincipalType -eq 'Group' }).Count
            ServicePrincipal = @($principalView | Where-Object { $_.PrincipalType -eq 'ServicePrincipal' }).Count
            ManagedIdentity = @($principalView | Where-Object { $_.PrincipalType -eq 'ManagedIdentity' }).Count
            Unknown = @($principalView | Where-Object { $_.PrincipalType -notin @('User', 'Group', 'ServicePrincipal', 'ManagedIdentity') }).Count
        }
        ByAccessTier = @{
            FullControl = @($principalView | Where-Object { $_.AccessByTier -and $_.AccessByTier.ContainsKey('FullControl') }).Count
            AccessManager = @($principalView | Where-Object { $_.AccessByTier -and $_.AccessByTier.ContainsKey('AccessManager') }).Count
            Administrative = @($principalView | Where-Object { $_.AccessByTier -and $_.AccessByTier.ContainsKey('Administrative') }).Count
            PrivilegedOps = @($principalView | Where-Object { $_.AccessByTier -and $_.AccessByTier.ContainsKey('PrivilegedOps') }).Count
            Write = @($principalView | Where-Object { $_.AccessByTier -and $_.AccessByTier.ContainsKey('Write') }).Count
            ReadOnly = @($principalView | Where-Object { $_.AccessByTier -and $_.AccessByTier.ContainsKey('ReadOnly') }).Count
        }
        OrphanedCount = ($principalView | Where-Object { $_.IsOrphaned }).Count
        ExternalCount = ($principalView | Where-Object { $_.IsExternal }).Count
        RedundantCount = ($principalView | ForEach-Object {
            $redundantCount = 0
            foreach ($tierName in @('FullControl', 'AccessManager', 'Administrative', 'PrivilegedOps', 'Write', 'ReadOnly')) {
                if ($_.AccessByTier -and $_.AccessByTier.ContainsKey($tierName)) {
                    $redundantEntries = $_.AccessByTier[$tierName] | Where-Object { $_.IsRedundant }
                    if ($redundantEntries) {
                        $redundantCount += $redundantEntries.Count
                    }
                }
            }
            $redundantCount
        } | Measure-Object -Sum).Sum
        CustomRoleCount = $allCustomRoles.Count
    }

    Write-Host "`nCollection complete!" -ForegroundColor Green
    Write-Host "Duration: $($duration.TotalSeconds.ToString('F1')) seconds" -ForegroundColor Gray
    Write-Host "Unique Assignments: $($uniqueAssignments.Count) (from $($allAssignments.Count) collected)" -ForegroundColor Gray
    Write-Host "Unique Principals: $($principalView.Count)" -ForegroundColor Gray

    #endregion

    #region Output

    # Build subscription names array for metadata
    $subscriptionNames = @($subscriptions | Select-Object -ExpandProperty Name | Sort-Object)
    
    return [PSCustomObject]@{
        Metadata = @{
            TenantId = $currentTenantId
            CollectionTime = $startTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
            Duration = $duration.TotalSeconds
            SubscriptionsScanned = $subscriptions.Count
            SubscriptionNames = $subscriptionNames
        }
        Statistics = $newStats
        Principals = $principalView
        AccessMatrix = $accessMatrix
        CustomRoles = $allCustomRoles.ToArray()
        OrphanedAssignments = @($orphanedAssignments)
        # Keep old structure for backward compatibility during transition
        RoleAssignments = $allAssignments.ToArray()
        Analysis = @{
            # Keep minimal analysis for backward compatibility
            OrphanedAssignments = @($orphanedAssignments)
        }
    }

    #endregion
}

