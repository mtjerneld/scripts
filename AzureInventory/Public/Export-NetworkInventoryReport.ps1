<#
.SYNOPSIS
    Generates HTML network inventory report.

.DESCRIPTION
    Creates a comprehensive HTML report for network topology.

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
    
    try {
        # Calculate summary metrics
        $totalVnets = $NetworkInventory.Count
        $totalSubnets = 0
        $totalNsgs = 0
        $totalPeerings = 0
        $totalGateways = 0
        $totalDevices = 0
        
        # We need to deduplicate NSGs if we count them from subnets, 
        # but realistically just counting attached NSGs is fine for now, 
        # or we could collect all unique NSG IDs.
        $uniqueNsgIds = [System.Collections.Generic.HashSet[string]]::new()
        
        foreach ($vnet in $NetworkInventory) {
            $totalSubnets += $vnet.Subnets.Count
            $totalPeerings += $vnet.Peerings.Count
            $totalGateways += $vnet.Gateways.Count
            
            foreach ($subnet in $vnet.Subnets) {
                if ($subnet.NsgId) {
                    [void]$uniqueNsgIds.Add($subnet.NsgId)
                }
                $totalDevices += $subnet.ConnectedDevices.Count
            }
        }
        $totalNsgs = $uniqueNsgIds.Count

        # Build HTML
        $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure Network Inventory</title>
    <style type="text/css">
$(Get-ReportStylesheet -IncludeReportSpecific)

        /* Network Specific Styles */
        .topology-tree {
            margin-top: 20px;
        }
        
        .vnet-box {
            background-color: var(--bg-card);
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
        }
        
        .vnet-content {
            padding: 15px;
            display: none; /* Collapsed by default */
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
            padding: 8px;
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
            background-color: rgba(241, 196, 15, 0.2);
            color: #f1c40f;
            padding: 2px 6px;
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
            <div class="summary-card" style="border-top: 3px solid #e67e22;">
                <div class="summary-card-label">Peerings</div>
                <div class="summary-card-value">$totalPeerings</div>
            </div>
            <div class="summary-card" style="border-top: 3px solid #95a5a6;">
                <div class="summary-card-label">Devices</div>
                <div class="summary-card-value">$totalDevices</div>
            </div>
        </div>

        <div class="filter-controls">
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

        foreach ($vnet in $NetworkInventory) {
            $vnetId = "vnet-" + [Guid]::NewGuid().ToString()
            $vnetSearchText = "$($vnet.Name) $($vnet.AddressSpace) $($vnet.Location) $($vnet.SubscriptionName)".ToLower()

            $html += @"
            <div class="vnet-box" data-searchable="$vnetSearchText">
                <div class="vnet-header" onclick="toggleVNet('$vnetId')">
                    <div class="vnet-title">
                        <span class="expand-icon" id="icon-$vnetId"></span>
                        $(Encode-Html $vnet.Name)
                        <span style="font-weight:normal; color:var(--text-secondary); font-size:0.9em; margin-left:10px;">$(Encode-Html $vnet.AddressSpace)</span>
                    </div>
                    <div class="vnet-meta">
                        $(Encode-Html $vnet.Location) | Subnets: $($vnet.Subnets.Count) | Peerings: $($vnet.Peerings.Count)
                    </div>
                </div>
                <div class="vnet-content" id="$vnetId">
                    <!-- Gateways -->
"@
            if ($vnet.Gateways.Count -gt 0) {
                $html += @"
                    <div style="margin-bottom:15px;">
                        <h4 style="margin:5px 0;">Gateways</h4>
"@
                foreach ($gw in $vnet.Gateways) {
                    $html += @"
                        <div style="padding:5px; background:rgba(155, 89, 182, 0.1); border-radius:4px; margin-bottom:5px;">
                            <strong>$(Encode-Html $gw.Name)</strong> <span class="badge-gw">$(Encode-Html $gw.Type)</span>
                            <span style="margin-left:10px; font-size:0.9em;">SKU: $(Encode-Html $gw.Sku) | VPN: $(Encode-Html $gw.VpnType)</span>
                        </div>
"@
                }
                $html += "</div>"
            }

            $html += @"
                    <!-- Subnets -->
                    <h4 style="margin:10px 0;">Subnets</h4>
"@
            foreach ($subnet in $vnet.Subnets) {
                $subnetId = "subnet-" + [Guid]::NewGuid().ToString()
                $nsgBadge = if ($subnet.NsgName) { "<span class='badge-nsg'>NSG: $(Encode-Html $subnet.NsgName)</span>" } else { "<span style='color:red; font-size:0.8em;'>No NSG</span>" }
                
                $html += @"
                    <div class="subnet-box">
                        <div class="subnet-header" onclick="toggleSubnet('$subnetId')">
                            <div>
                                <span class="expand-icon" id="icon-$subnetId"></span>
                                <span class="subnet-title">$(Encode-Html $subnet.Name)</span>
                                <span style="margin-left:10px; color:var(--text-secondary);">$(Encode-Html $subnet.AddressPrefix)</span>
                            </div>
                            <div>
                                $nsgBadge
                                <span style="font-size:0.9em; margin-left:10px;">Devices: $($subnet.ConnectedDevices.Count)</span>
                            </div>
                        </div>
                        <div class="subnet-content" id="$subnetId">
"@
                if ($subnet.ConnectedDevices.Count -gt 0) {
                    $html += @"
                            <table class="device-table">
                                <thead>
                                    <tr>
                                        <th>Name</th>
                                        <th>Private IP</th>
                                        <th>Public IP</th>
                                        <th>Attached To</th>
                                    </tr>
                                </thead>
                                <tbody>
"@
                    foreach ($device in $subnet.ConnectedDevices) {
                        $html += @"
                                    <tr>
                                        <td>$(Encode-Html $device.Name)</td>
                                        <td>$(Encode-Html $device.PrivateIp)</td>
                                        <td>$(Encode-Html $device.PublicIp)</td>
                                        <td>$(Encode-Html $device.VmName)</td>
                                    </tr>
"@
                    }
                    $html += @"
                                </tbody>
                            </table>
"@
                } else {
                    $html += "<div style='color:var(--text-secondary); font-style:italic; padding:5px;'>No connected devices</div>"
                }
                
                # Show Route Table if present
                if ($subnet.RouteTableName) {
                    $html += "<div style='margin-top:5px; font-size:0.9em;'><strong>Route Table:</strong> $(Encode-Html $subnet.RouteTableName)</div>"
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
                                    <th>State</th>
                                    <th>Traffic</th>
                                    <th>Gateway Use</th>
                                </tr>
                            </thead>
                            <tbody>
"@
                foreach ($peering in $vnet.Peerings) {
                     $html += @"
                                <tr>
                                    <td>$(Encode-Html $peering.RemoteVnetName)</td>
                                    <td>$(Encode-Html $peering.State)</td>
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
        
        <div class="footer">
            <p>Report generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
        </div>
    </div>

    <script>
        function toggleVNet(id) {
            const content = document.getElementById(id);
            const icon = document.getElementById('icon-' + id);
            const header = content.previousElementSibling;
            
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
            const icon = document.getElementById('icon-' + id);
            const header = content.previousElementSibling;
             
            // Stop propagation to prevent VNet toggle
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
            document.querySelectorAll('.vnet-content, .subnet-content').forEach(el => el.style.display = 'block');
            document.querySelectorAll('.vnet-header, .subnet-header').forEach(el => el.classList.add('expanded'));
        });

        document.getElementById('collapseAll').addEventListener('click', function() {
            document.querySelectorAll('.vnet-content, .subnet-content').forEach(el => el.style.display = 'none');
            document.querySelectorAll('.vnet-header, .subnet-header').forEach(el => el.classList.remove('expanded'));
        });

        // Search functionality
        document.getElementById('searchFilter').addEventListener('keyup', function() {
            const filter = this.value.toLowerCase();
            const vnets = document.querySelectorAll('.vnet-box');
            
            vnets.forEach(vnet => {
                const searchable = vnet.getAttribute('data-searchable');
                // Also search inside text content to catch subnets/devices
                const content = vnet.textContent.toLowerCase();
                
                if (searchable.includes(filter) || content.includes(filter)) {
                    vnet.style.display = '';
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
        
        return @{
            OutputPath = $OutputPath
            VNetCount = $totalVnets
            DeviceCount = $totalDevices
        }
    }
    catch {
        Write-Error "Failed to generate network report: $_"
        throw
    }
}

