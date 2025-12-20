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
$(Get-ReportStylesheet)
    </style>
</head>
<body>
$(Get-ReportNavigation -ActivePage "VMBackup")
    
    <div class="container">
        <div class="page-header">
            <h1>VM Backup Overview</h1>
            <div class="metadata">
                <p><strong>Tenant:</strong> $TenantId</p>
                <p><strong>Scanned:</strong> $timestamp</p>
                <p><strong>Subscriptions:</strong> $subscriptionCount</p>
                <p><strong>Resources:</strong> $totalVMs</p>
                <p><strong>Total Findings:</strong> $totalVMs</p>
            </div>
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
    
    # Return metadata for Dashboard consumption
    return @{
        OutputPath = $OutputPath
        TotalVMs = $totalVMs
        ProtectedVMs = $protectedVMs
        UnprotectedVMs = $unprotectedVMs
        BackupRate = $protectionRate
        RunningVMs = $runningVMs
    }
}

