<#
.SYNOPSIS
    Combines domain-specific AI insights into single JSON payload.

.DESCRIPTION
    Takes hashtables of insights from different modules and combines them
    into a single, structured JSON payload for AI analysis.

.PARAMETER AdvisorInsights
    Comprehensive Advisor recommendations insights (all categories).

.PARAMETER CostInsights
    Cost optimization insights from Advisor (deprecated - use AdvisorInsights instead).

.PARAMETER SecurityInsights
    Security compliance insights hashtable.

.PARAMETER RBACInsights
    RBAC governance insights hashtable.

.PARAMETER NetworkInsights
    Network security insights hashtable.

.PARAMETER EOLInsights
    EOL compliance insights hashtable.

.PARAMETER ChangeTrackingInsights
    Change tracking insights hashtable.

.PARAMETER VMBackupInsights
    VM backup insights hashtable.

.PARAMETER CostTrackingInsights
    Actual cost tracking insights (spending data, not recommendations).

.PARAMETER SubscriptionCount
    Total number of subscriptions analyzed.

.EXAMPLE
    $payload = ConvertTo-CombinedPayload -AdvisorInsights $advisor -SecurityInsights $sec -RBACInsights $rbac -SubscriptionCount 30
#>
function ConvertTo-CombinedPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$AdvisorInsights,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$CostInsights,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$SecurityInsights,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$RBACInsights,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$NetworkInsights,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$EOLInsights,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$ChangeTrackingInsights,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$VMBackupInsights,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$CostTrackingInsights,
        
        [Parameter(Mandatory = $true)]
        [int]$SubscriptionCount
    )
    
    # Build combined payload
    $payload = @{
        report_metadata = @{
            generated_at = (Get-Date).ToString("o")
            reporting_period = (Get-Date -Format "yyyy-MM")
            subscription_count = $SubscriptionCount
            modules_analyzed = @()
        }
    }
    
    # Add each domain's insights
    if ($AdvisorInsights) {
        $payload.advisor_recommendations = $AdvisorInsights
        $payload.report_metadata.modules_analyzed += "advisor_recommendations"
    }
    
    # Keep CostInsights for backward compatibility, but prefer AdvisorInsights
    if ($CostInsights -and -not $AdvisorInsights) {
        $payload.cost_optimization = $CostInsights
        $payload.report_metadata.modules_analyzed += "cost_optimization"
    }
    
    if ($SecurityInsights) {
        $payload.security_compliance = $SecurityInsights
        $payload.report_metadata.modules_analyzed += "security_compliance"
    }
    
    if ($RBACInsights) {
        $payload.rbac_governance = $RBACInsights
        $payload.report_metadata.modules_analyzed += "rbac_governance"
    }
    
    if ($NetworkInsights) {
        $payload.network_security = $NetworkInsights
        $payload.report_metadata.modules_analyzed += "network_security"
    }
    
    if ($EOLInsights) {
        $payload.eol_compliance = $EOLInsights
        $payload.report_metadata.modules_analyzed += "eol_compliance"
    }
    
    if ($ChangeTrackingInsights) {
        $payload.change_tracking = $ChangeTrackingInsights
        $payload.report_metadata.modules_analyzed += "change_tracking"
    }
    
    if ($VMBackupInsights) {
        $payload.vm_backup = $VMBackupInsights
        $payload.report_metadata.modules_analyzed += "vm_backup"
    }
    
    if ($CostTrackingInsights) {
        $payload.cost_tracking = $CostTrackingInsights
        $payload.report_metadata.modules_analyzed += "cost_tracking"
    }
    
    return $payload
}

