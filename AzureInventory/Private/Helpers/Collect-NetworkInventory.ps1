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
                
                # Calculate detailed statistics
                $vnetCount = $inventory.Count
                $deviceCount = 0
                $gatewayCount = 0
                $peeringCount = 0
                $s2sConnectionCount = 0
                $erConnectionCount = 0
                
                foreach ($vnet in $inventory) {
                    # Count gateways
                    if ($vnet.Gateways) {
                        $gatewayCount += $vnet.Gateways.Count
                        
                        # Count connections per gateway
                        foreach ($gateway in $vnet.Gateways) {
                            # Check if this is an ExpressRoute gateway
                            $isExpressRouteGateway = ($gateway.Type -eq "ExpressRoute")
                            
                            if ($isExpressRouteGateway) {
                                # ExpressRoute gateways count as ER connections
                                $erConnectionCount++
                            }
                            elseif ($gateway.Connections) {
                                foreach ($conn in $gateway.Connections) {
                                    # S2S connections are IPsec VPN connections
                                    if ($conn.ConnectionType -eq "IPsec") {
                                        $s2sConnectionCount++
                                    }
                                    # ER connections can also be in ConnectionType
                                    elseif ($conn.ConnectionType -eq "ExpressRoute") {
                                        $erConnectionCount++
                                    }
                                }
                            }
                        }
                    }
                    
                    # Count peerings
                    if ($vnet.Peerings) {
                        $peeringCount += $vnet.Peerings.Count
                    }
                    
                    # Count devices (connected devices in subnets)
                    if ($vnet.Subnets) {
                        foreach ($subnet in $vnet.Subnets) {
                            if ($subnet.ConnectedDevices) {
                                $deviceCount += $subnet.ConnectedDevices.Count
                            }
                        }
                    }
                }
                
                # Output detailed statistics
                Write-Host "    Found $vnetCount VNET" -ForegroundColor Green
                if ($deviceCount -gt 0) {
                    Write-Host "    Found $deviceCount device$(if ($deviceCount -ne 1) { 's' })" -ForegroundColor Green
                }
                if ($gatewayCount -gt 0) {
                    Write-Host "    Found $gatewayCount Gateway$(if ($gatewayCount -ne 1) { 's' })" -ForegroundColor Green
                }
                if ($peeringCount -gt 0) {
                    Write-Host "    Found $peeringCount Peering$(if ($peeringCount -ne 1) { 's' })" -ForegroundColor Green
                }
                if ($s2sConnectionCount -gt 0) {
                    Write-Host "    Found $s2sConnectionCount S2S Connection$(if ($s2sConnectionCount -ne 1) { 's' })" -ForegroundColor Green
                }
                if ($erConnectionCount -gt 0) {
                    Write-Host "    Found $erConnectionCount ER Connection$(if ($erConnectionCount -ne 1) { 's' })" -ForegroundColor Green
                }
            }
        }
        catch {
            Write-Warning "Failed to get network inventory for $subscriptionNameToUse : $_"
            $Errors.Add("Failed to get network inventory for $subscriptionNameToUse : $_")
        }
    }
    
    Write-Host "`n  Total VNets collected: $($NetworkInventory.Count)" -ForegroundColor Green
}



