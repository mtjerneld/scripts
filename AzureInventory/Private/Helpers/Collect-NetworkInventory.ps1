<#
.SYNOPSIS
    Collects network inventory data for all subscriptions.

.DESCRIPTION
    Iterates through subscriptions and collects network inventory data using
    the Get-AzureNetworkInventory function.

.PARAMETER Subscriptions
    Array of subscription objects to collect data from.

.PARAMETER NetworkInventory
    List to append network inventory data to.

.PARAMETER Errors
    List to append errors to.

.OUTPUTS
    Updated collections (NetworkInventory, Errors).
#>
function Collect-NetworkInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Subscriptions,
        
        [Parameter(Mandatory = $false)]
        [System.Collections.Generic.List[PSObject]]$NetworkInventory,
        
        [Parameter(Mandatory = $false)]
        [System.Collections.Generic.List[string]]$Errors
    )
    
    # Initialize collections if not provided
    if ($null -eq $NetworkInventory) {
        $NetworkInventory = [System.Collections.Generic.List[PSObject]]::new()
    }
    if ($null -eq $Errors) {
        $Errors = [System.Collections.Generic.List[string]]::new()
    }
    
    Write-Host "`n=== Collecting Network Inventory Data ===" -ForegroundColor Cyan
    
    # Check if function exists, if not try to load it directly (similar to Collect-ChangeTrackingData)
    if (-not (Get-Command -Name Get-AzureNetworkInventory -ErrorAction SilentlyContinue)) {
        $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $collectorPath = Join-Path $moduleRoot "Private\Collectors\Get-AzureNetworkInventory.ps1"
        
        if (Test-Path $collectorPath) {
            try {
                . $collectorPath
            }
            catch {
                Write-Warning "Failed to load function: $_"
            }
        }
    }
    
    # Get tenant ID for context switching
    $currentContext = Get-AzContext
    $tenantId = if ($currentContext -and $currentContext.Tenant) { $currentContext.Tenant.Id } else { $null }
    
    foreach ($sub in $Subscriptions) {
        $subscriptionNameToUse = Get-SubscriptionDisplayName -Subscription $sub
        Write-Host "`n  Collecting from: $subscriptionNameToUse..." -ForegroundColor Gray
        
        try {
            Invoke-WithSuppressedWarnings {
                if ($tenantId) {
                    Set-AzContext -SubscriptionId $sub.Id -TenantId $tenantId -ErrorAction Stop | Out-Null
                } else {
                    Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
                }
            }
            
            $inventory = Get-AzureNetworkInventory -SubscriptionId $sub.Id -SubscriptionName $subscriptionNameToUse
            
            if ($inventory) {
                foreach ($item in $inventory) {
                    $NetworkInventory.Add($item)
                }
                Write-Host "    Found $($inventory.Count) VNets" -ForegroundColor Green
            }
        }
        catch {
            Write-Warning "Failed to get network inventory for $subscriptionNameToUse : $_"
            $Errors.Add("Failed to get network inventory for $subscriptionNameToUse : $_")
        }
    }
    
    Write-Host "`n  Total VNets collected: $($NetworkInventory.Count)" -ForegroundColor Green
}


