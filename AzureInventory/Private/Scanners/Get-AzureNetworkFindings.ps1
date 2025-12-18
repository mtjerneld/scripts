<#
.SYNOPSIS
    Scans Azure Network resources for CIS security compliance.

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
function Get-AzureNetworkFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionName,
        
        [switch]$IncludeLevel2
    )
    
    # Suppress Azure PowerShell module warnings about unapproved verbs
    $findings = [System.Collections.Generic.List[PSObject]]::new()
    $eolFindings = [System.Collections.Generic.List[PSObject]]::new()
    
    # Track metadata for consolidated output
    $uniqueResourcesScanned = @{}
    $controlsEvaluated = 0
    
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
                    if ($mapping.resourceType) {
                        $resourceTypeMapping[$mapping.resourceType] = $mapping
                    }
                }
            }
            Write-Verbose "Loaded $($resourceTypeMapping.Keys.Count) resource type mapping(s) from ResourceTypeMapping.json"
        }
        catch {
            Write-Verbose "Failed to load ResourceTypeMapping: $_"
        }
    } else {
        Write-Verbose "ResourceTypeMapping.json not found at $mappingPath - EOL matching may be limited"
    }
    
    # Load enabled controls from JSON
    try {
        $controls = Get-ControlsForCategory -Category "Network" -IncludeLevel2:$IncludeLevel2
        if ($null -eq $controls -or $controls.Count -eq 0) {
            Write-Warning "No enabled Network controls found in configuration for subscription $SubscriptionName"
            Write-Verbose "This may indicate all Network controls are disabled in ControlDefinitions.json"
            return @{
                Findings = $findings
                EOLFindings = $eolFindings
                ResourceCount = 0
                ControlCount = 0
                FailureCount = 0
                EOLCount = 0
            }
        }
        Write-Verbose "Loaded $($controls.Count) Network control(s) from configuration"
    }
    catch {
        Write-Warning "Failed to load Network controls from configuration: $_"
        Write-Verbose "Error details: $($_.Exception.Message)"
        return @{
            Findings = $findings
            EOLFindings = $eolFindings
            ResourceCount = 0
            ControlCount = 0
            FailureCount = 0
            EOLCount = 0
        }
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
        foreach ($nsg in $nsgs) {
            Write-Verbose "Scanning NSG: $($nsg.Name)"
            
            # Track this resource as scanned
            $resourceKey = if ($nsg.Id) { $nsg.Id } else { "$($nsg.ResourceGroupName)/$($nsg.Name)" }
            if (-not $uniqueResourcesScanned.ContainsKey($resourceKey)) {
                $uniqueResourcesScanned[$resourceKey] = $true
            }
            
            # Track if we found issues for each control per NSG
            $rdpControl = $controlLookup["No RDP from Internet"]
            $sshControl = $controlLookup["No SSH from Internet"]
            $anyToAnyControl = $controlLookup["No Any-to-Any Allow Rules"]
            
            $hasRdpIssue = $false
            $hasSshIssue = $false
            $hasAnyToAnyIssue = $false
            
            try {
                $rules = Invoke-AzureApiWithRetry {
                    Get-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -ErrorAction SilentlyContinue
                }
                
                if ($rules -and $rules.Count -gt 0) {
                    foreach ($rule in $rules) {
                        # Control 6.1: No RDP from Internet
                        if ($rdpControl) {
                            if ($rule.Direction -eq "Inbound" -and 
                                $rule.Access -eq "Allow" -and
                                ($rule.DestinationPortRange -eq "3389" -or $rule.DestinationPortRanges -contains "3389") -and
                                ($rule.SourceAddressPrefix -eq "*" -or $rule.SourceAddressPrefix -eq "Internet" -or 
                                 $rule.SourceAddressPrefixes -contains "*" -or $rule.SourceAddressPrefixes -contains "Internet")) {
                                $hasRdpIssue = $true
                            }
                        }
                        else {
                            Write-Verbose "Control 'No RDP from Internet' not found in controlLookup. Available controls: $($controlLookup.Keys -join ', ')"
                        }
                        
                        # Control 6.2: No SSH from Internet
                        if ($sshControl) {
                            if ($rule.Direction -eq "Inbound" -and 
                                $rule.Access -eq "Allow" -and
                                ($rule.DestinationPortRange -eq "22" -or $rule.DestinationPortRanges -contains "22") -and
                                ($rule.SourceAddressPrefix -eq "*" -or $rule.SourceAddressPrefix -eq "Internet" -or 
                                 $rule.SourceAddressPrefixes -contains "*" -or $rule.SourceAddressPrefixes -contains "Internet")) {
                                $hasSshIssue = $true
                            }
                        }
                        else {
                            Write-Verbose "Control 'No SSH from Internet' not found in controlLookup. Available controls: $($controlLookup.Keys -join ', ')"
                        }
                        
                        # Control: No Any-to-Any Rules
                        if ($anyToAnyControl) {
                            if ($rule.Direction -eq "Inbound" -and 
                                $rule.Access -eq "Allow" -and
                                ($rule.SourceAddressPrefix -eq "*" -or $rule.SourceAddressPrefixes -contains "*") -and
                                ($rule.DestinationAddressPrefix -eq "*" -or $rule.DestinationAddressPrefixes -contains "*")) {
                                $hasAnyToAnyIssue = $true
                            }
                        }
                        else {
                            Write-Verbose "Control 'No Any-to-Any Allow Rules' not found in controlLookup. Available controls: $($controlLookup.Keys -join ', ')"
                        }
                    }
                }
                
                # Create findings per NSG (not per rule) - one finding per control
                # Control 6.1: No RDP from Internet
                if ($rdpControl) {
                    $controlsEvaluated++
                    if ($hasRdpIssue) {
                        $remediationCmd = $rdpControl.remediationCommand -replace '\{nsgName\}', $nsg.Name -replace '\{rg\}', $nsg.ResourceGroupName
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
                            -Frameworks $rdpControl.frameworks `
                            -Severity $rdpControl.severity `
                            -CisLevel $rdpControl.level `
                            -CurrentValue "RDP (3389) allowed from Internet" `
                            -ExpectedValue $rdpControl.expectedValue `
                            -Status "FAIL" `
                            -RemediationSteps $rdpControl.businessImpact `
                            -RemediationCommand $remediationCmd
                        $findings.Add($finding)
                    }
                    else {
                        # Create PASS finding to show the check was performed
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
                            -Frameworks $rdpControl.frameworks `
                            -Severity $rdpControl.severity `
                            -CisLevel $rdpControl.level `
                            -CurrentValue "No RDP (3389) allowed from Internet" `
                            -ExpectedValue $rdpControl.expectedValue `
                            -Status "PASS" `
                            -RemediationSteps $rdpControl.businessImpact `
                            -RemediationCommand ""
                        $findings.Add($finding)
                    }
                }
                
                # Control 6.2: No SSH from Internet
                if ($sshControl) {
                    $controlsEvaluated++
                    $descAndRefs = Get-ControlDescriptionAndReferences -Control $sshControl
                    $description = $descAndRefs.Description
                    $references = $descAndRefs.References
                    
                    if ($hasSshIssue) {
                        $remediationCmd = $sshControl.remediationCommand -replace '\{nsgName\}', $nsg.Name -replace '\{rg\}', $nsg.ResourceGroupName
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
                            -Frameworks $sshControl.frameworks `
                            -Severity $sshControl.severity `
                            -CisLevel $sshControl.level `
                            -CurrentValue "SSH (22) allowed from Internet" `
                            -ExpectedValue $sshControl.expectedValue `
                            -Status "FAIL" `
                            -RemediationSteps $description `
                            -RemediationCommand $remediationCmd `
                            -References $references
                        $findings.Add($finding)
                    }
                    else {
                        # Create PASS finding to show the check was performed
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
                            -Frameworks $sshControl.frameworks `
                            -Severity $sshControl.severity `
                            -CisLevel $sshControl.level `
                            -CurrentValue "No SSH (22) allowed from Internet" `
                            -ExpectedValue $sshControl.expectedValue `
                            -Status "PASS" `
                            -RemediationSteps $description `
                            -RemediationCommand "" `
                            -References $references
                        $findings.Add($finding)
                    }
                }
                
                # Control: No Any-to-Any Rules
                if ($anyToAnyControl) {
                    $controlsEvaluated++
                    if ($hasAnyToAnyIssue) {
                        $remediationCmd = $anyToAnyControl.remediationCommand -replace '\{nsgName\}', $nsg.Name -replace '\{rg\}', $nsg.ResourceGroupName
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
                            -Frameworks $anyToAnyControl.frameworks `
                            -Severity $anyToAnyControl.severity `
                            -CisLevel $anyToAnyControl.level `
                            -CurrentValue "Any-to-any rule present" `
                            -ExpectedValue $anyToAnyControl.expectedValue `
                            -Status "FAIL" `
                            -RemediationSteps $anyToAnyControl.businessImpact `
                            -RemediationCommand $remediationCmd
                        $findings.Add($finding)
                    }
                    else {
                        # Create PASS finding to show the check was performed
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
                            -Frameworks $anyToAnyControl.frameworks `
                            -Severity $anyToAnyControl.severity `
                            -CisLevel $anyToAnyControl.level `
                            -CurrentValue "No any-to-any rules" `
                            -ExpectedValue $anyToAnyControl.expectedValue `
                            -Status "PASS" `
                            -RemediationSteps $anyToAnyControl.businessImpact `
                            -RemediationCommand ""
                        $findings.Add($finding)
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
                # Track VNets as resources scanned
                foreach ($vnet in $vnets) {
                    $resourceKey = if ($vnet.Id) { $vnet.Id } else { "$($vnet.ResourceGroupName)/$($vnet.Name)" }
                    if (-not $uniqueResourcesScanned.ContainsKey($resourceKey)) {
                        $uniqueResourcesScanned[$resourceKey] = $true
                    }
                }
                $regions = $vnets | Select-Object -ExpandProperty Location -Unique
                foreach ($region in $regions) {
                    $controlsEvaluated++
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
                        -Frameworks $watcherControl.frameworks `
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
    
    # Control: VPN Gateway - Availability Zone SKU Required (Security check only, EOL handled separately)
    $vpnGwControl = $controlLookup["VPN Gateway - Availability Zone SKU Required"]
    if ($vpnGwControl) {
        try {
            # Get VPN Gateways using Get-AzResource first to avoid prompting for ResourceGroup
            $gatewayResources = Invoke-AzureApiWithRetry {
                Get-AzResource -ResourceType "Microsoft.Network/virtualNetworkGateways" -ErrorAction SilentlyContinue
            }
            
            if ($gatewayResources -and $gatewayResources.Count -gt 0) {
                foreach ($gwResource in $gatewayResources) {
                    # Track gateway as resource scanned
                    $resourceKey = if ($gwResource.Id) { $gwResource.Id } else { "$($gwResource.ResourceGroupName)/$($gwResource.Name)" }
                    if (-not $uniqueResourcesScanned.ContainsKey($resourceKey)) {
                        $uniqueResourcesScanned[$resourceKey] = $true
                    }
                    
                    try {
                        $gateway = Invoke-AzureApiWithRetry {
                            Get-AzVirtualNetworkGateway -ResourceGroupName $gwResource.ResourceGroupName -Name $gwResource.Name -ErrorAction SilentlyContinue
                        }
                        
                        if ($gateway) {
                            $controlsEvaluated++
                            $skuName = if ($gateway.Sku) { $gateway.Sku.Name } else { "Unknown" }
                            
                            # Check if SKU is deprecated (VpnGw1-5 without AZ suffix, but not ExpressRoute SKUs)
                            $deprecatedSkus = @("VpnGw1", "VpnGw2", "VpnGw3", "VpnGw4", "VpnGw5")
                            $isDeprecated = $deprecatedSkus -contains $skuName
                            
                            $gwStatus = if ($isDeprecated) { "FAIL" } else { "PASS" }
                            $currentValue = if ($isDeprecated) { "$skuName (Deprecated - EOL Sep 2026)" } else { "$skuName (Zone-redundant or ExpressRoute)" }
                            
                            $remediationCmd = $vpnGwControl.remediationCommand -replace '\{name\}', $gateway.Name -replace '\{rg\}', $gateway.ResourceGroupName
                            # Replace {newSku} with appropriate AZ version
                            $newSku = $skuName + "AZ"
                            $remediationCmd = $remediationCmd -replace '\{newSku\}', $newSku
                            
                            $finding = New-SecurityFinding `
                                -SubscriptionId $SubscriptionId `
                                -SubscriptionName $SubscriptionName `
                                -ResourceGroup $gateway.ResourceGroupName `
                                -ResourceType "Microsoft.Network/virtualNetworkGateways" `
                                -ResourceName $gateway.Name `
                                -ResourceId $gateway.Id `
                                -ControlId $vpnGwControl.controlId `
                                -ControlName $vpnGwControl.controlName `
                                -Category $vpnGwControl.category `
                                -Frameworks $vpnGwControl.frameworks `
                                -Severity $vpnGwControl.severity `
                                -CisLevel $vpnGwControl.level `
                                -CurrentValue $currentValue `
                                -ExpectedValue $vpnGwControl.expectedValue `
                                -Status $gwStatus `
                                -RemediationSteps $vpnGwControl.businessImpact `
                                -RemediationCommand $remediationCmd
                            $findings.Add($finding)
                            
                            # EOL Checking: Check if this VPN Gateway matches any deprecation rules
                            if ($deprecationRules -and $deprecationRules.Count -gt 0) {
                                $mapping = if ($resourceTypeMapping.ContainsKey("Microsoft.Network/virtualNetworkGateways")) {
                                    $resourceTypeMapping["Microsoft.Network/virtualNetworkGateways"]
                                } else {
                                    $null
                                }
                                
                                # Debug: Log gateway SKU for troubleshooting
                                Write-Verbose "VPN Gateway EOL Check: $($gateway.Name), SKU: $skuName, Mapping present: $($null -ne $mapping)"
                                if ($mapping) {
                                    Write-Verbose "VPN Gateway EOL Check: Mapping properties: $($mapping.properties | ConvertTo-Json -Compress)"
                                }
                                
                                $eolStatus = Test-ResourceEOLStatus `
                                    -Resource $gateway `
                                    -ResourceType "Microsoft.Network/virtualNetworkGateways" `
                                    -DeprecationRules $deprecationRules `
                                    -ResourceTypeMapping @{ "Microsoft.Network/virtualNetworkGateways" = $mapping }
                                
                                $ruleComponent = if ($eolStatus.Rule) { $eolStatus.Rule.component } else { 'None' }
                                Write-Verbose "VPN Gateway EOL Check Result: Matched=$($eolStatus.Matched), Severity=$($eolStatus.Severity), Rule=$ruleComponent"
                                
                                if ($eolStatus.Matched -and $eolStatus.Rule) {
                                    $rule = $eolStatus.Rule
                                    
                                    # Map status to ensure compatibility (DeprecationRules uses "Deprecated", "Retiring", "RETIRED")
                                    $mappedStatus = if ($rule.status) {
                                        switch ($rule.status) {
                                            "DEPRECATED" { "Deprecated" }
                                            "ANNOUNCED" { "Retiring" }
                                            "RETIRED" { "RETIRED" }
                                            default { $rule.status }
                                        }
                                    } else {
                                        # If no status in rule, calculate based on deadline
                                        if ($eolStatus.DaysUntilDeadline -lt 0) {
                                            "RETIRED"
                                        } elseif ($eolStatus.DaysUntilDeadline -lt 90) {
                                            "Deprecated"
                                        } else {
                                            "Retiring"
                                        }
                                    }
                                    
                                    $eolFinding = New-EOLFinding `
                                        -SubscriptionId $SubscriptionId `
                                        -SubscriptionName $SubscriptionName `
                                        -ResourceGroup $gateway.ResourceGroupName `
                                        -ResourceType "Microsoft.Network/virtualNetworkGateways" `
                                        -ResourceName $gateway.Name `
                                        -ResourceId $gateway.Id `
                                        -Component $rule.component `
                                        -Status $mappedStatus `
                                        -Deadline $eolStatus.Deadline `
                                        -Severity $eolStatus.Severity `
                                        -DaysUntilDeadline $eolStatus.DaysUntilDeadline `
                                        -ActionRequired $rule.actionRequired `
                                        -MigrationGuide $rule.migrationGuide `
                                        -References $(if ($rule.references) { $rule.references } else { @() })
                                    $eolFindings.Add($eolFinding)
                                    Write-Verbose "Added EOL finding for VPN Gateway: $($gateway.Name), Status: $mappedStatus, Severity: $($eolStatus.Severity)"
                                }
                            }
                        }
                    }
                    catch {
                        Write-Verbose "Could not get VPN Gateway $($gwResource.Name): $_"
                    }
                }
            }
        }
        catch {
            Write-Verbose "Could not check VPN Gateways: $_"
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
                    # Track VNet as resource scanned
                    $resourceKey = if ($vnet.Id) { $vnet.Id } else { "$($vnet.ResourceGroupName)/$($vnet.Name)" }
                    if (-not $uniqueResourcesScanned.ContainsKey($resourceKey)) {
                        $uniqueResourcesScanned[$resourceKey] = $true
                    }
                    $controlsEvaluated++
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
                        -Frameworks $ddosControl.frameworks `
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
                foreach ($firewall in $firewalls) {
                    # Track firewall as resource scanned
                    $resourceKey = if ($firewall.Id) { $firewall.Id } else { "$($firewall.ResourceGroupName)/$($firewall.Name)" }
                    if (-not $uniqueResourcesScanned.ContainsKey($resourceKey)) {
                        $uniqueResourcesScanned[$resourceKey] = $true
                    }
                    $controlsEvaluated++
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
                        -Frameworks $threatIntelControl.frameworks `
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
    
    Write-Verbose "Network scan completed. Resources scanned: $($uniqueResourcesScanned.Count), Controls evaluated: $controlsEvaluated, Total findings: $($findings.Count), EOL findings: $($eolFindings.Count)"
    
    # If no resources were found but controls are enabled, log a warning
    if ($uniqueResourcesScanned.Count -eq 0 -and $controls.Count -gt 0) {
        Write-Verbose "No Network resources (NSGs, VNets, Firewalls) found in subscription $SubscriptionName, but $($controls.Count) control(s) are enabled"
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

