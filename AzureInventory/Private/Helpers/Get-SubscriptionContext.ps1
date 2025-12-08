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
        $context = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
        if ($context) {
            Write-Verbose "Successfully switched to subscription: $SubscriptionId ($($context.Subscription.Name))"
            return $true
        }
        return $false
    }
    catch {
        Write-Warning "Failed to switch to subscription $SubscriptionId : $_"
        return $false
    }
}


