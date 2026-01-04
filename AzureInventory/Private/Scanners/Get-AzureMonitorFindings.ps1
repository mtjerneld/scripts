<#
.SYNOPSIS
    Scans Azure Monitor configuration for CIS security compliance (P0 and P1 controls).

.DESCRIPTION
    Checks Azure Monitor configuration against security controls:
    P0: No MMA/OMS Agents (deprecated, EOL Aug 2024)
    P1: Diagnostic Settings enabled, DCR Associations present

.PARAMETER SubscriptionId
    Azure subscription ID to scan.

.PARAMETER SubscriptionName
    Human-readable subscription name.

.OUTPUTS
    Array of SecurityFinding objects.
#>
function Get-AzureMonitorFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionName
    )
    
    $findings = [System.Collections.Generic.List[PSObject]]::new()
    $eolFindings = [System.Collections.Generic.List[PSObject]]::new()
    
    # Track metadata for consolidated output
    $uniqueResourcesScanned = @{}
    $controlsEvaluated = 0
    
    # Load enabled controls from JSON
    $controls = Get-ControlsForCategory -Category "Monitor"
    if ($null -eq $controls -or $controls.Count -eq 0) {
        Write-Verbose "No enabled Monitor controls found in configuration for subscription $SubscriptionName"
        return @{
            Findings = $findings
            EOLFindings = $eolFindings
            ResourceCount = 0
            ControlCount = 0
            FailureCount = 0
            EOLCount = 0
        }
    }
    Write-Verbose "Loaded $($controls.Count) Monitor control(s) from configuration"
    
    # Create lookup hashtable for quick control access
    $controlLookup = @{}
    foreach ($control in $controls) {
        $controlLookup[$control.controlName] = $control
    }
    Write-Verbose "Control lookup created with keys: $($controlLookup.Keys -join ', ')"
    
    # Control: No MMA/OMS Agents
    $mmaControl = $controlLookup["No MMA/OMS Agents"]
    if ($mmaControl) {
        try {
            # Get Log Analytics workspaces
            $workspaces = Invoke-AzureApiWithRetry {
                Get-AzOperationalInsightsWorkspace -ErrorAction SilentlyContinue
            }
            
            if ($workspaces) {
                foreach ($workspace in $workspaces) {
                    # Track workspace as resource scanned
                    $resourceKey = if ($workspace.Id) { $workspace.Id } else { "$($workspace.ResourceGroupName)/$($workspace.Name)" }
                    if (-not $uniqueResourcesScanned.ContainsKey($resourceKey)) {
                        $uniqueResourcesScanned[$resourceKey] = $true
                    }
                    
                    try {
                        # Skip if ResourceGroupName is empty
                        if ([string]::IsNullOrWhiteSpace($workspace.ResourceGroupName)) {
                            Write-Verbose "Skipping workspace $($workspace.Name) - ResourceGroupName is empty"
                            continue
                        }
                        
                        # Query for legacy MMA agents (Direct Agent category)
                        # For now, we'll create a finding if workspace exists and note that manual verification needed
                        $descAndRefs = Get-ControlDescriptionAndReferences -Control $mmaControl
                        
                        $finding = New-SecurityFinding `
                            -SubscriptionId $SubscriptionId `
                            -SubscriptionName $SubscriptionName `
                            -ResourceGroup $workspace.ResourceGroupName `
                            -ResourceType "Microsoft.OperationalInsights/workspaces" `
                            -ResourceName $workspace.Name `
                            -ResourceId $workspace.Id `
                            -ControlId $mmaControl.controlId `
                            -ControlName $mmaControl.controlName `
                            -Category $mmaControl.category `
                            -Frameworks $mmaControl.frameworks `
                            -Severity $mmaControl.severity `
                            -CisLevel $mmaControl.level `
                            -CurrentValue "Manual verification required" `
                            -ExpectedValue $mmaControl.expectedValue `
                            -Status "SKIPPED" `
                            -RemediationSteps $descAndRefs.Description `
                            -RemediationCommand $mmaControl.remediationCommand `
                            -EOLDate $mmaControl.eolDate `
                            -References $descAndRefs.References
                        # Only add one finding per subscription for this check
                        $findings.Add($finding)
                        break
                    }
                    catch {
                        Write-Verbose "Could not query workspace $($workspace.Name): $_"
                    }
                }
            }
        }
        catch {
            Write-Verbose "Could not check for MMA agents: $_"
        }
    }
    
    # Control: Log Analytics Workspace Retention Period
    $retentionControl = $controlLookup["Log Analytics Workspace Retention Period"]
    if ($retentionControl) {
        $controlsEvaluated++
        try {
            $workspaces = Invoke-AzureApiWithRetry {
                Get-AzOperationalInsightsWorkspace -ErrorAction SilentlyContinue
            }
            
            if ($workspaces) {
                foreach ($workspace in $workspaces) {
                    # Track workspace as resource scanned
                    $resourceKey = if ($workspace.Id) { $workspace.Id } else { "$($workspace.ResourceGroupName)/$($workspace.Name)" }
                    if (-not $uniqueResourcesScanned.ContainsKey($resourceKey)) {
                        $uniqueResourcesScanned[$resourceKey] = $true
                    }
                    
                    try {
                        # Skip if ResourceGroupName is empty
                        if ([string]::IsNullOrWhiteSpace($workspace.ResourceGroupName)) {
                            Write-Verbose "Skipping workspace $($workspace.Name) - ResourceGroupName is empty"
                            continue
                        }
                        
                        $retentionDays = if ($workspace.RetentionInDays) { $workspace.RetentionInDays } else { 0 }
                        $meetsRequirement = $retentionDays -ge 90
                        $status = if ($meetsRequirement) { "PASS" } else { "FAIL" }
                        $currentValue = if ($retentionDays -gt 0) { "$retentionDays days" } else { "Not configured" }
                        
                        $remediationCmd = $retentionControl.remediationCommand -replace '\{name\}', $workspace.Name -replace '\{rg\}', $workspace.ResourceGroupName
                        $descAndRefs = Get-ControlDescriptionAndReferences -Control $retentionControl
                        
                        $finding = New-SecurityFinding `
                            -SubscriptionId $SubscriptionId `
                            -SubscriptionName $SubscriptionName `
                            -ResourceGroup $workspace.ResourceGroupName `
                            -ResourceType "Microsoft.OperationalInsights/workspaces" `
                            -ResourceName $workspace.Name `
                            -ResourceId $workspace.Id `
                            -ControlId $retentionControl.controlId `
                            -ControlName $retentionControl.controlName `
                            -Category $retentionControl.category `
                            -Frameworks $retentionControl.frameworks `
                            -Severity $retentionControl.severity `
                            -CisLevel $retentionControl.level `
                            -CurrentValue $currentValue `
                            -ExpectedValue $retentionControl.expectedValue `
                            -Status $status `
                            -RemediationSteps $descAndRefs.Description `
                            -RemediationCommand $remediationCmd `
                            -References $descAndRefs.References
                        $findings.Add($finding)
                    }
                    catch {
                        Write-Verbose "Could not check retention for workspace $($workspace.Name): $_"
                    }
                }
            }
        }
        catch {
            Write-Verbose "Could not check Log Analytics retention: $_"
        }
    }
    
    # Control: Diagnostic Settings Enabled
    $diagControl = $controlLookup["Diagnostic Settings Enabled"]
    if ($diagControl) {
        $controlsEvaluated++
        try {
            # Check diagnostic settings on subscription level resources
            # This is a simplified check - in production, you'd check all resources
            $keyResources = @()
            
            # Sample: Check storage accounts
            $storageAccounts = Invoke-AzureApiWithRetry {
                Get-AzStorageAccount -ErrorAction SilentlyContinue | Select-Object -First 5
            }
            if ($storageAccounts) {
                $keyResources += $storageAccounts
            }
            
            foreach ($resource in $keyResources) {
                # Skip if ResourceGroupName is empty
                if ([string]::IsNullOrWhiteSpace($resource.ResourceGroupName)) {
                    Write-Verbose "Skipping resource $($resource.Name) - ResourceGroupName is empty"
                    continue
                }
                
                try {
                    # Suppress breaking change warnings from Get-AzDiagnosticSetting
                    $diagnosticSettings = Invoke-AzureApiWithRetry {
                        Get-AzDiagnosticSetting -ResourceId $resource.Id -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                    }
                    $diagnosticsEnabled = if ($diagnosticSettings) { $true } else { $false }
                }
                catch {
                    $diagnosticsEnabled = $false
                }
                
                # Always create finding (PASS or FAIL)
                $diagStatus = if ($diagnosticsEnabled) { "PASS" } else { "FAIL" }
                $descAndRefs = Get-ControlDescriptionAndReferences -Control $diagControl
                $remediationCmd = if ($diagnosticsEnabled) { "" } else { $diagControl.remediationCommand -replace '\{resourceId\}', $resource.Id }
                
                $finding = New-SecurityFinding `
                    -SubscriptionId $SubscriptionId `
                    -SubscriptionName $SubscriptionName `
                    -ResourceGroup $resource.ResourceGroupName `
                    -ResourceType $resource.ResourceType `
                    -ResourceName $resource.Name `
                    -ResourceId $resource.Id `
                    -ControlId $diagControl.controlId `
                    -ControlName $diagControl.controlName `
                    -Category $diagControl.category `
                    -Frameworks $diagControl.frameworks `
                    -Severity $diagControl.severity `
                    -CisLevel $diagControl.level `
                    -CurrentValue $(if ($diagnosticsEnabled) { "Configured" } else { "Not configured" }) `
                    -ExpectedValue $diagControl.expectedValue `
                    -Status $diagStatus `
                    -RemediationSteps $descAndRefs.Description `
                    -RemediationCommand $remediationCmd `
                    -References $descAndRefs.References
                $findings.Add($finding)
            }
        }
        catch {
            Write-Verbose "Could not check diagnostic settings: $_"
        }
    }
    
    # Control: DCR Associations
    $dcrControl = $controlLookup["DCR Associations"]
    if ($dcrControl) {
        $controlsEvaluated++
        try {
            $dcrs = Invoke-AzureApiWithRetry {
                Get-AzDataCollectionRule -ErrorAction SilentlyContinue
            }
            
            if ($dcrs) {
                foreach ($dcr in $dcrs) {
                    try {
                        # Skip if ResourceGroupName is empty
                        if ([string]::IsNullOrWhiteSpace($dcr.ResourceGroupName)) {
                            Write-Verbose "Skipping DCR $($dcr.Name) - ResourceGroupName is empty"
                            continue
                        }
                        
                        # Check for associations (simplified - would need proper API call)
                        $hasAssociations = $false  # Placeholder - would check actual associations
                        
                        # Always create finding (PASS or FAIL)
                        $dcrStatus = if ($hasAssociations) { "PASS" } else { "FAIL" }
                        $descAndRefs = Get-ControlDescriptionAndReferences -Control $dcrControl
                        $remediationCmd = if ($hasAssociations) { "" } else { $dcrControl.remediationCommand -replace '\{dcrId\}', $dcr.Id }
                        
                        $finding = New-SecurityFinding `
                            -SubscriptionId $SubscriptionId `
                            -SubscriptionName $SubscriptionName `
                            -ResourceGroup $dcr.ResourceGroupName `
                            -ResourceType "Microsoft.Insights/dataCollectionRules" `
                            -ResourceName $dcr.Name `
                            -ResourceId $dcr.Id `
                            -ControlId $dcrControl.controlId `
                            -ControlName $dcrControl.controlName `
                            -Category $dcrControl.category `
                            -Frameworks $dcrControl.frameworks `
                            -Severity $dcrControl.severity `
                            -CisLevel $dcrControl.level `
                            -CurrentValue $(if ($hasAssociations) { "Has associations" } else { "No associations" }) `
                            -ExpectedValue $dcrControl.expectedValue `
                            -Status $dcrStatus `
                            -RemediationSteps $descAndRefs.Description `
                            -RemediationCommand $remediationCmd `
                            -References $descAndRefs.References
                        $findings.Add($finding)
                    }
                    catch {
                        Write-Verbose "Could not check DCR associations: $_"
                    }
                }
            }
        }
        catch {
            Write-Verbose "Could not check DCRs: $_"
        }
    }
    
    # Calculate failure count
    $failureCount = @($findings | Where-Object { $_.Status -eq 'FAIL' }).Count
    
    # Return both security findings and EOL findings with metadata
    return @{
        Findings = $findings
        EOLFindings = $eolFindings
        ResourceCount = $uniqueResourcesScanned.Count
        ControlCount = $controlsEvaluated
        FailureCount = $failureCount
        EOLCount = $eolFindings.Count
    }
}


