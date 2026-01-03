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
            Uses Microsoft Graph REST API to avoid requiring Graph scope in Azure PowerShell connection.
        #>
        param(
            [string]$ObjectId,
            [string]$ObjectType,
            [hashtable]$Cache,
            [string]$KnownDisplayName = $null,
            [string]$KnownUPN = $null
        )
        
        if ($Cache.ContainsKey($ObjectId)) {
            return $Cache[$ObjectId]
        }
        
        $info = @{
            DisplayName = $KnownDisplayName
            UserPrincipalName = $KnownUPN
            ObjectType = $ObjectType
            IsOrphaned = $false
            IsExternal = $false
            AppId = $null
        }
        
        # Use cached Graph token (set at collector level)
        $graphToken = $script:graphToken
        
        try {
            switch ($ObjectType) {
                'User' {
                    # Try Graph REST API first if we have a token
                    if ($graphToken) {
                        try {
                            $headers = @{
                                'Authorization' = "Bearer $graphToken"
                                'Content-Type' = 'application/json'
                            }
                            $graphUri = "https://graph.microsoft.com/v1.0/users/$ObjectId"
                            $userResponse = Invoke-RestMethod -Method GET -Uri $graphUri -Headers $headers -ErrorAction Stop
                            if ($userResponse) {
                                $info.DisplayName = $userResponse.displayName
                                $info.UserPrincipalName = $userResponse.userPrincipalName
                                $info.IsExternal = $userResponse.userPrincipalName -match '#EXT#' -or $userResponse.userType -eq 'Guest'
                            }
                        }
                        catch {
                            Write-Verbose "Graph API call failed for user $ObjectId : $_"
                            # Fall through to try Get-AzADUser
                        }
                    }
                    
                    # Fallback to Get-AzADUser if Graph API didn't work or no token
                    if (-not $info.DisplayName -or $info.DisplayName -eq $ObjectId) {
                        $user = Get-AzADUser -ObjectId $ObjectId -ErrorAction SilentlyContinue
                        if ($user) {
                            $info.DisplayName = $user.DisplayName
                            $info.UserPrincipalName = $user.UserPrincipalName
                            $info.IsExternal = $user.UserPrincipalName -match '#EXT#'
                        }
                        else {
                            # Resolution failed - use KnownDisplayName if available, otherwise use ObjectId
                            if ($KnownDisplayName) {
                                $info.DisplayName = $KnownDisplayName
                            }
                            else {
                                $info.DisplayName = $ObjectId
                            }
                            $info.IsOrphaned = $false
                        }
                    }
                }
                'Group' {
                    # Try Graph REST API first if we have a token
                    if ($graphToken) {
                        try {
                            $headers = @{
                                'Authorization' = "Bearer $graphToken"
                                'Content-Type' = 'application/json'
                            }
                            $graphUri = "https://graph.microsoft.com/v1.0/groups/$ObjectId"
                            $groupResponse = Invoke-RestMethod -Method GET -Uri $graphUri -Headers $headers -ErrorAction Stop
                            if ($groupResponse) {
                                $info.DisplayName = $groupResponse.displayName
                            }
                        }
                        catch {
                            Write-Verbose "Graph API call failed for group $ObjectId : $_"
                            # Fall through to try Get-AzADGroup
                        }
                    }
                    
                    # Fallback to Get-AzADGroup if Graph API didn't work or no token
                    if (-not $info.DisplayName -or $info.DisplayName -eq $ObjectId) {
                        $group = Get-AzADGroup -ObjectId $ObjectId -ErrorAction SilentlyContinue
                        if ($group) {
                            $info.DisplayName = $group.DisplayName
                        }
                        else {
                            if ($KnownDisplayName) {
                                $info.DisplayName = $KnownDisplayName
                            }
                            else {
                                $info.DisplayName = $ObjectId
                            }
                            $info.IsOrphaned = $false
                        }
                    }
                }
                'ServicePrincipal' {
                    # Try Graph REST API first if we have a token
                    if ($graphToken) {
                        try {
                            $headers = @{
                                'Authorization' = "Bearer $graphToken"
                                'Content-Type' = 'application/json'
                            }
                            $graphUri = "https://graph.microsoft.com/v1.0/servicePrincipals/$ObjectId"
                            $spResponse = Invoke-RestMethod -Method GET -Uri $graphUri -Headers $headers -ErrorAction Stop
                            if ($spResponse) {
                                $info.DisplayName = $spResponse.displayName
                                $info.AppId = $spResponse.appId
                                # Check if it's a managed identity
                                if ($spResponse.servicePrincipalType -eq 'ManagedIdentity') {
                                    $info.ObjectType = 'ManagedIdentity'
                                } else {
                                    $info.ObjectType = 'ServicePrincipal'
                                }
                            }
                        }
                        catch {
                            Write-Verbose "Graph API call failed for service principal $ObjectId : $_"
                            # Fall through to try Get-AzADServicePrincipal
                        }
                    }
                    
                    # Fallback to Get-AzADServicePrincipal if Graph API didn't work or no token
                    if (-not $info.DisplayName -or $info.DisplayName -eq $ObjectId) {
                        $sp = Get-AzADServicePrincipal -ObjectId $ObjectId -ErrorAction SilentlyContinue
                        if ($sp) {
                            $info.DisplayName = $sp.DisplayName
                            $info.AppId = $sp.AppId
                            $info.ObjectType = if ($sp.ServicePrincipalType -eq 'ManagedIdentity') { 'ManagedIdentity' } else { 'ServicePrincipal' }
                        }
                        else {
                            if ($KnownDisplayName) {
                                $info.DisplayName = $KnownDisplayName
                            }
                            else {
                                $info.DisplayName = $ObjectId
                            }
                            $info.IsOrphaned = $false
                        }
                    }
                }
                default {
                    # Unknown type - try to resolve as ServicePrincipal first, then User
                    # Try Graph REST API first if we have a token
                    if ($graphToken) {
                        try {
                            $headers = @{
                                'Authorization' = "Bearer $graphToken"
                                'Content-Type' = 'application/json'
                            }
                            # Try as ServicePrincipal first
                            $graphUri = "https://graph.microsoft.com/v1.0/servicePrincipals/$ObjectId"
                            $spResponse = Invoke-RestMethod -Method GET -Uri $graphUri -Headers $headers -ErrorAction SilentlyContinue
                            if ($spResponse) {
                                $info.DisplayName = $spResponse.displayName
                                $info.AppId = $spResponse.appId
                                $info.ObjectType = if ($spResponse.servicePrincipalType -eq 'ManagedIdentity') { 'ManagedIdentity' } else { 'ServicePrincipal' }
                            }
                            else {
                                # Try as User
                                $graphUri = "https://graph.microsoft.com/v1.0/users/$ObjectId"
                                $userResponse = Invoke-RestMethod -Method GET -Uri $graphUri -Headers $headers -ErrorAction SilentlyContinue
                                if ($userResponse) {
                                    $info.DisplayName = $userResponse.displayName
                                    $info.UserPrincipalName = $userResponse.userPrincipalName
                                    $info.ObjectType = 'User'
                                }
                            }
                        }
                        catch {
                            Write-Verbose "Graph API call failed for unknown type $ObjectId : $_"
                        }
                    }
                    
                    # Fallback to Get-AzAD cmdlets if Graph API didn't work or no token
                    if (-not $info.DisplayName -or $info.DisplayName -eq $ObjectId) {
                        $sp = Get-AzADServicePrincipal -ObjectId $ObjectId -ErrorAction SilentlyContinue
                        if ($sp) {
                            $info.DisplayName = $sp.DisplayName
                            $info.AppId = $sp.AppId
                            $info.ObjectType = if ($sp.ServicePrincipalType -eq 'ManagedIdentity') { 'ManagedIdentity' } else { 'ServicePrincipal' }
                        }
                        else {
                            $user = Get-AzADUser -ObjectId $ObjectId -ErrorAction SilentlyContinue
                            if ($user) {
                                $info.DisplayName = $user.DisplayName
                                $info.UserPrincipalName = $user.UserPrincipalName
                                $info.ObjectType = 'User'
                            }
                            else {
                                if ($KnownDisplayName) {
                                    $info.DisplayName = $KnownDisplayName
                                }
                                else {
                                    $info.DisplayName = $ObjectId
                                }
                                $info.IsOrphaned = $false
                            }
                        }
                    }
                }
            }
        }
        catch {
            Write-Verbose "Unexpected error resolving principal $ObjectId : $_"
            if ($KnownDisplayName) {
                $info.DisplayName = $KnownDisplayName
            }
            else {
                $info.DisplayName = $ObjectId
            }
            $info.IsOrphaned = $false
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
            Classifies Azure roles using Microsoft's official privileged role classification.
        .DESCRIPTION
            - Privileged: Microsoft's official privileged administrator roles (Owner, Contributor, User Access Administrator, Role Based Access Control Administrator, Access Review Operator Service Role)
            - Write: Roles that can modify resources  
            - Read: View-only roles
        #>
        param([string]$RoleName)
        
        # Microsoft's official Privileged Administrator Roles
        # https://learn.microsoft.com/en-us/azure/role-based-access-control/rbac-and-directory-admin-roles
        $privilegedRoles = @(
            'Owner',
            'Contributor', 
            'User Access Administrator',
            'Role Based Access Control Administrator',
            'Access Review Operator Service Role'
        )
        
        # Explicit read-only patterns
        $readOnlyPatterns = @(
            'Reader$',
            'Viewer$',
            '^Billing Reader$',
            '^Cost Management Reader$',
            '^Security Reader$',
            '^Log Analytics Reader$',
            '^Monitoring Reader$',
            '^Workbook Reader$',
            '^Blueprint Operator$'
        )
        
        # Check privileged first (exact match)
        if ($privilegedRoles -contains $RoleName) {
            return @{ 
                Tier = 'Privileged'
                Display = 'Privileged'
                Order = 0
                Color = 'red'
            }
        }
        
        # Check read-only patterns
        foreach ($pattern in $readOnlyPatterns) {
            if ($RoleName -match $pattern) {
                return @{
                    Tier = 'Read'
                    Display = 'Read'
                    Order = 2
                    Color = 'green'
                }
            }
        }
        
        # Everything else is Write (can modify something)
        return @{
            Tier = 'Write'
            Display = 'Write'
            Order = 1
            Color = 'yellow'
        }
    }

    function Get-RolePrivilegeLevel {
        <#
        .SYNOPSIS
            Returns privilege level for redundancy detection only.
            Lower number = higher privilege.
            Used to determine if one role assignment makes another redundant.
        #>
        param([string]$RoleName)
        
        # Owner trumps everything
        if ($RoleName -eq 'Owner') { return 0 }
        
        # Contributor and UAA are high privilege
        if ($RoleName -in @('Contributor', 'User Access Administrator', 'Role Based Access Control Administrator', 'Access Review Operator Service Role')) { 
            return 1 
        }
        
        # Reader is lowest useful privilege
        if ($RoleName -match 'Reader$' -or $RoleName -match 'Viewer$') { return 3 }
        
        # Everything else (write roles) in the middle
        return 2
    }

    function Get-ManagementGroupHierarchy {
        <#
        .SYNOPSIS
            Fetches the complete Management Group hierarchy and builds ancestry maps.
        .DESCRIPTION
            Returns hashtables mapping:
            - Subscriptions to their MG ancestors
            - MGs to their MG ancestors
            - All scopes to their parent chain
            
            Uses Azure Resource Graph to query subscriptions (which include their MG ancestor chain).
            This approach only requires subscription read access, not MG-level Resource Graph access.
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$TenantId
        )
        
        
        # Initialize result
        $result = @{
            SubscriptionToAncestors = @{}  # SubId → @(MG1, MG2, ..., TenantRoot)
            MgToAncestors = @{}            # MGName → @(ParentMG, ..., TenantRoot)
            MgToChildren = @{}             # MGName → @(ChildMG1, ChildMG2, ...)
            MgToSubscriptions = @{}        # MGName → @(SubId1, SubId2, ...)
            SubscriptionToDirectMg = @{}   # SubId → DirectParentMg
            Success = $false
            Error = $null
        }
        
        # Check for Az.ResourceGraph module
        if (-not (Get-Module -ListAvailable -Name Az.ResourceGraph)) {
            $result.Error = "Az.ResourceGraph module is not available"
            Write-Warning "Az.ResourceGraph module is not available. Management Group hierarchy cannot be fetched."
            Write-Warning "Redundancy detection will be limited to Subscription/RG/Resource scope relationships."
            return $result
        }
        
        Import-Module Az.ResourceGraph -ErrorAction SilentlyContinue | Out-Null
        
        try {
            # Query subscriptions - they include their MG ancestor chain
            # This works with just subscription read access!
            $subQuery = @"
resourcecontainers
| where type == 'microsoft.resources/subscriptions'
| project subscriptionId, name, mgChain = properties.managementGroupAncestorsChain
"@
            
            # Query without -ManagementGroup flag - uses subscription scope
            Write-Verbose "Querying subscriptions from Resource Graph..."
            $subs = Search-AzGraph -Query $subQuery -First 1000 -ErrorAction Stop
            
            if (-not $subs -or $subs.Count -eq 0) {
                throw "No subscriptions found in Resource Graph"
            }
            
            # Build maps from subscription data
            $allMgs = @{}  # mgName → @(ancestor1, ancestor2, ...)
            
            foreach ($sub in $subs) {
                $subId = $sub.subscriptionId
                
                if ($sub.mgChain -and $sub.mgChain.Count -gt 0) {
                    # mgChain is array: [{name: "direct-parent-mg"}, {name: "grandparent-mg"}, ..., {name: "tenant-root-group"}]
                    # First element is direct parent, last is root MG
                    $mgNames = @($sub.mgChain | ForEach-Object { 
                        if ($_.PSObject.Properties['name']) {
                            $_.name
                        }
                        elseif ($_.PSObject.Properties['Name']) {
                            $_.Name
                        }
                        else {
                            # Try to extract from id or full object
                            $mgId = if ($_.id) { 
                                $idStr = $_.id.ToString()
                                if ($idStr -match '/managementGroups/([^/]+)') { $Matches[1] } else { $idStr }
                            } elseif ($_.PSObject.Properties['id']) {
                                $idStr = $_.id.ToString()
                                if ($idStr -match '/managementGroups/([^/]+)') { $Matches[1] } else { $idStr }
                            } else {
                                $_.ToString()
                            }
                            $mgId
                        }
                    })
                    
                    # Filter out null/empty values
                    $mgNames = @($mgNames | Where-Object { $_ -and $_.ToString().Trim() -ne '' })
                    
                    if ($mgNames.Count -gt 0) {
                        # Subscription's ancestors (all MGs above it)
                        $result.SubscriptionToAncestors[$subId] = $mgNames
                        
                        # Direct parent (first in chain)
                        $result.SubscriptionToDirectMg[$subId] = $mgNames[0]
                        
                        # Add to parent's subscription list
                        $directParent = $mgNames[0]
                        if (-not $result.MgToSubscriptions.ContainsKey($directParent)) {
                            $result.MgToSubscriptions[$directParent] = @()
                        }
                        if ($result.MgToSubscriptions[$directParent] -notcontains $subId) {
                            $result.MgToSubscriptions[$directParent] += $subId
                        }
                        
                        # Build MG ancestor chains from this subscription's chain
                        for ($i = 0; $i -lt $mgNames.Count; $i++) {
                            $mgName = $mgNames[$i]
                            
                            # Ancestors of this MG = all MGs after it in the chain
                            $ancestors = @()
                            if ($i + 1 -lt $mgNames.Count) {
                                $ancestors = @($mgNames[($i + 1)..($mgNames.Count - 1)])
                            }
                            
                            # Only set if not already set or if this chain is longer (more complete)
                            if (-not $allMgs.ContainsKey($mgName) -or $allMgs[$mgName].Count -lt $ancestors.Count) {
                                $allMgs[$mgName] = $ancestors
                            }
                            
                            # Build parent-child relationships
                            if ($i + 1 -lt $mgNames.Count) {
                                $parentMg = $mgNames[$i + 1]
                                if (-not $result.MgToChildren.ContainsKey($parentMg)) {
                                    $result.MgToChildren[$parentMg] = @()
                                }
                                if ($result.MgToChildren[$parentMg] -notcontains $mgName) {
                                    $result.MgToChildren[$parentMg] += $mgName
                                }
                            }
                        }
                    }
                }
            }
            
            $result.MgToAncestors = $allMgs
            $result.Success = $true
            
            $mgCount = $allMgs.Count
            $subCount = $result.SubscriptionToAncestors.Count
        }
        catch {
            $result.Error = $_.Exception.Message
            Write-Warning "Failed to fetch Management Group hierarchy: $($result.Error)"
            Write-Warning "Redundancy detection will be limited to Subscription/RG/Resource scope relationships."
        }
        
        return $result
    }

    function Test-IsAncestorScope {
        <#
        .SYNOPSIS
            Determines if PotentialAncestor scope is an ancestor of Descendant scope.
        .DESCRIPTION
            Uses the MG hierarchy map for accurate MG/Subscription relationships.
            Falls back to scope string parsing for RG/Resource relationships.
        #>
        param(
            [Parameter(Mandatory)]
            [string]$AncestorScope,
            
            [Parameter(Mandatory)]
            [string]$DescendantScope,
            
            [Parameter(Mandatory)]
            [hashtable]$HierarchyMap
        )
        
        # Same scope - considered ancestor of itself (for role comparison at same scope)
        if ($AncestorScope -eq $DescendantScope) {
            return $true
        }
        
        # Tenant Root (/) is ancestor of everything
        if ($AncestorScope -eq '/') {
            return $true
        }
        
        # Parse both scopes
        $ancestorInfo = Get-ScopeInfo -Scope $AncestorScope
        $descendantInfo = Get-ScopeInfo -Scope $DescendantScope
        
        # Root ancestors everything (already handled above)
        if ($ancestorInfo.Type -eq 'Root') {
            return $true
        }
        
        # Descendant is Root - nothing can be its ancestor except itself
        if ($descendantInfo.Type -eq 'Root') {
            return $false
        }
        
        # === MG as potential ancestor ===
        if ($ancestorInfo.Type -eq 'ManagementGroup') {
            $ancestorMg = $ancestorInfo.ManagementGroup
            
            # Descendant is MG - check MG hierarchy
            if ($descendantInfo.Type -eq 'ManagementGroup') {
                $descendantMg = $descendantInfo.ManagementGroup
                if ($HierarchyMap.MgToAncestors.ContainsKey($descendantMg)) {
                    return $HierarchyMap.MgToAncestors[$descendantMg] -contains $ancestorMg
                }
                return $false
            }
            
            # Descendant is Subscription - check if sub is under this MG
            if ($descendantInfo.Type -eq 'Subscription') {
                $subId = $descendantInfo.SubscriptionId
                if ($HierarchyMap.SubscriptionToAncestors.ContainsKey($subId)) {
                    return $HierarchyMap.SubscriptionToAncestors[$subId] -contains $ancestorMg
                }
                return $false
            }
            
            # Descendant is RG or Resource - check if its subscription is under this MG
            if ($descendantInfo.Type -in @('ResourceGroup', 'Resource')) {
                $subId = $descendantInfo.SubscriptionId
                if ($HierarchyMap.SubscriptionToAncestors.ContainsKey($subId)) {
                    return $HierarchyMap.SubscriptionToAncestors[$subId] -contains $ancestorMg
                }
                return $false
            }
        }
        
        # === Subscription as potential ancestor ===
        if ($ancestorInfo.Type -eq 'Subscription') {
            $ancestorSubId = $ancestorInfo.SubscriptionId
            
            # Descendant must be RG or Resource in the SAME subscription
            if ($descendantInfo.Type -in @('ResourceGroup', 'Resource')) {
                return $descendantInfo.SubscriptionId -eq $ancestorSubId
            }
            
            # Subscription cannot be ancestor of another Subscription or MG
            return $false
        }
        
        # === ResourceGroup as potential ancestor ===
        if ($ancestorInfo.Type -eq 'ResourceGroup') {
            # Descendant must be Resource in the SAME subscription AND SAME RG
            if ($descendantInfo.Type -eq 'Resource') {
                return ($descendantInfo.SubscriptionId -eq $ancestorInfo.SubscriptionId) -and
                       ($descendantInfo.ResourceGroup -eq $ancestorInfo.ResourceGroup)
            }
            return $false
        }
        
        # === Resource cannot be ancestor of anything ===
        if ($ancestorInfo.Type -eq 'Resource') {
            return $false
        }
        
        # Unknown - assume not ancestor
        return $false
    }

    function Test-RoleIncludesRole {
        <#
        .SYNOPSIS
            Determines if RoleA's permissions are a superset of RoleB's permissions.
        .DESCRIPTION
            Only returns true for the well-known inclusion chain:
            Owner ⊃ (Contributor, Reader, User Access Administrator, Role Based Access Control Administrator)
            Contributor ⊃ Reader
            
            All other role pairs are considered incomparable (returns false).
        #>
        param(
            [Parameter(Mandatory)]
            [string]$RoleA,
            
            [Parameter(Mandatory)]
            [string]$RoleB
        )
        
        # Same role always includes itself
        if ($RoleA -eq $RoleB) {
            return $true
        }
        
        # Owner includes everything in the chain (Owner has * which includes Microsoft.Authorization/*)
        if ($RoleA -eq 'Owner') {
            return $RoleB -in @('Contributor', 'Reader', 'User Access Administrator', 'Role Based Access Control Administrator')
        }
        
        # Contributor includes Reader (but Contributor does NOT include UAA - it excludes authorization actions)
        if ($RoleA -eq 'Contributor') {
            return $RoleB -eq 'Reader'
        }
        
        # User Access Administrator - only includes itself (handled above)
        # It grants different permissions than Owner (can manage access but not resources)
        
        # All other role pairs are incomparable
        # Examples:
        # - VM Contributor does NOT include Network Contributor (different resources)
        # - Storage Blob Data Owner does NOT include Contributor (data plane vs control plane)
        # - Key Vault Administrator does NOT include Reader (different permission model)
        
        return $false
    }

    function Find-RedundantAssignments {
        <#
        .SYNOPSIS
            Identifies redundant role assignments for a principal.
        .DESCRIPTION
            An assignment X is redundant if there exists another assignment Y where:
            - Y.Scope is an ancestor of X.Scope (or same scope)
            - Y.Role includes X.Role's permissions
            
            Returns the assignments array with IsRedundant and RedundantReason populated.
        #>
        param(
            [Parameter(Mandatory)]
            [array]$Assignments,
            
            [Parameter(Mandatory)]
            [hashtable]$HierarchyMap
        )
        
        foreach ($assignment in $Assignments) {
            $assignment.IsRedundant = $false
            $assignment.RedundantReason = $null
            
            foreach ($other in $Assignments) {
                # Don't compare to self
                if ($other.ScopeRaw -eq $assignment.ScopeRaw -and $other.Role -eq $assignment.Role) {
                    continue
                }
                
                # Check if other's scope is ancestor of (or same as) this assignment's scope
                $isAncestorScope = Test-IsAncestorScope `
                    -AncestorScope $other.ScopeRaw `
                    -DescendantScope $assignment.ScopeRaw `
                    -HierarchyMap $HierarchyMap
                
                if (-not $isAncestorScope) {
                    continue
                }
                
                # Check if other's role includes this assignment's role
                $roleIncludes = Test-RoleIncludesRole -RoleA $other.Role -RoleB $assignment.Role
                
                if (-not $roleIncludes) {
                    continue
                }
                
                # This assignment is redundant!
                $assignment.IsRedundant = $true
                
                # Build explanation
                if ($other.ScopeRaw -eq $assignment.ScopeRaw) {
                    # Same scope, higher privilege role
                    $assignment.RedundantReason = "Covered by $($other.Role) at same scope"
                }
                else {
                    # Ancestor scope
                    $otherScopeName = Get-FriendlyScopeName -Scope $other.ScopeRaw -SubscriptionNameMap $script:subscriptionNameMap -ManagementGroupNameMap $script:managementGroupNameMap
                    if ($other.Role -eq $assignment.Role) {
                        $assignment.RedundantReason = "Same role at $otherScopeName"
                    }
                    else {
                        $assignment.RedundantReason = "$($other.Role) at $otherScopeName"
                    }
                }
                
                # Found one dominating assignment, no need to check more
                break
            }
        }
        
        return $Assignments
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
            'Access Review Operator Service Role',
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

    $startTime = Get-Date

    # Get current context
    $context = Get-AzContext
    if (-not $context) {
        throw "Not connected to Azure. Please run Connect-AzAccount first."
    }

    $currentTenantId = if ($TenantId) { $TenantId } else { $context.Tenant.Id }
    
    # Initialize Graph token (will be set below)
    $script:graphToken = $null
    $script:graphTokenAvailable = $false

    # Get subscriptions
    $subscriptions = if ($SubscriptionIds) {
        $SubscriptionIds | ForEach-Object { Get-AzSubscription -SubscriptionId $_ -TenantId $currentTenantId }
    } else {
        Get-AzSubscription -TenantId $currentTenantId | Where-Object { $_.State -eq 'Enabled' }
    }

    # Build subscription name map for friendly scope names
    $subscriptionNameMap = @{}
    foreach ($sub in $subscriptions) {
        $subscriptionNameMap[$sub.Id] = $sub.Name
    }
    
    # Store at script scope for use in redundancy detection
    $script:subscriptionNameMap = $subscriptionNameMap

    # Fetch Management Group hierarchy for accurate redundancy detection
    $hierarchyMap = Get-ManagementGroupHierarchy -TenantId $currentTenantId
    
    # Handle failure case - create empty hierarchy map structure
    if (-not $hierarchyMap.Success) {
        Write-Warning "Management Group hierarchy not available. Redundancy detection limited to Subscription/RG/Resource relationships."
        Write-Warning "To enable full redundancy detection, ensure you have 'Management Group Reader' permission at tenant root."
        
        # Create empty hierarchy map - Test-IsAncestorScope will still work for Sub/RG/Resource
        if (-not $hierarchyMap.SubscriptionToAncestors) { $hierarchyMap.SubscriptionToAncestors = @{} }
        if (-not $hierarchyMap.MgToAncestors) { $hierarchyMap.MgToAncestors = @{} }
    }
    
    # Store management group name map at script scope for use in redundancy reasons
    # (Will be set below, but initialize here)
    $script:managementGroupNameMap = @{}

    # Build Management Group name map for friendly scope names
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
        
    }
    catch {
        Write-Verbose "Could not retrieve Management Groups: $_"
        # Even if we fail, add default Tenant Root Group entry
        if (-not $managementGroupNameMap.ContainsKey($currentTenantId)) {
            $managementGroupNameMap[$currentTenantId] = "Tenant Root Group"
        }
    }
    
    # Store at script scope for use in redundancy detection
    $script:managementGroupNameMap = $managementGroupNameMap

    # Initialize collections
    $allAssignments = [System.Collections.Generic.List[object]]::new()
    $allCustomRoles = [System.Collections.Generic.List[object]]::new()
    $principalCache = @{}
    
    # Try to get Microsoft Graph access token once for all principal resolutions
    # This avoids getting a new token for each principal lookup
    # Note: We don't test the token here - individual lookups will try it and fall back gracefully if it fails
    try {
        $tokenResult = Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com" -ErrorAction Stop
        if ($tokenResult -and $tokenResult.Token) {
            $script:graphToken = $tokenResult.Token
            $script:graphTokenAvailable = $true
            Write-Verbose "Graph API token obtained - will attempt principal name resolution"
        }
        else {
            Write-Verbose "Could not obtain Graph API token - will use fallback methods"
            $script:graphTokenAvailable = $false
        }
    }
    catch {
        # Token not available - principal lookups will use Get-AzAD* cmdlets as fallback
        Write-Verbose "Graph API token not available - will use fallback methods for principal names"
        $script:graphToken = $null
        $script:graphTokenAvailable = $false
    }

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
        
        try {
            Set-AzContext -SubscriptionId $sub.Id -TenantId $currentTenantId -ErrorAction Stop | Out-Null
            
            # Get role assignments
            # Note: Get-AzRoleAssignment tries to resolve principal names via Microsoft Graph API,
            # which requires -AuthScope MicrosoftGraphEndpointResourceId when connecting.
            # To avoid this requirement, we'll use REST API directly to get raw role assignments,
            # then resolve principals separately (which we already do with Get-PrincipalDisplayInfo).
            $assignments = @()
            $subScope = "/subscriptions/$($sub.Id)"
            
            # Method 1: Try using REST API to avoid Graph API dependency
            # This method doesn't require Microsoft Graph API access
            try {
                # Use REST API to get role assignments - this returns all assignments at subscription scope and below
                # The $filter=atScope() parameter returns assignments at the specified scope and all descendant scopes
                # Note: $filter uses OData syntax, and we need to URL-encode it properly
                $filterValue = "atScope()"
                $encodedFilter = [System.Uri]::EscapeDataString($filterValue)
                $uri = "https://management.azure.com$subScope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=$encodedFilter"
                $response = Invoke-AzRestMethod -Method GET -Uri $uri -ErrorAction Stop
                
                if ($response.StatusCode -eq 200 -and $response.Content) {
                    $roleAssignmentsData = $response.Content | ConvertFrom-Json
                    
                    if ($roleAssignmentsData.value) {
                        # Convert REST API response to objects similar to Get-AzRoleAssignment output
                        foreach ($ra in $roleAssignmentsData.value) {
                            # Get role definition details
                            $roleDefId = $ra.properties.roleDefinitionId -replace '.*/', ''
                            $roleDefScope = $ra.properties.scope
                            
                            try {
                                $roleDef = Get-AzRoleDefinition -Id $roleDefId -Scope $roleDefScope -ErrorAction SilentlyContinue
                                if (-not $roleDef) {
                                    # Fallback: try without scope
                                    $roleDef = Get-AzRoleDefinition -Id $roleDefId -ErrorAction SilentlyContinue
                                }
                            }
                            catch {
                                Write-Verbose "  Could not get role definition for $roleDefId : $_"
                            }
                            
                            # Create assignment object similar to Get-AzRoleAssignment output
                            $assignmentObj = [PSCustomObject]@{
                                RoleAssignmentId = $ra.id
                                RoleDefinitionId = $ra.properties.roleDefinitionId
                                RoleDefinitionName = if ($roleDef) { $roleDef.Name } else { "Unknown" }
                                Scope = $ra.properties.scope
                                ObjectId = $ra.properties.principalId
                                ObjectType = $ra.properties.principalType
                                DisplayName = $null  # Will be resolved later
                                SignInName = $null   # Will be resolved later
                                CanDelegate = $ra.properties.canDelegate
                                Description = $ra.properties.description
                                Condition = $ra.properties.condition
                                ConditionVersion = $ra.properties.conditionVersion
                                CreatedOn = if ($ra.properties.createdOn) { [DateTime]::Parse($ra.properties.createdOn) } else { $null }
                                UpdatedOn = if ($ra.properties.updatedOn) { [DateTime]::Parse($ra.properties.updatedOn) } else { $null }
                            }
                            
                            $assignments += $assignmentObj
                        }
                        
                        # Handle pagination if needed
                        $nextLink = $roleAssignmentsData.nextLink
                        while ($nextLink) {
                            try {
                                $nextResponse = Invoke-AzRestMethod -Method GET -Uri $nextLink -ErrorAction Stop
                                if ($nextResponse.StatusCode -eq 200 -and $nextResponse.Content) {
                                    $nextData = $nextResponse.Content | ConvertFrom-Json
                                    if ($nextData.value) {
                                        foreach ($ra in $nextData.value) {
                                            $roleDefId = $ra.properties.roleDefinitionId -replace '.*/', ''
                                            $roleDefScope = $ra.properties.scope
                                            $roleDef = Get-AzRoleDefinition -Id $roleDefId -Scope $roleDefScope -ErrorAction SilentlyContinue
                                            if (-not $roleDef) {
                                                $roleDef = Get-AzRoleDefinition -Id $roleDefId -ErrorAction SilentlyContinue
                                            }
                                            
                                            $assignmentObj = [PSCustomObject]@{
                                                RoleAssignmentId = $ra.id
                                                RoleDefinitionId = $ra.properties.roleDefinitionId
                                                RoleDefinitionName = if ($roleDef) { $roleDef.Name } else { "Unknown" }
                                                Scope = $ra.properties.scope
                                                ObjectId = $ra.properties.principalId
                                                ObjectType = $ra.properties.principalType
                                                DisplayName = $null
                                                SignInName = $null
                                                CanDelegate = $ra.properties.canDelegate
                                                Description = $ra.properties.description
                                                Condition = $ra.properties.condition
                                                ConditionVersion = $ra.properties.conditionVersion
                                                CreatedOn = if ($ra.properties.createdOn) { [DateTime]::Parse($ra.properties.createdOn) } else { $null }
                                                UpdatedOn = if ($ra.properties.updatedOn) { [DateTime]::Parse($ra.properties.updatedOn) } else { $null }
                                            }
                                            $assignments += $assignmentObj
                                        }
                                    }
                                    $nextLink = $nextData.nextLink
                                } else {
                                    $nextLink = $null
                                }
                            }
                            catch {
                                Write-Verbose "  Error fetching next page: $_"
                                $nextLink = $null
                            }
                        }
                        
                        Write-Verbose "Found $($assignments.Count) role assignments (via REST API)"
                    }
                }
            }
            catch {
                Write-Verbose "  REST API method failed, trying Get-AzRoleAssignment: $_"
                
                # Method 2: Fallback to Get-AzRoleAssignment (requires Graph API scope)
                try {
                    $assignments = Get-AzRoleAssignment -Scope $subScope -ErrorAction Stop
                    if ($null -eq $assignments) {
                        $assignments = @()
                    }
                    Write-Verbose "Found $($assignments.Count) role assignments (via Get-AzRoleAssignment)"
                }
                catch {
                    $errorMsg = $_.Exception.Message
                    Write-Warning "  Failed to get role assignments: $errorMsg"
                    
                    # Check for Graph API authentication error
                    if ($errorMsg -match "MicrosoftGraphEndpointResourceId|Authentication failed against resource") {
                        Write-Warning "  Graph API authentication required. To fix this, reconnect with:"
                        Write-Warning "    Connect-AzAccount -AuthScope MicrosoftGraphEndpointResourceId"
                        Write-Warning "  Or use REST API method (which doesn't require Graph API)."
                    }
                    # Check if it's a permission error
                    elseif ($errorMsg -match "Authorization|Permission|Access|Forbidden|Unauthorized|does not have authorization") {
                        Write-Warning "  Permission issue detected. Current user may lack 'Reader' or 'User Access Administrator' role."
                        Write-Warning "  Required permissions: Microsoft.Authorization/roleAssignments/read"
                    }
                    
                    $assignments = @()
                }
            }
            
            foreach ($assignment in $assignments) {
                # Resolve principal
                $principalInfo = Get-PrincipalDisplayInfo -ObjectId $assignment.ObjectId `
                    -ObjectType $assignment.ObjectType `
                    -Cache $principalCache `
                    -KnownDisplayName $assignment.DisplayName `
                    -KnownUPN $assignment.SignInName
                
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

    # Build assignment rows for flat table display

    $assignmentRows = $uniqueAssignments | ForEach-Object {
        $tierInfo = Get-AccessTier -RoleName $_.RoleDefinitionName
        $scopeInfo = Get-ScopeInfo -Scope $_.Scope
        
        # Determine scope type display name
        $scopeTypeDisplay = switch ($scopeInfo.Type) {
            'Root' { 'Tenant Root' }
            'ManagementGroup' { 'Management Group' }
            'Subscription' { 'Subscription' }
            'ResourceGroup' { 'Resource Group' }
            'Resource' { 'Resource' }
            default { $scopeInfo.Type }
        }
        
        # Get friendly scope name
        $scopeFriendlyName = Get-FriendlyScopeName -Scope $_.Scope -SubscriptionNameMap $subscriptionNameMap -ManagementGroupNameMap $managementGroupNameMap
        # Remove prefix since we have ScopeType column
        $scopeName = $scopeFriendlyName -replace '^(MG|Sub|RG|Resource): ', ''
        
        # Build affected subscriptions list
        $affectedSubs = @()
        if ($_.InheritedBySubscriptions -and $_.InheritedBySubscriptions.Count -gt 0) {
            if ($scopeInfo.Type -eq 'Root') {
                # Root scope affects ALL subscriptions in the tenant
                $affectedSubs = @("All $($_.InheritedBySubscriptions.Count) subscriptions")
            } else {
                # Management Groups and other scopes show the actual subscription names
                $affectedSubs = $_.InheritedBySubscriptions
            }
        } elseif ($scopeInfo.Type -eq 'Subscription' -and $_.SubscriptionName) {
            $affectedSubs = @($_.SubscriptionName)
        } elseif ($scopeInfo.Type -in @('ResourceGroup', 'Resource') -and $_.SubscriptionName) {
            $affectedSubs = @($_.SubscriptionName)
        }
        
        [PSCustomObject]@{
            # Principal
            PrincipalId = $_.PrincipalId
            PrincipalDisplayName = $_.PrincipalDisplayName
            PrincipalType = $_.PrincipalType
            PrincipalUPN = $_.PrincipalUPN
            AppId = $_.AppId
            IsOrphaned = $_.IsOrphaned
            IsExternal = $_.IsExternal
            
            # Role
            Role = if ($_.RoleDefinitionName) { $_.RoleDefinitionName } else { "[Unknown Role]" }
            RiskTier = $tierInfo.Tier
            RiskOrder = $tierInfo.Order
            RiskColor = $tierInfo.Color
            
            # Scope
            ScopeType = $scopeTypeDisplay
            ScopeLevel = $scopeInfo.Level
            ScopeName = $scopeName
            ScopeRaw = $_.Scope
            
            # Subscription context
            SubscriptionName = $_.SubscriptionName
            AffectedSubscriptions = $affectedSubs
            AffectedCount = $affectedSubs.Count
            
            # Flags
            IsRedundant = $false  # Will be calculated below
            RedundantReason = $null  # Will be populated by Find-RedundantAssignments
            IsPrivileged = ($tierInfo.Tier -eq 'Privileged')  # Mark if role is privileged
            AssignmentId = $_.RoleAssignmentId
        }
    } | Sort-Object PrincipalDisplayName, RiskOrder, ScopeLevel

    # Combine duplicate inherited assignments (Tenant Root and Management Groups)
    # This handles cases where multiple assignments exist at the same scope but should be shown as one row
    $assignmentRowsList = [System.Collections.Generic.List[object]]::new()
    
    # Separate inherited scopes (Root and Management Groups) from direct assignments
    $inheritedRows = $assignmentRows | Where-Object { 
        ($_.ScopeType -eq 'Tenant Root' -and $_.ScopeRaw -eq '/') -or 
        $_.ScopeType -eq 'Management Group'
    }
    $otherRows = $assignmentRows | Where-Object { 
        -not (($_.ScopeType -eq 'Tenant Root' -and $_.ScopeRaw -eq '/') -or $_.ScopeType -eq 'Management Group')
    }
    
    # Group inherited rows by PrincipalId + Role + ScopeRaw (to identify same scope)
    $inheritedGroups = $inheritedRows | Group-Object -Property @{Expression={"{0}|{1}|{2}" -f $_.PrincipalId, $_.Role, $_.ScopeRaw}}
    
    foreach ($group in $inheritedGroups) {
        $first = $group.Group[0]
        
        if ($group.Count -gt 1) {
            # Multiple assignments at same inherited scope with same principal+role - combine them
            
            # Collect all unique subscription names from all rows in the group
            $allSubscriptions = @()
            foreach ($row in $group.Group) {
                if ($row.AffectedSubscriptions) {
                    # Extract subscription names, handling both "All X subscriptions" format and actual names
                    foreach ($sub in $row.AffectedSubscriptions) {
                        if ($sub -notmatch '^All \d+ subscriptions$') {
                            $allSubscriptions += $sub
                        }
                    }
                }
            }
            
            # Get unique subscription names and sort
            $uniqueSubs = $allSubscriptions | Select-Object -Unique | Sort-Object
            
            # Determine how to display subscriptions
            if ($first.ScopeType -eq 'Tenant Root') {
                # For Tenant Root, always show "All X subscriptions"
                $totalSubCount = $subscriptions.Count
                $affectedSubs = @("All $totalSubCount subscriptions")
                $affectedCount = $totalSubCount
            }
            else {
                # For Management Groups, show all unique subscription names or "All X" if it matches total
                if ($uniqueSubs.Count -eq $subscriptions.Count) {
                    $affectedSubs = @("All $($uniqueSubs.Count) subscriptions")
                    $affectedCount = $uniqueSubs.Count
                }
                else {
                    $affectedSubs = $uniqueSubs
                    $affectedCount = $uniqueSubs.Count
                }
            }
            
            # Create combined row
            $combinedRow = [PSCustomObject]@{
                # Principal (same for all)
                PrincipalId = $first.PrincipalId
                PrincipalDisplayName = $first.PrincipalDisplayName
                PrincipalType = $first.PrincipalType
                PrincipalUPN = $first.PrincipalUPN
                AppId = $first.AppId
                IsOrphaned = $first.IsOrphaned
                IsExternal = $first.IsExternal
                
                # Role (same for all)
                Role = $first.Role
                RiskTier = $first.RiskTier
                RiskOrder = $first.RiskOrder
                RiskColor = $first.RiskColor
                
                # Scope (same for all)
                ScopeType = $first.ScopeType
                ScopeLevel = $first.ScopeLevel
                ScopeName = $first.ScopeName
                ScopeRaw = $first.ScopeRaw
                
                # Subscription context - combined
                SubscriptionName = $null
                AffectedSubscriptions = $affectedSubs
                AffectedCount = $affectedCount
                
                # Flags - take from first (should be same for all)
                IsRedundant = $false  # Will be calculated below
                RedundantReason = $null
                IsPrivileged = $first.IsPrivileged
                AssignmentId = $first.AssignmentId  # Use first assignment ID
            }
            
            $assignmentRowsList.Add($combinedRow)
        }
        else {
            # Single assignment at inherited scope - keep as-is (already has correct subscription info)
            $assignmentRowsList.Add($first)
        }
    }
    
    # Add all non-inherited rows as-is
    foreach ($row in $otherRows) {
        $assignmentRowsList.Add($row)
    }
    
    $assignmentRows = $assignmentRowsList.ToArray()

    # Mark redundant assignments using hierarchy-based detection
    $principalGroups = $assignmentRows | Group-Object PrincipalId
    foreach ($group in $principalGroups) {
        $assignments = $group.Group
        # Use new hierarchy-based redundancy detection
        $assignments = Find-RedundantAssignments -Assignments $assignments -HierarchyMap $hierarchyMap
    }

    # Group assignments by principal for principal-centric view
    $principalGroups = $assignmentRows | Group-Object PrincipalId

    $principalsList = [System.Collections.Generic.List[object]]::new()
    foreach ($group in $principalGroups) {
        $assignments = $group.Group
        $firstAssignment = $assignments[0]
        
        # Get unique roles and subscriptions
        $uniqueRoles = $assignments | Select-Object -ExpandProperty Role -Unique | Sort-Object
        $allSubs = @()
        foreach ($assignment in $assignments) {
            if ($assignment.AffectedSubscriptions) {
                foreach ($sub in $assignment.AffectedSubscriptions) {
                    # Handle summary strings like "All X subscriptions" - add all actual subscription names
                    if ($sub -match '^All (\d+) subscriptions$') {
                        # "All X subscriptions" means all subscriptions in the tenant
                        $allSubs += $subscriptions | Select-Object -ExpandProperty Name
                    }
                    else {
                        # Actual subscription name
                        $allSubs += $sub
                    }
                }
            }
        }
        $uniqueSubs = $allSubs | Select-Object -Unique | Sort-Object
        
        # Check if principal has any privileged roles
        $hasPrivilegedRoles = ($assignments | Where-Object { $_.IsPrivileged }).Count -gt 0
        
        # Build assignments array for this principal
        $principalAssignments = foreach ($a in $assignments) {
            @{
                Role = $a.Role
                ScopeType = $a.ScopeType
                ScopeName = $a.ScopeName
                ScopeRaw = $a.ScopeRaw
                Subscriptions = $a.AffectedSubscriptions
                SubscriptionCount = $a.AffectedCount
                IsRedundant = $a.IsRedundant
                RedundantReason = $a.RedundantReason
                IsPrivileged = $a.IsPrivileged
            }
        }
        
        $principalObj = [PSCustomObject]@{
            PrincipalId = $firstAssignment.PrincipalId
            PrincipalDisplayName = $firstAssignment.PrincipalDisplayName
            PrincipalType = $firstAssignment.PrincipalType
            PrincipalUPN = $firstAssignment.PrincipalUPN
            AppId = $firstAssignment.AppId
            IsOrphaned = $firstAssignment.IsOrphaned
            IsExternal = $firstAssignment.IsExternal
            HasPrivilegedRoles = $hasPrivilegedRoles
            
            # Summary stats
            AssignmentCount = $assignments.Count
            RoleCount = $uniqueRoles.Count
            SubscriptionCount = $uniqueSubs.Count
            UniqueRoles = $uniqueRoles
            UniqueSubscriptions = $uniqueSubs
            
            # Assignments array
            Assignments = $principalAssignments
        }
        $principalsList.Add($principalObj)
    }
    $principals = $principalsList | Sort-Object PrincipalDisplayName

    # Enhance custom roles with usage tracking
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

    # Get orphaned assignments (from assignment rows)
    $orphanedAssignments = @($assignmentRows | Where-Object { $_.IsOrphaned })

    $endTime = Get-Date
    $duration = $endTime - $startTime

    # Build role-based access matrix (top roles by name)
    $roleCounts = $assignmentRows | Group-Object Role | 
        Sort-Object { $_.Count } -Descending | 
        Select-Object -First 10

    $accessMatrix = @{}
    $scopeTypes = @('Tenant Root', 'Management Group', 'Subscription', 'Resource Group', 'Resource')

    foreach ($roleGroup in $roleCounts) {
        $roleName = $roleGroup.Name
        $accessMatrix[$roleName] = @{}
        foreach ($scopeType in $scopeTypes) {
            $count = @($roleGroup.Group | Where-Object { $_.ScopeType -eq $scopeType }).Count
            $accessMatrix[$roleName][$scopeType] = $count
        }
        $accessMatrix[$roleName]['Total'] = $roleGroup.Count
        
        # Add privileged flag (check if any assignment for this role is privileged)
        $isPrivileged = ($roleGroup.Group | Where-Object { $_.IsPrivileged }).Count -gt 0
        $accessMatrix[$roleName]['IsPrivileged'] = $isPrivileged
        
        # Count unique principals for this role
        $uniquePrincipals = @($roleGroup.Group | Select-Object -Property PrincipalId -Unique)
        $accessMatrix[$roleName]['Unique'] = $uniquePrincipals.Count
    }
    
    # Calculate statistics
    $uniquePrincipals = $assignmentRows | Select-Object -Property PrincipalId -Unique
    $newStats = @{
        TotalAssignments = $assignmentRows.Count
        TotalPrincipals = $uniquePrincipals.Count
        ByRiskTier = @{
            Privileged = @($assignmentRows | Where-Object { $_.RiskTier -eq 'Privileged' }).Count
            Write = @($assignmentRows | Where-Object { $_.RiskTier -eq 'Write' }).Count
            Read = @($assignmentRows | Where-Object { $_.RiskTier -eq 'Read' }).Count
        }
        ByPrincipalType = @{
            User = @($uniquePrincipals | ForEach-Object { $principalId = $_.PrincipalId; $assignmentRows | Where-Object { $_.PrincipalId -eq $principalId } | Select-Object -First 1 } | Where-Object { $_.PrincipalType -eq 'User' }).Count
            Group = @($uniquePrincipals | ForEach-Object { $principalId = $_.PrincipalId; $assignmentRows | Where-Object { $_.PrincipalId -eq $principalId } | Select-Object -First 1 } | Where-Object { $_.PrincipalType -eq 'Group' }).Count
            ServicePrincipal = @($uniquePrincipals | ForEach-Object { $principalId = $_.PrincipalId; $assignmentRows | Where-Object { $_.PrincipalId -eq $principalId } | Select-Object -First 1 } | Where-Object { $_.PrincipalType -eq 'ServicePrincipal' }).Count
            ManagedIdentity = @($uniquePrincipals | ForEach-Object { $principalId = $_.PrincipalId; $assignmentRows | Where-Object { $_.PrincipalId -eq $principalId } | Select-Object -First 1 } | Where-Object { $_.PrincipalType -eq 'ManagedIdentity' }).Count
        }
        OrphanedCount = @($assignmentRows | Where-Object { $_.IsOrphaned } | Select-Object -Property PrincipalId -Unique).Count
        ExternalCount = @($assignmentRows | Where-Object { $_.IsExternal } | Select-Object -Property PrincipalId -Unique).Count
        RedundantCount = @($assignmentRows | Where-Object { $_.IsRedundant }).Count
        CustomRoleCount = $allCustomRoles.Count
    }

    Write-Host "    $($assignmentRows.Count) assignments | $($newStats.TotalPrincipals) principals" -ForegroundColor Green

    #endregion

    #region Output

    # Build subscription names array for metadata
    $subscriptionNames = @($subscriptions | Select-Object -ExpandProperty Name | Sort-Object)
    
    # Calculate resolution statistics
    $totalPrincipals = @($assignmentRows | Select-Object -Property PrincipalId -Unique).Count
    $unresolvedCount = @($assignmentRows | Where-Object { 
        $_.PrincipalDisplayName -eq $_.PrincipalId 
    } | Select-Object -Property PrincipalId -Unique).Count

    $resolvedPercentage = if ($totalPrincipals -gt 0) { 
        [math]::Round((($totalPrincipals - $unresolvedCount) / $totalPrincipals) * 100, 0) 
    } else { 
        100 
    }

    # Only flag as "lacking Entra ID access" if less than 50% resolved
    # Otherwise it's likely just B2B/foreign principals that can't be resolved
    $lacksEntraIdAccess = $resolvedPercentage -lt 50
    
    return [PSCustomObject]@{
        Metadata = @{
            TenantId = $currentTenantId
            CollectionTime = $startTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
            Duration = $duration.TotalSeconds
            SubscriptionsScanned = $subscriptions.Count
            SubscriptionNames = $subscriptionNames
            UnresolvedPrincipalCount = $unresolvedCount
            TotalPrincipalCount = $totalPrincipals
            ResolvedPercentage = $resolvedPercentage
            LacksEntraIdAccess = $lacksEntraIdAccess
        }
        Statistics = $newStats
        Principals = $principals              # NEW: Principal-grouped structure
        Assignments = $assignmentRows        # Keep for backward compatibility/statistics
        AccessMatrix = $accessMatrix
        CustomRoles = $allCustomRoles.ToArray()
        OrphanedAssignments = @($assignmentRows | Where-Object { $_.IsOrphaned })
    }

    #endregion
}

