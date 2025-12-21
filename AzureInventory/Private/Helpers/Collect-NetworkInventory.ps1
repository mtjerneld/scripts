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
# Note: "Collect" is intentionally used (not an approved verb) to distinguish aggregation functions
# from single-source retrieval functions (which use "Get-"). This is a known PSScriptAnalyzer warning.
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
                $vnetItems = @($inventory | Where-Object { $_.Type -eq "VNet" })
                $vnetCount = $vnetItems.Count
                $virtualWANHubItems = @($inventory | Where-Object { $_.Type -eq "VirtualWANHub" })
                $virtualWANHubCount = $virtualWANHubItems.Count
                $azureFirewallItems = @($inventory | Where-Object { $_.Type -eq "AzureFirewall" })
                $azureFirewallCount = $azureFirewallItems.Count
                $deviceCount = 0
                $gatewayCount = 0
                $peeringCount = 0
                $s2sConnectionCount = 0
                $erConnectionCount = 0
                
                foreach ($item in $inventory) {
                    if ($item.Type -eq "VNet") {
                        # Count gateways
                        if ($item.Gateways) {
                            $gatewayCount += $item.Gateways.Count
                            
                            # Count connections per gateway
                            foreach ($gateway in $item.Gateways) {
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
                        if ($item.Peerings) {
                            $peeringCount += $item.Peerings.Count
                        }
                        
                        # Count devices (connected devices in subnets)
                        if ($item.Subnets) {
                            foreach ($subnet in $item.Subnets) {
                                if ($subnet.ConnectedDevices) {
                                    $deviceCount += $subnet.ConnectedDevices.Count
                                }
                            }
                        }
                    }
                    elseif ($item.Type -eq "VirtualWANHub") {
                        # Count ExpressRoute connections from hub
                        if ($item.ExpressRouteConnections) {
                            $erConnectionCount += $item.ExpressRouteConnections.Count
                        }
                        
                        # Count S2S VPN connections from hub
                        if ($item.VpnConnections) {
                            $s2sConnectionCount += $item.VpnConnections.Count
                        }
                        
                        # Count peerings to hub
                        if ($item.Peerings) {
                            $peeringCount += $item.Peerings.Count
                        }
                    }
                }
                
                # Output detailed statistics
                if ($vnetCount -gt 0) {
                    Write-Host "    Found $vnetCount VNET$(if ($vnetCount -ne 1) { 's' })" -ForegroundColor Green
                }
                if ($virtualWANHubCount -gt 0) {
                    Write-Host "    Found $virtualWANHubCount Virtual WAN Hub$(if ($virtualWANHubCount -ne 1) { 's' })" -ForegroundColor Green
                }
                if ($azureFirewallCount -gt 0) {
                    Write-Host "    Found $azureFirewallCount Azure Firewall$(if ($azureFirewallCount -ne 1) { 's' })" -ForegroundColor Green
                }
                if ($deviceCount -gt 0) {
                    Write-Host "    Found $deviceCount Device$(if ($deviceCount -ne 1) { 's' })" -ForegroundColor Green
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
    
    $totalVnets = ($NetworkInventory | Where-Object { $_.Type -eq "VNet" }).Count
    $totalHubs = ($NetworkInventory | Where-Object { $_.Type -eq "VirtualWANHub" }).Count
    $totalFirewalls = ($NetworkInventory | Where-Object { $_.Type -eq "AzureFirewall" }).Count
    Write-Host "`n  Total collected: $totalVnets VNet$(if ($totalVnets -ne 1) { 's' })" -ForegroundColor Green
    if ($totalHubs -gt 0) {
        Write-Host "  Total Virtual WAN Hubs: $totalHubs" -ForegroundColor Green
    }
    if ($totalFirewalls -gt 0) {
        Write-Host "  Total Azure Firewalls: $totalFirewalls" -ForegroundColor Green
    }
}



