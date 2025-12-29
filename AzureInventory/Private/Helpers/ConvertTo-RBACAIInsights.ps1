<#
.SYNOPSIS
    Converts RBAC inventory data into AI-ready JSON insights.

.DESCRIPTION
    Extracts and structures the most important RBAC governance insights
    for AI analysis, focusing on orphaned assignments, external users,
    over-privileged principals, and redundant assignments.

.PARAMETER RBACData
    RBAC inventory object from Get-AzureRBACInventory.

.PARAMETER TopN
    Number of top risks to include (default: 20).

.EXAMPLE
    $insights = ConvertTo-RBACAIInsights -RBACData $rbacInventory -TopN 25
#>
function ConvertTo-RBACAIInsights {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$RBACData,
        
        [Parameter(Mandatory = $false)]
        [int]$TopN = 20
    )
    
    Write-Verbose "Converting RBAC data to AI insights (TopN: $TopN)"
    
    # Handle empty/null data
    if (-not $RBACData -or -not $RBACData.Assignments) {
        Write-Verbose "No RBAC data found"
        return @{
            domain = "rbac_governance"
            generated_at = (Get-Date).ToString("o")
            summary = @{
                total_assignments = 0
                total_principals = 0
                orphaned_count = 0
                external_count = 0
                redundant_count = 0
                privileged_count = 0
                critical_risk_count = 0
                high_risk_count = 0
            }
            top_risks = @()
            by_principal_type = @()
            by_risk_level = @()
            compliance_gaps = @{
                orphaned_assignments = @()
                external_privileged_users = @()
                over_privileged_principals = @()
                excessive_scope_assignments = @()
            }
        }
    }
    
    $assignments = @($RBACData.Assignments)
    $principals = if ($RBACData.Principals) { @($RBACData.Principals) } else { @() }
    
    # Calculate summary statistics
    $totalAssignments = $assignments.Count
    $totalPrincipals = if ($principals.Count -gt 0) { $principals.Count } else { ($assignments | Select-Object -ExpandProperty PrincipalId -Unique).Count }
    $orphanedCount = @($assignments | Where-Object { $_.IsOrphaned }).Count
    $externalCount = @($assignments | Where-Object { $_.IsExternal }).Count
    $redundantCount = @($assignments | Where-Object { $_.IsRedundant }).Count
    
    # Risk level counts
    $criticalRisk = @($assignments | Where-Object { $_.RiskLevel -eq 'Critical' }).Count
    $highRisk = @($assignments | Where-Object { $_.RiskLevel -eq 'High' }).Count
    $mediumRisk = @($assignments | Where-Object { $_.RiskLevel -eq 'Medium' }).Count
    $lowRisk = @($assignments | Where-Object { $_.RiskLevel -eq 'Low' }).Count
    
    # Privileged assignments (Critical or High risk)
    $privilegedCount = $criticalRisk + $highRisk
    
    # Get orphaned assignments
    $orphanedAssignments = @($assignments | Where-Object { $_.IsOrphaned } | Sort-Object RiskLevel)
    
    # Get external users with privileged roles
    $externalPrivileged = @($assignments | Where-Object { 
        $_.IsExternal -and $_.RiskLevel -in @('Critical', 'High') 
    })
    
    # Find over-privileged principals (multiple high-risk roles or excessive scope)
    $overPrivilegedPrincipals = @()
    if ($principals.Count -gt 0) {
        $overPrivilegedPrincipals = @($principals | Where-Object {
            ($_.HasPrivilegedRoles -and $_.AssignmentCount -gt 5) -or
            ($_.SubscriptionCount -gt 10) -or
            ($_.RoleCount -gt 3 -and $_.HasPrivilegedRoles)
        } | Sort-Object @{
            Expression = { if ($_.HasPrivilegedRoles) { 0 } else { 1 } }
        }, @{
            Expression = { $_.AssignmentCount }
            Descending = $true
        } | Select-Object -First $TopN)
    } else {
        # Fallback: group assignments by principal
        $principalGroups = $assignments | Group-Object PrincipalId
        $overPrivilegedPrincipals = @($principalGroups | Where-Object {
            $group = $_.Group
            $hasPrivileged = @($group | Where-Object { $_.RiskLevel -in @('Critical', 'High') }).Count -gt 0
            ($hasPrivileged -and $group.Count -gt 5) -or
            (($group | Select-Object -ExpandProperty SubscriptionName -Unique).Count -gt 10) -or
            (($group | Select-Object -ExpandProperty RoleDefinitionName -Unique).Count -gt 3 -and $hasPrivileged)
        } | ForEach-Object {
            $group = $_.Group
            $first = $group[0]
            [PSCustomObject]@{
                PrincipalId = $_.Name
                PrincipalDisplayName = $first.PrincipalDisplayName
                PrincipalType = $first.PrincipalType
                AssignmentCount = $group.Count
                SubscriptionCount = ($group | Select-Object -ExpandProperty SubscriptionName -Unique).Count
                RoleCount = ($group | Select-Object -ExpandProperty RoleDefinitionName -Unique).Count
                HasPrivilegedRoles = @($group | Where-Object { $_.RiskLevel -in @('Critical', 'High') }).Count -gt 0
            }
        } | Sort-Object @{
            Expression = { if ($_.HasPrivilegedRoles) { 0 } else { 1 } }
        }, @{
            Expression = { $_.AssignmentCount }
            Descending = $true
        } | Select-Object -First $TopN)
    }
    
    # Find excessive scope assignments (tenant root, management group)
    $excessiveScope = @($assignments | Where-Object {
        $_.ScopeType -in @('Root', 'ManagementGroup') -and $_.RiskLevel -in @('Critical', 'High')
    } | Sort-Object @{
        Expression = { if ($_.ScopeType -eq 'Root') { 0 } else { 1 } }
    }, @{
        Expression = { if ($_.RiskLevel -eq 'Critical') { 0 } else { 1 } }
    } | Select-Object -First $TopN)
    
    # Build top risks list
    $topRisks = @()
    
    # Add orphaned assignments as top risks
    $topRisks += @($orphanedAssignments | Select-Object -First ($TopN / 4) | ForEach-Object {
        @{
            risk_type = "orphaned_assignment"
            principal_id = $_.PrincipalId
            principal_display_name = $_.PrincipalDisplayName
            principal_type = $_.PrincipalType
            role = $_.RoleDefinitionName
            scope = $_.ScopeDisplayName
            scope_type = $_.ScopeType
            subscription = $_.SubscriptionName
            risk_level = $_.RiskLevel
            description = "Orphaned assignment: Principal not found in directory"
        }
    })
    
    # Add external privileged users
    $topRisks += @($externalPrivileged | Select-Object -First ($TopN / 4) | ForEach-Object {
        @{
            risk_type = "external_privileged"
            principal_id = $_.PrincipalId
            principal_display_name = $_.PrincipalDisplayName
            principal_type = $_.PrincipalType
            role = $_.RoleDefinitionName
            scope = $_.ScopeDisplayName
            subscription = $_.SubscriptionName
            risk_level = $_.RiskLevel
            description = "External user with privileged role assignment"
        }
    })
    
    # Add excessive scope assignments
    $topRisks += @($excessiveScope | Select-Object -First ($TopN / 4) | ForEach-Object {
        @{
            risk_type = "excessive_scope"
            principal_id = $_.PrincipalId
            principal_display_name = $_.PrincipalDisplayName
            principal_type = $_.PrincipalType
            role = $_.RoleDefinitionName
            scope = $_.ScopeDisplayName
            scope_type = $_.ScopeType
            subscription = $_.SubscriptionName
            risk_level = $_.RiskLevel
            description = "Privileged role assigned at $($_.ScopeType) scope"
        }
    })
    
    # Add over-privileged principals
    $topRisks += @($overPrivilegedPrincipals | Select-Object -First ($TopN / 4) | ForEach-Object {
        @{
            risk_type = "over_privileged"
            principal_id = $_.PrincipalId
            principal_display_name = $_.PrincipalDisplayName
            principal_type = $_.PrincipalType
            assignment_count = $_.AssignmentCount
            subscription_count = $_.SubscriptionCount
            role_count = $_.RoleCount
            has_privileged_roles = $_.HasPrivilegedRoles
            description = "Principal with excessive assignments or scope"
        }
    })
    
    # Limit to TopN and sort by risk
    $topRisks = @($topRisks | Sort-Object @{
        Expression = {
            switch ($_.risk_type) {
                "orphaned_assignment" { 0 }
                "external_privileged" { 1 }
                "excessive_scope" { 2 }
                "over_privileged" { 3 }
                default { 4 }
            }
        }
    } | Select-Object -First $TopN)
    
    # Group by principal type
    $byPrincipalType = @($assignments | 
        Group-Object PrincipalType | 
        ForEach-Object {
            $typeAssignments = $_.Group
            @{
                principal_type = $_.Name
                count = $_.Count
                percentage = [math]::Round(($_.Count / $totalAssignments) * 100, 1)
                critical_count = @($typeAssignments | Where-Object { $_.RiskLevel -eq 'Critical' }).Count
                high_count = @($typeAssignments | Where-Object { $_.RiskLevel -eq 'High' }).Count
                orphaned_count = @($typeAssignments | Where-Object { $_.IsOrphaned }).Count
                external_count = @($typeAssignments | Where-Object { $_.IsExternal }).Count
            }
        } | Sort-Object count -Descending)
    
    # Group by risk level
    $byRiskLevel = @($assignments | 
        Group-Object RiskLevel | 
        ForEach-Object {
            @{
                risk_level = $_.Name
                count = $_.Count
                percentage = [math]::Round(($_.Count / $totalAssignments) * 100, 1)
                principals_affected = ($_.Group | Select-Object -ExpandProperty PrincipalId -Unique).Count
            }
        } | Sort-Object @{
            Expression = {
                switch ($_.risk_level) {
                    "Critical" { 0 }
                    "High" { 1 }
                    "Medium" { 2 }
                    "Low" { 3 }
                    default { 4 }
                }
            }
        })
    
    $insights = @{
        domain = "rbac_governance"
        generated_at = (Get-Date).ToString("o")
        
        summary = @{
            total_assignments = $totalAssignments
            total_principals = $totalPrincipals
            orphaned_count = $orphanedCount
            external_count = $externalCount
            redundant_count = $redundantCount
            privileged_count = $privilegedCount
            critical_risk_count = $criticalRisk
            high_risk_count = $highRisk
            medium_risk_count = $mediumRisk
            low_risk_count = $lowRisk
        }
        
        top_risks = $topRisks
        
        by_principal_type = $byPrincipalType
        
        by_risk_level = $byRiskLevel
        
        compliance_gaps = @{
            orphaned_assignments = @($orphanedAssignments | Select-Object -First 10 | ForEach-Object {
                @{
                    principal_id = $_.PrincipalId
                    principal_display_name = $_.PrincipalDisplayName
                    role = $_.RoleDefinitionName
                    scope = $_.ScopeDisplayName
                    subscription = $_.SubscriptionName
                    risk_level = $_.RiskLevel
                }
            })
            
            external_privileged_users = @($externalPrivileged | Select-Object -First 10 | ForEach-Object {
                @{
                    principal_id = $_.PrincipalId
                    principal_display_name = $_.PrincipalDisplayName
                    principal_type = $_.PrincipalType
                    role = $_.RoleDefinitionName
                    scope = $_.ScopeDisplayName
                    subscription = $_.SubscriptionName
                    risk_level = $_.RiskLevel
                }
            })
            
            over_privileged_principals = @($overPrivilegedPrincipals | Select-Object -First 10 | ForEach-Object {
                @{
                    principal_id = $_.PrincipalId
                    principal_display_name = $_.PrincipalDisplayName
                    principal_type = $_.PrincipalType
                    assignment_count = $_.AssignmentCount
                    subscription_count = $_.SubscriptionCount
                    role_count = $_.RoleCount
                    has_privileged_roles = $_.HasPrivilegedRoles
                }
            })
            
            excessive_scope_assignments = @($excessiveScope | Select-Object -First 10 | ForEach-Object {
                @{
                    principal_id = $_.PrincipalId
                    principal_display_name = $_.PrincipalDisplayName
                    role = $_.RoleDefinitionName
                    scope = $_.ScopeDisplayName
                    scope_type = $_.ScopeType
                    subscription = $_.SubscriptionName
                    risk_level = $_.RiskLevel
                }
            })
        }
    }
    
    Write-Verbose "RBAC insights generated: $totalAssignments assignments, $orphanedCount orphaned, $externalCount external, $privilegedCount privileged"
    
    return $insights
}

