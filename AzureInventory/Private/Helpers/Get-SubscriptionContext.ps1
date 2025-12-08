<#
.SYNOPSIS
    Safely switches Azure subscription context with error handling.

.DESCRIPTION
    Sets the Azure context to the specified subscription ID and handles errors gracefully.
    Returns $true if successful, $false otherwise.

.PARAMETER SubscriptionId
    Azure subscription ID to switch to.

.EXAMPLE
    if (Get-SubscriptionContext -SubscriptionId "sub-123") {
        # Subscription context set successfully
    }
#>
function Get-SubscriptionContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId
    )
    
    try {
        # Suppress warnings about other tenants during context switching
        $originalWarningPreference = $WarningPreference
        $WarningPreference = 'SilentlyContinue'
        
        try {
            # Get current tenant to ensure we only switch to subscriptions in the same tenant
            $currentContext = Get-AzContext
            $currentTenantId = if ($currentContext -and $currentContext.Tenant) { $currentContext.Tenant.Id } else { $null }
            
            # Get subscription details first to verify tenant match (suppress warnings)
            if ($currentTenantId) {
                $subDetails = Get-AzSubscription -SubscriptionId $SubscriptionId -TenantId $currentTenantId -ErrorAction SilentlyContinue
                if ($subDetails -and $subDetails.TenantId -ne $currentTenantId) {
                    Write-Verbose "Subscription $SubscriptionId belongs to tenant $($subDetails.TenantId), but current tenant is $currentTenantId. Skipping."
                    return $false
                }
            }
            
            # Set context (suppress warnings about other tenants)
            $context = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
            if ($context) {
                Write-Verbose "Successfully switched to subscription: $SubscriptionId ($($context.Subscription.Name))"
                return $true
            }
            return $false
        }
        finally {
            $WarningPreference = $originalWarningPreference
        }
    }
    catch {
        Write-Verbose "Failed to switch to subscription $SubscriptionId : $_"
        return $false
    }
}


