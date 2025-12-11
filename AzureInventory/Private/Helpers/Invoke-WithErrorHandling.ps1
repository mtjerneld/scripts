<#
.SYNOPSIS
    Executes a script block with standardized error handling.

.DESCRIPTION
    Wraps script block execution with consistent try-catch error handling,
    logging, and optional error collection.

.PARAMETER ScriptBlock
    Script block to execute.

.PARAMETER ErrorMessage
    Custom error message prefix for logging.

.PARAMETER Errors
    Optional list to append errors to.

.PARAMETER ContinueOnError
    If specified, returns $null on error instead of throwing.

.EXAMPLE
    $result = Invoke-WithErrorHandling -ScriptBlock { Get-AzResource } -ErrorMessage "Failed to get resources"
#>
function Invoke-WithErrorHandling {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        
        [Parameter(Mandatory = $false)]
        [string]$ErrorMessage = "An error occurred",
        
        [Parameter(Mandatory = $false)]
        [System.Collections.Generic.List[string]]$Errors,
        
        [switch]$ContinueOnError
    )
    
    try {
        return & $ScriptBlock
    }
    catch {
        $errorMsg = "$ErrorMessage : $_"
        Write-Verbose $errorMsg
        Write-Verbose "Error type: $($_.Exception.GetType().FullName)"
        Write-Verbose "Error message: $($_.Exception.Message)"
        
        if ($_.ScriptStackTrace) {
            Write-Verbose "Stack trace: $($_.ScriptStackTrace)"
        }
        
        if ($Errors) {
            $Errors.Add($errorMsg)
        }
        
        if ($ContinueOnError) {
            return $null
        } else {
            throw
        }
    }
}



