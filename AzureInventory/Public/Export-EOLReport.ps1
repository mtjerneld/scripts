<#
.SYNOPSIS
    Generates a dedicated End of Life (EOL) / Deprecated Components HTML report.

.DESCRIPTION
    Renders a standalone EOL report page based on EOL findings (New-EOLFinding objects)
    collected during the security audit. Groups findings by deprecated component and
    provides summary cards, grouped drilldowns, and a 24‑month timeline of upcoming
    deprecations.

.PARAMETER EOLFindings
    Array or List of EOL finding objects as produced by New-EOLFinding.

.PARAMETER OutputPath
    Path for the HTML report output file.

.PARAMETER TenantId
    Azure Tenant ID for display in the report header.

.OUTPUTS
    Hashtable with basic metadata (counts, totals) for dashboard aggregation.
#>
function Export-EOLReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSObject[]]$EOLFindings,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [string]$TenantId = "Unknown"
    )

    # With [PSObject[]] parameter type, PowerShell automatically converts List to Array
    # Check for empty array
    if ($null -eq $EOLFindings -or $EOLFindings.Count -eq 0) {
        Write-Host "Export-EOLReport: No EOL findings to process" -ForegroundColor Yellow
        return
    }
    
    Write-Host "Export-EOLReport: Received $($EOLFindings.Count) findings - Type = $($EOLFindings.GetType().FullName)" -ForegroundColor Gray
    
    # Validate findings - filter out null items and ensure Component property exists
    $validFindings = @()
    $originalCount = $EOLFindings.Count
    
    foreach ($finding in $EOLFindings) {
        if ($null -ne $finding) {
            # Check for Component property (case-insensitive)
            $hasComponent = $false
            $propertyNames = @()
            if ($finding.PSObject.Properties.Name) {
                $propertyNames = $finding.PSObject.Properties.Name
                foreach ($propName in $propertyNames) {
                    if ($propName -eq 'Component') {
                        $hasComponent = $true
                        break
                    }
                }
            }
            
            if ($hasComponent) {
                $validFindings += $finding
                Write-Verbose "Export-EOLReport: Valid finding - Component: $($finding.Component), Severity: $($finding.Severity)"
            } else {
                Write-Host "Export-EOLReport: Skipping invalid finding object (missing Component property)" -ForegroundColor Yellow
                Write-Host "Export-EOLReport: Finding type: $($finding.GetType().FullName)" -ForegroundColor Yellow
                Write-Host "Export-EOLReport: Available properties: $($propertyNames -join ', ')" -ForegroundColor Yellow
            }
        }
    }
    
    if ($validFindings.Count -lt $originalCount) {
        Write-Host "Export-EOLReport: Filtered out $($originalCount - $validFindings.Count) invalid findings (had $originalCount, kept $($validFindings.Count))" -ForegroundColor Yellow
    }
    
    if ($validFindings.Count -eq 0) {
        Write-Host "Export-EOLReport: No valid EOL findings to process after validation" -ForegroundColor Yellow
        return
    }
    
    $eolFindings = $validFindings

    Write-Verbose "Export-EOLReport: Final EOL findings count = $($eolFindings.Count)"
    
    # Debug: Log first finding if available
    if ($eolFindings.Count -gt 0) {
        $firstFinding = $eolFindings[0]
        Write-Verbose "Export-EOLReport: First finding - Component: $($firstFinding.Component), Severity: $($firstFinding.Severity), ResourceName: $($firstFinding.ResourceName)"
        Write-Host "Export-EOLReport: Processing $($eolFindings.Count) EOL findings (first: $($firstFinding.Component) - $($firstFinding.Severity))" -ForegroundColor Gray
    } else {
        Write-Host "Export-EOLReport: No EOL findings to process" -ForegroundColor Yellow
    }

    $timestamp   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $totalFindings = $eolFindings.Count

    # Group by component
    $components = @()
    if ($totalFindings -gt 0) {
        $components = $eolFindings |
            Group-Object -Property Component |
            ForEach-Object {
                $group = $_
                $items = $group.Group
                $critical = @($items | Where-Object { $_.Severity -eq 'Critical' }).Count
                $high     = @($items | Where-Object { $_.Severity -eq 'High' }).Count
                $medium   = @($items | Where-Object { $_.Severity -eq 'Medium' }).Count
                $low      = @($items | Where-Object { $_.Severity -eq 'Low' }).Count
                $deadline = ($items | Where-Object { $_.Deadline } | Sort-Object {
                    try { [DateTime]::Parse($_.Deadline) } catch { [DateTime]::MaxValue }
                } | Select-Object -First 1).Deadline
                $daysUntil = $null
                if ($deadline) {
                    try {
                        $d = [DateTime]::Parse($deadline)
                        $daysUntil = ($d - (Get-Date)).Days
                    } catch {
                        $daysUntil = $null
                    }
                }
                $topSeverity = if ($critical -gt 0) { 'Critical' } elseif ($high -gt 0) { 'High' } elseif ($medium -gt 0) { 'Medium' } elseif ($low -gt 0) { 'Low' } else { 'Low' }

                [PSCustomObject]@{
                    Component      = $group.Name
                    Findings       = $items
                    Count          = $items.Count
                    CriticalCount  = $critical
                    HighCount      = $high
                    MediumCount    = $medium
                    LowCount       = $low
                    TopSeverity    = $topSeverity
                    Deadline       = $deadline
                    DaysUntil      = $daysUntil
                }
            } | Sort-Object -Property @{Expression = { 
                    switch ($_.TopSeverity) {
                        'Critical' { 0 }
                        'High'     { 1 }
                        'Medium'   { 2 }
                        'Low'      { 3 }
                        default    { 4 }
                    }
                }}, @{Expression = { if ($_.DaysUntil -ne $null) { $_.DaysUntil } else { 99999 } }}
    }

    $componentCount = $components.Count

    # Aggregate severity counts across all findings
    $criticalTotal = @($eolFindings | Where-Object { $_.Severity -eq 'Critical' }).Count
    $highTotal     = @($eolFindings | Where-Object { $_.Severity -eq 'High' }).Count
    $mediumTotal   = @($eolFindings | Where-Object { $_.Severity -eq 'Medium' }).Count
    $lowTotal      = @($eolFindings | Where-Object { $_.Severity -eq 'Low' }).Count

    # Build 24‑month timeline of deadlines by severity with component names
    $today = Get-Date
    $months = @()
    $timeline = [System.Collections.Generic.List[PSObject]]::new()
    for ($i = 0; $i -lt 24; $i++) {
        $monthDate = $today.AddMonths($i)
        $monthKey = $monthDate.ToString('yyyy-MM')
        $months += $monthKey
        $timeline.Add([PSCustomObject]@{
            MonthKey        = $monthKey
            Label           = $monthDate.ToString('yyyy-MM')
            CriticalCount   = 0
            HighCount       = 0
            MediumCount     = 0
            LowCount        = 0
            CriticalComponents = [System.Collections.Generic.List[string]]::new()
            HighComponents     = [System.Collections.Generic.List[string]]::new()
            MediumComponents   = [System.Collections.Generic.List[string]]::new()
            LowComponents      = [System.Collections.Generic.List[string]]::new()
        })
    }

    $timelineByKey = @{}
    foreach ($m in $timeline) {
        $timelineByKey[$m.MonthKey] = $m
    }

    # Build component counts per month and severity
    foreach ($f in $eolFindings) {
        if ($f.Deadline) {
            try {
                $d = [DateTime]::Parse($f.Deadline)
                $mk = $d.ToString('yyyy-MM')
                if ($timelineByKey.ContainsKey($mk)) {
                    $entry = $timelineByKey[$mk]
                    $componentName = $f.Component
                    switch ($f.Severity) {
                        'Critical' { 
                            $entry.CriticalCount++
                            # Track component name and count
                            $existingIndex = -1
                            for ($i = 0; $i -lt $entry.CriticalComponents.Count; $i++) {
                                if ($entry.CriticalComponents[$i] -eq $componentName) {
                                    $existingIndex = $i
                                    break
                                }
                            }
                            if ($existingIndex -ge 0) {
                                # Component already exists, increment count (stored as "ComponentName|Count")
                                $parts = $entry.CriticalComponents[$existingIndex] -split '\|'
                                $count = [int]$parts[1] + 1
                                $entry.CriticalComponents[$existingIndex] = "$componentName|$count"
                            } else {
                                $entry.CriticalComponents.Add("$componentName|1")
                            }
                        }
                        'High' { 
                            $entry.HighCount++
                            $existingIndex = -1
                            for ($i = 0; $i -lt $entry.HighComponents.Count; $i++) {
                                if ($entry.HighComponents[$i] -eq $componentName) {
                                    $existingIndex = $i
                                    break
                                }
                            }
                            if ($existingIndex -ge 0) {
                                $parts = $entry.HighComponents[$existingIndex] -split '\|'
                                $count = [int]$parts[1] + 1
                                $entry.HighComponents[$existingIndex] = "$componentName|$count"
                            } else {
                                $entry.HighComponents.Add("$componentName|1")
                            }
                        }
                        'Medium' { 
                            $entry.MediumCount++
                            $existingIndex = -1
                            for ($i = 0; $i -lt $entry.MediumComponents.Count; $i++) {
                                if ($entry.MediumComponents[$i] -eq $componentName) {
                                    $existingIndex = $i
                                    break
                                }
                            }
                            if ($existingIndex -ge 0) {
                                $parts = $entry.MediumComponents[$existingIndex] -split '\|'
                                $count = [int]$parts[1] + 1
                                $entry.MediumComponents[$existingIndex] = "$componentName|$count"
                            } else {
                                $entry.MediumComponents.Add("$componentName|1")
                            }
                        }
                        'Low' { 
                            $entry.LowCount++
                            $existingIndex = -1
                            for ($i = 0; $i -lt $entry.LowComponents.Count; $i++) {
                                if ($entry.LowComponents[$i] -eq $componentName) {
                                    $existingIndex = $i
                                    break
                                }
                            }
                            if ($existingIndex -ge 0) {
                                $parts = $entry.LowComponents[$existingIndex] -split '\|'
                                $count = [int]$parts[1] + 1
                                $entry.LowComponents[$existingIndex] = "$componentName|$count"
                            } else {
                                $entry.LowComponents.Add("$componentName|1")
                            }
                        }
                    }
                }
            } catch {
                # ignore invalid date
            }
        }
    }

    $timelineArray = @($timeline)

    # Build JSON for chart data and component lists (Severity view)
    $labelsJson = ($timelineArray | ForEach-Object { '"{0}"' -f $_.Label }) -join ','
    $criticalSeries = ($timelineArray | ForEach-Object { $_.CriticalCount }) -join ','
    $highSeries     = ($timelineArray | ForEach-Object { $_.HighCount }) -join ','
    $mediumSeries   = ($timelineArray | ForEach-Object { $_.MediumCount }) -join ','
    $lowSeries      = ($timelineArray | ForEach-Object { $_.LowCount }) -join ','
    
    # Build component lists JSON for tooltips
    $criticalComponentsJson = ($timelineArray | ForEach-Object { 
        $comps = @($_.CriticalComponents)
        ($comps | ConvertTo-Json -Compress)
    }) -join ','
    
    $highComponentsJson = ($timelineArray | ForEach-Object { 
        $comps = @($_.HighComponents)
        ($comps | ConvertTo-Json -Compress)
    }) -join ','
    
    $mediumComponentsJson = ($timelineArray | ForEach-Object { 
        $comps = @($_.MediumComponents)
        ($comps | ConvertTo-Json -Compress)
    }) -join ','
    
    $lowComponentsJson = ($timelineArray | ForEach-Object { 
        $comps = @($_.LowComponents)
        ($comps | ConvertTo-Json -Compress)
    }) -join ','
    
    # Build data for Subscription-stacked view
    $subscriptions = @($eolFindings | Select-Object -ExpandProperty SubscriptionName -Unique | Sort-Object)
    $subscriptionDataByMonth = @{}
    foreach ($sub in $subscriptions) {
        $subscriptionDataByMonth[$sub] = @{}
        foreach ($monthEntry in $timelineArray) {
            $subscriptionDataByMonth[$sub][$monthEntry.MonthKey] = 0
        }
    }
    
    foreach ($f in $eolFindings) {
        if ($f.Deadline) {
            try {
                $d = [DateTime]::Parse($f.Deadline)
                $mk = $d.ToString('yyyy-MM')
                $subName = if ($f.SubscriptionName) { $f.SubscriptionName } else { "Unknown" }
                if ($subscriptionDataByMonth.ContainsKey($subName) -and $subscriptionDataByMonth[$subName].ContainsKey($mk)) {
                    $subscriptionDataByMonth[$subName][$mk]++
                }
            } catch {
                # ignore invalid date
            }
        }
    }
    
    # Build JSON for subscription-stacked view
    $subscriptionDatasets = @()
    foreach ($sub in $subscriptions) {
        $subData = @($timelineArray | ForEach-Object { $subscriptionDataByMonth[$sub][$_.MonthKey] })
        $subscriptionDatasets += [PSCustomObject]@{
            label = $sub
            data = $subData
        }
    }
    if ($subscriptionDatasets.Count -eq 0) {
        $subscriptionSeriesJson = "[]"
    } else {
        # Ensure it's always an array by wrapping in @() and converting to JSON
        $subscriptionSeriesJson = (@($subscriptionDatasets) | ConvertTo-Json -Compress -Depth 10)
        # Verify it starts with [ to ensure it's an array
        if (-not $subscriptionSeriesJson.StartsWith('[')) {
            $subscriptionSeriesJson = "[$subscriptionSeriesJson]"
        }
    }
    
    # Build data for Category (Component)-stacked view
    $categoryDataByMonth = @{}
    foreach ($comp in $components) {
        $compName = $comp.Component
        $categoryDataByMonth[$compName] = @{}
        foreach ($monthEntry in $timelineArray) {
            $categoryDataByMonth[$compName][$monthEntry.MonthKey] = 0
        }
    }
    
    foreach ($f in $eolFindings) {
        if ($f.Deadline) {
            try {
                $d = [DateTime]::Parse($f.Deadline)
                $mk = $d.ToString('yyyy-MM')
                $compName = $f.Component
                if ($categoryDataByMonth.ContainsKey($compName) -and $categoryDataByMonth[$compName].ContainsKey($mk)) {
                    $categoryDataByMonth[$compName][$mk]++
                }
            } catch {
                # ignore invalid date
            }
        }
    }
    
    # Build JSON for category-stacked view
    $categoryDatasets = @()
    foreach ($comp in $components) {
        $compName = $comp.Component
        $compData = @($timelineArray | ForEach-Object { $categoryDataByMonth[$compName][$_.MonthKey] })
        $categoryDatasets += [PSCustomObject]@{
            label = $compName
            data = $compData
        }
    }
    if ($categoryDatasets.Count -eq 0) {
        $categorySeriesJson = "[]"
    } else {
        # Ensure it's always an array by wrapping in @() and converting to JSON
        $categorySeriesJson = (@($categoryDatasets) | ConvertTo-Json -Compress -Depth 10)
        # Verify it starts with [ to ensure it's an array
        if (-not $categorySeriesJson.StartsWith('[')) {
            $categorySeriesJson = "[$categorySeriesJson]"
        }
    }
    
    # Escape JSON strings for safe JavaScript injection (escape single quotes and backslashes)
    $subscriptionSeriesJsonEscaped = $subscriptionSeriesJson -replace "\\", "\\\\" -replace "'", "\'" -replace "`r`n", " " -replace "`n", " "
    $categorySeriesJsonEscaped = $categorySeriesJson -replace "\\", "\\\\" -replace "'", "\'" -replace "`r`n", " " -replace "`n", " "

    # Prepare component HTML
    $componentCardsHtml = ""
    foreach ($comp in $components) {
        $compName = [System.Web.HttpUtility]::HtmlEncode($comp.Component)
        $compDeadline = $comp.Deadline
        $daysUntil = $comp.DaysUntil
        $topSeverity = $comp.TopSeverity
        $topSeverityLower = $topSeverity.ToLower()
        $deadlineText = if ($compDeadline) { $compDeadline } else { "N/A" }
        $daysText = if ($daysUntil -ne $null) {
            if ($daysUntil -lt 0) { "Past due ({0} d)" -f [math]::Abs($daysUntil) } else { "{0} d" -f $daysUntil }
        } else {
            "N/A"
        }

        # Build per‑component resource table
        $resourceRows = ""
        foreach ($f in ($comp.Findings | Sort-Object SubscriptionName, ResourceGroup, ResourceName)) {
            $subName = if ($f.SubscriptionName) { [System.Web.HttpUtility]::HtmlEncode($f.SubscriptionName) } else { $f.SubscriptionId }
            $rg      = if ($f.ResourceGroup) { [System.Web.HttpUtility]::HtmlEncode($f.ResourceGroup) } else { "N/A" }
            $resName = [System.Web.HttpUtility]::HtmlEncode($f.ResourceName)
            $resType = [System.Web.HttpUtility]::HtmlEncode($f.ResourceType)
            $sev     = $f.Severity
            $sevLower = $sev.ToLower()
            $dl      = $f.Deadline
            $di      = $f.DaysUntilDeadline
            $dlText  = if ($dl) { $dl } else { "N/A" }
            $diText  = if ($di -ne $null) {
                if ($di -lt 0) { "Past due ({0} d)" -f [math]::Abs($di) } else { "{0} d" -f $di }
            } else { "N/A" }

            $action  = $f.ActionRequired
            $actionHtml = if ($action) { [System.Web.HttpUtility]::HtmlEncode($action) } else { "" }
            
            # Use first reference URL if available, otherwise fall back to migrationGuide
            $guideUrl = $null
            if ($f.References -and $f.References.Count -gt 0) {
                # Get first URL from references array
                $firstRef = $f.References[0]
                if ($firstRef -and $firstRef -match '^https?://') {
                    $guideUrl = $firstRef
                }
            }
            
            # Fallback to migrationGuide if it looks like a URL
            if (-not $guideUrl -and $f.MigrationGuide) {
                if ($f.MigrationGuide -match '^https?://') {
                    $guideUrl = $f.MigrationGuide
                }
            }
            
            $guideHtml = if ($guideUrl) { 
                $escapedUrl = [System.Web.HttpUtility]::HtmlAttributeEncode($guideUrl)
                "<a href='$escapedUrl' target='_blank' rel='noopener' class='eol-guidance-link'>View guidance</a>" 
            } else { 
                "" 
            }

            $resourceRows += @"
                                <tr class="eol-resource-row" data-subscription="$subName" data-severity="$sevLower">
                                    <td>$subName</td>
                                    <td>$rg</td>
                                    <td>$resName</td>
                                    <td>$resType</td>
                                    <td><span class="badge severity-$sevLower">$sev</span></td>
                                    <td>$dlText</td>
                                    <td>$diText</td>
                                    <td>
                                        <div class="resource-action-text">$actionHtml</div>
                                        $guideHtml
                                    </td>
                                </tr>
"@
        }

        $componentCardsHtml += @"
                    <div class="eol-card-item" data-severity="$topSeverityLower">
                        <div class="eol-card-header" onclick="toggleEolComponent(this)">
                            <div class="eol-card-main">
                                <div class="eol-card-header-info">
                                    <span class="eol-component-name">$compName</span>
                                    <span class="badge">$($comp.Count) resource(s)</span>
                                    <span class="badge">Deadline: $deadlineText ($daysText)</span>
                                    <span class="badge severity-$topSeverityLower eol-severity-badge">$topSeverity</span>
                                </div>
                            </div>
                            <div class="eol-card-toggle">
                                <span class="expand-arrow">&#9654;</span>
                            </div>
                        </div>
                        <div class="eol-card-body">
                            <div class="eol-card-table">
                                <table class="resource-summary-table eol-resource-table">
                                    <thead>
                                        <tr>
                                            <th>Subscription</th>
                                            <th>Resource Group</th>
                                            <th>Resource</th>
                                            <th>Type</th>
                                            <th>Severity</th>
                                            <th>Deadline</th>
                                            <th>Days</th>
                                            <th>Action</th>
                                        </tr>
                                    </thead>
                                    <tbody>
$resourceRows
                                    </tbody>
                                </table>
                            </div>
                        </div>
                    </div>
"@
    }

    # Prepare summary cards values
    $criticalLabel = "$criticalTotal"
    $highLabel     = "$highTotal"
    $mediumLabel   = "$mediumTotal"
    $lowLabel      = "$lowTotal"

    # Build HTML
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure EOL / Deprecated Components</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
$(Get-ReportStylesheet)

        .summary-cards {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }

        .summary-card {
            background: var(--bg-surface);
            border-radius: var(--radius-md);
            padding: 20px;
            border: 1px solid var(--border-color);
            display: flex;
            flex-direction: column;
            gap: 6px;
        }

        .summary-card .label {
            font-size: 0.85rem;
            text-transform: uppercase;
            color: var(--text-secondary);
            letter-spacing: 0.5px;
        }

        .summary-card .value {
            font-size: 1.8rem;
            font-weight: 700;
        }

        .summary-card .value.critical { color: var(--accent-red); }
        .summary-card .value.high     { color: var(--accent-orange); }
        .summary-card .value.medium   { color: var(--accent-yellow); }
        .summary-card .value.low      { color: var(--accent-green); }

        .timeline-section {
            background: var(--bg-surface);
            border-radius: var(--radius-md);
            padding: 24px;
            margin-bottom: 30px;
            border: 1px solid var(--border-color);
        }

        .timeline-section h2 {
            margin-top: 0;
            margin-bottom: 12px;
        }

        .timeline-legend {
            display: flex;
            flex-wrap: wrap;
            gap: 12px;
            margin-bottom: 12px;
        }

        .timeline-legend-item {
            display: flex;
            align-items: center;
            gap: 6px;
            font-size: 0.85rem;
            color: var(--text-secondary);
        }

        .timeline-legend-color {
            width: 12px;
            height: 12px;
            border-radius: 2px;
        }

        .timeline-legend-critical { background: rgba(231, 76, 60, 0.8); }
        .timeline-legend-high     { background: rgba(241, 196, 15, 0.9); }
        .timeline-legend-medium   { background: rgba(52, 152, 219, 0.8); }
        .timeline-legend-low      { background: rgba(39, 174, 96, 0.8); }

        .chart-container {
            position: relative;
            height: 320px;
            width: 100%;
        }

        .eol-component-list {
            background: var(--bg-surface);
            border-radius: var(--radius-md);
            padding: 16px 20px;
            border: 1px solid var(--border-color);
            max-height: none;
            overflow-y: visible;
        }

        .eol-component-list h2 {
            margin-top: 0;
            margin-bottom: 12px;
        }

        .eol-filter-bar {
            display: flex;
            flex-wrap: wrap;
            gap: 10px;
            margin-bottom: 12px;
        }

        .eol-filter-bar input,
        .eol-filter-bar select {
            background: var(--bg-secondary);
            border: 1px solid var(--border-color);
            color: var(--text-primary);
            padding: 6px 10px;
            border-radius: 6px;
            font-size: 0.85rem;
        }

        .eol-filter-bar label {
            font-size: 0.8rem;
            color: var(--text-secondary);
        }

        .eol-card-item {
            border: 1px solid var(--border-color);
            border-radius: var(--radius-sm);
            margin-bottom: 10px;
            overflow: hidden;
        }

        .eol-card-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 12px 16px;
            cursor: pointer;
            background: var(--bg-secondary);
            gap: 12px;
        }

        .eol-card-header:hover {
            background: var(--bg-hover);
        }

        .eol-component-name {
            font-weight: 600;
            margin-right: 12px;
            min-width: 200px;
        }
        
        .eol-card-header-info .badge {
            margin-right: 0;
            white-space: nowrap;
        }

        .eol-card-main {
            display: flex;
            flex-wrap: wrap;
            align-items: center;
            gap: 8px;
            flex: 1;
        }
        
        .eol-card-header-info {
            display: flex;
            flex-wrap: wrap;
            align-items: center;
            gap: 20px;
            flex: 1;
            row-gap: 10px;
        }
        
        .eol-severity-badge {
            margin-left: auto;
        }
        
        .eol-card-header-info > * {
            margin: 0;
        }

        .eol-card-toggle .expand-arrow {
            font-size: 0.8rem;
            display: inline-block;
            transition: transform 0.2s;
            color: var(--text-muted);
        }

        .eol-card-item.expanded .eol-card-toggle .expand-arrow {
            transform: rotate(90deg);
        }

        .eol-card-body {
            display: none;
            padding: 10px 12px 12px;
            background: var(--bg-primary);
        }

        .eol-card-item.expanded .eol-card-body {
            display: block;
        }


        .eol-resource-table .resource-action-text {
            max-width: 260px;
            white-space: normal;
            font-size: 0.8rem;
            color: var(--text-secondary);
        }

        .eol-resource-table {
            width: 100%;
        }

        .eol-resource-table thead {
            background: var(--bg-secondary);
        }

        .eol-resource-table th {
            padding: 12px 16px;
            text-align: left;
            font-weight: 600;
            color: var(--text-primary);
            border-bottom: 2px solid var(--border-color);
            font-size: 0.85rem;
            white-space: nowrap;
        }

        .eol-resource-table td {
            padding: 12px 16px;
            border-bottom: none;
            color: var(--text-secondary);
            font-size: 0.85rem;
            word-wrap: break-word;
        }

        .eol-resource-table tbody tr {
            background: transparent;
        }

        .eol-resource-table tbody tr:hover {
            background: var(--bg-hover);
        }

        .badge.severity-critical {
            background-color: rgba(231, 76, 60, 0.15);
            color: #ff6b6b;
        }
        .badge.severity-high {
            background-color: rgba(243, 156, 18, 0.15);
            color: #f5b041;
        }
        .badge.severity-medium {
            background-color: rgba(52, 152, 219, 0.15);
            color: #5dade2;
        }
        .badge.severity-low {
            background-color: rgba(46, 204, 113, 0.15);
            color: #58d68d;
        }
        
        .eol-guidance-link {
            color: var(--text-primary) !important;
            text-decoration: none;
        }
        
        .eol-guidance-link:hover {
            color: var(--text-primary) !important;
            text-decoration: underline;
        }
        
        .eol-guidance-link:visited {
            color: var(--text-primary) !important;
        }
        
        .eol-guidance-link:link {
            color: var(--text-primary) !important;
        }
    </style>
</head>
<body>
$(Get-ReportNavigation -ActivePage "EOL")

    <div class="container">
        <div class="page-header">
            <h1>End of Life / Deprecated Components</h1>
            <p class="subtitle">EOL and deprecation risk overview for Azure resources · Tenant: $TenantId · Generated: $timestamp</p>
        </div>

        <div class="summary-cards">
            <div class="summary-card">
                <div class="label">Total EOL Findings</div>
                <div class="value">$totalFindings</div>
            </div>
            <div class="summary-card">
                <div class="label">Unique Components</div>
                <div class="value">$componentCount</div>
            </div>
            <div class="summary-card">
                <div class="label">Critical</div>
                <div class="value critical">$criticalTotal</div>
            </div>
            <div class="summary-card">
                <div class="label">High</div>
                <div class="value high">$highTotal</div>
            </div>
            <div class="summary-card">
                <div class="label">Medium</div>
                <div class="value medium">$mediumTotal</div>
            </div>
            <div class="summary-card">
                <div class="label">Low</div>
                <div class="value low">$lowTotal</div>
            </div>
        </div>

        <div class="timeline-section">
            <h2>24-Month EOL Timeline</h2>
            <div class="chart-controls" style="margin-bottom: 16px;">
                <select id="eolChartView" onchange="updateEolChartView()" style="background: var(--bg-secondary); border: 1px solid var(--border-color); color: var(--text-primary); padding: 6px 10px; border-radius: 6px; font-size: 0.85rem;">
                    <option value="severity">Stacked by Severity</option>
                    <option value="subscription">Stacked by Subscription</option>
                    <option value="category">Stacked by Category</option>
                </select>
            </div>
            <div class="timeline-legend" id="eolLegend">
                <div class="timeline-legend-item"><span class="timeline-legend-color timeline-legend-critical"></span> Critical (&lt; 0d or &lt; 90d)</div>
                <div class="timeline-legend-item"><span class="timeline-legend-color timeline-legend-high"></span> High (90-180d)</div>
                <div class="timeline-legend-item"><span class="timeline-legend-color timeline-legend-medium"></span> Medium (180-365d)</div>
                <div class="timeline-legend-item"><span class="timeline-legend-color timeline-legend-low"></span> Low (365-730d)</div>
            </div>
            <div class="chart-container">
                <canvas id="eolTimelineChart"></canvas>
            </div>
        </div>

        <div class="eol-component-list">
            <h2>Deprecated Components</h2>
            <div class="eol-filter-bar">
                <div>
                    <label for="eolSearch">Search</label><br/>
                    <input type="text" id="eolSearch" placeholder="Search component or resource..." />
                </div>
                <div>
                    <label for="eolSeverityFilter">Severity</label><br/>
                    <select id="eolSeverityFilter">
                        <option value="all">All</option>
                        <option value="critical">Critical</option>
                        <option value="high">High</option>
                        <option value="medium">Medium</option>
                        <option value="low">Low</option>
                    </select>
                </div>
            </div>

            <div id="eolComponents">
$componentCardsHtml
$(if ($componentCount -eq 0) { @"
                <div style=""padding: 16px; text-align: center; color: var(--text-secondary);"">
                    <p>No EOL / deprecated components detected for the scanned subscriptions.</p>
                </div>
"@ })
            </div>
        </div>
    </div>

    <script>
        const eolLabels = [$labelsJson];
        const eolCritical = [$criticalSeries];
        const eolHigh = [$highSeries];
        const eolMedium = [$mediumSeries];
        const eolLow = [$lowSeries];
        
        // Component names per month and severity for tooltips
        const eolCriticalComponents = [$criticalComponentsJson];
        const eolHighComponents = [$highComponentsJson];
        const eolMediumComponents = [$mediumComponentsJson];
        const eolLowComponents = [$lowComponentsJson];
        
        // Data for different chart views - parse JSON strings
        let eolSubscriptionData = [];
        let eolCategoryData = [];
        
        try {
            const subJsonStr = '$subscriptionSeriesJsonEscaped';
            if (subJsonStr && subJsonStr !== 'null' && subJsonStr.trim() !== '' && subJsonStr !== "[]") {
                eolSubscriptionData = JSON.parse(subJsonStr);
                if (!Array.isArray(eolSubscriptionData)) {
                    eolSubscriptionData = [];
                }
            }
        } catch (e) {
            console.error('Error parsing subscription data:', e);
            eolSubscriptionData = [];
        }
        
        try {
            const catJsonStr = '$categorySeriesJsonEscaped';
            if (catJsonStr && catJsonStr !== 'null' && catJsonStr.trim() !== '' && catJsonStr !== "[]") {
                eolCategoryData = JSON.parse(catJsonStr);
                if (!Array.isArray(eolCategoryData)) {
                    eolCategoryData = [];
                }
            }
        } catch (e) {
            console.error('Error parsing category data:', e);
            eolCategoryData = [];
        }
        
        let eolChart = null;
        let currentEolView = 'severity';
        
        // Color palette for subscriptions and categories
        const eolChartColors = [
            'rgba(231, 76, 60, 0.8)',   // Red
            'rgba(241, 196, 15, 0.9)',  // Yellow
            'rgba(52, 152, 219, 0.8)',  // Blue
            'rgba(39, 174, 96, 0.8)',   // Green
            'rgba(155, 89, 182, 0.8)',  // Purple
            'rgba(46, 204, 113, 0.8)',  // Light Green
            'rgba(230, 126, 34, 0.8)',  // Orange
            'rgba(26, 188, 156, 0.8)',  // Turquoise
            'rgba(241, 196, 15, 0.8)',  // Gold
            'rgba(231, 76, 60, 0.6)',   // Light Red
            'rgba(52, 152, 219, 0.6)',  // Light Blue
            'rgba(155, 89, 182, 0.6)',  // Light Purple
            'rgba(230, 126, 34, 0.6)',  // Light Orange
            'rgba(26, 188, 156, 0.6)',  // Light Turquoise
            'rgba(46, 204, 113, 0.6)'   // Light Light Green
        ];

        function updateEolChartView() {
            currentEolView = document.getElementById('eolChartView').value;
            updateEolChart();
        }
        
        function updateEolChart() {
            if (!eolChart) return;
            
            let datasets = [];
            let showLegend = true;
            
            if (currentEolView === 'severity') {
                // Severity view - original stacked by severity
                datasets = [
                    {
                        label: 'Critical',
                        data: eolCritical,
                        backgroundColor: 'rgba(231, 76, 60, 0.8)',
                        borderColor: 'rgba(231, 76, 60, 1)',
                        borderWidth: 1,
                        stack: 'severity'
                    },
                    {
                        label: 'High',
                        data: eolHigh,
                        backgroundColor: 'rgba(241, 196, 15, 0.9)',
                        borderColor: 'rgba(243, 156, 18, 1)',
                        borderWidth: 1,
                        stack: 'severity'
                    },
                    {
                        label: 'Medium',
                        data: eolMedium,
                        backgroundColor: 'rgba(52, 152, 219, 0.8)',
                        borderColor: 'rgba(52, 152, 219, 1)',
                        borderWidth: 1,
                        stack: 'severity'
                    },
                    {
                        label: 'Low',
                        data: eolLow,
                        backgroundColor: 'rgba(39, 174, 96, 0.8)',
                        borderColor: 'rgba(39, 174, 96, 1)',
                        borderWidth: 1,
                        stack: 'severity'
                    }
                ];
                // Show severity legend
                document.getElementById('eolLegend').style.display = 'flex';
                // Show chart legend
                eolChart.options.plugins.legend.display = true;
            } else if (currentEolView === 'subscription') {
                // Subscription view - stacked by subscription
                if (eolSubscriptionData && Array.isArray(eolSubscriptionData) && eolSubscriptionData.length > 0) {
                    datasets = eolSubscriptionData.map((sub, index) => ({
                        label: sub.label,
                        data: sub.data,
                        backgroundColor: eolChartColors[index % eolChartColors.length],
                        borderColor: eolChartColors[index % eolChartColors.length].replace('0.8', '1').replace('0.9', '1').replace('0.6', '1'),
                        borderWidth: 1,
                        stack: 'subscription'
                    }));
                } else {
                    // Fallback to severity if no subscription data
                    datasets = [
                        {
                            label: 'Critical',
                            data: eolCritical,
                            backgroundColor: 'rgba(231, 76, 60, 0.8)',
                            borderColor: 'rgba(231, 76, 60, 1)',
                            borderWidth: 1,
                            stack: 'severity'
                        }
                    ];
                }
                // Hide severity legend, show chart legend
                document.getElementById('eolLegend').style.display = 'none';
                eolChart.options.plugins.legend.display = true;
            } else if (currentEolView === 'category') {
                // Category view - stacked by component
                if (eolCategoryData && Array.isArray(eolCategoryData) && eolCategoryData.length > 0) {
                    datasets = eolCategoryData.map((cat, index) => ({
                        label: cat.label,
                        data: cat.data,
                        backgroundColor: eolChartColors[index % eolChartColors.length],
                        borderColor: eolChartColors[index % eolChartColors.length].replace('0.8', '1').replace('0.9', '1').replace('0.6', '1'),
                        borderWidth: 1,
                        stack: 'category'
                    }));
                } else {
                    // Fallback to severity if no category data
                    datasets = [
                        {
                            label: 'Critical',
                            data: eolCritical,
                            backgroundColor: 'rgba(231, 76, 60, 0.8)',
                            borderColor: 'rgba(231, 76, 60, 1)',
                            borderWidth: 1,
                            stack: 'severity'
                        }
                    ];
                }
                // Hide severity legend, show chart legend
                document.getElementById('eolLegend').style.display = 'none';
                eolChart.options.plugins.legend.display = true;
            }
            
            eolChart.data.datasets = datasets;
            eolChart.update('none');
        }

        document.addEventListener('DOMContentLoaded', function () {
            const ctx = document.getElementById('eolTimelineChart').getContext('2d');
            eolChart = new Chart(ctx, {
                type: 'bar',
                data: {
                    labels: eolLabels,
                    datasets: [
                        {
                            label: 'Critical',
                            data: eolCritical,
                            backgroundColor: 'rgba(231, 76, 60, 0.8)',
                            borderColor: 'rgba(231, 76, 60, 1)',
                            borderWidth: 1,
                            stack: 'severity'
                        },
                        {
                            label: 'High',
                            data: eolHigh,
                            backgroundColor: 'rgba(241, 196, 15, 0.9)',
                            borderColor: 'rgba(243, 156, 18, 1)',
                            borderWidth: 1,
                            stack: 'severity'
                        },
                        {
                            label: 'Medium',
                            data: eolMedium,
                            backgroundColor: 'rgba(52, 152, 219, 0.8)',
                            borderColor: 'rgba(52, 152, 219, 1)',
                            borderWidth: 1,
                            stack: 'severity'
                        },
                        {
                            label: 'Low',
                            data: eolLow,
                            backgroundColor: 'rgba(39, 174, 96, 0.8)',
                            borderColor: 'rgba(39, 174, 96, 1)',
                            borderWidth: 1,
                            stack: 'severity'
                        }
                    ]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    plugins: {
                        legend: {
                            display: true,
                            position: 'bottom',
                            labels: {
                                color: '#e8e8e8',
                                usePointStyle: true,
                                padding: 12
                            }
                        },
                        tooltip: {
                            mode: 'index',
                            intersect: false,
                            backgroundColor: 'rgba(37, 37, 66, 0.95)',
                            titleColor: '#e8e8e8',
                            bodyColor: '#b8b8b8',
                            borderColor: '#3d3d5c',
                            borderWidth: 1,
                            callbacks: {
                                title: function(context) {
                                    return context[0].label || '';
                                },
                                label: function(context) {
                                    const datasetIndex = context.datasetIndex;
                                    const dataIndex = context.dataIndex;
                                    const value = context.parsed.y;
                                    
                                    if (value === 0) {
                                        return '';
                                    }
                                    
                                    // For severity view, show component names
                                    if (currentEolView === 'severity') {
                                        let components = [];
                                        
                                        // Get components for this severity and month
                                        if (datasetIndex === 0) {
                                            components = eolCriticalComponents[dataIndex] || [];
                                        } else if (datasetIndex === 1) {
                                            components = eolHighComponents[dataIndex] || [];
                                        } else if (datasetIndex === 2) {
                                            components = eolMediumComponents[dataIndex] || [];
                                        } else if (datasetIndex === 3) {
                                            components = eolLowComponents[dataIndex] || [];
                                        }
                                        
                                        // Build tooltip text - show component name with count
                                        let tooltipLines = [];
                                        
                                        if (components.length > 0) {
                                            components.forEach(function(compEntry) {
                                                let compName = compEntry;
                                                let compCount = 1;
                                                
                                                if (compEntry.indexOf('|') > -1) {
                                                    const parts = compEntry.split('|');
                                                    compName = parts[0];
                                                    compCount = parseInt(parts[1]) || 1;
                                                }
                                                
                                                const countText = compCount === 1 ? '1 resource' : compCount + ' resources';
                                                tooltipLines.push(compName + ' - ' + countText);
                                            });
                                        } else if (value > 0) {
                                            tooltipLines.push(value + ' resource(s)');
                                        }
                                        
                                        return tooltipLines.length > 0 ? tooltipLines.join('\n') : '';
                                    } else {
                                        // For subscription/category views, show simple count
                                        const label = context.dataset.label;
                                        const countText = value === 1 ? '1 resource' : value + ' resources';
                                        return label + ': ' + countText;
                                    }
                                }
                            }
                        }
                    },
                    scales: {
                        x: {
                            stacked: true,
                            ticks: {
                                color: '#888',
                                maxRotation: 45,
                                minRotation: 45
                            },
                            grid: {
                                color: 'rgba(61, 61, 92, 0.4)'
                            }
                        },
                        y: {
                            stacked: true,
                            beginAtZero: true,
                            ticks: {
                                color: '#888',
                                precision: 0
                            },
                            grid: {
                                color: 'rgba(61, 61, 92, 0.4)'
                            }
                        }
                    }
                }
            });

            initEolFilters();
        });

        function initEolFilters() {
            const searchInput = document.getElementById('eolSearch');
            const severitySelect = document.getElementById('eolSeverityFilter');

            function applyFilters() {
                const search = (searchInput.value || '').toLowerCase();
                const sevFilter = (severitySelect.value || 'all');

                const cards = document.querySelectorAll('.eol-card-item');
                cards.forEach(card => {
                    let visible = true;

                    if (sevFilter !== 'all' && !card.dataset) {
                        visible = true;
                    } else if (sevFilter !== 'all') {
                        const sev = card.getAttribute('data-severity');
                        if (sev !== sevFilter) {
                            visible = false;
                        }
                    }

                    if (visible && search) {
                        const text = card.textContent.toLowerCase();
                        if (!text.includes(search)) {
                            visible = false;
                        }
                    }

                    card.style.display = visible ? '' : 'none';
                });
            }

            if (searchInput) {
                searchInput.addEventListener('input', applyFilters);
            }
            if (severitySelect) {
                severitySelect.addEventListener('change', applyFilters);
            }
        }

        function toggleEolComponent(headerEl) {
            const card = headerEl.closest('.eol-card-item');
            if (!card) return;
            card.classList.toggle('expanded');
        }
    </script>

</body>
</html>
"@

    # Persist HTML to disk
    [System.IO.File]::WriteAllText($OutputPath, $html, [System.Text.Encoding]::UTF8)

    # Return lightweight summary for dashboard usage
    return @{
        OutputPath      = $OutputPath
        TotalFindings   = $totalFindings
        ComponentCount  = $componentCount
        CriticalCount   = $criticalTotal
        HighCount       = $highTotal
        MediumCount     = $mediumTotal
        LowCount        = $lowTotal
        SoonestDeadline = ($components | Where-Object { $_.Deadline } | Sort-Object {
            try { [DateTime]::Parse($_.Deadline) } catch { [DateTime]::MaxValue }
        } | Select-Object -First 1).Deadline
    }
}

