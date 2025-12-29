<#
.SYNOPSIS
    Converts change tracking data into AI-ready JSON insights.

.DESCRIPTION
    Extracts and structures the most important change tracking insights
    for AI analysis, focusing on security alerts, delete operations,
    and unusual activity patterns.

.PARAMETER ChangeTrackingData
    Array of change tracking objects from Get-AzureChangeAnalysis.

.PARAMETER TopN
    Number of top findings to include (default: 20).

.EXAMPLE
    $insights = ConvertTo-ChangeTrackingAIInsights -ChangeTrackingData $changes -TopN 25
#>
function ConvertTo-ChangeTrackingAIInsights {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$ChangeTrackingData,
        
        [Parameter(Mandatory = $false)]
        [int]$TopN = 20
    )
    
    Write-Verbose "Converting change tracking data to AI insights (TopN: $TopN)"
    
    # Handle empty/null data
    if (-not $ChangeTrackingData -or $ChangeTrackingData.Count -eq 0) {
        Write-Verbose "No change tracking data found"
        return @{
            domain = "change_tracking"
            generated_at = (Get-Date).ToString("o")
            summary = @{
                total_changes = 0
                creates = 0
                updates = 0
                deletes = 0
                security_alerts = 0
                high_security_flags = 0
                medium_security_flags = 0
                affected_subscriptions = 0
            }
            security_alerts = @()
            delete_operations = @()
            activity_patterns = @()
            by_resource_type = @()
        }
    }
    
    # Calculate summary statistics
    $totalChanges = $ChangeTrackingData.Count
    $creates = @($ChangeTrackingData | Where-Object { $_.ChangeType -eq 'Create' }).Count
    $updates = @($ChangeTrackingData | Where-Object { $_.ChangeType -eq 'Update' }).Count
    $deletes = @($ChangeTrackingData | Where-Object { $_.ChangeType -eq 'Delete' }).Count
    
    $highSecurityFlags = @($ChangeTrackingData | Where-Object { $_.SecurityFlag -eq 'high' }).Count
    $mediumSecurityFlags = @($ChangeTrackingData | Where-Object { $_.SecurityFlag -eq 'medium' }).Count
    $totalSecurityAlerts = $highSecurityFlags + $mediumSecurityFlags
    
    $affectedSubscriptions = ($ChangeTrackingData | Select-Object -ExpandProperty SubscriptionName -Unique).Count
    
    # Get security alerts (high and medium priority)
    $securityAlerts = @($ChangeTrackingData | 
        Where-Object { $_.SecurityFlag -in @('high', 'medium') } | 
        Sort-Object @{
            Expression = {
                if ($_.SecurityFlag -eq 'high') { 0 } else { 1 }
            }
        }, ChangeTime -Descending | 
        Select-Object -First $TopN | 
        ForEach-Object {
            @{
                change_time = if ($_.ChangeTime -is [DateTime]) { 
                    $_.ChangeTime.ToString("o") 
                } else { 
                    try { ([DateTime]$_.ChangeTime).ToString("o") } catch { $_.ChangeTime.ToString() }
                }
                change_type = $_.ChangeType
                resource_name = $_.ResourceName
                resource_type = $_.ResourceType
                resource_category = $_.ResourceCategory
                resource_group = $_.ResourceGroup
                subscription = $_.SubscriptionName
                security_flag = $_.SecurityFlag
                security_reason = $_.SecurityReason
                caller = $_.Caller
                caller_type = $_.CallerType
                operation = $_.Operation
                change_source = $_.ChangeSource
            }
        })
    
    # Get delete operations (potential data loss)
    $deleteOperations = @($ChangeTrackingData | 
        Where-Object { $_.ChangeType -eq 'Delete' } | 
        Sort-Object ChangeTime -Descending | 
        Select-Object -First $TopN | 
        ForEach-Object {
            @{
                change_time = if ($_.ChangeTime -is [DateTime]) { 
                    $_.ChangeTime.ToString("o") 
                } else { 
                    try { ([DateTime]$_.ChangeTime).ToString("o") } catch { $_.ChangeTime.ToString() }
                }
                resource_name = $_.ResourceName
                resource_type = $_.ResourceType
                resource_category = $_.ResourceCategory
                resource_group = $_.ResourceGroup
                subscription = $_.SubscriptionName
                caller = $_.Caller
                caller_type = $_.CallerType
                operation = $_.Operation
                security_flag = $_.SecurityFlag
                security_reason = $_.SecurityReason
            }
        })
    
    # Analyze activity patterns (bursts, off-hours)
    $activityPatterns = @()
    
    # Group changes by hour to find unusual patterns
    $changesByHour = $ChangeTrackingData | 
        Where-Object { $_.ChangeTime } |
        Group-Object @{
            Expression = {
                if ($_.ChangeTime -is [DateTime]) {
                    $_.ChangeTime.ToString("yyyy-MM-dd HH:00")
                } else {
                    try {
                        ([DateTime]$_.ChangeTime).ToString("yyyy-MM-dd HH:00")
                    } catch {
                        "Unknown"
                    }
                }
            }
        }
    
    # Find hours with unusually high activity (more than 2 standard deviations above mean)
    if ($changesByHour.Count -gt 0) {
        $hourlyCounts = $changesByHour | ForEach-Object { $_.Count }
        $mean = ($hourlyCounts | Measure-Object -Average).Average
        $stdDev = if ($hourlyCounts.Count -gt 1) {
            $variance = ($hourlyCounts | ForEach-Object { [math]::Pow($_ - $mean, 2) } | Measure-Object -Average).Average
            [math]::Sqrt($variance)
        } else {
            0
        }
        $threshold = $mean + (2 * $stdDev)
        
        $burstHours = @($changesByHour | 
            Where-Object { $_.Count -gt $threshold } | 
            Sort-Object Count -Descending | 
            Select-Object -First 5)
        
        foreach ($burst in $burstHours) {
            $hourChanges = $burst.Group
            $hourTime = if ($hourChanges[0].ChangeTime -is [DateTime]) {
                $hourChanges[0].ChangeTime
            } else {
                try {
                    [DateTime]::Parse($hourChanges[0].ChangeTime)
                } catch {
                    Get-Date
                }
            }
            
            $activityPatterns += @{
                pattern_type = "activity_burst"
                time_period = $burst.Name
                change_count = $burst.Count
                hour = $hourTime.Hour
                day_of_week = $hourTime.DayOfWeek.ToString()
                is_off_hours = ($hourTime.Hour -lt 6 -or $hourTime.Hour -gt 22)
                description = "Unusual spike in activity: $($burst.Count) changes in one hour"
            }
        }
    }
    
    # Find off-hours activity (outside business hours: 6 AM - 10 PM)
    $offHoursChanges = @($ChangeTrackingData | 
        Where-Object { 
            $changeTime = if ($_.ChangeTime -is [DateTime]) { 
                $_.ChangeTime 
            } else { 
                try { [DateTime]::Parse($_.ChangeTime) } catch { $null }
            }
            if ($changeTime) {
                $hour = $changeTime.Hour
                $hour -lt 6 -or $hour -gt 22
            } else {
                $false
            }
        })
    
    if ($offHoursChanges.Count -gt 0) {
        $offHoursPercentage = [math]::Round(($offHoursChanges.Count / $totalChanges) * 100, 1)
        if ($offHoursPercentage -gt 10) {  # Only flag if >10% of changes are off-hours
            $activityPatterns += @{
                pattern_type = "off_hours_activity"
                change_count = $offHoursChanges.Count
                percentage = $offHoursPercentage
                description = "$offHoursPercentage% of changes occurred outside business hours (6 AM - 10 PM)"
            }
        }
    }
    
    # Group by resource type
    $byResourceType = @($ChangeTrackingData | 
        Group-Object ResourceType | 
        Sort-Object Count -Descending | 
        Select-Object -First 10 | 
        ForEach-Object {
            $typeChanges = $_.Group
            @{
                resource_type = $_.Name
                count = $_.Count
                percentage = [math]::Round(($_.Count / $totalChanges) * 100, 1)
                creates = @($typeChanges | Where-Object { $_.ChangeType -eq 'Create' }).Count
                updates = @($typeChanges | Where-Object { $_.ChangeType -eq 'Update' }).Count
                deletes = @($typeChanges | Where-Object { $_.ChangeType -eq 'Delete' }).Count
                security_alerts = @($typeChanges | Where-Object { $_.SecurityFlag -in @('high', 'medium') }).Count
            }
        })
    
    $insights = @{
        domain = "change_tracking"
        generated_at = (Get-Date).ToString("o")
        
        summary = @{
            total_changes = $totalChanges
            creates = $creates
            updates = $updates
            deletes = $deletes
            security_alerts = $totalSecurityAlerts
            high_security_flags = $highSecurityFlags
            medium_security_flags = $mediumSecurityFlags
            affected_subscriptions = $affectedSubscriptions
        }
        
        security_alerts = $securityAlerts
        
        delete_operations = $deleteOperations
        
        activity_patterns = $activityPatterns
        
        by_resource_type = $byResourceType
    }
    
    Write-Verbose "Change tracking insights generated: $totalChanges changes, $totalSecurityAlerts security alerts, $deletes deletes"
    
    return $insights
}

