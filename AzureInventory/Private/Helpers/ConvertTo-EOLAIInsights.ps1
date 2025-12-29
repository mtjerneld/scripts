<#
.SYNOPSIS
    Converts EOL findings data into AI-ready JSON insights.

.DESCRIPTION
    Extracts and structures the most important EOL (End of Life) insights
    for AI analysis, focusing on critical components, upcoming deadlines,
    and affected resources.

.PARAMETER EOLFindings
    Array of EOL finding objects from Get-AzureEOLStatus.

.PARAMETER TopN
    Number of top findings to include (default: 20).

.PARAMETER DaysThreshold
    Only include EOL findings within this many days (default: 90).

.EXAMPLE
    $insights = ConvertTo-EOLAIInsights -EOLFindings $eolFindings -TopN 25 -DaysThreshold 90
#>
function ConvertTo-EOLAIInsights {
    [CmdletBinding()]
    param(
    [Parameter(Mandatory = $false)]
    [array]$EOLFindings = @(),
        
        [Parameter(Mandatory = $false)]
        [int]$TopN = 20,
        
        [Parameter(Mandatory = $false)]
        [int]$DaysThreshold = 90
    )
    
    Write-Verbose "Converting EOL data to AI insights (TopN: $TopN, DaysThreshold: $DaysThreshold)"
    
    # Handle empty/null data
    if (-not $EOLFindings -or $EOLFindings.Count -eq 0) {
        Write-Verbose "No EOL findings found"
        return @{
            domain = "eol_compliance"
            generated_at = (Get-Date).ToString("o")
            summary = @{
                total_findings = 0
                critical_count = 0
                high_count = 0
                medium_count = 0
                low_count = 0
                unique_components = 0
                affected_resources = 0
                affected_subscriptions = 0
                upcoming_deadlines_count = 0
            }
            critical_components = @()
            upcoming_deadlines = @()
            by_severity = @()
            timeline = @()
        }
    }
    
    # Filter to findings within threshold (if DaysUntilDeadline is available)
    $today = Get-Date
    $filteredFindings = @($EOLFindings | Where-Object {
        if ($null -eq $_.DaysUntilDeadline) {
            # If DaysUntilDeadline is null, try to parse Deadline
            if ($_.Deadline -and $_.Deadline -ne "TBD") {
                try {
                    $deadlineDate = [DateTime]::Parse($_.Deadline)
                    $daysUntil = ($deadlineDate - $today).Days
                    $daysUntil -le $DaysThreshold
                } catch {
                    $true  # Include if we can't parse
                }
            } else {
                $true  # Include if no deadline
            }
        } else {
            $_.DaysUntilDeadline -le $DaysThreshold
        }
    })
    
    # Calculate summary statistics
    $totalFindings = $filteredFindings.Count
    $criticalCount = @($filteredFindings | Where-Object { $_.Severity -eq 'Critical' }).Count
    $highCount = @($filteredFindings | Where-Object { $_.Severity -eq 'High' }).Count
    $mediumCount = @($filteredFindings | Where-Object { $_.Severity -eq 'Medium' }).Count
    $lowCount = @($filteredFindings | Where-Object { $_.Severity -eq 'Low' }).Count
    
    $uniqueComponents = ($filteredFindings | Select-Object -ExpandProperty Component -Unique).Count
    $affectedResources = ($filteredFindings | Select-Object -ExpandProperty ResourceName -Unique).Count
    $affectedSubscriptions = ($filteredFindings | Select-Object -ExpandProperty SubscriptionName -Unique).Count
    
    # Find upcoming deadlines (within 90 days, sorted by urgency)
    $upcomingDeadlines = @($filteredFindings | 
        Where-Object { 
            $_.Deadline -and $_.Deadline -ne "TBD" -and 
            ($null -eq $_.DaysUntilDeadline -or $_.DaysUntilDeadline -ge 0)
        } | 
        Sort-Object @{
            Expression = {
                if ($null -ne $_.DaysUntilDeadline) {
                    $_.DaysUntilDeadline
                } else {
                    try {
                        $deadlineDate = [DateTime]::Parse($_.Deadline)
                        ($deadlineDate - $today).Days
                    } catch {
                        99999
                    }
                }
            }
        } | 
        Select-Object -First $TopN)
    
    # Group by component for critical components list
    $componentsByGroup = $filteredFindings | Group-Object Component
    $criticalComponents = @($componentsByGroup | 
        Where-Object {
            $group = $_.Group
            @($group | Where-Object { $_.Severity -in @('Critical', 'High') }).Count -gt 0
        } | 
        Sort-Object @{
            Expression = {
                $group = $_.Group
                $critical = @($group | Where-Object { $_.Severity -eq 'Critical' }).Count
                $high = @($group | Where-Object { $_.Severity -eq 'High' }).Count
                # Sort by critical count first, then high count
                -($critical * 1000 + $high)
            }
        } | 
        Select-Object -First $TopN | 
        ForEach-Object {
            $group = $_.Group
            $firstFinding = $group[0]
            $affectedResources = ($group | Select-Object -ExpandProperty ResourceName -Unique).Count
            $affectedSubs = ($group | Select-Object -ExpandProperty SubscriptionName -Unique).Count
            
            # Get earliest deadline
            $earliestDeadline = $null
            $earliestDays = $null
            foreach ($finding in $group) {
                if ($finding.Deadline -and $finding.Deadline -ne "TBD") {
                    $days = if ($null -ne $finding.DaysUntilDeadline) {
                        $finding.DaysUntilDeadline
                    } else {
                        try {
                            $deadlineDate = [DateTime]::Parse($finding.Deadline)
                            ($deadlineDate - $today).Days
                        } catch {
                            $null
                        }
                    }
                    if ($null -ne $days -and ($null -eq $earliestDays -or $days -lt $earliestDays)) {
                        $earliestDays = $days
                        $earliestDeadline = $finding.Deadline
                    }
                }
            }
            
            @{
                component = $_.Name
                status = $firstFinding.Status
                severity = if (@($group | Where-Object { $_.Severity -eq 'Critical' }).Count -gt 0) { "Critical" } 
                          elseif (@($group | Where-Object { $_.Severity -eq 'High' }).Count -gt 0) { "High" }
                          else { "Medium" }
                affected_resources = $affectedResources
                affected_subscriptions = $affectedSubs
                total_findings = $group.Count
                critical_count = @($group | Where-Object { $_.Severity -eq 'Critical' }).Count
                high_count = @($group | Where-Object { $_.Severity -eq 'High' }).Count
                deadline = $earliestDeadline
                days_until_deadline = $earliestDays
                action_required = $firstFinding.ActionRequired
            }
        })
    
    # Build timeline (group by month)
    $timeline = @()
    $findingsByMonth = $filteredFindings | 
        Where-Object { $_.Deadline -and $_.Deadline -ne "TBD" } |
        Group-Object @{
            Expression = {
                try {
                    $deadlineDate = [DateTime]::Parse($_.Deadline)
                    $deadlineDate.ToString("yyyy-MM")
                } catch {
                    "Unknown"
                }
            }
        }
    
    foreach ($monthGroup in $findingsByMonth) {
        $monthFindings = $monthGroup.Group
        $timeline += @{
            month = $monthGroup.Name
            count = $monthFindings.Count
            critical_count = @($monthFindings | Where-Object { $_.Severity -eq 'Critical' }).Count
            high_count = @($monthFindings | Where-Object { $_.Severity -eq 'High' }).Count
            components = @($monthFindings | Select-Object -ExpandProperty Component -Unique)
        }
    }
    
    $timeline = @($timeline | Sort-Object month)
    
    # Group by severity
    $bySeverity = @($filteredFindings | 
        Group-Object Severity | 
        ForEach-Object {
            @{
                severity = $_.Name
                count = $_.Count
                percentage = [math]::Round(($_.Count / $totalFindings) * 100, 1)
                unique_components = ($_.Group | Select-Object -ExpandProperty Component -Unique).Count
                affected_resources = ($_.Group | Select-Object -ExpandProperty ResourceName -Unique).Count
            }
        } | Sort-Object @{
            Expression = {
                switch ($_.severity) {
                    "Critical" { 0 }
                    "High" { 1 }
                    "Medium" { 2 }
                    "Low" { 3 }
                    default { 4 }
                }
            }
        })
    
    $insights = @{
        domain = "eol_compliance"
        generated_at = (Get-Date).ToString("o")
        
        summary = @{
            total_findings = $totalFindings
            critical_count = $criticalCount
            high_count = $highCount
            medium_count = $mediumCount
            low_count = $lowCount
            unique_components = $uniqueComponents
            affected_resources = $affectedResources
            affected_subscriptions = $affectedSubscriptions
            upcoming_deadlines_count = $upcomingDeadlines.Count
        }
        
        critical_components = $criticalComponents
        
        upcoming_deadlines = @($upcomingDeadlines | ForEach-Object {
            @{
                component = $_.Component
                resource_name = $_.ResourceName
                resource_type = $_.ResourceType
                subscription = $_.SubscriptionName
                resource_group = $_.ResourceGroup
                deadline = $_.Deadline
                days_until_deadline = $_.DaysUntilDeadline
                severity = $_.Severity
                status = $_.Status
                action_required = $_.ActionRequired
                migration_guide = $_.MigrationGuide
            }
        })
        
        by_severity = $bySeverity
        
        timeline = $timeline
    }
    
    Write-Verbose "EOL insights generated: $totalFindings findings, $uniqueComponents components, $upcomingDeadlines.Count upcoming deadlines"
    
    return $insights
}

