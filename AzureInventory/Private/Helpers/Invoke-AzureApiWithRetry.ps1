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
        
        [int]$MaxRetries = (Get-RetryConfig).MAX_RETRIES,
        
        [int]$BaseDelaySeconds = (Get-RetryConfig).BASE_DELAY_SECONDS
    )
    
    $attempt = 0
    $lastError = $null
    
    do {
        $attempt++
        try {
            # Suppress warnings from Azure PowerShell modules using helper function
            $result = Invoke-WithSuppressedWarnings -SuppressPSDefaultParams -ScriptBlock $ScriptBlock
            return $result
        }
        catch {
            $lastError = $_
            $errorMessage = $_.Exception.Message
            
            if ($attempt -lt $MaxRetries) {
                $transientPatterns = Get-TransientErrorPatterns
                $isTransient = $false
                $isRateLimit = $false
                
                foreach ($pattern in $transientPatterns) {
                    if ($errorMessage -match $pattern) {
                        $isTransient = $true
                        if ($pattern -match '429|throttl|TooManyRequests') {
                            $isRateLimit = $true
                        }
                        break
                    }
                }
                
                if ($isTransient) {
                    if ($isRateLimit) {
                        # Exponential backoff for rate limiting
                        $delay = $BaseDelaySeconds * [Math]::Pow(2, $attempt - 1)
                        Write-Verbose "Rate limited. Waiting $delay seconds before retry $attempt of $MaxRetries"
                    } else {
                        # Linear backoff for service unavailable or network errors
                        $delay = $BaseDelaySeconds * $attempt
                        Write-Verbose "Transient error detected. Waiting $delay seconds before retry $attempt of $MaxRetries"
                    }
                    Start-Sleep -Seconds $delay
                } else {
                    throw
                }
            }
            else {
                throw
            }
        }
    } while ($attempt -lt $MaxRetries)
    
    throw $lastError
}


