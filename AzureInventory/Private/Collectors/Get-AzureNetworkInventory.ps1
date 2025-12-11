<#
.SYNOPSIS
    Collects comprehensive network inventory for a subscription.

.DESCRIPTION
    Scans for VNets, Subnets, NSGs, Peerings, Gateways, NICs, Public IPs, etc.
    Returns a hierarchical object structure suitable for the Network Inventory report.

.PARAMETER SubscriptionId
    ID of the subscription to scan.

.PARAMETER SubscriptionName
    Name of the subscription to scan.

.OUTPUTS
    PSCustomObject containing the network inventory.
#>
function Get-AzureNetworkInventory {
    [CmdletBinding()]
    param(
        [string]$SubscriptionId,
        [string]$SubscriptionName
    )

    $inventory = [System.Collections.Generic.List[PSObject]]::new()
    
    try {
        Write-Verbose "Getting VNets..."
        $vnets = Get-AzVirtualNetwork -ErrorAction SilentlyContinue

        if (-not $vnets) {
            return $inventory
        }

        # Cache related resources to avoid repeated calls
        Write-Verbose "Caching network resources..."
        $nsgs = Get-AzNetworkSecurityGroup -ErrorAction SilentlyContinue
        $routeTables = Get-AzRouteTable -ErrorAction SilentlyContinue
        
        # Get Gateways using Get-AzResource first to avoid prompting for ResourceGroup
        $gateways = [System.Collections.Generic.List[PSObject]]::new()
        $gatewayResources = Get-AzResource -ResourceType "Microsoft.Network/virtualNetworkGateways" -ErrorAction SilentlyContinue
        if ($gatewayResources) {
            foreach ($res in $gatewayResources) {
                $gw = Get-AzVirtualNetworkGateway -ResourceGroupName $res.ResourceGroupName -Name $res.Name -ErrorAction SilentlyContinue
                if ($gw) { $gateways.Add($gw) }
            }
        }
        
        # Get VPN Connections (S2S tunnels)
        $vpnConnections = [System.Collections.Generic.List[PSObject]]::new()
        $connectionResources = Get-AzResource -ResourceType "Microsoft.Network/connections" -ErrorAction SilentlyContinue
        if ($connectionResources) {
            foreach ($res in $connectionResources) {
                try {
                    $conn = Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $res.ResourceGroupName -Name $res.Name -ErrorAction SilentlyContinue
                    if ($conn -and $conn.ConnectionType -eq "IPsec") {
                        $vpnConnections.Add($conn)
                    }
                }
                catch {
                    # Connection might not be a gateway connection, skip
                }
            }
        }
        
        # Get Local Network Gateways (on-premises networks)
        $localGateways = [System.Collections.Generic.List[PSObject]]::new()
        $localGatewayResources = Get-AzResource -ResourceType "Microsoft.Network/localNetworkGateways" -ErrorAction SilentlyContinue
        if ($localGatewayResources) {
            foreach ($res in $localGatewayResources) {
                $lgw = Get-AzLocalNetworkGateway -ResourceGroupName $res.ResourceGroupName -Name $res.Name -ErrorAction SilentlyContinue
                if ($lgw) { $localGateways.Add($lgw) }
            }
        }

        $publicIps = Get-AzPublicIpAddress -ErrorAction SilentlyContinue
        $privateEndpoints = Get-AzPrivateEndpoint -ErrorAction SilentlyContinue
        
        # Get all NICs once (might be heavy, but better than per-subnet loop if many subnets)
        $allNics = Get-AzNetworkInterface -ErrorAction SilentlyContinue

        # If $vnets is null, the previous check handles it.
        # Ensure collection is not null before looping
        if ($null -eq $vnets) { $vnets = @() }

        foreach ($vnet in $vnets) {
            # Safely handle Tags (might be null)
            $tagsString = ""
            if ($vnet.Tags -and $vnet.Tags.Count -gt 0) {
                $tagsString = ($vnet.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "; "
            }
            
            # Safely handle DnsServers
            $dnsServersString = ""
            if ($vnet.DhcpOptions -and $vnet.DhcpOptions.DnsServers) {
                $dnsServersString = $vnet.DhcpOptions.DnsServers -join ", "
            }
            
            # Safely handle AddressSpace
            $addressSpaceString = ""
            if ($vnet.AddressSpace -and $vnet.AddressSpace.AddressPrefixes) {
                $addressSpaceString = $vnet.AddressSpace.AddressPrefixes -join ", "
            }

            $vnetObj = [PSCustomObject]@{
                Type = "VNet"
                Id = $vnet.Id
                Name = $vnet.Name
                ResourceGroup = $vnet.ResourceGroupName
                Location = $vnet.Location
                AddressSpace = $addressSpaceString
                SubscriptionId = $SubscriptionId
                SubscriptionName = $SubscriptionName
                DnsServers = $dnsServersString
                Tags = $tagsString
                
                Subnets = [System.Collections.Generic.List[PSObject]]::new()
                Peerings = [System.Collections.Generic.List[PSObject]]::new()
                Gateways = [System.Collections.Generic.List[PSObject]]::new()
            }

            # Process Peerings
            if ($vnet.VirtualNetworkPeerings) {
                foreach ($peering in $vnet.VirtualNetworkPeerings) {
                    # Safely extract remote VNet name
                    $remoteVnetName = ""
                    $remoteVnetId = ""
                    if ($peering.RemoteVirtualNetwork -and $peering.RemoteVirtualNetwork.Id) {
                        $remoteVnetId = $peering.RemoteVirtualNetwork.Id
                        $remoteVnetName = $remoteVnetId.Split('/')[-1]
                    }
                    
                    $vnetObj.Peerings.Add([PSCustomObject]@{
                        Name = $peering.Name
                        RemoteVnetId = $remoteVnetId
                        RemoteVnetName = $remoteVnetName
                        State = $peering.PeeringState
                        AllowForwardedTraffic = $peering.AllowForwardedTraffic
                        AllowGatewayTransit = $peering.AllowGatewayTransit
                        UseRemoteGateways = $peering.UseRemoteGateways
                    })
                }
            }

            # Process Gateways (find gateways connected to this VNet)
            # Gateways are typically in a 'GatewaySubnet' within the VNet.
            # We can match by finding the GatewaySubnet ID in the gateway's IP configurations.
            $vnetGateways = @()
            if ($gateways -and $gateways.Count -gt 0) {
                $vnetGateways = $gateways | Where-Object { 
                    $matched = $false
                    if ($_.IpConfigurations) {
                        foreach ($ipconf in $_.IpConfigurations) {
                            if ($ipconf.Subnet -and $ipconf.Subnet.Id -like "$($vnet.Id)/subnets/*") {
                                $matched = $true
                                break
                            }
                        }
                    }
                    $matched
                }
            }

            if ($vnetGateways) {
                foreach ($gw in $vnetGateways) {
                    # Handle possible null Public IP configuration
                    $pipId = $null
                    if ($gw.IpConfigurations) {
                        foreach ($ipConfig in $gw.IpConfigurations) {
                            if ($ipConfig.PublicIpAddress -and $ipConfig.PublicIpAddress.Id) {
                                $pipId = $ipConfig.PublicIpAddress.Id
                                break # Assume first PIP for now or join them if multiple
                            }
                        }
                    }
                    
                    # Safely handle Sku
                    $skuName = $null
                    if ($gw.Sku -and $gw.Sku.Name) {
                        $skuName = $gw.Sku.Name
                    }
                    
                    # Find VPN connections for this gateway
                    $gwConnections = [System.Collections.Generic.List[PSObject]]::new()
                    foreach ($conn in $vpnConnections) {
                        if ($conn.VirtualNetworkGateway1 -and $conn.VirtualNetworkGateway1.Id -eq $gw.Id) {
                            # This is a connection FROM this gateway
                            $remoteNetwork = $null
                            $remoteNetworkName = "Unknown"
                            
                            # Check if connected to Local Network Gateway (on-premises)
                            if ($conn.LocalNetworkGateway2) {
                                $lgw = $localGateways | Where-Object { $_.Id -eq $conn.LocalNetworkGateway2.Id } | Select-Object -First 1
                                if ($lgw) {
                                    $remoteNetworkName = $lgw.Name
                                    $remoteNetwork = [PSCustomObject]@{
                                        Type = "OnPremises"
                                        Name = $lgw.Name
                                        AddressSpace = if ($lgw.LocalNetworkAddressSpace) { $lgw.LocalNetworkAddressSpace.AddressPrefixes -join ", " } else { "" }
                                        GatewayIpAddress = if ($lgw.GatewayIpAddress) { $lgw.GatewayIpAddress } else { "" }
                                    }
                                }
                            }
                            # Check if connected to another Virtual Network Gateway (VNet-to-VNet)
                            elseif ($conn.VirtualNetworkGateway2) {
                                $remoteGw = $gateways | Where-Object { $_.Id -eq $conn.VirtualNetworkGateway2.Id } | Select-Object -First 1
                                if ($remoteGw) {
                                    # Find the VNet this gateway belongs to
                                    $remoteVnet = $vnets | Where-Object {
                                        $matched = $false
                                        if ($remoteGw.IpConfigurations) {
                                            foreach ($ipconf in $remoteGw.IpConfigurations) {
                                                if ($ipconf.Subnet -and $ipconf.Subnet.Id -like "$($_.Id)/subnets/*") {
                                                    $matched = $true
                                                    break
                                                }
                                            }
                                        }
                                        $matched
                                    } | Select-Object -First 1
                                    
                                    if ($remoteVnet) {
                                        $remoteNetworkName = $remoteVnet.Name
                                        $remoteNetwork = [PSCustomObject]@{
                                            Type = "VNet"
                                            Name = $remoteVnet.Name
                                            AddressSpace = if ($remoteVnet.AddressSpace -and $remoteVnet.AddressSpace.AddressPrefixes) {
                                                $remoteVnet.AddressSpace.AddressPrefixes -join ", "
                                            } else { "" }
                                            SubscriptionId = $remoteVnet.SubscriptionId
                                        }
                                    }
                                }
                            }
                            
                            $gwConnections.Add([PSCustomObject]@{
                                Name = $conn.Name
                                Id = $conn.Id
                                ConnectionStatus = $conn.ConnectionStatus
                                ConnectionType = $conn.ConnectionType
                                RemoteNetwork = $remoteNetwork
                                RemoteNetworkName = $remoteNetworkName
                            })
                        }
                    }

                    $vnetObj.Gateways.Add([PSCustomObject]@{
                        Name = $gw.Name
                        Id = $gw.Id
                        Type = $gw.GatewayType
                        Sku = $skuName
                        VpnType = $gw.VpnType
                        PublicIp = $pipId
                        Connections = $gwConnections
                    })
                }
            }

            # Process Subnets
            if ($vnet.Subnets) {
                foreach ($subnet in $vnet.Subnets) {
                    # Find attached NSG
                    $nsg = $null
                    if ($subnet.NetworkSecurityGroup -and $nsgs) {
                        $nsg = $nsgs | Where-Object { $_.Id -eq $subnet.NetworkSecurityGroup.Id } | Select-Object -First 1
                    }

                    # Find attached Route Table
                    $rt = $null
                    if ($subnet.RouteTable -and $routeTables) {
                        $rt = $routeTables | Where-Object { $_.Id -eq $subnet.RouteTable.Id } | Select-Object -First 1
                    }

                    # Find connected NICs
                    # IpConfigurations can be null or a single object or an array, robust handling needed
                    $subnetNics = @()
                    if ($allNics) {
                        $subnetNics = $allNics | Where-Object { 
                            if ($_.IpConfigurations) {
                                foreach ($ipconf in $_.IpConfigurations) {
                                    if ($ipconf.Subnet -and $ipconf.Subnet.Id -eq $subnet.Id) {
                                        return $true
                                    }
                                }
                            }
                            return $false
                        }
                    }

                    # Safely handle AddressPrefix
                    $addressPrefixString = ""
                    if ($subnet.AddressPrefix) {
                        $addressPrefixString = $subnet.AddressPrefix -join ", "
                    }
                    
                    # Safely handle ServiceEndpoints
                    $serviceEndpointsString = ""
                    if ($subnet.ServiceEndpoints -and $subnet.ServiceEndpoints.Service) {
                        $serviceEndpointsString = $subnet.ServiceEndpoints.Service -join ", "
                    }

                    # Analyze NSG for security risks
                    $nsgRisks = @()
                    if ($nsg -and $nsg.SecurityRules) {
                        $nsgRisks = @(Get-NsgRiskAnalysis -NsgRules $nsg.SecurityRules -NsgName $nsg.Name)
                    }

                    $subnetObj = [PSCustomObject]@{
                        Name = $subnet.Name
                        Id = $subnet.Id
                        AddressPrefix = $addressPrefixString
                        ServiceEndpoints = $serviceEndpointsString
                        
                        NsgId = if ($nsg) { $nsg.Id } else { $null }
                        NsgName = if ($nsg) { $nsg.Name } else { $null }
                        NsgRules = if ($nsg) { $nsg.SecurityRules } else { $null }
                        NsgRisks = $nsgRisks
                        
                        RouteTableId = if ($rt) { $rt.Id } else { $null }
                        RouteTableName = if ($rt) { $rt.Name } else { $null }
                        Routes = if ($rt) { $rt.Routes } else { $null }
                        
                        ConnectedDevices = [System.Collections.Generic.List[PSObject]]::new()
                    }

                    # Process Connected Devices (NICs)
                    foreach ($nic in $subnetNics) {
                        $vmId = $null
                        if ($nic.VirtualMachine -and $nic.VirtualMachine.Id) {
                            $vmId = $nic.VirtualMachine.Id
                        }
                        $vmName = if ($vmId) { $vmId.Split('/')[-1] } else { "Unattached" }
                        
                        # Check for Private Endpoint
                        $isPe = $false
                        $peName = ""
                        if ($nic.PrivateEndpoint -and $nic.PrivateEndpoint.Id) {
                            $isPe = $true
                            $peName = $nic.PrivateEndpoint.Id.Split('/')[-1]
                            $vmName = "PE: $peName"
                        }

                        # Public IP - Handle array of IP Configs
                        $pipId = $null
                        $privateIp = $null
                        
                        if ($nic.IpConfigurations) {
                            # Find the IP config that matches this subnet
                            foreach ($ipconf in $nic.IpConfigurations) {
                                if ($ipconf.Subnet -and $ipconf.Subnet.Id -eq $subnet.Id) {
                                    $privateIp = $ipconf.PrivateIpAddress
                                    if ($ipconf.PublicIpAddress -and $ipconf.PublicIpAddress.Id) {
                                        $pipId = $ipconf.PublicIpAddress.Id
                                    }
                                    break 
                                }
                            }
                        }

                        $pip = $null
                        if ($pipId -and $publicIps) {
                            $pip = $publicIps | Where-Object { $_.Id -eq $pipId } | Select-Object -First 1
                        }

                        $subnetObj.ConnectedDevices.Add([PSCustomObject]@{
                            Name = $nic.Name
                            Id = $nic.Id
                            PrivateIp = $privateIp
                            PublicIp = if ($pip) { $pip.IpAddress } else { $null }
                            VmName = $vmName
                            VmId = $vmId
                            IsPrivateEndpoint = $isPe
                        })
                    }

                    $vnetObj.Subnets.Add($subnetObj)
                }
            }

            $inventory.Add($vnetObj)
        }
    }
    catch {
        Write-Error "Error getting network inventory for subscription $SubscriptionName : $_"
    }

    return $inventory
}

