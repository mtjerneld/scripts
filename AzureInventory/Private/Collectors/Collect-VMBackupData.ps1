<#
.SYNOPSIS
    Collects VM backup data from multiple subscriptions.

.DESCRIPTION
    Iterates through provided subscriptions and uses Get-AzureVirtualMachineFindings
    to collect VM inventory and backup status. This aggregated data is used for
    the VM Backup Report.

.PARAMETER Subscriptions
    Array of subscription objects to scan.

.OUTPUTS
    List of PSObjects containing VM inventory and backup status.
#>
function Collect-VMBackupData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Subscriptions
    )
    
    $allVMInventory = [System.Collections.Generic.List[PSObject]]::new()
    
    foreach ($sub in $Subscriptions) {
        $subId = $sub.Id
        $subName = $sub.Name
        
        Write-Verbose "Collecting VM backup data for subscription: $subName"
        
        # Set subscription context
        $contextSet = Get-SubscriptionContext -SubscriptionId $subId -ErrorAction SilentlyContinue
        if (-not $contextSet) {
            Write-Warning "Failed to set context for subscription $subName ($subId) - skipping"
            continue
        }
        
        try {
            # Use the existing scanner which already collects backup inventory
            $result = Get-AzureVirtualMachineFindings `
                -SubscriptionId $subId `
                -SubscriptionName $subName
            
            if ($result -and $result.Inventory) {
                $count = $result.Inventory.Count
                Write-Verbose "Found $count VMs in subscription $subName"
                
                # Add all inventory items to our master list
                foreach ($item in $result.Inventory) {
                    $allVMInventory.Add($item)
                }
            }
        }
        catch {
            Write-Warning "Error collecting VM backup data for $subName : $_"
        }
    }
    
    Write-Host "    $($allVMInventory.Count) VMs found" -ForegroundColor $(if ($allVMInventory.Count -gt 0) { 'Green' } else { 'Gray' })

    return $allVMInventory
}
