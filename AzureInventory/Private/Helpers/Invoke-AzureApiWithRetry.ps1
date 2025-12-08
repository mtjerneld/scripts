<#
.SYNOPSIS
    Executes an Azure API call with automatic retry logic for rate limiting and transient errors.

.DESCRIPTION
    Wraps Azure API calls with exponential backoff retry logic to handle:
    - HTTP 429 (Too Many Requests) - rate limiting
    - HTTP 503 (Service Unavailable) - transient service errors
    - Other transient exceptions

.PARAMETER ScriptBlock
    Script block containing the Azure API call to execute.

.PARAMETER MaxRetries
    Maximum number of retry attempts (default: 3).

.PARAMETER BaseDelaySeconds
    Base delay in seconds for exponential backoff (default: 2).

.EXAMPLE
    $storageAccounts = Invoke-AzureApiWithRetry {
        Get-AzStorageAccount
    }
#>
function Invoke-AzureApiWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        
        [int]$MaxRetries = 3,
        
        [int]$BaseDelaySeconds = 2
    )
    
    $attempt = 0
    $lastError = $null
    
    # Save original warning preference
    $originalWarningPreference = $WarningPreference
    
    do {
        $attempt++
        try {
            # Suppress warnings from Azure PowerShell modules (e.g., unapproved verbs)
            # This must be set before the scriptblock executes to catch module import warnings
            $WarningPreference = 'SilentlyContinue'
            $result = & $ScriptBlock
            $WarningPreference = $originalWarningPreference
            return $result
        }
        catch {
            # Restore warning preference even on error
            $WarningPreference = $originalWarningPreference
            $lastError = $_
            $errorMessage = $_.Exception.Message
            
            if ($attempt -lt $MaxRetries) {
                if ($errorMessage -match '429|throttl|TooManyRequests') {
                    # Exponential backoff for rate limiting
                    $delay = $BaseDelaySeconds * [Math]::Pow(2, $attempt - 1)
                    Write-Verbose "Rate limited. Waiting $delay seconds before retry $attempt of $MaxRetries"
                    Start-Sleep -Seconds $delay
                }
                elseif ($errorMessage -match '503|ServiceUnavailable') {
                    # Linear backoff for service unavailable
                    $delay = $BaseDelaySeconds * $attempt
                    Write-Verbose "Service unavailable. Waiting $delay seconds before retry $attempt of $MaxRetries"
                    Start-Sleep -Seconds $delay
                }
                else {
                    # For other errors, throw immediately unless it's a network/transient error
                    if ($errorMessage -match 'timeout|network|connection|temporarily') {
                        $delay = $BaseDelaySeconds * $attempt
                        Write-Verbose "Transient error detected. Waiting $delay seconds before retry $attempt of $MaxRetries"
                        Start-Sleep -Seconds $delay
                    }
                    else {
                        throw
                    }
                }
            }
            else {
                throw
            }
        }
    } while ($attempt -lt $MaxRetries)
    
    # Restore warning preference before throwing
    $WarningPreference = $originalWarningPreference
    throw $lastError
}


