<#
.SYNOPSIS
    Collects Azure Activity Log change tracking data for all subscriptions.

.DESCRIPTION
    Iterates through subscriptions and collects change tracking data using
    the Get-AzureChangeTracking function.

.PARAMETER Subscriptions
    Array of subscription objects to collect change tracking data from.

.PARAMETER ChangeTrackingData
    List to append change tracking data to.

.PARAMETER Errors
    List to append errors to.

.OUTPUTS
    Updated collections (ChangeTrackingData, Errors).
#>
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
    
    Write-Host "`n=== Collecting Azure Change Tracking Data ===" -ForegroundColor Cyan
    
    # Check if function exists, if not try to load it directly
    if (-not (Get-Command -Name Get-AzureChangeTracking -ErrorAction SilentlyContinue)) {
        Write-Verbose "Get-AzureChangeTracking function not found, attempting to load directly..."
        
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
        
        $collectorPath = Join-Path $moduleRoot "Private\Collectors\Get-AzureChangeTracking.ps1"
        
        Write-Verbose "Module root: $moduleRoot"
        Write-Verbose "Looking for function at: $collectorPath"
        
        if (Test-Path $collectorPath) {
            Write-Verbose "File found! Loading function..."
            try {
                . $collectorPath
                
                # Verify it loaded
                if (Get-Command -Name Get-AzureChangeTracking -ErrorAction SilentlyContinue) {
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
        Write-Verbose "Get-AzureChangeTracking function found"
    }
    
    # Check again after potential load
    if (-not (Get-Command -Name Get-AzureChangeTracking -ErrorAction SilentlyContinue)) {
        Write-Warning "Get-AzureChangeTracking function still not available! Make sure the module is properly loaded."
        return
    }
    
    # Check if Az.Monitor module is available
    if (-not (Get-Module -ListAvailable -Name Az.Monitor)) {
        Write-Warning "Az.Monitor module is not installed! Install with: Install-Module -Name Az.Monitor"
    } else {
        Write-Verbose "Az.Monitor module is available"
    }
    
    # Get tenant ID for context switching
    $currentContext = Get-AzContext
    $tenantId = if ($currentContext -and $currentContext.Tenant) { $currentContext.Tenant.Id } else { $null }
    
    foreach ($sub in $Subscriptions) {
        $subscriptionNameToUse = Get-SubscriptionDisplayName -Subscription $sub
        Write-Host "`n  Collecting from: $subscriptionNameToUse..." -ForegroundColor Gray
        
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
            Write-Verbose "Calling Get-AzureChangeTracking for $subscriptionNameToUse..."
            $changeData = Get-AzureChangeTracking -SubscriptionId $sub.Id -SubscriptionName $subscriptionNameToUse
            
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
                Write-Host "    Added $addedCount changes" -ForegroundColor Green
                Write-Verbose "Total changes in collection after adding: $($ChangeTrackingData.Count)"
            } else {
                Write-Verbose "No changes found (this may be normal if no changes occurred)"
            }
        }
        catch {
            Write-Warning "Failed to get change tracking data for $subscriptionNameToUse : $_"
            Write-Verbose "Error type: $($_.Exception.GetType().FullName)"
            Write-Verbose "Error message: $($_.Exception.Message)"
            if ($_.ScriptStackTrace) {
                Write-Verbose "Stack trace: $($_.ScriptStackTrace)"
            }
            $Errors.Add("Failed to get change tracking data for $subscriptionNameToUse : $_")
        }
    }
    
    Write-Host "`n  Total changes collected: $($ChangeTrackingData.Count)" -ForegroundColor $(if ($ChangeTrackingData.Count -gt 0) { 'Green' } else { 'Yellow' })
}

