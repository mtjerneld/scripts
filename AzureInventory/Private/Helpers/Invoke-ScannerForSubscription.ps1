<#
.SYNOPSIS
    Executes all scanners for a single subscription.

.DESCRIPTION
    Sets subscription context and runs all specified category scanners, collecting findings
    and VM inventory data.

.PARAMETER Subscription
    Subscription object to scan.

.PARAMETER CategoriesToScan
    Array of category names to scan.

.PARAMETER Scanners
    Hashtable mapping category names to scanner script blocks.

.PARAMETER IncludeLevel2
    Whether to include Level 2 CIS controls.

.PARAMETER AllFindings
    List to append findings to.

.PARAMETER VMInventory
    List to append VM inventory data to.

.PARAMETER Errors
    List to append errors to.

.OUTPUTS
    Updated collections (AllFindings, VMInventory, Errors).
#>
# PSScriptAnalyzer may report false positives for try-catch structure due to complex nesting
# PowerShell parser confirms syntax is valid
# Note: IDE linter may report false positive "missing closing brace" errors - these are parser false positives
# The PowerShell parser confirms all braces are properly matched and syntax is valid
function Invoke-ScannerForSubscription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Subscription,
        
        [Parameter(Mandatory = $true)]
        [string[]]$CategoriesToScan,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Scanners,
        
        [switch]$IncludeLevel2,
        
        [switch]$SuppressOutput,
        
        [Parameter(Mandatory = $false)]
        [System.Collections.Generic.List[PSObject]]$AllFindings,
        
        [Parameter(Mandatory = $false)]
        [System.Collections.Generic.List[PSObject]]$AllEOLFindings,
        
        [Parameter(Mandatory = $false)]
        [System.Collections.Generic.List[PSObject]]$VMInventory,
        
        [Parameter(Mandatory = $false)]
        [System.Collections.Generic.List[string]]$Errors
    )
    
    # Initialize collections if not provided (but don't create new ones if they're already passed in, even if empty)
    # Use $null check instead of truthy check to preserve the reference to the original list
    if ($null -eq $AllFindings) {
        $AllFindings = [System.Collections.Generic.List[PSObject]]::new()
    }
    if ($null -eq $AllEOLFindings) {
        $AllEOLFindings = [System.Collections.Generic.List[PSObject]]::new()
    }
    if ($null -eq $VMInventory) {
        $VMInventory = [System.Collections.Generic.List[PSObject]]::new()
    }
    if ($null -eq $Errors) {
        $Errors = [System.Collections.Generic.List[string]]::new()
    }
    
    $subDisplayName = Get-SubscriptionDisplayName -Subscription $Subscription
    
    # Set subscription context
    $subscriptionNameToUse = $null
    $contextSet = Invoke-WithSuppressedWarnings {
        Get-SubscriptionContext -SubscriptionId $Subscription.Id -ErrorAction SilentlyContinue
    }
    
    try {
        if (-not $contextSet) {
            Write-Warning "Failed to set context for subscription $subDisplayName ($($Subscription.Id)) - skipping"
            $Errors.Add("Failed to set context for subscription $subDisplayName ($($Subscription.Id))")
            return
        }
        
        # Verify context was set correctly and get subscription name from context
        $verifyContext = Get-AzContext
        if ($verifyContext.Subscription.Id -ne $Subscription.Id) {
            Write-Warning "Context verification failed: Expected $($Subscription.Id), got $($verifyContext.Subscription.Id) - skipping"
            $Errors.Add("Context verification failed for subscription $subDisplayName ($($Subscription.Id))")
            return
        }
        
        # Use subscription name from verified context (more reliable than $Subscription.Name)
        $subscriptionNameToUse = Get-SubscriptionDisplayName -Subscription $verifyContext.Subscription
        if ([string]::IsNullOrWhiteSpace($subscriptionNameToUse) -or $subscriptionNameToUse -eq "Unknown Subscription") {
            $subscriptionNameToUse = Get-SubscriptionDisplayName -Subscription $Subscription
        }
        
        Write-Verbose "Context verified: $subscriptionNameToUse ($($verifyContext.Subscription.Id))"
        
        # Verify we can actually read resources in this subscription
        try {
            $testResource = Get-AzResource -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $testResource) {
                Write-Verbose "No resources found or unable to read resources in subscription $subscriptionNameToUse"
            }
        }
        catch {
            Write-Verbose "Warning: May have limited permissions in subscription ${subscriptionNameToUse}: $_"
        }
    }
    catch {
        Write-Warning "Failed to set context for subscription $subDisplayName ($($Subscription.Id)): $_ - skipping"
        $Errors.Add("Failed to set context for subscription $subDisplayName ($($Subscription.Id)): $_")
        return
    }
    
    # Run scanners for each category
    foreach ($category in $CategoriesToScan) {
        if (-not $Scanners.ContainsKey($category)) {
            Write-Warning "Unknown category: $category"
            continue
        }
        
        # Always show category name, even when SuppressOutput is true
        Write-Host "  - $category..." -NoNewline
        # PSScriptAnalyzer false positive: try-catch structure is valid (verified by PowerShell parser)
        try {
            # Suppress Azure module warnings about unapproved verbs during scanning
            $scanResult = Invoke-WithSuppressedWarnings -SuppressPSDefaultParams {
                & $Scanners[$category] -subId $Subscription.Id -subName $subscriptionNameToUse -includeL2:$IncludeLevel2
            }
            
            # Handle scanners that return structured results (Findings + EOLFindings or Findings + Inventory)
            $findings = $null
            $eolFindings = $null
            $resourceCount = 0
            $controlCount = 0
            $failureCount = 0
            $eolCount = 0
            
            if ($scanResult -is [hashtable]) {
                # Scanners return hashtable with Findings and EOLFindings (Storage, Network, AppService, SQL, KeyVault, Monitor, ARC)
                if ($scanResult.ContainsKey('Findings')) {
                    $findings = $scanResult['Findings']
                }
                if ($scanResult.ContainsKey('EOLFindings')) {
                    $eolFindings = $scanResult['EOLFindings']
                }
                # Extract metadata if available
                if ($scanResult.ContainsKey('ResourceCount')) {
                    $resourceCount = $scanResult['ResourceCount']
                }
                if ($scanResult.ContainsKey('ControlCount')) {
                    $controlCount = $scanResult['ControlCount']
                }
                if ($scanResult.ContainsKey('FailureCount')) {
                    $failureCount = $scanResult['FailureCount']
                }
                if ($scanResult.ContainsKey('EOLCount')) {
                    $eolCount = $scanResult['EOLCount']
                }
                Write-Verbose "Scanner $category returned hashtable: Findings=$($findings.Count), EOLFindings=$($eolFindings.Count), Resources=$resourceCount, Controls=$controlCount, Failures=$failureCount, EOL=$eolCount"
            }
            elseif ($category -eq 'VM' -and $scanResult -is [PSCustomObject] -and $scanResult.PSObject.Properties.Name -contains 'Findings') {
                $findings = $scanResult.Findings
                # Add VM inventory data
                if ($scanResult.Inventory -and $scanResult.Inventory.Count -gt 0) {
                    foreach ($vmData in $scanResult.Inventory) {
                        $VMInventory.Add($vmData)
                    }
                }
                # VM scanner also returns EOLFindings
                if ($scanResult.PSObject.Properties.Name -contains 'EOLFindings') {
                    $eolFindings = $scanResult.EOLFindings
                }
                # Extract metadata if available
                if ($scanResult.PSObject.Properties.Name -contains 'ResourceCount') {
                    $resourceCount = $scanResult.ResourceCount
                }
                if ($scanResult.PSObject.Properties.Name -contains 'ControlCount') {
                    $controlCount = $scanResult.ControlCount
                }
                if ($scanResult.PSObject.Properties.Name -contains 'FailureCount') {
                    $failureCount = $scanResult.FailureCount
                }
                if ($scanResult.PSObject.Properties.Name -contains 'EOLCount') {
                    $eolCount = $scanResult.EOLCount
                }
                Write-Verbose "Scanner $category returned PSCustomObject: Findings=$($findings.Count), EOLFindings=$($eolFindings.Count), Resources=$resourceCount, Controls=$controlCount, Failures=$failureCount, EOL=$eolCount"
            } else {
                $findings = $scanResult
                Write-Verbose "Scanner $category returned simple array: Findings=$($findings.Count)"
            }
            
            # Handle null or empty results
            if ($null -eq $findings) {
                $findings = @()
            }
            
            # Add findings to collection - @() ensures array even for single objects
            $findingsAdded = 0
            foreach ($finding in @($findings)) {
                if ($null -ne $finding) {
                    $AllFindings.Add($finding)
                    $findingsAdded++
                }
            }
            
            Write-Verbose "Added $findingsAdded findings from $category scan. Total findings in collection: $($AllFindings.Count)"
            
            # Handle EOL findings if present
            if ($null -ne $eolFindings) {
                $eolFindingsAdded = 0
                foreach ($eolFinding in @($eolFindings)) {
                    if ($null -ne $eolFinding) {
                        $AllEOLFindings.Add($eolFinding)
                        $eolFindingsAdded++
                    }
                }
                Write-Verbose "Added $eolFindingsAdded EOL findings from $category scan. Total EOL findings in collection: $($AllEOLFindings.Count)"
            }
            
            # Calculate unique resources and unique checks from findings
            # This ensures we show unique checks, not multiplied checks (resources * checks)
            $validFindings = @($findings | Where-Object { $null -ne $_ })
            
            # Count unique resources and unique controls using hashtables
            $uniqueResourceIds = @{}
            $uniqueControls = @{}
            $failCount = 0
            
            foreach ($finding in $validFindings) {
                # Count unique resources by ResourceId or ResourceName+ResourceGroup
                $resourceKey = $null
                if ($finding.PSObject.Properties.Name -contains 'ResourceId' -and -not [string]::IsNullOrWhiteSpace($finding.ResourceId)) {
                    $resourceKey = $finding.ResourceId
                }
                elseif ($finding.PSObject.Properties.Name -contains 'ResourceName' -and -not [string]::IsNullOrWhiteSpace($finding.ResourceName)) {
                    $rg = if ($finding.PSObject.Properties.Name -contains 'ResourceGroup') { $finding.ResourceGroup } else { "" }
                    $resourceKey = "$($finding.ResourceName)|$rg"
                }
                
                if ($resourceKey -and -not $uniqueResourceIds.ContainsKey($resourceKey)) {
                    $uniqueResourceIds[$resourceKey] = $true
                }
                
                # Count unique controls by Category + ControlId
                $controlKey = $null
                if ($finding.PSObject.Properties.Name -contains 'Category' -and $finding.PSObject.Properties.Name -contains 'ControlId') {
                    $cat = if ($finding.Category) { $finding.Category } else { "Unknown" }
                    $ctrlId = if ($finding.ControlId) { $finding.ControlId } else { "Unknown" }
                    $controlKey = "$cat|$ctrlId"
                }
                
                if ($controlKey -and -not $uniqueControls.ContainsKey($controlKey)) {
                    $uniqueControls[$controlKey] = $true
                }
                
                # Count failures
                if ($finding.PSObject.Properties.Name -contains 'Status' -and $finding.Status -eq 'FAIL') {
                    $failCount++
                }
            }
            
            $uniqueResourcesFromFindings = $uniqueResourceIds.Count
            $uniqueChecksFromFindings = $uniqueControls.Count
            
            # Use resourceCount from metadata if available (more accurate when all checks pass and no findings)
            # But validate: if metadata says 0 resources but > 0 checks, that's invalid - ignore the checks
            $finalResourceCount = if ($resourceCount -gt 0) { $resourceCount } else { $uniqueResourcesFromFindings }
            
            # Always use unique checks calculated from findings to avoid multiplication issue
            # If no findings but metadata has resourceCount > 0, we can't know unique checks - use controlCount as fallback
            # but only if it seems reasonable (not multiplied)
            if ($uniqueChecksFromFindings -gt 0) {
                $finalCheckCount = $uniqueChecksFromFindings
            }
            elseif ($finalResourceCount -gt 0 -and $controlCount -gt 0) {
                # No findings but resources exist - check if controlCount seems multiplied
                # If controlCount is much larger than a reasonable number of unique checks, it's likely multiplied
                # Use it anyway but it might be inaccurate
                $finalCheckCount = $controlCount
            }
            else {
                $finalCheckCount = 0
            }
            
            # Validate: if resources = 0, checks must also be 0 (can't check 0 resources)
            if ($finalResourceCount -eq 0 -and $finalCheckCount -gt 0) {
                $finalCheckCount = 0
            }
            
            # Use failureCount from metadata if available and findings-based count is 0
            # Otherwise use the calculated failCount from findings
            $finalFailureCount = if ($failureCount -gt 0 -and $failCount -eq 0) { $failureCount } else { $failCount }
            
            # Format output message
            $color = if ($finalFailureCount -gt 0) { 'Red' } else { 'Green' }
            if ($finalResourceCount -eq 0 -and $finalCheckCount -eq 0) {
                Write-Host " 0 resources (0 checks)" -ForegroundColor Gray
            }
            else {
                $resourceWord = if ($finalResourceCount -eq 1) { "resource" } else { "resources" }
                $checkWord = if ($finalCheckCount -eq 1) { "check" } else { "checks" }
                $failureWord = if ($finalFailureCount -eq 1) { "failure" } else { "failures" }
                
                # Build output message with proper string formatting
                $outputMsg = " $finalResourceCount $resourceWord evaluated against $finalCheckCount $checkWord ($finalFailureCount $failureWord"
                if ($eolCount -gt 0) {
                    $eolWord = if ($eolCount -eq 1) { "EOL" } else { "EOL" }
                    $outputMsg = "$outputMsg, $eolCount $eolWord"
                }
                $outputMsg = "$outputMsg)"
                
                Write-Host $outputMsg -ForegroundColor $color
            }
        }
        catch {
            Write-Host " ERROR: $_" -ForegroundColor Red
            $Errors.Add("$category scan failed for ${subscriptionNameToUse}: $_")
            
            # Check if it's a permissions error
            $permissionPatterns = Get-PermissionErrorPatterns
            $isPermissionError = $false
            foreach ($pattern in $permissionPatterns) {
                if ($_.Exception.Message -match $pattern) {
                    $isPermissionError = $true
                    break
                }
            }
            if ($isPermissionError) {
                Write-Host "    [WARNING] This may be a permissions issue. Ensure you have Reader role on subscription ${subscriptionNameToUse}" -ForegroundColor Yellow
            }
        }
    }
}

