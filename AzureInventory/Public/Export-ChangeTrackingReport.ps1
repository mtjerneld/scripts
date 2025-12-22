<#
.SYNOPSIS
    Generates a consolidated HTML report for Azure Change Tracking data.

.DESCRIPTION
    Creates an interactive HTML report showing Azure Activity Log changes
    with summary cards, trend chart, security alerts, and filterable change log.

.PARAMETER ChangeTrackingData
    Array of change tracking objects from Get-AzureChangeAnalysis.

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
    
    # Ensure ChangeTrackingData is an array (handle null/empty cases)
    if ($null -eq $ChangeTrackingData) {
        $ChangeTrackingData = @()
    } else {
        $ChangeTrackingData = @($ChangeTrackingData)
    }
    
    Write-Verbose "Export-ChangeTrackingReport: Processing $($ChangeTrackingData.Count) changes"
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    
    # Calculate statistics
    $totalChanges = $ChangeTrackingData.Count
    $subscriptionCount = ($ChangeTrackingData | Select-Object -ExpandProperty SubscriptionName -Unique).Count
    $creates = @($ChangeTrackingData | Where-Object { $_.ChangeType -eq 'Create' }).Count
    $updates = @($ChangeTrackingData | Where-Object { $_.ChangeType -eq 'Update' }).Count
    $deletes = @($ChangeTrackingData | Where-Object { $_.ChangeType -eq 'Delete' }).Count
    $highSecurityFlags = @($ChangeTrackingData | Where-Object { $_.SecurityFlag -eq 'high' }).Count
    $mediumSecurityFlags = @($ChangeTrackingData | Where-Object { $_.SecurityFlag -eq 'medium' }).Count
    $totalSecurityAlerts = $highSecurityFlags + $mediumSecurityFlags
    
    # Top resource types
    $topResourceTypes = $ChangeTrackingData | 
        Group-Object ResourceType | 
        Sort-Object Count -Descending | 
        Select-Object -First 5 | 
        ForEach-Object { [PSCustomObject]@{ ResourceType = $_.Name; Count = $_.Count } }
    
    # Changes by day (for sparkline) - use ChangeTime instead of Timestamp
    # First, group changes by day
    $changesGrouped = $ChangeTrackingData | 
        Where-Object { $_.ChangeTime } |
        Group-Object { 
            if ($_.ChangeTime -is [DateTime]) {
                $_.ChangeTime.ToString('yyyy-MM-dd')
            } else {
                try {
                    ([DateTime]$_.ChangeTime).ToString('yyyy-MM-dd')
                } catch {
                    (Get-Date).ToString('yyyy-MM-dd')
                }
            }
        }
    
    # Create a hashtable for quick lookup
    $changesByDate = @{}
    foreach ($group in $changesGrouped) {
        $changesByDate[$group.Name] = $group.Count
    }
    
    # Generate all 14 days (from 13 days ago to today, inclusive)
    $today = (Get-Date).Date
    $changesByDay = @()
    for ($i = 13; $i -ge 0; $i--) {
        $date = $today.AddDays(-$i)
        $dateKey = $date.ToString('yyyy-MM-dd')
        $count = if ($changesByDate.ContainsKey($dateKey)) { $changesByDate[$dateKey] } else { 0 }
        $changesByDay += [PSCustomObject]@{ Date = $date; Count = $count }
    }
    
    # Security alerts (high and medium priority)
    $securityAlerts = @($ChangeTrackingData | Where-Object { $_.SecurityFlag -in @('high', 'medium') } | Sort-Object ChangeTime -Descending)
    
    # Get unique subscriptions for filter
    $allSubscriptions = @($ChangeTrackingData | Select-Object -ExpandProperty SubscriptionName -Unique | Sort-Object)
    
    # Encode-Html is imported from Private/Helpers/Encode-Html.ps1
    
    # Serialize data for client-side rendering
    $exportData = $ChangeTrackingData | Sort-Object ChangeTime -Descending | ForEach-Object {
        # Serialize ChangedProperties for Update operations
        $changedPropsJson = $null
        if ($_.ChangeType -eq 'Update' -and $_.ChangedProperties -and $_.ChangedProperties.Count -gt 0) {
            $changedPropsJson = $_.ChangedProperties | ConvertTo-Json -Compress
        }
        
        # Safely get all properties with null checks
        $time = if ($_.ChangeTime -is [DateTime]) { $_.ChangeTime.ToString('yyyy-MM-dd HH:mm') } else { try { ([DateTime]$_.ChangeTime).ToString('yyyy-MM-dd HH:mm') } catch { if ($_.ChangeTime) { $_.ChangeTime.ToString() } else { '' } } }
        $dateStr = if ($_.ChangeTime -is [DateTime]) { 
            $dt = $_.ChangeTime
            "$($dt.ToString('yyyy-MM-dd')) $($dt.ToString('yyyy-MM')) $($dt.ToString('MM-dd')) $($dt.ToString('MMMM')) $($dt.ToString('MMM')) $($dt.Day) $($dt.Year)"
        } else { 
            try { 
                if ($_.ChangeTime) {
                    $dt = [DateTime]$_.ChangeTime
                    "$($dt.ToString('yyyy-MM-dd')) $($dt.ToString('yyyy-MM')) $($dt.ToString('MM-dd')) $($dt.ToString('MMMM')) $($dt.ToString('MMM')) $($dt.Day) $($dt.Year)"
                } else {
                    ''
                }
            } catch { 
                '' 
            } 
        }
        
        @{
            time    = $time
            type    = if ($_.ChangeType) { $_.ChangeType } else { '' }
            res     = if ($_.ResourceName) { $_.ResourceName } else { '' }
            rg      = if ($_.ResourceGroup) { $_.ResourceGroup } else { '' }
            cat     = if ($_.ResourceCategory) { $_.ResourceCategory } else { '' }
            resType = if ($_.ResourceType) { $_.ResourceType } else { '' }
            sub     = if ($_.SubscriptionName) { $_.SubscriptionName } else { '' }
            sec     = if ($_.SecurityFlag) { $_.SecurityFlag } else { $null }
            id      = if ($_.ResourceId) { $_.ResourceId } else { '' }
            sReason = if ($_.SecurityReason) { $_.SecurityReason } else { $null }
            changedProps = $changedPropsJson
            hasChangeDetails = if ($null -ne $_.HasChangeDetails) { $_.HasChangeDetails } else { $false }
            changeSource = if ($_.ChangeSource) { $_.ChangeSource } else { 'ChangeAnalysis' }
            caller  = if ($_.Caller) { $_.Caller } else { $null }
            callerType = if ($_.CallerType) { $_.CallerType } else { $null }
            clientType = if ($_.ClientType) { $_.ClientType } else { $null }
            operation = if ($_.Operation) { $_.Operation } else { $null }
            subLower = if ($_.SubscriptionName) { $_.SubscriptionName.ToLower() } else { '' }
            rgLower  = if ($_.ResourceGroup) { $_.ResourceGroup.ToLower() } else { '' }
            catLower = if ($_.ResourceCategory) { $_.ResourceCategory.ToLower() } else { '' }
            # Searchable string for fast filtering - include date for date filtering
            search   = "$(if ($_.ResourceName) { $_.ResourceName } else { '' }) $(if ($_.ResourceCategory) { $_.ResourceCategory } else { '' }) $(if ($_.SubscriptionName) { $_.SubscriptionName } else { '' }) $(if ($_.ResourceGroup) { $_.ResourceGroup } else { '' }) $(if ($_.Caller) { $_.Caller } else { '' }) $time $dateStr".ToLower()
        }
    }
    
    # Convert to JSON (compress to save space)
    $jsonChanges = $exportData | ConvertTo-Json -Depth 2 -Compress

    # Start building HTML - HEADER
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure Change Tracking Report (14 days)</title>
    <style>
$(Get-ReportStylesheet)
        /* Change Tracking specific styles */
        .summary-cards {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
            gap: 15px;
            margin-bottom: 30px;
        }
        
        .summary-card {
            background: var(--bg-surface);
            border-radius: var(--radius-md);
            padding: 15px;
            border: 1px solid var(--border-color);
            text-align: center;
            cursor: pointer;
            transition: transform 0.2s, box-shadow 0.2s;
        }

        .summary-card:hover {
            transform: translateY(-2px);
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06);
            border-color: var(--accent-primary);
        }
        
        .summary-card .value {
            font-size: 1.8rem;
            font-weight: 700;
            margin-bottom: 5px;
        }
        
        .summary-card.create .value { color: var(--accent-green); }
        .summary-card.modify .value { color: var(--accent-blue); }
        .summary-card.delete .value { color: var(--accent-red); }
        .summary-card.action .value { color: var(--accent-yellow); }
        .summary-card.resourcehealth .value { color: #9b59b6; }
        .summary-card.security .value { color: var(--accent-red); }
        
        .summary-card .label {
            color: var(--text-muted);
            font-size: 0.85rem;
        }
        
        .trend-chart {
            background: var(--bg-surface);
            border-radius: var(--radius-md);
            padding: 20px;
            margin-bottom: 30px;
            border: 1px solid var(--border-color);
        }

        .chart-labels {
            display: flex;
            margin-top: 10px;
            gap: 2px;
            padding: 0;
            color: var(--text-muted);
            font-size: 0.8rem;
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
            table-layout: fixed; /* Better performance for large tables */
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
            width: 12.5%; /* Distribute width evenly or adjust as needed */
        }

        /* Specific column widths */
        .change-table th:nth-child(1) { width: 140px; } /* Time */
        .change-table th:nth-child(2) { width: 100px; } /* Type */
        .change-table th:nth-child(7) { width: 150px; } /* Caller */
        .change-table th:nth-child(8) { width: 80px; } /* Security */
        
        .change-table td {
            padding: 12px;
            border-bottom: 1px solid var(--border-color);
            word-break: break-word;
            white-space: normal; /* Ensure wrapping */
        }
        
        .change-table tbody tr.change-row {
            cursor: pointer;
            transition: background 0.2s;
        }
        
        .change-table tbody tr.change-row:hover {
            background: var(--bg-hover);
        }
        
        .change-table tbody tr.expanded {
            background: var(--bg-secondary);
            border-bottom: none;
        }
        
        /* Security Alerts table - optimized column widths */
        #security-alerts-section .change-table th:nth-child(1) { width: 15%; } /* Time */
        #security-alerts-section .change-table th:nth-child(2) { width: 10%; } /* Type */
        #security-alerts-section .change-table th:nth-child(3) { width: 10%; } /* Alert */
        #security-alerts-section .change-table th:nth-child(4) { width: 35%; } /* Resource */
        #security-alerts-section .change-table th:nth-child(5) { width: 30%; } /* Caller */
        
        .change-details {
            display: block; /* Managed by JS rendering */
            padding: 15px;
            background: var(--bg-secondary);
            border-top: 1px solid var(--border-color);
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

        /* Pagination Styles */
        .pagination {
            display: flex;
            justify-content: center;
            align-items: center;
            gap: 5px;
            margin-top: 20px;
        }
        
        .pagination button {
            background: var(--bg-secondary);
            border: 1px solid var(--border-color);
            color: var(--text-primary);
            padding: 8px 12px;
            border-radius: 4px;
            cursor: pointer;
            transition: background 0.2s;
        }
        
        .pagination button:hover:not(:disabled) {
            background: var(--bg-hover);
        }
        
        .pagination button:disabled {
            opacity: 0.5;
            cursor: not-allowed;
        }
        
        .pagination .page-info {
            color: var(--text-secondary);
            font-size: 0.9rem;
            margin: 0 10px;
        }

        .pagination .active {
            background: var(--accent-primary);
            color: white;
            border-color: var(--accent-primary);
        }
    </style>
</head>
<body>
    $(Get-ReportNavigation -ActivePage "ChangeTracking")
    
    <div class="container">
        <div class="page-header">
            <h1>Change Tracking (14 days)</h1>
            <div class="metadata">
                <p><strong>Tenant:</strong> $TenantId</p>
                <p><strong>Scanned:</strong> $timestamp</p>
                <p><strong>Subscriptions:</strong> $subscriptionCount</p>
                <p><strong>Resources:</strong> $totalChanges</p>
                <p><strong>Total Findings:</strong> $totalChanges</p>
            </div>
        </div>
        
        <div class="summary-cards">
            <div class="summary-card create" onclick="setFilter('Type', 'Create')">
                <div class="value">$creates</div>
                <div class="label">Created</div>
            </div>
            <div class="summary-card modify" onclick="setFilter('Type', 'Update')">
                <div class="value">$updates</div>
                <div class="label">Updated</div>
            </div>
            <div class="summary-card delete" onclick="setFilter('Type', 'Delete')">
                <div class="value">$deletes</div>
                <div class="label">Deleted</div>
            </div>
            <div class="summary-card security" onclick="scrollToSecurity()">
                <div class="value">$totalSecurityAlerts</div>
                <div class="label">Security Alerts</div>
            </div>
        </div>
        
        <div class="trend-chart">
            <h3 style="margin-top: 0; margin-bottom: 15px;">Changes Over Time (14 days)</h3>
            <div style="height: 60px; display: flex; align-items: flex-end; gap: 2px;">
"@
    
    # Generate sparkline bars and labels - always show all 14 days
    $barsHtml = ""
    $labelsHtml = ""
    
    # Calculate max count for scaling (use at least 1 to avoid division by zero)
    $maxCount = ($changesByDay | Measure-Object -Property Count -Maximum).Maximum
    if ($maxCount -eq 0) { $maxCount = 1 }
    
    $totalDays = $changesByDay.Count
    $i = 0
    
    foreach ($day in $changesByDay) {
        # Calculate height (minimum 2px so zero days are still visible)
        $height = if ($maxCount -gt 0) { 
            $calculated = [math]::Round(($day.Count / $maxCount) * 100, 0)
            if ($calculated -eq 0 -and $day.Count -eq 0) { 2 } else { $calculated }
        } else { 
            2 
        }
        
        $dateStr = $day.Date.ToString('yyyy-MM-dd')
        
        # Use a slightly different color for zero days to make them visible but distinct
        $barColor = if ($day.Count -eq 0) { 'var(--border-color)' } else { 'var(--accent-blue)' }
        $barsHtml += "                <div style='flex: 1; background: $barColor; height: ${height}%; border-radius: 2px 2px 0 0; cursor: pointer;' title='${dateStr}: $($day.Count) changes' onclick='filterByDate(`"$dateStr`")'></div>`n"
        
        # Show labels for first, last, and every 7th day
        $showLabel = ($i -eq 0) -or ($i -eq ($totalDays - 1)) -or ($i % 7 -eq 0)
        $visibility = if ($showLabel) { "visible" } else { "hidden" }
        
        $dateLabel = $day.Date.ToString('yyyy-MM-dd')
        
        # Align labels to match bars: center for most, left for first, right for last
        $textAlign = "center"
        if ($i -eq 0) { $textAlign = "left" }
        elseif ($i -eq ($totalDays - 1)) { $textAlign = "right" }
        
        $labelsHtml += "                <div style='flex: 1; text-align: $textAlign; visibility: $visibility; font-size: 0.65rem; white-space: nowrap; overflow: visible; min-width: 0;'>$dateLabel</div>`n"
        
        $i++
    }
    $html += $barsHtml
    
    $html += @"
            </div>
            <div class="chart-labels" style="display: flex; gap: 2px;">
                $labelsHtml
            </div>
        </div>
        
        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; margin-bottom: 30px;">
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
            
            <div class="insights-panel">
                <h3>Changes by Category</h3>
                <ul class="insights-list">
"@
    
    $changesByCategory = $ChangeTrackingData | 
        Group-Object ResourceCategory | 
        Sort-Object Count -Descending | 
        ForEach-Object { [PSCustomObject]@{ Category = $_.Name; Count = $_.Count } }
    
    foreach ($cat in $changesByCategory) {
        $escapedCat = Encode-Html $cat.Category
        $html += "                    <li><strong>$escapedCat</strong> ($($cat.Count) changes)</li>`n"
    }
    
    if ($changesByCategory.Count -eq 0) {
        $html += "                    <li style='color: var(--text-muted);'>No category data available</li>`n"
    }
    
    $html += @"
                </ul>
            </div>
        </div>
        
        $(if ($securityAlerts.Count -gt 0) {
            $alertsHtml = @"
        <div class="insights-panel" id="security-alerts-section">
            <details>
                <summary style="cursor: pointer; outline: none; padding: 5px 0;">
                    <h3 style="display: inline-block; margin: 0; font-size: 1.2rem;">Security-Sensitive Operations ($($securityAlerts.Count))</h3>
                    <span style="font-size: 0.9rem; color: var(--text-muted); margin-left: 10px;">(Click to expand)</span>
                </summary>
                <div style="margin-top: 15px; overflow-x: auto;">
                    <table class="change-table">
                        <thead>
                            <tr>
                                <th>Time</th>
                                <th>Type</th>
                                <th>Alert</th>
                                <th>Resource</th>
                                <th>Resource Type</th>
                            </tr>
                        </thead>
                        <tbody>
"@
            # Note: We keep Security Alerts as server-side rendered for now as they are high priority and usually fewer
            foreach ($alert in $securityAlerts) {
                $alertClass = if ($alert.SecurityFlag -eq 'high') { 'high' } else { 'medium' }
                $changeType = $alert.ChangeType
                $operationIcon = switch ($changeType) {
                    'Create' { '<span class="operation-icon create">+</span>' }
                    'Update' { '<span class="operation-icon modify">~</span>' }
                    'Delete' { '<span class="operation-icon delete">-</span>' }
                    default { '' }
                }
                
                $escapedReason = Encode-Html $alert.SecurityReason
                $escapedResource = Encode-Html $alert.ResourceName
                $escapedResId = Encode-Html $alert.ResourceId
                $escapedResGroup = Encode-Html $alert.ResourceGroup
                $escapedResType = Encode-Html $alert.ResourceType
                
                $timeStr = if ($alert.ChangeTime -is [DateTime]) {
                    $alert.ChangeTime.ToString('yyyy-MM-dd HH:mm')
                } else {
                    try {
                        ([DateTime]$alert.ChangeTime).ToString('yyyy-MM-dd HH:mm')
                    } catch {
                        (Get-Date).ToString('yyyy-MM-dd HH:mm')
                    }
                }
                
                $securityBadge = "<span class='security-badge $alertClass'>$($alert.SecurityFlag.Substring(0,1).ToUpper() + $alert.SecurityFlag.Substring(1))</span>"
                
                $alertsHtml += @"
                            <tr class="security-row" onclick="toggleSecurityDetails(this)" style="cursor: pointer;">
                                <td>$timeStr</td>
                                <td>$operationIcon $changeType</td>
                                <td>$securityBadge</td>
                                <td>$escapedResource</td>
                                <td>$escapedResType</td>
                            </tr>
                            <tr class="change-details-row" style="display:none;">
                                <td colspan="5">
                                    <div class="change-details" style="display:block;">
                                        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 15px;">
                                            <div>
                                                <strong style="color: var(--accent-red);">Security Alert:</strong><br>
                                                <span style="color: var(--accent-red); font-weight: bold;">$escapedReason</span>
                                            </div>
                                            <div>
                                                <strong>Change Source:</strong><br>
                                                <span style="font-family: 'Consolas', monospace; font-size: 0.9em;">$($alert.ChangeSource)</span>
                                            </div>
                                            
                                            <div>
                                                <strong>Resource ID:</strong><br>
                                                <span style="font-family: 'Consolas', monospace; font-size: 0.85em; word-break: break-all;">$escapedResId</span>
                                            </div>
                                            <div>
                                                <strong>Resource Group:</strong><br>
                                                $escapedResGroup
                                            </div>
                                        </div>
                                    </div>
                                </td>
                            </tr>
"@
            }
            $alertsHtml += @"
                        </tbody>
                    </table>
                </div>
            </details>
        </div>
"@
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
                    <option value="Update">Update</option>
                    <option value="Delete">Delete</option>
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
    
    foreach ($rg in $allResourceGroups) {
        $escapedRg = Encode-Html $rg
        $html += "                    <option value=`"$escapedRg`">$escapedRg</option>`n"
    }
    
    $html += @"
                </select>
            </div>
            <div class="filter-group">
                <label>Caller Type:</label>
                <select id="callerTypeFilter">
                    <option value="all">All Callers</option>
                    <option value="User">User Only</option>
                    <option value="System">System Only</option>
                    <option value="Application">Application Only</option>
                </select>
            </div>
        </div>
        
        <div id="table-container">
            <table class="change-table" id="mainChangeTable">
                <thead>
                    <tr>
                        <th>Time</th>
                        <th>Type</th>
                        <th>Subscription</th>
                        <th>Resource Group</th>
                        <th>Resource</th>
                        <th>Category</th>
                        <th>Caller</th>
                        <th>Security</th>
                    </tr>
                </thead>
                <tbody id="changeTableBody">
                    <!-- Populated by JS -->
                </tbody>
            </table>
            
            <div class="pagination" id="pagination">
                <!-- Populated by JS -->
            </div>
            
            <div id="noDataMessage" class="no-data" style="display:none; margin-top: 30px;">
                <h2>No Changes Found</h2>
                <p>No changes match the current filters.</p>
            </div>
        </div>
    </div>
"@

    # Inject JSON data (double quoted to expand variable)
    $html += @"
    <script>
        // Data injected from PowerShell
        const allChanges = $jsonChanges;
    </script>
"@

    # JavaScript logic (SINGLE quoted to preserve JS syntax like ${...} and `...`)
    $html += @'
    <script>
        // State
        let filteredChanges = [...allChanges];
        let currentPage = 1;
        const pageSize = 50;
        
        // DOM Elements
        const tableBody = document.getElementById('changeTableBody');
        const pagination = document.getElementById('pagination');
        const noDataMessage = document.getElementById('noDataMessage');
        const table = document.getElementById('mainChangeTable');
        
        // Security Row Toggle (Server-side rendered)
        function toggleSecurityDetails(row) {
            const detailsRow = row.nextElementSibling;
            if (detailsRow) {
                if (detailsRow.style.display === 'none') {
                    detailsRow.style.display = '';
                    row.classList.add('expanded');
                } else {
                    detailsRow.style.display = 'none';
                    row.classList.remove('expanded');
                }
            }
        }
        
        // Helper to escape HTML for safety
        function escapeHtml(str) {
            if (!str) return '';
            const div = document.createElement('div');
            div.textContent = str;
            return div.innerHTML;
        }
        
        // Helper to get Icon HTML
        function getOperationIcon(type) {
            type = type || '';
            const lowerType = type.toLowerCase();
            let icon = '';
            let className = '';
            
            if (lowerType === 'create') { icon = '+'; className = 'create'; }
            else if (lowerType === 'update') { icon = '~'; className = 'modify'; }
            else if (lowerType === 'delete') { icon = '-'; className = 'delete'; }
            
            if (icon) {
                return `<span class="operation-icon ${className}">${icon}</span>`;
            }
            return '';
        }
        
        // Helper to render ChangedProperties table for Update operations
        function renderChangedProperties(changedPropsJson) {
            if (!changedPropsJson) return '';
            
            try {
                const props = JSON.parse(changedPropsJson);
                if (!props || props.length === 0) return '';
                
                let html = '<div style="margin-top: 15px;"><strong>Changed Properties:</strong><br>';
                html += '<table style="width: 100%; margin-top: 10px; border-collapse: collapse; font-size: 0.9em;">';
                html += '<thead><tr style="background: var(--bg-secondary);"><th style="padding: 8px; text-align: left; border: 1px solid var(--border-color);">Property</th><th style="padding: 8px; text-align: left; border: 1px solid var(--border-color);">From</th><th style="padding: 8px; text-align: left; border: 1px solid var(--border-color);">To</th><th style="padding: 8px; text-align: left; border: 1px solid var(--border-color);">Category</th></tr></thead>';
                html += '<tbody>';
                
                props.forEach(prop => {
                    const propPath = escapeHtml(prop.PropertyPath || '');
                    const prevValue = escapeHtml(String(prop.PreviousValue || ''));
                    const newValue = escapeHtml(String(prop.NewValue || ''));
                    const category = escapeHtml(prop.ChangeCategory || 'User');
                    html += `<tr><td style="padding: 8px; border: 1px solid var(--border-color); font-family: 'Consolas', monospace;">${propPath}</td><td style="padding: 8px; border: 1px solid var(--border-color);">${prevValue}</td><td style="padding: 8px; border: 1px solid var(--border-color);">${newValue}</td><td style="padding: 8px; border: 1px solid var(--border-color);">${category}</td></tr>`;
                });
                
                html += '</tbody></table></div>';
                return html;
            } catch (e) {
                console.error('Failed to parse changed properties:', e);
                return '';
            }
        }

        function getSecurityBadge(flag) {
            if (flag === 'high') return '<span class="security-badge high">High</span>';
            if (flag === 'medium') return '<span class="security-badge medium">Medium</span>';
            return '';
        }
        
        // Render Table
        function renderTable() {
            // Calculate slice
            const start = (currentPage - 1) * pageSize;
            const end = start + pageSize;
            const pageData = filteredChanges.slice(start, end);
            
            // Clear table
            tableBody.innerHTML = '';
            
            if (pageData.length === 0) {
                table.style.display = 'none';
                noDataMessage.style.display = 'block';
                pagination.style.display = 'none';
                return;
            }
            
            table.style.display = '';
            noDataMessage.style.display = 'none';
            pagination.style.display = 'flex';
            
            // Generate Rows
            const fragment = document.createDocumentFragment();
            
            pageData.forEach((item, index) => {
                const tr = document.createElement('tr');
                tr.className = 'change-row';
                
                // Build row HTML safely
                const callerDisplay = item.caller ? escapeHtml(item.caller) : (item.callerType ? `(${escapeHtml(item.callerType)})` : '');
                tr.innerHTML = `
                    <td>${escapeHtml(item.time)}</td>
                    <td>${getOperationIcon(item.type)} ${escapeHtml(item.type)}</td>
                    <td>${escapeHtml(item.sub)}</td>
                    <td>${escapeHtml(item.rg)}</td>
                    <td>${escapeHtml(item.res)}</td>
                    <td>${escapeHtml(item.cat)}</td>
                    <td>${callerDisplay}${item.clientType ? `<br><small style="color: var(--text-muted);">${escapeHtml(item.clientType)}</small>` : ''}</td>
                    <td>${getSecurityBadge(item.sec)}</td>
                `;
                
                // Click handler for details
                tr.addEventListener('click', () => toggleDetails(tr, item));
                
                fragment.appendChild(tr);
                
                // Details row placeholder (created on click or pre-created?)
                // Pre-creating creates too many DOM nodes. Let's create on click or keep hidden?
                // For pagination, creating 50 hidden detail rows is fine.
                
                const detailsTr = document.createElement('tr');
                detailsTr.className = 'change-details-row';
                detailsTr.style.display = 'none';
                
                // Build details content
                let detailsContent = '<div class="change-details"><div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 15px;">';
                
                // Resource ID
                detailsContent += `<div><strong>Resource ID:</strong><br><span style="font-family: 'Consolas', monospace; font-size: 0.85em; word-break: break-all;">${escapeHtml(item.id)}</span></div>`;
                
                // Resource Group
                detailsContent += `<div><strong>Resource Group:</strong><br>${escapeHtml(item.rg)}</div>`;
                
                // Change Source
                detailsContent += `<div><strong>Change Source:</strong><br>${escapeHtml(item.changeSource || 'ChangeAnalysis')}</div>`;
                
                // Operation (RBAC permission used) - show if available
                if (item.operation) {
                    detailsContent += `<div><strong>Operation:</strong><br><span style="font-family: 'Consolas', monospace; font-size: 0.9em;">${escapeHtml(item.operation)}</span></div>`;
                }
                
                // Caller information
                if (item.caller) {
                    let callerInfo = escapeHtml(item.caller);
                    if (item.callerType) {
                        callerInfo += ` (${escapeHtml(item.callerType)})`;
                    }
                    if (item.clientType) {
                        callerInfo += `<br><small style="color: var(--text-muted);">via ${escapeHtml(item.clientType)}</small>`;
                    }
                    detailsContent += `<div><strong>Changed By:</strong><br>${callerInfo}</div>`;
                }
                
                // Security Reason if present
                if (item.sReason) {
                    detailsContent += `<div><strong>Security Reason:</strong><br>${escapeHtml(item.sReason)}</div>`;
                }
                
                detailsContent += '</div>';
                
                // Add ChangedProperties table for Update operations
                if (item.type === 'Update') {
                    if (item.changedProps && item.hasChangeDetails) {
                        detailsContent += renderChangedProperties(item.changedProps);
                    } else {
                        // Show message when change details aren't available
                        detailsContent += '<div style="margin-top: 15px; padding: 12px; background: var(--bg-secondary); border-radius: 6px; border-left: 4px solid var(--accent-yellow);">';
                        detailsContent += '<strong style="color: var(--accent-yellow);">Change Details Not Available</strong><br>';
                        detailsContent += '<span style="color: var(--text-muted); font-size: 0.9em;">';
                        if (item.callerType === 'System') {
                            detailsContent += 'This is a system-initiated change. Property-level change details are not available for system changes in Resource Graph Change Analysis.';
                        } else {
                            detailsContent += 'Property-level change details are not available for this update. Azure Resource Graph Change Analysis does not always provide property-level details for all resource types or operations. The operation shown above indicates the RBAC permission used, but not the specific properties that changed.';
                        }
                        detailsContent += '</span></div>';
                    }
                }
                
                detailsContent += '</div>';
                
                detailsTr.innerHTML = `<td colspan="8">${detailsContent}</td>`;
                fragment.appendChild(detailsTr);
            });
            
            tableBody.appendChild(fragment);
            renderPagination();
        }
        
        function toggleDetails(row, item) {
            const detailsRow = row.nextElementSibling;
            if (detailsRow) {
                if (detailsRow.style.display === 'none') {
                    detailsRow.style.display = '';
                    row.classList.add('expanded');
                } else {
                    detailsRow.style.display = 'none';
                    row.classList.remove('expanded');
                }
            }
        }
        
        function renderPagination() {
            const totalPages = Math.ceil(filteredChanges.length / pageSize);
            pagination.innerHTML = '';
            
            if (totalPages <= 1) return;
            
            // Previous
            const prevBtn = document.createElement('button');
            prevBtn.textContent = 'Previous';
            prevBtn.disabled = currentPage === 1;
            prevBtn.onclick = () => { if (currentPage > 1) { currentPage--; renderTable(); } };
            pagination.appendChild(prevBtn);
            
            // Page Info
            const info = document.createElement('span');
            info.className = 'page-info';
            info.textContent = `Page ${currentPage} of ${totalPages} (${filteredChanges.length} items)`;
            pagination.appendChild(info);
            
            // Next
            const nextBtn = document.createElement('button');
            nextBtn.textContent = 'Next';
            nextBtn.disabled = currentPage === totalPages;
            nextBtn.onclick = () => { if (currentPage < totalPages) { currentPage++; renderTable(); } };
            pagination.appendChild(nextBtn);
        }
        
        // Filtering
        function applyFilters() {
            const searchText = document.getElementById('searchFilter').value.toLowerCase();
            const subscriptionValue = document.getElementById('subscriptionFilter').value;
            const typeValue = document.getElementById('typeFilter').value;
            const categoryValue = document.getElementById('categoryFilter').value;
            const resourceGroupValue = document.getElementById('resourceGroupFilter').value;
            const callerTypeValue = document.getElementById('callerTypeFilter').value;
            
            filteredChanges = allChanges.filter(item => {
                const searchMatch = !searchText || item.search.includes(searchText);
                const subMatch = subscriptionValue === 'all' || item.subLower === subscriptionValue;
                const typeMatch = typeValue === 'all' || item.type === typeValue;
                const categoryMatch = categoryValue === 'all' || item.catLower === categoryValue.toLowerCase();
                const rgMatch = resourceGroupValue === 'all' || item.rgLower === resourceGroupValue.toLowerCase();
                const callerTypeMatch = callerTypeValue === 'all' || (item.callerType && item.callerType.toLowerCase() === callerTypeValue.toLowerCase());
                
                return searchMatch && subMatch && typeMatch && categoryMatch && rgMatch && callerTypeMatch;
            });
            
            currentPage = 1;
            renderTable();
        }
        
        // Filter Event Listeners
        document.getElementById('searchFilter').addEventListener('input', applyFilters);
        document.getElementById('subscriptionFilter').addEventListener('change', applyFilters);
        document.getElementById('typeFilter').addEventListener('change', applyFilters);
        document.getElementById('categoryFilter').addEventListener('change', applyFilters);
        document.getElementById('resourceGroupFilter').addEventListener('change', applyFilters);
        document.getElementById('callerTypeFilter').addEventListener('change', applyFilters);
        
        // Global functions for Summary Cards
        window.setFilter = function(filterType, value) {
            if (filterType === 'Type') {
                const select = document.getElementById('typeFilter');
                if (select) {
                    select.value = value;
                    applyFilters();
                    // Scroll to filter section
                    document.querySelector('.filter-section').scrollIntoView({ behavior: 'smooth' });
                }
            }
        };
        
        window.filterByDate = function(dateStr) {
            const searchInput = document.getElementById('searchFilter');
            if (searchInput) {
                // Set search to the date string (simple way to filter by date since we include time in search index)
                // Note: The date format in chart is yyyy-MM-dd. Our search index includes time yyyy-MM-dd HH:mm.
                // Searching for yyyy-MM-dd should work.
                searchInput.value = dateStr;
                applyFilters();
                // Scroll to filter section
                document.querySelector('.filter-section').scrollIntoView({ behavior: 'smooth' });
            }
        };
        
        window.scrollToSecurity = function() {
            const el = document.getElementById('security-alerts-section');
            if (el) {
                el.scrollIntoView({ behavior: 'smooth' });
                const details = el.querySelector('details');
                if (details) details.open = true;
            }
        };
        
        // Initial Render
        renderTable();
    </script>
</body>
</html>
'@
    
    $html += "</body></html>"
    
    # Write to file
    $html | Out-File -FilePath $OutputPath -Encoding UTF8
    
    # Return metadata for Dashboard
    return @{
        OutputPath = $OutputPath
        TotalChanges = $totalChanges
        Creates = $creates
        Updates = $updates
        Deletes = $deletes
        HighSecurityFlags = $highSecurityFlags
        MediumSecurityFlags = $mediumSecurityFlags
    }
}
