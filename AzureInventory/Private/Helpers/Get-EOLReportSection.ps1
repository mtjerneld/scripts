<#
.SYNOPSIS
    Generates the HTML section for End of Life (EOL) tracking in the Security report.

.PARAMETER EOLStatus
    Array of EOL status objects as returned by Get-EOLStatus.
#>
function Get-EOLReportSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$EOLStatus
    )

    $items = @($EOLStatus)
    $total = $items.Count

    if ($total -eq 0) {
        return @"
        <div class="section" id="eol-section">
            <div class="section-header">
                <h2>End of Life (EOL) Tracking</h2>
            </div>
            <div class="section-content" id="eol-content">
                <div style="padding: 20px; text-align: center; color: var(--text-secondary);">
                    <p style="margin: 0; font-size: 1.1em;">No EOL services detected for the scanned subscriptions.</p>
                </div>
            </div>
        </div>
"@
    }

    # Pre-calc counts
    $criticalCount = @($items | Where-Object { $_.Severity -eq 'Critical' }).Count
    $highCount = @($items | Where-Object { $_.Severity -eq 'High' }).Count
    $mediumCount = @($items | Where-Object { $_.Severity -eq 'Medium' }).Count
    $lowCount = @($items | Where-Object { $_.Severity -eq 'Low' }).Count

    $html = @"
        <div class="section" id="eol-section">
            <div class="section-header" onclick="toggleEolSection()">
                <h2>End of Life (EOL) Tracking</h2>
                <span class="toggle-icon" id="eol-toggle-icon">▼</span>
            </div>
            <div class="section-content" id="eol-content">
                <div class="eol-summary-cards">
                    <div class="eol-card eol-critical">
                        <h3>Critical (&lt; 30d)</h3>
                        <p class="number">$criticalCount</p>
                        <p class="label">Components</p>
                    </div>
                    <div class="eol-card eol-high">
                        <h3>High (&lt; 90d)</h3>
                        <p class="number">$highCount</p>
                        <p class="label">Components</p>
                    </div>
                    <div class="eol-card eol-medium">
                        <h3>Medium (&lt; 180d)</h3>
                        <p class="number">$mediumCount</p>
                        <p class="label">Components</p>
                    </div>
                    <div class="eol-card eol-low">
                        <h3>Low (&ge; 180d)</h3>
                        <p class="number">$lowCount</p>
                        <p class="label">Components</p>
                    </div>
                </div>

                <div class="eol-filter-section">
                    <input type="text" id="eol-search" placeholder="Search components, actions, resources...">
                    <select id="eol-severity-filter">
                        <option value="all">All Severities</option>
                        <option value="Critical">Critical</option>
                        <option value="High">High</option>
                        <option value="Medium">Medium</option>
                        <option value="Low">Low</option>
                    </select>
                    <select id="eol-status-filter">
                        <option value="all">All Statuses</option>
                        <option value="RETIRED">Retired</option>
                        <option value="DEPRECATED">Deprecated</option>
                        <option value="ANNOUNCED">Announced</option>
                        <option value="UNKNOWN">Unknown</option>
                    </select>
                    <span id="eol-result-count" class="result-count">Showing $total components</span>
                </div>

                <div class="eol-items">
"@

    # Sort: severity (Critical..Low), then days until deadline ascending, then component
    $severityOrder = @{ "Critical" = 0; "High" = 1; "Medium" = 2; "Low" = 3 }
    $sorted = $items | Sort-Object {
        $sev = if ($severityOrder.ContainsKey($_.Severity)) { $severityOrder[$_.Severity] } else { 99 }
        $days = if ($_.DaysUntilDeadline -ne $null) { $_.DaysUntilDeadline } else { 99999 }
        "$sev|$days|$($_.Component)"
    }

    foreach ($item in $sorted) {
        $component = $item.Component
        $status = $item.Status
        $deadline = $item.Deadline
        $days = $item.DaysUntilDeadline
        $severity = $item.Severity
        $count = $item.AffectedResourceCount
        $action = $item.ActionRequired
        $guide = $item.MigrationGuide

        $severityLower = $severity.ToLower()
        $statusLower = $status.ToLower()
        $searchable = "$component $status $severity $action $guide".ToLower()

        $daysText = if ($days -ne $null) {
            if ($days -lt 0) { "Past due ($days days)" } else { "$days days" }
        } else {
            "N/A"
        }

        $html += @"
                    <div class="eol-item" 
                         data-severity="$severityLower" 
                         data-status="$statusLower"
                         data-searchable="$searchable">
                        <div class="eol-item-header" onclick="toggleEolItemDetails(this)">
                            <div class="eol-item-main">
                                <h3>$component</h3>
                                <div class="eol-meta">
                                    <span class="badge severity-$severityLower">$severity</span>
                                    <span class="badge status-$statusLower">$status</span>
                                    <span class="badge">$count resource(s)</span>
                                    <span class="badge">Deadline: $deadline ($daysText)</span>
                                </div>
                            </div>
                            <div class="eol-item-action">
                                <span class="expand-icon">▼</span>
                            </div>
                        </div>
                        <div class="eol-item-details" style="display: none;">
                            <div class="eol-action">
                                <h4>Action Required</h4>
                                <p>$(Encode-Html $action)</p>
                                $(if ($guide) { "<p><a href='$guide' target='_blank' rel='noopener'>Migration guidance</a></p>" } else { "" })
                            </div>
                            <div class="eol-resources">
                                <h4>Affected Resources ($count)</h4>
                                <table class="resource-summary-table eol-resource-table">
                                    <thead>
                                        <tr>
                                            <th>Subscription</th>
                                            <th>Resource Group</th>
                                            <th>Resource</th>
                                            <th>Location</th>
                                        </tr>
                                    </thead>
                                    <tbody>
"@

        foreach ($res in $item.AffectedResources) {
            $subId = $res.SubscriptionId
            $rg = $res.ResourceGroup
            $name = $res.Name
            $loc = $res.Location

            $html += @"
                                        <tr>
                                            <td>$(Encode-Html $subId)</td>
                                            <td>$(Encode-Html $rg)</td>
                                            <td>$(Encode-Html $name)</td>
                                            <td>$(Encode-Html $loc)</td>
                                        </tr>
"@
        }

        $html += @"
                                    </tbody>
                                </table>
                            </div>
                        </div>
                    </div>
"@
    }

    $html += @"
                </div>
            </div>
        </div>
"@

    return $html
}


