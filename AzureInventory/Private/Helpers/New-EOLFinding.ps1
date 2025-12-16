<#
.SYNOPSIS
    Creates a new EOL (End of Life) Finding object for deprecated resources.

.DESCRIPTION
    Factory function that creates standardized EOL finding objects for tracking
    deprecated Azure resources/components based on DeprecationRules.

.PARAMETER SubscriptionId
    Azure subscription ID where the resource resides.

.PARAMETER SubscriptionName
    Human-readable subscription name.

.PARAMETER ResourceGroup
    Resource group name containing the resource.

.PARAMETER ResourceType
    Azure resource type (e.g., Microsoft.Storage/storageAccounts).

.PARAMETER ResourceName
    Name of the Azure resource.

.PARAMETER ResourceId
    Full ARM resource ID.

.PARAMETER Component
    Name of the deprecated component (e.g., "Azure Storage - TLS 1.0/1.1").

.PARAMETER Status
    Deprecation status: Deprecated, Retiring, or RETIRED.

.PARAMETER Deadline
    EOL deadline date (ISO format: YYYY-MM-DD).

.PARAMETER Severity
    EOL severity based on time until deadline: Critical, High, Medium, or Low.

.PARAMETER DaysUntilDeadline
    Number of days until the deadline (negative if past due).

.PARAMETER ActionRequired
    Human-readable description of required action.

.PARAMETER MigrationGuide
    CLI or PowerShell command to migrate/fix the issue.

.PARAMETER References
    Array of reference URLs.

.EXAMPLE
    $eolFinding = New-EOLFinding `
        -SubscriptionId "sub-123" `
        -SubscriptionName "Production" `
        -ResourceGroup "rg-storage" `
        -ResourceType "Microsoft.Storage/storageAccounts" `
        -ResourceName "mystorage" `
        -ResourceId "/subscriptions/.../storageAccounts/mystorage" `
        -Component "Azure Storage - TLS 1.0/1.1" `
        -Status "Deprecated" `
        -Deadline "2026-02-03" `
        -Severity "Critical" `
        -DaysUntilDeadline 45 `
        -ActionRequired "Upgrade storage accounts to TLS 1.2 minimum" `
        -MigrationGuide "az storage account update --name mystorage --resource-group rg-storage --min-tls-version TLS1_2"
#>
function New-EOLFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionName,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceType,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceName,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceId,
        
        [Parameter(Mandatory = $true)]
        [string]$Component,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('Deprecated', 'Retiring', 'RETIRED')]
        [string]$Status,
        
        [Parameter(Mandatory = $true)]
        [string]$Deadline,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('Critical', 'High', 'Medium', 'Low')]
        [string]$Severity,
        
        [Parameter(Mandatory = $true)]
        [int]$DaysUntilDeadline,
        
        [Parameter(Mandatory = $true)]
        [string]$ActionRequired,
        
        [string]$MigrationGuide = "",
        
        [string[]]$References = @()
    )
    
    [PSCustomObject]@{
        Id                 = [guid]::NewGuid().ToString()
        SubscriptionId     = $SubscriptionId
        SubscriptionName   = $SubscriptionName
        ResourceGroup      = $ResourceGroup
        ResourceType       = $ResourceType
        ResourceName       = $ResourceName
        ResourceId         = $ResourceId
        Component          = $Component
        Status             = $Status
        Deadline           = $Deadline
        Severity           = $Severity
        DaysUntilDeadline  = $DaysUntilDeadline
        ActionRequired     = $ActionRequired
        MigrationGuide     = $MigrationGuide
        References         = $References
        ScanTimestamp      = Get-Date
    }
}

