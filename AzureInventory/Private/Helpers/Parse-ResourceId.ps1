<#
.SYNOPSIS
    Parses an Azure Resource ID to extract resource group and resource name.

.DESCRIPTION
    Extracts resource group name and resource name from a full Azure Resource Manager (ARM) resource ID.
    Resource IDs follow the format: /subscriptions/{subId}/resourceGroups/{rgName}/providers/{provider}/{type}/{name}

.PARAMETER ResourceId
    Full ARM resource ID to parse.

.EXAMPLE
    $parsed = Parse-ResourceId -ResourceId "/subscriptions/123/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/sa1"
    # Returns: @{ ResourceGroup = "rg1"; ResourceName = "sa1"; SubscriptionId = "123" }

.EXAMPLE
    $rg = (Parse-ResourceId -ResourceId $resourceId).ResourceGroup
#>
function Parse-ResourceId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )
    
    $result = @{
        ResourceGroup  = $null
        ResourceName   = $null
        SubscriptionId = $null
        Provider       = $null
        ResourceType   = $null
    }
    
    if ([string]::IsNullOrWhiteSpace($ResourceId)) {
        return $result
    }
    
    # Extract subscription ID
    if ($ResourceId -match '/subscriptions/([^/]+)') {
        $result.SubscriptionId = $Matches[1]
    }
    
    # Extract resource group
    if ($ResourceId -match '/resourceGroups/([^/]+)') {
        $result.ResourceGroup = $Matches[1]
    }
    
    # Extract provider and resource type
    if ($ResourceId -match '/providers/([^/]+)/([^/]+)') {
        $result.Provider = $Matches[1]
        $result.ResourceType = $Matches[2]
    }
    
    # Extract resource name (last segment after providers)
    if ($ResourceId -match '/([^/]+)$') {
        $result.ResourceName = $Matches[1]
    }
    
    return $result
}



