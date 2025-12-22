<#
.SYNOPSIS
    Generates HTML network inventory report.

.DESCRIPTION
    Creates a comprehensive HTML report for network topology with interactive
    network diagram, subscription grouping, and NSG security risk analysis.

.PARAMETER NetworkInventory
    List of network inventory objects.

.PARAMETER OutputPath
    Path for HTML report output.

.PARAMETER TenantId
    Tenant ID for context.
#>
function Export-NetworkInventoryReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[PSObject]]$NetworkInventory,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [string]$TenantId
    )
    
    # Create output directory if needed
    $outputDir = Split-Path -Parent $OutputPath
    if ($outputDir -and -not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    
    # If OutputPath is just a filename, make it relative to current location
    if (-not [System.IO.Path]::IsPathRooted($OutputPath) -and -not $outputDir) {
        $OutputPath = Join-Path (Get-Location).Path $OutputPath
    }
    
    Write-Verbose "Generating network inventory report to: $OutputPath"
    
    # Helper function to escape strings for JavaScript
    function Format-JsString {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
            [string]$Text
        )
        # Escape backslashes, quotes, and convert actual newlines to \n escape sequence
        # PowerShell uses `n for newlines, but JavaScript strings require \n escape sequences
        # The CSS white-space: pre-line will render \n as line breaks in the browser
        return $Text -replace '\\', '\\\\' -replace '"', '\"' -replace "`r`n", '\n' -replace "`n", '\n' -replace "`r", '\n'
    }
    
    # Helper function to check if two CIDR subnets overlap
    function Test-SubnetOverlap {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true)]
            [string]$Subnet1,
            [Parameter(Mandatory=$true)]
            [string]$Subnet2
        )
        
        try {
            # Parse CIDR notation (e.g., "10.0.0.0/24")
            # Match separately to avoid $Matches being overwritten
            if (-not ($Subnet1 -match '^(\d+\.\d+\.\d+\.\d+)/(\d+)$')) {
                return $false
            }
            $ip1Str = $Matches[1]
            $prefix1 = [int]$Matches[2]
            
            if (-not ($Subnet2 -match '^(\d+\.\d+\.\d+\.\d+)/(\d+)$')) {
                return $false
            }
            $ip2Str = $Matches[1]
            $prefix2 = [int]$Matches[2]
            
            # Validate prefix length
            if ($prefix1 -lt 0 -or $prefix1 -gt 32 -or $prefix2 -lt 0 -or $prefix2 -gt 32) {
                return $false
            }
            
            $ip1 = [System.Net.IPAddress]::Parse($ip1Str)
            $ip2 = [System.Net.IPAddress]::Parse($ip2Str)
            
            # Get network addresses as bytes
            $ip1Bytes = $ip1.GetAddressBytes()
            $ip2Bytes = $ip2.GetAddressBytes()
            
            # Convert to uint32 (network byte order - big endian)
            $ip1Uint = [uint32]$ip1Bytes[0] * 16777216 + [uint32]$ip1Bytes[1] * 65536 + [uint32]$ip1Bytes[2] * 256 + [uint32]$ip1Bytes[3]
            $ip2Uint = [uint32]$ip2Bytes[0] * 16777216 + [uint32]$ip2Bytes[1] * 65536 + [uint32]$ip2Bytes[2] * 256 + [uint32]$ip2Bytes[3]
            
            # Calculate network addresses by masking out host bits
            # Network mask: all 1s in network portion
            $hostBits1 = 32 - $prefix1
            $hostBits2 = 32 - $prefix2
            
            # Calculate number of hosts: 2^hostBits - 1 (for broadcast), but we need the mask
            # Network mask = ~(2^hostBits - 1) = MaxValue - (2^hostBits - 1)
            $hostCount1 = [Math]::Pow(2, $hostBits1) - 1
            $hostCount2 = [Math]::Pow(2, $hostBits2) - 1
            
            $networkMask1 = [uint32]::MaxValue - [uint32]$hostCount1
            $networkMask2 = [uint32]::MaxValue - [uint32]$hostCount2
            
            # Calculate network addresses (IP AND network mask)
            $network1 = $ip1Uint -band $networkMask1
            $network2 = $ip2Uint -band $networkMask2
            
            # Calculate broadcast addresses (network + host count)
            $broadcast1 = $network1 + [uint32]$hostCount1
            $broadcast2 = $network2 + [uint32]$hostCount2
            
            # Two ranges overlap if: range1.start <= range2.end AND range2.start <= range1.end
            # This means: network1 <= broadcast2 AND network2 <= broadcast1
            return ($network1 -le $broadcast2 -and $network2 -le $broadcast1)
        }
        catch {
            return $false
        }
    }
    
    # Helper function to find overlapping subnets across connections
    function Find-OverlappingSubnets {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true)]
            [array]$Connections
        )
        
        $overlaps = @()
        $subnetMap = @{}  # subnet -> connection name
        
        foreach ($conn in $Connections) {
            if (-not $conn.RemoteNetwork -or -not $conn.RemoteNetwork.AddressSpace) { continue }
            
            $connName = if ($conn.RemoteNetworkName) { $conn.RemoteNetworkName } else { "Unknown" }
            $subnets = $conn.RemoteNetwork.AddressSpace -split ',' | ForEach-Object { $_.Trim() }
            
            foreach ($subnet in $subnets) {
                if ($subnet -notmatch '^\d+\.\d+\.\d+\.\d+/\d+$') { continue }
                
                # Check for exact duplicate first
                if ($subnetMap.ContainsKey($subnet)) {
                    # Exact duplicate subnet in multiple connections
                    $overlaps += [PSCustomObject]@{
                        Subnet = $subnet
                        Connection1 = $subnetMap[$subnet]
                        Connection2 = $connName
                        Type = "Duplicate"
                    }
                } else {
                    # Check for range overlaps with existing subnets
                    foreach ($existingSubnet in $subnetMap.Keys) {
                        if (Test-SubnetOverlap -Subnet1 $subnet -Subnet2 $existingSubnet) {
                            $overlaps += [PSCustomObject]@{
                                Subnet = "$subnet vs $existingSubnet"
                                Connection1 = $subnetMap[$existingSubnet]
                                Connection2 = $connName
                                Type = "Overlap"
                            }
                        }
                    }
                    # Track this subnet with its connection
                    $subnetMap[$subnet] = $connName
                }
            }
        }
        
        # Force array return to prevent PowerShell unwrapping single-item arrays
        return , $overlaps
    }
    
    try {
        # Ensure NetworkInventory is not null
        if (-not $NetworkInventory) {
            $NetworkInventory = [System.Collections.Generic.List[PSObject]]::new()
        }
        
        # Separate VNets, Virtual WAN Hubs, and Azure Firewalls
        $vnets = @($NetworkInventory | Where-Object { $_.Type -eq "VNet" })
        $virtualWANHubs = @($NetworkInventory | Where-Object { $_.Type -eq "VirtualWANHub" })
        $azureFirewalls = @($NetworkInventory | Where-Object { $_.Type -eq "AzureFirewall" })
        
        # Calculate summary metrics - @() ensures array, so Count always works
        $totalVnets = $vnets.Count
        $totalVirtualWANHubs = $virtualWANHubs.Count
        $totalAzureFirewalls = $azureFirewalls.Count
        $totalSubnets = 0
        $totalNsgs = 0
        $totalPeerings = 0
        $totalGateways = 0
        $subscriptionCount = ($NetworkInventory | Select-Object -ExpandProperty SubscriptionName -Unique).Count
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $totalDevices = 0
        $totalCriticalRisks = 0
        $totalHighRisks = 0
        $totalMediumRisks = 0
        $totalS2SConnections = 0
        $totalERConnections = 0
        $disconnectedConnections = 0
        $subnetsMissingNSG = 0
        $subnetsWithServiceEndpoints = 0
        $totalServiceEndpoints = 0
        
        # Collect unique NSGs and subscriptions, and all NSG risks
        $uniqueNsgIds = [System.Collections.Generic.HashSet[string]]::new()
        $subscriptions = [System.Collections.Generic.Dictionary[string, PSObject]]::new()
        $allRisks = [System.Collections.Generic.List[PSObject]]::new()
        
        # Count unique peerings (each peering relationship appears twice - once from each VNet)
        $uniquePeerings = [System.Collections.Generic.HashSet[string]]::new()
        
        foreach ($vnet in $vnets) {
            $totalSubnets += $vnet.Subnets.Count
            $totalGateways += $vnet.Gateways.Count
            
            # Track unique peering relationships
            foreach ($peering in $vnet.Peerings) {
                # Create a unique key by sorting VNet names alphabetically
                $vnetPair = @($vnet.Name, $peering.RemoteVnetName) | Sort-Object
                $peeringKey = "$($vnetPair[0])|$($vnetPair[1])"
                [void]$uniquePeerings.Add($peeringKey)
            }
            
            # Count gateway connections (S2S and ER)
            foreach ($gateway in $vnet.Gateways) {
                if ($gateway.Type -eq "ExpressRoute") {
                    $totalERConnections++
                }
                elseif ($gateway.Connections) {
                    foreach ($conn in $gateway.Connections) {
                        if ($conn.ConnectionType -eq "IPsec") {
                            $totalS2SConnections++
                        }
                        elseif ($conn.ConnectionType -eq "ExpressRoute") {
                            $totalERConnections++
                        }
                        # Check connection status
                        if ($conn.ConnectionStatus -and $conn.ConnectionStatus -ne "Connected") {
                            $disconnectedConnections++
                        }
                    }
                }
            }
            
            # Track subscriptions
            $subKey = $vnet.SubscriptionId
            if ($subKey -and -not $subscriptions.ContainsKey($subKey)) {
                $subscriptions[$subKey] = [PSCustomObject]@{
                    Id = $vnet.SubscriptionId
                    Name = $vnet.SubscriptionName
                    VNets = [System.Collections.Generic.List[PSObject]]::new()
                }
            }
            if ($subKey) {
                $subscriptions[$subKey].VNets.Add($vnet)
            }
            
            foreach ($subnet in $vnet.Subnets) {
                if ($subnet.NsgId) {
                    [void]$uniqueNsgIds.Add($subnet.NsgId)
                } else {
                    # Count subnets missing NSG, but exclude legitimate exceptions
                    $subnetName = $subnet.Name
                    
                    # Exclude special subnet names that shouldn't have NSGs:
                    # - GatewaySubnet: VPN/ExpressRoute Gateway subnets
                    # - AzureBastionSubnet: Azure Bastion subnets
                    # - AzureFirewallSubnet: Azure Firewall subnets
                    # Note: Application Gateway v2 subnets CAN have NSGs (with specific rules),
                    # so they are still counted if missing NSG
                    $isExceptionSubnet = ($subnetName -eq "GatewaySubnet" -or 
                                        $subnetName -eq "AzureBastionSubnet" -or 
                                        $subnetName -eq "AzureFirewallSubnet")
                    
                    # Only count as missing NSG if it's not an exception subnet
                    if (-not $isExceptionSubnet) {
                        $subnetsMissingNSG++
                    }
                }
                
                # Count Service Endpoints
                if ($subnet.ServiceEndpoints -and $subnet.ServiceEndpoints.Trim() -ne "") {
                    $subnetsWithServiceEndpoints++
                    if ($subnet.ServiceEndpointsList -and $subnet.ServiceEndpointsList.Count -gt 0) {
                        $totalServiceEndpoints += $subnet.ServiceEndpointsList.Count
                    } else {
                        # Fallback: count comma-separated values
                        $endpointCount = ($subnet.ServiceEndpoints -split ",").Count
                        $totalServiceEndpoints += $endpointCount
                    }
                }
                
                $totalDevices += $subnet.ConnectedDevices.Count
                
                # Collect NSG risks with context
                if ($subnet.NsgRisks) {
                    foreach ($risk in $subnet.NsgRisks) {
                        switch ($risk.Severity) {
                            "Critical" { $totalCriticalRisks++ }
                            "High" { $totalHighRisks++ }
                            "Medium" { $totalMediumRisks++ }
                        }
                        
                        # Add risk with VNet and Subnet context
                        $allRisks.Add([PSCustomObject]@{
                            Severity = $risk.Severity
                            RuleName = $risk.RuleName
                            Direction = $risk.Direction
                            Port = $risk.Port
                            PortName = $risk.PortName
                            Source = $risk.Source
                            Destination = $risk.Destination
                            Protocol = $risk.Protocol
                            Priority = $risk.Priority
                            Description = $risk.Description
                            NsgName = $risk.NsgName
                            VNetName = $vnet.Name
                            SubnetName = $subnet.Name
                            SubscriptionName = $vnet.SubscriptionName
                        })
                    }
                }
            }
        }
        
        # Process Virtual WAN Hubs
        foreach ($hub in $virtualWANHubs) {
            # Count ExpressRoute connections from hubs
            if ($hub.ExpressRouteConnections) {
                foreach ($erConn in $hub.ExpressRouteConnections) {
                    $totalERConnections++
                    if ($erConn.ConnectionStatus -and $erConn.ConnectionStatus -ne "Connected") {
                        $disconnectedConnections++
                    }
                }
            }
            
            # Count S2S VPN connections from hubs
            if ($hub.VpnConnections) {
                foreach ($vpnConn in $hub.VpnConnections) {
                    $totalS2SConnections++
                    if ($vpnConn.ConnectionStatus -and $vpnConn.ConnectionStatus -ne "Connected") {
                        $disconnectedConnections++
                    }
                }
            }
            
            # Count peerings to hubs
            if ($hub.Peerings) {
                foreach ($peering in $hub.Peerings) {
                    $peeringKey = "$($peering.VNetName)|$($hub.Name)"
                    [void]$uniquePeerings.Add($peeringKey)
                }
            }
        }
        
        # Set total peerings to unique count (each bidirectional peering counted once)
        $totalPeerings = $uniquePeerings.Count
        $totalNsgs = $uniqueNsgIds.Count
        $totalRisks = $totalCriticalRisks + $totalHighRisks + $totalMediumRisks

        # Generate subscription color map for diagram
        $subscriptionColors = @(
            '#3498db', '#e74c3c', '#2ecc71', '#9b59b6', '#f39c12', 
            '#1abc9c', '#e67e22', '#34495e', '#16a085', '#c0392b'
        )
        $subColorMap = @{}
        $colorIndex = 0
        foreach ($subId in $subscriptions.Keys) {
            $subColorMap[$subId] = $subscriptionColors[$colorIndex % $subscriptionColors.Count]
            $colorIndex++
        }

        # Build HTML
        $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure Network Inventory</title>
    <script src="https://unpkg.com/vis-network/standalone/umd/vis-network.min.js"></script>
    <style type="text/css">
$(Get-ReportStylesheet -IncludeReportSpecific)

        /* Network Specific Styles - Additional Color Variables */
        :root {
            --network-blue: #3498db;
            --network-red: #e74c3c;
            --network-green: #2ecc71;
            --network-yellow: #f1c40f;
            --network-purple: #9b59b6;
            --network-teal: #16a085;
            --network-orange: #f39c12;
            --network-gray: #95a5a6;
        }
        
        .network-diagram-container {
            background: var(--bg-surface);
            border: 1px solid var(--border-color);
            border-radius: 8px;
            margin-bottom: 30px;
            overflow: hidden;
        }
        
        .diagram-header {
            padding: 15px 20px;
            background: var(--bg-secondary);
            border-bottom: 1px solid var(--border-color);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        
        .diagram-header h2 {
            margin: 0;
            font-size: 1.2em;
        }
        
        .diagram-legend {
            display: flex;
            gap: 20px;
            font-size: 0.85em;
            flex-wrap: wrap;
        }
        
        .diagram-controls {
            display: flex;
            gap: 10px;
            align-items: center;
        }
        
        .diagram-btn {
            padding: 6px 12px;
            background: var(--bg-surface);
            border: 1px solid var(--border-color);
            border-radius: 4px;
            color: var(--text-primary);
            cursor: pointer;
            font-size: 0.85em;
            transition: all 0.2s;
        }
        
        .diagram-btn:hover {
            background: var(--bg-hover);
            border-color: var(--accent-blue);
        }
        
        .legend-item {
            display: flex;
            align-items: center;
            gap: 6px;
        }
        
        .legend-dot {
            width: 12px;
            height: 12px;
            border-radius: 50%;
        }
        
        .legend-diamond {
            width: 10px;
            height: 10px;
            background: var(--network-purple);
            transform: rotate(45deg);
        }
        
        .legend-line {
            width: 30px;
            height: 2px;
            flex-shrink: 0;
        }
        
        .legend-line.peering {
            background: var(--network-green);
            height: 2px;
        }
        
        .legend-line.s2s {
            background: repeating-linear-gradient(
                to right,
                var(--network-teal) 0px,
                var(--network-teal) 4px,
                transparent 4px,
                transparent 8px
            );
            height: 3px;
        }
        
        #network-diagram {
            height: 500px;
            width: 100%;
        }
        
        /* Fix tooltip line breaks - render \n as line breaks */
        .vis-tooltip {
            white-space: pre-line !important;
            max-width: 300px;
        }
        
        /* Summary card border color classes */
        .summary-card.blue-border { border-top: 3px solid var(--network-blue); }
        .summary-card.green-border { border-top: 3px solid var(--network-green); }
        .summary-card.yellow-border { border-top: 3px solid var(--network-yellow); }
        .summary-card.purple-border { border-top: 3px solid var(--network-purple); }
        .summary-card.teal-border { border-top: 3px solid var(--network-teal); }
        .summary-card.red-border { border-top: 3px solid var(--network-red); }
        .summary-card.gray-border { border-top: 3px solid var(--network-gray); }
        .summary-card.orange-border { border-top: 3px solid var(--network-orange); }
        
        /* Summary card value color classes */
        .summary-card-value.blue { color: var(--network-blue); }
        .summary-card-value.green { color: var(--network-green); }
        .summary-card-value.red { color: var(--network-red); }
        .summary-card-value.white { color: var(--text-primary); }
        
        /* Badge color classes */
        .badge-firewall {
            background-color: rgba(231, 76, 60, 0.2);
            color: var(--network-red);
        }
        
        .badge-endpoint {
            background-color: rgba(52, 152, 219, 0.2);
            color: var(--network-blue);
        }
        
        /* Fullscreen overlay */
        .diagram-fullscreen {
            display: none;
            position: fixed;
            top: 0;
            left: 0;
            width: 100vw;
            height: 100vh;
            background: var(--bg-primary);
            z-index: 10000;
            flex-direction: column;
        }
        
        .diagram-fullscreen.active {
            display: flex;
        }
        
        .diagram-fullscreen-header {
            padding: 15px 20px;
            background: var(--bg-secondary);
            border-bottom: 1px solid var(--border-color);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        
        .diagram-fullscreen-header h2 {
            margin: 0;
            font-size: 1.2em;
        }
        
        .diagram-fullscreen-content {
            flex: 1;
            overflow: hidden;
            position: relative;
        }
        
        #network-diagram-fullscreen {
            width: 100%;
            height: 100%;
        }
        
        .diagram-fullscreen-close {
            padding: 8px 16px;
            background: var(--bg-surface);
            border: 1px solid var(--border-color);
            border-radius: 4px;
            color: var(--text-primary);
            cursor: pointer;
            font-size: 0.9em;
            transition: all 0.2s;
        }
        
        .diagram-fullscreen-close:hover {
            background: var(--bg-hover);
            border-color: var(--accent-blue);
        }
        
        .topology-tree {
            margin-top: 20px;
        }
        
        .subscription-section {
            margin-bottom: 25px;
        }
        
        .subscription-header {
            padding: 12px 20px;
            background: var(--bg-secondary);
            border: 1px solid var(--border-color);
            border-radius: 8px 8px 0 0;
            display: flex;
            align-items: center;
            gap: 12px;
            cursor: pointer;
        }
        
        .subscription-header:hover {
            background: var(--bg-hover);
        }
        
        .subscription-color-dot {
            width: 14px;
            height: 14px;
            border-radius: 50%;
            flex-shrink: 0;
        }
        
        .subscription-title {
            font-weight: 600;
            font-size: 1.1em;
            flex: 1;
        }
        
        .subscription-stats {
            font-size: 0.85em;
            color: var(--text-secondary);
        }
        
        .subscription-content {
            border: 1px solid var(--border-color);
            border-top: none;
            border-radius: 0 0 8px 8px;
            padding: 15px;
        }
        
        .vnet-box {
            background-color: var(--bg-surface);
            border: 1px solid var(--border-color);
            border-radius: 6px;
            margin-bottom: 15px;
            overflow: hidden;
        }
        
        .vnet-header {
            padding: 15px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            background-color: rgba(52, 152, 219, 0.1);
            border-bottom: 1px solid var(--border-color);
            cursor: pointer;
        }
        
        .vnet-title {
            font-size: 1.1em;
            font-weight: 600;
            color: var(--text-primary);
            display: flex;
            align-items: center;
            gap: 10px;
        }
        
        .vnet-meta {
            font-size: 0.9em;
            color: var(--text-secondary);
            display: flex;
            align-items: center;
            gap: 15px;
        }
        
        .vnet-content {
            padding: 15px;
            display: none;
        }
        
        .subnet-box {
            margin-left: 20px;
            margin-bottom: 10px;
            border-left: 2px solid var(--border-color);
            padding-left: 15px;
        }
        
        .subnet-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding: 8px 12px;
            background-color: var(--bg-secondary);
            border-radius: 4px;
            margin-bottom: 5px;
            cursor: pointer;
        }

        .subnet-title {
            font-weight: 600;
            color: var(--text-primary);
        }

        .subnet-content {
            display: none;
            padding: 10px;
        }
        
        .device-table {
            width: 100%;
            border-collapse: collapse;
            font-size: 0.9em;
            margin-top: 5px;
        }
        
        .device-table th, .device-table td {
            text-align: left;
            padding: 8px;
            border-bottom: 1px solid var(--border-color);
        }
        
        .device-table th {
            color: var(--text-secondary);
            font-weight: 600;
        }

        .badge-nsg {
            background-color: rgba(46, 204, 113, 0.2);
            color: var(--network-green);
            padding: 2px 8px;
            border-radius: 4px;
            font-size: 0.8em;
        }

        .badge-gw {
            background-color: rgba(155, 89, 182, 0.2);
            color: var(--network-purple);
            padding: 2px 6px;
            border-radius: 4px;
            font-size: 0.8em;
        }

        .peering-section {
            margin-top: 15px;
            padding: 10px;
            background-color: rgba(0, 0, 0, 0.2);
            border-radius: 4px;
        }

        .expand-icon {
            display: inline-block;
            width: 0;
            height: 0;
            border-top: 5px solid transparent;
            border-bottom: 5px solid transparent;
            border-left: 6px solid var(--text-secondary);
            margin-right: 8px;
            transition: transform 0.2s;
        }

        .expanded .expand-icon {
            transform: rotate(90deg);
        }
        
        /* Risk Badges */
        .risk-badge {
            padding: 2px 8px;
            border-radius: 4px;
            font-size: 0.75em;
            font-weight: 600;
            margin-left: 8px;
        }
        
        .risk-badge.critical {
            background-color: rgba(231, 76, 60, 0.2);
            color: var(--network-red);
        }
        
        .risk-badge.high {
            background-color: rgba(230, 126, 34, 0.2);
            color: #e67e22;
        }
        
        .risk-badge.medium {
            background-color: rgba(241, 196, 15, 0.2);
            color: var(--network-yellow);
        }
        
        .no-nsg-badge {
            background-color: rgba(231, 76, 60, 0.15);
            color: var(--network-red);
            padding: 2px 8px;
            border-radius: 4px;
            font-size: 0.8em;
        }
        
        /* Security Risks Section */
        .security-risks-section {
            margin-top: 10px;
            padding: 10px;
            background-color: rgba(231, 76, 60, 0.05);
            border: 1px solid rgba(231, 76, 60, 0.2);
            border-radius: 4px;
        }
        
        .security-risks-header {
            font-weight: 600;
            color: var(--network-red);
            margin-bottom: 8px;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        
        .risk-table {
            width: 100%;
            border-collapse: collapse;
            font-size: 0.85em;
        }
        
        .risk-table th {
            text-align: left;
            padding: 6px 8px;
            color: var(--text-secondary);
            font-weight: 600;
            border-bottom: 1px solid var(--border-color);
        }
        
        .risk-table td {
            padding: 6px 8px;
            border-bottom: 1px solid var(--border-color);
        }
        
        .risk-row.critical td { background-color: rgba(231, 76, 60, 0.05); }
        .risk-row.high td { background-color: rgba(230, 126, 34, 0.05); }
        .risk-row.medium td { background-color: rgba(241, 196, 15, 0.05); }
        
        /* Expandable Risk Summary */
        .risk-summary-section {
            background: rgba(231, 76, 60, 0.1);
            border: 1px solid rgba(231, 76, 60, 0.3);
            border-radius: 8px;
            margin-bottom: 20px;
            overflow: hidden;
        }
        
        .risk-summary-header {
            padding: 15px 20px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            cursor: pointer;
            transition: background 0.2s;
        }
        
        .risk-summary-header:hover {
            background: rgba(231, 76, 60, 0.15);
        }
        
        .risk-summary-title {
            display: flex;
            align-items: center;
            gap: 12px;
            font-weight: 600;
            color: var(--network-red);
        }
        
        .risk-summary-badges {
            display: flex;
            gap: 10px;
            flex-wrap: wrap;
        }
        
        .risk-summary-content {
            display: none;
            padding: 0 20px 20px 20px;
        }
        
        .risk-summary-section.expanded .risk-summary-content {
            display: block;
        }
        
        .risk-summary-table {
            width: 100%;
            border-collapse: collapse;
            font-size: 0.9em;
            margin-top: 15px;
        }
        
        .risk-summary-table th {
            text-align: left;
            padding: 10px 12px;
            background: var(--bg-secondary);
            color: var(--text-secondary);
            font-weight: 600;
            border-bottom: 2px solid var(--border-color);
            position: sticky;
            top: 0;
        }
        
        .risk-summary-table td {
            padding: 10px 12px;
            border-bottom: 1px solid var(--border-color);
        }
        
        .risk-summary-table tr:hover td {
            background: var(--bg-hover);
        }
        
        .risk-summary-table .risk-row.critical td { background-color: rgba(231, 76, 60, 0.08); }
        .risk-summary-table .risk-row.high td { background-color: rgba(230, 126, 34, 0.08); }
        .risk-summary-table .risk-row.medium td { background-color: rgba(241, 196, 15, 0.08); }

    </style>
</head>
<body>
$(Get-ReportNavigation -ActivePage "Network")
    
    <div class="container">
        <div class="page-header">
            <h1>Network Inventory</h1>
            <div class="metadata">
                <p><strong>Tenant:</strong> $TenantId</p>
                <p><strong>Scanned:</strong> $timestamp</p>
                <p><strong>Subscriptions:</strong> $subscriptionCount</p>
                <p><strong>Resources:</strong> $totalVnets</p>
                <p><strong>Total Findings:</strong> $totalVnets</p>
            </div>
        </div>
        
        <div class="summary-grid">
            <div class="summary-card blue-border">
                <div class="summary-card-label">VNets</div>
                <div class="summary-card-value">$($totalVnets)</div>
            </div>
            <div class="summary-card green-border">
                <div class="summary-card-label">Subnets</div>
                <div class="summary-card-value">$totalSubnets</div>
            </div>
            <div class="summary-card yellow-border">
                <div class="summary-card-label">NSGs</div>
                <div class="summary-card-value">$totalNsgs</div>
            </div>
            <div class="summary-card purple-border">
                <div class="summary-card-label">Gateways</div>
                <div class="summary-card-value">$totalGateways</div>
            </div>
            <div class="summary-card teal-border">
                <div class="summary-card-label">Peerings</div>
                <div class="summary-card-value">$totalPeerings</div>
            </div>
            <div class="summary-card gray-border">
                <div class="summary-card-label">Devices</div>
                <div class="summary-card-value">$totalDevices</div>
            </div>
            <div class="summary-card red-border">
                <div class="summary-card-label">Security Risks</div>
                <div class="summary-card-value $(if ($totalRisks -gt 0) { 'red' } else { 'white' })">$totalRisks</div>
            </div>
            $(if ($subnetsWithServiceEndpoints -gt 0) {
                "<div class='summary-card blue-border'><div class='summary-card-label'>Subnets with Service Endpoints</div><div class='summary-card-value blue'>$subnetsWithServiceEndpoints</div></div>"
            })
            $(if ($totalVirtualWANHubs -gt 0) {
                "<div class='summary-card orange-border'><div class='summary-card-label'>Virtual WAN Hubs</div><div class='summary-card-value' style='color: var(--network-orange);'>$totalVirtualWANHubs</div></div>"
            })
            $(if ($totalAzureFirewalls -gt 0) {
                "<div class='summary-card red-border'><div class='summary-card-label'>Azure Firewalls</div><div class='summary-card-value red'>$totalAzureFirewalls</div></div>"
            })
        </div>
"@

        # Add expandable risk summary if there are risks
        if ($totalRisks -gt 0) {
            # Sort risks by severity, then by subscription for better grouping
            $severityOrder = @{ "Critical" = 1; "High" = 2; "Medium" = 3 }
            $sortedAllRisks = $allRisks | Sort-Object { $severityOrder[$_.Severity] }, SubscriptionName, VNetName, SubnetName, Priority
            
            $html += @"
        <div class="risk-summary-section" id="risk-summary">
            <div class="risk-summary-header" onclick="toggleRiskSummary()">
                <div class="risk-summary-title">
                    <span class="expand-icon" id="icon-risk-summary" style="transform: rotate(0deg);"></span>
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                        <path d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/>
                    </svg>
                    <span>NSG Security Risks Found: $totalRisks</span>
                </div>
                <div class="risk-summary-badges">
                    $(if ($totalCriticalRisks -gt 0) { "<span class='risk-badge critical'>$totalCriticalRisks Critical</span>" })
                    $(if ($totalHighRisks -gt 0) { "<span class='risk-badge high'>$totalHighRisks High</span>" })
                    $(if ($totalMediumRisks -gt 0) { "<span class='risk-badge medium'>$totalMediumRisks Medium</span>" })
                </div>
            </div>
            <div class="risk-summary-content">
                <table class="risk-summary-table">
                    <thead>
                        <tr>
                            <th>Severity</th>
                            <th>Subscription</th>
                            <th>NSG</th>
                            <th>VNet</th>
                            <th>Subnet</th>
                            <th>Rule</th>
                            <th>Port</th>
                            <th>Source</th>
                            <th>Destination</th>
                            <th>Description</th>
                        </tr>
                    </thead>
                    <tbody>
"@
            foreach ($risk in $sortedAllRisks) {
                $severityLower = $risk.Severity.ToLower()
                # Cache HTML-encoded values for risk properties
                $riskSeverityHtml = Encode-Html $risk.Severity
                $riskNsgNameHtml = Encode-Html $risk.NsgName
                $riskVNetNameHtml = Encode-Html $risk.VNetName
                $riskSubnetNameHtml = Encode-Html $risk.SubnetName
                $riskRuleNameHtml = Encode-Html $risk.RuleName
                $riskPortHtml = Encode-Html $risk.Port
                $riskPortNameHtml = Encode-Html $risk.PortName
                $riskSourceHtml = Encode-Html $risk.Source
                $riskDescriptionHtml = Encode-Html $risk.Description
                $destination = if ($risk.Destination) { Encode-Html $risk.Destination } else { "<span style='color:var(--text-muted);'>Any</span>" }
                $subscriptionName = if ($risk.SubscriptionName) { Encode-Html $risk.SubscriptionName } else { "<span style='color:var(--text-muted);'>Unknown</span>" }
                $html += @"
                        <tr class="risk-row $severityLower">
                            <td><span class="risk-badge $severityLower">$riskSeverityHtml</span></td>
                            <td>$subscriptionName</td>
                            <td>$riskNsgNameHtml</td>
                            <td>$riskVNetNameHtml</td>
                            <td>$riskSubnetNameHtml</td>
                            <td>$riskRuleNameHtml</td>
                            <td>$riskPortHtml ($riskPortNameHtml)</td>
                            <td>$riskSourceHtml</td>
                            <td>$destination</td>
                            <td>$riskDescriptionHtml</td>
                        </tr>
"@
            }
            $html += @"
                    </tbody>
                </table>
            </div>
        </div>
"@
        }

        # Virtual WAN Hubs Section
        if ($virtualWANHubs -and $virtualWANHubs.Count -gt 0) {
            $html += @"
        <h2 style="margin-top: 2rem; margin-bottom: 1rem;">Virtual WAN Hubs</h2>
"@
            foreach ($hub in ($virtualWANHubs | Sort-Object SubscriptionName, Name)) {
                $hubId = "hub-" + [Guid]::NewGuid().ToString()
                $hubSearchText = "$($hub.Name) $($hub.Location) $($hub.AddressPrefix) $($hub.SubscriptionName)".ToLower()
                
                $html += @"
        <div class="subscription-box vwan-hub-box" 
            data-subscription="$(Encode-Html $hub.SubscriptionName)"
            data-searchable="$hubSearchText">
            <div class="subscription-header vwan-hub-header collapsed" data-hub-id="$hubId" style="cursor: pointer;">
                <span class="expand-icon"></span>
                <h3>$(Encode-Html $hub.Name)</h3>
                <span class="header-severity-summary">
                    $(if ($hub.ExpressRouteConnections.Count -gt 0) { "<span class='badge'>$($hub.ExpressRouteConnections.Count) ER</span>" })
                    $(if ($hub.VpnConnections.Count -gt 0) { "<span class='badge'>$($hub.VpnConnections.Count) S2S</span>" })
                    $(if ($hub.Peerings.Count -gt 0) { "<span class='badge'>$($hub.Peerings.Count) Peerings</span>" })
                    $(if ($hub.Firewalls -and $hub.Firewalls.Count -gt 0) { "<span class='badge badge-firewall'>$($hub.Firewalls.Count) Firewall$(if ($hub.Firewalls.Count -ne 1) { 's' })</span>" })
                </span>
            </div>
            <div class="subscription-content vwan-hub-content" id="$hubId" style="display: none;">
                <div class="vnet-meta-info">
                    <p><strong>Location:</strong> $(Encode-Html $hub.Location)</p>
                    <p><strong>Address Prefix:</strong> $(Encode-Html $hub.AddressPrefix)</p>
                    <p><strong>Routing Preference:</strong> $(Encode-Html $hub.HubRoutingPreference)</p>
                </div>
"@
                
                # ExpressRoute Connections
                if ($hub.ExpressRouteConnections -and $hub.ExpressRouteConnections.Count -gt 0) {
                    $html += @"
                <div class="peering-section">
                    <h4 style="margin:5px 0;">ExpressRoute Connections</h4>
                    <table class="device-table">
                        <thead>
                            <tr>
                                <th>Connection Name</th>
                                <th>Status</th>
                                <th>Circuit Name</th>
                                <th>Service Provider</th>
                                <th>Peering Location</th>
                                <th>Bandwidth</th>
                                <th>SKU</th>
                                <th>Peer ASN</th>
                            </tr>
                        </thead>
                        <tbody>
"@
                    foreach ($erConn in $hub.ExpressRouteConnections) {
                        $statusColor = if ($erConn.ConnectionStatus -eq "Connected") { "#2ecc71" } else { "#e74c3c" }
                        # Get circuit name from multiple possible sources
                        # Priority: 1) Circuit object Name, 2) ExpressRouteCircuitName (if not Unknown), 3) Extract from CircuitId, 4) Unknown
                        $circuit = $erConn.ExpressRouteCircuit
                        $circuitName = if ($circuit -and $circuit.Name) {
                            # Best source: actual circuit object name from API
                            $circuit.Name
                        } elseif ($erConn.ExpressRouteCircuitName -and $erConn.ExpressRouteCircuitName -ne "Unknown") { 
                            $erConn.ExpressRouteCircuitName 
                        } elseif ($erConn.ExpressRouteCircuitId) {
                            # Extract name from circuit ID as fallback
                            ($erConn.ExpressRouteCircuitId -split '/')[-1]
                        } else { 
                            "Unknown" 
                        }
                        $serviceProvider = if ($circuit -and $circuit.ServiceProviderName) { $circuit.ServiceProviderName } else { "N/A" }
                        $peeringLocation = if ($circuit -and $circuit.PeeringLocation) { $circuit.PeeringLocation } else { "N/A" }
                        $bandwidth = if ($circuit -and $circuit.BandwidthInMbps) { "$($circuit.BandwidthInMbps) Mbps" } else { "N/A" }
                        $sku = if ($circuit -and $circuit.SkuName) { "$($circuit.SkuTier) - $($circuit.SkuName)" } else { "N/A" }
                        $html += @"
                            <tr>
                                <td>$(Encode-Html $erConn.Name)</td>
                                <td style="color: $statusColor;">$(Encode-Html $erConn.ConnectionStatus)</td>
                                <td>$(Encode-Html $circuitName)</td>
                                <td>$(Encode-Html $serviceProvider)</td>
                                <td>$(Encode-Html $peeringLocation)</td>
                                <td>$(Encode-Html $bandwidth)</td>
                                <td>$(Encode-Html $sku)</td>
                                <td>$(if ($erConn.PeerASN) { $erConn.PeerASN } else { "N/A" })</td>
                            </tr>
"@
                    }
                    $html += @"
                        </tbody>
                    </table>
                </div>
"@
                }
                
                # S2S VPN Connections
                if ($hub.VpnConnections -and $hub.VpnConnections.Count -gt 0) {
                    $html += @"
                <div class="peering-section">
                    <h4 style="margin:5px 0;">S2S VPN Connections</h4>
                    <table class="device-table">
                        <thead>
                            <tr>
                                <th>Connection Name</th>
                                <th>Status</th>
                                <th>Remote Site</th>
                                <th>Address Space</th>
                            </tr>
                        </thead>
                        <tbody>
"@
                    foreach ($vpnConn in $hub.VpnConnections) {
                        $statusColor = if ($vpnConn.ConnectionStatus -eq "Connected") { "#2ecc71" } else { "#e74c3c" }
                        $html += @"
                            <tr>
                                <td>$(Encode-Html $vpnConn.Name)</td>
                                <td style="color: $statusColor;">$(Encode-Html $vpnConn.ConnectionStatus)</td>
                                <td>$(Encode-Html $vpnConn.RemoteSiteName)</td>
                                <td>$(Encode-Html $vpnConn.RemoteSiteAddressSpace)</td>
                            </tr>
"@
                    }
                    $html += @"
                        </tbody>
                    </table>
                </div>
"@
                }
                
                # Azure Firewalls (Virtual WAN-integrated)
                if ($hub.Firewalls -and $hub.Firewalls.Count -gt 0) {
                    $html += @"
                <div class="peering-section">
                    <h4 style="margin:5px 0;">Azure Firewalls</h4>
                    <table class="device-table">
                        <thead>
                            <tr>
                                <th>Firewall Name</th>
                                <th>SKU</th>
                                <th>Threat Intel Mode</th>
                                <th>Public IPs</th>
                            </tr>
                        </thead>
                        <tbody>
"@
                    foreach ($fw in $hub.Firewalls) {
                        $threatIntelColor = if ($fw.ThreatIntelMode -in @("Alert", "Deny")) { "#2ecc71" } else { "#e74c3c" }
                        $publicIPsString = if ($fw.PublicIPs -and $fw.PublicIPs.Count -gt 0) { ($fw.PublicIPs | ForEach-Object { Encode-Html $_ }) -join ", " } else { "N/A" }
                        $html += @"
                            <tr>
                                <td>$(Encode-Html $fw.Name)</td>
                                <td>$(Encode-Html $fw.SkuTier)</td>
                                <td style="color: $threatIntelColor;">$(Encode-Html $fw.ThreatIntelMode)</td>
                                <td>$publicIPsString</td>
                            </tr>
"@
                    }
                    $html += @"
                        </tbody>
                    </table>
                </div>
"@
                }
                
                # VNets Peered to Hub
                if ($hub.Peerings -and $hub.Peerings.Count -gt 0) {
                    $html += @"
                <div class="peering-section">
                    <h4 style="margin:5px 0;">VNets Peered to Hub</h4>
                    <table class="device-table">
                        <thead>
                            <tr>
                                <th>VNet Name</th>
                                <th>State</th>
                                <th>Allow Forwarded Traffic</th>
                                        <th>Gateway Use</th>
                            </tr>
                        </thead>
                        <tbody>
"@
                    foreach ($peering in $hub.Peerings) {
                        $stateColor = if ($peering.State -eq "Connected") { "#2ecc71" } else { "#e74c3c" }
                        
                        # Build gateway direction indicator for Virtual WAN Hub peerings
                        # UseRemoteGateways = true means VNet uses the Hub's gateway
                        $gatewayDirection = if ($peering.UseRemoteGateways) {
                            "<span style='color:white;' title='VNet uses Hub Gateway'>Uses Hub Gateway</span>"
                        } else {
                            "None"
                        }
                        
                        $html += @"
                            <tr>
                                <td>$(Encode-Html $peering.VNetName)</td>
                                <td style="color: $stateColor;">$(Encode-Html $peering.State)</td>
                                <td>$($peering.AllowForwardedTraffic)</td>
                                <td style="text-align:center;">$gatewayDirection</td>
                            </tr>
"@
                    }
                    $html += @"
                        </tbody>
                    </table>
                </div>
"@
                }
                
                $html += @"
            </div>
        </div>
"@
            }
        }

        # Network Diagram Section
        $html += @"

        <div class="network-diagram-container">
            <div class="diagram-header">
                <h2>Network Topology</h2>
                <div style="display: flex; align-items: center; gap: 20px;">
                    <div class="diagram-legend">
                        <div class="legend-item" id="legend-vnet"><div class="legend-dot" style="background: var(--network-blue);"></div> VNet - color by subscription</div>
                        <div class="legend-item" id="legend-gateway"><div class="legend-diamond"></div> Gateway</div>
                        <div class="legend-item" id="legend-hub"><div class="legend-hexagon" style="background: var(--network-orange); width: 12px; height: 12px; display: inline-block; margin-right: 6px;"></div> Virtual WAN Hub</div>
                        <div class="legend-item" id="legend-firewall"><div class="legend-box" style="background: var(--network-red); width: 12px; height: 12px; display: inline-block; margin-right: 6px;"></div> Azure Firewall</div>
                        <div class="legend-item" id="legend-onprem"><div class="legend-dot" style="background: #34495e; border-radius: 0;"></div> On-Premises</div>
                        <div class="legend-item" id="legend-peering"><div class="legend-line peering"></div> Peering</div>
                        <div class="legend-item" id="legend-s2s"><div class="legend-line s2s"></div> S2S Tunnel / ExpressRoute</div>
                    </div>
                    <div class="diagram-controls">
                        <button class="diagram-btn" id="resetLayout">Reset Layout</button>
                        <button class="diagram-btn" id="togglePhysics">Disable Physics</button>
                        <button class="diagram-btn" id="toggleLayout">Hierarchical Layout</button>
                        <button class="diagram-btn" id="openFullscreen">Fullscreen</button>
                    </div>
                </div>
            </div>
            <div id="network-diagram"></div>
        </div>
        
        <!-- Fullscreen diagram overlay -->
        <div class="diagram-fullscreen" id="diagram-fullscreen">
            <div class="diagram-fullscreen-header">
                <h2>Network Topology - Fullscreen</h2>
                <div style="display: flex; align-items: center; gap: 15px;">
                    <div class="diagram-legend">
                        <div class="legend-item" id="legend-vnet-fullscreen"><div class="legend-dot" style="background: var(--network-blue);"></div> VNet - color by subscription</div>
                        <div class="legend-item" id="legend-gateway-fullscreen"><div class="legend-diamond"></div> Gateway</div>
                        <div class="legend-item" id="legend-hub-fullscreen"><div class="legend-hexagon" style="background: var(--network-orange); width: 12px; height: 12px; display: inline-block; margin-right: 6px;"></div> Virtual WAN Hub</div>
                        <div class="legend-item" id="legend-firewall-fullscreen"><div class="legend-box" style="background: var(--network-red); width: 12px; height: 12px; display: inline-block; margin-right: 6px;"></div> Azure Firewall</div>
                        <div class="legend-item" id="legend-onprem-fullscreen"><div class="legend-dot" style="background: #34495e; border-radius: 0;"></div> On-Premises</div>
                        <div class="legend-item" id="legend-peering-fullscreen"><div class="legend-line peering"></div> Peering</div>
                        <div class="legend-item" id="legend-s2s-fullscreen"><div class="legend-line s2s"></div> S2S Tunnel / ExpressRoute</div>
                    </div>
                    <div class="diagram-controls">
                        <button class="diagram-btn" id="resetLayoutFullscreen">Reset Layout</button>
                        <button class="diagram-btn" id="togglePhysicsFullscreen">Disable Physics</button>
                        <button class="diagram-btn" id="toggleLayoutFullscreen">Hierarchical Layout</button>
                        <button class="diagram-fullscreen-close" id="closeFullscreen">Close Fullscreen</button>
                    </div>
                </div>
            </div>
            <div class="diagram-fullscreen-content">
                <div id="network-diagram-fullscreen"></div>
            </div>
        </div>

        <div class="filter-controls">
            <div class="filter-group">
                <label for="subscriptionFilter">Subscription:</label>
                <select id="subscriptionFilter" class="filter-select">
                    <option value="">All Subscriptions</option>
"@
        foreach ($subId in $subscriptions.Keys) {
            $subName = $subscriptions[$subId].Name
            $encodedSubName = Encode-Html $subName
            $html += @"
                    <option value="$subId">$encodedSubName</option>
"@
        }
        $html += @"
                </select>
            </div>
            <div class="filter-group">
                <label for="searchFilter">Search:</label>
                <input type="text" id="searchFilter" class="filter-input" placeholder="Search VNets, Subnets, IPs...">
            </div>
            <div class="filter-group">
                <button id="expandAll" class="btn-clear">Expand All</button>
                <button id="collapseAll" class="btn-clear">Collapse All</button>
            </div>
        </div>

        <div class="topology-tree">
"@

        # Pre-compute risk counts per VNet and subscription to avoid duplicate loops
        $vnetRiskCounts = @{}
        $subscriptionRiskCounts = @{}
        
        foreach ($vnet in $vnets) {
            $vnetCritical = 0
            $vnetHigh = 0
            $vnetMedium = 0
            $deviceCount = 0
            
            foreach ($subnet in $vnet.Subnets) {
                $deviceCount += $subnet.ConnectedDevices.Count
                if ($subnet.NsgRisks) {
                    foreach ($risk in $subnet.NsgRisks) {
                        switch ($risk.Severity) {
                            "Critical" { $vnetCritical++ }
                            "High" { $vnetHigh++ }
                            "Medium" { $vnetMedium++ }
                        }
                    }
                }
            }
            
            $vnetRiskCounts[$vnet.Name] = @{
                Critical = $vnetCritical
                High = $vnetHigh
                Medium = $vnetMedium
                DeviceCount = $deviceCount
            }
            
            # Accumulate subscription totals
            $subId = $vnet.SubscriptionId
            if (-not $subscriptionRiskCounts.ContainsKey($subId)) {
                $subscriptionRiskCounts[$subId] = @{ Critical = 0; High = 0; Medium = 0; DeviceCount = 0 }
            }
            $subscriptionRiskCounts[$subId].Critical += $vnetCritical
            $subscriptionRiskCounts[$subId].High += $vnetHigh
            $subscriptionRiskCounts[$subId].Medium += $vnetMedium
            $subscriptionRiskCounts[$subId].DeviceCount += $deviceCount
        }

        # Generate VNets grouped by subscription
        foreach ($subId in $subscriptions.Keys) {
            $sub = $subscriptions[$subId]
            $subColor = $subColorMap[$subId]
            $subVnetCount = $sub.VNets.Count
            
            # Use pre-computed risk counts
            $subRiskData = $subscriptionRiskCounts[$subId]
            $subDeviceCount = if ($subRiskData) { $subRiskData.DeviceCount } else { 0 }
            $subCriticalRisks = if ($subRiskData) { $subRiskData.Critical } else { 0 }
            $subHighRisks = if ($subRiskData) { $subRiskData.High } else { 0 }
            $subMediumRisks = if ($subRiskData) { $subRiskData.Medium } else { 0 }
            
            # Build risk badges HTML for subscription header
            $subRiskBadgesHtml = ""
            if ($subCriticalRisks -gt 0 -or $subHighRisks -gt 0 -or $subMediumRisks -gt 0) {
                if ($subCriticalRisks -gt 0) { 
                    $subRiskBadgesHtml += @"
<span class='risk-badge critical'>$subCriticalRisks</span>
"@
                }
                if ($subHighRisks -gt 0) { 
                    $subRiskBadgesHtml += @"
<span class='risk-badge high'>$subHighRisks</span>
"@
                }
                if ($subMediumRisks -gt 0) { 
                    $subRiskBadgesHtml += @"
<span class='risk-badge medium'>$subMediumRisks</span>
"@
                }
            }
            
            $html += @"
            <div class="subscription-section" data-subscription-id="$subId">
                <div class="subscription-header" onclick="toggleSubscription('sub-$subId')">
                    <span class="expand-icon" id="icon-sub-$subId"></span>
                    <div class="subscription-color-dot" style="background-color: $subColor;"></div>
                    <span class="subscription-title">$(Encode-Html $sub.Name)</span>
                    <span class="subscription-stats">$subRiskBadgesHtml $subVnetCount VNets &#124; $subDeviceCount Devices</span>
                </div>
                <div class="subscription-content" id="sub-$subId" style="display: none;">
"@

            foreach ($vnet in $sub.VNets) {
                $vnetId = "vnet-" + [Guid]::NewGuid().ToString()
                $vnetSearchText = "$($vnet.Name) $($vnet.AddressSpace) $($vnet.Location) $($vnet.SubscriptionName)".ToLower()
                
                # Cache HTML-encoded values to avoid repeated Encode-Html calls
                $vnetNameHtml = Encode-Html $vnet.Name
                $vnetAddressHtml = Encode-Html $vnet.AddressSpace
                $vnetLocationHtml = Encode-Html $vnet.Location
                
                # Use pre-computed risk counts for this VNet
                $vnetRiskData = $vnetRiskCounts[$vnet.Name]
                $vnetCritical = if ($vnetRiskData) { $vnetRiskData.Critical } else { 0 }
                $vnetHigh = if ($vnetRiskData) { $vnetRiskData.High } else { 0 }
                $vnetMedium = if ($vnetRiskData) { $vnetRiskData.Medium } else { 0 }

                $html += @"
                <div class="vnet-box" data-searchable="$vnetSearchText" data-vnet-name="$vnetNameHtml">
                    <div class="vnet-header" onclick="toggleVNet('$vnetId')">
                        <div class="vnet-title">
                            <span class="expand-icon" id="icon-$vnetId"></span>
                            $vnetNameHtml
                            <span style="font-weight:normal; color:var(--text-secondary); font-size:0.9em; margin-left:10px;">$vnetAddressHtml</span>
                        </div>
                        <div class="vnet-meta">
                            <span>$vnetLocationHtml</span>
                            <span>Subnets: $($vnet.Subnets.Count)</span>
                            <span>Peerings: $($vnet.Peerings.Count)</span>
"@
                if ($vnetCritical -gt 0 -or $vnetHigh -gt 0 -or $vnetMedium -gt 0) {
                    $html += @"
                            <span>
"@
                    if ($vnetCritical -gt 0) { 
                        $html += @"
<span class='risk-badge critical'>$vnetCritical</span>
"@
                    }
                    if ($vnetHigh -gt 0) { 
                        $html += @"
<span class='risk-badge high'>$vnetHigh</span>
"@
                    }
                    if ($vnetMedium -gt 0) { 
                        $html += @"
<span class='risk-badge medium'>$vnetMedium</span>
"@
                    }
                    $html += @"
</span>
"@
                }
                $html += @"

                        </div>
                    </div>
                    <div class="vnet-content" id="$vnetId">
"@
                # Gateways
                if ($vnet.Gateways.Count -gt 0) {
                    $html += @"
                        <div style="margin-bottom:15px;">
                            <h4 style="margin:5px 0;">Gateways</h4>
"@
                    foreach ($gw in $vnet.Gateways) {
                        $html += @"
                            <div style="padding:8px 12px; background:rgba(155, 89, 182, 0.1); border-radius:4px; margin-bottom:5px;">
                                <strong>$(Encode-Html $gw.Name)</strong> <span class="badge-gw">$(Encode-Html $gw.Type)</span>
                                <span style="margin-left:10px; font-size:0.9em; color:var(--text-secondary);">SKU: $(Encode-Html $gw.Sku) | VPN: $(Encode-Html $gw.VpnType)</span>
"@

                        # Show P2S (Point-to-Site) client configuration if present
                        $p2sAddressPools = $null
                        if ($gw.P2SAddressPools) {
                            $p2sAddressPools = ($gw.P2SAddressPools | ForEach-Object { Encode-Html $_ }) -join ', '
                        } elseif ($gw.P2SAddressPool) {
                            $p2sAddressPools = Encode-Html $gw.P2SAddressPool
                        } elseif ($gw.VpnClientAddressPools) {
                            $p2sAddressPools = ($gw.VpnClientAddressPools | ForEach-Object { Encode-Html $_ }) -join ', '
                        } elseif ($gw.VpnClientAddressPool) {
                            $p2sAddressPools = Encode-Html $gw.VpnClientAddressPool
                        }

                        $p2sTunnelType = $null
                        if ($gw.P2STunnelType) {
                            $p2sTunnelType = Encode-Html $gw.P2STunnelType
                        } elseif ($gw.VpnClientProtocols) {
                            $p2sTunnelType = ($gw.VpnClientProtocols | ForEach-Object { Encode-Html $_ }) -join ', '
                        }

                        $p2sAuthType = $null
                        if ($gw.P2SAuthType) {
                            $p2sAuthType = Encode-Html $gw.P2SAuthType
                        } elseif ($gw.P2SAuthenticationType) {
                            $p2sAuthType = Encode-Html $gw.P2SAuthenticationType
                        } elseif ($gw.VpnClientAuthenticationTypes) {
                            $p2sAuthType = ($gw.VpnClientAuthenticationTypes | ForEach-Object { Encode-Html $_ }) -join ', '
                        } elseif ($gw.VpnClientAuthenticationType) {
                            $p2sAuthType = Encode-Html $gw.VpnClientAuthenticationType
                        }

                        if ($p2sAddressPools -or $p2sTunnelType -or $p2sAuthType) {
                            $html += @"
                                <div style="margin-top:8px; padding-top:8px; border-top:1px solid rgba(155, 89, 182, 0.3);">
                                    <div style="font-size:0.85em; color:var(--text-secondary); margin-bottom:4px;"><strong>P2S Clients:</strong></div>
"@
                            if ($p2sAddressPools) {
                                $html += @"
                                    <div style="margin-left:12px; font-size:0.85em;">Address pool(s): $p2sAddressPools</div>
"@
                            }
                            if ($p2sTunnelType) {
                                $html += @"
                                    <div style="margin-left:12px; font-size:0.85em;">Tunnel type: $p2sTunnelType</div>
"@
                            }
                            if ($p2sAuthType) {
                                $html += @"
                                    <div style="margin-left:12px; font-size:0.85em;">Authentication: $p2sAuthType</div>
"@
                            }
                            $html += @"
                                </div>
"@
                        }

                        # Show S2S connections
                        if ($gw.Connections -and $gw.Connections.Count -gt 0) {
                            # Check for overlapping subnets across connections
                            $overlaps = Find-OverlappingSubnets -Connections $gw.Connections
                            
                            $html += @"
                                <div style="margin-top:8px; padding-top:8px; border-top:1px solid rgba(155, 89, 182, 0.3);">
                                    <div style="font-size:0.85em; color:var(--text-secondary); margin-bottom:4px;"><strong>S2S Connections:</strong></div>
"@
                            
                            # Show warning if overlaps detected (handle single-item array unwrapping)
                            $overlapCount = @($overlaps).Count
                            if ($overlapCount -gt 0) {
                                # Build overlap details with connection names for better context
                                $overlapDetailsParts = $overlaps | ForEach-Object {
                                    if ($_.Type -eq "Duplicate") {
                                        "$(Encode-Html $_.Subnet) in $(Encode-Html $_.Connection1) and $(Encode-Html $_.Connection2)"
                                    } else {
                                        "$(Encode-Html $_.Subnet) between $(Encode-Html $_.Connection1) and $(Encode-Html $_.Connection2)"
                                    }
                                }
                                $overlapDetailsHtml = $overlapDetailsParts -join '; '
                                $html += @"
                                    <div style="margin-left:12px; margin-bottom:6px; padding:6px; background-color:rgba(241, 196, 15, 0.15); border-left:3px solid var(--network-yellow); border-radius:3px; font-size:0.85em;">
                                        <span style="color:var(--network-yellow); font-weight:bold;">&#9888; Warning:</span> <span style="color:var(--text-secondary);">Overlapping remote subnets detected: $overlapDetailsHtml</span>
                                    </div>
"@
                            }
                            
                            foreach ($conn in $gw.Connections) {
                                $statusColor = if ($conn.ConnectionStatus -eq "Connected") { "#2ecc71" } else { "#e74c3c" }
                                $remoteType = if ($conn.RemoteNetwork -and $conn.RemoteNetwork.Type -eq "OnPremises") { "On-Premises" } else { "VNet" }
                                $connName = if ($conn.Name) { Encode-Html $conn.Name } else { "Unknown" }
                                $html += @"
                                    <div style="margin-left:12px; margin-bottom:4px; font-size:0.85em;">
                                        <span style="color: $statusColor; font-weight: bold; margin-right: 4px;">*</span> <strong>$connName</strong> &#8594; $(Encode-Html $conn.RemoteNetworkName) ($remoteType)
                                        <span style="color:var(--text-secondary); margin-left:8px;">- $(Encode-Html $conn.ConnectionStatus)</span>
"@
                                if ($conn.RemoteNetwork -and $conn.RemoteNetwork.AddressSpace) {
                                    $html += @"
 <span style='color:var(--text-muted);'>($(Encode-Html $conn.RemoteNetwork.AddressSpace))</span>
"@
                                }
                                $html += @"
                                    </div>
"@
                            }
                            $html += @"
                                </div>
"@
                        }
                        $html += @"
                            </div>
"@
                    }
                    $html += @"
                        </div>
"@
                }
                
                # Azure Firewalls
                if ($vnet.Firewalls -and $vnet.Firewalls.Count -gt 0) {
                    $html += @"
                        <div style="margin-bottom:15px;">
                            <h4 style="margin:5px 0;">Azure Firewalls</h4>
"@
                    foreach ($fw in $vnet.Firewalls) {
                        $threatIntelColor = if ($fw.ThreatIntelMode -in @("Alert", "Deny")) { "#2ecc71" } else { "#e74c3c" }
                        $html += @"
                            <div style="padding:8px 12px; background:rgba(231, 76, 60, 0.1); border-radius:4px; margin-bottom:5px;">
                                <strong>$(Encode-Html $fw.Name)</strong> <span class="badge badge-firewall">Firewall</span>
                                <div style="margin-top:6px; font-size:0.85em; color:var(--text-secondary);">
                                    <div>SKU: $(Encode-Html $fw.SkuTier) | Threat Intel: <span style="color: $threatIntelColor;">$(Encode-Html $fw.ThreatIntelMode)</span></div>
                                    $(if ($fw.PrivateIP) { "<div>Private IP: $(Encode-Html $fw.PrivateIP)</div>" })
                                    $(if ($fw.PublicIPs -and $fw.PublicIPs.Count -gt 0) { "<div>Public IPs: $(($fw.PublicIPs | ForEach-Object { Encode-Html $_ }) -join ', ')</div>" })
                                </div>
                            </div>
"@
                    }
                    $html += @"
                        </div>
"@
                }

                # Subnets
                $html += @"
                        <h4 style="margin:10px 0;">Subnets</h4>
"@
                foreach ($subnet in $vnet.Subnets) {
                    $subnetId = "subnet-" + [Guid]::NewGuid().ToString()
                    
                    # NSG badge with risk indicators
                    $nsgBadgeHtml = ""
                    if ($subnet.NsgName) {
                        $nsgBadgeHtml = @"
<span class='badge-nsg'>NSG: $(Encode-Html $subnet.NsgName)</span>
"@
                        
                        # Add risk badges if present
                        if ($subnet.NsgRisks -and $subnet.NsgRisks.Count -gt 0) {
                            $subnetCritical = @($subnet.NsgRisks | Where-Object { $_.Severity -eq "Critical" }).Count
                            $subnetHigh = @($subnet.NsgRisks | Where-Object { $_.Severity -eq "High" }).Count
                            $subnetMedium = @($subnet.NsgRisks | Where-Object { $_.Severity -eq "Medium" }).Count
                            
                            if ($subnetCritical -gt 0) { 
                                $nsgBadgeHtml += @"
<span class='risk-badge critical'>$subnetCritical</span>
"@
                            }
                            if ($subnetHigh -gt 0) { 
                                $nsgBadgeHtml += @"
<span class='risk-badge high'>$subnetHigh</span>
"@
                            }
                            if ($subnetMedium -gt 0) { 
                                $nsgBadgeHtml += @"
<span class='risk-badge medium'>$subnetMedium</span>
"@
                            }
                        }
                    } else {
                        # Check for legitimate exception subnets - show in green with note, using same CSS as NSG badges
                        $subnetName = $subnet.Name
                        if ($subnetName -eq "GatewaySubnet") {
                            $nsgBadgeHtml = @"
<span class='badge-nsg'>No NSG (GW subnet)</span>
"@
                        } elseif ($subnetName -eq "AzureBastionSubnet") {
                            $nsgBadgeHtml = @"
<span class='badge-nsg'>No NSG (Bastion subnet)</span>
"@
                        } elseif ($subnetName -eq "AzureFirewallSubnet") {
                            $nsgBadgeHtml = @"
<span class='badge-nsg'>No NSG (Firewall subnet)</span>
"@
                        } else {
                            $nsgBadgeHtml = @"
<span class='no-nsg-badge'>No NSG</span>
"@
                        }
                    }
                    
                    $html += @"
                        <div class="subnet-box">
                            <div class="subnet-header" onclick="toggleSubnet('$subnetId')">
                                <div>
                                    <span class="expand-icon" id="icon-$subnetId"></span>
                                    <span class="subnet-title">$(Encode-Html $subnet.Name)</span>
                                    <span style="margin-left:10px; color:var(--text-secondary);">$(Encode-Html $subnet.AddressPrefix)</span>
                                </div>
                                <div>
                                    $nsgBadgeHtml
                                    <span style="font-size:0.9em; margin-left:10px;">Devices: $($subnet.ConnectedDevices.Count)</span>
                                </div>
                            </div>
                            <div class="subnet-content" id="$subnetId">
"@
                    # Connected Devices
                    if ($subnet.ConnectedDevices.Count -gt 0) {
                        $html += @"
                                <table class="device-table">
                                    <thead>
                                        <tr>
                                            <th>Name</th>
                                            <th>Type</th>
                                            <th>Private IP</th>
                                            <th>Public IP</th>
                                            <th>Attached To</th>
                                        </tr>
                                    </thead>
                                    <tbody>
"@
                        foreach ($device in $subnet.ConnectedDevices) {
                            $deviceType = if ($device.DeviceType) { $device.DeviceType } else { if ($device.IsPrivateEndpoint) { "Private Endpoint" } else { "NIC/VM" } }
                            $html += @"
                                        <tr>
                                            <td>$(Encode-Html $device.Name)</td>
                                            <td>$(Encode-Html $deviceType)</td>
                                            <td>$(if ($device.PrivateIp) { Encode-Html $device.PrivateIp } else { "<span style='color:var(--text-muted);'>-</span>" })</td>
                                            <td>$(if ($device.PublicIp) { Encode-Html $device.PublicIp } else { "<span style='color:var(--text-muted);'>-</span>" })</td>
                                            <td>$(Encode-Html $device.VmName)</td>
                                        </tr>
"@
                        }
                        $html += @"
                                    </tbody>
                                </table>
"@
                    } else {
                        $html += @"
                                <div style='color:var(--text-secondary); font-style:italic; padding:5px;'>No connected devices</div>
"@
                    }
                    
                    # Route Table
                    if ($subnet.RouteTableName) {
                        $html += @"
                                <div style='margin-top:10px; font-size:0.9em;'><strong>Route Table:</strong> $(Encode-Html $subnet.RouteTableName)</div>
"@
                    }
                    
                    # Service Endpoints
                    if ($subnet.ServiceEndpoints -and $subnet.ServiceEndpoints.Trim() -ne "") {
                        $serviceEndpointsList = $subnet.ServiceEndpoints -split ", " | Where-Object { $_.Trim() -ne "" }
                        if ($serviceEndpointsList.Count -gt 0) {
                            $html += @"
                                <div style='margin-top:10px; font-size:0.9em;'>
                                    <strong>Service Endpoints:</strong>
                                    <div style='margin-left:15px; margin-top:4px;'>
"@
                            foreach ($endpoint in $serviceEndpointsList) {
                                $html += @"
                                        <span class='badge badge-endpoint' style='margin-right: 5px; margin-bottom: 3px; display: inline-block;'>$(Encode-Html $endpoint.Trim())</span>
"@
                            }
                            $html += @"
                                    </div>
                                </div>
"@
                        }
                    }
                    
                    # Security Risks Section
                    if ($subnet.NsgRisks -and $subnet.NsgRisks.Count -gt 0) {
                        $html += @"
                                <div class="security-risks-section">
                                    <div class="security-risks-header">
                                        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                                            <path d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/>
                                        </svg>
                                        Security Risks Detected
                                    </div>
                                    <table class="risk-table">
                                        <thead>
                                            <tr>
                                                <th>Severity</th>
                                                <th>Rule</th>
                                                <th>Port</th>
                                                <th>Source</th>
                                                <th>Destination</th>
                                                <th>Description</th>
                                            </tr>
                                        </thead>
                                        <tbody>
"@
                        foreach ($risk in $subnet.NsgRisks) {
                            $severityLower = $risk.Severity.ToLower()
                            # Cache HTML-encoded values for risk properties
                            $riskSeverityHtml = Encode-Html $risk.Severity
                            $riskRuleNameHtml = Encode-Html $risk.RuleName
                            $riskPortHtml = Encode-Html $risk.Port
                            $riskPortNameHtml = Encode-Html $risk.PortName
                            $riskSourceHtml = Encode-Html $risk.Source
                            $riskDescriptionHtml = Encode-Html $risk.Description
                            $destination = if ($risk.Destination) { Encode-Html $risk.Destination } else { "<span style='color:var(--text-muted);'>Any</span>" }
                            $html += @"
                                            <tr class="risk-row $severityLower">
                                                <td><span class="risk-badge $severityLower">$riskSeverityHtml</span></td>
                                                <td>$riskRuleNameHtml</td>
                                                <td>$riskPortHtml ($riskPortNameHtml)</td>
                                                <td>$riskSourceHtml</td>
                                                <td>$destination</td>
                                                <td>$riskDescriptionHtml</td>
                                            </tr>
"@
                        }
                        $html += @"
                                        </tbody>
                                    </table>
                                </div>
"@
                    }

                    $html += @"
                            </div>
                        </div>
"@
                }

                # Peerings
                if ($vnet.Peerings.Count -gt 0) {
                    $html += @"
                        <div class="peering-section">
                            <h4 style="margin:5px 0;">Peerings</h4>
                            <table class="device-table">
                                <thead>
                                    <tr>
                                        <th>Remote VNet</th>
                                        <th>Subscription</th>
                                        <th>State</th>
                                        <th>Traffic</th>
                                        <th>Gateway Use</th>
                                    </tr>
                                </thead>
                                <tbody>
"@
                    foreach ($peering in $vnet.Peerings) {
                        # Find the remote VNet or Hub to get its subscription
                        $remoteVnet = $vnets | Where-Object { $_.Name -eq $peering.RemoteVnetName } | Select-Object -First 1
                        $remoteHub = if ($peering.IsVirtualWANHub) { $virtualWANHubs | Where-Object { $_.Name -eq $peering.RemoteVnetName } | Select-Object -First 1 } else { $null }
                        $remoteSubscription = if ($remoteVnet) { $remoteVnet.SubscriptionName } elseif ($remoteHub) { $remoteHub.SubscriptionName } else { "Unknown" }
                        
                        $stateColor = if ($peering.State -eq "Connected") { "#2ecc71" } else { "#e74c3c" }
                        $remoteType = if ($peering.IsVirtualWANHub) { "Virtual WAN Hub" } else { "VNet" }
                        
                        # Build gateway direction indicators
                        $gatewayDirection = ""
                        if ($peering.UseRemoteGateways) {
                            $gatewayDirection = "Uses Remote Gateway"  # This VNet uses remote gateway
                        }
                        if ($peering.AllowGatewayTransit) {
                            if ($gatewayDirection) {
                                $gatewayDirection = "Bidirectional"  # Bidirectional gateway transit
                            } else {
                                $gatewayDirection = "Allows Remote to Use"  # Remote VNet uses this gateway
                            }
                        }
                        
                        $gatewayDisplay = if ($gatewayDirection) { 
                            "<span style='color:white;' title='Gateway Transit: $gatewayDirection'>$gatewayDirection</span>" 
                        } else { 
                            "None" 
                        }
                        
                        $html += @"
                                    <tr>
                                        <td>$(Encode-Html $peering.RemoteVnetName) <span style="color:var(--text-muted); font-size:0.85em;">($remoteType)</span></td>
                                        <td>$(Encode-Html $remoteSubscription)</td>
                                        <td style="color: $stateColor;">$(Encode-Html $peering.State)</td>
                                        <td>Fwd: $($peering.AllowForwardedTraffic)</td>
                                        <td style="text-align:center;">$gatewayDisplay</td>
                                    </tr>
"@
                    }
                    $html += @"
                                </tbody>
                            </table>
                        </div>
"@
                }

                $html += @"
                    </div>
                </div>
"@
            }

            $html += @"
                </div>
            </div>
"@
        }

        # Build vis.js network data
        $nodesJson = [System.Collections.Generic.List[string]]::new()
        $edgesJson = [System.Collections.Generic.List[string]]::new()
        $nodeIdMap = @{}  # Map VNet/Hub name to node ID
        $gwNodeIdMap = @{}  # Map Gateway ID to node ID
        $nodeCounter = 1
        $processedPeerings = [System.Collections.Generic.HashSet[string]]::new()
        $processedS2S = [System.Collections.Generic.HashSet[string]]::new()
        
        # Initialize subscription color map (reuse from earlier in script)
        if (-not $subColorMap) {
            $subColorMap = @{}
        }
        
        # Group VNets by subscription for better layout
        $vnetGroups = @{}
        foreach ($vnet in $vnets) {
            $subId = $vnet.SubscriptionId
            if (-not $vnetGroups.ContainsKey($subId)) {
                $vnetGroups[$subId] = [System.Collections.Generic.List[PSObject]]::new()
            }
            $vnetGroups[$subId].Add($vnet)
        }
        
        # Group Virtual WAN Hubs by subscription
        $hubGroups = @{}
        foreach ($hub in $virtualWANHubs) {
            $subId = $hub.SubscriptionId
            if (-not $hubGroups.ContainsKey($subId)) {
                $hubGroups[$subId] = [System.Collections.Generic.List[PSObject]]::new()
            }
            $hubGroups[$subId].Add($hub)
        }
        
        # Map for firewall nodes
        $fwNodeIdMap = @{}
        
        # Map VNet names to their levels (for edge styling)
        $vnetLevelMap = @{}
        
        # Detect hub VNet (has gateway + peerings, or most peerings)
        $hubVnetName = $null
        $maxPeerings = 0
        
        foreach ($vnet in $vnets) {
            # Skip hub representations (HV_* VNets)
            if ($vnet.Name -like "HV_*") { continue }
            
            $hasGateway = $vnet.Gateways -and $vnet.Gateways.Count -gt 0
            $peeringCount = if ($vnet.Peerings) { $vnet.Peerings.Count } else { 0 }
            
            if ($hasGateway -and $peeringCount -gt 0 -and $peeringCount -gt $maxPeerings) {
                $maxPeerings = $peeringCount
                $hubVnetName = $vnet.Name
            }
        }
        
        # Fallback: most peerings if no gateway-based hub found
        if (-not $hubVnetName) {
            foreach ($vnet in $vnets) {
                if ($vnet.Name -like "HV_*") { continue }
                $peeringCount = if ($vnet.Peerings) { $vnet.Peerings.Count } else { 0 }
                if ($peeringCount -gt $maxPeerings) {
                    $maxPeerings = $peeringCount
                    $hubVnetName = $vnet.Name
                }
            }
        }
        
        # Build map of spoke VNets (VNets peered to hub)
        $spokeVnets = @{}
        if ($hubVnetName) {
            foreach ($vnet in $vnets) {
                if ($vnet.Name -eq $hubVnetName) { continue }
                if ($vnet.Name -like "HV_*") { continue }
                if ($vnet.Peerings) {
                    foreach ($peering in $vnet.Peerings) {
                        if ($peering.RemoteVnetName -eq $hubVnetName) {
                            $spokeVnets[$vnet.Name] = $true
                            break
                        }
                    }
                }
            }
        }
        
        # Debug: Output hub detection results
        Write-Verbose "Hub Detection: hubVnetName = '$hubVnetName', spokeVnets = $($spokeVnets.Keys -join ', ')"
        
        # Create nodes grouped by subscription
        foreach ($subId in $vnetGroups.Keys) {
            # Ensure subscription color is assigned (build color map if missing)
            if (-not $subColorMap.ContainsKey($subId)) {
                $colorIndex = $subColorMap.Count
                $subColorMap[$subId] = $subscriptionColors[$colorIndex % $subscriptionColors.Count]
            }
            $subColor = $subColorMap[$subId]
            
            foreach ($vnet in $vnetGroups[$subId]) {
                # Check if this VNet is actually a Virtual WAN Hub representation (e.g., "HV_p-conhub-sec-vhub_...")
                # These are created by Azure for peering purposes but should use the hub node instead
                $isHubRepresentation = $false
                $matchingHub = $null
                if ($vnet.Name -like "HV_*") {
                    # Extract base name by removing "HV_" prefix and GUID suffix
                    $vnetBaseName = $vnet.Name -replace '^HV_', '' -replace '_[a-f0-9-]+$', ''
                    # Check if this matches any Virtual WAN Hub
                    $matchingHub = $virtualWANHubs | Where-Object { 
                        $hubBaseName = $_.Name -replace '^HV_', '' -replace '_[a-f0-9-]+$', ''
                        $_.Name -eq $vnetBaseName -or $hubBaseName -eq $vnetBaseName -or $_.Name -eq $vnet.Name
                    } | Select-Object -First 1
                    if ($matchingHub) {
                        $isHubRepresentation = $true
                    }
                }
                
                # Skip creating a node for hub representations - they'll be mapped to the hub node later
                if ($isHubRepresentation) {
                    Write-Verbose "Skipping VNet node creation for hub representation: $($vnet.Name) (maps to hub: $($matchingHub.Name))"
                    continue
                }
                
                $nodeId = $nodeCounter++
                $nodeIdMap[$vnet.Name] = $nodeId
                $deviceCount = 0
                foreach ($s in $vnet.Subnets) { $deviceCount += $s.ConnectedDevices.Count }
                
                $tooltip = "$($vnet.Name)`nSubscription: $($vnet.SubscriptionName)`nAddress: $($vnet.AddressSpace)`nLocation: $($vnet.Location)`nSubnets: $($vnet.Subnets.Count)`nDevices: $deviceCount"
                # Escape tooltip and label for JavaScript
                $tooltipEscaped = Format-JsString $tooltip
                $vnetNameEscaped = Format-JsString $vnet.Name
                
                # Determine VNet level: Hub (2), Spoke (3), or Isolated (2)
                $vnetLevel = 2  # Default: Isolated VNets on same level as hubs for visibility
                if ($vnet.Name -eq $hubVnetName) {
                    $vnetLevel = 2  # Main hub VNet
                } elseif ($vnet.Gateways -and $vnet.Gateways.Count -gt 0) {
                    $vnetLevel = 2  # VNet with gateway is a hub (e.g., vnet-ext with vgw-ext)
                } elseif ($spokeVnets.ContainsKey($vnet.Name)) {
                    $vnetLevel = 3  # Spoke VNet (peered to hub)
                } elseif ($vnet.Peerings -and $vnet.Peerings.Count -gt 0) {
                    $vnetLevel = 3  # Other peered VNets
                }
                # Isolated VNets (no gateways, no peerings) default to level 2
                
                # Store level in map for edge styling
                $vnetLevelMap[$vnet.Name] = $vnetLevel
                
                # Debug: Log level assignment for VNets
                Write-Verbose "VNet '$($vnet.Name)': level=$vnetLevel (hub='$hubVnetName', isSpoke=$($spokeVnets.ContainsKey($vnet.Name)))"
                
                # Use subscription color for each VNet (no group to avoid group color overrides)
                $nodesJson.Add("{ id: $nodeId, label: `"$vnetNameEscaped`", title: `"$tooltipEscaped`", color: `"$subColor`", shape: `"dot`", size: 25, font: { color: `"#e8e8e8`", size: 16 }, level: $vnetLevel }")
                
                # Add gateway nodes
                foreach ($gw in $vnet.Gateways) {
                    $gwNodeId = $nodeCounter++
                    $gwNodeIdMap[$gw.Id] = $gwNodeId
                    $gwTooltip = "$($gw.Name)`nType: $($gw.Type)`nSKU: $($gw.Sku)`nVPN: $($gw.VpnType)"
                    $gwTooltipEscaped = Format-JsString $gwTooltip
                    $gwNameEscaped = Format-JsString $gw.Name
                    $nodesJson.Add("{ id: $gwNodeId, label: `"$gwNameEscaped`", title: `"$gwTooltipEscaped`", color: `"#9b59b6`", shape: `"diamond`", size: 15, font: { color: `"#e8e8e8`", size: 16 }, level: 1 }")
                    $edgesJson.Add("{ from: $nodeId, to: $gwNodeId, color: { color: `"#9b59b6`" }, width: 2, length: 50 }")
                }
                
                # Add Azure Firewall nodes
                if ($vnet.Firewalls -and $vnet.Firewalls.Count -gt 0) {
                    foreach ($fw in $vnet.Firewalls) {
                        $fwNodeId = $null
                        if ($fwNodeIdMap.ContainsKey($fw.Id)) {
                            $fwNodeId = $fwNodeIdMap[$fw.Id]
                        } else {
                            $fwNodeId = $nodeCounter++
                            $fwNodeIdMap[$fw.Id] = $fwNodeId
                            $fwTooltip = "$($fw.Name)`nType: Azure Firewall`nSKU: $($fw.SkuTier)`nThreat Intel: $($fw.ThreatIntelMode)"
                            $fwTooltipEscaped = Format-JsString $fwTooltip
                            $fwNameEscaped = Format-JsString $fw.Name
                            # Firewalls stay at level 2 (same as gateway level)
                            $nodesJson.Add("{ id: $fwNodeId, label: `"$fwNameEscaped`", title: `"$fwTooltipEscaped`", color: `"#e74c3c`", shape: `"box`", size: 15, font: { color: `"#e8e8e8`", size: 16 }, level: 2 }")
                        }
                        
                        # Always create edge from VNet to Firewall (if both nodes exist)
                        if ($nodeId -and $fwNodeId) {
                            $edgesJson.Add("{ from: $nodeId, to: $fwNodeId, color: { color: `"#e74c3c`" }, width: 2, length: 50, title: `"Azure Firewall in VNet`" }")
                        } else {
                            Write-Verbose "Failed to create edge for firewall $($fw.Name) in VNet $($vnet.Name): VNet nodeId=$nodeId, Firewall nodeId=$fwNodeId"
                        }
                    }
                }
            }
        }
        
        # Add Virtual WAN Hub nodes
        foreach ($subId in $hubGroups.Keys) {
            if (-not $subColorMap.ContainsKey($subId)) {
                $colorIndex = $subColorMap.Count
                $subColorMap[$subId] = $subscriptionColors[$colorIndex % $subscriptionColors.Count]
            }
            $subColor = $subColorMap[$subId]
            
            foreach ($hub in $hubGroups[$subId]) {
                $hubNodeId = $nodeCounter++
                $nodeIdMap[$hub.Name] = $hubNodeId
                $firewallCount = if ($hub.Firewalls) { $hub.Firewalls.Count } else { 0 }
                $hubTooltip = "$($hub.Name)`nType: Virtual WAN Hub`nLocation: $($hub.Location)`nAddress: $($hub.AddressPrefix)`nER: $($hub.ExpressRouteConnections.Count) | S2S: $($hub.VpnConnections.Count) | Firewalls: $firewallCount"
                $hubTooltipEscaped = Format-JsString $hubTooltip
                $hubNameEscaped = Format-JsString $hub.Name
                # Virtual WAN Hubs are at level 2 (same as hub VNet)
                $nodesJson.Add("{ id: $hubNodeId, label: `"$hubNameEscaped`", title: `"$hubTooltipEscaped`", color: `"#f39c12`", shape: `"hexagon`", size: 30, font: { color: `"#e8e8e8`", size: 16 }, level: 2 }")
                
                # Add Virtual WAN-integrated Azure Firewall nodes
                if ($hub.Firewalls -and $hub.Firewalls.Count -gt 0) {
                    foreach ($fw in $hub.Firewalls) {
                        if (-not $fwNodeIdMap.ContainsKey($fw.Id)) {
                            $fwNodeId = $nodeCounter++
                            $fwNodeIdMap[$fw.Id] = $fwNodeId
                            $fwTooltip = "$($fw.Name)`nType: Azure Firewall (Virtual WAN)`nSKU: $($fw.SkuTier)`nThreat Intel: $($fw.ThreatIntelMode)`nHub: $($hub.Name)"
                            $fwTooltipEscaped = Format-JsString $fwTooltip
                            $fwNameEscaped = Format-JsString $fw.Name
                            $nodesJson.Add("{ id: $fwNodeId, label: `"$fwNameEscaped`", title: `"$fwTooltipEscaped`", color: `"#e74c3c`", shape: `"box`", size: 15, font: { color: `"#e8e8e8`", size: 16 }, level: 2 }")
                            # Create edge from Hub to Firewall
                            $edgesJson.Add("{ from: $hubNodeId, to: $fwNodeId, color: { color: `"#e74c3c`" }, width: 2, length: 50, title: `"Azure Firewall in Virtual WAN Hub`" }")
                        }
                    }
                }
            }
        }
        
        # Map hub representation VNet names to their hub node IDs
        # These are VNets like "HV_p-conhub-sec-vhub_..." that represent hubs for peering
        foreach ($vnet in $vnets) {
            if ($vnet.Name -like "HV_*" -and -not $nodeIdMap.ContainsKey($vnet.Name)) {
                $vnetBaseName = $vnet.Name -replace '^HV_', '' -replace '_[a-f0-9-]+$', ''
                $matchingHub = $virtualWANHubs | Where-Object { 
                    $hubBaseName = $_.Name -replace '^HV_', '' -replace '_[a-f0-9-]+$', ''
                    $_.Name -eq $vnetBaseName -or $hubBaseName -eq $vnetBaseName -or $_.Name -eq $vnet.Name
                } | Select-Object -First 1
                if ($matchingHub -and $nodeIdMap.ContainsKey($matchingHub.Name)) {
                    # Map the hub representation VNet name to the hub's node ID
                    $nodeIdMap[$vnet.Name] = $nodeIdMap[$matchingHub.Name]
                    Write-Verbose "Mapped hub representation VNet '$($vnet.Name)' to hub node '$($matchingHub.Name)'"
                }
            }
        }
        
        # Add standalone Azure Firewall nodes (not linked to VNets or Hubs in inventory)
        # These are firewalls that weren't added to any VNet's or Hub's Firewalls list
        foreach ($fw in $azureFirewalls) {
            if (-not $fwNodeIdMap.ContainsKey($fw.Id)) {
                $fwSubId = $fw.SubscriptionId
                if (-not $subColorMap.ContainsKey($fwSubId)) {
                    $colorIndex = $subColorMap.Count
                    $subColorMap[$fwSubId] = $subscriptionColors[$colorIndex % $subscriptionColors.Count]
                }
                
                $fwNodeId = $nodeCounter++
                $fwNodeIdMap[$fw.Id] = $fwNodeId
                $deploymentInfo = if ($fw.DeploymentType -eq "VirtualWAN") { "Virtual WAN Hub: $($fw.VirtualHubName)" } else { "VNet: $($fw.VNetName)" }
                $fwTooltip = "$($fw.Name)`nType: Azure Firewall`nSKU: $($fw.SkuTier)`nThreat Intel: $($fw.ThreatIntelMode)`n$deploymentInfo"
                $fwTooltipEscaped = Format-JsString $fwTooltip
                $fwNameEscaped = Format-JsString $fw.Name
                $nodesJson.Add("{ id: $fwNodeId, label: `"$fwNameEscaped`", title: `"$fwTooltipEscaped`", color: `"#e74c3c`", shape: `"box`", size: 15, font: { color: `"#e8e8e8`", size: 16 }, level: 2 }")
                
                # Try to link to VNet if VNetName is known and VNet node exists
                if ($fw.VNetName -and $nodeIdMap.ContainsKey($fw.VNetName)) {
                    $vnetNodeId = $nodeIdMap[$fw.VNetName]
                    $edgesJson.Add("{ from: $vnetNodeId, to: $fwNodeId, color: { color: `"#e74c3c`" }, width: 2, length: 50, title: `"Azure Firewall in VNet`" }")
                }
                # Try to link to Virtual WAN Hub if VirtualHubName is known and Hub node exists
                elseif ($fw.VirtualHubName -and $fw.VirtualHubName -ne "Unknown" -and $nodeIdMap.ContainsKey($fw.VirtualHubName)) {
                    $hubNodeId = $nodeIdMap[$fw.VirtualHubName]
                    $edgesJson.Add("{ from: $hubNodeId, to: $fwNodeId, color: { color: `"#e74c3c`" }, width: 2, length: 50, title: `"Azure Firewall in Virtual WAN Hub`" }")
                } else {
                    Write-Verbose "Standalone firewall $($fw.Name) could not be linked: VNet=$($fw.VNetName), Hub=$($fw.VirtualHubName), DeploymentType=$($fw.DeploymentType)"
                }
            }
        }
        
        # Create nodes for remote VNets and Virtual WAN Hubs that aren't in NetworkInventory (unknown subscriptions)
        # NOTE: This must run AFTER hub nodes are created above, so we check if hub already exists
        $unknownVnetColor = "#95a5a6"  # Gray color for unknown VNets
        $unknownHubColor = "#d68910"  # Orange color for unknown hubs
        foreach ($vnet in $vnets) {
            foreach ($peering in $vnet.Peerings) {
                $remoteVnetName = $peering.RemoteVnetName
                if ($remoteVnetName -and -not $nodeIdMap.ContainsKey($remoteVnetName)) {
                    # Skip hub representation VNets (they should already be mapped to hub nodes)
                    if ($remoteVnetName -like "HV_*") {
                        $vnetBaseName = $remoteVnetName -replace '^HV_', '' -replace '_[a-f0-9-]+$', ''
                        $foundHub = $virtualWANHubs | Where-Object { 
                            $hubBaseName = $_.Name -replace '^HV_', '' -replace '_[a-f0-9-]+$', ''
                            $_.Name -eq $vnetBaseName -or $hubBaseName -eq $vnetBaseName -or $_.Name -eq $remoteVnetName
                        } | Select-Object -First 1
                        if ($foundHub -and $nodeIdMap.ContainsKey($foundHub.Name)) {
                            # Map to existing hub node
                            $nodeIdMap[$remoteVnetName] = $nodeIdMap[$foundHub.Name]
                            continue
                        }
                    }
                    
                    # Check if this is a Virtual WAN hub or a VNet
                    if ($peering.IsVirtualWANHub) {
                        # Check if this hub is actually in our inventory (might be in different subscription)
                        $foundHub = $virtualWANHubs | Where-Object { $_.Name -eq $remoteVnetName } | Select-Object -First 1
                        if (-not $foundHub) {
                            # This is a Virtual WAN hub not in our inventory
                            $nodeId = $nodeCounter++
                            $nodeIdMap[$remoteVnetName] = $nodeId
                            $tooltip = "$remoteVnetName`nType: Virtual WAN Hub`nSubscription: Unknown`n(No access to this subscription)"
                            $tooltipEscaped = Format-JsString $tooltip
                            $remoteVnetNameEscaped = Format-JsString $remoteVnetName
                            # Unknown Virtual WAN Hub - treat as level 2 (same as known hubs)
                            $nodesJson.Add("{ id: $nodeId, label: `"$remoteVnetNameEscaped`", title: `"$tooltipEscaped`", color: `"$unknownHubColor`", shape: `"hexagon`", size: 30, font: { color: `"#e8e8e8`", size: 16 }, level: 2 }")
                        }
                    } else {
                        # Check if this VNet is actually in our inventory (might be in different subscription)
                        $foundVnet = $vnets | Where-Object { $_.Name -eq $remoteVnetName } | Select-Object -First 1
                        if (-not $foundVnet) {
                            # This remote VNet is not in our inventory - create a node for it
                            $nodeId = $nodeCounter++
                            $nodeIdMap[$remoteVnetName] = $nodeId
                            $tooltip = "$remoteVnetName`nSubscription: Unknown`n(No access to this subscription)"
                            $tooltipEscaped = Format-JsString $tooltip
                            $remoteVnetNameEscaped = Format-JsString $remoteVnetName
                            # Unknown remote VNet - treat as isolated (level 4)
                            $nodesJson.Add("{ id: $nodeId, label: `"$remoteVnetNameEscaped`", title: `"$tooltipEscaped`", color: `"$unknownVnetColor`", shape: `"dot`", size: 25, font: { color: `"#e8e8e8`", size: 16 }, level: 4 }")
                        }
                    }
                }
            }
        }
        
        # Add peering edges (VNet-to-VNet and VNet-to-Hub)
        foreach ($vnet in $vnets) {
            if (-not $nodeIdMap.ContainsKey($vnet.Name)) { continue }
            $fromId = $nodeIdMap[$vnet.Name]
            
            foreach ($peering in $vnet.Peerings) {
                $remoteVnetName = $peering.RemoteVnetName
                if (-not $remoteVnetName) { continue }
                
                # Try to find the target node - could be a VNet or a Hub
                $toId = $null
                if ($nodeIdMap.ContainsKey($remoteVnetName)) {
                    $toId = $nodeIdMap[$remoteVnetName]
                } elseif ($peering.IsVirtualWANHub) {
                    # If it's a hub peering, try multiple ways to find the hub
                    # First try by ID (most reliable)
                    $foundHub = $null
                    if ($peering.RemoteHubId) {
                        $foundHub = $virtualWANHubs | Where-Object { $_.Id -eq $peering.RemoteHubId } | Select-Object -First 1
                    }
                    # If not found by ID, try by exact name match
                    if (-not $foundHub) {
                        $foundHub = $virtualWANHubs | Where-Object { $_.Name -eq $remoteVnetName } | Select-Object -First 1
                    }
                    # Try case-insensitive name match
                    if (-not $foundHub) {
                        $foundHub = $virtualWANHubs | Where-Object { $_.Name -ieq $remoteVnetName } | Select-Object -First 1
                    }
                    # Try fuzzy matching: check if hub name is contained in remote name or vice versa
                    if (-not $foundHub) {
                        foreach ($hub in $virtualWANHubs) {
                            # Remove common prefixes/suffixes for matching
                            $hubBaseName = $hub.Name -replace '^HV_', '' -replace '_[a-f0-9-]+$', ''
                            $remoteBaseName = $remoteVnetName -replace '^HV_', '' -replace '_[a-f0-9-]+$', ''
                            
                            # Try various matching strategies
                            if ($hubBaseName -eq $remoteBaseName -or 
                                $hub.Name -eq $remoteBaseName -or 
                                $remoteVnetName -eq $hubBaseName -or
                                $hub.Name -like "*$remoteBaseName*" -or
                                $remoteVnetName -like "*$hubBaseName*") {
                                $foundHub = $hub
                                break
                            }
                        }
                    }
                    if ($foundHub) {
                        # Try to find the hub node by its name
                        if ($nodeIdMap.ContainsKey($foundHub.Name)) {
                            $toId = $nodeIdMap[$foundHub.Name]
                        } else {
                            # Hub exists but node not created - this shouldn't happen, but log it
                            Write-Verbose "Hub found in inventory but node not in map: $($foundHub.Name) (looking for: $remoteVnetName)"
                        }
                    } else {
                        Write-Verbose "Hub peering found but hub not in inventory: $remoteVnetName (ID: $($peering.RemoteHubId))"
                    }
                }
                
                if ($toId) {
                    # Create a unique key for this peering pair to avoid duplicates
                    $peeringKey = if ($fromId -lt $toId) { "$fromId-$toId" } else { "$toId-$fromId" }
                    
                    if (-not $processedPeerings.Contains($peeringKey)) {
                        [void]$processedPeerings.Add($peeringKey)
                        $edgeColor = if ($peering.State -eq "Connected") { "#2ecc71" } else { "#e74c3c" }
                        # Use different edge style for Virtual WAN hub peerings
                        $edgeDashes = if ($peering.IsVirtualWANHub) { "true" } else { "false" }
                        $edgeTitle = if ($peering.IsVirtualWANHub) { "Peering to Virtual WAN Hub: $($peering.State)" } else { "Peering: $($peering.State)" }
                        
                        # Determine arrow direction based on gateway usage
                        # UseRemoteGateways = true means this VNet uses remote gateway (arrow to remote)
                        # AllowGatewayTransit = true means remote VNet uses this gateway (arrow from remote)
                        $arrowDirection = ""
                        if ($peering.UseRemoteGateways -and $peering.AllowGatewayTransit) {
                            $arrowDirection = ", arrows: `"to;from`""  # Bidirectional
                        } elseif ($peering.UseRemoteGateways) {
                            $arrowDirection = ", arrows: `"to`""  # This VNet uses remote gateway
                        } elseif ($peering.AllowGatewayTransit) {
                            $arrowDirection = ", arrows: `"from`""  # Remote VNet uses this gateway
                        }
                        
                        # Check if this is a spoke-to-spoke peering (both VNets are level 3)
                        $fromLevel = if ($vnetLevelMap.ContainsKey($vnet.Name)) { $vnetLevelMap[$vnet.Name] } else { 4 }
                        $toLevel = if ($vnetLevelMap.ContainsKey($remoteVnetName)) { $vnetLevelMap[$remoteVnetName] } else { 4 }
                        $isSpokeToSpoke = ($fromLevel -eq 3) -and ($toLevel -eq 3) -and (-not $peering.IsVirtualWANHub)
                        
                        # Add curved smooth settings for spoke-to-spoke peerings
                        $smoothOption = ""
                        if ($isSpokeToSpoke) {
                            $smoothOption = ", smooth: { type: 'curvedCW', roundness: 0.5 }"
                        }
                        
                        $edgesJson.Add("{ from: $fromId, to: $toId, color: { color: `"$edgeColor`" }, dashes: $edgeDashes, width: 2, title: `"$edgeTitle`"$arrowDirection$smoothOption }")
                    }
                } else {
                    # Debug: Log if we can't find the target node
                    Write-Verbose "Could not find target node for peering: $($vnet.Name) -> $remoteVnetName (IsVirtualWANHub: $($peering.IsVirtualWANHub))"
                }
            }
        }
        
        # Also add peerings from hubs to VNets (reverse direction)
        foreach ($hub in $virtualWANHubs) {
            if (-not $nodeIdMap.ContainsKey($hub.Name)) { continue }
            $fromId = $nodeIdMap[$hub.Name]
            
            if ($hub.Peerings) {
                foreach ($peering in $hub.Peerings) {
                    $vnetName = $peering.VNetName
                    if (-not $vnetName) { continue }
                    
                    if ($nodeIdMap.ContainsKey($vnetName)) {
                        $toId = $nodeIdMap[$vnetName]
                        
                        # Create a unique key for this peering pair to avoid duplicates
                        $peeringKey = if ($fromId -lt $toId) { "$fromId-$toId" } else { "$toId-$fromId" }
                        
                        if (-not $processedPeerings.Contains($peeringKey)) {
                            [void]$processedPeerings.Add($peeringKey)
                            $edgeColor = if ($peering.State -eq "Connected") { "#2ecc71" } else { "#e74c3c" }
                            $edgeTitle = "Peering from Virtual WAN Hub: $($peering.State)"
                            
                            # Determine arrow direction based on gateway usage
                            # UseRemoteGateways = true means VNet uses Hub's gateway (arrow from Hub to VNet)
                            # For Hub peerings, typically the VNet uses the Hub's gateway
                            $arrowDirection = ""
                            if ($peering.UseRemoteGateways) {
                                $arrowDirection = ", arrows: `"to`""  # VNet uses Hub gateway
                            }
                            
                            $edgesJson.Add("{ from: $fromId, to: $toId, color: { color: `"$edgeColor`" }, dashes: true, width: 2, title: `"$edgeTitle`"$arrowDirection }")
                        }
                    }
                }
            }
        }
        
        # Note: Duplicate Virtual WAN Hub nodes (e.g., "p-conhub-sec-vhub" and "HV_p-conhub-sec-vhub_...")
        # are now prevented from being created. Hub representation VNets are mapped to hub nodes above.
        
        # Add S2S tunnel edges, P2S clients, and on-premises nodes from classic gateways
        foreach ($vnet in $vnets) {
            foreach ($gw in $vnet.Gateways) {
                # Add P2S clients as a separate node (if configured)
                $p2sAddressPoolsRaw = $null
                if ($gw.P2SAddressPools) {
                    $p2sAddressPoolsRaw = $gw.P2SAddressPools -join ', '
                } elseif ($gw.P2SAddressPool) {
                    $p2sAddressPoolsRaw = $gw.P2SAddressPool
                } elseif ($gw.VpnClientAddressPools) {
                    $p2sAddressPoolsRaw = $gw.VpnClientAddressPools -join ', '
                } elseif ($gw.VpnClientAddressPool) {
                    $p2sAddressPoolsRaw = $gw.VpnClientAddressPool
                }

                $p2sTunnelTypeRaw = $null
                if ($gw.P2STunnelType) {
                    $p2sTunnelTypeRaw = $gw.P2STunnelType
                } elseif ($gw.VpnClientProtocols) {
                    $p2sTunnelTypeRaw = $gw.VpnClientProtocols -join ', '
                }

                $p2sAuthTypeRaw = $null
                if ($gw.P2SAuthType) {
                    $p2sAuthTypeRaw = $gw.P2SAuthType
                } elseif ($gw.P2SAuthenticationType) {
                    $p2sAuthTypeRaw = $gw.P2SAuthenticationType
                } elseif ($gw.VpnClientAuthenticationTypes) {
                    $p2sAuthTypeRaw = $gw.VpnClientAuthenticationTypes -join ', '
                } elseif ($gw.VpnClientAuthenticationType) {
                    $p2sAuthTypeRaw = $gw.VpnClientAuthenticationType
                }

                if ($p2sAddressPoolsRaw -or $p2sTunnelTypeRaw -or $p2sAuthTypeRaw) {
                    $p2sNodeId = $nodeCounter++
                    $p2sLines = @("P2S Clients")
                    if ($p2sAddressPoolsRaw) { $p2sLines += "Address pool(s): $p2sAddressPoolsRaw" }
                    if ($p2sTunnelTypeRaw) { $p2sLines += "Tunnel type: $p2sTunnelTypeRaw" }
                    if ($p2sAuthTypeRaw) { $p2sLines += "Authentication: $p2sAuthTypeRaw" }
                    $p2sTooltip = $p2sLines -join "`n"
                    $p2sTooltipEscaped = Format-JsString $p2sTooltip
                    # P2S Clients are at level 0 (on-premises level)
                    $nodesJson.Add("{ id: $p2sNodeId, label: `"P2S Clients`", title: `"$p2sTooltipEscaped`", color: `"#2980b9`", shape: `"box`", size: 18, font: { color: `"#e8e8e8`", size: 14 }, level: 0 }")
                    $edgesJson.Add("{ from: $p2sNodeId, to: $gwNodeId, color: { color: `"#2980b9`" }, dashes: true, width: 2, title: `"P2S Clients`", arrows: `"to`" }")
                }

                if ($gw.Connections -and $gw.Connections.Count -gt 0) {
                    $gwNodeId = $gwNodeIdMap[$gw.Id]
                    
                    foreach ($conn in $gw.Connections) {
                        if ($conn.RemoteNetwork) {
                            $remoteName = $conn.RemoteNetworkName
                            $s2sKey = "$($gw.Id)-$remoteName"
                            
                            if (-not $processedS2S.Contains($s2sKey)) {
                                [void]$processedS2S.Add($s2sKey)
                                
                                if ($conn.RemoteNetwork.Type -eq "OnPremises") {
                                    # Create on-premises node
                                $onPremNodeId = $nodeCounter++
                                $connNameForTooltip = if ($conn.Name) { $conn.Name } else { "Unknown" }
                                $onPremTooltip = "Name: $connNameForTooltip`nLGW: $remoteName`nType: On-Premises Network`nAddress Space: $($conn.RemoteNetwork.AddressSpace)`nGateway IP: $($conn.RemoteNetwork.GatewayIpAddress)"
                                $onPremTooltipEscaped = Format-JsString $onPremTooltip
                                $remoteNameEscaped = Format-JsString $remoteName
                                # On-premises sites are at level 0
                                $nodesJson.Add("{ id: $onPremNodeId, label: `"$remoteNameEscaped`", title: `"$onPremTooltipEscaped`", color: `"#34495e`", shape: `"box`", size: 20, font: { color: `"#ffffff`", size: 16 }, level: 0 }")
                                    
                                    # Add S2S edge
                                    $statusColor = if ($conn.ConnectionStatus -eq "Connected") { "#16a085" } else { "#e74c3c" }
                                    $edgesJson.Add("{ from: $gwNodeId, to: $onPremNodeId, color: { color: `"$statusColor`" }, dashes: true, width: 3, title: `"S2S: $($conn.ConnectionStatus)`", arrows: `"to`" }")
                                }
                                elseif ($conn.RemoteNetwork.Type -eq "VNet") {
                                    # VNet-to-VNet connection
                                    $remoteVnetName = $conn.RemoteNetwork.Name
                                    $remoteVnetId = $nodeIdMap[$remoteVnetName]
                                    
                                    if ($remoteVnetId) {
                                        # Find the remote gateway node
                                        $remoteGw = $NetworkInventory | ForEach-Object { $_.Gateways } | Where-Object { 
                                            $_.Connections | Where-Object { $_.RemoteNetworkName -eq $vnet.Name }
                                        } | Select-Object -First 1
                                        
                                        if ($remoteGw -and $gwNodeIdMap[$remoteGw.Id]) {
                                            $remoteGwNodeId = $gwNodeIdMap[$remoteGw.Id]
                                            $statusColor = if ($conn.ConnectionStatus -eq "Connected") { "#16a085" } else { "#e74c3c" }
                                            $edgesJson.Add("{ from: $gwNodeId, to: $remoteGwNodeId, color: { color: `"$statusColor`" }, dashes: true, width: 3, title: `"S2S VNet-to-VNet: $($conn.ConnectionStatus)`" }")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        
        # Add ExpressRoute and S2S connections from Virtual WAN Hubs
        foreach ($hub in $virtualWANHubs) {
            $hubNodeId = $nodeIdMap[$hub.Name]
            if (-not $hubNodeId) { continue }  # Skip if hub node wasn't created
            
            # ExpressRoute connections
            if ($hub.ExpressRouteConnections) {
                foreach ($erConn in $hub.ExpressRouteConnections) {
                    # Get circuit name from multiple possible sources
                    # Priority: 1) Circuit object Name, 2) ExpressRouteCircuitName (if not Unknown), 3) Extract from CircuitId, 4) Unknown
                    $circuit = $erConn.ExpressRouteCircuit
                    $circuitName = if ($circuit -and $circuit.Name) {
                        # Best source: actual circuit object name from API
                        ($circuit.Name -replace "`r`n", " " -replace "`n", " " -replace "`r", " ").Trim()
                    } elseif ($erConn.ExpressRouteCircuitName -and $erConn.ExpressRouteCircuitName -ne "Unknown") { 
                        ($erConn.ExpressRouteCircuitName -replace "`r`n", " " -replace "`n", " " -replace "`r", " ").Trim()
                    } elseif ($erConn.ExpressRouteCircuitId) { 
                        # Extract name from circuit ID as fallback
                        (($erConn.ExpressRouteCircuitId -split '/')[-1] -replace "`r`n", " " -replace "`n", " " -replace "`r", " ").Trim()
                    } else { 
                        "Unknown Circuit" 
                    }
                    $onPremKey = "onprem-er-$circuitName"
                    
                    if (-not $nodeIdMap.ContainsKey($onPremKey)) {
                        $onPremNodeId = $nodeCounter++
                        $nodeIdMap[$onPremKey] = $onPremNodeId
                        # Use circuit object if not already retrieved above
                        if (-not $circuit) {
                            $circuit = $erConn.ExpressRouteCircuit
                        }
                        $tooltipParts = @("ExpressRoute Circuit", $circuitName)
                        if ($circuit) {
                            if ($circuit.ServiceProviderName) { $tooltipParts += "Provider: $($circuit.ServiceProviderName)" }
                            if ($circuit.PeeringLocation) { $tooltipParts += "Location: $($circuit.PeeringLocation)" }
                            if ($circuit.BandwidthInMbps) { $tooltipParts += "Bandwidth: $($circuit.BandwidthInMbps) Mbps" }
                            if ($circuit.SkuTier) { $tooltipParts += "SKU: $($circuit.SkuTier)" }
                        }
                        if ($erConn.PeerASN) { $tooltipParts += "Peer ASN: $($erConn.PeerASN)" }
                        $onPremTooltip = $tooltipParts -join "`n"
                        # Escape the tooltip and name for JavaScript
                        $onPremTooltipEscaped = Format-JsString $onPremTooltip
                        $circuitNameEscaped = Format-JsString $circuitName
                        # ExpressRoute circuits are at level 0 (on-premises level)
                        $nodesJson.Add("{ id: $onPremNodeId, label: `"$circuitNameEscaped`", title: `"$onPremTooltipEscaped`", color: `"#34495e`", shape: `"box`", size: 20, font: { color: `"#e8e8e8`", size: 14 }, level: 0 }")
                    }
                    
                    $onPremNodeId = $nodeIdMap[$onPremKey]
                    $erStatusColor = if ($erConn.ConnectionStatus -eq "Connected") { "#2ecc71" } else { "#e74c3c" }
                    $edgesJson.Add("{ from: $hubNodeId, to: $onPremNodeId, color: { color: `"$erStatusColor`" }, dashes: true, width: 2, title: `"ExpressRoute: $($erConn.ConnectionStatus)`" }")
                }
            }
            
            # S2S VPN connections
            if ($hub.VpnConnections) {
                foreach ($vpnConn in $hub.VpnConnections) {
                    $remoteSiteName = $vpnConn.RemoteSiteName
                    $onPremKey = "onprem-s2s-$remoteSiteName"
                    
                    if (-not $nodeIdMap.ContainsKey($onPremKey)) {
                        $onPremNodeId = $nodeCounter++
                        $nodeIdMap[$onPremKey] = $onPremNodeId
                        $onPremTooltip = "On-Premises Site`n$remoteSiteName`nAddress Space: $($vpnConn.RemoteSiteAddressSpace)"
                        $onPremTooltipEscaped = Format-JsString $onPremTooltip
                        $remoteSiteNameEscaped = Format-JsString $remoteSiteName
                        # VPN Sites are at level 0 (on-premises level)
                        $nodesJson.Add("{ id: $onPremNodeId, label: `"$remoteSiteNameEscaped`", title: `"$onPremTooltipEscaped`", color: `"#34495e`", shape: `"box`", size: 20, font: { color: `"#e8e8e8`", size: 14 }, level: 0 }")
                    }
                    
                    $onPremNodeId = $nodeIdMap[$onPremKey]
                    $vpnStatusColor = if ($vpnConn.ConnectionStatus -eq "Connected") { "#2ecc71" } else { "#e74c3c" }
                    $edgesJson.Add("{ from: $hubNodeId, to: $onPremNodeId, color: { color: `"$vpnStatusColor`" }, dashes: true, width: 2, title: `"S2S VPN: $($vpnConn.ConnectionStatus)`" }")
                }
            }
        }

        # Ensure we have valid JSON arrays (empty arrays if no nodes/edges)
        if ($nodesJson.Count -eq 0) {
            $nodesJsonString = ""
        } else {
            $nodesJsonString = $nodesJson -join ",`n            "
        }
        
        if ($edgesJson.Count -eq 0) {
            $edgesJsonString = ""
        } else {
            $edgesJsonString = $edgesJson -join ",`n            "
        }
        
        # Build JavaScript array strings - use empty string if no data
        $jsNodesArrayContent = if ($nodesJsonString) { "`n            $nodesJsonString`n        " } else { "" }
        $jsEdgesArrayContent = if ($edgesJsonString) { "`n            $edgesJsonString`n        " } else { "" }
        
        # Escape hubVnetName for JavaScript injection (wrap in quotes and escape)
        $hubVnetNameEscaped = if ($hubVnetName) { 
            $escaped = Format-JsString $hubVnetName
            "`"$escaped`""
        } else { 
            "null" 
        }

        $html += @"
        </div>
        
        <div class="footer">
            <p>Report generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
        </div>
    </div>

    <script>
        // Initialize vis.js network diagram
        var nodesData = [$jsNodesArrayContent];
        var edgesData = [$jsEdgesArrayContent];
        
        // Debug: Log hub detection and node levels
        try {
            console.log('Hub Detection Debug:');
            console.log('Detected hub VNet:', $hubVnetNameEscaped);
            console.log('Node levels:');
            if (nodesData && Array.isArray(nodesData) && nodesData.length > 0) {
                nodesData.forEach(function(node) {
                    if (node && node.label) {
                        console.log('  ' + node.label + ': level=' + (node.level !== undefined ? node.level : 'undefined') + ', shape=' + (node.shape || 'undefined'));
                    }
                });
            } else {
                console.log('  No nodes found or nodesData is not an array');
            }
        } catch (e) {
            console.error('Error in debug logging:', e);
        }
        var nodes = new vis.DataSet(nodesData);
        var edges = new vis.DataSet(edgesData);
        
        // Helper to show/hide legend items based on actual topology contents
        function updateLegendVisibility() {
            var hasGateway = nodesData.some(function (n) { return n.shape === 'diamond'; });
            var hasHub = nodesData.some(function (n) { return n.shape === 'hexagon'; });
            var hasFirewall = nodesData.some(function (n) { return n.shape === 'box' && n.color === '#e74c3c'; });
            var hasOnPrem = nodesData.some(function (n) { return n.shape === 'box' && n.color === '#34495e'; });
            var hasPeering = edgesData.some(function (e) { return e.dashes === false || e.dashes === undefined; });
            var hasS2S = edgesData.some(function (e) { return e.dashes === true; });

            function setLegendVisible(id, visible) {
                var el = document.getElementById(id);
                if (el) {
                    el.style.display = visible ? '' : 'none';
                }
            }

            // Main diagram legend
            setLegendVisible('legend-gateway', hasGateway);
            setLegendVisible('legend-hub', hasHub);
            setLegendVisible('legend-firewall', hasFirewall);
            setLegendVisible('legend-onprem', hasOnPrem);
            setLegendVisible('legend-peering', hasPeering);
            setLegendVisible('legend-s2s', hasS2S);

            // Fullscreen legend
            setLegendVisible('legend-gateway-fullscreen', hasGateway);
            setLegendVisible('legend-hub-fullscreen', hasHub);
            setLegendVisible('legend-firewall-fullscreen', hasFirewall);
            setLegendVisible('legend-onprem-fullscreen', hasOnPrem);
            setLegendVisible('legend-peering-fullscreen', hasPeering);
            setLegendVisible('legend-s2s-fullscreen', hasS2S);
        }

        updateLegendVisibility();

        var container = document.getElementById('network-diagram');
        if (!container) {
            console.error('Network diagram container not found!');
        } else {
            var data = { nodes: nodes, edges: edges };
            var options = {
                layout: {
                    improvedLayout: true,
                    hierarchical: {
                        enabled: false,
                        direction: 'DU',
                        sortMethod: 'directed',
                        levelSeparation: 200,
                        nodeSpacing: 200,
                        treeSpacing: 200,
                        blockShifting: true,
                        edgeMinimization: true,
                        parentCentralization: true
                    }
                },
                physics: {
                    enabled: true,
                solver: 'forceAtlas2Based',
                forceAtlas2Based: {
                    gravitationalConstant: -50,
                    centralGravity: 0.001,
                    springLength: 200,
                    springConstant: 0.01,
                    avoidOverlap: 0.5,
                    damping: 0.3
                },
                stabilization: { 
                    iterations: 100,
                    fit: true,
                    updateInterval: 25
                }
            },
            interaction: {
                hover: true,
                tooltipDelay: 100,
                zoomView: true,
                dragView: true,
                dragNodes: true
            },
            nodes: {
                borderWidth: 2,
                shadow: true,
                font: {
                    size: 16
                },
                fixed: {
                    x: false,
                    y: false
                }
            },
            edges: {
                smooth: {
                    type: 'cubicBezier',
                    forceDirection: 'vertical',
                    roundness: 0.5
                },
                arrows: {
                    to: {
                        enabled: false,
                        scaleFactor: 0.5
                    }
                }
            },
                groups: {
                    useDefaultGroups: false
                }
            };
            
            try {
                var network = new vis.Network(container, data, options);
                
                // Track physics and layout state
                var physicsEnabled = true;
                var hierarchicalEnabled = false;
                
                // Disable physics after initial stabilization so nodes stay where dragged
                network.on('stabilizationEnd', function() {
                    if (physicsEnabled) {
                        options.physics.enabled = false;
                        network.setOptions(options);
                        physicsEnabled = false;
                        var toggleBtn = document.getElementById('togglePhysics');
                        if (toggleBtn) {
                            toggleBtn.textContent = 'Enable Physics';
                        }
                        // Fix all nodes in their current positions after stabilization
                        var allNodeIds = nodes.getIds();
                        allNodeIds.forEach(function(nodeId) {
                            var position = network.getPositions([nodeId]);
                            if (position[nodeId]) {
                                nodes.update({
                                    id: nodeId,
                                    x: position[nodeId].x,
                                    y: position[nodeId].y,
                                    fixed: {
                                        x: true,
                                        y: true
                                    }
                                });
                            }
                        });
                    }
                });
                
                // Fix nodes immediately when dragging starts (prevents any physics from affecting them)
                network.on('dragStart', function(params) {
                    if (!physicsEnabled && params.nodes.length > 0) {
                        params.nodes.forEach(function(nodeId) {
                            nodes.update({
                                id: nodeId,
                                fixed: {
                                    x: true,
                                    y: true
                                }
                            });
                        });
                    }
                });
                
                // Update fixed position when drag ends
                network.on('dragEnd', function(params) {
                    if (!physicsEnabled && params.nodes.length > 0) {
                        params.nodes.forEach(function(nodeId) {
                            var position = network.getPositions([nodeId]);
                            if (position[nodeId]) {
                                nodes.update({
                                    id: nodeId,
                                    x: position[nodeId].x,
                                    y: position[nodeId].y,
                                    fixed: {
                                        x: true,
                                        y: true
                                    }
                                });
                            }
                        });
                    }
                });
                
                // Toggle physics on/off
                document.getElementById('togglePhysics').addEventListener('click', function() {
                    physicsEnabled = !physicsEnabled;
                    this.textContent = physicsEnabled ? 'Disable Physics' : 'Enable Physics';
                    
                    if (!physicsEnabled) {
                        // Disabling physics: get current positions and fix nodes
                        var allNodeIds = nodes.getIds();
                        var positions = network.getPositions(allNodeIds);
                        var updates = [];
                        allNodeIds.forEach(function(nodeId) {
                            if (positions[nodeId]) {
                                updates.push({
                                    id: nodeId,
                                    x: positions[nodeId].x,
                                    y: positions[nodeId].y,
                                    fixed: {
                                        x: true,
                                        y: true
                                    }
                                });
                            }
                        });
                        if (updates.length > 0) {
                            nodes.update(updates);
                        }
                        // Disable physics after nodes are fixed
                        options.physics.enabled = false;
                        network.setOptions(options);
                    } else {
                        // Enabling physics: unfix nodes first
                        var allNodeIds = nodes.getIds();
                        var updates = [];
                        allNodeIds.forEach(function(nodeId) {
                            updates.push({
                                id: nodeId,
                                fixed: false
                            });
                        });
                        nodes.update(updates);
                        // Enable physics after nodes are unfixed
                        options.physics.enabled = true;
                        network.setOptions(options);
                    }
                });

                // Toggle layout between free and hierarchical (layout only, keep colors/styles unchanged)
                document.getElementById('toggleLayout').addEventListener('click', function () {
                    hierarchicalEnabled = !hierarchicalEnabled;
                    this.textContent = hierarchicalEnabled ? 'Free Layout' : 'Hierarchical Layout';

                    if (hierarchicalEnabled) {
                        // Enable hierarchical layout (tree style)
                        options.layout.hierarchical.enabled = true;
                        options.layout.hierarchical.direction = 'DU';
                        options.layout.hierarchical.sortMethod = 'directed';
                        options.layout.hierarchical.levelSeparation = 200;
                        options.layout.hierarchical.nodeSpacing = 200;
                        options.layout.hierarchical.treeSpacing = 200;
                        options.layout.hierarchical.blockShifting = true;
                        options.layout.hierarchical.edgeMinimization = true;
                        options.layout.hierarchical.parentCentralization = true;
                        network.setOptions(options);
                        // Force vis-network to re-apply hierarchical layout
                        network.setData({ nodes: nodes, edges: edges });
                        network.fit({ animation: { duration: 500, easing: 'easeInOutQuad' } });
                    } else {
                        // Return to free layout (no hierarchical constraints)
                        options.layout.hierarchical.enabled = false;
                        network.setOptions(options);
                        // Force layout refresh back to free layout
                        network.setData({ nodes: nodes, edges: edges });
                        network.fit({ animation: { duration: 500, easing: 'easeInOutQuad' } });
                    }
                });
                
                // Reset layout button
                document.getElementById('resetLayout').addEventListener('click', function() {
                    // Unfix all nodes to allow physics to reposition them
                    var allNodeIds = nodes.getIds();
                    var updates = [];
                    allNodeIds.forEach(function(nodeId) {
                        updates.push({
                            id: nodeId,
                            fixed: false
                        });
                    });
                    nodes.update(updates);
                    
                    // Re-enable physics and force a new stabilization
                    options.physics.enabled = true;
                    network.setOptions(options);
                    physicsEnabled = true;
                    document.getElementById('togglePhysics').textContent = 'Disable Physics';
                    
                    // Fit the view and start a fresh stabilization
                    network.fit({ animation: false });
                    network.stabilize(200);
                    
                    // Auto-disable after stabilization
                    network.once('stabilizationEnd', function() {
                        options.physics.enabled = false;
                        network.setOptions(options);
                        physicsEnabled = false;
                        document.getElementById('togglePhysics').textContent = 'Enable Physics';
                        
                        // Fix nodes in their new positions after stabilization
                        var allNodeIds = nodes.getIds();
                        allNodeIds.forEach(function(nodeId) {
                            var position = network.getPositions([nodeId]);
                            if (position[nodeId]) {
                                nodes.update({
                                    id: nodeId,
                                    x: position[nodeId].x,
                                    y: position[nodeId].y,
                                    fixed: {
                                        x: true,
                                        y: true
                                    }
                                });
                            }
                        });
                    });
                });
                
                // Fullscreen functionality
                var networkFullscreen = null;
                var physicsEnabledFullscreen = true;
                var hierarchicalEnabledFullscreen = false;
                var optionsFullscreen = null;
                
                function initializeFullscreenDiagram() {
                    if (networkFullscreen) {
                        return; // Already initialized
                    }
                    
                    var containerFullscreen = document.getElementById('network-diagram-fullscreen');
                    var dataFullscreen = { nodes: nodes, edges: edges };
                    optionsFullscreen = JSON.parse(JSON.stringify(options)); // Clone options
                    
                    // Sync hierarchical state from main diagram
                    hierarchicalEnabledFullscreen = hierarchicalEnabled;
                    if (hierarchicalEnabled) {
                        optionsFullscreen.layout.hierarchical.enabled = true;
                        optionsFullscreen.layout.hierarchical.direction = 'DU';
                    }
                    
                    // Disable physics initially if it's disabled in main diagram, to preserve positions
                    physicsEnabledFullscreen = physicsEnabled;
                    if (!physicsEnabled) {
                        optionsFullscreen.physics.enabled = false;
                    }
                    
                    networkFullscreen = new vis.Network(containerFullscreen, dataFullscreen, optionsFullscreen);
                    
                    // Sync positions and fixed state from main diagram immediately
                    var allNodeIds = nodes.getIds();
                    var positions = network.getPositions(allNodeIds);
                    networkFullscreen.setPositions(positions);
                    
                    // Also sync fixed state of nodes from the dataset
                    var nodeUpdates = [];
                    allNodeIds.forEach(function(nodeId) {
                        var node = nodes.get(nodeId);
                        if (node && node.fixed !== undefined) {
                            if (positions[nodeId]) {
                                nodeUpdates.push({
                                    id: nodeId,
                                    x: positions[nodeId].x,
                                    y: positions[nodeId].y,
                                    fixed: node.fixed
                                });
                            }
                        }
                    });
                    if (nodeUpdates.length > 0) {
                        nodes.update(nodeUpdates);
                        // Update positions again after fixing nodes
                        networkFullscreen.setPositions(positions);
                    }
                    
                    // Sync physics state UI
                    if (!physicsEnabled) {
                        physicsEnabledFullscreen = false;
                        document.getElementById('togglePhysicsFullscreen').textContent = 'Enable Physics';
                    }
                    
                    // Fix all nodes after stabilization (only if physics was enabled)
                    networkFullscreen.on('stabilizationEnd', function() {
                        if (physicsEnabledFullscreen) {
                            optionsFullscreen.physics.enabled = false;
                            networkFullscreen.setOptions(optionsFullscreen);
                            physicsEnabledFullscreen = false;
                            document.getElementById('togglePhysicsFullscreen').textContent = 'Enable Physics';
                            
                            var allNodeIds = nodes.getIds();
                            allNodeIds.forEach(function(nodeId) {
                                var position = networkFullscreen.getPositions([nodeId]);
                                if (position[nodeId]) {
                                    nodes.update({
                                        id: nodeId,
                                        x: position[nodeId].x,
                                        y: position[nodeId].y,
                                        fixed: {
                                            x: true,
                                            y: true
                                        }
                                    });
                                }
                            });
                        }
                    });
                    
                    // Fix nodes when dragging
                    networkFullscreen.on('dragStart', function(params) {
                        if (!physicsEnabledFullscreen && params.nodes.length > 0) {
                            params.nodes.forEach(function(nodeId) {
                                nodes.update({
                                    id: nodeId,
                                    fixed: {
                                        x: true,
                                        y: true
                                    }
                                });
                            });
                        }
                    });
                    
                    networkFullscreen.on('dragEnd', function(params) {
                        if (!physicsEnabledFullscreen && params.nodes.length > 0) {
                            params.nodes.forEach(function(nodeId) {
                                var position = networkFullscreen.getPositions([nodeId]);
                                if (position[nodeId]) {
                                    nodes.update({
                                        id: nodeId,
                                        x: position[nodeId].x,
                                        y: position[nodeId].y,
                                        fixed: {
                                            x: true,
                                            y: true
                                        }
                                    });
                                }
                            });
                        }
                    });
                }
                
                // Open fullscreen
                document.getElementById('openFullscreen').addEventListener('click', function() {
                    // Show overlay first so container has dimensions
                    document.getElementById('diagram-fullscreen').classList.add('active');
                    
                    // Initialize after a short delay to ensure rendering
                    setTimeout(function() {
                        initializeFullscreenDiagram();
                        
                        if (networkFullscreen) {
                            // Sync positions from main diagram (positions are already synced in initializeFullscreenDiagram, but refresh to be sure)
                            var allNodeIds = nodes.getIds();
                            var positions = network.getPositions(allNodeIds);
                            networkFullscreen.setPositions(positions);
                            
                            // Force redraw and fit to view
                            networkFullscreen.redraw();
                            networkFullscreen.fit({ animation: false });
                        }
                    }, 50);
                });
                
                // Close fullscreen
                document.getElementById('closeFullscreen').addEventListener('click', function() {
                    document.getElementById('diagram-fullscreen').classList.remove('active');
                    
                    // Sync positions back to main diagram
                    if (networkFullscreen) {
                        var allNodeIds = nodes.getIds();
                        var positions = networkFullscreen.getPositions(allNodeIds);
                        network.setPositions(positions);
                    }
                });
                
                // Toggle physics in fullscreen
                document.getElementById('togglePhysicsFullscreen').addEventListener('click', function() {
                    if (!networkFullscreen || !optionsFullscreen) return;
                    
                    physicsEnabledFullscreen = !physicsEnabledFullscreen;
                    this.textContent = physicsEnabledFullscreen ? 'Disable Physics' : 'Enable Physics';
                    
                    if (!physicsEnabledFullscreen) {
                        // Disabling physics: get current positions and fix nodes
                        var allNodeIds = nodes.getIds();
                        var positions = networkFullscreen.getPositions(allNodeIds);
                        var updates = [];
                        allNodeIds.forEach(function(nodeId) {
                            if (positions[nodeId]) {
                                updates.push({
                                    id: nodeId,
                                    x: positions[nodeId].x,
                                    y: positions[nodeId].y,
                                    fixed: {
                                        x: true,
                                        y: true
                                    }
                                });
                            }
                        });
                        if (updates.length > 0) {
                            nodes.update(updates);
                        }
                        // Disable physics after nodes are fixed
                        optionsFullscreen.physics.enabled = false;
                        networkFullscreen.setOptions(optionsFullscreen);
                    } else {
                        // Enabling physics: unfix nodes first
                        var allNodeIds = nodes.getIds();
                        var updates = [];
                        allNodeIds.forEach(function(nodeId) {
                            updates.push({
                                id: nodeId,
                                fixed: false
                            });
                        });
                        nodes.update(updates);
                        // Enable physics after nodes are unfixed
                        optionsFullscreen.physics.enabled = true;
                        networkFullscreen.setOptions(optionsFullscreen);
                    }
                });

                // Toggle layout in fullscreen between free and hierarchical (layout only)
                document.getElementById('toggleLayoutFullscreen').addEventListener('click', function () {
                    if (!networkFullscreen || !optionsFullscreen) {
                        return;
                    }
                    hierarchicalEnabledFullscreen = !hierarchicalEnabledFullscreen;
                    this.textContent = hierarchicalEnabledFullscreen ? 'Free Layout' : 'Hierarchical Layout';

                    if (hierarchicalEnabledFullscreen) {
                        optionsFullscreen.layout.hierarchical.enabled = true;
                        optionsFullscreen.layout.hierarchical.direction = 'DU';
                        optionsFullscreen.layout.hierarchical.sortMethod = 'directed';
                        optionsFullscreen.layout.hierarchical.levelSeparation = 200;
                        optionsFullscreen.layout.hierarchical.nodeSpacing = 200;
                        optionsFullscreen.layout.hierarchical.treeSpacing = 200;
                        optionsFullscreen.layout.hierarchical.blockShifting = true;
                        optionsFullscreen.layout.hierarchical.edgeMinimization = true;
                        optionsFullscreen.layout.hierarchical.parentCentralization = true;
                        networkFullscreen.setOptions(optionsFullscreen);
                        // Force vis-network to re-apply hierarchical layout in fullscreen
                        networkFullscreen.setData({ nodes: nodes, edges: edges });
                        networkFullscreen.fit({ animation: { duration: 500, easing: 'easeInOutQuad' } });
                    } else {
                        optionsFullscreen.layout.hierarchical.enabled = false;
                        networkFullscreen.setOptions(optionsFullscreen);
                        // Force layout refresh back to free layout in fullscreen
                        networkFullscreen.setData({ nodes: nodes, edges: edges });
                        networkFullscreen.fit({ animation: { duration: 500, easing: 'easeInOutQuad' } });
                    }
                });
                
                // Reset layout in fullscreen
                document.getElementById('resetLayoutFullscreen').addEventListener('click', function() {
                    if (!networkFullscreen || !optionsFullscreen) return;
                    
                    var allNodeIds = nodes.getIds();
                    var updates = [];
                    allNodeIds.forEach(function(nodeId) {
                        updates.push({
                            id: nodeId,
                            fixed: false
                        });
                    });
                    nodes.update(updates);
                    
                    optionsFullscreen.physics.enabled = true;
                    networkFullscreen.setOptions(optionsFullscreen);
                    physicsEnabledFullscreen = true;
                    document.getElementById('togglePhysicsFullscreen').textContent = 'Disable Physics';
                    
                    networkFullscreen.fit({ animation: false });
                    networkFullscreen.stabilize(200);
                    
                    networkFullscreen.once('stabilizationEnd', function() {
                        optionsFullscreen.physics.enabled = false;
                        networkFullscreen.setOptions(optionsFullscreen);
                        physicsEnabledFullscreen = false;
                        document.getElementById('togglePhysicsFullscreen').textContent = 'Enable Physics';
                        
                        // Fix nodes in their new positions after stabilization
                        var allNodeIds = nodes.getIds();
                        allNodeIds.forEach(function(nodeId) {
                            var position = networkFullscreen.getPositions([nodeId]);
                            if (position[nodeId]) {
                                nodes.update({
                                    id: nodeId,
                                    x: position[nodeId].x,
                                    y: position[nodeId].y,
                                    fixed: {
                                        x: true,
                                        y: true
                                    }
                                });
                            }
                        });
                    });
                });
                
                // Close fullscreen on Escape key
                document.addEventListener('keydown', function(event) {
                    if (event.key === 'Escape') {
                        var fullscreen = document.getElementById('diagram-fullscreen');
                        if (fullscreen && fullscreen.classList.contains('active')) {
                            document.getElementById('closeFullscreen').click();
                        }
                    }
                });
                
                // Handle window resize for fullscreen diagram
                window.addEventListener('resize', function() {
                    if (networkFullscreen) {
                        var fullscreen = document.getElementById('diagram-fullscreen');
                        if (fullscreen && fullscreen.classList.contains('active')) {
                            setTimeout(function() {
                                networkFullscreen.fit();
                            }, 100);
                        }
                    }
                });
                
                // Click on node to scroll to VNet details
                network.on('click', function(params) {
                    if (params.nodes.length > 0) {
                        var nodeId = params.nodes[0];
                        var node = nodes.get(nodeId);
                        if (node && node.shape === 'dot') {
                            var vnetBox = document.querySelector('[data-vnet-name="' + node.label + '"]');
                            if (vnetBox) {
                                vnetBox.scrollIntoView({ behavior: 'smooth', block: 'center' });
                                // Expand the VNet
                                var vnetContent = vnetBox.querySelector('.vnet-content');
                                var vnetHeader = vnetBox.querySelector('.vnet-header');
                                if (vnetContent && vnetContent.style.display !== 'block') {
                                    vnetContent.style.display = 'block';
                                    vnetHeader.classList.add('expanded');
                                }
                            }
                        }
                    }
                });
            } catch (error) {
                console.error('Error initializing network diagram:', error);
            }
        }

        function toggleRiskSummary() {
            const section = document.getElementById('risk-summary');
            const content = section.querySelector('.risk-summary-content');
            const icon = document.getElementById('icon-risk-summary');
            
            if (section.classList.contains('expanded')) {
                section.classList.remove('expanded');
                if (icon) icon.style.transform = 'rotate(0deg)';
            } else {
                section.classList.add('expanded');
                if (icon) icon.style.transform = 'rotate(90deg)';
            }
        }

        function toggleSubscription(id) {
            const content = document.getElementById(id);
            const header = content.previousElementSibling;
            
            if (content.style.display === 'none') {
                content.style.display = 'block';
                header.classList.add('expanded');
            } else {
                content.style.display = 'none';
                header.classList.remove('expanded');
            }
        }

        function toggleVNet(id) {
            const content = document.getElementById(id);
            const header = content.previousElementSibling;
            
            if (event) event.stopPropagation();
            
            if (content.style.display === 'block') {
                content.style.display = 'none';
                header.classList.remove('expanded');
            } else {
                content.style.display = 'block';
                header.classList.add('expanded');
            }
        }

        function toggleSubnet(id) {
            const content = document.getElementById(id);
            const header = content.previousElementSibling;
             
            if (event) event.stopPropagation();

            if (content.style.display === 'block') {
                content.style.display = 'none';
                header.classList.remove('expanded');
            } else {
                content.style.display = 'block';
                header.classList.add('expanded');
            }
        }

        document.getElementById('expandAll').addEventListener('click', function() {
            document.querySelectorAll('.vnet-content, .subnet-content, .subscription-content').forEach(el => el.style.display = 'block');
            document.querySelectorAll('.vnet-header, .subnet-header, .subscription-header').forEach(el => el.classList.add('expanded'));
        });

        document.getElementById('collapseAll').addEventListener('click', function() {
            document.querySelectorAll('.vnet-content, .subnet-content, .subscription-content').forEach(el => el.style.display = 'none');
            document.querySelectorAll('.vnet-header, .subnet-header, .subscription-header').forEach(el => el.classList.remove('expanded'));
        });
        
        // Collapse all subscription tables on page load
        document.addEventListener('DOMContentLoaded', function() {
            document.querySelectorAll('.subscription-content').forEach(el => el.style.display = 'none');
            document.querySelectorAll('.subscription-header').forEach(el => el.classList.remove('expanded'));
        });

        // Subscription filter
        document.getElementById('subscriptionFilter').addEventListener('change', function() {
            const selectedSub = this.value;
            const sections = document.querySelectorAll('.subscription-section');
            
            sections.forEach(section => {
                if (!selectedSub || section.getAttribute('data-subscription-id') === selectedSub) {
                    section.style.display = '';
                } else {
                    section.style.display = 'none';
                }
            });
        });

        // Search functionality
        document.getElementById('searchFilter').addEventListener('keyup', function() {
            const filter = this.value.toLowerCase();
            const vnets = document.querySelectorAll('.vnet-box');
            
            vnets.forEach(vnet => {
                const searchable = vnet.getAttribute('data-searchable');
                const content = vnet.textContent.toLowerCase();
                
                if (searchable.includes(filter) || content.includes(filter)) {
                    vnet.style.display = '';
                    // Show parent subscription section
                    const subSection = vnet.closest('.subscription-section');
                    if (subSection) subSection.style.display = '';
                } else {
                    vnet.style.display = 'none';
                }
            });
        });
    </script>
</body>
</html>
"@
        
        [System.IO.File]::WriteAllText($OutputPath, $html, [System.Text.Encoding]::UTF8)
        
        # Verify file was created
        if (-not (Test-Path $OutputPath)) {
            throw "File was not created at expected path: $OutputPath"
        }
        
        $fileInfo = Get-Item $OutputPath
        Write-Verbose "Report file created: $($fileInfo.FullName) ($([math]::Round($fileInfo.Length / 1KB, 2)) KB)"
        
        return @{
            OutputPath = $OutputPath
            VNetCount = $totalVnets
            DeviceCount = $totalDevices
            SecurityRisks = $totalRisks
            SubnetCount = $totalSubnets
            NSGCount = $totalNsgs
            PeeringCount = $totalPeerings
            GatewayCount = $totalGateways
            S2SConnectionCount = $totalS2SConnections
            ERConnectionCount = $totalERConnections
            DisconnectedConnections = $disconnectedConnections
            SubnetsMissingNSG = $subnetsMissingNSG
            VirtualWANHubCount = $totalVirtualWANHubs
            AzureFirewallCount = $totalAzureFirewalls
            SubnetsWithServiceEndpoints = $subnetsWithServiceEndpoints
            TotalServiceEndpoints = $totalServiceEndpoints
        }
    }
    catch {
        Write-Error "Failed to generate network report: $_"
        Write-Error "Output path was: $OutputPath"
        if ($_.Exception.InnerException) {
            Write-Error "Inner exception: $($_.Exception.InnerException.Message)"
        }
        throw
    }
}
