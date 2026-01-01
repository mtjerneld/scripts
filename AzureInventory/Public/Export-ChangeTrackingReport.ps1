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
    
    # Changes by day and type (for stacked chart) - use ChangeTime instead of Timestamp
    # Group changes by day and type
    $changesGrouped = $ChangeTrackingData | 
        Where-Object { $_.ChangeTime -and $_.ChangeType } |
        Group-Object { 
            $dateKey = if ($_.ChangeTime -is [DateTime]) {
                $_.ChangeTime.ToString('yyyy-MM-dd')
            } else {
                try {
                    ([DateTime]$_.ChangeTime).ToString('yyyy-MM-dd')
                } catch {
                    (Get-Date).ToString('yyyy-MM-dd')
                }
            }
            "$dateKey|$($_.ChangeType)"
        }
    
    # Create a nested hashtable for quick lookup: $changesByDateAndType[date][type] = count
    $changesByDateAndType = @{}
    foreach ($group in $changesGrouped) {
        $parts = $group.Name -split '\|'
        $dateKey = $parts[0]
        $type = $parts[1]
        if (-not $changesByDateAndType.ContainsKey($dateKey)) {
            $changesByDateAndType[$dateKey] = @{}
        }
        $changesByDateAndType[$dateKey][$type] = $group.Count
    }
    
    # Get all unique change types
    $allChangeTypes = @($ChangeTrackingData | Where-Object { $_.ChangeType } | Select-Object -ExpandProperty ChangeType -Unique | Sort-Object)
    
    # Generate all 14 days (from 13 days ago to today, inclusive)
    $today = (Get-Date).Date
    $changesByDay = @()
    for ($i = 13; $i -ge 0; $i--) {
        $date = $today.AddDays(-$i)
        $dateKey = $date.ToString('yyyy-MM-dd')
        $dayData = @{ Date = $date; Types = @{}; Total = 0 }
        foreach ($type in $allChangeTypes) {
            $count = if ($changesByDateAndType.ContainsKey($dateKey) -and $changesByDateAndType[$dateKey].ContainsKey($type)) {
                $changesByDateAndType[$dateKey][$type]
            } else {
                0
            }
            $dayData.Types[$type] = $count
            $dayData.Total += $count
        }
        $changesByDay += [PSCustomObject]$dayData
    }
    
    # Security alerts (high and medium priority)
    $securityAlerts = @($ChangeTrackingData | Where-Object { $_.SecurityFlag -in @('high', 'medium') } | Sort-Object ChangeTime -Descending)
    
    # Get unique subscriptions for filter
    $allSubscriptions = @($ChangeTrackingData | Select-Object -ExpandProperty SubscriptionName -Unique | Sort-Object)
    
    # Get unique resource groups for filter
    $allResourceGroups = @($ChangeTrackingData | Where-Object { $_.ResourceGroup } | Select-Object -ExpandProperty ResourceGroup -Unique | Sort-Object)
    
    # Get unique change types for filter
    $allChangeTypes = @($ChangeTrackingData | Where-Object { $_.ChangeType } | Select-Object -ExpandProperty ChangeType -Unique | Sort-Object)
    
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
    </style>
</head>
<body>
    $(Get-ReportNavigation -ActivePage "ChangeTracking")
    
    <div class="container">
        <div class="page-header">
            <h1>&#128202; Change Tracking (14 days)</h1>
            <div class="metadata">
                <p><strong>Tenant:</strong> $TenantId</p>
                <p><strong>Scanned:</strong> $timestamp</p>
                <p><strong>Subscriptions:</strong> $subscriptionCount</p>
                <p><strong>Resources:</strong> $totalChanges</p>
                <p><strong>Total Findings:</strong> $totalChanges</p>
            </div>
        </div>
        
        <div class="section-box">
            <h2>Change Overview</h2>
            <div class="summary-grid">
                <div class="summary-card green-border" onclick="setFilter('Type', 'Create')">
                    <div class="summary-card-value" id="summary-creates">$creates</div>
                    <div class="summary-card-label">Created</div>
                </div>
                <div class="summary-card blue-border" onclick="setFilter('Type', 'Update')">
                    <div class="summary-card-value" id="summary-updates">$updates</div>
                    <div class="summary-card-label">Updated</div>
                </div>
                <div class="summary-card red-border" onclick="setFilter('Type', 'Delete')">
                    <div class="summary-card-value" id="summary-deletes">$deletes</div>
                    <div class="summary-card-label">Deleted</div>
                </div>
                <div class="summary-card orange-border" onclick="scrollToSecurity()">
                    <div class="summary-card-value" id="summary-security">$totalSecurityAlerts</div>
                    <div class="summary-card-label">Sensitive Operations</div>
                </div>
            </div>
        </div>
        
        <div class="section-box">
            <h2>Changes Over Time (14 days)</h2>
            <div class="trend-chart" id="trend-chart-container">
                <div class="chart-bars">
"@
    
    # Generate stacked bars and labels - always show all 14 days
    $barsHtml = ""
    $labelsHtml = ""
    
    # Calculate max count for scaling (use at least 1 to avoid division by zero)
    $maxCount = ($changesByDay | Measure-Object -Property Total -Maximum).Maximum
    if ($maxCount -eq 0) { $maxCount = 1 }
    
    # Color mapping for change types
    $typeColors = @{
        'Create' = 'var(--accent-green)'
        'Update' = 'var(--accent-blue)'
        'Delete' = 'var(--accent-red)'
        'Action' = 'var(--accent-orange)'
    }
    
    $totalDays = $changesByDay.Count
    $i = 0
    
    foreach ($day in $changesByDay) {
        $dateStr = $day.Date.ToString('yyyy-MM-dd')
        
        # Calculate total height percentage for the container
        $totalHeight = if ($day.Total -eq 0) {
            2  # 2% for zero days
        } else {
            $calculated = [math]::Round(($day.Total / $maxCount) * 100, 0)
            if ($calculated -lt 5) { 5 } else { $calculated }
        }
        
        # Set height on the container
        $barHtml = "                    <div class='chart-bar-stack' style='height: ${totalHeight}%;' onclick='filterByDate(`"$dateStr`")' title='${dateStr}: $($day.Total) changes'>`n"
        
        if ($day.Total -eq 0) {
            # Empty day - show a thin border
            $barHtml += "                        <div class='chart-bar-segment' style='background: var(--border-color); height: 100%;'></div>`n"
        } else {
            # Build segments for each type (bottom to top)
            $segments = @()
            foreach ($type in $allChangeTypes) {
                $typeCount = $day.Types[$type]
                if ($typeCount -gt 0) {
                    $segmentHeight = [math]::Round(($typeCount / $day.Total) * 100, 1)
                    $color = if ($typeColors.ContainsKey($type)) { $typeColors[$type] } else { 'var(--accent-blue)' }
                    $segments += "                        <div class='chart-bar-segment' style='background: $color; height: ${segmentHeight}%;' title='$type : $typeCount'></div>`n"
                }
            }
            
            # Add segments
            $barHtml += ($segments -join '')
        }
        
        $barHtml += "                    </div>`n"
        $barsHtml += $barHtml
        
        # Show labels for first, last, and every 7th day
        $showLabel = ($i -eq 0) -or ($i -eq ($totalDays - 1)) -or ($i % 7 -eq 0)
        $visibility = if ($showLabel) { "visible" } else { "hidden" }
        
        $dateLabel = $day.Date.ToString('yyyy-MM-dd')
        
        # Align labels to match bars: center for most, left for first, right for last
        $textAlign = "center"
        if ($i -eq 0) { $textAlign = "left" }
        elseif ($i -eq ($totalDays - 1)) { $textAlign = "right" }
        
        $labelClass = "chart-label"
        if ($textAlign -ne "center") {
            $labelClass += " chart-label--$textAlign"
        }
        if (-not $showLabel) {
            $labelClass += " chart-label--hidden"
        }
        $labelsHtml += "                    <div class='$labelClass'>$dateLabel</div>`n"
        
        $i++
    }
    $html += $barsHtml
    
    $html += @"
                </div>
                <div class="chart-labels">
                    $labelsHtml
                </div>
                <div class="chart-legend">
"@
    
    # Generate legend items for all change types that exist in data
    foreach ($type in $allChangeTypes) {
        $colorClass = switch ($type) {
            'Create' { 'chart-legend-color--create' }
            'Update' { 'chart-legend-color--update' }
            'Delete' { 'chart-legend-color--delete' }
            'Action' { 'chart-legend-color--action' }
            default { 'chart-legend-color--update' }
        }
        $escapedType = Encode-Html $type
        $html += "                    <div class='chart-legend-item'><div class='chart-legend-color $colorClass'></div><span>$escapedType</span></div>`n"
    }
    
    $html += @"
                </div>
            </div>
        </div>
        
        <div class="section-box">
            <h2>Top 5</h2>
            <div class="insights-grid">
                <div class="insights-panel">
                    <h3>Changed Resource Types</h3>
                    <ul class="insights-list" id="insights-resource-types">
"@
    
    foreach ($resType in $topResourceTypes) {
        $escapedType = Encode-Html $resType.ResourceType
        $html += "                        <li><strong>$escapedType</strong> ($($resType.Count) changes)</li>`n"
    }
    
    if ($topResourceTypes.Count -eq 0) {
        $html += "                        <li class='text-muted'>No resource type data available</li>`n"
    }
    
    $html += @"
                    </ul>
                </div>
                
                <div class="insights-panel">
                    <h3>Changes by Category</h3>
                    <ul class="insights-list" id="insights-categories">
"@
    
    $changesByCategory = $ChangeTrackingData | 
        Group-Object ResourceCategory | 
        Sort-Object Count -Descending | 
        Select-Object -First 5 |
        ForEach-Object { [PSCustomObject]@{ Category = $_.Name; Count = $_.Count } }
    
    foreach ($cat in $changesByCategory) {
        $escapedCat = Encode-Html $cat.Category
        $html += "                        <li><strong>$escapedCat</strong> ($($cat.Count) changes)</li>`n"
    }
    
    if ($changesByCategory.Count -eq 0) {
        $html += "                        <li class='text-muted'>No category data available</li>`n"
    }
    
    $html += @"
                    </ul>
                </div>
                
                <div class="insights-panel">
                    <h3>Changes by Caller</h3>
                    <ul class="insights-list" id="insights-callers">
"@
    
    $changesByCaller = $ChangeTrackingData | 
        Where-Object { $_.Caller } |
        Group-Object Caller | 
        Sort-Object Count -Descending | 
        Select-Object -First 5 |
        ForEach-Object { [PSCustomObject]@{ Caller = $_.Name; Count = $_.Count } }
    
    foreach ($caller in $changesByCaller) {
        $escapedCaller = Encode-Html $caller.Caller
        $html += "                        <li><strong>$escapedCaller</strong> ($($caller.Count) changes)</li>`n"
    }
    
    if ($changesByCaller.Count -eq 0) {
        $html += "                        <li class='text-muted'>No caller data available</li>`n"
    }
    
    $html += @"
                    </ul>
                </div>
                
                <div class="insights-panel">
                    <h3>Changes by Subscription</h3>
                    <ul class="insights-list" id="insights-subscriptions">
"@
    
    $changesBySubscription = $ChangeTrackingData | 
        Where-Object { $_.SubscriptionName } |
        Group-Object SubscriptionName | 
        Sort-Object Count -Descending | 
        Select-Object -First 5 |
        ForEach-Object { [PSCustomObject]@{ Subscription = $_.Name; Count = $_.Count } }
    
    foreach ($sub in $changesBySubscription) {
        $escapedSub = Encode-Html $sub.Subscription
        $html += "                        <li><strong>$escapedSub</strong> ($($sub.Count) changes)</li>`n"
    }
    
    if ($changesBySubscription.Count -eq 0) {
        $html += "                        <li class='text-muted'>No subscription data available</li>`n"
    }
    
    $html += @"
                    </ul>
                </div>
            </div>
        </div>
        
        $(if ($securityAlerts.Count -gt 0) {
            $alertsHtml = @"
        <div class="section-box" id="security-alerts-section">
            <h2>Security-Sensitive Operations</h2>
            <details>
                <summary>
                    <h3>Sensitive Operations ($($securityAlerts.Count))</h3>
                    <span>(Click to expand)</span>
                </summary>
                <div>
                    <table class="data-table">
                        <thead>
                            <tr>
                                <th>Time</th>
                                <th>Type</th>
                                <th>Sensitivity</th>
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
                    'Action' { '<span class="operation-icon action">></span>' }
                    default { '' }
                }
                
                $escapedReason = if ($alert.SecurityReason) { Encode-Html ([string]$alert.SecurityReason) } else { '' }
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
                
                $badgeModifier = if ($alertClass -eq 'high') { 'danger' } else { 'warning' }
                $securityBadge = "<span class='badge badge--$badgeModifier'>$($alert.SecurityFlag.Substring(0,1).ToUpper() + $alert.SecurityFlag.Substring(1))</span>"
                
                $alertsHtml += @"
                            <tr class="security-row" onclick="toggleSecurityDetails(this)">
                                <td>$timeStr</td>
                                <td>$operationIcon $changeType</td>
                                <td>$securityBadge</td>
                                <td>$escapedResource</td>
                                <td>$escapedResType</td>
                            </tr>
                            <tr class="change-details-row">
                                <td colspan="5">
                                    <div class="change-details">
                                        <div class="change-details-grid">
                                            <div>
                                                <strong>Security Alert:</strong><br>
                                                <span class="security-alert-text">$escapedReason</span>
                                            </div>
                                            <div>
                                                <strong>Change Source:</strong><br>
                                                <span class="monospace-medium">$($alert.ChangeSource)</span>
                                            </div>
                                            
                                            <div>
                                                <strong>Resource ID:</strong><br>
                                                <span class="monospace">$escapedResId</span>
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
        
        <div class="section-box">
            <h2>Filters</h2>
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
"@
    
    foreach ($changeType in $allChangeTypes) {
        $escapedType = Encode-Html $changeType
        $html += "                    <option value=`"$escapedType`">$escapedType</option>`n"
    }
    
    $html += @"
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
                <label>Sensitivity:</label>
                <select id="sensitivityFilter">
                    <option value="all">All Sensitivity Levels</option>
"@
    
    foreach ($sensitivity in $allSensitivityLevels) {
        $escapedSensitivity = Encode-Html $sensitivity
        $displayName = $sensitivity.Substring(0,1).ToUpper() + $sensitivity.Substring(1)
        $html += "                    <option value=`"$escapedSensitivity`">$displayName</option>`n"
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
            <div class="filter-stats">
                Showing <span id="visibleCount">$totalChanges</span> of <span id="totalCount">$totalChanges</span> changes
            </div>
        </div>
        
        <div class="section-box">
            <h2>Change Log</h2>
            <div id="table-container">
            <table class="data-table" id="mainChangeTable">
                <thead>
                    <tr>
                        <th>Time</th>
                        <th>Type</th>
                        <th>Subscription</th>
                        <th>Resource Group</th>
                        <th>Resource</th>
                        <th>Category</th>
                        <th>Caller</th>
                        <th>Sensitivity</th>
                    </tr>
                </thead>
                <tbody id="changeTableBody">
                    <!-- Populated by JS -->
                </tbody>
            </table>
            
            <div class="pagination" id="pagination">
                <!-- Populated by JS -->
            </div>
            
            <div id="noDataMessage" class="no-data">
                <h2>No Changes Found</h2>
                <p>No changes match the current filters.</p>
            </div>
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
                if (detailsRow.classList.contains('is-visible')) {
                    detailsRow.classList.remove('is-visible');
                    row.classList.remove('expanded');
                } else {
                    detailsRow.classList.add('is-visible');
                    row.classList.add('expanded');
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
            else if (lowerType === 'action') { icon = '>'; className = 'action'; }
            
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
                
                let html = '<div class="changed-properties-container"><strong>Changed Properties:</strong><br>';
                html += '<table class="changed-properties-table"><thead><tr><th>Property</th><th>From</th><th>To</th><th>Category</th></tr></thead><tbody>';
                
                props.forEach(prop => {
                    const propPath = escapeHtml(prop.PropertyPath || '');
                    const prevValue = escapeHtml(String(prop.PreviousValue || ''));
                    const newValue = escapeHtml(String(prop.NewValue || ''));
                    const category = escapeHtml(prop.ChangeCategory || 'User');
                    html += `<tr><td class="property-path">${propPath}</td><td>${prevValue}</td><td>${newValue}</td><td>${category}</td></tr>`;
                });
                
                html += '</tbody></table></div>';
                return html;
            } catch (e) {
                console.error('Failed to parse changed properties:', e);
                return '';
            }
        }

        function getSecurityBadge(flag) {
            if (flag === 'high') return '<span class="badge badge--danger">High</span>';
            if (flag === 'medium') return '<span class="badge badge--warning">Medium</span>';
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
                noDataMessage.classList.add('is-visible');
                pagination.style.display = 'none';
                return;
            }
            
            table.style.display = '';
            noDataMessage.classList.remove('is-visible');
            pagination.style.display = '';
            
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
                    <td>${callerDisplay}${item.clientType ? `<br><small class="text-muted">${escapeHtml(item.clientType)}</small>` : ''}</td>
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
                
                // Build details content
                let detailsContent = '<div class="change-details"><div class="change-details-grid">';
                
                // Resource ID
                detailsContent += `<div><strong>Resource ID:</strong><br><span class="monospace">${escapeHtml(item.id)}</span></div>`;
                
                // Resource Group
                detailsContent += `<div><strong>Resource Group:</strong><br>${escapeHtml(item.rg)}</div>`;
                
                // Change Source
                detailsContent += `<div><strong>Change Source:</strong><br>${escapeHtml(item.changeSource || 'ChangeAnalysis')}</div>`;
                
                // Operation (RBAC permission used) - show if available
                if (item.operation) {
                    detailsContent += `<div><strong>Operation:</strong><br><span class="monospace-medium">${escapeHtml(item.operation)}</span></div>`;
                }
                
                // Caller information
                if (item.caller) {
                    let callerInfo = escapeHtml(item.caller);
                    if (item.callerType) {
                        callerInfo += ` (${escapeHtml(item.callerType)})`;
                    }
                    if (item.clientType) {
                        callerInfo += `<br><small class="text-muted">via ${escapeHtml(item.clientType)}</small>`;
                    }
                    detailsContent += `<div><strong>Changed By:</strong><br>${callerInfo}</div>`;
                }
                
                // Security Reason if present
                if (item.sReason) {
                    detailsContent += `<div><strong>Security Reason:</strong><br><span class="security-alert-text">${escapeHtml(item.sReason)}</span></div>`;
                }
                
                detailsContent += '</div>';
                
                // Add ChangedProperties table for Update operations
                if (item.type === 'Update') {
                    if (item.changedProps && item.hasChangeDetails) {
                        detailsContent += renderChangedProperties(item.changedProps);
                    } else {
                        // Show message when change details aren't available
                        detailsContent += '<div class="change-details-unavailable">';
                        detailsContent += '<strong>Change Details Not Available</strong><br>';
                        detailsContent += '<span>';
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
                if (detailsRow.classList.contains('is-visible')) {
                    detailsRow.classList.remove('is-visible');
                    row.classList.remove('expanded');
                } else {
                    detailsRow.classList.add('is-visible');
                    row.classList.add('expanded');
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
        
        // Update Summary Cards
        function updateSummaryCards() {
            const creates = filteredChanges.filter(item => item.type === 'Create').length;
            const updates = filteredChanges.filter(item => item.type === 'Update').length;
            const deletes = filteredChanges.filter(item => item.type === 'Delete').length;
            const security = filteredChanges.filter(item => item.sec === 'high' || item.sec === 'medium').length;
            
            const createsEl = document.getElementById('summary-creates');
            const updatesEl = document.getElementById('summary-updates');
            const deletesEl = document.getElementById('summary-deletes');
            const securityEl = document.getElementById('summary-security');
            
            if (createsEl) createsEl.textContent = creates;
            if (updatesEl) updatesEl.textContent = updates;
            if (deletesEl) deletesEl.textContent = deletes;
            if (securityEl) securityEl.textContent = security;
        }
        
        // Update Trend Chart
        function updateTrendChart() {
            // Group changes by day and type
            const changesByDateAndType = {};
            const today = new Date();
            today.setHours(0, 0, 0, 0);
            
            // Get all unique types
            const allTypes = [...new Set(filteredChanges.filter(item => item.type).map(item => item.type))].sort();
            
            filteredChanges.forEach(item => {
                if (item.time && item.type) {
                    try {
                        const changeDate = new Date(item.time);
                        changeDate.setHours(0, 0, 0, 0);
                        const dateKey = changeDate.toISOString().split('T')[0];
                        if (!changesByDateAndType[dateKey]) {
                            changesByDateAndType[dateKey] = {};
                        }
                        if (!changesByDateAndType[dateKey][item.type]) {
                            changesByDateAndType[dateKey][item.type] = 0;
                        }
                        changesByDateAndType[dateKey][item.type]++;
                    } catch (e) {
                        // Skip invalid dates
                    }
                }
            });
            
            // Generate 14 days (from 13 days ago to today)
            const days = [];
            for (let i = 13; i >= 0; i--) {
                const date = new Date(today);
                date.setDate(date.getDate() - i);
                const dateKey = date.toISOString().split('T')[0];
                const dayData = { date: dateKey, types: {}, total: 0 };
                allTypes.forEach(type => {
                    const count = (changesByDateAndType[dateKey] && changesByDateAndType[dateKey][type]) || 0;
                    dayData.types[type] = count;
                    dayData.total += count;
                });
                days.push(dayData);
            }
            
            // Calculate max for scaling
            const maxCount = Math.max(...days.map(d => d.total), 1);
            
            // Color mapping
            const typeColors = {
                'Create': 'var(--accent-green)',
                'Update': 'var(--accent-blue)',
                'Delete': 'var(--accent-red)',
                'Action': 'var(--accent-orange)'
            };
            
            // Update chart bars
            const chartBars = document.querySelector('#trend-chart-container .chart-bars');
            const chartLabels = document.querySelector('#trend-chart-container .chart-labels');
            const chartLegend = document.querySelector('#trend-chart-container .chart-legend');
            
            if (chartBars && chartLabels) {
                chartBars.innerHTML = '';
                chartLabels.innerHTML = '';
                
                // Update legend if it exists
                if (chartLegend) {
                    chartLegend.innerHTML = '';
                    allTypes.forEach(type => {
                        const colorClass = type === 'Create' ? 'chart-legend-color--create' :
                                          type === 'Update' ? 'chart-legend-color--update' :
                                          type === 'Delete' ? 'chart-legend-color--delete' :
                                          type === 'Action' ? 'chart-legend-color--action' :
                                          'chart-legend-color--update';
                        const legendItem = document.createElement('div');
                        legendItem.className = 'chart-legend-item';
                        legendItem.innerHTML = `<div class="chart-legend-color ${colorClass}"></div><span>${escapeHtml(type)}</span>`;
                        chartLegend.appendChild(legendItem);
                    });
                }
                
                days.forEach((day, index) => {
                    // Calculate total height percentage for the container
                    const totalHeight = day.total === 0 ? 2 : 
                        Math.max(5, Math.round((day.total / maxCount) * 100));
                    
                    // Create stacked bar container
                    const barStack = document.createElement('div');
                    barStack.className = 'chart-bar-stack';
                    barStack.style.height = totalHeight + '%';
                    barStack.title = `${day.date}: ${day.total} changes`;
                    barStack.onclick = () => filterByDate(day.date);
                    
                    if (day.total === 0) {
                        // Empty day
                        const segment = document.createElement('div');
                        segment.className = 'chart-bar-segment';
                        segment.style.background = 'var(--border-color)';
                        segment.style.height = '100%';
                        barStack.appendChild(segment);
                    } else {
                        // Create segments for each type
                        allTypes.forEach(type => {
                            const typeCount = day.types[type] || 0;
                            if (typeCount > 0) {
                                const segmentHeight = Math.round((typeCount / day.total) * 100 * 10) / 10;
                                const segment = document.createElement('div');
                                segment.className = 'chart-bar-segment';
                                segment.style.background = typeColors[type] || 'var(--accent-blue)';
                                segment.style.height = segmentHeight + '%';
                                segment.title = `${type}: ${typeCount}`;
                                barStack.appendChild(segment);
                            }
                        });
                    }
                    
                    chartBars.appendChild(barStack);
                    
                    // Labels (first, last, every 7th)
                    const showLabel = index === 0 || index === days.length - 1 || index % 7 === 0;
                    const label = document.createElement('div');
                    label.className = 'chart-label' + 
                        (index === 0 ? ' chart-label--left' : '') +
                        (index === days.length - 1 ? ' chart-label--right' : '') +
                        (!showLabel ? ' chart-label--hidden' : '');
                    label.textContent = day.date;
                    chartLabels.appendChild(label);
                });
            }
        }
        
        // Update Top 5 Insights
        function updateTop5Insights() {
            // Resource Types
            const resourceTypes = {};
            filteredChanges.forEach(item => {
                if (item.resType) {
                    resourceTypes[item.resType] = (resourceTypes[item.resType] || 0) + 1;
                }
            });
            const topResourceTypes = Object.entries(resourceTypes)
                .sort((a, b) => b[1] - a[1])
                .slice(0, 5);
            
            const resTypesEl = document.getElementById('insights-resource-types');
            if (resTypesEl) {
                resTypesEl.innerHTML = '';
                if (topResourceTypes.length === 0) {
                    resTypesEl.innerHTML = '<li class="text-muted">No resource type data available</li>';
                } else {
                    topResourceTypes.forEach(([type, count]) => {
                        const li = document.createElement('li');
                        li.innerHTML = `<strong>${escapeHtml(type)}</strong> (${count} changes)`;
                        resTypesEl.appendChild(li);
                    });
                }
            }
            
            // Categories
            const categories = {};
            filteredChanges.forEach(item => {
                if (item.cat) {
                    categories[item.cat] = (categories[item.cat] || 0) + 1;
                }
            });
            const topCategories = Object.entries(categories)
                .sort((a, b) => b[1] - a[1])
                .slice(0, 5);
            
            const categoriesEl = document.getElementById('insights-categories');
            if (categoriesEl) {
                categoriesEl.innerHTML = '';
                if (topCategories.length === 0) {
                    categoriesEl.innerHTML = '<li class="text-muted">No category data available</li>';
                } else {
                    topCategories.forEach(([cat, count]) => {
                        const li = document.createElement('li');
                        li.innerHTML = `<strong>${escapeHtml(cat)}</strong> (${count} changes)`;
                        categoriesEl.appendChild(li);
                    });
                }
            }
            
            // Callers
            const callers = {};
            filteredChanges.forEach(item => {
                if (item.caller) {
                    callers[item.caller] = (callers[item.caller] || 0) + 1;
                }
            });
            const topCallers = Object.entries(callers)
                .sort((a, b) => b[1] - a[1])
                .slice(0, 5);
            
            const callersEl = document.getElementById('insights-callers');
            if (callersEl) {
                callersEl.innerHTML = '';
                if (topCallers.length === 0) {
                    callersEl.innerHTML = '<li class="text-muted">No caller data available</li>';
                } else {
                    topCallers.forEach(([caller, count]) => {
                        const li = document.createElement('li');
                        li.innerHTML = `<strong>${escapeHtml(caller)}</strong> (${count} changes)`;
                        callersEl.appendChild(li);
                    });
                }
            }
            
            // Subscriptions
            const subscriptions = {};
            filteredChanges.forEach(item => {
                if (item.sub) {
                    subscriptions[item.sub] = (subscriptions[item.sub] || 0) + 1;
                }
            });
            const topSubscriptions = Object.entries(subscriptions)
                .sort((a, b) => b[1] - a[1])
                .slice(0, 5);
            
            const subscriptionsEl = document.getElementById('insights-subscriptions');
            if (subscriptionsEl) {
                subscriptionsEl.innerHTML = '';
                if (topSubscriptions.length === 0) {
                    subscriptionsEl.innerHTML = '<li class="text-muted">No subscription data available</li>';
                } else {
                    topSubscriptions.forEach(([sub, count]) => {
                        const li = document.createElement('li');
                        li.innerHTML = `<strong>${escapeHtml(sub)}</strong> (${count} changes)`;
                        subscriptionsEl.appendChild(li);
                    });
                }
            }
        }
        
        // Filtering
        function applyFilters() {
            const searchText = document.getElementById('searchFilter').value.toLowerCase();
            const subscriptionValue = document.getElementById('subscriptionFilter').value;
            const typeValue = document.getElementById('typeFilter').value;
            const categoryValue = document.getElementById('categoryFilter').value;
            const sensitivityValue = document.getElementById('sensitivityFilter').value;
            const callerTypeValue = document.getElementById('callerTypeFilter').value;
            
            filteredChanges = allChanges.filter(item => {
                const searchMatch = !searchText || item.search.includes(searchText);
                const subMatch = subscriptionValue === 'all' || item.subLower === subscriptionValue;
                const typeMatch = typeValue === 'all' || item.type === typeValue;
                const categoryMatch = categoryValue === 'all' || item.catLower === categoryValue.toLowerCase();
                const sensitivityMatch = sensitivityValue === 'all' || (item.sec && item.sec.toLowerCase() === sensitivityValue.toLowerCase());
                const callerTypeMatch = callerTypeValue === 'all' || (item.callerType && item.callerType.toLowerCase() === callerTypeValue.toLowerCase());
                
                return searchMatch && subMatch && typeMatch && categoryMatch && sensitivityMatch && callerTypeMatch;
            });
            
            currentPage = 1;
            
            // Update all sections based on filtered data
            updateSummaryCards();
            updateTrendChart();
            updateTop5Insights();
            renderTable();
        }
        
        // Filter Event Listeners
        document.getElementById('searchFilter').addEventListener('input', applyFilters);
        document.getElementById('subscriptionFilter').addEventListener('change', applyFilters);
        document.getElementById('typeFilter').addEventListener('change', applyFilters);
        document.getElementById('categoryFilter').addEventListener('change', applyFilters);
        document.getElementById('sensitivityFilter').addEventListener('change', applyFilters);
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

