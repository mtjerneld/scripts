<#
.SYNOPSIS
    Executes a script block with suppressed warnings from Azure PowerShell modules.

.DESCRIPTION
    Temporarily suppresses warnings (e.g., unapproved verbs, breaking changes) from Azure PowerShell modules
    while executing a script block, then restores the original warning preference.

.PARAMETER ScriptBlock
    Script block to execute with suppressed warnings.

.PARAMETER SuppressPSDefaultParams
    If specified, also suppresses warnings via PSDefaultParameterValues (for Azure cmdlets).

.EXAMPLE
    $result = Invoke-WithSuppressedWarnings {
        Get-AzStorageAccount
    }

.EXAMPLE
    $result = Invoke-WithSuppressedWarnings -ScriptBlock { Get-AzSubscription } -SuppressPSDefaultParams
#>
function Invoke-WithSuppressedWarnings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        
        [switch]$SuppressPSDefaultParams
    )
    
    # Save original warning preference
    $originalWarningPreference = $WarningPreference
    $WarningPreference = 'SilentlyContinue'
    
    # Optionally suppress via PSDefaultParameterValues
    $originalPSDefaultParams = $null
    if ($SuppressPSDefaultParams) {
        $originalPSDefaultParams = $PSDefaultParameterValues.Clone()
        $PSDefaultParameterValues['*:WarningAction'] = 'SilentlyContinue'
    }
    
    try {
        $result = & $ScriptBlock
        return $result
    }
    finally {
        # Restore original warning preference
        $WarningPreference = $originalWarningPreference
        
        # Restore PSDefaultParameterValues if we modified them
        if ($SuppressPSDefaultParams -and $originalPSDefaultParams) {
            $PSDefaultParameterValues.Clear()
            foreach ($key in $originalPSDefaultParams.Keys) {
                $PSDefaultParameterValues[$key] = $originalPSDefaultParams[$key]
            }
        }
    }
}




