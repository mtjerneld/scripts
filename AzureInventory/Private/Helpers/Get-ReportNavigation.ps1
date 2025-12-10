<#
.SYNOPSIS
    Generates HTML navigation bar for audit reports.

.DESCRIPTION
    Creates a consistent navigation bar with links to all report pages.
    The active page is highlighted.

.PARAMETER ActivePage
    The currently active page: "Dashboard", "Security", "VMBackup", or "Advisor".

.EXAMPLE
    $nav = Get-ReportNavigation -ActivePage "Security"
#>
function Get-ReportNavigation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Dashboard', 'Security', 'VMBackup', 'Advisor', 'ChangeTracking')]
        [string]$ActivePage
    )
    
    $dashboardClass = if ($ActivePage -eq 'Dashboard') { 'active' } else { '' }
    $securityClass = if ($ActivePage -eq 'Security') { 'active' } else { '' }
    $vmBackupClass = if ($ActivePage -eq 'VMBackup') { 'active' } else { '' }
    $advisorClass = if ($ActivePage -eq 'Advisor') { 'active' } else { '' }
    $changeTrackingClass = if ($ActivePage -eq 'ChangeTracking') { 'active' } else { '' }
    
    return @"
    <nav class="report-nav">
        <span class="nav-brand">Azure Audit Reports</span>
        <a href="index.html" class="nav-link $dashboardClass">Dashboard</a>
        <a href="security.html" class="nav-link $securityClass">Security Audit</a>
        <a href="vm-backup.html" class="nav-link $vmBackupClass">VM Backup</a>
        <a href="advisor.html" class="nav-link $advisorClass">Advisor</a>
        <a href="change-tracking.html" class="nav-link $changeTrackingClass">Change Tracking</a>
    </nav>
"@
}


