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
    
    try {
        # Calculate summary metrics
        $totalVnets = $NetworkInventory.Count
        $totalSubnets = 0
        $totalNsgs = 0
        $totalPeerings = 0
        $totalGateways = 0
        $totalDevices = 0
        $totalCriticalRisks = 0
        $totalHighRisks = 0
        $totalMediumRisks = 0
        
        # Collect unique NSGs and subscriptions, and all NSG risks
        $uniqueNsgIds = [System.Collections.Generic.HashSet[string]]::new()
        $subscriptions = [System.Collections.Generic.Dictionary[string, PSObject]]::new()
        $allRisks = [System.Collections.Generic.List[PSObject]]::new()
        
        # Count unique peerings (each peering relationship appears twice - once from each VNet)
        $uniquePeerings = [System.Collections.Generic.HashSet[string]]::new()
        
        foreach ($vnet in $NetworkInventory) {
            $totalSubnets += $vnet.Subnets.Count
            $totalGateways += $vnet.Gateways.Count
            
            # Track unique peering relationships
            foreach ($peering in $vnet.Peerings) {
                # Create a unique key by sorting VNet names alphabetically
                $vnetPair = @($vnet.Name, $peering.RemoteVnetName) | Sort-Object
                $peeringKey = "$($vnetPair[0])|$($vnetPair[1])"
                [void]$uniquePeerings.Add($peeringKey)
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

        /* Network Specific Styles */
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
            background: #9b59b6;
            transform: rotate(45deg);
        }
        
        .legend-line {
            width: 30px;
            height: 2px;
            flex-shrink: 0;
        }
        
        .legend-line.peering {
            background: #2ecc71;
            height: 2px;
        }
        
        .legend-line.s2s {
            background: repeating-linear-gradient(
                to right,
                #16a085 0px,
                #16a085 4px,
                transparent 4px,
                transparent 8px
            );
            height: 3px;
        }
        
        #network-diagram {
            height: 500px;
            width: 100%;
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
            color: #2ecc71;
            padding: 2px 8px;
            border-radius: 4px;
            font-size: 0.8em;
        }

        .badge-gw {
            background-color: rgba(155, 89, 182, 0.2);
            color: #9b59b6;
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
            color: #e74c3c;
        }
        
        .risk-badge.high {
            background-color: rgba(230, 126, 34, 0.2);
            color: #e67e22;
        }
        
        .risk-badge.medium {
            background-color: rgba(241, 196, 15, 0.2);
            color: #f1c40f;
        }
        
        .no-nsg-badge {
            background-color: rgba(231, 76, 60, 0.15);
            color: #e74c3c;
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
            color: #e74c3c;
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
            color: #e74c3c;
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
                <p><strong>Generated:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
            </div>
        </div>
        
        <div class="summary-grid">
            <div class="summary-card" style="border-top: 3px solid #3498db;">
                <div class="summary-card-label">VNets</div>
                <div class="summary-card-value">$totalVnets</div>
            </div>
            <div class="summary-card" style="border-top: 3px solid #2ecc71;">
                <div class="summary-card-label">Subnets</div>
                <div class="summary-card-value">$totalSubnets</div>
            </div>
            <div class="summary-card" style="border-top: 3px solid #f1c40f;">
                <div class="summary-card-label">NSGs</div>
                <div class="summary-card-value">$totalNsgs</div>
            </div>
            <div class="summary-card" style="border-top: 3px solid #9b59b6;">
                <div class="summary-card-label">Gateways</div>
                <div class="summary-card-value">$totalGateways</div>
            </div>
            <div class="summary-card" style="border-top: 3px solid #16a085;">
                <div class="summary-card-label">Peerings</div>
                <div class="summary-card-value">$totalPeerings</div>
            </div>
            <div class="summary-card" style="border-top: 3px solid #95a5a6;">
                <div class="summary-card-label">Devices</div>
                <div class="summary-card-value">$totalDevices</div>
            </div>
            <div class="summary-card" style="border-top: 3px solid #e74c3c;">
                <div class="summary-card-label">Security Risks</div>
                <div class="summary-card-value" style="color: $(if ($totalRisks -gt 0) { '#e74c3c' } else { '#2ecc71' });">$totalRisks</div>
            </div>
        </div>
"@

        # Add expandable risk summary if there are risks
        if ($totalRisks -gt 0) {
            # Sort risks by severity
            $severityOrder = @{ "Critical" = 1; "High" = 2; "Medium" = 3 }
            $sortedAllRisks = $allRisks | Sort-Object { $severityOrder[$_.Severity] }, Priority
            
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
                $destination = if ($risk.Destination) { Encode-Html $risk.Destination } else { "<span style='color:var(--text-muted);'>Any</span>" }
                $html += @"
                        <tr class="risk-row $severityLower">
                            <td><span class="risk-badge $severityLower">$(Encode-Html $risk.Severity)</span></td>
                            <td>$(Encode-Html $risk.NsgName)</td>
                            <td>$(Encode-Html $risk.VNetName)</td>
                            <td>$(Encode-Html $risk.SubnetName)</td>
                            <td>$(Encode-Html $risk.RuleName)</td>
                            <td>$(Encode-Html $risk.Port) ($(Encode-Html $risk.PortName))</td>
                            <td>$(Encode-Html $risk.Source)</td>
                            <td>$destination</td>
                            <td>$(Encode-Html $risk.Description)</td>
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

        # Network Diagram Section
        $html += @"

        <div class="network-diagram-container">
            <div class="diagram-header">
                <h2>Network Topology</h2>
                <div style="display: flex; align-items: center; gap: 20px;">
                    <div class="diagram-legend">
                        <div class="legend-item"><div class="legend-dot" style="background: #3498db;"></div> VNet (color by subscription)</div>
                        <div class="legend-item"><div class="legend-dot" style="background: #95a5a6;"></div> VNet (Unknown Subscription)</div>
                        <div class="legend-item"><div class="legend-diamond"></div> Gateway</div>
                        <div class="legend-item"><div class="legend-dot" style="background: #34495e; border-radius: 0;"></div> On-Premises</div>
                        <div class="legend-item"><div class="legend-line peering"></div> Peering</div>
                        <div class="legend-item"><div class="legend-line s2s"></div> S2S Tunnel</div>
                    </div>
                    <div class="diagram-controls">
                        <button class="diagram-btn" id="resetLayout">Reset Layout</button>
                        <button class="diagram-btn" id="togglePhysics">Disable Physics</button>
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
                        <div class="legend-item"><div class="legend-dot" style="background: #3498db;"></div> VNet (color by subscription)</div>
                        <div class="legend-item"><div class="legend-dot" style="background: #95a5a6;"></div> VNet (Unknown Subscription)</div>
                        <div class="legend-item"><div class="legend-diamond"></div> Gateway</div>
                        <div class="legend-item"><div class="legend-dot" style="background: #34495e; border-radius: 0;"></div> On-Premises</div>
                        <div class="legend-item"><div class="legend-line peering"></div> Peering</div>
                        <div class="legend-item"><div class="legend-line s2s"></div> S2S Tunnel</div>
                    </div>
                    <div class="diagram-controls">
                        <button class="diagram-btn" id="resetLayoutFullscreen">Reset Layout</button>
                        <button class="diagram-btn" id="togglePhysicsFullscreen">Disable Physics</button>
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
            $html += "                    <option value=`"$subId`">$(Encode-Html $subName)</option>`n"
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

        # Generate VNets grouped by subscription
        foreach ($subId in $subscriptions.Keys) {
            $sub = $subscriptions[$subId]
            $subColor = $subColorMap[$subId]
            $subVnetCount = $sub.VNets.Count
            $subDeviceCount = 0
            foreach ($v in $sub.VNets) {
                foreach ($s in $v.Subnets) {
                    $subDeviceCount += $s.ConnectedDevices.Count
                }
            }
            
            $html += @"
            <div class="subscription-section" data-subscription-id="$subId">
                <div class="subscription-header" onclick="toggleSubscription('sub-$subId')">
                    <span class="expand-icon" id="icon-sub-$subId"></span>
                    <div class="subscription-color-dot" style="background-color: $subColor;"></div>
                    <span class="subscription-title">$(Encode-Html $sub.Name)</span>
                    <span class="subscription-stats">$subVnetCount VNets | $subDeviceCount Devices</span>
                </div>
                <div class="subscription-content" id="sub-$subId" style="display: block;">
"@

            foreach ($vnet in $sub.VNets) {
                $vnetId = "vnet-" + [Guid]::NewGuid().ToString()
                $vnetSearchText = "$($vnet.Name) $($vnet.AddressSpace) $($vnet.Location) $($vnet.SubscriptionName)".ToLower()
                
                # Count risks for this VNet
                $vnetCritical = 0
                $vnetHigh = 0
                $vnetMedium = 0
                foreach ($subnet in $vnet.Subnets) {
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

                $html += @"
                <div class="vnet-box" data-searchable="$vnetSearchText" data-vnet-name="$(Encode-Html $vnet.Name)">
                    <div class="vnet-header" onclick="toggleVNet('$vnetId')">
                        <div class="vnet-title">
                            <span class="expand-icon" id="icon-$vnetId"></span>
                            $(Encode-Html $vnet.Name)
                            <span style="font-weight:normal; color:var(--text-secondary); font-size:0.9em; margin-left:10px;">$(Encode-Html $vnet.AddressSpace)</span>
                        </div>
                        <div class="vnet-meta">
                            <span>$(Encode-Html $vnet.Location)</span>
                            <span>Subnets: $($vnet.Subnets.Count)</span>
                            <span>Peerings: $($vnet.Peerings.Count)</span>
"@
                if ($vnetCritical -gt 0 -or $vnetHigh -gt 0 -or $vnetMedium -gt 0) {
                    $html += "                            <span>"
                    if ($vnetCritical -gt 0) { $html += "<span class='risk-badge critical'>$vnetCritical</span>" }
                    if ($vnetHigh -gt 0) { $html += "<span class='risk-badge high'>$vnetHigh</span>" }
                    if ($vnetMedium -gt 0) { $html += "<span class='risk-badge medium'>$vnetMedium</span>" }
                    $html += "</span>"
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
                        # Show S2S connections
                        if ($gw.Connections -and $gw.Connections.Count -gt 0) {
                            $html += @"
                                <div style="margin-top:8px; padding-top:8px; border-top:1px solid rgba(155, 89, 182, 0.3);">
                                    <div style="font-size:0.85em; color:var(--text-secondary); margin-bottom:4px;"><strong>S2S Connections:</strong></div>
"@
                            foreach ($conn in $gw.Connections) {
                                $statusColor = if ($conn.ConnectionStatus -eq "Connected") { "#2ecc71" } else { "#e74c3c" }
                                $remoteType = if ($conn.RemoteNetwork -and $conn.RemoteNetwork.Type -eq "OnPremises") { "On-Premises" } else { "VNet" }
                                $html += @"
                                    <div style="margin-left:12px; margin-bottom:4px; font-size:0.85em;">
                                        <span style="color: $statusColor; font-weight: bold; margin-right: 4px;">*</span> $(Encode-Html $conn.RemoteNetworkName) ($remoteType)
                                        <span style="color:var(--text-secondary); margin-left:8px;">- $(Encode-Html $conn.ConnectionStatus)</span>
"@
                                if ($conn.RemoteNetwork -and $conn.RemoteNetwork.AddressSpace) {
                                    $html += " <span style='color:var(--text-muted);'>($(Encode-Html $conn.RemoteNetwork.AddressSpace))</span>"
                                }
                                $html += @"
                                    </div>
"@
                            }
                            $html += "                                </div>`n"
                        }
                        $html += @"
                            </div>
"@
                    }
                    $html += "                        </div>`n"
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
                        $nsgBadgeHtml = "<span class='badge-nsg'>NSG: $(Encode-Html $subnet.NsgName)</span>"
                        
                        # Add risk badges if present
                        if ($subnet.NsgRisks -and $subnet.NsgRisks.Count -gt 0) {
                            $subnetCritical = @($subnet.NsgRisks | Where-Object { $_.Severity -eq "Critical" }).Count
                            $subnetHigh = @($subnet.NsgRisks | Where-Object { $_.Severity -eq "High" }).Count
                            $subnetMedium = @($subnet.NsgRisks | Where-Object { $_.Severity -eq "Medium" }).Count
                            
                            if ($subnetCritical -gt 0) { $nsgBadgeHtml += "<span class='risk-badge critical'>$subnetCritical</span>" }
                            if ($subnetHigh -gt 0) { $nsgBadgeHtml += "<span class='risk-badge high'>$subnetHigh</span>" }
                            if ($subnetMedium -gt 0) { $nsgBadgeHtml += "<span class='risk-badge medium'>$subnetMedium</span>" }
                        }
                    } else {
                        $nsgBadgeHtml = "<span class='no-nsg-badge'>No NSG</span>"
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
                        $html += "                                <div style='color:var(--text-secondary); font-style:italic; padding:5px;'>No connected devices</div>`n"
                    }
                    
                    # Route Table
                    if ($subnet.RouteTableName) {
                        $html += "                                <div style='margin-top:10px; font-size:0.9em;'><strong>Route Table:</strong> $(Encode-Html $subnet.RouteTableName)</div>`n"
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
                            $destination = if ($risk.Destination) { Encode-Html $risk.Destination } else { "<span style='color:var(--text-muted);'>Any</span>" }
                            $html += @"
                                            <tr class="risk-row $severityLower">
                                                <td><span class="risk-badge $severityLower">$(Encode-Html $risk.Severity)</span></td>
                                                <td>$(Encode-Html $risk.RuleName)</td>
                                                <td>$(Encode-Html $risk.Port) ($(Encode-Html $risk.PortName))</td>
                                                <td>$(Encode-Html $risk.Source)</td>
                                                <td>$destination</td>
                                                <td>$(Encode-Html $risk.Description)</td>
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
                        # Find the remote VNet to get its subscription
                        $remoteVnet = $NetworkInventory | Where-Object { $_.Name -eq $peering.RemoteVnetName } | Select-Object -First 1
                        $remoteSubscription = if ($remoteVnet) { $remoteVnet.SubscriptionName } else { "Unknown" }
                        
                        $stateColor = if ($peering.State -eq "Connected") { "#2ecc71" } else { "#e74c3c" }
                        $html += @"
                                    <tr>
                                        <td>$(Encode-Html $peering.RemoteVnetName)</td>
                                        <td>$(Encode-Html $remoteSubscription)</td>
                                        <td style="color: $stateColor;">$(Encode-Html $peering.State)</td>
                                        <td>Fwd: $($peering.AllowForwardedTraffic)</td>
                                        <td>RemoteGW: $($peering.UseRemoteGateways)</td>
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
        $nodeIdMap = @{}  # Map VNet name to node ID
        $gwNodeIdMap = @{}  # Map Gateway ID to node ID
        $nodeCounter = 1
        $processedPeerings = [System.Collections.Generic.HashSet[string]]::new()
        $processedS2S = [System.Collections.Generic.HashSet[string]]::new()
        
        # Group VNets by subscription for better layout
        $vnetGroups = @{}
        foreach ($vnet in $NetworkInventory) {
            $subId = $vnet.SubscriptionId
            if (-not $vnetGroups.ContainsKey($subId)) {
                $vnetGroups[$subId] = [System.Collections.Generic.List[PSObject]]::new()
            }
            $vnetGroups[$subId].Add($vnet)
        }
        
        # Create nodes grouped by subscription
        foreach ($subId in $vnetGroups.Keys) {
            # Ensure subscription color is assigned (build color map if missing)
            if (-not $subColorMap.ContainsKey($subId)) {
                $colorIndex = $subColorMap.Count
                $subColorMap[$subId] = $subscriptionColors[$colorIndex % $subscriptionColors.Count]
            }
            $subColor = $subColorMap[$subId]
            
            foreach ($vnet in $vnetGroups[$subId]) {
                $nodeId = $nodeCounter++
                $nodeIdMap[$vnet.Name] = $nodeId
                $deviceCount = 0
                foreach ($s in $vnet.Subnets) { $deviceCount += $s.ConnectedDevices.Count }
                
                $tooltip = "$($vnet.Name)\nSubscription: $($vnet.SubscriptionName)\nAddress: $($vnet.AddressSpace)\nLocation: $($vnet.Location)\nSubnets: $($vnet.Subnets.Count)\nDevices: $deviceCount"
                # Use subscription color for each VNet
                $nodesJson.Add("{ id: $nodeId, label: `"$($vnet.Name)`", title: `"$tooltip`", color: `"$subColor`", shape: `"dot`", size: 25, font: { color: `"#e8e8e8`", size: 16 }, group: `"$subId`" }")
                
                # Add gateway nodes
                foreach ($gw in $vnet.Gateways) {
                    $gwNodeId = $nodeCounter++
                    $gwNodeIdMap[$gw.Id] = $gwNodeId
                    $gwTooltip = "$($gw.Name)\nType: $($gw.Type)\nSKU: $($gw.Sku)\nVPN: $($gw.VpnType)"
                    $nodesJson.Add("{ id: $gwNodeId, label: `"$($gw.Name)`", title: `"$gwTooltip`", color: `"#9b59b6`", shape: `"diamond`", size: 15, font: { color: `"#e8e8e8`", size: 16 }, group: `"$subId`" }")
                    $edgesJson.Add("{ from: $nodeId, to: $gwNodeId, color: { color: `"#9b59b6`" }, width: 2, length: 50 }")
                }
            }
        }
        
        # Create nodes for remote VNets that aren't in NetworkInventory (unknown subscriptions)
        $unknownVnetColor = "#95a5a6"  # Gray color for unknown VNets
        foreach ($vnet in $NetworkInventory) {
            foreach ($peering in $vnet.Peerings) {
                $remoteVnetName = $peering.RemoteVnetName
                if ($remoteVnetName -and -not $nodeIdMap.ContainsKey($remoteVnetName)) {
                    # This remote VNet is not in our inventory - create a node for it
                    $nodeId = $nodeCounter++
                    $nodeIdMap[$remoteVnetName] = $nodeId
                    $tooltip = "$remoteVnetName\nSubscription: Unknown\n(No access to this subscription)"
                    $nodesJson.Add("{ id: $nodeId, label: `"$remoteVnetName`", title: `"$tooltip`", color: `"$unknownVnetColor`", shape: `"dot`", size: 25, font: { color: `"#e8e8e8`", size: 16 }, group: `"unknown`" }")
                }
            }
        }
        
        # Add peering edges
        foreach ($vnet in $NetworkInventory) {
            $fromId = $nodeIdMap[$vnet.Name]
            foreach ($peering in $vnet.Peerings) {
                $remoteVnetName = $peering.RemoteVnetName
                $toId = $nodeIdMap[$remoteVnetName]
                
                if ($toId) {
                    # Create a unique key for this peering pair to avoid duplicates
                    $peeringKey = if ($fromId -lt $toId) { "$fromId-$toId" } else { "$toId-$fromId" }
                    
                    if (-not $processedPeerings.Contains($peeringKey)) {
                        [void]$processedPeerings.Add($peeringKey)
                        $edgeColor = if ($peering.State -eq "Connected") { "#2ecc71" } else { "#e74c3c" }
                        # Peerings are always dashed to match legend (---)
                        $edgesJson.Add("{ from: $fromId, to: $toId, color: { color: `"$edgeColor`" }, dashes: false, width: 2, title: `"Peering: $($peering.State)`" }")
                    }
                }
            }
        }
        
        # Add S2S tunnel edges and on-premises nodes
        foreach ($vnet in $NetworkInventory) {
            foreach ($gw in $vnet.Gateways) {
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
                                    $onPremTooltip = "$remoteName\nType: On-Premises Network\nAddress Space: $($conn.RemoteNetwork.AddressSpace)\nGateway IP: $($conn.RemoteNetwork.GatewayIpAddress)"
                                    $nodesJson.Add("{ id: $onPremNodeId, label: `"$remoteName`", title: `"$onPremTooltip`", color: `"#34495e`", shape: `"box`", size: 20, font: { color: `"#ffffff`", size: 16 } }")
                                    
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

        $nodesJsonString = $nodesJson -join ",`n                "
        $edgesJsonString = $edgesJson -join ",`n                "

        $html += @"
        </div>
        
        <div class="footer">
            <p>Report generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
        </div>
    </div>

    <script>
        // Initialize vis.js network diagram
        var nodes = new vis.DataSet([
                $nodesJsonString
        ]);
        
        var edges = new vis.DataSet([
                $edgesJsonString
        ]);
        
        var container = document.getElementById('network-diagram');
        var data = { nodes: nodes, edges: edges };
        var options = {
            layout: {
                improvedLayout: true,
                hierarchical: {
                    enabled: false,
                    direction: 'UD',
                    sortMethod: 'directed'
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
                    type: 'continuous',
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
        
        var network = new vis.Network(container, data, options);
        
        // Track physics state
        var physicsEnabled = true;
        
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
            options.physics.enabled = physicsEnabled;
            network.setOptions(options);
            this.textContent = physicsEnabled ? 'Disable Physics' : 'Enable Physics';
            
            // If disabling physics, fix all nodes in current positions
            if (!physicsEnabled) {
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
            } else {
                // If enabling physics, unfix all nodes
                var allNodeIds = nodes.getIds();
                allNodeIds.forEach(function(nodeId) {
                    nodes.update({
                        id: nodeId,
                        fixed: {
                            x: false,
                            y: false
                        }
                    });
                });
            }
        });
        
        // Reset layout button
        document.getElementById('resetLayout').addEventListener('click', function() {
            // Unfix all nodes
            var allNodeIds = nodes.getIds();
            allNodeIds.forEach(function(nodeId) {
                nodes.update({
                    id: nodeId,
                    fixed: {
                        x: false,
                        y: false
                    }
                });
            });
            
            // Re-enable physics temporarily to reset layout
            options.physics.enabled = true;
            network.setOptions(options);
            physicsEnabled = true;
            document.getElementById('togglePhysics').textContent = 'Disable Physics';
            
            // Auto-disable after stabilization
            network.once('stabilizationEnd', function() {
                options.physics.enabled = false;
                network.setOptions(options);
                physicsEnabled = false;
                document.getElementById('togglePhysics').textContent = 'Enable Physics';
            });
        });
        
        // Fullscreen functionality
        var networkFullscreen = null;
        var physicsEnabledFullscreen = true;
        var optionsFullscreen = null;
        
        function initializeFullscreenDiagram() {
            if (networkFullscreen) {
                return; // Already initialized
            }
            
            var containerFullscreen = document.getElementById('network-diagram-fullscreen');
            var dataFullscreen = { nodes: nodes, edges: edges };
            optionsFullscreen = JSON.parse(JSON.stringify(options)); // Clone options
            
            networkFullscreen = new vis.Network(containerFullscreen, dataFullscreen, optionsFullscreen);
            physicsEnabledFullscreen = physicsEnabled;
            
            // Sync physics state
            if (!physicsEnabled) {
                optionsFullscreen.physics.enabled = false;
                networkFullscreen.setOptions(optionsFullscreen);
                physicsEnabledFullscreen = false;
                document.getElementById('togglePhysicsFullscreen').textContent = 'Enable Physics';
            }
            
            // Fix all nodes after stabilization
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
            
            // Sync positions from main diagram when opening fullscreen
            var allNodeIds = nodes.getIds();
            var positions = network.getPositions(allNodeIds);
            networkFullscreen.setPositions(positions);
        }
        
        // Open fullscreen
        document.getElementById('openFullscreen').addEventListener('click', function() {
            // Show overlay first so container has dimensions
            document.getElementById('diagram-fullscreen').classList.add('active');
            
            // Initialize after a short delay to ensure rendering
            setTimeout(function() {
                initializeFullscreenDiagram();
                
                if (networkFullscreen) {
                    // Sync positions from main diagram
                    var allNodeIds = nodes.getIds();
                    var positions = network.getPositions(allNodeIds);
                    networkFullscreen.setPositions(positions);
                    
                    // Force redraw and fit
                    networkFullscreen.redraw();
                    networkFullscreen.fit();
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
            optionsFullscreen.physics.enabled = physicsEnabledFullscreen;
            networkFullscreen.setOptions(optionsFullscreen);
            this.textContent = physicsEnabledFullscreen ? 'Disable Physics' : 'Enable Physics';
            
            if (!physicsEnabledFullscreen) {
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
            } else {
                var allNodeIds = nodes.getIds();
                allNodeIds.forEach(function(nodeId) {
                    nodes.update({
                        id: nodeId,
                        fixed: {
                            x: false,
                            y: false
                        }
                    });
                });
            }
        });
        
        // Reset layout in fullscreen
        document.getElementById('resetLayoutFullscreen').addEventListener('click', function() {
            if (!networkFullscreen || !optionsFullscreen) return;
            
            var allNodeIds = nodes.getIds();
            allNodeIds.forEach(function(nodeId) {
                nodes.update({
                    id: nodeId,
                    fixed: {
                        x: false,
                        y: false
                    }
                });
            });
            
            optionsFullscreen.physics.enabled = true;
            networkFullscreen.setOptions(optionsFullscreen);
            physicsEnabledFullscreen = true;
            document.getElementById('togglePhysicsFullscreen').textContent = 'Disable Physics';
            
            networkFullscreen.once('stabilizationEnd', function() {
                optionsFullscreen.physics.enabled = false;
                networkFullscreen.setOptions(optionsFullscreen);
                physicsEnabledFullscreen = false;
                document.getElementById('togglePhysicsFullscreen').textContent = 'Enable Physics';
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
            document.querySelectorAll('.vnet-content, .subnet-content').forEach(el => el.style.display = 'none');
            document.querySelectorAll('.vnet-header, .subnet-header').forEach(el => el.classList.remove('expanded'));
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
