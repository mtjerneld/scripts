<#
.SYNOPSIS
    Collects Azure Change Analysis data for all subscriptions.

.DESCRIPTION
    Uses Resource Graph Change Analysis to collect actual configuration changes
    across all subscriptions in a single cross-subscription query. Optionally
    includes curated Activity Log security events.

.PARAMETER Subscriptions
    Array of subscription objects to collect change tracking data from.

.PARAMETER ChangeTrackingData
    List to append change tracking data to.

.PARAMETER Errors
    List to append errors to.

.OUTPUTS
    Updated collections (ChangeTrackingData, Errors).
#>
# Note: "Collect" is intentionally used (not an approved verb) to distinguish aggregation functions
# from single-source retrieval functions (which use "Get-"). This is a known PSScriptAnalyzer warning.
# Suppressing PSScriptAnalyzer warning about unapproved verb
function Collect-ChangeTrackingData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Subscriptions,
        
        [Parameter(Mandatory = $false)]
        [System.Collections.Generic.List[PSObject]]$ChangeTrackingData,
        
        [Parameter(Mandatory = $false)]
        [System.Collections.Generic.List[string]]$Errors
    )
    
    # Initialize collections if not provided (but don't create new ones if they're already passed in, even if empty)
    # Use $null check instead of truthy check to preserve the reference to the original list
    if ($null -eq $ChangeTrackingData) {
        $ChangeTrackingData = [System.Collections.Generic.List[PSObject]]::new()
    }
    if ($null -eq $Errors) {
        $Errors = [System.Collections.Generic.List[string]]::new()
    }
    
    
    # Check if function exists, if not try to load it directly
    if (-not (Get-Command -Name Get-AzureChangeAnalysis -ErrorAction SilentlyContinue)) {
        Write-Verbose "Get-AzureChangeAnalysis function not found, attempting to load directly..."
        
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
        
        $collectorPath = Join-Path $moduleRoot "Private\Collectors\Get-AzureChangeAnalysis.ps1"
        
        Write-Verbose "Module root: $moduleRoot"
        Write-Verbose "Looking for function at: $collectorPath"
        
        if (Test-Path $collectorPath) {
            Write-Verbose "File found! Loading function..."
            try {
                . $collectorPath
                
                # Verify it loaded
                if (Get-Command -Name Get-AzureChangeAnalysis -ErrorAction SilentlyContinue) {
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
        Write-Verbose "Get-AzureChangeAnalysis function found"
    }
    
    # Check again after potential load
    if (-not (Get-Command -Name Get-AzureChangeAnalysis -ErrorAction SilentlyContinue)) {
        Write-Warning "Get-AzureChangeAnalysis function still not available! Make sure the module is properly loaded."
        return
    }
    
    # Check if Az.ResourceGraph module is available
    if (-not (Get-Module -ListAvailable -Name Az.ResourceGraph)) {
        Write-Warning "Az.ResourceGraph module is not installed! Install with: Install-Module -Name Az.ResourceGraph"
    } else {
        Write-Verbose "Az.ResourceGraph module is available"
    }
    
    # Check if Az.Monitor module is available (for security events)
    if (-not (Get-Module -ListAvailable -Name Az.Monitor)) {
        Write-Warning "Az.Monitor module is not installed! Security events will be skipped. Install with: Install-Module -Name Az.Monitor"
    } else {
        Write-Verbose "Az.Monitor module is available"
    }
    
    try {
        # Extract subscription IDs for cross-subscription query
        $subscriptionIds = @($Subscriptions | ForEach-Object { $_.Id })
        
        if ($subscriptionIds.Count -eq 0) {
            Write-Warning "No subscriptions provided for change tracking"
            return
        }
        
        # Call Get-AzureChangeAnalysis with all subscription IDs at once (cross-subscription query)
        # Include security events by default
        $changeData = Get-AzureChangeAnalysis -SubscriptionIds $subscriptionIds -Days 14 -IncludeSecurityEvents
        
        Write-Verbose "Function returned: Type=$($changeData.GetType().FullName), Count=$($changeData.Count)"
        
        # Ensure changeData is an array
        if ($null -eq $changeData) {
            $changeData = @()
        } else {
            $changeData = @($changeData)
        }
        
        if ($changeData.Count -gt 0) {
            $addedCount = 0
            foreach ($change in $changeData) {
                if ($null -ne $change) {
                    $ChangeTrackingData.Add($change)
                    $addedCount++
                } else {
                    Write-Verbose "Skipping null change object"
                }
            }
            Write-Verbose "Total changes in collection after adding: $($ChangeTrackingData.Count)"
        } else {
            Write-Verbose "No changes found (this may be normal if no changes occurred)"
        }
    }
    catch {
        Write-Warning "Failed to get change tracking data: $_"
        Write-Verbose "Error type: $($_.Exception.GetType().FullName)"
        Write-Verbose "Error message: $($_.Exception.Message)"
        if ($_.ScriptStackTrace) {
            Write-Verbose "Stack trace: $($_.ScriptStackTrace)"
        }
        $Errors.Add("Failed to get change tracking data: $_")
    }
    
    Write-Host "    $($ChangeTrackingData.Count) changes collected" -ForegroundColor $(if ($ChangeTrackingData.Count -gt 0) { 'Green' } else { 'Gray' })
}

