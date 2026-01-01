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
        [AllowEmptyCollection()]
        [PSObject[]]$EOLFindings,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [string]$TenantId = "Unknown"
    )

    # With [PSObject[]] parameter type, PowerShell automatically converts List to Array
    # Handle null or empty array - still generate report with empty state
    if ($null -eq $EOLFindings -or $EOLFindings.Count -eq 0) {
        Write-Host "Export-EOLReport: No EOL findings provided - generating empty report" -ForegroundColor Yellow
        $eolFindings = @()
    } else {
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
        
        $eolFindings = $validFindings
    }

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
    
    # Calculate metadata for display
    $subscriptionCount = ($eolFindings | Select-Object -ExpandProperty SubscriptionName -Unique).Count
    $resourceCount = ($eolFindings | Select-Object -ExpandProperty ResourceName -Unique).Count

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
                }}, @{Expression = { if ($null -ne $_.DaysUntil) { $_.DaysUntil } else { 99999 } }}
    }

    $componentCount = $components.Count

    # Aggregate severity counts across all findings
    $criticalTotal = @($eolFindings | Where-Object { $_.Severity -eq 'Critical' }).Count
    $highTotal     = @($eolFindings | Where-Object { $_.Severity -eq 'High' }).Count
    $mediumTotal   = @($eolFindings | Where-Object { $_.Severity -eq 'Medium' }).Count
    $lowTotal      = @($eolFindings | Where-Object { $_.Severity -eq 'Low' }).Count

    # Build timeline of deadlines by severity with component names
    # Include past months if there are deprecated components with passed dates
    $today = Get-Date
    $todayMonth = Get-Date -Year $today.Year -Month $today.Month -Day 1
    
    # Find earliest deadline date (including past dates)
    $earliestDate = $null
    $latestDate = $null
    foreach ($f in $eolFindings) {
        if ($f.Deadline -and $f.Deadline -ne "TBD") {
            try {
                $d = [DateTime]::Parse($f.Deadline)
                $dMonth = Get-Date -Year $d.Year -Month $d.Month -Day 1
                if ($null -eq $earliestDate -or $dMonth -lt $earliestDate) {
                    $earliestDate = $dMonth
                }
                if ($null -eq $latestDate -or $dMonth -gt $latestDate) {
                    $latestDate = $dMonth
                }
            } catch {
                # ignore invalid date
            }
        }
    }
    
    # Determine timeline range
    # If we have past dates, include up to 6 months before earliest, or 12 months before today (whichever is less)
    # Otherwise, start from today
    $startMonth = $todayMonth
    if ($earliestDate -and $earliestDate -lt $todayMonth) {
        # Include some past months
        $monthsBack = [math]::Min(12, [math]::Max(6, [int](($todayMonth - $earliestDate).TotalDays / 30)))
        $startMonth = $todayMonth.AddMonths(-$monthsBack)
    }
    
    # End month: 24 months from today, or 6 months after latest deadline (whichever is later)
    $endMonth = $todayMonth.AddMonths(24)
    if ($latestDate -and $latestDate -gt $endMonth) {
        $monthsForward = [int](($latestDate - $todayMonth).TotalDays / 30) + 6
        $endMonth = $todayMonth.AddMonths($monthsForward)
    }
    
    # Ensure we have at least 24 months of timeline (fallback if no dates found)
    if ($null -eq $earliestDate -and $null -eq $latestDate) {
        $startMonth = $todayMonth
        $endMonth = $todayMonth.AddMonths(24)
    }
    
    # Build timeline from startMonth to endMonth
    $months = @()
    $timeline = [System.Collections.Generic.List[PSObject]]::new()
    $currentMonth = $startMonth
    $currentMonthIndex = 0
    $todayMonthIndex = -1
    
    # Safety check: ensure endMonth is after startMonth
    if ($endMonth -le $startMonth) {
        $endMonth = $startMonth.AddMonths(24)
    }
    
    $maxIterations = 100  # Safety limit to prevent infinite loops
    $iterationCount = 0
    
    while ($currentMonth -le $endMonth -and $iterationCount -lt $maxIterations) {
        $monthKey = $currentMonth.ToString('yyyy-MM')
        $months += $monthKey
        
        # Track which index represents the current month
        if ($currentMonth.Year -eq $todayMonth.Year -and $currentMonth.Month -eq $todayMonth.Month) {
            $todayMonthIndex = $currentMonthIndex
        }
        
        $isPastMonth = $currentMonth -lt $todayMonth
        
        $timeline.Add([PSCustomObject]@{
            MonthKey        = $monthKey
            Label           = $currentMonth.ToString('yyyy-MM')
            CriticalCount   = 0
            HighCount       = 0
            MediumCount     = 0
            LowCount        = 0
            CriticalComponents = [System.Collections.Generic.List[string]]::new()
            HighComponents     = [System.Collections.Generic.List[string]]::new()
            MediumComponents   = [System.Collections.Generic.List[string]]::new()
            LowComponents      = [System.Collections.Generic.List[string]]::new()
            IsPastMonth      = $isPastMonth
        })
        
        $currentMonth = $currentMonth.AddMonths(1)
        $currentMonthIndex++
        $iterationCount++
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
    
    # Ensure we have at least some timeline entries (safety check)
    if ($timelineArray.Count -eq 0) {
        Write-Warning "Timeline array is empty - creating default 24-month timeline"
        $timelineArray = @()
        $currentMonth = $todayMonth
        for ($i = 0; $i -lt 24; $i++) {
            $monthDate = $currentMonth.AddMonths($i)
            $monthKey = $monthDate.ToString('yyyy-MM')
            $isPastMonth = $monthDate -lt $todayMonth
            if ($i -eq 0) { $todayMonthIndex = 0 }
            $timelineArray += [PSCustomObject]@{
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
                IsPastMonth      = $isPastMonth
            }
        }
    }

    # Build JSON for chart data and component lists (Severity view)
    # Ensure arrays are never empty - use empty string if no data
    if ($timelineArray.Count -eq 0) {
        $labelsJson = ''
        $isPastMonthJson = ''
        $criticalSeries = ''
        $highSeries = ''
        $mediumSeries = ''
        $lowSeries = ''
        $criticalComponentsJson = ''
        $highComponentsJson = ''
        $mediumComponentsJson = ''
        $lowComponentsJson = ''
    } else {
        $labelsJson = ($timelineArray | ForEach-Object { '"{0}"' -f $_.Label }) -join ','
        $isPastMonthJson = ($timelineArray | ForEach-Object { if ($_.IsPastMonth) { 'true' } else { 'false' } }) -join ','
        $criticalSeries = ($timelineArray | ForEach-Object { $_.CriticalCount }) -join ','
        $highSeries     = ($timelineArray | ForEach-Object { $_.HighCount }) -join ','
        $mediumSeries   = ($timelineArray | ForEach-Object { $_.MediumCount }) -join ','
        $lowSeries      = ($timelineArray | ForEach-Object { $_.LowCount }) -join ','
        
        # Build component lists JSON for tooltips
        # Fix: PowerShell's ConvertTo-Json -Compress on single-element arrays outputs just the string, not an array
        # We need to explicitly wrap single items to ensure they're always arrays
        $criticalComponentsJson = ($timelineArray | ForEach-Object { 
            $comps = @($_.CriticalComponents)
            if ($comps.Count -eq 0) { 
                '[]' 
            } elseif ($comps.Count -eq 1) {
                # Single item - manually wrap to ensure array format
                '[' + ($comps[0] | ConvertTo-Json -Compress) + ']'
            } else {
                # Multiple items - ConvertTo-Json handles arrays correctly
                ConvertTo-Json -InputObject $comps -Compress
            }
        }) -join ','
        
        $highComponentsJson = ($timelineArray | ForEach-Object { 
            $comps = @($_.HighComponents)
            if ($comps.Count -eq 0) { 
                '[]' 
            } elseif ($comps.Count -eq 1) {
                # Single item - manually wrap to ensure array format
                '[' + ($comps[0] | ConvertTo-Json -Compress) + ']'
            } else {
                # Multiple items - ConvertTo-Json handles arrays correctly
                ConvertTo-Json -InputObject $comps -Compress
            }
        }) -join ','
        
        $mediumComponentsJson = ($timelineArray | ForEach-Object { 
            $comps = @($_.MediumComponents)
            if ($comps.Count -eq 0) { 
                '[]' 
            } elseif ($comps.Count -eq 1) {
                # Single item - manually wrap to ensure array format
                '[' + ($comps[0] | ConvertTo-Json -Compress) + ']'
            } else {
                # Multiple items - ConvertTo-Json handles arrays correctly
                ConvertTo-Json -InputObject $comps -Compress
            }
        }) -join ','
        
        $lowComponentsJson = ($timelineArray | ForEach-Object { 
            $comps = @($_.LowComponents)
            if ($comps.Count -eq 0) { 
                '[]' 
            } elseif ($comps.Count -eq 1) {
                # Single item - manually wrap to ensure array format
                '[' + ($comps[0] | ConvertTo-Json -Compress) + ']'
            } else {
                # Multiple items - ConvertTo-Json handles arrays correctly
                ConvertTo-Json -InputObject $comps -Compress
            }
        }) -join ','
    }
    
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
        $deadlineText = if ($compDeadline) { 
            if ($compDeadline -eq "TBD") { "TBD (To Be Determined)" } else { $compDeadline }
        } else { 
            "N/A" 
        }
        $daysText = if ($null -ne $daysUntil) {
            if ($daysUntil -lt 0) { "Past due ({0} d)" -f [math]::Abs($daysUntil) } else { "{0} d" -f $daysUntil }
        } else {
            if ($compDeadline -eq "TBD") { "TBD" } else { "N/A" }
        }

        # Build per‑component resource table
        $resourceRows = ""
        foreach ($f in ($comp.Findings | Sort-Object SubscriptionName, ResourceGroup, ResourceName)) {
            # Prefer SubscriptionName, but if missing, try to get it from SubscriptionId
            $subName = if ($f.SubscriptionName -and $f.SubscriptionName -ne "Unknown") { 
                [System.Web.HttpUtility]::HtmlEncode($f.SubscriptionName) 
            } elseif ($f.SubscriptionId) {
                # Try to get subscription name if we have the ID (suppress warnings/errors)
                try {
                    $displayName = Get-SubscriptionDisplayName -SubscriptionId $f.SubscriptionId -ErrorAction SilentlyContinue -WarningAction SilentlyContinue 2>$null
                    if ($displayName -and $displayName -ne "Unknown" -and $displayName -ne $f.SubscriptionId) {
                        [System.Web.HttpUtility]::HtmlEncode($displayName)
                    } else {
                        [System.Web.HttpUtility]::HtmlEncode($f.SubscriptionId)
                    }
                } catch {
                    [System.Web.HttpUtility]::HtmlEncode($f.SubscriptionId)
                }
            } else {
                "Unknown"
            }
            $rg      = if ($f.ResourceGroup) { [System.Web.HttpUtility]::HtmlEncode($f.ResourceGroup) } else { "N/A" }
            $resName = [System.Web.HttpUtility]::HtmlEncode($f.ResourceName)
            $resType = [System.Web.HttpUtility]::HtmlEncode($f.ResourceType)
            $sev     = $f.Severity
            $sevLower = $sev.ToLower()
            $dl      = $f.Deadline
            $di      = $f.DaysUntilDeadline
            $dlText  = if ($dl) { 
                if ($dl -eq "TBD") { "TBD (To Be Determined)" } else { $dl }
            } else { 
                "N/A" 
            }
            $diText  = if ($null -ne $di) {
                if ($di -lt 0) { "Past due ({0} d)" -f [math]::Abs($di) } else { "{0} d" -f $di }
            } else {
                if ($dl -eq "TBD") { "TBD" } else { "N/A" }
            }

            $action  = $f.ActionRequired
            # Extract URL from ActionRequired if it contains one and make it clickable
            $actionHtml = ""
            if ($action) {
                # Check if ActionRequired contains a URL (http:// or https://)
                if ($action -match '(https?://[^\s<>"]+)') {
                    $actionUrl = $matches[1]
                    # Split action text: part before URL and the URL itself
                    $parts = $action -split '(https?://[^\s<>"]+)', 2
                    $actionText = $parts[0].Trim()
                    if ([string]::IsNullOrWhiteSpace($actionText)) {
                        $actionText = "Review retirement notice:"
                    }
                    
                    # Build HTML with clickable link
                    $escapedText = [System.Web.HttpUtility]::HtmlEncode($actionText)
                    $escapedUrl = [System.Web.HttpUtility]::HtmlAttributeEncode($actionUrl)
                    $escapedUrlText = [System.Web.HttpUtility]::HtmlEncode($actionUrl)
                    $actionHtml = "$escapedText <a href='$escapedUrl' target='_blank' rel='noopener' class='eol-guidance-link' style='color: #ffffff !important; text-decoration: underline !important;'>$escapedUrlText</a>"
                } else {
                    # No URL found, just encode the text
                    $actionHtml = [System.Web.HttpUtility]::HtmlEncode($action)
                }
            }
            
            # Use first reference URL if available, otherwise fall back to migrationGuide
            $guideUrl = $null
            if ($f.References -and $f.References.Count -gt 0) {
                # Get first URL from references array
                $firstRef = $f.References[0]
                if ($firstRef -and $firstRef -match '^https?://') {
                    $guideUrl = $firstRef
                }
            }
            
            # Fallback to migrationGuide if it looks like a URL (and we haven't already used ActionRequired URL)
            if (-not $guideUrl -and $f.MigrationGuide) {
                if ($f.MigrationGuide -match '^https?://') {
                    $guideUrl = $f.MigrationGuide
                }
            }
            
            # Only show "View guidance" link if we have a separate URL (not already in ActionRequired)
            $guideHtml = if ($guideUrl -and $guideUrl -ne $actionUrl) { 
                $escapedUrl = [System.Web.HttpUtility]::HtmlAttributeEncode($guideUrl)
                "<a href='$escapedUrl' target='_blank' rel='noopener' class='eol-guidance-link' style='color: #ffffff !important; text-decoration: underline !important;'>View guidance</a>" 
            } else { 
                "" 
            }

            $resourceRows += @"
                                <tr class="eol-resource-row" data-subscription="$subName" data-severity="$sevLower">
                                    <td>$subName</td>
                                    <td>$rg</td>
                                    <td>$resName</td>
                                    <td>$resType</td>
                                    <td><span class="badge badge--$(if ($sevLower -eq 'critical') { 'danger' } elseif ($sevLower -eq 'high') { 'high' } elseif ($sevLower -eq 'medium') { 'warning' } else { 'info' })">$sev</span></td>
                                    <td>$dlText</td>
                                    <td>$diText</td>
                                    <td>
                                        <div class="resource-action-text">$actionHtml</div>
                                        <div class="eol-guidance-link-container">$guideHtml</div>
                                    </td>
                                </tr>
"@
        }

        $componentCardsHtml += @"
                    <div class="expandable expandable--collapsed" data-severity="$topSeverityLower">
                        <div class="expandable__header" onclick="toggleEolComponent(this)">
                            <div class="expandable__title">
                                <span class="expand-icon"></span>
                                <h3>$compName</h3>
                            </div>
                            <div class="expandable__badges">
                                <span class="badge badge--neutral">$($comp.Count) resource(s)</span>
                                <span class="badge badge--neutral">Deadline: $deadlineText ($daysText)</span>
                                <span class="badge badge--$(if ($topSeverityLower -eq 'critical') { 'danger' } elseif ($topSeverityLower -eq 'high') { 'high' } elseif ($topSeverityLower -eq 'medium') { 'warning' } else { 'info' })">$topSeverity</span>
                            </div>
                        </div>
                        <div class="expandable__content">
                            <table class="data-table data-table--sticky-header data-table--compact">
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
"@
    }

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
    </style>
</head>
<body>
$(Get-ReportNavigation -ActivePage "EOL")

    <div class="container">
        <div class="page-header">
            <h1>&#9200; End of Life / Deprecated Components</h1>
            <div class="metadata">
                <p><strong>Tenant:</strong> $TenantId</p>
                <p><strong>Scanned:</strong> $timestamp</p>
                <p><strong>Subscriptions:</strong> $subscriptionCount</p>
                <p><strong>Resources:</strong> $resourceCount</p>
                <p><strong>Total Findings:</strong> $totalFindings</p>
            </div>
        </div>

        <div class="section-box">
            <h2>EOL Overview</h2>
            <div class="summary-grid">
                <div class="summary-card blue-border">
                    <div class="summary-card-value">$totalFindings</div>
                    <div class="summary-card-label">Total EOL Findings</div>
                </div>
                <div class="summary-card teal-border">
                    <div class="summary-card-value">$componentCount</div>
                    <div class="summary-card-label">Unique Components</div>
                </div>
                <div class="summary-card red-border">
                    <div class="summary-card-value">$criticalTotal</div>
                    <div class="summary-card-label">Critical</div>
                </div>
                <div class="summary-card orange-border">
                    <div class="summary-card-value">$highTotal</div>
                    <div class="summary-card-label">High</div>
                </div>
                <div class="summary-card yellow-border">
                    <div class="summary-card-value">$mediumTotal</div>
                    <div class="summary-card-label">Medium</div>
                </div>
                <div class="summary-card green-border">
                    <div class="summary-card-value">$lowTotal</div>
                    <div class="summary-card-label">Low</div>
                </div>
            </div>
        </div>

        <div class="section-box">
            <h2>EOL Timeline</h2>
            <div class="chart-controls">
                <select id="eolChartView" onchange="updateEolChartView()" class="eol-chart-select">
                    <option value="severity">Stacked by Severity</option>
                    <option value="subscription">Stacked by Subscription</option>
                    <option value="category">Stacked by Category</option>
                </select>
            </div>
            <div class="timeline-legend" id="eolLegend" style="display: none;">
                <div class="timeline-legend-item"><span class="timeline-legend-color timeline-legend-critical"></span> Critical (&lt; 0d or &lt; 90d)</div>
                <div class="timeline-legend-item"><span class="timeline-legend-color timeline-legend-high"></span> High (90-180d)</div>
                <div class="timeline-legend-item"><span class="timeline-legend-color timeline-legend-medium"></span> Medium (180-365d)</div>
                <div class="timeline-legend-item"><span class="timeline-legend-color timeline-legend-low"></span> Low (> 365d)</div>
            </div>
            <div class="chart-container">
                <canvas id="eolTimelineChart"></canvas>
            </div>
        </div>

        <div class="section-box">
            <h2>Deprecated Components</h2>
            <div class="eol-filter-bar">
                <div class="filter-group">
                    <label for="eolSearch">Search</label>
                    <input type="text" id="eolSearch" placeholder="Search component or resource..." />
                </div>
                <div class="filter-group">
                    <label for="eolSeverityFilter">Severity</label>
                    <select id="eolSeverityFilter">
                        <option value="all">All</option>
                        <option value="critical">Critical</option>
                        <option value="high">High</option>
                        <option value="medium">Medium</option>
                        <option value="low">Low</option>
                    </select>
                </div>
            </div>
            <div class="filter-stats">
                Showing <span id="visibleCount">$componentCount</span> of <span id="totalCount">$componentCount</span> components
            </div>

            <div id="eolComponents">
$componentCardsHtml
$(if ($componentCount -eq 0) { @"
                <div class="eol-empty-state">
                    <p>No EOL / deprecated components detected for the scanned subscriptions.</p>
                </div>
"@ })
            </div>
        </div>
    </div>

    <script>
        // Initialize chart data arrays - handle empty case
        const eolLabels = $(if ([string]::IsNullOrWhiteSpace($labelsJson)) { '[]' } else { "[$labelsJson]" });
        const eolCritical = $(if ([string]::IsNullOrWhiteSpace($criticalSeries)) { '[]' } else { "[$criticalSeries]" });
        const eolHigh = $(if ([string]::IsNullOrWhiteSpace($highSeries)) { '[]' } else { "[$highSeries]" });
        const eolMedium = $(if ([string]::IsNullOrWhiteSpace($mediumSeries)) { '[]' } else { "[$mediumSeries]" });
        const eolLow = $(if ([string]::IsNullOrWhiteSpace($lowSeries)) { '[]' } else { "[$lowSeries]" });
        const eolIsPastMonth = $(if ([string]::IsNullOrWhiteSpace($isPastMonthJson)) { '[]' } else { "[$isPastMonthJson]" });
        const eolTodayMonthIndex = $(if ($todayMonthIndex -ge 0) { $todayMonthIndex } else { -1 });
        
        // Component names per month and severity for tooltips
        const eolCriticalComponents = $(if ([string]::IsNullOrWhiteSpace($criticalComponentsJson)) { '[]' } else { "[$criticalComponentsJson]" });
        const eolHighComponents = $(if ([string]::IsNullOrWhiteSpace($highComponentsJson)) { '[]' } else { "[$highComponentsJson]" });
        const eolMediumComponents = $(if ([string]::IsNullOrWhiteSpace($mediumComponentsJson)) { '[]' } else { "[$mediumComponentsJson]" });
        const eolLowComponents = $(if ([string]::IsNullOrWhiteSpace($lowComponentsJson)) { '[]' } else { "[$lowComponentsJson]" });
        
        // Debug logging
        console.log('EOL Chart Data initialized:', {
            labelsCount: eolLabels.length,
            criticalCount: eolCritical.length,
            todayIndex: eolTodayMonthIndex
        });
        
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
        
        // Function to get background color with opacity based on past month
        function getBackgroundColor(datasetIndex, dataIndex) {
            const isPast = eolIsPastMonth && dataIndex < eolIsPastMonth.length && eolIsPastMonth[dataIndex] === true;
            const baseColors = [
                'rgba(231, 76, 60, 0.8)',   // Critical
                'rgba(241, 196, 15, 0.9)',  // High
                'rgba(52, 152, 219, 0.8)',  // Medium
                'rgba(39, 174, 96, 0.8)'    // Low
            ];
            const baseColor = baseColors[datasetIndex] || 'rgba(128, 128, 128, 0.8)';
            
            if (isPast) {
                // Reduce opacity for past months (multiply alpha by 0.5)
                return baseColor.replace(/[\d\.]+\)$/g, function(match) {
                    const alpha = parseFloat(match.replace(')', ''));
                    return (alpha * 0.5).toFixed(2) + ')';
                });
            }
            return baseColor;
        }
        
        // Function to get border color with opacity based on past month
        function getBorderColor(datasetIndex, dataIndex) {
            const isPast = eolIsPastMonth && dataIndex < eolIsPastMonth.length && eolIsPastMonth[dataIndex] === true;
            const baseColors = [
                'rgba(231, 76, 60, 1)',     // Critical
                'rgba(243, 156, 18, 1)',    // High
                'rgba(52, 152, 219, 1)',    // Medium
                'rgba(39, 174, 96, 1)'      // Low
            ];
            const baseColor = baseColors[datasetIndex] || 'rgba(128, 128, 128, 1)';
            
            if (isPast) {
                // Reduce opacity for past months
                return baseColor.replace(/[\d\.]+\)$/g, function(match) {
                    const alpha = parseFloat(match.replace(')', ''));
                    return (alpha * 0.5).toFixed(2) + ')';
                });
            }
            return baseColor;
        }
        
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
                // Severity view - original stacked by severity with past month styling
                // Colors match summary card border colors: Critical=Red, High=Orange, Medium=Yellow, Low=Green
                // For past months (overdue), all events are shown in red to indicate they're past due
                // Pre-compute colors for updateEolChart as well
                const criticalBgUpdate = eolIsPastMonth.map(isPast => isPast ? 'rgba(255, 107, 107, 0.6)' : 'rgba(255, 107, 107, 0.8)');
                const highBgUpdate = eolIsPastMonth.map(isPast => isPast ? 'rgba(255, 107, 107, 0.6)' : 'rgba(255, 159, 67, 0.8)');
                const mediumBgUpdate = eolIsPastMonth.map(isPast => isPast ? 'rgba(255, 107, 107, 0.6)' : 'rgba(254, 202, 87, 0.8)');
                const lowBgUpdate = eolIsPastMonth.map(isPast => isPast ? 'rgba(255, 107, 107, 0.6)' : 'rgba(0, 210, 106, 0.8)');
                
                datasets = [
                    {
                        label: 'Critical (< 0d or < 90d)',
                        data: eolCritical,
                        backgroundColor: criticalBgUpdate,
                        borderColor: function(context) {
                            const dataIndex = context.dataIndex;
                            const isPast = eolIsPastMonth && dataIndex < eolIsPastMonth.length && eolIsPastMonth[dataIndex] === true;
                            return 'rgba(255, 107, 107, 1)'; // Always red for Critical
                        },
                        borderWidth: 1,
                        stack: 'severity'
                    },
                    {
                        label: 'High (90-180d)',
                        data: eolHigh,
                        backgroundColor: highBgUpdate,
                        borderColor: function(context) {
                            const dataIndex = context.dataIndex;
                            const isPast = eolIsPastMonth && dataIndex < eolIsPastMonth.length && eolIsPastMonth[dataIndex] === true;
                            return isPast ? 'rgba(255, 107, 107, 1)' : 'rgba(255, 159, 67, 1)'; // Red if past, orange if future
                        },
                        borderWidth: 1,
                        stack: 'severity'
                    },
                    {
                        label: 'Medium (180-365d)',
                        data: eolMedium,
                        backgroundColor: mediumBgUpdate,
                        borderColor: function(context) {
                            const dataIndex = context.dataIndex;
                            const isPast = eolIsPastMonth && dataIndex < eolIsPastMonth.length && eolIsPastMonth[dataIndex] === true;
                            return isPast ? 'rgba(255, 107, 107, 1)' : 'rgba(254, 202, 87, 1)'; // Red if past, yellow if future
                        },
                        borderWidth: 1,
                        stack: 'severity'
                    },
                    {
                        label: 'Low (> 365d)',
                        data: eolLow,
                        backgroundColor: lowBgUpdate,
                        borderColor: function(context) {
                            const dataIndex = context.dataIndex;
                            const isPast = eolIsPastMonth && dataIndex < eolIsPastMonth.length && eolIsPastMonth[dataIndex] === true;
                            return isPast ? 'rgba(255, 107, 107, 1)' : 'rgba(0, 210, 106, 1)'; // Red if past, green if future
                        },
                        borderWidth: 1,
                        stack: 'severity'
                    }
                ];
                // Hide top timeline legend - Chart.js legend will show with verbose descriptions
                document.getElementById('eolLegend').style.display = 'none';
                // Show chart legend with verbose labels
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
            const canvas = document.getElementById('eolTimelineChart');
            if (!canvas) {
                console.error('EOL timeline chart canvas not found');
                return;
            }
            
            const ctx = canvas.getContext('2d');
            if (!ctx) {
                console.error('Could not get 2d context from canvas');
                return;
            }
            
            // Validate data arrays
            if (!Array.isArray(eolLabels) || eolLabels.length === 0) {
                console.warn('EOL labels array is empty or invalid:', eolLabels);
            }
            if (!Array.isArray(eolCritical) || !Array.isArray(eolHigh) || !Array.isArray(eolMedium) || !Array.isArray(eolLow)) {
                console.error('EOL data arrays are invalid:', {
                    critical: Array.isArray(eolCritical),
                    high: Array.isArray(eolHigh),
                    medium: Array.isArray(eolMedium),
                    low: Array.isArray(eolLow)
                });
                // Don't return - still try to render with empty data
            }
            
            // Ensure arrays have the same length as labels
            const expectedLength = eolLabels.length;
            if (eolCritical.length !== expectedLength) {
                console.warn('EOL Critical array length mismatch:', eolCritical.length, 'expected:', expectedLength);
            }
            if (eolHigh.length !== expectedLength) {
                console.warn('EOL High array length mismatch:', eolHigh.length, 'expected:', expectedLength);
            }
            if (eolMedium.length !== expectedLength) {
                console.warn('EOL Medium array length mismatch:', eolMedium.length, 'expected:', expectedLength);
            }
            if (eolLow.length !== expectedLength) {
                console.warn('EOL Low array length mismatch:', eolLow.length, 'expected:', expectedLength);
            }
            
            try {
                // Pre-compute colors based on isPast
                // Colors match summary card border colors: Critical=Red, High=Orange, Medium=Yellow, Low=Green
                // For past months (overdue), all events are shown in red to indicate they're past due
                const criticalBg = eolIsPastMonth.map(isPast => isPast ? 'rgba(255, 107, 107, 0.6)' : 'rgba(255, 107, 107, 0.8)');
                const highBg = eolIsPastMonth.map(isPast => isPast ? 'rgba(255, 107, 107, 0.6)' : 'rgba(255, 159, 67, 0.8)');
                const mediumBg = eolIsPastMonth.map(isPast => isPast ? 'rgba(255, 107, 107, 0.6)' : 'rgba(254, 202, 87, 0.8)');
                const lowBg = eolIsPastMonth.map(isPast => isPast ? 'rgba(255, 107, 107, 0.6)' : 'rgba(0, 210, 106, 0.8)');
                
                // Pre-compute x-axis tick colors - past months are red
                const xAxisTickColors = eolIsPastMonth.map(isPast => isPast ? '#ff6b6b' : '#888');
                
                eolChart = new Chart(ctx, {
                    type: 'bar',
                    data: {
                        labels: eolLabels,
                        datasets: [
                            {
                                label: 'Critical (< 0d or < 90d)',
                                data: eolCritical,
                                backgroundColor: criticalBg,
                                borderColor: function(context) {
                                    const dataIndex = context.dataIndex;
                                    const isPast = eolIsPastMonth && dataIndex < eolIsPastMonth.length && eolIsPastMonth[dataIndex] === true;
                                    return 'rgba(255, 107, 107, 1)'; // Always red for Critical
                                },
                                borderWidth: 1,
                                stack: 'severity'
                            },
                            {
                                label: 'High (90-180d)',
                                data: eolHigh,
                                backgroundColor: highBg,
                                borderColor: function(context) {
                                    const dataIndex = context.dataIndex;
                                    const isPast = eolIsPastMonth && dataIndex < eolIsPastMonth.length && eolIsPastMonth[dataIndex] === true;
                                    return isPast ? 'rgba(255, 107, 107, 1)' : 'rgba(255, 159, 67, 1)'; // Red if past, orange if future
                                },
                                borderWidth: 1,
                                stack: 'severity'
                            },
                            {
                                label: 'Medium (180-365d)',
                                data: eolMedium,
                                backgroundColor: mediumBg,
                                borderColor: function(context) {
                                    const dataIndex = context.dataIndex;
                                    const isPast = eolIsPastMonth && dataIndex < eolIsPastMonth.length && eolIsPastMonth[dataIndex] === true;
                                    return isPast ? 'rgba(255, 107, 107, 1)' : 'rgba(254, 202, 87, 1)'; // Red if past, yellow if future
                                },
                                borderWidth: 1,
                                stack: 'severity'
                            },
                            {
                                label: 'Low (> 365d)',
                                data: eolLow,
                                backgroundColor: lowBg,
                                borderColor: function(context) {
                                    const dataIndex = context.dataIndex;
                                    const isPast = eolIsPastMonth && dataIndex < eolIsPastMonth.length && eolIsPastMonth[dataIndex] === true;
                                    return isPast ? 'rgba(255, 107, 107, 1)' : 'rgba(0, 210, 106, 1)'; // Red if past, green if future
                                },
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
                                    const label = context[0].label || '';
                                    const dataIndex = context[0].dataIndex;
                                    const isPast = eolIsPastMonth && dataIndex < eolIsPastMonth.length && eolIsPastMonth[dataIndex] === true;
                                    return label + (isPast ? ' (Past)' : '');
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
                        },
                    },
                    scales: {
                        x: {
                            stacked: true,
                            ticks: {
                                color: function(context) {
                                    const index = context.index;
                                    const isPast = eolIsPastMonth && index < eolIsPastMonth.length && eolIsPastMonth[index] === true;
                                    return isPast ? '#ff6b6b' : '#888';
                                },
                                maxRotation: 45,
                                minRotation: 45
                            },
                            grid: {
                                color: 'rgba(61, 61, 92, 0.4)',
                                lineWidth: 1
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
                
                console.log('EOL Chart created successfully');
            } catch (error) {
                console.error('Error creating EOL chart:', error);
                console.error('Chart data:', {
                    labels: eolLabels,
                    critical: eolCritical,
                    high: eolHigh,
                    medium: eolMedium,
                    low: eolLow
                });
            }
            
            // Function to draw vertical line for current month
            function drawCurrentMonthLine(chart) {
                if (eolTodayMonthIndex < 0) return;
                
                const ctx = chart.ctx;
                const xScale = chart.scales.x;
                const yScale = chart.scales.y;
                
                const xPos = xScale.getPixelForValue(eolTodayMonthIndex);
                
                ctx.save();
                ctx.strokeStyle = 'rgba(255, 255, 255, 0.8)';
                ctx.lineWidth = 2;
                ctx.setLineDash([5, 5]);
                ctx.beginPath();
                ctx.moveTo(xPos, yScale.top);
                ctx.lineTo(xPos, yScale.bottom);
                ctx.stroke();
                ctx.setLineDash([]);
                
                // Draw label
                ctx.fillStyle = 'rgba(255, 255, 255, 0.9)';
                ctx.font = 'bold 11px Arial';
                ctx.textAlign = 'center';
                ctx.textBaseline = 'top';
                ctx.fillRect(xPos - 25, yScale.top + 5, 50, 18);
                ctx.fillStyle = '#000';
                ctx.fillText('Today', xPos, yScale.top + 8);
                
                ctx.restore();
            }

            initEolFilters();
        });

        function initEolFilters() {
            const searchInput = document.getElementById('eolSearch');
            const severitySelect = document.getElementById('eolSeverityFilter');

            function applyFilters() {
                const search = (searchInput.value || '').toLowerCase();
                const sevFilter = (severitySelect.value || 'all');

                const cards = document.querySelectorAll('.expandable[data-severity]');
                cards.forEach(card => {
                    let visible = true;

                    if (sevFilter !== 'all') {
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

                    card.classList.toggle('hidden', !visible);
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
            const expandable = headerEl.closest('.expandable');
            if (!expandable) return;
            expandable.classList.toggle('expandable--collapsed');
        }
    </script>

</body>
</html>
"@

    # Persist HTML to disk
    # Write to file with UTF-8 encoding (no BOM for better browser compatibility)
    [System.IO.File]::WriteAllText($OutputPath, $html, [System.Text.UTF8Encoding]::new($false))

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

