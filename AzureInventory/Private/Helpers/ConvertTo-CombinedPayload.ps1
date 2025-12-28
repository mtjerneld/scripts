<#
.SYNOPSIS
    Combines domain-specific AI insights into single JSON payload.

.DESCRIPTION
    Takes hashtables of insights from different modules and combines them
    into a single, structured JSON payload for AI analysis.

.PARAMETER CostInsights
    Cost analysis insights hashtable.

.PARAMETER SecurityInsights
    Security analysis insights hashtable.

.PARAMETER SubscriptionCount
    Total number of subscriptions analyzed.

.EXAMPLE
    $payload = ConvertTo-CombinedPayload -CostInsights $cost -SecurityInsights $sec -SubscriptionCount 30
#>
function ConvertTo-CombinedPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$CostInsights,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$SecurityInsights,
        
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
    if ($CostInsights) {
        $payload.cost_optimization = $CostInsights
        $payload.report_metadata.modules_analyzed += "cost_optimization"
    }
    
    if ($SecurityInsights) {
        $payload.security_compliance = $SecurityInsights
        $payload.report_metadata.modules_analyzed += "security_compliance"
    }
    
    return $payload
}

