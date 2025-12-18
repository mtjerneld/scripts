<#
.SYNOPSIS
    Generates the navigation HTML for audit reports.

.DESCRIPTION
    Returns consistent navigation HTML used across all report pages.

.PARAMETER ActivePage
    The current page to highlight as active.

.OUTPUTS
    HTML string containing the navigation bar.
#>
function Get-ReportNavigation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet('Dashboard', 'Security', 'Network', 'VMBackup', 'Advisor', 'ChangeTracking', 'CostTracking', 'EOL')]
        [string]$ActivePage = 'Dashboard'
    )
    
    $navItems = @(
        @{ Name = 'Dashboard';         Href = 'index.html';           Page = 'Dashboard' }
        @{ Name = 'Security Audit';    Href = 'security.html';        Page = 'Security' }
        @{ Name = 'Network Inventory'; Href = 'network.html';         Page = 'Network' }
        @{ Name = 'VM Backup';         Href = 'vm-backup.html';       Page = 'VMBackup' }
        @{ Name = 'Advisor';           Href = 'advisor.html';         Page = 'Advisor' }
        @{ Name = 'Change Tracking';   Href = 'change-tracking.html'; Page = 'ChangeTracking' }
        @{ Name = 'Cost Tracking';     Href = 'cost-tracking.html';   Page = 'CostTracking' }
        @{ Name = 'EOL Tracking';      Href = 'eol.html';             Page = 'EOL' }
    )
    
    $navHtml = @"
    <nav class="report-nav">
        <span class="nav-brand">Azure Audit Reports</span>
"@
    
    foreach ($item in $navItems) {
        $activeClass = if ($item.Page -eq $ActivePage) { ' active' } else { '' }
        $navHtml += "`n        <a href=`"$($item.Href)`" class=`"nav-link$activeClass`">$($item.Name)</a>"
    }
    
    $navHtml += "`n    </nav>"
    
    return $navHtml
}
