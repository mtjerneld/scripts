<#
.SYNOPSIS
    Retrieves Azure subscriptions to scan based on provided IDs or all enabled subscriptions.

.DESCRIPTION
    Gets subscriptions either from provided SubscriptionIds parameter or all enabled subscriptions
    in the current tenant. Handles errors and returns subscription objects.

.PARAMETER SubscriptionIds
    Optional array of subscription IDs to scan. If not provided, returns all enabled subscriptions.

.PARAMETER Errors
    List to append any errors encountered during subscription retrieval.

.OUTPUTS
    Array of subscription objects and updated error list.
#>
function Get-SubscriptionsToScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionIds,
        
        [Parameter(Mandatory = $false)]
        [System.Collections.Generic.List[string]]$Errors
    )
    
    if (-not $Errors) {
        $Errors = [System.Collections.Generic.List[string]]::new()
    }
    
    $subscriptions = @()
    
    if (-not $SubscriptionIds -or $SubscriptionIds.Count -eq 0) {
        try {
            # Get current tenant from context to avoid cross-tenant authentication issues
            $currentContext = Get-AzContext
            if (-not $currentContext) {
                Write-Error "No Azure context found. Please run Connect-AuditEnvironment first."
                return @{ Subscriptions = @(); Errors = $Errors }
            }
            
            if ($currentContext.Tenant) {
                $currentTenantId = $currentContext.Tenant.Id
                Write-Verbose "Filtering subscriptions to current tenant: $currentTenantId"
                
                # Suppress warnings about other tenants during subscription retrieval
                $allSubscriptions = Invoke-WithSuppressedWarnings {
                    # Use -TenantId parameter to only query the current tenant (avoids MFA prompts for other tenants)
                    Get-AzSubscription -TenantId $currentTenantId -ErrorAction Stop
                }
                $subscriptions = $allSubscriptions | Where-Object { 
                    $_.State -eq 'Enabled' -and $_.TenantId -eq $currentTenantId
                }
            }
            else {
                Write-Warning "No tenant information found in context. Attempting to get all enabled subscriptions..."
                $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
            }
        }
        catch {
            Write-Error "Failed to retrieve subscriptions. Ensure you are connected to Azure: $_"
            return @{ Subscriptions = @(); Errors = $Errors }
        }
    }
    else {
        foreach ($subId in $SubscriptionIds) {
            try {
                $sub = Get-AzSubscription -SubscriptionId $subId -ErrorAction Stop
                if ($sub) {
                    $subscriptions += $sub
                }
            }
            catch {
                $errorMsg = "Failed to retrieve subscription $subId : $_"
                $Errors.Add($errorMsg)
                Write-Warning $errorMsg
            }
        }
    }
    
    return @{
        Subscriptions = $subscriptions
        Errors = $Errors
    }
}




