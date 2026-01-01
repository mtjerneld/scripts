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
    
    # Calculate metadata for display
    $subscriptionCount = ($VMInventory | Select-Object -ExpandProperty SubscriptionName -Unique).Count
    
    # Calculate statistics
    $totalVMs = $VMInventory.Count
    $protectedVMs = @($VMInventory | Where-Object { $_.BackupEnabled }).Count
    $unprotectedVMs = $totalVMs - $protectedVMs
    $protectionRate = if ($totalVMs -gt 0) { [math]::Round(($protectedVMs / $totalVMs) * 100, 1) } else { 0 }
    
    # Calculate VMs with last backup >48 hours ago
    $cutoffTime = (Get-Date).AddHours(-48)
    $oldBackups = @($VMInventory | Where-Object { 
        $_.BackupEnabled -and 
        $_.LastBackupTime -and 
        $_.LastBackupTime -lt $cutoffTime 
    }).Count
    
    # Calculate backup issues (HealthStatus != 'Passed' OR LastBackupStatus != 'Completed')
    # Note: Only 'Passed' is considered OK, everything else (Failed, Action required, null, etc.) is an issue
    $backupIssues = @($VMInventory | Where-Object { 
        $_.BackupEnabled -and (
            (-not $_.HealthStatus -or $_.HealthStatus -ne 'Passed') -or
            ($_.LastBackupStatus -and $_.LastBackupStatus -ne 'Completed')
        )
    }).Count
    
    # Get unique HealthStatus values for filter
    $healthStatuses = @($VMInventory | Where-Object { $_.HealthStatus } | Select-Object -ExpandProperty HealthStatus -Unique | Sort-Object)
    
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VM Backup Overview</title>
    <style>
$(Get-ReportStylesheet)
    </style>
</head>
<body>
$(Get-ReportNavigation -ActivePage "VMBackup")
    
    <div class="container">
        <div class="page-header">
            <h1>&#128190; VM Backup Overview</h1>
            <div class="metadata">
                <p><strong>Tenant:</strong> $TenantId</p>
                <p><strong>Scanned:</strong> $timestamp</p>
                <p><strong>Subscriptions:</strong> $subscriptionCount</p>
                <p><strong>Resources:</strong> $totalVMs</p>
                <p><strong>Total Findings:</strong> $totalVMs</p>
            </div>
        </div>
        
        <div class="section-box">
            <h2>VM Backup Overview</h2>
            <div class="summary-grid">
                <div class="summary-card blue-border">
                    <div class="summary-card-value">$totalVMs</div>
                    <div class="summary-card-label">Total VMs</div>
                </div>
                <div class="summary-card green-border">
                    <div class="summary-card-value">$protectedVMs</div>
                    <div class="summary-card-label">Backup Protected VMs</div>
                </div>
                <div class="summary-card red-border">
                    <div class="summary-card-value">$unprotectedVMs</div>
                    <div class="summary-card-label">Unprotected VMs</div>
                </div>
                <div class="summary-card orange-border">
                    <div class="summary-card-value">$oldBackups</div>
                    <div class="summary-card-label">Last backup >48 hours ago</div>
                </div>
                <div class="summary-card red-border">
                    <div class="summary-card-value">$backupIssues</div>
                    <div class="summary-card-label">Backup Issues</div>
                </div>
                <div class="summary-card purple-border">
                    <div class="summary-card-value">$protectionRate%</div>
                    <div class="summary-card-label">Protection Rate</div>
                </div>
            </div>
        </div>
        
        <div class="section-box">
            <h2>Backup Protection Coverage</h2>
            <div class="progress-bar">
                <div class="progress-bar__label">
                    <span>$protectedVMs of $totalVMs VMs protected ($protectionRate%)</span>
                </div>
                <div class="progress-bar__track">
                    <div class="progress-bar__fill" style="width: $protectionRate%"></div>
                </div>
            </div>
        </div>
        
        <div class="section-box">
            <h2>Filters</h2>
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
                <label for="healthFilter">Backup Health:</label>
                <select id="healthFilter">
                    <option value="all">All</option>
"@
    
    # Add health status options
    foreach ($health in $healthStatuses) {
        $html += "                    <option value=`"$($health.ToLower())`">$health</option>`n"
    }
    
    $html += @"
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
            <div class="filter-stats">
                Showing <span id="visibleCount">$totalVMs</span> of <span id="totalCount">$totalVMs</span> VMs
            </div>
        </div>
"@

    # Group VMs by subscription
    $vmsBySubscription = $VMInventory | Group-Object SubscriptionName | Sort-Object Name
    
    $html += @"
        <div class="section-box">
            <h2>VM Inventory by Subscription</h2>
"@
    
    foreach ($subGroup in $vmsBySubscription) {
        $subName = $subGroup.Name
        $subVMs = $subGroup.Group
        $subProtected = @($subVMs | Where-Object { $_.BackupEnabled }).Count
        $subUnprotected = $subVMs.Count - $subProtected
        $subRunning = @($subVMs | Where-Object { $_.PowerState -eq 'running' }).Count
        
        $html += @"
        
        <div class="expandable expandable--collapsed subscription-section" data-subscription="$($subName.ToLower())">
            <div class="expandable__header subscription-header" onclick="toggleSubscription(this)">
                <div class="expandable__title subscription-title">
                    <span class="expand-icon"></span>
                    <span>$subName</span>
                </div>
                <div class="expandable__badges subscription-stats">
                    <span class="stat">$($subVMs.Count) VMs</span>
                    <span class="stat protected">&check; $subProtected protected</span>
                    <span class="stat unprotected">&cross; $subUnprotected unprotected</span>
                    <span class="stat running">&bull; $subRunning running</span>
                </div>
            </div>
            <div class="expandable__content subscription-content">
                <table class="data-table data-table--sticky-header data-table--compact">
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
            # Only 'Passed' is OK, everything else is treated as an issue
            $healthClass = if ($vm.HealthStatus -eq 'Passed') { 'passed' } else { 'failed' }
            $healthText = if ($vm.HealthStatus) { $vm.HealthStatus } else { '-' }
            $healthValue = if ($vm.HealthStatus) { $vm.HealthStatus.ToLower() } else { 'none' }
            $osType = if ($vm.OsType) { $vm.OsType } else { 'Unknown' }
            $vmSize = if ($vm.VMSize) { $vm.VMSize } else { '-' }
            $searchableText = "$($vm.VMName) $($vm.ResourceGroup) $vaultName $policyName".ToLower()
            
            $html += @"
                        <tr class="vm-row" 
                            data-searchable="$searchableText"
                            data-backup="$backupClass"
                            data-power="$powerClass"
                            data-health="$healthValue">
                            <td><strong>$($vm.VMName)</strong></td>
                            <td>$($vm.ResourceGroup)</td>
                            <td><span class="badge badge--neutral badge--small">$osType</span></td>
                            <td class="text-muted">$vmSize</td>
                            <td><span class="badge badge--$(if ($powerClass -eq 'running') { 'info' } elseif ($powerClass -eq 'deallocated' -or $powerClass -eq 'stopped') { 'warning' } else { 'neutral' })">$($vm.PowerState)</span></td>
                            <td><span class="badge badge--$(if ($backupClass -eq 'protected') { 'success' } else { 'danger' })">$backupText</span></td>
                            <td>$vaultName</td>
                            <td class="text-muted">$policyName</td>
                            <td>$lastBackup</td>
                            <td><span class="badge badge--$(if ($healthClass -eq 'passed') { 'success' } elseif ($healthClass -eq 'failed') { 'danger' } else { 'neutral' })">$healthText</span></td>
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
    
    $html += @"
        </div>
"@
    
    # Add JavaScript
    $html += @"
    </div>
    
    <script>
        function toggleSubscription(header) {
            const parent = header.closest('.expandable');
            if (parent) {
                parent.classList.toggle('expandable--collapsed');
            }
        }
        
        // Filter functionality
        const searchFilter = document.getElementById('searchFilter');
        const backupFilter = document.getElementById('backupFilter');
        const powerFilter = document.getElementById('powerFilter');
        const healthFilter = document.getElementById('healthFilter');
        const subscriptionFilter = document.getElementById('subscriptionFilter');
        
        // Check if all filters exist before setting up event listeners
        if (!searchFilter || !backupFilter || !powerFilter || !subscriptionFilter) {
            console.error('Required filter elements not found');
        }
        
        // Function to update summary cards based on filtered data
        function updateSummaryCards() {
            const subscriptionValue = subscriptionFilter ? subscriptionFilter.value : 'all';
            let filteredVMs = [];
            
            // Collect all visible VMs after filtering
            document.querySelectorAll('.vm-row:not(.hidden)').forEach(row => {
                const section = row.closest('.subscription-section');
                if (section) {
                    const sectionSub = section.getAttribute('data-subscription');
                    const subMatch = subscriptionValue === 'all' || sectionSub === subscriptionValue;
                    if (subMatch && section.style.display !== 'none') {
                        filteredVMs.push(row);
                    }
                }
            });
            
            // Calculate statistics from filtered VMs
            const total = filteredVMs.length;
            const protected = filteredVMs.filter(r => r.getAttribute('data-backup') === 'protected').length;
            const unprotected = total - protected;
            const protectionRate = total > 0 ? Math.round((protected / total) * 100 * 10) / 10 : 0;
            
            // Calculate old backups (>48 hours)
            const cutoffTime = new Date();
            cutoffTime.setHours(cutoffTime.getHours() - 48);
            let oldBackups = 0;
            filteredVMs.forEach(row => {
                if (row.getAttribute('data-backup') === 'protected') {
                    const lastBackupCell = row.cells[8]; // Last Backup column
                    if (lastBackupCell && lastBackupCell.textContent !== '-') {
                        const backupTime = new Date(lastBackupCell.textContent);
                        if (backupTime < cutoffTime) {
                            oldBackups++;
                        }
                    }
                }
            });
            
            // Calculate backup issues (only 'passed' is OK, everything else is an issue)
            let backupIssues = 0;
            filteredVMs.forEach(row => {
                if (row.getAttribute('data-backup') === 'protected') {
                    const health = row.getAttribute('data-health');
                    if (!health || health === 'none' || health !== 'passed') {
                        backupIssues++;
                    }
                }
            });
            
            // Update summary cards (in order: Total, Protected, Unprotected, Old Backups, Backup Issues, Protection Rate)
            const cards = document.querySelectorAll('.summary-grid .summary-card');
            if (cards.length >= 6) {
                cards[0].querySelector('.summary-card-value').textContent = total;
                cards[1].querySelector('.summary-card-value').textContent = protected;
                cards[2].querySelector('.summary-card-value').textContent = unprotected;
                cards[3].querySelector('.summary-card-value').textContent = oldBackups;
                cards[4].querySelector('.summary-card-value').textContent = backupIssues;
                cards[5].querySelector('.summary-card-value').textContent = protectionRate + '%';
            }
            
            // Update progress bar
            const progressFill = document.querySelector('.progress-bar__fill');
            if (progressFill) {
                progressFill.style.width = protectionRate + '%';
            }
            const progressLabel = document.querySelector('.progress-bar__label span');
            if (progressLabel) {
                progressLabel.textContent = protected + ' of ' + total + ' VMs protected (' + protectionRate + '%)';
            }
        }
        
        function applyFilters() {
            const searchText = searchFilter ? searchFilter.value.toLowerCase() : '';
            const backupValue = backupFilter ? backupFilter.value : 'all';
            const powerValue = powerFilter ? powerFilter.value : 'all';
            const healthValue = healthFilter ? healthFilter.value : 'all';
            const subscriptionValue = subscriptionFilter ? subscriptionFilter.value : 'all';
            
            // Filter subscription sections
            document.querySelectorAll('.subscription-section, .expandable').forEach(section => {
                const sectionSub = section.getAttribute('data-subscription');
                const subMatch = subscriptionValue === 'all' || sectionSub === subscriptionValue;
                
                if (!subMatch) {
                    section.style.display = 'none';
                    return;
                }
                
                section.style.display = 'block';
                
                // Filter rows within section
                let visibleRows = 0;
                section.querySelectorAll('.vm-row, tr[data-searchable]').forEach(row => {
                    const searchable = row.getAttribute('data-searchable');
                    const backup = row.getAttribute('data-backup');
                    const power = row.getAttribute('data-power');
                    const health = row.getAttribute('data-health') || 'none';
                    
                    const searchMatch = searchText === '' || searchable.includes(searchText);
                    const backupMatch = backupValue === 'all' || backup === backupValue;
                    const powerMatch = powerValue === 'all' || 
                                       (powerValue === 'deallocated' && (power === 'deallocated' || power === 'stopped')) ||
                                       power === powerValue;
                    const healthMatch = healthValue === 'all' || health === healthValue;
                    
                    if (searchMatch && backupMatch && powerMatch && healthMatch) {
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
        
        // Set up event listeners only if elements exist
        if (searchFilter) {
            searchFilter.addEventListener('input', () => { applyFilters(); updateSummaryCards(); });
        }
        if (backupFilter) {
            backupFilter.addEventListener('change', () => { applyFilters(); updateSummaryCards(); });
        }
        if (powerFilter) {
            powerFilter.addEventListener('change', () => { applyFilters(); updateSummaryCards(); });
        }
        if (healthFilter) {
            healthFilter.addEventListener('change', () => { applyFilters(); updateSummaryCards(); });
        }
        if (subscriptionFilter) {
            subscriptionFilter.addEventListener('change', () => { applyFilters(); updateSummaryCards(); });
        }
    </script>
</body>
</html>
"@
    
    # Write to file
    $html | Out-File -FilePath $OutputPath -Encoding UTF8
    
    # Return metadata for Dashboard consumption
    return @{
        OutputPath = $OutputPath
        TotalVMs = $totalVMs
        ProtectedVMs = $protectedVMs
        UnprotectedVMs = $unprotectedVMs
        BackupRate = $protectionRate
        OldBackups = $oldBackups
        BackupIssues = $backupIssues
    }
}

