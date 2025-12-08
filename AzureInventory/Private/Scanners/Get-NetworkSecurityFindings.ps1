<#
.SYNOPSIS
    Scans Azure Network Security Groups and related networking resources for CIS security compliance.

.DESCRIPTION
    Checks Network Security Groups, Virtual Networks, and Azure Firewalls against CIS controls:
    P0: No RDP/SSH from Internet, No any-to-any rules
    P1: Network Watcher enabled, DDoS protection, Azure Firewall threat intel

.PARAMETER SubscriptionId
    Azure subscription ID to scan.

.PARAMETER SubscriptionName
    Human-readable subscription name.

.OUTPUTS
    Array of SecurityFinding objects.
#>
function Get-NetworkSecurityFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionName,
        
        [switch]$IncludeLevel2
    )
    
    # Suppress Azure PowerShell module warnings about unapproved verbs
    # This must be set before any Azure cmdlets are called
    $originalWarningPreference = $WarningPreference
    $WarningPreference = 'SilentlyContinue'
    
    $findings = [System.Collections.Generic.List[PSObject]]::new()
    $resourcesChecked = 0
    $checksPerformed = 0
    
    # Load enabled controls from JSON
    try {
        $controls = Get-ControlsForCategory -Category "Network" -IncludeLevel2:$IncludeLevel2
        if ($null -eq $controls -or $controls.Count -eq 0) {
            Write-Warning "No enabled Network controls found in configuration for subscription $SubscriptionName"
            Write-Verbose "This may indicate all Network controls are disabled in ControlDefinitions.json"
            return $findings
        }
        Write-Verbose "Loaded $($controls.Count) Network control(s) from configuration"
    }
    catch {
        Write-Warning "Failed to load Network controls from configuration: $_"
        Write-Verbose "Error details: $($_.Exception.Message)"
        return $findings
    }
    
    # Create lookup hashtable for quick control access
    $controlLookup = @{}
    foreach ($control in $controls) {
        $controlLookup[$control.controlName] = $control
    }
    Write-Verbose "Control lookup created with keys: $($controlLookup.Keys -join ', ')"
    
    # P0: Network Security Group Rules
    try {
        $nsgs = Invoke-AzureApiWithRetry {
            Get-AzNetworkSecurityGroup -ErrorAction Stop
        }
        Write-Verbose "Found $($nsgs.Count) NSG(s) in subscription $SubscriptionName"
    }
    catch {
        Write-Warning "Failed to retrieve NSGs in subscription $SubscriptionName : $_"
        Write-Verbose "Error details: $($_.Exception.Message)"
        $nsgs = $null
    }
    
    if ($nsgs -and $nsgs.Count -gt 0) {
        $resourcesChecked += $nsgs.Count
        foreach ($nsg in $nsgs) {
            Write-Verbose "Scanning NSG: $($nsg.Name)"
            
            try {
                $rules = Invoke-AzureApiWithRetry {
                    Get-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -ErrorAction SilentlyContinue
                }
                
                if ($rules -and $rules.Count -gt 0) {
                    foreach ($rule in $rules) {
                        # Control 6.1: No RDP from Internet
                        $rdpControl = $controlLookup["No RDP from Internet"]
                        if ($rdpControl) {
                            $checksPerformed++
                            $hasRdpFromInternet = $false
                            if ($rule.Direction -eq "Inbound" -and 
                                $rule.Access -eq "Allow" -and
                                ($rule.DestinationPortRange -eq "3389" -or $rule.DestinationPortRanges -contains "3389") -and
                                ($rule.SourceAddressPrefix -eq "*" -or $rule.SourceAddressPrefix -eq "Internet" -or 
                                 $rule.SourceAddressPrefixes -contains "*" -or $rule.SourceAddressPrefixes -contains "Internet")) {
                                $hasRdpFromInternet = $true
                            }
                            
                            # Only create finding if RDP from Internet is found (FAIL case)
                            if ($hasRdpFromInternet) {
                                $remediationCmd = $rdpControl.remediationCommand -replace '\{name\}', $rule.Name -replace '\{nsgName\}', $nsg.Name -replace '\{rg\}', $nsg.ResourceGroupName
                                $finding = New-SecurityFinding `
                                    -SubscriptionId $SubscriptionId `
                                    -SubscriptionName $SubscriptionName `
                                    -ResourceGroup $nsg.ResourceGroupName `
                                    -ResourceType "Microsoft.Network/networkSecurityGroups" `
                                    -ResourceName $nsg.Name `
                                    -ResourceId $nsg.Id `
                                    -ControlId $rdpControl.controlId `
                                    -ControlName $rdpControl.controlName `
                                    -Category $rdpControl.category `
                                    -Severity $rdpControl.severity `
                                    -CisLevel $rdpControl.level `
                                    -CurrentValue "RDP (3389) allowed from Internet" `
                                    -ExpectedValue $rdpControl.expectedValue `
                                    -Status "FAIL" `
                                    -RemediationSteps $rdpControl.businessImpact `
                                    -RemediationCommand $remediationCmd
                                $findings.Add($finding)
                            }
                        }
                        else {
                            Write-Verbose "Control 'No RDP from Internet' not found in controlLookup. Available controls: $($controlLookup.Keys -join ', ')"
                        }
                        
                        # Control 6.2: No SSH from Internet
                        $sshControl = $controlLookup["No SSH from Internet"]
                        if ($sshControl) {
                            $checksPerformed++
                            $hasSshFromInternet = $false
                            if ($rule.Direction -eq "Inbound" -and 
                                $rule.Access -eq "Allow" -and
                                ($rule.DestinationPortRange -eq "22" -or $rule.DestinationPortRanges -contains "22") -and
                                ($rule.SourceAddressPrefix -eq "*" -or $rule.SourceAddressPrefix -eq "Internet" -or 
                                 $rule.SourceAddressPrefixes -contains "*" -or $rule.SourceAddressPrefixes -contains "Internet")) {
                                $hasSshFromInternet = $true
                            }
                            
                            # Only create finding if SSH from Internet is found (FAIL case)
                            if ($hasSshFromInternet) {
                                $remediationCmd = $sshControl.remediationCommand -replace '\{name\}', $rule.Name -replace '\{nsgName\}', $nsg.Name -replace '\{rg\}', $nsg.ResourceGroupName
                                $finding = New-SecurityFinding `
                                    -SubscriptionId $SubscriptionId `
                                    -SubscriptionName $SubscriptionName `
                                    -ResourceGroup $nsg.ResourceGroupName `
                                    -ResourceType "Microsoft.Network/networkSecurityGroups" `
                                    -ResourceName $nsg.Name `
                                    -ResourceId $nsg.Id `
                                    -ControlId $sshControl.controlId `
                                    -ControlName $sshControl.controlName `
                                    -Category $sshControl.category `
                                    -Severity $sshControl.severity `
                                    -CisLevel $sshControl.level `
                                    -CurrentValue "SSH (22) allowed from Internet" `
                                    -ExpectedValue $sshControl.expectedValue `
                                    -Status "FAIL" `
                                    -RemediationSteps $sshControl.businessImpact `
                                    -RemediationCommand $remediationCmd
                                $findings.Add($finding)
                            }
                        }
                        else {
                            Write-Verbose "Control 'No SSH from Internet' not found in controlLookup. Available controls: $($controlLookup.Keys -join ', ')"
                        }
                        
                        # Control: No Any-to-Any Rules
                        $anyToAnyControl = $controlLookup["No Any-to-Any Allow Rules"]
                        if ($anyToAnyControl) {
                            $checksPerformed++
                            $hasAnyToAny = $false
                            if ($rule.Direction -eq "Inbound" -and 
                                $rule.Access -eq "Allow" -and
                                ($rule.SourceAddressPrefix -eq "*" -or $rule.SourceAddressPrefixes -contains "*") -and
                                ($rule.DestinationAddressPrefix -eq "*" -or $rule.DestinationAddressPrefixes -contains "*")) {
                                $hasAnyToAny = $true
                            }
                            
                            # Only create finding if any-to-any rule is found (FAIL case)
                            if ($hasAnyToAny) {
                                $remediationCmd = $anyToAnyControl.remediationCommand -replace '\{name\}', $rule.Name -replace '\{nsgName\}', $nsg.Name -replace '\{rg\}', $nsg.ResourceGroupName -replace '\{ruleName\}', $rule.Name
                                $finding = New-SecurityFinding `
                                    -SubscriptionId $SubscriptionId `
                                    -SubscriptionName $SubscriptionName `
                                    -ResourceGroup $nsg.ResourceGroupName `
                                    -ResourceType "Microsoft.Network/networkSecurityGroups" `
                                    -ResourceName $nsg.Name `
                                    -ResourceId $nsg.Id `
                                    -ControlId $anyToAnyControl.controlId `
                                    -ControlName $anyToAnyControl.controlName `
                                    -Category $anyToAnyControl.category `
                                    -Severity $anyToAnyControl.severity `
                                    -CisLevel $anyToAnyControl.level `
                                    -CurrentValue "Any-to-any rule present" `
                                    -ExpectedValue $anyToAnyControl.expectedValue `
                                    -Status "FAIL" `
                                    -RemediationSteps $anyToAnyControl.businessImpact `
                                    -RemediationCommand $remediationCmd
                                $findings.Add($finding)
                            }
                        }
                        else {
                            Write-Verbose "Control 'No Any-to-Any Allow Rules' not found in controlLookup. Available controls: $($controlLookup.Keys -join ', ')"
                        }
                    }
                }
            }
            catch {
                Write-Verbose "Could not retrieve rules for NSG $($nsg.Name): $_"
            }
        }
    }
    
    # Control 6.6: Network Watcher Enabled (check per region with VNets)
    $watcherControl = $controlLookup["Network Watcher Enabled"]
    if ($watcherControl) {
        try {
            $vnets = Invoke-AzureApiWithRetry {
                Get-AzVirtualNetwork -ErrorAction SilentlyContinue
            }
            
            if ($vnets -and $vnets.Count -gt 0) {
                $resourcesChecked += $vnets.Count
                $regions = $vnets | Select-Object -ExpandProperty Location -Unique
                foreach ($region in $regions) {
                    $checksPerformed++
                    try {
                        $networkWatcher = Invoke-AzureApiWithRetry {
                            Get-AzNetworkWatcher -Location $region -ErrorAction SilentlyContinue
                        }
                        $watcherEnabled = if ($networkWatcher) { $true } else { $false }
                    }
                    catch {
                        $watcherEnabled = $false
                    }
                    
                    # Create finding for both PASS and FAIL to show all checks performed
                    $watcherStatus = if ($watcherEnabled) { "PASS" } else { "FAIL" }
                    $remediationCmd = $watcherControl.remediationCommand -replace '\{region\}', $region
                    $finding = New-SecurityFinding `
                        -SubscriptionId $SubscriptionId `
                        -SubscriptionName $SubscriptionName `
                        -ResourceGroup "NetworkWatcherRG" `
                        -ResourceType "Microsoft.Network/networkWatchers" `
                        -ResourceName "NetworkWatcher_$region" `
                        -ResourceId "/subscriptions/$SubscriptionId/resourceGroups/NetworkWatcherRG/providers/Microsoft.Network/networkWatchers/NetworkWatcher_$region" `
                        -ControlId $watcherControl.controlId `
                        -ControlName $watcherControl.controlName `
                        -Category $watcherControl.category `
                        -Severity $watcherControl.severity `
                        -CisLevel $watcherControl.level `
                        -CurrentValue $(if ($watcherEnabled) { "Enabled" } else { "Not enabled" }) `
                        -ExpectedValue $watcherControl.expectedValue `
                        -Status $watcherStatus `
                        -RemediationSteps $watcherControl.businessImpact `
                        -RemediationCommand $remediationCmd
                    $findings.Add($finding)
                }
            }
        }
        catch {
            Write-Verbose "Could not check Network Watcher: $_"
        }
    }
    
    # Control: DDoS Protection Standard (only if enabled in JSON)
    $ddosControl = $controlLookup["DDoS Protection Standard"]
    if ($ddosControl) {
        try {
            $vnets = Invoke-AzureApiWithRetry {
                Get-AzVirtualNetwork -ErrorAction SilentlyContinue
            }
            Write-Verbose "Found $($vnets.Count) VNet(s) for DDoS Protection check"
            
            if ($vnets -and $vnets.Count -gt 0) {
                foreach ($vnet in $vnets) {
                    $checksPerformed++
                    $ddosEnabled = if ($vnet.EnableDdosProtection) { $vnet.EnableDdosProtection } else { $false }
                    
                    # Create finding for both PASS and FAIL to show all checks performed
                    $ddosStatus = if ($ddosEnabled) { "PASS" } else { "FAIL" }
                    $remediationCmd = $ddosControl.remediationCommand -replace '\{name\}', $vnet.Name -replace '\{rg\}', $vnet.ResourceGroupName
                    $note = if ($ddosControl.commercial) { "Level 2 - Commercial feature. Costs $($ddosControl.commercialCost). Basic DDoS Protection (free) is enabled by default." } else { "" }
                    $finding = New-SecurityFinding `
                        -SubscriptionId $SubscriptionId `
                        -SubscriptionName $SubscriptionName `
                        -ResourceGroup $vnet.ResourceGroupName `
                        -ResourceType "Microsoft.Network/virtualNetworks" `
                        -ResourceName $vnet.Name `
                        -ResourceId $vnet.Id `
                        -ControlId $ddosControl.controlId `
                        -ControlName $ddosControl.controlName `
                        -Category $ddosControl.category `
                        -Severity $ddosControl.severity `
                        -CisLevel $ddosControl.level `
                        -Note $note `
                        -CurrentValue $(if ($ddosEnabled) { "Enabled" } else { "Disabled" }) `
                        -ExpectedValue $ddosControl.expectedValue `
                        -Status $ddosStatus `
                        -RemediationSteps $ddosControl.businessImpact `
                        -RemediationCommand $remediationCmd
                    $findings.Add($finding)
                }
            }
        }
        catch {
            Write-Verbose "Could not check DDoS protection: $_"
        }
    }
    
    # Control: Azure Firewall Threat Intel
    $threatIntelControl = $controlLookup["Azure Firewall Threat Intel"]
    if ($threatIntelControl) {
        try {
            $firewalls = Invoke-AzureApiWithRetry {
                Get-AzFirewall -ErrorAction SilentlyContinue
            }
            Write-Verbose "Found $($firewalls.Count) Azure Firewall(s) for Threat Intel check"
            
            if ($firewalls -and $firewalls.Count -gt 0) {
                $resourcesChecked += $firewalls.Count
                foreach ($firewall in $firewalls) {
                    $checksPerformed++
                    try {
                        $policy = Invoke-AzureApiWithRetry {
                            Get-AzFirewallPolicy -ResourceId $firewall.FirewallPolicy.Id -ErrorAction SilentlyContinue
                        }
                        $threatIntelMode = if ($policy) { $policy.ThreatIntelMode } else { "Off" }
                    }
                    catch {
                        $threatIntelMode = "Off"
                    }
                    
                    $threatIntelStatus = if ($threatIntelMode -in @("Alert", "Deny")) { "PASS" } else { "FAIL" }
                    
                    $remediationCmd = $threatIntelControl.remediationCommand -replace '\{policyName\}', $(if ($policy) { $policy.Name } else { '<policy-name>' }) -replace '\{rg\}', $firewall.ResourceGroupName
                    $finding = New-SecurityFinding `
                        -SubscriptionId $SubscriptionId `
                        -SubscriptionName $SubscriptionName `
                        -ResourceGroup $firewall.ResourceGroupName `
                        -ResourceType "Microsoft.Network/azureFirewalls" `
                        -ResourceName $firewall.Name `
                        -ResourceId $firewall.Id `
                        -ControlId $threatIntelControl.controlId `
                        -ControlName $threatIntelControl.controlName `
                        -Category $threatIntelControl.category `
                        -Severity $threatIntelControl.severity `
                        -CisLevel $threatIntelControl.level `
                        -CurrentValue $threatIntelMode `
                        -ExpectedValue $threatIntelControl.expectedValue `
                        -Status $threatIntelStatus `
                        -RemediationSteps $threatIntelControl.businessImpact `
                        -RemediationCommand $remediationCmd
                    $findings.Add($finding)
                }
            }
            else {
                Write-Verbose "No Azure Firewalls found in subscription $SubscriptionName"
            }
        }
        catch {
            Write-Verbose "Could not check Azure Firewall: $_"
        }
    }
    else {
        Write-Verbose "Control 'Azure Firewall Threat Intel' not found in controlLookup or not enabled"
    }
    
    Write-Verbose "Network scan completed. Resources checked: $resourcesChecked, Checks performed: $checksPerformed, Total findings: $($findings.Count)"
    
    # If no resources were found but controls are enabled, log a warning
    if ($resourcesChecked -eq 0 -and $controls.Count -gt 0) {
        Write-Verbose "No Network resources (NSGs, VNets, Firewalls) found in subscription $SubscriptionName, but $($controls.Count) control(s) are enabled"
    }
    
    # Restore original warning preference
    $WarningPreference = $originalWarningPreference
    
    return $findings
}


