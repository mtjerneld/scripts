<#
.SYNOPSIS
    Converts network inventory data into AI-ready JSON insights.

.DESCRIPTION
    Extracts and structures the most important network security insights
    for AI analysis, focusing on NSG security risks, unprotected subnets,
    overlapping subnets, and network topology issues.

.PARAMETER NetworkInventory
    Array of network inventory objects from Get-AzureNetworkInventory.

.PARAMETER TopN
    Number of top risks to include (default: 20).

.EXAMPLE
    $insights = ConvertTo-NetworkAIInsights -NetworkInventory $networkInventory -TopN 25
#>
function ConvertTo-NetworkAIInsights {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$NetworkInventory,
        
        [Parameter(Mandatory = $false)]
        [int]$TopN = 20
    )
    
    Write-Verbose "Converting network data to AI insights (TopN: $TopN)"
    
    # Handle empty/null data
    if (-not $NetworkInventory -or $NetworkInventory.Count -eq 0) {
        Write-Verbose "No network inventory found"
        return @{
            domain = "network_security"
            generated_at = (Get-Date).ToString("o")
            summary = @{
                total_vnets = 0
                total_subnets = 0
                unprotected_subnets = 0
                total_nsg_risks = 0
                critical_risks = 0
                high_risks = 0
                overlapping_subnets = 0
                isolated_vnets = 0
                disconnected_connections = 0
            }
            security_risks = @()
            topology_issues = @()
            unprotected_subnets = @()
            disconnected_connections = @()
            by_subscription = @()
        }
    }
    
    # Filter to VNets only (exclude Virtual WAN Hubs and Azure Firewalls for main analysis)
    $vnets = @($NetworkInventory | Where-Object { $_.Type -eq "VNet" })
    
    # Also process Virtual WAN Hubs for ExpressRoute and VPN connections
    $virtualWanHubs = @($NetworkInventory | Where-Object { $_.Type -eq "VirtualWANHub" })
    
    # Calculate summary statistics
    $totalVnets = $vnets.Count
    $totalSubnets = 0
    $unprotectedSubnets = 0
    $allNsgRisks = [System.Collections.Generic.List[PSObject]]::new()
    $criticalRisks = 0
    $highRisks = 0
    $mediumRisks = 0
    
    # Exception subnets that don't need NSG
    $exceptionSubnets = @("GatewaySubnet", "AzureBastionSubnet", "AzureFirewallSubnet")
    
    # Collect all security risks and unprotected subnets
    $unprotectedSubnetList = [System.Collections.Generic.List[PSObject]]::new()
    $isolatedVnets = [System.Collections.Generic.List[PSObject]]::new()
    $disconnectedConnections = [System.Collections.Generic.List[PSObject]]::new()
    
    foreach ($vnet in $vnets) {
        $hasPeerings = $vnet.Peerings -and $vnet.Peerings.Count -gt 0
        $hasGateways = $vnet.Gateways -and $vnet.Gateways.Count -gt 0
        
        # Check if VNet is isolated (no peerings, no gateways)
        if (-not $hasPeerings -and -not $hasGateways) {
            $isolatedVnets.Add([PSCustomObject]@{
                VNetName = $vnet.Name
                ResourceGroup = $vnet.ResourceGroup
                SubscriptionName = $vnet.SubscriptionName
                AddressSpace = $vnet.AddressSpace
            })
        }
        
        # Check for disconnected peerings
        if ($vnet.Peerings) {
            foreach ($peering in $vnet.Peerings) {
                if ($peering.State -and $peering.State -ne "Connected") {
                    $disconnectedConnections.Add([PSCustomObject]@{
                        ConnectionType = "VNetPeering"
                        Name = $peering.Name
                        VNetName = $vnet.Name
                        RemoteVnetName = $peering.RemoteVnetName
                        ResourceGroup = $vnet.ResourceGroup
                        SubscriptionName = $vnet.SubscriptionName
                        Status = $peering.State
                        Description = "VNet peering is not connected (State: $($peering.State))"
                    })
                }
            }
        }
        
        # Check for disconnected gateway connections (S2S VPN)
        if ($vnet.Gateways) {
            foreach ($gateway in $vnet.Gateways) {
                if ($gateway.Connections) {
                    foreach ($connection in $gateway.Connections) {
                        if ($connection.ConnectionStatus -and $connection.ConnectionStatus -ne "Connected") {
                            $connectionType = if ($connection.ConnectionType) { $connection.ConnectionType } else { "S2S VPN" }
                            $disconnectedConnections.Add([PSCustomObject]@{
                                ConnectionType = $connectionType
                                Name = $connection.Name
                                VNetName = $vnet.Name
                                GatewayName = $gateway.Name
                                RemoteSiteName = if ($connection.RemoteNetwork) { $connection.RemoteNetwork.Name } else { "Unknown" }
                                ResourceGroup = $vnet.ResourceGroup
                                SubscriptionName = $vnet.SubscriptionName
                                Status = $connection.ConnectionStatus
                                Description = "$connectionType connection is not connected (Status: $($connection.ConnectionStatus))"
                            })
                        }
                    }
                }
            }
        }
        
        if ($vnet.Subnets) {
            foreach ($subnet in $vnet.Subnets) {
                $totalSubnets++
                
                # Check for unprotected subnets (excluding exceptions)
                if (-not $subnet.NsgId -and $subnet.Name -notin $exceptionSubnets) {
                    $unprotectedSubnets++
                    $unprotectedSubnetList.Add([PSCustomObject]@{
                        VNetName = $vnet.Name
                        SubnetName = $subnet.Name
                        ResourceGroup = $vnet.ResourceGroup
                        SubscriptionName = $vnet.SubscriptionName
                        AddressPrefix = $subnet.AddressPrefix
                        ConnectedDevices = $subnet.ConnectedDevices.Count
                    })
                }
                
                # Collect NSG risks
                if ($subnet.NsgRisks) {
                    foreach ($risk in $subnet.NsgRisks) {
                        # Add VNet and subnet context
                        $riskObj = [PSCustomObject]@{
                            Severity = $risk.Severity
                            RuleName = $risk.RuleName
                            Port = $risk.Port
                            PortName = $risk.PortName
                            Source = $risk.Source
                            Destination = $risk.Destination
                            Protocol = $risk.Protocol
                            Description = $risk.Description
                            NsgName = $risk.NsgName
                            VNetName = $vnet.Name
                            SubnetName = $subnet.Name
                            ResourceGroup = $vnet.ResourceGroup
                            SubscriptionName = $vnet.SubscriptionName
                        }
                        $allNsgRisks.Add($riskObj)
                        
                        if ($risk.Severity -eq "Critical") { $criticalRisks++ }
                        elseif ($risk.Severity -eq "High") { $highRisks++ }
                        elseif ($risk.Severity -eq "Medium") { $mediumRisks++ }
                    }
                }
            }
        }
    }
    
    $totalNsgRisks = $allNsgRisks.Count
    
    # Check Virtual WAN Hubs for disconnected ExpressRoute and VPN connections
    foreach ($hub in $virtualWanHubs) {
        # Check ExpressRoute connections
        if ($hub.ExpressRouteConnections) {
            foreach ($erConn in $hub.ExpressRouteConnections) {
                if ($erConn.ConnectionStatus -and $erConn.ConnectionStatus -ne "Connected") {
                    $disconnectedConnections.Add([PSCustomObject]@{
                        ConnectionType = "ExpressRoute"
                        Name = $erConn.Name
                        HubName = $hub.Name
                        CircuitName = $erConn.ExpressRouteCircuitName
                        ResourceGroup = $hub.ResourceGroup
                        SubscriptionName = $hub.SubscriptionName
                        Status = $erConn.ConnectionStatus
                        Description = "ExpressRoute connection is not connected (Status: $($erConn.ConnectionStatus))"
                    })
                }
            }
        }
        
        # Check VPN connections (S2S)
        if ($hub.VpnConnections) {
            foreach ($vpnConn in $hub.VpnConnections) {
                if ($vpnConn.ConnectionStatus -and $vpnConn.ConnectionStatus -ne "Connected") {
                    $disconnectedConnections.Add([PSCustomObject]@{
                        ConnectionType = "S2S VPN"
                        Name = $vpnConn.Name
                        HubName = $hub.Name
                        RemoteSiteName = $vpnConn.RemoteSiteName
                        ResourceGroup = $hub.ResourceGroup
                        SubscriptionName = $hub.SubscriptionName
                        Status = $vpnConn.ConnectionStatus
                        Description = "S2S VPN connection is not connected (Status: $($vpnConn.ConnectionStatus))"
                    })
                }
            }
        }
        
        # Check hub peerings
        if ($hub.Peerings) {
            foreach ($peering in $hub.Peerings) {
                if ($peering.State -and $peering.State -ne "Connected") {
                    $disconnectedConnections.Add([PSCustomObject]@{
                        ConnectionType = "HubPeering"
                        Name = $peering.PeeringName
                        HubName = $hub.Name
                        VNetName = $peering.VNetName
                        ResourceGroup = $hub.ResourceGroup
                        SubscriptionName = $hub.SubscriptionName
                        Status = $peering.State
                        Description = "Virtual WAN Hub peering is not connected (State: $($peering.State))"
                    })
                }
            }
        }
    }
    
    # Find overlapping subnets (simplified - check for duplicate address prefixes)
    $overlappingSubnets = [System.Collections.Generic.List[PSObject]]::new()
    $subnetMap = @{}
    
    foreach ($vnet in $vnets) {
        if ($vnet.Subnets) {
            foreach ($subnet in $vnet.Subnets) {
                if ($subnet.AddressPrefix) {
                    if ($subnetMap.ContainsKey($subnet.AddressPrefix)) {
                        # Found duplicate/overlapping subnet
                        $existing = $subnetMap[$subnet.AddressPrefix]
                        $overlappingSubnets.Add([PSCustomObject]@{
                            AddressPrefix = $subnet.AddressPrefix
                            VNet1 = $existing.VNetName
                            Subnet1 = $existing.SubnetName
                            Subscription1 = $existing.SubscriptionName
                            VNet2 = $vnet.Name
                            Subnet2 = $subnet.Name
                            Subscription2 = $vnet.SubscriptionName
                        })
                    } else {
                        $subnetMap[$subnet.AddressPrefix] = [PSCustomObject]@{
                            VNetName = $vnet.Name
                            SubnetName = $subnet.Name
                            SubscriptionName = $vnet.SubscriptionName
                        }
                    }
                }
            }
        }
    }
    
    # Build top security risks (sorted by severity)
    $topSecurityRisks = @($allNsgRisks | Sort-Object @{
        Expression = {
            switch ($_.Severity) {
                "Critical" { 0 }
                "High" { 1 }
                "Medium" { 2 }
                default { 3 }
            }
        }
    } | Select-Object -First $TopN | ForEach-Object {
        @{
            severity = $_.Severity
            rule_name = $_.RuleName
            port = $_.Port
            port_name = $_.PortName
            source = $_.Source
            destination = $_.Destination
            protocol = $_.Protocol
            description = $_.Description
            nsg_name = $_.NsgName
            vnet_name = $_.VNetName
            subnet_name = $_.SubnetName
            resource_group = $_.ResourceGroup
            subscription = $_.SubscriptionName
        }
    })
    
    # Build topology issues
    $topologyIssues = @()
    
    # Add isolated VNets
    $topologyIssues += @($isolatedVnets | Select-Object -First ($TopN / 2) | ForEach-Object {
        @{
            issue_type = "isolated_vnet"
            vnet_name = $_.VNetName
            resource_group = $_.ResourceGroup
            subscription = $_.SubscriptionName
            address_space = $_.AddressSpace
            description = "VNet has no peerings or gateways - may be isolated"
        }
    })
    
    # Add overlapping subnets
    $topologyIssues += @($overlappingSubnets | Select-Object -First ($TopN / 2) | ForEach-Object {
        @{
            issue_type = "overlapping_subnet"
            address_prefix = $_.AddressPrefix
            vnet1 = $_.VNet1
            subnet1 = $_.Subnet1
            subscription1 = $_.Subscription1
            vnet2 = $_.VNet2
            subnet2 = $_.Subnet2
            subscription2 = $_.Subscription2
            description = "Duplicate or overlapping subnet address prefix detected"
        }
    })
    
    # Limit topology issues to TopN
    $topologyIssues = @($topologyIssues | Select-Object -First $TopN)
    
    # Group by subscription
    $bySubscription = @($vnets | 
        Group-Object SubscriptionName | 
        ForEach-Object {
            $subVnets = $_.Group
            $subSubnets = 0
            $subUnprotected = 0
            $subRisks = 0
            $subCritical = 0
            $subHigh = 0
            
            foreach ($vnet in $subVnets) {
                if ($vnet.Subnets) {
                    foreach ($subnet in $vnet.Subnets) {
                        $subSubnets++
                        if (-not $subnet.NsgId -and $subnet.Name -notin $exceptionSubnets) {
                            $subUnprotected++
                        }
                        if ($subnet.NsgRisks) {
                            $subRisks += $subnet.NsgRisks.Count
                            foreach ($risk in $subnet.NsgRisks) {
                                if ($risk.Severity -eq "Critical") { $subCritical++ }
                                elseif ($risk.Severity -eq "High") { $subHigh++ }
                            }
                        }
                    }
                }
            }
            
            @{
                subscription = $_.Name
                vnet_count = $subVnets.Count
                subnet_count = $subSubnets
                unprotected_subnets = $subUnprotected
                nsg_risks = $subRisks
                critical_risks = $subCritical
                high_risks = $subHigh
            }
        } | Sort-Object nsg_risks -Descending)
    
    $insights = @{
        domain = "network_security"
        generated_at = (Get-Date).ToString("o")
        
            summary = @{
                total_vnets = $totalVnets
                total_subnets = $totalSubnets
                unprotected_subnets = $unprotectedSubnets
                total_nsg_risks = $totalNsgRisks
                critical_risks = $criticalRisks
                high_risks = $highRisks
                medium_risks = $mediumRisks
                overlapping_subnets = $overlappingSubnets.Count
                isolated_vnets = $isolatedVnets.Count
                disconnected_connections = $disconnectedConnections.Count
            }
            
            security_risks = $topSecurityRisks
            
            topology_issues = $topologyIssues
            
            unprotected_subnets = @($unprotectedSubnetList | Select-Object -First 10 | ForEach-Object {
                @{
                    vnet_name = $_.VNetName
                    subnet_name = $_.SubnetName
                    resource_group = $_.ResourceGroup
                    subscription = $_.SubscriptionName
                    address_prefix = $_.AddressPrefix
                    connected_devices = $_.ConnectedDevices
                }
            })
            
            disconnected_connections = @($disconnectedConnections | Select-Object -First $TopN | ForEach-Object {
                @{
                    connection_type = $_.ConnectionType
                    name = $_.Name
                    status = $_.Status
                    description = $_.Description
                    vnet_name = $_.VNetName
                    hub_name = $_.HubName
                    remote_vnet_name = $_.RemoteVnetName
                    remote_site_name = $_.RemoteSiteName
                    gateway_name = $_.GatewayName
                    circuit_name = $_.CircuitName
                    resource_group = $_.ResourceGroup
                    subscription = $_.SubscriptionName
                }
            })
            
            by_subscription = $bySubscription
    }
    
    Write-Verbose "Network insights generated: $totalVnets VNets, $totalSubnets subnets, $unprotectedSubnets unprotected, $totalNsgRisks NSG risks"
    
    return $insights
}

