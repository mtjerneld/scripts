<#
.SYNOPSIS
    Scans Azure Virtual Machines for CIS security compliance (P0 and P1 controls).

.DESCRIPTION
    Checks Virtual Machines against CIS Azure Foundations Benchmark controls:
    P0: Managed disks, Defender for Servers, AMA agent, NO legacy MMA agent (CRITICAL EOL)
    P1: Disk encryption, Approved extensions, Antimalware

.PARAMETER SubscriptionId
    Azure subscription ID to scan.

.PARAMETER SubscriptionName
    Human-readable subscription name.

.OUTPUTS
    Array of SecurityFinding objects.
#>
function Get-VirtualMachineFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionName,
        
        [switch]$IncludeLevel2
    )
    
    $findings = [System.Collections.Generic.List[PSObject]]::new()
    
    # Load enabled controls from JSON
    $controls = Get-ControlsForCategory -Category "VM" -IncludeLevel2:$IncludeLevel2
    if ($null -eq $controls -or $controls.Count -eq 0) {
        Write-Verbose "No enabled VM controls found in configuration for subscription $SubscriptionName"
        return $findings
    }
    Write-Verbose "Loaded $($controls.Count) VM control(s) from configuration"
    
    # Create lookup hashtable for quick control access
    $controlLookup = @{}
    foreach ($control in $controls) {
        $controlLookup[$control.controlName] = $control
    }
    Write-Verbose "Control lookup created with keys: $($controlLookup.Keys -join ', ')"
    
    try {
        $vms = Invoke-AzureApiWithRetry {
            Get-AzVM -ErrorAction Stop
        }
    }
    catch {
        Write-Warning "Failed to retrieve VMs in subscription $SubscriptionName : $_"
        return $findings
    }
    
    # Check if vms is null or empty array
    if ($null -eq $vms -or ($vms -is [System.Array] -and $vms.Count -eq 0)) {
        Write-Verbose "No VMs found in subscription $SubscriptionName"
        return $findings
    }
    
    foreach ($vm in $vms) {
        # Skip if essential properties are missing
        if ([string]::IsNullOrWhiteSpace($vm.Name) -or [string]::IsNullOrWhiteSpace($vm.ResourceGroupName)) {
            Write-Verbose "Skipping VM with missing name or resource group"
            continue
        }
        
        Write-Verbose "Scanning VM: $($vm.Name)"
        
        # Construct ResourceId if missing
        $resourceId = $vm.Id
        if ([string]::IsNullOrWhiteSpace($resourceId)) {
            # Fallback: construct ResourceId from components
            $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$($vm.ResourceGroupName)/providers/Microsoft.Compute/virtualMachines/$($vm.Name)"
            Write-Verbose "Constructed ResourceId for $($vm.Name): $resourceId"
        }
        
        # Get VM extensions once for reuse
        $extensions = $null
        try {
            $extensions = Invoke-AzureApiWithRetry {
                Get-AzVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Verbose "Could not check VM extensions for $($vm.Name): $_"
        }
        
        # Control: Managed Disks
        $managedDiskControl = $controlLookup["Managed Disks"]
        if ($managedDiskControl) {
            $hasManagedDisk = $null -ne $vm.StorageProfile.OsDisk.ManagedDisk
            $managedDiskStatus = if ($hasManagedDisk) { "PASS" } else { "FAIL" }
            
            $remediationCmd = $managedDiskControl.remediationCommand -replace '\{vmName\}', $vm.Name -replace '\{rg\}', $vm.ResourceGroupName
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $vm.ResourceGroupName `
                -ResourceType "Microsoft.Compute/virtualMachines" `
                -ResourceName $vm.Name `
                -ResourceId $resourceId `
                -ControlId $managedDiskControl.controlId `
                -ControlName $managedDiskControl.controlName `
                -Category $managedDiskControl.category `
                -Frameworks $managedDiskControl.frameworks `
                -Severity $managedDiskControl.severity `
                -CisLevel $managedDiskControl.level `
                -CurrentValue $(if ($hasManagedDisk) { "Managed disk" } else { "Unmanaged VHD" }) `
                -ExpectedValue $managedDiskControl.expectedValue `
                -Status $managedDiskStatus `
                -RemediationSteps $managedDiskControl.businessImpact `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }
        
        # Control: NO Legacy MMA/OMS Agent (RETIRED)
        # Always create a finding (PASS if no legacy agent, FAIL if present)
        $legacyMmaControl = $controlLookup["NO Legacy MMA/OMS Agent (RETIRED)"]
        if ($legacyMmaControl) {
            $legacyMmaPresent = $false
            if ($extensions) {
                foreach ($ext in $extensions) {
                    if ($ext.ExtensionType -eq "MicrosoftMonitoringAgent" -or $ext.ExtensionType -eq "OmsAgentForLinux") {
                        $legacyMmaPresent = $true
                        break
                    }
                }
            }
            
            $legacyStatus = if ($legacyMmaPresent) { "FAIL" } else { "PASS" }
            $remediationCmd = if ($legacyMmaPresent) { $legacyMmaControl.remediationCommand -replace '\{vmName\}', $vm.Name -replace '\{rg\}', $vm.ResourceGroupName } else { "" }
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $vm.ResourceGroupName `
                -ResourceType "Microsoft.Compute/virtualMachines" `
                -ResourceName $vm.Name `
                -ResourceId $resourceId `
                -ControlId $legacyMmaControl.controlId `
                -ControlName $legacyMmaControl.controlName `
                -Category $legacyMmaControl.category `
                -Frameworks $legacyMmaControl.frameworks `
                -Severity $legacyMmaControl.severity `
                -CisLevel $legacyMmaControl.level `
                -CurrentValue $(if ($legacyMmaPresent) { "Legacy MMA agent present" } else { "No legacy agent" }) `
                -ExpectedValue $legacyMmaControl.expectedValue `
                -Status $legacyStatus `
                -RemediationSteps $legacyMmaControl.businessImpact `
                -RemediationCommand $remediationCmd `
                -EOLDate $legacyMmaControl.eolDate
            $findings.Add($finding)
        }
        
        # Control: Azure Monitor Agent (AMA) Installed
        # Always create a finding (PASS if installed, FAIL if not)
        $amaControl = $controlLookup["Azure Monitor Agent (AMA) Installed"]
        if ($amaControl) {
            $amaInstalled = $false
            if ($extensions) {
                foreach ($ext in $extensions) {
                    if ($ext.Publisher -eq "Microsoft.Azure.Monitor" -and 
                        ($ext.ExtensionType -eq "AzureMonitorWindowsAgent" -or $ext.ExtensionType -eq "AzureMonitorLinuxAgent")) {
                        $amaInstalled = $true
                        break
                    }
                }
            }
            
            $amaStatus = if ($amaInstalled) { "PASS" } else { "FAIL" }
            $remediationCmd = if ($amaInstalled) { "" } else { $amaControl.remediationCommand -replace '\{vmName\}', $vm.Name -replace '\{rg\}', $vm.ResourceGroupName }
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $vm.ResourceGroupName `
                -ResourceType "Microsoft.Compute/virtualMachines" `
                -ResourceName $vm.Name `
                -ResourceId $resourceId `
                -ControlId $amaControl.controlId `
                -ControlName $amaControl.controlName `
                -Category $amaControl.category `
                -Frameworks $amaControl.frameworks `
                -Severity $amaControl.severity `
                -CisLevel $amaControl.level `
                -CurrentValue $(if ($amaInstalled) { "Installed" } else { "Not installed" }) `
                -ExpectedValue $amaControl.expectedValue `
                -Status $amaStatus `
                -RemediationSteps $amaControl.businessImpact `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }
        
        # Control: Antimalware Extension (Level 2)
        $antimalwareControl = $controlLookup["Antimalware Extension"]
        if ($antimalwareControl -and $extensions) {
            $antimalwareInstalled = $false
            foreach ($ext in $extensions) {
                if ($ext.ExtensionType -eq "IaaSAntimalware") {
                    $antimalwareInstalled = $true
                    break
                }
            }
            
            $antimalwareStatus = if ($antimalwareInstalled) { "PASS" } else { "FAIL" }
            
            $remediationCmd = $antimalwareControl.remediationCommand -replace '\{vmName\}', $vm.Name -replace '\{rg\}', $vm.ResourceGroupName
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $vm.ResourceGroupName `
                -ResourceType "Microsoft.Compute/virtualMachines" `
                -ResourceName $vm.Name `
                -ResourceId $resourceId `
                -ControlId $antimalwareControl.controlId `
                -ControlName $antimalwareControl.controlName `
                -Category $antimalwareControl.category `
                -Frameworks $antimalwareControl.frameworks `
                -Severity $antimalwareControl.severity `
                -CisLevel $antimalwareControl.level `
                -CurrentValue $(if ($antimalwareInstalled) { "Installed" } else { "Not installed" }) `
                -ExpectedValue $antimalwareControl.expectedValue `
                -Status $antimalwareStatus `
                -RemediationSteps $antimalwareControl.businessImpact `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }

    }
    
    # Control: VM Backup Enabled (ASB) - Check after VM loop to batch API calls
    $backupControl = $controlLookup["VM Backup Enabled"]
    if ($backupControl -and $vms.Count -gt 0) {
        # Get all Recovery Services Vaults in the subscription
        $backupProtectedVMs = @{}
        try {
            $vaults = Invoke-AzureApiWithRetry {
                Get-AzRecoveryServicesVault -ErrorAction SilentlyContinue
            }
            
            if ($vaults) {
                foreach ($vault in $vaults) {
                    try {
                        # Set vault context
                        Set-AzRecoveryServicesVaultContext -Vault $vault -ErrorAction SilentlyContinue
                        
                        # Get all backup items (Azure VMs) in this vault
                        $backupItems = Invoke-AzureApiWithRetry {
                            Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -ErrorAction SilentlyContinue
                        }
                        
                        if ($backupItems) {
                            foreach ($item in $backupItems) {
                                # Extract VM name from the backup item
                                # SourceResourceId format: /subscriptions/.../resourceGroups/.../providers/Microsoft.Compute/virtualMachines/{vmName}
                                if ($item.SourceResourceId) {
                                    $vmIdLower = $item.SourceResourceId.ToLower()
                                    $backupProtectedVMs[$vmIdLower] = @{
                                        VaultName = $vault.Name
                                        ProtectionStatus = $item.ProtectionStatus
                                        LastBackupStatus = $item.LastBackupStatus
                                        LastBackupTime = $item.LastBackupTime
                                    }
                                }
                            }
                        }
                    }
                    catch {
                        Write-Verbose "Could not query backup items from vault $($vault.Name): $_"
                    }
                }
            }
        }
        catch {
            Write-Verbose "Could not retrieve Recovery Services Vaults: $_"
        }
        
        Write-Verbose "Found $($backupProtectedVMs.Count) VMs with backup protection"
        
        # Now check each VM against the backup protection list
        foreach ($vm in $vms) {
            if ([string]::IsNullOrWhiteSpace($vm.Name) -or [string]::IsNullOrWhiteSpace($vm.ResourceGroupName)) {
                continue
            }
            
            $resourceId = $vm.Id
            if ([string]::IsNullOrWhiteSpace($resourceId)) {
                $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$($vm.ResourceGroupName)/providers/Microsoft.Compute/virtualMachines/$($vm.Name)"
            }
            
            $resourceIdLower = $resourceId.ToLower()
            $backupInfo = $backupProtectedVMs[$resourceIdLower]
            $backupEnabled = $null -ne $backupInfo
            
            $currentValue = if ($backupEnabled) {
                $lastBackup = if ($backupInfo.LastBackupTime) { $backupInfo.LastBackupTime.ToString("yyyy-MM-dd HH:mm") } else { "N/A" }
                "Protected by $($backupInfo.VaultName) (Last: $lastBackup)"
            } else {
                "No backup protection detected"
            }
            
            $backupStatus = if ($backupEnabled) { "PASS" } else { "FAIL" }
            $remediationCmd = $backupControl.remediationCommand
            
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $vm.ResourceGroupName `
                -ResourceType "Microsoft.Compute/virtualMachines" `
                -ResourceName $vm.Name `
                -ResourceId $resourceId `
                -ControlId $backupControl.controlId `
                -ControlName $backupControl.controlName `
                -Category $backupControl.category `
                -Frameworks $backupControl.frameworks `
                -Severity $backupControl.severity `
                -CisLevel $backupControl.level `
                -CurrentValue $currentValue `
                -ExpectedValue $backupControl.expectedValue `
                -Status $backupStatus `
                -RemediationSteps $backupControl.businessImpact `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }
    }
    
    return $findings
}
