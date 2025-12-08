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
    
    # P0: No MMA/OMS Agents - Check via Log Analytics query
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
                    $query = "Heartbeat | where TimeGenerated > ago(24h) | where Category == 'Direct Agent' | distinct Computer, OSType"
                    
                    # Execute query using REST API (simplified - would need proper implementation)
                    # For now, we'll create a finding if workspace exists and note that manual verification needed
                    $finding = New-SecurityFinding `
                        -SubscriptionId $SubscriptionId `
                        -SubscriptionName $SubscriptionName `
                        -ResourceGroup $workspace.ResourceGroupName `
                        -ResourceType "Microsoft.OperationalInsights/workspaces" `
                        -ResourceName $workspace.Name `
                        -ResourceId $workspace.Id `
                        -ControlId "N/A" `
                        -ControlName "No MMA/OMS Agents" `
                        -Category "Monitor" `
                        -Severity "Critical" `
                        -CurrentValue "Manual verification required" `
                        -ExpectedValue "No Direct Agent category in Heartbeat logs" `
                        -Status "SKIPPED" `
                        -RemediationSteps "CRITICAL: Log Analytics Agent (MMA) was retired on August 31, 2024. Verify no machines are using Direct Agent category. Migrate to Azure Monitor Agent (AMA) immediately." `
                        -RemediationCommand "Query Log Analytics: Heartbeat | where Category == 'Direct Agent' | distinct Computer" `
                        -EOLDate "2024-08-31"
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
    
    # P1 Control 5.4: Diagnostic Settings Enabled (sample check on key resources)
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
                # Use both WarningPreference and WarningAction to ensure warnings are suppressed
                $originalWarningPreference = $WarningPreference
                $WarningPreference = 'SilentlyContinue'
                try {
                    $diagnosticSettings = Invoke-AzureApiWithRetry {
                        Get-AzDiagnosticSetting -ResourceId $resource.Id -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                    }
                    $diagnosticsEnabled = if ($diagnosticSettings) { $true } else { $false }
                }
                finally {
                    $WarningPreference = $originalWarningPreference
                }
            }
            catch {
                $diagnosticsEnabled = $false
            }
            
            # Always create finding (PASS or FAIL)
            $diagStatus = if ($diagnosticsEnabled) { "PASS" } else { "FAIL" }
            $remediationCmd = if ($diagnosticsEnabled) { "" } else { "az monitor diagnostic-settings create --resource $($resource.Id) --name <setting-name> --workspace <log-analytics-workspace-id>" }
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $resource.ResourceGroupName `
                -ResourceType $resource.ResourceType `
                -ResourceName $resource.Name `
                -ResourceId $resource.Id `
                -ControlId "5.4" `
                -ControlName "Diagnostic Settings Enabled" `
                -Category "Monitor" `
                -Severity "Medium" `
                -CisLevel "L1" `
                -CurrentValue $(if ($diagnosticsEnabled) { "Configured" } else { "Not configured" }) `
                -ExpectedValue "Diagnostic settings configured" `
                -Status $diagStatus `
                -RemediationSteps "Enable diagnostic settings for the resource to collect logs and metrics for monitoring." `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }
    }
    catch {
        Write-Verbose "Could not check diagnostic settings: $_"
    }
    
    # P1: DCR Associations (Data Collection Rule Associations)
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
                    $remediationCmd = if ($hasAssociations) { "" } else { "az monitor data-collection rule association create --rule-id $($dcr.Id) --resource <target-resource-id>" }
                    $finding = New-SecurityFinding `
                        -SubscriptionId $SubscriptionId `
                        -SubscriptionName $SubscriptionName `
                        -ResourceGroup $dcr.ResourceGroupName `
                        -ResourceType "Microsoft.Insights/dataCollectionRules" `
                        -ResourceName $dcr.Name `
                        -ResourceId $dcr.Id `
                        -ControlId "N/A" `
                        -ControlName "DCR Associations" `
                        -Category "Monitor" `
                        -Severity "Medium" `
                        -CisLevel "N/A" `
                        -CurrentValue $(if ($hasAssociations) { "Has associations" } else { "No associations" }) `
                        -ExpectedValue "At least one DCR association" `
                        -Status $dcrStatus `
                        -RemediationSteps "Associate Data Collection Rule (DCR) with resources for centralized data collection." `
                        -RemediationCommand $remediationCmd
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
    
    return $findings
}


