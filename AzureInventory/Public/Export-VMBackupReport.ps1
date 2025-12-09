<#
.SYNOPSIS
    Generates an HTML report for VM backup status across subscriptions.

.DESCRIPTION
    Creates an interactive HTML report showing all VMs and their backup status,
    power state, vault information, and last backup times.

.PARAMETER VMInventory
    Array of VM inventory objects from Get-VirtualMachineFindings.

.PARAMETER OutputPath
    Path for the HTML report output.

.PARAMETER TenantId
    Azure Tenant ID for display in report.

.OUTPUTS
    String path to the generated HTML report.
#>
function Export-VMBackupReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[PSObject]]$VMInventory,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        
        [string]$TenantId = "Unknown"
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    
    # Calculate statistics
    $totalVMs = $VMInventory.Count
    $protectedVMs = @($VMInventory | Where-Object { $_.BackupEnabled }).Count
    $unprotectedVMs = $totalVMs - $protectedVMs
    $runningVMs = @($VMInventory | Where-Object { $_.PowerState -eq 'running' }).Count
    $stoppedVMs = @($VMInventory | Where-Object { $_.PowerState -eq 'deallocated' -or $_.PowerState -eq 'stopped' }).Count
    $otherStateVMs = $totalVMs - $runningVMs - $stoppedVMs
    $protectionRate = if ($totalVMs -gt 0) { [math]::Round(($protectedVMs / $totalVMs) * 100, 1) } else { 0 }
    
    # Group by subscription for summary
    $subscriptionSummary = $VMInventory | Group-Object SubscriptionName | ForEach-Object {
        $subVMs = $_.Group
        [PSCustomObject]@{
            Name = $_.Name
            Total = $_.Count
            Protected = @($subVMs | Where-Object { $_.BackupEnabled }).Count
            Unprotected = @($subVMs | Where-Object { -not $_.BackupEnabled }).Count
            Running = @($subVMs | Where-Object { $_.PowerState -eq 'running' }).Count
        }
    }
    
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VM Backup Overview</title>
    <style>
        :root {
            --bg-primary: #0f0f1a;
            --bg-secondary: #1a1a2e;
            --bg-surface: #252542;
            --bg-hover: #2d2d4a;
            --text-primary: #e8e8e8;
            --text-secondary: #b8b8b8;
            --text-muted: #888;
            --accent-green: #00d26a;
            --accent-red: #ff6b6b;
            --accent-yellow: #feca57;
            --accent-blue: #54a0ff;
            --accent-purple: #9b59b6;
            --border-color: #3d3d5c;
        }
        
        * { box-sizing: border-box; margin: 0; padding: 0; }
        
        body {
            font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            line-height: 1.6;
            padding: 0;
        }
        
        /* Navigation */
        .report-nav {
            background: var(--bg-secondary);
            padding: 15px 30px;
            display: flex;
            gap: 10px;
            align-items: center;
            border-bottom: 1px solid var(--border-color);
            position: sticky;
            top: 0;
            z-index: 100;
        }
        
        .nav-brand {
            font-weight: 600;
            font-size: 1.1rem;
            color: var(--accent-blue);
            margin-right: 30px;
        }
        
        .nav-link {
            color: var(--text-muted);
            text-decoration: none;
            padding: 8px 16px;
            border-radius: 6px;
            transition: all 0.2s ease;
            font-size: 0.9rem;
        }
        
        .nav-link:hover {
            background: var(--bg-surface);
            color: var(--text-primary);
        }
        
        .nav-link.active {
            background: var(--accent-blue);
            color: white;
        }
        
        /* Main content */
        .container {
            max-width: 1600px;
            margin: 0 auto;
            padding: 30px;
        }
        
        .page-header {
            margin-bottom: 30px;
        }
        
        .page-header h1 {
            font-size: 2rem;
            font-weight: 600;
            margin-bottom: 8px;
        }
        
        .page-header .subtitle {
            color: var(--text-muted);
            font-size: 0.9rem;
        }
        
        /* Summary Cards */
        .summary-cards {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        
        .summary-card {
            background: var(--bg-surface);
            padding: 24px;
            border-radius: 12px;
            text-align: center;
            border: 1px solid var(--border-color);
            transition: transform 0.2s ease;
        }
        
        .summary-card:hover {
            transform: translateY(-2px);
        }
        
        .summary-card .value {
            font-size: 2.5rem;
            font-weight: 700;
            line-height: 1.2;
        }
        
        .summary-card .label {
            color: var(--text-muted);
            font-size: 0.85rem;
            margin-top: 8px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        
        .summary-card.total .value { color: var(--accent-blue); }
        .summary-card.protected .value { color: var(--accent-green); }
        .summary-card.unprotected .value { color: var(--accent-red); }
        .summary-card.running .value { color: var(--accent-blue); }
        .summary-card.stopped .value { color: var(--accent-yellow); }
        .summary-card.rate .value { color: var(--accent-purple); }
        
        /* Progress bar */
        .protection-bar {
            background: var(--bg-surface);
            padding: 20px 24px;
            border-radius: 12px;
            margin-bottom: 30px;
            border: 1px solid var(--border-color);
        }
        
        .protection-bar-label {
            display: flex;
            justify-content: space-between;
            margin-bottom: 10px;
            font-size: 0.9rem;
        }
        
        .protection-bar-track {
            height: 12px;
            background: var(--bg-hover);
            border-radius: 6px;
            overflow: hidden;
        }
        
        .protection-bar-fill {
            height: 100%;
            background: linear-gradient(90deg, var(--accent-green), #00b359);
            border-radius: 6px;
            transition: width 0.5s ease;
        }
        
        /* Filter section */
        .filter-section {
            background: var(--bg-surface);
            padding: 20px 24px;
            border-radius: 12px;
            margin-bottom: 30px;
            border: 1px solid var(--border-color);
            display: flex;
            gap: 15px;
            flex-wrap: wrap;
            align-items: center;
        }
        
        .filter-group {
            display: flex;
            align-items: center;
            gap: 8px;
        }
        
        .filter-group label {
            color: var(--text-muted);
            font-size: 0.85rem;
        }
        
        .filter-group select, .filter-group input {
            background: var(--bg-hover);
            border: 1px solid var(--border-color);
            color: var(--text-primary);
            padding: 8px 12px;
            border-radius: 6px;
            font-size: 0.9rem;
        }
        
        .filter-group input {
            width: 200px;
        }
        
        /* Subscription sections */
        .subscription-section {
            background: var(--bg-surface);
            border-radius: 12px;
            margin-bottom: 20px;
            border: 1px solid var(--border-color);
            overflow: hidden;
        }
        
        .subscription-header {
            background: var(--bg-secondary);
            padding: 16px 24px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            cursor: pointer;
            transition: background 0.2s ease;
        }
        
        .subscription-header:hover {
            background: var(--bg-hover);
        }
        
        .subscription-title {
            font-weight: 600;
            font-size: 1.1rem;
        }
        
        .subscription-stats {
            display: flex;
            gap: 20px;
            font-size: 0.85rem;
        }
        
        .subscription-stats .stat {
            display: flex;
            align-items: center;
            gap: 6px;
        }
        
        .subscription-stats .stat.protected { color: var(--accent-green); }
        .subscription-stats .stat.unprotected { color: var(--accent-red); }
        .subscription-stats .stat.running { color: var(--accent-blue); }
        
        .subscription-content {
            padding: 0;
        }
        
        /* Table */
        .vm-table {
            width: 100%;
            border-collapse: collapse;
        }
        
        .vm-table th {
            background: var(--bg-hover);
            padding: 12px 16px;
            text-align: left;
            font-weight: 600;
            font-size: 0.8rem;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            color: var(--text-muted);
            border-bottom: 1px solid var(--border-color);
        }
        
        .vm-table td {
            padding: 14px 16px;
            border-bottom: 1px solid var(--border-color);
            font-size: 0.9rem;
        }
        
        .vm-table tr:last-child td {
            border-bottom: none;
        }
        
        .vm-table tr:hover td {
            background: var(--bg-hover);
        }
        
        .vm-table tr.hidden {
            display: none;
        }
        
        /* Status badges */
        .status-badge {
            display: inline-block;
            padding: 4px 10px;
            border-radius: 4px;
            font-size: 0.8rem;
            font-weight: 500;
        }
        
        .status-badge.protected {
            background: rgba(0, 210, 106, 0.15);
            color: var(--accent-green);
        }
        
        .status-badge.unprotected {
            background: rgba(255, 107, 107, 0.15);
            color: var(--accent-red);
        }
        
        .status-badge.running {
            background: rgba(84, 160, 255, 0.15);
            color: var(--accent-blue);
        }
        
        .status-badge.deallocated, .status-badge.stopped {
            background: rgba(254, 202, 87, 0.15);
            color: var(--accent-yellow);
        }
        
        .status-badge.unknown {
            background: rgba(136, 136, 136, 0.15);
            color: var(--text-muted);
        }
        
        .status-badge.healthy {
            background: rgba(0, 210, 106, 0.15);
            color: var(--accent-green);
        }
        
        .status-badge.warning {
            background: rgba(254, 202, 87, 0.15);
            color: var(--accent-yellow);
        }
        
        .os-badge {
            display: inline-block;
            padding: 2px 8px;
            border-radius: 4px;
            font-size: 0.75rem;
            background: var(--bg-hover);
            color: var(--text-secondary);
        }
        
        .vault-link {
            color: var(--accent-blue);
            text-decoration: none;
        }
        
        .vault-link:hover {
            text-decoration: underline;
        }
        
        .text-muted {
            color: var(--text-muted);
        }
        
        /* Responsive */
        @media (max-width: 768px) {
            .container { padding: 15px; }
            .summary-cards { grid-template-columns: repeat(2, 1fr); }
            .filter-section { flex-direction: column; align-items: stretch; }
            .subscription-stats { flex-wrap: wrap; gap: 10px; }
        }
    </style>
</head>
<body>
    <nav class="report-nav">
        <span class="nav-brand">Azure Audit Reports</span>
        <a href="index.html" class="nav-link">Dashboard</a>
        <a href="security.html" class="nav-link">Security Audit</a>
        <a href="vm-backup.html" class="nav-link active">VM Backup</a>
    </nav>
    
    <div class="container">
        <div class="page-header">
            <h1>VM Backup Overview</h1>
            <p class="subtitle">Generated: $timestamp | Tenant: $TenantId</p>
        </div>
        
        <div class="summary-cards">
            <div class="summary-card total">
                <div class="value">$totalVMs</div>
                <div class="label">Total VMs</div>
            </div>
            <div class="summary-card protected">
                <div class="value">$protectedVMs</div>
                <div class="label">Backup Protected</div>
            </div>
            <div class="summary-card unprotected">
                <div class="value">$unprotectedVMs</div>
                <div class="label">Unprotected</div>
            </div>
            <div class="summary-card running">
                <div class="value">$runningVMs</div>
                <div class="label">Running</div>
            </div>
            <div class="summary-card stopped">
                <div class="value">$stoppedVMs</div>
                <div class="label">Stopped</div>
            </div>
            <div class="summary-card rate">
                <div class="value">$protectionRate%</div>
                <div class="label">Protection Rate</div>
            </div>
        </div>
        
        <div class="protection-bar">
            <div class="protection-bar-label">
                <span>Backup Protection Coverage</span>
                <span>$protectedVMs of $totalVMs VMs protected ($protectionRate%)</span>
            </div>
            <div class="protection-bar-track">
                <div class="protection-bar-fill" style="width: $protectionRate%"></div>
            </div>
        </div>
        
        <div class="filter-section">
            <div class="filter-group">
                <label for="searchFilter">Search:</label>
                <input type="text" id="searchFilter" placeholder="VM name, resource group...">
            </div>
            <div class="filter-group">
                <label for="backupFilter">Backup Status:</label>
                <select id="backupFilter">
                    <option value="all">All</option>
                    <option value="protected">Protected</option>
                    <option value="unprotected">Unprotected</option>
                </select>
            </div>
            <div class="filter-group">
                <label for="powerFilter">Power State:</label>
                <select id="powerFilter">
                    <option value="all">All</option>
                    <option value="running">Running</option>
                    <option value="deallocated">Stopped/Deallocated</option>
                </select>
            </div>
            <div class="filter-group">
                <label for="subscriptionFilter">Subscription:</label>
                <select id="subscriptionFilter">
                    <option value="all">All Subscriptions</option>
"@

    # Add subscription options
    foreach ($sub in ($VMInventory | Select-Object -ExpandProperty SubscriptionName -Unique | Sort-Object)) {
        $html += "                    <option value=`"$($sub.ToLower())`">$sub</option>`n"
    }
    
    $html += @"
                </select>
            </div>
        </div>
"@

    # Group VMs by subscription
    $vmsBySubscription = $VMInventory | Group-Object SubscriptionName | Sort-Object Name
    
    foreach ($subGroup in $vmsBySubscription) {
        $subName = $subGroup.Name
        $subVMs = $subGroup.Group
        $subProtected = @($subVMs | Where-Object { $_.BackupEnabled }).Count
        $subUnprotected = $subVMs.Count - $subProtected
        $subRunning = @($subVMs | Where-Object { $_.PowerState -eq 'running' }).Count
        
        $html += @"
        
        <div class="subscription-section" data-subscription="$($subName.ToLower())">
            <div class="subscription-header" onclick="toggleSubscription(this)">
                <span class="subscription-title">$subName</span>
                <div class="subscription-stats">
                    <span class="stat">$($subVMs.Count) VMs</span>
                    <span class="stat protected">&check; $subProtected protected</span>
                    <span class="stat unprotected">&cross; $subUnprotected unprotected</span>
                    <span class="stat running">&bull; $subRunning running</span>
                </div>
            </div>
            <div class="subscription-content">
                <table class="vm-table">
                    <thead>
                        <tr>
                            <th>VM Name</th>
                            <th>Resource Group</th>
                            <th>OS</th>
                            <th>Size</th>
                            <th>Power State</th>
                            <th>Backup Status</th>
                            <th>Vault</th>
                            <th>Policy</th>
                            <th>Last Backup</th>
                            <th>Health</th>
                        </tr>
                    </thead>
                    <tbody>
"@
        
        foreach ($vm in ($subVMs | Sort-Object VMName)) {
            $powerClass = switch ($vm.PowerState) {
                'running' { 'running' }
                'deallocated' { 'deallocated' }
                'stopped' { 'stopped' }
                default { 'unknown' }
            }
            $backupClass = if ($vm.BackupEnabled) { 'protected' } else { 'unprotected' }
            $backupText = if ($vm.BackupEnabled) { 'Protected' } else { 'Unprotected' }
            $vaultName = if ($vm.VaultName) { $vm.VaultName } else { '-' }
            $policyName = if ($vm.PolicyName) { $vm.PolicyName } else { '-' }
            $lastBackup = if ($vm.LastBackupTime) { $vm.LastBackupTime.ToString('yyyy-MM-dd HH:mm') } else { '-' }
            $healthClass = switch ($vm.HealthStatus) {
                'Healthy' { 'healthy' }
                'Warning' { 'warning' }
                default { 'unknown' }
            }
            $healthText = if ($vm.HealthStatus) { $vm.HealthStatus } else { '-' }
            $osType = if ($vm.OsType) { $vm.OsType } else { 'Unknown' }
            $vmSize = if ($vm.VMSize) { $vm.VMSize } else { '-' }
            $searchableText = "$($vm.VMName) $($vm.ResourceGroup) $vaultName $policyName".ToLower()
            
            $html += @"
                        <tr class="vm-row" 
                            data-searchable="$searchableText"
                            data-backup="$backupClass"
                            data-power="$powerClass">
                            <td><strong>$($vm.VMName)</strong></td>
                            <td>$($vm.ResourceGroup)</td>
                            <td><span class="os-badge">$osType</span></td>
                            <td class="text-muted">$vmSize</td>
                            <td><span class="status-badge $powerClass">$($vm.PowerState)</span></td>
                            <td><span class="status-badge $backupClass">$backupText</span></td>
                            <td>$vaultName</td>
                            <td class="text-muted">$policyName</td>
                            <td>$lastBackup</td>
                            <td><span class="status-badge $healthClass">$healthText</span></td>
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
    
    # Add JavaScript
    $html += @"
    </div>
    
    <script>
        function toggleSubscription(header) {
            const content = header.nextElementSibling;
            content.style.display = content.style.display === 'none' ? 'block' : 'none';
        }
        
        // Filter functionality
        const searchFilter = document.getElementById('searchFilter');
        const backupFilter = document.getElementById('backupFilter');
        const powerFilter = document.getElementById('powerFilter');
        const subscriptionFilter = document.getElementById('subscriptionFilter');
        
        function applyFilters() {
            const searchText = searchFilter.value.toLowerCase();
            const backupValue = backupFilter.value;
            const powerValue = powerFilter.value;
            const subscriptionValue = subscriptionFilter.value;
            
            // Filter subscription sections
            document.querySelectorAll('.subscription-section').forEach(section => {
                const sectionSub = section.getAttribute('data-subscription');
                const subMatch = subscriptionValue === 'all' || sectionSub === subscriptionValue;
                
                if (!subMatch) {
                    section.style.display = 'none';
                    return;
                }
                
                section.style.display = 'block';
                
                // Filter rows within section
                let visibleRows = 0;
                section.querySelectorAll('.vm-row').forEach(row => {
                    const searchable = row.getAttribute('data-searchable');
                    const backup = row.getAttribute('data-backup');
                    const power = row.getAttribute('data-power');
                    
                    const searchMatch = searchText === '' || searchable.includes(searchText);
                    const backupMatch = backupValue === 'all' || backup === backupValue;
                    const powerMatch = powerValue === 'all' || 
                                       (powerValue === 'deallocated' && (power === 'deallocated' || power === 'stopped')) ||
                                       power === powerValue;
                    
                    if (searchMatch && backupMatch && powerMatch) {
                        row.classList.remove('hidden');
                        visibleRows++;
                    } else {
                        row.classList.add('hidden');
                    }
                });
                
                // Hide section if no visible rows
                if (visibleRows === 0) {
                    section.style.display = 'none';
                }
            });
        }
        
        searchFilter.addEventListener('input', applyFilters);
        backupFilter.addEventListener('change', applyFilters);
        powerFilter.addEventListener('change', applyFilters);
        subscriptionFilter.addEventListener('change', applyFilters);
    </script>
</body>
</html>
"@
    
    # Write to file
    $html | Out-File -FilePath $OutputPath -Encoding UTF8
    
    return $OutputPath
}

