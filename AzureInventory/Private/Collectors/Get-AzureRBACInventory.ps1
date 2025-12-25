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

    function Get-RiskLevel {
        <#
        .SYNOPSIS
            Calculates risk level based on role and scope.
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
                
                # Update stats
                $stats.TotalAssignments++
                $stats.ByPrincipalType[$principalInfo.ObjectType]++
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

    # Build cross-subscription analysis
    Write-Host "`nBuilding cross-subscription analysis..." -ForegroundColor Cyan

    # Find principals with access to multiple subscriptions
    $crossSubPrincipals = $allAssignments | 
        Where-Object { -not $_.IsOrphaned } |
        Group-Object PrincipalId |
        Where-Object { ($_.Group | Select-Object -ExpandProperty SubscriptionId -Unique).Count -gt 1 } |
        ForEach-Object {
            $subscriptionAccess = $_.Group | Select-Object -ExpandProperty SubscriptionName -Unique
            $highestRisk = ($_.Group | Sort-Object { 
                switch ($_.RiskLevel) { 'Critical' { 0 } 'High' { 1 } 'Medium' { 2 } 'Low' { 3 } }
            } | Select-Object -First 1).RiskLevel
            
            [PSCustomObject]@{
                PrincipalId = $_.Name
                PrincipalDisplayName = $_.Group[0].PrincipalDisplayName
                PrincipalUPN = $_.Group[0].PrincipalUPN
                PrincipalType = $_.Group[0].PrincipalType
                SubscriptionCount = $subscriptionAccess.Count
                Subscriptions = $subscriptionAccess
                AssignmentCount = $_.Count
                HighestRiskLevel = $highestRisk
                Roles = ($_.Group | Select-Object -ExpandProperty RoleDefinitionName -Unique)
                Assignments = $_.Group  # Include all assignments for detailed breakdown
            }
        } | Sort-Object SubscriptionCount -Descending

    # Identify privileged assignments (Owner, Contributor, UAA at broad scope)
    $privilegedAssignments = $allAssignments | 
        Where-Object { $_.RiskLevel -in @('Critical', 'High') } |
        Sort-Object { 
            switch ($_.RiskLevel) { 'Critical' { 0 } 'High' { 1 } 'Medium' { 2 } 'Low' { 3 } }
        }, ScopeLevel

    # Get orphaned assignments
    $orphanedAssignments = $allAssignments | Where-Object { $_.IsOrphaned }

    # Get external/guest assignments
    $externalAssignments = $allAssignments | Where-Object { $_.IsExternal }

    # Get non-human identities (SP and MI)
    $nonHumanAssignments = $allAssignments | 
        Where-Object { $_.PrincipalType -in @('ServicePrincipal', 'ManagedIdentity') } |
        Sort-Object PrincipalDisplayName

    # Role usage analysis
    $roleUsage = $allAssignments |
        Group-Object RoleDefinitionName |
        Select-Object @{N='RoleName';E={$_.Name}}, 
            @{N='AssignmentCount';E={$_.Count}},
            @{N='UniqueSubscriptions';E={($_.Group | Select-Object SubscriptionId -Unique).Count}},
            @{N='PrincipalTypes';E={($_.Group | Select-Object PrincipalType -Unique | ForEach-Object { $_.PrincipalType }) -join ', '}} |
        Sort-Object AssignmentCount -Descending

    $endTime = Get-Date
    $duration = $endTime - $startTime

    Write-Host "`nCollection complete!" -ForegroundColor Green
    Write-Host "Duration: $($duration.TotalSeconds.ToString('F1')) seconds" -ForegroundColor Gray
    Write-Host "Total Assignments: $($stats.TotalAssignments)" -ForegroundColor Gray

    #endregion

    #region Output

    return [PSCustomObject]@{
        Metadata = @{
            TenantId = $currentTenantId
            CollectionTime = $startTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
            Duration = $duration.TotalSeconds
            SubscriptionsScanned = $subscriptions.Count
        }
        Statistics = $stats
        RoleAssignments = $allAssignments.ToArray()
        CustomRoles = $allCustomRoles.ToArray()
        Analysis = @{
            CrossSubscriptionPrincipals = @($crossSubPrincipals)
            PrivilegedAssignments = @($privilegedAssignments)
            OrphanedAssignments = @($orphanedAssignments)
            ExternalAssignments = @($externalAssignments)
            NonHumanIdentities = @($nonHumanAssignments)
            RoleUsage = @($roleUsage)
        }
    }

    #endregion
}

