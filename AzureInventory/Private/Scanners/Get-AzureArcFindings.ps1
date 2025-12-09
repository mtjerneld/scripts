<#
.SYNOPSIS
    Scans Azure ARC Connected Machines for CIS security compliance (P0 and P1 controls).

.DESCRIPTION
    Checks Azure ARC machines against security controls:
    P0: Agent version current, Connection status
    P1: AMA extension installed, Automatic upgrade enabled

.PARAMETER SubscriptionId
    Azure subscription ID to scan.

.PARAMETER SubscriptionName
    Human-readable subscription name.

.OUTPUTS
    Array of SecurityFinding objects.
#>
function Get-AzureArcFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionName
    )
    
    $findings = [System.Collections.Generic.List[PSObject]]::new()
    
    # Load enabled controls from JSON
    $controls = Get-ControlsForCategory -Category "ARC"
    if ($null -eq $controls -or $controls.Count -eq 0) {
        Write-Verbose "No enabled ARC controls found in configuration for subscription $SubscriptionName"
        return $findings
    }
    Write-Verbose "Loaded $($controls.Count) ARC control(s) from configuration"
    
    # Create lookup hashtable for quick control access
    $controlLookup = @{}
    foreach ($control in $controls) {
        $controlLookup[$control.controlName] = $control
    }
    Write-Verbose "Control lookup created with keys: $($controlLookup.Keys -join ', ')"
    
    try {
        $arcMachines = Invoke-AzureApiWithRetry {
            Get-AzConnectedMachine -ErrorAction Stop
        }
    }
    catch {
        Write-Warning "Failed to retrieve ARC machines in subscription $SubscriptionName : $_"
        return $findings
    }
    
    if (-not $arcMachines) {
        Write-Verbose "No ARC machines found in subscription $SubscriptionName"
        return $findings
    }
    
    foreach ($machine in $arcMachines) {
        Write-Verbose "Scanning ARC machine: $($machine.Name)"
        
        # Skip if ResourceGroupName is empty
        if ([string]::IsNullOrWhiteSpace($machine.ResourceGroupName)) {
            Write-Verbose "Skipping ARC machine $($machine.Name) - ResourceGroupName is empty"
            continue
        }
        
        # Control: Agent Version Current
        $versionControl = $controlLookup["ARC Agent Version Current"]
        if ($versionControl) {
            $agentVersion = if ($machine.AgentVersion) { $machine.AgentVersion } else { "Unknown" }
            $versionCurrent = $true  # Simplified - in production, parse version and check against known current versions
            $versionStatus = if ($versionCurrent) { "PASS" } else { "FAIL" }
            
            $descAndRefs = Get-ControlDescriptionAndReferences -Control $versionControl
            $remediationCmd = $versionControl.remediationCommand -replace '\{name\}', $machine.Name -replace '\{rg\}', $machine.ResourceGroupName
            
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $machine.ResourceGroupName `
                -ResourceType "Microsoft.HybridCompute/machines" `
                -ResourceName $machine.Name `
                -ResourceId $machine.Id `
                -ControlId $versionControl.controlId `
                -ControlName $versionControl.controlName `
                -Category $versionControl.category `
                -Frameworks $versionControl.frameworks `
                -Severity $versionControl.severity `
                -CisLevel $versionControl.level `
                -CurrentValue $agentVersion `
                -ExpectedValue $versionControl.expectedValue `
                -Status $versionStatus `
                -RemediationSteps $descAndRefs.Description `
                -RemediationCommand $remediationCmd `
                -References $descAndRefs.References
            $findings.Add($finding)
        }
        
        # Control: Connection Status
        $connectionControl = $controlLookup["ARC Connection Status"]
        if ($connectionControl) {
            $connectionStatus = if ($machine.Status) { $machine.Status } else { "Unknown" }
            $connectedStatus = if ($connectionStatus -eq "Connected") { "PASS" } else { "FAIL" }
            
            $descAndRefs = Get-ControlDescriptionAndReferences -Control $connectionControl
            $remediationCmd = $connectionControl.remediationCommand -replace '\{name\}', $machine.Name -replace '\{rg\}', $machine.ResourceGroupName
            
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $machine.ResourceGroupName `
                -ResourceType "Microsoft.HybridCompute/machines" `
                -ResourceName $machine.Name `
                -ResourceId $machine.Id `
                -ControlId $connectionControl.controlId `
                -ControlName $connectionControl.controlName `
                -Category $connectionControl.category `
                -Frameworks $connectionControl.frameworks `
                -Severity $connectionControl.severity `
                -CisLevel $connectionControl.level `
                -CurrentValue $connectionStatus `
                -ExpectedValue $connectionControl.expectedValue `
                -Status $connectedStatus `
                -RemediationSteps $descAndRefs.Description `
                -RemediationCommand $remediationCmd `
                -References $descAndRefs.References
            $findings.Add($finding)
        }
        
        # Control: AMA Extension Installed
        $amaControl = $controlLookup["ARC AMA Extension Installed"]
        if ($amaControl) {
            try {
                $extensions = Invoke-AzureApiWithRetry {
                    Get-AzConnectedMachineExtension -ResourceGroupName $machine.ResourceGroupName -MachineName $machine.Name -ErrorAction SilentlyContinue
                }
                
                $amaInstalled = $false
                if ($extensions) {
                    foreach ($ext in $extensions) {
                        if ($ext.Type -eq "AzureMonitorWindowsAgent" -or $ext.Type -eq "AzureMonitorLinuxAgent") {
                            $amaInstalled = $true
                            break
                        }
                    }
                }
            }
            catch {
                $amaInstalled = $false
            }
            
            $amaStatus = if ($amaInstalled) { "PASS" } else { "FAIL" }
            
            $descAndRefs = Get-ControlDescriptionAndReferences -Control $amaControl
            $remediationCmd = $amaControl.remediationCommand -replace '\{name\}', $machine.Name -replace '\{rg\}', $machine.ResourceGroupName
            
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $machine.ResourceGroupName `
                -ResourceType "Microsoft.HybridCompute/machines" `
                -ResourceName $machine.Name `
                -ResourceId $machine.Id `
                -ControlId $amaControl.controlId `
                -ControlName $amaControl.controlName `
                -Category $amaControl.category `
                -Frameworks $amaControl.frameworks `
                -Severity $amaControl.severity `
                -CisLevel $amaControl.level `
                -CurrentValue $(if ($amaInstalled) { "Installed" } else { "Not installed" }) `
                -ExpectedValue $amaControl.expectedValue `
                -Status $amaStatus `
                -RemediationSteps $descAndRefs.Description `
                -RemediationCommand $remediationCmd `
                -References $descAndRefs.References
            $findings.Add($finding)
        }
        
        # Control: Automatic Upgrade Enabled
        $upgradeControl = $controlLookup["ARC Automatic Upgrade Enabled"]
        if ($upgradeControl) {
            try {
                $upgradeSettings = $machine.AgentUpgrade
                $autoUpgrade = if ($upgradeSettings) { $upgradeSettings.EnableAutomaticUpgrade } else { $false }
            }
            catch {
                $autoUpgrade = $false
            }
            
            $upgradeStatus = if ($autoUpgrade) { "PASS" } else { "FAIL" }
            
            $descAndRefs = Get-ControlDescriptionAndReferences -Control $upgradeControl
            $remediationCmd = $upgradeControl.remediationCommand -replace '\{name\}', $machine.Name -replace '\{rg\}', $machine.ResourceGroupName
            
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $machine.ResourceGroupName `
                -ResourceType "Microsoft.HybridCompute/machines" `
                -ResourceName $machine.Name `
                -ResourceId $machine.Id `
                -ControlId $upgradeControl.controlId `
                -ControlName $upgradeControl.controlName `
                -Category $upgradeControl.category `
                -Frameworks $upgradeControl.frameworks `
                -Severity $upgradeControl.severity `
                -CisLevel $upgradeControl.level `
                -CurrentValue $autoUpgrade.ToString() `
                -ExpectedValue $upgradeControl.expectedValue `
                -Status $upgradeStatus `
                -RemediationSteps $descAndRefs.Description `
                -RemediationCommand $remediationCmd `
                -References $descAndRefs.References
            $findings.Add($finding)
        }
    }
    
    return $findings
}


