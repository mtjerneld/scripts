<#
.SYNOPSIS
    Gets a display name for a subscription, using the name if available, otherwise the ID.

.DESCRIPTION
    Returns a human-readable subscription name. If the subscription object has a Name property
    that is not null or whitespace, returns that. Otherwise, returns the subscription ID.

.PARAMETER Subscription
    Subscription object (from Get-AzSubscription) or hashtable with Name and Id properties.

.PARAMETER SubscriptionId
    Subscription ID as fallback if subscription object is not provided.

.EXAMPLE
    $displayName = Get-SubscriptionDisplayName -Subscription $sub

.EXAMPLE
    $displayName = Get-SubscriptionDisplayName -SubscriptionId "sub-123"
#>
function Get-SubscriptionDisplayName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
        $Subscription,
        
        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId
    )
    
    if ($Subscription) {
        $subName = if ($Subscription.Name) { $Subscription.Name } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($subName)) {
            return $subName
        }
        
        # Fallback to ID from subscription object
        if ($Subscription.Id) {
            return $Subscription.Id
        }
    }
    
    # Fallback to provided ID
    if ($SubscriptionId) {
        return $SubscriptionId
    }
    
    # Last resort
    return "Unknown Subscription"
}


