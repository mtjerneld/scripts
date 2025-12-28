<#
.SYNOPSIS
    Estimates remediation effort for a security finding.

.DESCRIPTION
    Returns effort rating (low/medium/high) based on control type,
    severity, and affected resource count.

.PARAMETER Finding
    Security finding object.

.EXAMPLE
    $effort = Get-RemediationEffort -Finding $securityFinding
#>
function Get-RemediationEffort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Finding
    )
    
    # Base effort on control category (CIS section)
    $baseEffort = switch -Regex ($Finding.ControlId) {
        # Network controls often require coordination
        "^(3\.|4\.)" { "medium" }  # CIS sections 3 (Networking) and 4 (VM)
        
        # Storage and database controls are usually straightforward
        "^(2\.|7\.)" { "low" }     # CIS sections 2 (Storage) and 7 (Database)
        
        # IAM controls can be complex
        "^1\." { "high" }          # CIS section 1 (Identity)
        
        # Logging and monitoring
        "^5\." { "low" }           # CIS section 5 (Logging)
        
        # Default
        default { "medium" }
    }
    
    # Adjust for number of affected resources
    if ($Finding.AffectedResources -and $Finding.AffectedResources -gt 50) {
        # Large-scale changes require more effort
        if ($baseEffort -eq "low") { $baseEffort = "medium" }
        elseif ($baseEffort -eq "medium") { $baseEffort = "high" }
    }
    
    # Critical findings might need expedited handling (can reduce effort if small scope)
    if ($Finding.Severity -eq "Critical" -and $Finding.AffectedResources -and $Finding.AffectedResources -le 5) {
        # Small number of critical issues = focused remediation
        $baseEffort = "low"
    }
    
    return $baseEffort
}

