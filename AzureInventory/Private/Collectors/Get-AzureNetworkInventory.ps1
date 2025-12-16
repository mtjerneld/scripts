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
        
        # Get additional network resources
        Write-Verbose "Collecting additional network resources..."
        
        # DNS Resolvers
        $dnsResolvers = @()
        try {
            $dnsResolverResources = Get-AzResource -ResourceType "Microsoft.Network/dnsResolvers" -ErrorAction SilentlyContinue
            if ($dnsResolverResources) {
                foreach ($res in $dnsResolverResources) {
                    try {
                        $resolver = Get-AzDnsResolver -ResourceGroupName $res.ResourceGroupName -Name $res.Name -ErrorAction SilentlyContinue
                        if ($resolver) { $dnsResolvers += $resolver }
                    } catch {
                        # DNS Resolver cmdlet might not be available in all Az.Network versions
                    }
                }
            }
        } catch {
            Write-Verbose "DNS Resolvers collection skipped: $_"
        }
        
        # Load Balancers
        $loadBalancers = Get-AzLoadBalancer -ErrorAction SilentlyContinue
        
        # Application Gateways
        $appGateways = @()
        try {
            $appGwResources = Get-AzResource -ResourceType "Microsoft.Network/applicationGateways" -ErrorAction SilentlyContinue
            if ($appGwResources) {
                foreach ($res in $appGwResources) {
                    try {
                        $appGw = Get-AzApplicationGateway -ResourceGroupName $res.ResourceGroupName -Name $res.Name -ErrorAction SilentlyContinue
                        if ($appGw) { $appGateways += $appGw }
                    } catch {
                        Write-Verbose "Failed to get Application Gateway $($res.Name): $_"
                    }
                }
            }
        } catch {
            Write-Verbose "Application Gateways collection skipped: $_"
        }
        
        # NAT Gateways
        $natGateways = @()
        try {
            $natGwResources = Get-AzResource -ResourceType "Microsoft.Network/natGateways" -ErrorAction SilentlyContinue
            if ($natGwResources) {
                foreach ($res in $natGwResources) {
                    try {
                        $natGw = Get-AzNatGateway -ResourceGroupName $res.ResourceGroupName -Name $res.Name -ErrorAction SilentlyContinue
                        if ($natGw) { $natGateways += $natGw }
                    } catch {
                        Write-Verbose "Failed to get NAT Gateway $($res.Name): $_"
                    }
                }
            }
        } catch {
            Write-Verbose "NAT Gateways collection skipped: $_"
        }
        
        # Bastion Hosts
        $bastionHosts = @()
        try {
            $bastionResources = Get-AzResource -ResourceType "Microsoft.Network/bastionHosts" -ErrorAction SilentlyContinue
            if ($bastionResources) {
                foreach ($res in $bastionResources) {
                    try {
                        $bastion = Get-AzBastion -ResourceGroupName $res.ResourceGroupName -Name $res.Name -ErrorAction SilentlyContinue
                        if ($bastion) { $bastionHosts += $bastion }
                    } catch {
                        Write-Verbose "Failed to get Bastion Host $($res.Name): $_"
                    }
                }
            }
        } catch {
            Write-Verbose "Bastion Hosts collection skipped: $_"
        }

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

                    # Track Private Endpoints already added via NICs to avoid duplicates
                    $processedPEIds = [System.Collections.Generic.HashSet[string]]::new()
                    
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
                        $peId = $null
                        if ($nic.PrivateEndpoint -and $nic.PrivateEndpoint.Id) {
                            $isPe = $true
                            $peId = $nic.PrivateEndpoint.Id
                            $peName = $peId.Split('/')[-1]
                            $vmName = "PE: $peName"
                            [void]$processedPEIds.Add($peId)
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
                            DeviceType = if ($isPe) { "Private Endpoint" } else { "NIC/VM" }
                        })
                    }
                    
                    # Process Private Endpoints directly (not just via NICs)
                    if ($privateEndpoints) {
                        foreach ($pe in $privateEndpoints) {
                            # Skip if this PE was already added via NIC processing
                            if ($processedPEIds.Contains($pe.Id)) {
                                continue
                            }
                            
                            # Check if PE is connected to this subnet
                            if ($pe.Subnet -and $pe.Subnet.Id -eq $subnet.Id) {
                                $pePrivateIp = $null
                                if ($pe.PrivateIPAddress) {
                                    $pePrivateIp = $pe.PrivateIPAddress
                                } elseif ($pe.NetworkInterfaces -and $pe.NetworkInterfaces.Count -gt 0) {
                                    # Try to get IP from first NIC
                                    $peNicId = $pe.NetworkInterfaces[0].Id
                                    $peNic = $allNics | Where-Object { $_.Id -eq $peNicId } | Select-Object -First 1
                                    if ($peNic -and $peNic.IpConfigurations) {
                                        foreach ($ipconf in $peNic.IpConfigurations) {
                                            if ($ipconf.Subnet -and $ipconf.Subnet.Id -eq $subnet.Id) {
                                                $pePrivateIp = $ipconf.PrivateIpAddress
                                                break
                                            }
                                        }
                                    }
                                }
                                
                                $subnetObj.ConnectedDevices.Add([PSCustomObject]@{
                                    Name = $pe.Name
                                    Id = $pe.Id
                                    PrivateIp = $pePrivateIp
                                    PublicIp = $null
                                    VmName = "Private Endpoint"
                                    VmId = $null
                                    IsPrivateEndpoint = $true
                                    DeviceType = "Private Endpoint"
                                })
                            }
                        }
                    }
                    
                    # Process DNS Resolvers
                    if ($dnsResolvers) {
                        foreach ($resolver in $dnsResolvers) {
                            # DNS Resolvers can have subnet references in various places
                            $matched = $false
                            if ($resolver.VirtualNetwork -and $resolver.VirtualNetwork.Id -eq $vnet.Id) {
                                # Check if resolver has direct subnet reference
                                if ($resolver.Subnet -and $resolver.Subnet.Id -eq $subnet.Id) {
                                    $matched = $true
                                }
                                # Check IP configurations for subnet references
                                elseif ($resolver.VirtualNetworkIpConfigurations) {
                                    foreach ($ipConfig in $resolver.VirtualNetworkIpConfigurations) {
                                        if ($ipConfig.Subnet -and $ipConfig.Subnet.Id -eq $subnet.Id) {
                                            $matched = $true
                                            break
                                        }
                                    }
                                }
                                
                                if ($matched) {
                                    $subnetObj.ConnectedDevices.Add([PSCustomObject]@{
                                        Name = $resolver.Name
                                        Id = $resolver.Id
                                        PrivateIp = $null
                                        PublicIp = $null
                                        VmName = "DNS Resolver"
                                        VmId = $null
                                        IsPrivateEndpoint = $false
                                        DeviceType = "DNS Resolver"
                                    })
                                }
                            }
                        }
                    }
                    
                    # Process Load Balancers
                    if ($loadBalancers) {
                        foreach ($lb in $loadBalancers) {
                            if ($lb.FrontendIpConfigurations) {
                                foreach ($frontendIp in $lb.FrontendIpConfigurations) {
                                    if ($frontendIp.Subnet -and $frontendIp.Subnet.Id -eq $subnet.Id) {
                                        $subnetObj.ConnectedDevices.Add([PSCustomObject]@{
                                            Name = $lb.Name
                                            Id = $lb.Id
                                            PrivateIp = if ($frontendIp.PrivateIpAddress) { $frontendIp.PrivateIpAddress } else { $null }
                                            PublicIp = if ($frontendIp.PublicIpAddress -and $frontendIp.PublicIpAddress.Id) {
                                                $pip = $publicIps | Where-Object { $_.Id -eq $frontendIp.PublicIpAddress.Id } | Select-Object -First 1
                                                if ($pip) { $pip.IpAddress } else { $null }
                                            } else { $null }
                                            VmName = "Load Balancer"
                                            VmId = $null
                                            IsPrivateEndpoint = $false
                                            DeviceType = "Load Balancer"
                                        })
                                        break
                                    }
                                }
                            }
                        }
                    }
                    
                    # Process Application Gateways
                    if ($appGateways) {
                        foreach ($appGw in $appGateways) {
                            if ($appGw.GatewayIPConfigurations) {
                                foreach ($ipConfig in $appGw.GatewayIPConfigurations) {
                                    if ($ipConfig.Subnet -and $ipConfig.Subnet.Id -eq $subnet.Id) {
                                        $subnetObj.ConnectedDevices.Add([PSCustomObject]@{
                                            Name = $appGw.Name
                                            Id = $appGw.Id
                                            PrivateIp = if ($ipConfig.Subnet) { "Subnet: $($subnet.Name)" } else { $null }
                                            PublicIp = if ($appGw.PublicIPAddresses) {
                                                $pipIds = $appGw.PublicIPAddresses | ForEach-Object { $_.Id }
                                                $pips = $publicIps | Where-Object { $pipIds -contains $_.Id }
                                                if ($pips) { ($pips | ForEach-Object { $_.IpAddress }) -join ", " } else { $null }
                                            } else { $null }
                                            VmName = "Application Gateway"
                                            VmId = $null
                                            IsPrivateEndpoint = $false
                                            DeviceType = "Application Gateway"
                                        })
                                        break
                                    }
                                }
                            }
                        }
                    }
                    
                    # Process NAT Gateways
                    if ($natGateways) {
                        foreach ($natGw in $natGateways) {
                            if ($natGw.Subnets) {
                                foreach ($natSubnet in $natGw.Subnets) {
                                    if ($natSubnet.Id -eq $subnet.Id) {
                                        $subnetObj.ConnectedDevices.Add([PSCustomObject]@{
                                            Name = $natGw.Name
                                            Id = $natGw.Id
                                            PrivateIp = $null
                                            PublicIp = if ($natGw.PublicIpAddresses) {
                                                $pipIds = $natGw.PublicIpAddresses | ForEach-Object { $_.Id }
                                                $pips = $publicIps | Where-Object { $pipIds -contains $_.Id }
                                                if ($pips) { ($pips | ForEach-Object { $_.IpAddress }) -join ", " } else { $null }
                                            } else { $null }
                                            VmName = "NAT Gateway"
                                            VmId = $null
                                            IsPrivateEndpoint = $false
                                            DeviceType = "NAT Gateway"
                                        })
                                        break
                                    }
                                }
                            }
                        }
                    }
                    
                    # Process Bastion Hosts
                    if ($bastionHosts) {
                        foreach ($bastion in $bastionHosts) {
                            if ($bastion.IpConfigurations) {
                                foreach ($ipConfig in $bastion.IpConfigurations) {
                                    if ($ipConfig.Subnet -and $ipConfig.Subnet.Id -eq $subnet.Id) {
                                        $subnetObj.ConnectedDevices.Add([PSCustomObject]@{
                                            Name = $bastion.Name
                                            Id = $bastion.Id
                                            PrivateIp = if ($ipConfig.PrivateIpAddress) { $ipConfig.PrivateIpAddress } else { $null }
                                            PublicIp = if ($ipConfig.PublicIpAddress -and $ipConfig.PublicIpAddress.Id) {
                                                $pip = $publicIps | Where-Object { $_.Id -eq $ipConfig.PublicIpAddress.Id } | Select-Object -First 1
                                                if ($pip) { $pip.IpAddress } else { $null }
                                            } else { $null }
                                            VmName = "Bastion Host"
                                            VmId = $null
                                            IsPrivateEndpoint = $false
                                            DeviceType = "Bastion Host"
                                        })
                                        break
                                    }
                                }
                            }
                        }
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

