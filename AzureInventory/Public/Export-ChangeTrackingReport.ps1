<#
.SYNOPSIS
    Generates a consolidated HTML report for Azure Change Tracking data.

.DESCRIPTION
    Creates an interactive HTML report showing Azure Activity Log changes
    with summary cards, trend chart, security alerts, and filterable change log.

.PARAMETER ChangeTrackingData
    Array of change tracking objects from Get-AzureChangeTracking.

.PARAMETER OutputPath
    Path for the HTML report output.

.PARAMETER TenantId
    Azure Tenant ID for display in report.

.OUTPUTS
    Hashtable with OutputPath and metadata for Dashboard.
#>
function Export-ChangeTrackingReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$ChangeTrackingData,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        
        [string]$TenantId = "Unknown"
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    
    # Ensure ChangeTrackingData is an array (handle null/empty cases)
    if ($null -eq $ChangeTrackingData) {
        $ChangeTrackingData = @()
    } else {
        $ChangeTrackingData = @($ChangeTrackingData)
    }
    
    Write-Verbose "Export-ChangeTrackingReport: Processing $($ChangeTrackingData.Count) changes"
    
    # Calculate statistics
    $totalChanges = $ChangeTrackingData.Count
    $creates = @($ChangeTrackingData | Where-Object { $_.OperationType -eq 'Create' }).Count
    $modifies = @($ChangeTrackingData | Where-Object { $_.OperationType -eq 'Modify' }).Count
    $deletes = @($ChangeTrackingData | Where-Object { $_.OperationType -eq 'Delete' }).Count
    $actions = @($ChangeTrackingData | Where-Object { $_.OperationType -eq 'Action' }).Count
    $highSecurityFlags = @($ChangeTrackingData | Where-Object { $_.SecurityFlag -eq 'high' }).Count
    $mediumSecurityFlags = @($ChangeTrackingData | Where-Object { $_.SecurityFlag -eq 'medium' }).Count
    
    # Top callers
    $topCallers = $ChangeTrackingData | 
        Group-Object Caller | 
        Sort-Object Count -Descending | 
        Select-Object -First 5 | 
        ForEach-Object { [PSCustomObject]@{ Caller = $_.Name; Count = $_.Count } }
    
    # Top resource types
    $topResourceTypes = $ChangeTrackingData | 
        Group-Object ResourceType | 
        Sort-Object Count -Descending | 
        Select-Object -First 5 | 
        ForEach-Object { [PSCustomObject]@{ ResourceType = $_.Name; Count = $_.Count } }
    
    # Changes by day (for sparkline)
    $changesByDay = $ChangeTrackingData | 
        Where-Object { $_.Timestamp } |
        Group-Object { 
            if ($_.Timestamp -is [DateTime]) {
                $_.Timestamp.Date
            } elseif ($_.Timestamp) {
                try {
                    ([DateTime]$_.Timestamp).Date
                } catch {
                    (Get-Date).Date
                }
            } else {
                (Get-Date).Date
            }
        } | 
        Sort-Object Name | 
        ForEach-Object { 
            $dateValue = $_.Name
            if ($dateValue -isnot [DateTime]) {
                try {
                    $dateValue = [DateTime]$dateValue
                } catch {
                    $dateValue = Get-Date
                }
            }
            [PSCustomObject]@{ Date = $dateValue; Count = $_.Count } 
        }
    
    # Changes by subscription
    $changesBySubscription = $ChangeTrackingData | 
        Group-Object SubscriptionName | 
        Sort-Object Count -Descending | 
        ForEach-Object { [PSCustomObject]@{ SubscriptionName = $_.Name; Count = $_.Count } }
    
    # Security alerts (high and medium priority)
    $securityAlerts = @($ChangeTrackingData | Where-Object { $_.SecurityFlag -in @('high', 'medium') } | Sort-Object Timestamp -Descending)
    
    # Get unique subscriptions for filter
    $allSubscriptions = @($ChangeTrackingData | Select-Object -ExpandProperty SubscriptionName -Unique | Sort-Object)
    
    # Encode-Html is imported from Private/Helpers/Encode-Html.ps1
    
    # Start building HTML
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure Change Tracking Report</title>
    <style>
$(Get-ReportStylesheet)
        /* Change Tracking specific styles */
        .summary-cards {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        
        .summary-card {
            background: var(--bg-surface);
            border-radius: var(--radius-md);
            padding: 20px;
            border: 1px solid var(--border-color);
            text-align: center;
        }
        
        .summary-card .value {
            font-size: 2rem;
            font-weight: 700;
            margin-bottom: 8px;
        }
        
        .summary-card.create .value { color: var(--accent-green); }
        .summary-card.modify .value { color: var(--accent-blue); }
        .summary-card.delete .value { color: var(--accent-red); }
        .summary-card.security .value { color: var(--accent-yellow); }
        
        .summary-card .label {
            color: var(--text-muted);
            font-size: 0.9rem;
        }
        
        .trend-chart {
            background: var(--bg-surface);
            border-radius: var(--radius-md);
            padding: 20px;
            margin-bottom: 30px;
            border: 1px solid var(--border-color);
        }
        
        .insights-panel {
            background: var(--bg-surface);
            border-radius: var(--radius-md);
            padding: 20px;
            border: 1px solid var(--border-color);
            margin-bottom: 20px;
        }
        
        .insights-panel h3 {
            margin-top: 0;
            margin-bottom: 15px;
            font-size: 1.1rem;
        }
        
        .insights-list {
            list-style: none;
            padding: 0;
            margin: 0;
        }
        
        .insights-list li {
            padding: 8px 0;
            border-bottom: 1px solid var(--border-color);
        }
        
        .insights-list li:last-child {
            border-bottom: none;
        }
        
        .security-alert {
            padding: 12px;
            border-radius: 6px;
            margin-bottom: 10px;
            border-left: 4px solid;
        }
        
        .security-alert.high {
            background: rgba(255, 107, 107, 0.1);
            border-left-color: var(--accent-red);
        }
        
        .security-alert.medium {
            background: rgba(254, 202, 87, 0.1);
            border-left-color: var(--accent-yellow);
        }
        
        .filter-section {
            background: var(--bg-surface);
            border-radius: var(--radius-md);
            padding: 20px;
            margin-bottom: 30px;
            border: 1px solid var(--border-color);
            display: flex;
            flex-wrap: wrap;
            gap: 15px;
            align-items: center;
        }
        
        .filter-group {
            display: flex;
            align-items: center;
            gap: 8px;
        }
        
        .filter-group label {
            color: var(--text-secondary);
            font-size: 0.9rem;
        }
        
        .filter-group input,
        .filter-group select {
            background: var(--bg-secondary);
            border: 1px solid var(--border-color);
            color: var(--text-primary);
            padding: 6px 12px;
            border-radius: 6px;
            font-size: 0.9rem;
        }
        
        .change-table {
            width: 100%;
            border-collapse: collapse;
            background: var(--bg-surface);
            border-radius: var(--radius-md);
            overflow: hidden;
        }
        
        .change-table thead {
            background: var(--bg-secondary);
        }
        
        .change-table th {
            padding: 12px;
            text-align: left;
            font-weight: 600;
            color: var(--text-primary);
            border-bottom: 2px solid var(--border-color);
        }
        
        .change-table td {
            padding: 12px;
            border-bottom: 1px solid var(--border-color);
        }
        
        .change-table tbody tr {
            cursor: pointer;
            transition: background 0.2s;
        }
        
        .change-table tbody tr:hover {
            background: var(--bg-hover);
        }
        
        .change-table tbody tr.expanded {
            background: var(--bg-secondary);
        }
        
        .change-details {
            display: none;
            padding: 15px;
            background: var(--bg-secondary);
            border-top: 1px solid var(--border-color);
        }
        
        .change-details.expanded {
            display: block;
        }
        
        .operation-icon {
            display: inline-block;
            width: 24px;
            height: 24px;
            border-radius: 4px;
            text-align: center;
            line-height: 24px;
            font-weight: 700;
            font-size: 0.8rem;
            margin-right: 8px;
        }
        
        .operation-icon.create { background: rgba(0, 210, 106, 0.2); color: var(--accent-green); }
        .operation-icon.modify { background: rgba(84, 160, 255, 0.2); color: var(--accent-blue); }
        .operation-icon.delete { background: rgba(255, 107, 107, 0.2); color: var(--accent-red); }
        .operation-icon.action { background: rgba(254, 202, 87, 0.2); color: var(--accent-yellow); }
        .operation-icon.health { background: rgba(52, 152, 219, 0.2); color: var(--accent-blue); }
        .operation-icon.incident { background: rgba(231, 76, 60, 0.2); color: #e74c3c; }
        .operation-icon.resourcehealth { background: rgba(155, 89, 182, 0.2); color: #9b59b6; }
        
        .security-badge {
            display: inline-block;
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 0.8rem;
            font-weight: 600;
        }
        
        .security-badge.high {
            background: rgba(255, 107, 107, 0.2);
            color: var(--accent-red);
        }
        
        .security-badge.medium {
            background: rgba(254, 202, 87, 0.2);
            color: var(--accent-yellow);
        }
    </style>
</head>
<body>
$(Get-ReportNavigation -ActivePage "ChangeTracking")
    
    <div class="container">
        <div class="page-header">
            <h1>Change Tracking</h1>
            <p class="subtitle">Activity Log changes over the last 30 days - $totalChanges total changes</p>
        </div>
        
        <div class="summary-cards">
            <div class="summary-card create">
                <div class="value">$creates</div>
                <div class="label">Created</div>
            </div>
            <div class="summary-card modify">
                <div class="value">$modifies</div>
                <div class="label">Modified</div>
            </div>
            <div class="summary-card delete">
                <div class="value">$deletes</div>
                <div class="label">Deleted</div>
            </div>
            <div class="summary-card security">
                <div class="value">$($highSecurityFlags + $mediumSecurityFlags)</div>
                <div class="label">Security-Sensitive Operations</div>
            </div>
        </div>
        
        <div class="trend-chart">
            <h3 style="margin-top: 0; margin-bottom: 15px;">Changes Over Time (30 days)</h3>
            <div style="height: 60px; display: flex; align-items: flex-end; gap: 2px;">
"@
    
    # Generate sparkline bars
    if ($changesByDay.Count -gt 0) {
        $maxCount = ($changesByDay | Measure-Object -Property Count -Maximum).Maximum
        foreach ($day in $changesByDay) {
            $height = if ($maxCount -gt 0) { [math]::Round(($day.Count / $maxCount) * 100, 0) } else { 0 }
            $dateStr = if ($day.Date -is [DateTime]) {
                $day.Date.ToString('yyyy-MM-dd')
            } else {
                try {
                    ([DateTime]$day.Date).ToString('yyyy-MM-dd')
                } catch {
                    (Get-Date).ToString('yyyy-MM-dd')
                }
            }
            $html += "                <div style='flex: 1; background: var(--accent-blue); height: ${height}%; border-radius: 2px 2px 0 0;' title='${dateStr}: $($day.Count) changes'></div>`n"
        }
    } else {
        $html += "                <div style='flex: 1; text-align: center; color: var(--text-muted); padding-top: 20px;'>No changes recorded</div>`n"
    }
    
    $html += @"
            </div>
        </div>
        
        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; margin-bottom: 30px;">
            <div class="insights-panel">
                <h3>Top Callers</h3>
                <ul class="insights-list">
"@
    
    foreach ($caller in $topCallers) {
        $escapedCaller = Encode-Html $caller.Caller
        $html += "                    <li><strong>$escapedCaller</strong> ($($caller.Count) changes)</li>`n"
    }
    
    if ($topCallers.Count -eq 0) {
        $html += "                    <li style='color: var(--text-muted);'>No caller data available</li>`n"
    }
    
    $html += @"
                </ul>
            </div>
            
            <div class="insights-panel">
                <h3>Most Changed Resource Types</h3>
                <ul class="insights-list">
"@
    
    foreach ($resType in $topResourceTypes) {
        $escapedType = Encode-Html $resType.ResourceType
        $html += "                    <li><strong>$escapedType</strong> ($($resType.Count) changes)</li>`n"
    }
    
    if ($topResourceTypes.Count -eq 0) {
        $html += "                    <li style='color: var(--text-muted);'>No resource type data available</li>`n"
    }
    
    $html += @"
                </ul>
            </div>
        </div>
        
        $(if ($securityAlerts.Count -gt 0) {
            $alertsHtml = @"
        <div class="insights-panel">
            <h3>Security-Sensitive Operations</h3>
"@
            foreach ($alert in ($securityAlerts | Select-Object -First 10)) {
                $alertClass = if ($alert.SecurityFlag -eq 'high') { 'high' } else { 'medium' }
                $escapedReason = Encode-Html $alert.SecurityReason
                $escapedResource = Encode-Html $alert.ResourceName
                $escapedCaller = Encode-Html $alert.Caller
                $timeStr = if ($alert.Timestamp -is [DateTime]) {
                    $alert.Timestamp.ToString('yyyy-MM-dd HH:mm')
                } else {
                    try {
                        ([DateTime]$alert.Timestamp).ToString('yyyy-MM-dd HH:mm')
                    } catch {
                        (Get-Date).ToString('yyyy-MM-dd HH:mm')
                    }
                }
                $alertsHtml += @"
            <div class="security-alert $alertClass">
                <strong>$escapedReason</strong><br>
                <span style="font-size: 0.9rem; color: var(--text-secondary);">
                    Resource: $escapedResource | Caller: $escapedCaller | $timeStr
                </span>
            </div>
"@
            }
            $alertsHtml += "        </div>`n"
            $alertsHtml
        } else { '' })
        
        <div class="filter-section">
            <div class="filter-group">
                <label>Search:</label>
                <input type="text" id="searchFilter" placeholder="Search changes...">
            </div>
            <div class="filter-group">
                <label>Subscription:</label>
                <select id="subscriptionFilter">
                    <option value="all">All Subscriptions</option>
"@
    
    # Add subscription options
    foreach ($sub in $allSubscriptions) {
        $html += "                    <option value=`"$(($sub).ToLower())`">$sub</option>`n"
    }
    
    $html += @"
                </select>
            </div>
            <div class="filter-group">
                <label>Type:</label>
                <select id="typeFilter">
                    <option value="all">All Types</option>
                    <option value="Create">Create</option>
                    <option value="Modify">Modify</option>
                    <option value="Delete">Delete</option>
                    <option value="Action">Action</option>
                    <option value="Health">Health</option>
                    <option value="Incident">Incident</option>
                    <option value="ResourceHealth">Resource Health</option>
                </select>
            </div>
            <div class="filter-group">
                <label>Category:</label>
                <select id="categoryFilter">
                    <option value="all">All Categories</option>
                    <option value="Compute">Compute</option>
                    <option value="Storage">Storage</option>
                    <option value="Networking">Networking</option>
                    <option value="Databases">Databases</option>
                    <option value="Identity">Identity</option>
                    <option value="Security">Security</option>
                    <option value="Containers">Containers</option>
                    <option value="Web">Web</option>
                    <option value="Other">Other</option>
                </select>
            </div>
            <div class="filter-group">
                <label>Resource Group:</label>
                <select id="resourceGroupFilter">
                    <option value="all">All Resource Groups</option>
"@
    
    # Get unique resource groups
    $allResourceGroups = $ChangeTrackingData | 
        Where-Object { $_.ResourceGroup } | 
        Select-Object -ExpandProperty ResourceGroup -Unique | 
        Sort-Object
    
    foreach ($rg in $allResourceGroups) {
        $escapedRg = Encode-Html $rg
        $html += "                    <option value=`"$escapedRg`">$escapedRg</option>`n"
    }
    
    $html += @"
                </select>
            </div>
        </div>
"@
    
    if ($totalChanges -eq 0) {
        $html += @"
        <div class="no-data">
            <h2>No Changes Found</h2>
            <p>No Activity Log changes were found for the last 30 days.</p>
        </div>
"@
    }
    else {
        $html += @"
        <table class="change-table">
            <thead>
                <tr>
                    <th>Time</th>
                    <th>Type</th>
                    <th>Resource</th>
                    <th>Resource Group</th>
                    <th>Category</th>
                    <th>Caller</th>
                    <th>Subscription</th>
                    <th>Security</th>
                </tr>
            </thead>
            <tbody>
"@
        
        foreach ($change in ($ChangeTrackingData | Sort-Object Timestamp -Descending)) {
            $timeStr = if ($change.Timestamp -is [DateTime]) {
                $change.Timestamp.ToString('yyyy-MM-dd HH:mm')
            } else {
                try {
                    ([DateTime]$change.Timestamp).ToString('yyyy-MM-dd HH:mm')
                } catch {
                    (Get-Date).ToString('yyyy-MM-dd HH:mm')
                }
            }
            $operationType = $change.OperationType
            $operationIcon = switch ($operationType) {
                'Create' { '<span class="operation-icon create">+</span>' }
                'Modify' { '<span class="operation-icon modify">~</span>' }
                'Delete' { '<span class="operation-icon delete">-</span>' }
                'Action' { '<span class="operation-icon action">*</span>' }
                'Health' { '<span class="operation-icon health">H</span>' }
                'Incident' { '<span class="operation-icon incident">I</span>' }
                'ResourceHealth' { '<span class="operation-icon resourcehealth">RH</span>' }
                default { '' }
            }
            
            $escapedResource = Encode-Html $change.ResourceName
            $escapedCategory = Encode-Html $change.ResourceCategory
            $escapedCaller = Encode-Html $change.Caller
            $escapedSub = Encode-Html $change.SubscriptionName
            $escapedOpName = Encode-Html $change.OperationName
            $escapedResId = Encode-Html $change.ResourceId
            $escapedResGroup = Encode-Html $change.ResourceGroup
            $escapedCallerType = Encode-Html $change.CallerType
            $escapedReason = Encode-Html $change.SecurityReason
            
            $securityBadge = ''
            if ($change.SecurityFlag -eq 'high') {
                $securityBadge = '<span class="security-badge high">High</span>'
            } elseif ($change.SecurityFlag -eq 'medium') {
                $securityBadge = '<span class="security-badge medium">Medium</span>'
            }
            
            $searchable = "$escapedResource $escapedCategory $escapedCaller $escapedSub $escapedResGroup".ToLower()
            $subLower = $escapedSub.ToLower()
            $rgLower = if ($escapedResGroup) { $escapedResGroup.ToLower() } else { '' }
            
            $html += @"
                <tr class="change-row" 
                    data-subscription="$subLower"
                    data-type="$operationType"
                    data-category="$escapedCategory"
                    data-resourcegroup="$rgLower"
                    data-searchable="$searchable"
                    onclick="toggleChangeDetails(this)">
                    <td>$timeStr</td>
                    <td>$operationIcon $operationType</td>
                    <td>$escapedResource</td>
                    <td>$escapedResGroup</td>
                    <td>$escapedCategory</td>
                    <td>$escapedCaller</td>
                    <td>$escapedSub</td>
                    <td>$securityBadge</td>
                </tr>
                <tr class="change-details-row">
                    <td colspan="8">
                        <div class="change-details">
                            <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 15px;">
                                <div>
                                    <strong>Operation:</strong><br>
                                    <span style="font-family: 'Consolas', monospace; font-size: 0.9em;">$escapedOpName</span>
                                    $(if ($operationType -eq 'Modify' -and $escapedOpName -match '/write$') {
                                        "<br><small style='color: var(--text-muted); font-size: 0.85em;'>Modify operations indicate configuration changes (settings, properties, etc.)</small>"
                                    } else { '' })
                                </div>
                                <div>
                                    <strong>Resource ID:</strong><br>
                                    <span style="font-family: 'Consolas', monospace; font-size: 0.85em; word-break: break-all;">$escapedResId</span>
                                </div>
                                <div>
                                    <strong>Resource Group:</strong><br>
                                    $escapedResGroup
                                </div>
                                <div>
                                    <strong>Caller Type:</strong><br>
                                    $escapedCallerType
                                </div>
                                $(if ($escapedReason) {
                                    "<div><strong>Security Reason:</strong><br>$escapedReason</div>"
                                } else { '' })
                            </div>
                        </div>
                    </td>
                </tr>
"@
        }
        
        $html += @"
            </tbody>
        </table>
"@
    }
    
    # JavaScript filtering
    $jsCode = @'
    </div>
    
    <script>
        function toggleChangeDetails(row) {
            const detailsRow = row.nextElementSibling;
            if (detailsRow && detailsRow.classList.contains('change-details-row')) {
                const details = detailsRow.querySelector('.change-details');
                if (details) {
                    details.classList.toggle('expanded');
                    row.classList.toggle('expanded');
                }
            }
        }
        
        // Filtering
        const searchFilter = document.getElementById('searchFilter');
        const subscriptionFilter = document.getElementById('subscriptionFilter');
        const typeFilter = document.getElementById('typeFilter');
        const categoryFilter = document.getElementById('categoryFilter');
        const resourceGroupFilter = document.getElementById('resourceGroupFilter');
        
        function applyFilters() {
            const searchText = searchFilter.value.toLowerCase();
            const subscriptionValue = subscriptionFilter.value;
            const typeValue = typeFilter.value;
            const categoryValue = categoryFilter.value;
            const resourceGroupValue = resourceGroupFilter.value;
            
            document.querySelectorAll('.change-row').forEach(row => {
                const searchable = row.getAttribute('data-searchable');
                const subscription = row.getAttribute('data-subscription');
                const type = row.getAttribute('data-type');
                const category = row.getAttribute('data-category').toLowerCase();
                const resourceGroup = row.getAttribute('data-resourcegroup') || '';
                
                const searchMatch = searchText === '' || searchable.includes(searchText);
                const subMatch = subscriptionValue === 'all' || subscription === subscriptionValue;
                const typeMatch = typeValue === 'all' || type === typeValue;
                const categoryMatch = categoryValue === 'all' || category === categoryValue.toLowerCase();
                const rgMatch = resourceGroupValue === 'all' || resourceGroup === resourceGroupValue.toLowerCase();
                
                if (searchMatch && subMatch && typeMatch && categoryMatch && rgMatch) {
                    row.style.display = '';
                    const detailsRow = row.nextElementSibling;
                    if (detailsRow && detailsRow.classList.contains('change-details-row')) {
                        detailsRow.style.display = '';
                    }
                } else {
                    row.style.display = 'none';
                    const detailsRow = row.nextElementSibling;
                    if (detailsRow && detailsRow.classList.contains('change-details-row')) {
                        detailsRow.style.display = 'none';
                        const details = detailsRow.querySelector('.change-details');
                        if (details) {
                            details.classList.remove('expanded');
                        }
                        row.classList.remove('expanded');
                    }
                }
            });
        }
        
        searchFilter.addEventListener('input', applyFilters);
        subscriptionFilter.addEventListener('change', applyFilters);
        typeFilter.addEventListener('change', applyFilters);
        categoryFilter.addEventListener('change', applyFilters);
        resourceGroupFilter.addEventListener('change', applyFilters);
    </script>
</body>
</html>
'@
    $html += $jsCode
    
    # Write to file
    $html | Out-File -FilePath $OutputPath -Encoding UTF8
    
    # Return metadata for Dashboard
    return @{
        OutputPath = $OutputPath
        TotalChanges = $totalChanges
        Creates = $creates
        Modifies = $modifies
        Deletes = $deletes
        HighSecurityFlags = $highSecurityFlags
        MediumSecurityFlags = $mediumSecurityFlags
    }
}

