<#
.SYNOPSIS
    Creates a new SecurityFinding object for audit results.

.DESCRIPTION
    Factory function that creates standardized security finding objects with all required properties
    for tracking CIS control compliance across Azure resources.

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

.PARAMETER ControlId
    CIS control ID (e.g., "3.15") or "N/A" if not mapped.

.PARAMETER ControlName
    Human-readable control description.

.PARAMETER Category
    Service category (Storage, AppService, VM, ARC, Monitor, Network, SQL).

.PARAMETER Severity
    Finding severity: Critical, High, Medium, or Low.

.PARAMETER CurrentValue
    Actual value found in the resource configuration.

.PARAMETER ExpectedValue
    Required secure value for compliance.

.PARAMETER Status
    Check status: PASS, FAIL, ERROR, or SKIPPED.

.PARAMETER RemediationSteps
    Human-readable remediation guidance.

.PARAMETER RemediationCommand
    CLI or PowerShell command to fix the issue.

.PARAMETER EOLDate
    Optional end-of-life date for deprecated components (ISO format: YYYY-MM-DD).

.PARAMETER CisLevel
    CIS Benchmark Level: L1 (Level 1) or L2 (Level 2). Level 2 controls apply only to critical data or high-security environments.

.PARAMETER Note
    Additional notes or context about the finding (e.g., "Level 2 - Required only for critical data").

.EXAMPLE
    $finding = New-SecurityFinding `
        -SubscriptionId "sub-123" `
        -SubscriptionName "Production" `
        -ResourceGroup "rg-storage" `
        -ResourceType "Microsoft.Storage/storageAccounts" `
        -ResourceName "mystorage" `
        -ResourceId "/subscriptions/.../storageAccounts/mystorage" `
        -ControlId "3.15" `
        -ControlName "Minimum TLS Version 1.2" `
        -Category "Storage" `
        -Severity "Critical" `
        -CurrentValue "TLS1_0" `
        -ExpectedValue "TLS1_2" `
        -Status "FAIL" `
        -RemediationSteps "Update storage account to use TLS 1.2 minimum" `
        -RemediationCommand "az storage account update --name mystorage --resource-group rg-storage --min-tls-version TLS1_2" `
        -EOLDate "2026-02-03"
#>
function New-SecurityFinding {
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
        [string]$ControlId,
        
        [Parameter(Mandatory = $true)]
        [string]$ControlName,
        
        [Parameter(Mandatory = $true)]
        [string]$Category,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('Critical', 'High', 'Medium', 'Low')]
        [string]$Severity,
        
        [string]$CurrentValue = "N/A",
        
        [Parameter(Mandatory = $true)]
        [string]$ExpectedValue,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('PASS', 'FAIL', 'ERROR', 'SKIPPED')]
        [string]$Status,
        
        [string]$RemediationSteps = "",
        
        [string]$RemediationCommand = "",
        
        [string]$EOLDate = $null,
        
        [ValidateSet('L1', 'L2', 'N/A')]
        [string]$CisLevel = "L1",
        
        [string]$Note = "",
        
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
        ControlId          = $ControlId
        ControlName        = $ControlName
        Category           = $Category
        Severity           = $Severity
        CurrentValue       = $CurrentValue
        ExpectedValue      = $ExpectedValue
        Status             = $Status
        RemediationSteps   = $RemediationSteps
        RemediationCommand = $RemediationCommand
        ScanTimestamp      = Get-Date
        EOLDate            = $EOLDate
        CisLevel           = $CisLevel
        Note               = $Note
        References         = $References
    }
}


