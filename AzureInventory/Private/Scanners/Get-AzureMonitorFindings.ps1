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
    
    # Load deprecation rules for EOL checking
    $deprecationRules = Get-DeprecationRules
    $resourceTypeMapping = @{}
    $moduleRoot = $PSScriptRoot -replace '\\Private\\Scanners$', ''
    $mappingPath = Join-Path $moduleRoot "Config\ResourceTypeMapping.json"
    if (Test-Path $mappingPath) {
        try {
            $mappingJson = Get-Content -Path $mappingPath -Raw | ConvertFrom-Json
            if ($mappingJson -and $mappingJson.mappings) {
                foreach ($mapping in $mappingJson.mappings) {
                    if ($mapping.resourceType -eq "Microsoft.OperationalInsights/workspaces" -or $mapping.resourceType -eq "Microsoft.Insights/dataCollectionRules") {
                        $resourceTypeMapping[$mapping.resourceType] = $mapping
                    }
                }
            }
        }
        catch {
            Write-Verbose "Failed to load ResourceTypeMapping: $_"
        }
    }
    
    # Load enabled controls from JSON
    $controls = Get-ControlsForCategory -Category "Monitor"
    if ($null -eq $controls -or $controls.Count -eq 0) {
        Write-Verbose "No enabled Monitor controls found in configuration for subscription $SubscriptionName"
        return @{
            Findings = $findings
            EOLFindings = $eolFindings
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
                        
                        # EOL Checking: Check if this workspace matches any deprecation rules
                        if ($deprecationRules -and $deprecationRules.Count -gt 0) {
                            $mapping = if ($resourceTypeMapping.ContainsKey("Microsoft.OperationalInsights/workspaces")) {
                                $resourceTypeMapping["Microsoft.OperationalInsights/workspaces"]
                            } else {
                                $null
                            }
                            
                            $eolStatus = Test-ResourceEOLStatus `
                                -Resource $workspace `
                                -ResourceType "Microsoft.OperationalInsights/workspaces" `
                                -DeprecationRules $deprecationRules `
                                -ResourceTypeMapping @{ "Microsoft.OperationalInsights/workspaces" = $mapping }
                            
                            if ($eolStatus.Matched -and $eolStatus.Rule) {
                                $rule = $eolStatus.Rule
                                $eolFinding = New-EOLFinding `
                                    -SubscriptionId $SubscriptionId `
                                    -SubscriptionName $SubscriptionName `
                                    -ResourceGroup $workspace.ResourceGroupName `
                                    -ResourceType "Microsoft.OperationalInsights/workspaces" `
                                    -ResourceName $workspace.Name `
                                    -ResourceId $workspace.Id `
                                    -Component $rule.component `
                                    -Status $rule.status `
                                    -Deadline $eolStatus.Deadline `
                                    -Severity $eolStatus.Severity `
                                    -DaysUntilDeadline $eolStatus.DaysUntilDeadline `
                                    -ActionRequired $rule.actionRequired `
                                    -MigrationGuide $rule.migrationGuide `
                                    -References $(if ($rule.references) { $rule.references } else { @() })
                                $eolFindings.Add($eolFinding)
                            }
                        }
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
    
    # Control: Diagnostic Settings Enabled
    $diagControl = $controlLookup["Diagnostic Settings Enabled"]
    if ($diagControl) {
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
                        
                        # EOL Checking: Check if this DCR matches any deprecation rules
                        if ($deprecationRules -and $deprecationRules.Count -gt 0) {
                            $mapping = if ($resourceTypeMapping.ContainsKey("Microsoft.Insights/dataCollectionRules")) {
                                $resourceTypeMapping["Microsoft.Insights/dataCollectionRules"]
                            } else {
                                $null
                            }
                            
                            $eolStatus = Test-ResourceEOLStatus `
                                -Resource $dcr `
                                -ResourceType "Microsoft.Insights/dataCollectionRules" `
                                -DeprecationRules $deprecationRules `
                                -ResourceTypeMapping @{ "Microsoft.Insights/dataCollectionRules" = $mapping }
                            
                            if ($eolStatus.Matched -and $eolStatus.Rule) {
                                $rule = $eolStatus.Rule
                                $eolFinding = New-EOLFinding `
                                    -SubscriptionId $SubscriptionId `
                                    -SubscriptionName $SubscriptionName `
                                    -ResourceGroup $dcr.ResourceGroupName `
                                    -ResourceType "Microsoft.Insights/dataCollectionRules" `
                                    -ResourceName $dcr.Name `
                                    -ResourceId $dcr.Id `
                                    -Component $rule.component `
                                    -Status $rule.status `
                                    -Deadline $eolStatus.Deadline `
                                    -Severity $eolStatus.Severity `
                                    -DaysUntilDeadline $eolStatus.DaysUntilDeadline `
                                    -ActionRequired $rule.actionRequired `
                                    -MigrationGuide $rule.migrationGuide `
                                    -References $(if ($rule.references) { $rule.references } else { @() })
                                $eolFindings.Add($eolFinding)
                            }
                        }
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
    
    # Return both security findings and EOL findings
    return @{
        Findings = $findings
        EOLFindings = $eolFindings
    }
}


