<#
.SYNOPSIS
    Collects Azure Advisor recommendations for all subscriptions.

.DESCRIPTION
    Iterates through subscriptions and collects Advisor recommendations using
    the Get-AzureAdvisorRecommendations function.

.PARAMETER Subscriptions
    Array of subscription objects to collect recommendations from.

.PARAMETER AdvisorRecommendations
    List to append recommendations to.

.PARAMETER Errors
    List to append errors to.

.OUTPUTS
    Updated collections (AdvisorRecommendations, Errors).
#>
# Note: "Collect" is intentionally used (not an approved verb) to distinguish aggregation functions
# from single-source retrieval functions (which use "Get-"). This is a known PSScriptAnalyzer warning.
# Suppressing PSScriptAnalyzer warning about unapproved verb
function Collect-AdvisorRecommendations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Subscriptions,
        
        [Parameter(Mandatory = $false)]
        [System.Collections.Generic.List[PSObject]]$AdvisorRecommendations,
        
        [Parameter(Mandatory = $false)]
        [System.Collections.Generic.List[string]]$Errors
    )
    
    # Initialize collections if not provided (but don't create new ones if they're already passed in, even if empty)
    # Use $null check instead of truthy check to preserve the reference to the original list
    if ($null -eq $AdvisorRecommendations) {
        $AdvisorRecommendations = [System.Collections.Generic.List[PSObject]]::new()
    }
    if ($null -eq $Errors) {
        $Errors = [System.Collections.Generic.List[string]]::new()
    }
    
    
    # Check if function exists, if not try to load it directly
    if (-not (Get-Command -Name Get-AzureAdvisorRecommendations -ErrorAction SilentlyContinue)) {
        Write-Verbose "Get-AzureAdvisorRecommendations function not found, attempting to load directly..."
        
        # Try to load the function directly from file
        # Try to find module root by looking for AzureSecurityAudit.psm1
        $moduleRoot = $null
        $currentPath = $PSScriptRoot
        while ($currentPath -and -not $moduleRoot) {
            if (Test-Path (Join-Path $currentPath "AzureSecurityAudit.psm1")) {
                $moduleRoot = $currentPath
                break
            }
            $parentPath = Split-Path -Parent $currentPath
            if ($parentPath -eq $currentPath) { break }
            $currentPath = $parentPath
        }
        
        if (-not $moduleRoot) {
            # Fallback: assume we're in Private/Helpers
            $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        }
        
        $collectorPath = Join-Path $moduleRoot "Private\Collectors\Get-AzureAdvisorRecommendations.ps1"
        
        Write-Verbose "Module root: $moduleRoot"
        Write-Verbose "Looking for function at: $collectorPath"
        
        if (Test-Path $collectorPath) {
            Write-Verbose "File found! Loading function..."
            try {
                . $collectorPath
                
                # Verify it loaded
                if (Get-Command -Name Get-AzureAdvisorRecommendations -ErrorAction SilentlyContinue) {
                    Write-Verbose "Function loaded and verified successfully"
                } else {
                    Write-Warning "Function file loaded but function not found in session"
                }
            }
            catch {
                Write-Warning "Failed to load function: $_"
                Write-Verbose "Error details: $($_.Exception.Message)"
            }
        } else {
            Write-Warning "Function file not found at: $collectorPath"
            Write-Verbose "Checking if Collectors directory exists..."
            $collectorsDir = Join-Path $moduleRoot "Private\Collectors"
            if (Test-Path $collectorsDir) {
                Write-Verbose "Collectors directory exists. Files:"
                Get-ChildItem -Path $collectorsDir -ErrorAction SilentlyContinue | ForEach-Object {
                    Write-Verbose "  - $($_.Name)"
                }
            } else {
                Write-Warning "Collectors directory does not exist: $collectorsDir"
            }
        }
    } else {
        Write-Verbose "Get-AzureAdvisorRecommendations function found"
    }
    
    # Check again after potential load
    if (-not (Get-Command -Name Get-AzureAdvisorRecommendations -ErrorAction SilentlyContinue)) {
        Write-Warning "Get-AzureAdvisorRecommendations function still not available! Make sure the module is properly loaded."
        return
    }
    
    # Check if Az.Advisor module is available
    if (-not (Get-Module -ListAvailable -Name Az.Advisor)) {
        Write-Warning "Az.Advisor module is not installed! Install with: Install-Module -Name Az.Advisor"
    } else {
        Write-Verbose "Az.Advisor module is available"
    }
    
    # Get tenant ID for context switching
    $currentContext = Get-AzContext
    $tenantId = if ($currentContext -and $currentContext.Tenant) { $currentContext.Tenant.Id } else { $null }
    
    foreach ($sub in $Subscriptions) {
        $subscriptionNameToUse = Get-SubscriptionDisplayName -Subscription $sub
        
        try {
            Write-Verbose "Setting subscription context for $subscriptionNameToUse..."
            Invoke-WithSuppressedWarnings {
                if ($tenantId) {
                    Set-AzContext -SubscriptionId $sub.Id -TenantId $tenantId -ErrorAction Stop | Out-Null
                } else {
                    Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
                }
            }
            Write-Verbose "Context set successfully"
            
            # Run function
            Write-Verbose "Calling Get-AzureAdvisorRecommendations for $subscriptionNameToUse..."
            $advisorRecs = Get-AzureAdvisorRecommendations -SubscriptionId $sub.Id -SubscriptionName $subscriptionNameToUse
            
            Write-Verbose "Function returned: $($advisorRecs.Count) recommendations"
            
            if ($advisorRecs -and $advisorRecs.Count -gt 0) {
                foreach ($rec in $advisorRecs) {
                    if ($null -ne $rec) {
                        $AdvisorRecommendations.Add($rec)
                    }
                }
                Write-Verbose "Total recommendations in collection after adding: $($AdvisorRecommendations.Count)"
            } else {
                Write-Verbose "No recommendations found (this may be normal if Advisor has no recommendations)"
            }
        }
        catch {
            Write-Warning "Failed to get Advisor recommendations for $subscriptionNameToUse : $_"
            Write-Verbose "Error type: $($_.Exception.GetType().FullName)"
            Write-Verbose "Error message: $($_.Exception.Message)"
            if ($_.ScriptStackTrace) {
                Write-Verbose "Stack trace: $($_.ScriptStackTrace)"
            }
            $Errors.Add("Failed to get Advisor recommendations for $subscriptionNameToUse : $_")
        }
    }
    
    Write-Host "    $($AdvisorRecommendations.Count) recommendations" -ForegroundColor $(if ($AdvisorRecommendations.Count -gt 0) { 'Green' } else { 'Gray' })
}

