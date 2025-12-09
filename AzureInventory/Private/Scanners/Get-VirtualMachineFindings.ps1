<#
.SYNOPSIS
    Scans Azure Virtual Machines for CIS security compliance and collects inventory data.

.DESCRIPTION
    Checks Virtual Machines against CIS Azure Foundations Benchmark controls:
    P0: Managed disks, Defender for Servers, AMA agent, NO legacy MMA agent (CRITICAL EOL)
    P1: Disk encryption, Approved extensions, Antimalware
    
    Also collects VM inventory data including backup status and power state for reporting.

.PARAMETER SubscriptionId
    Azure subscription ID to scan.

.PARAMETER SubscriptionName
    Human-readable subscription name.

.OUTPUTS
    PSCustomObject with:
    - Findings: Array of SecurityFinding objects
    - Inventory: Array of VM inventory objects (for backup/inventory reports)
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
    $inventory = [System.Collections.Generic.List[PSObject]]::new()
    
    # Load enabled controls from JSON
    $controls = Get-ControlsForCategory -Category "VM" -IncludeLevel2:$IncludeLevel2
    if ($null -eq $controls -or $controls.Count -eq 0) {
        Write-Verbose "No enabled VM controls found in configuration for subscription $SubscriptionName"
        return [PSCustomObject]@{
            Findings  = $findings
            Inventory = $inventory
        }
    }
    Write-Verbose "Loaded $($controls.Count) VM control(s) from configuration"
    
    # Create lookup hashtable for quick control access
    $controlLookup = @{}
    foreach ($control in $controls) {
        $controlLookup[$control.controlName] = $control
    }
    Write-Verbose "Control lookup created with keys: $($controlLookup.Keys -join ', ')"
    
    # Get VMs with status (includes power state)
    try {
        $vms = Invoke-AzureApiWithRetry {
            Get-AzVM -Status -ErrorAction Stop
        }
    }
    catch {
        Write-Warning "Failed to retrieve VMs in subscription $SubscriptionName : $_"
        return [PSCustomObject]@{
            Findings  = $findings
            Inventory = $inventory
        }
    }
    
    # Check if vms is null or empty array
    if ($null -eq $vms -or ($vms -is [System.Array] -and $vms.Count -eq 0)) {
        Write-Verbose "No VMs found in subscription $SubscriptionName"
        return [PSCustomObject]@{
            Findings  = $findings
            Inventory = $inventory
        }
    }
    
    # Get backup protection info for all VMs (batch API calls)
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
                            if ($item.SourceResourceId) {
                                $vmIdLower = $item.SourceResourceId.ToLower()
                                $backupProtectedVMs[$vmIdLower] = @{
                                    VaultName        = $vault.Name
                                    VaultId          = $vault.ID
                                    ProtectionStatus = $item.ProtectionStatus
                                    LastBackupStatus = $item.LastBackupStatus
                                    LastBackupTime   = $item.LastBackupTime
                                    PolicyName       = $item.ProtectionPolicyName
                                    HealthStatus     = $item.HealthStatus
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
            $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$($vm.ResourceGroupName)/providers/Microsoft.Compute/virtualMachines/$($vm.Name)"
            Write-Verbose "Constructed ResourceId for $($vm.Name): $resourceId"
        }
        
        # Parse power state - Get-AzVM -Status returns PowerState directly or in InstanceView
        $powerState = 'unknown'
        $provisioningState = 'unknown'
        
        # Try direct PowerState property first (most common with -Status flag)
        if ($vm.PowerState) {
            # PowerState is like "VM running" or "VM deallocated"
            $powerState = ($vm.PowerState -replace '^VM ', '').ToLower()
        }
        # Try InstanceView.Statuses (alternative location)
        elseif ($vm.InstanceView -and $vm.InstanceView.Statuses) {
            $powerStatus = $vm.InstanceView.Statuses | Where-Object { $_.Code -like 'PowerState/*' }
            if ($powerStatus) {
                $powerState = ($powerStatus.Code -replace 'PowerState/', '').ToLower()
            }
            $provStatus = $vm.InstanceView.Statuses | Where-Object { $_.Code -like 'ProvisioningState/*' }
            if ($provStatus) {
                $provisioningState = ($provStatus.Code -replace 'ProvisioningState/', '').ToLower()
            }
        }
        # Fallback: try Statuses directly on VM object
        elseif ($vm.Statuses) {
            $powerStatus = $vm.Statuses | Where-Object { $_.Code -like 'PowerState/*' }
            if ($powerStatus) {
                $powerState = ($powerStatus.Code -replace 'PowerState/', '').ToLower()
            }
        }
        
        Write-Verbose "VM $($vm.Name): PowerState=$powerState (raw: $($vm.PowerState))"
        
        # Detect OS type with multiple fallback methods (important for deallocated VMs)
        $osType = "Unknown"
        
        # Method 1: Check OSProfile (works when VM is running)
        if ($vm.OSProfile) {
            if ($vm.OSProfile.WindowsConfiguration) {
                $osType = "Windows"
            }
            elseif ($vm.OSProfile.LinuxConfiguration) {
                $osType = "Linux"
            }
        }
        
        # Method 2: Check StorageProfile.OsDisk.OsType (available even when deallocated)
        if ($osType -eq "Unknown" -and $vm.StorageProfile -and $vm.StorageProfile.OsDisk -and $vm.StorageProfile.OsDisk.OsType) {
            $osType = $vm.StorageProfile.OsDisk.OsType
        }
        
        # Method 3: Check ImageReference (can indicate OS type from image publisher/offer)
        if ($osType -eq "Unknown" -and $vm.StorageProfile -and $vm.StorageProfile.ImageReference) {
            $imageRef = $vm.StorageProfile.ImageReference
            $publisher = if ($imageRef.Publisher) { $imageRef.Publisher.ToLower() } else { "" }
            $offer = if ($imageRef.Offer) { $imageRef.Offer.ToLower() } else { "" }
            
            # Common Windows publishers/offers
            if ($publisher -match 'microsoft' -and ($offer -match 'windows' -or $offer -match 'sql' -or $offer -match 'visual-studio')) {
                $osType = "Windows"
            }
            # Common Linux publishers/offers
            elseif ($publisher -match 'canonical' -or $publisher -match 'redhat' -or $publisher -match 'suse' -or 
                    $publisher -match 'debian' -or $publisher -match 'oracle' -or $publisher -match 'openlogic' -or
                    $offer -match 'ubuntu' -or $offer -match 'rhel' -or $offer -match 'sles' -or $offer -match 'debian' -or $offer -match 'centos') {
                $osType = "Linux"
            }
        }
        
        # Method 4: Check OsDisk.Image (if VM was created from image)
        if ($osType -eq "Unknown" -and $vm.StorageProfile -and $vm.StorageProfile.OsDisk -and $vm.StorageProfile.OsDisk.Image) {
            $imageUri = $vm.StorageProfile.OsDisk.Image.Uri
            if ($imageUri) {
                # Check if image URI contains Windows or Linux indicators
                if ($imageUri -match 'windows|win|microsoft') {
                    $osType = "Windows"
                }
                elseif ($imageUri -match 'linux|ubuntu|rhel|sles|debian|centos') {
                    $osType = "Linux"
                }
            }
        }
        
        Write-Verbose "VM $($vm.Name): OsType=$osType (PowerState=$powerState)"
        
        # Get backup info for this VM
        $resourceIdLower = $resourceId.ToLower()
        $backupInfo = $backupProtectedVMs[$resourceIdLower]
        $backupEnabled = $null -ne $backupInfo
        
        # Build inventory entry
        $vmInventory = [PSCustomObject]@{
            SubscriptionId     = $SubscriptionId
            SubscriptionName   = $SubscriptionName
            VMName             = $vm.Name
            ResourceGroup      = $vm.ResourceGroupName
            ResourceId         = $resourceId
            Location           = $vm.Location
            VMSize             = $vm.HardwareProfile.VmSize
            OsType             = $osType
            PowerState         = $powerState
            ProvisioningState  = $provisioningState
            BackupEnabled      = $backupEnabled
            VaultName          = if ($backupInfo) { $backupInfo.VaultName } else { $null }
            ProtectionStatus   = if ($backupInfo) { $backupInfo.ProtectionStatus } else { $null }
            LastBackupStatus   = if ($backupInfo) { $backupInfo.LastBackupStatus } else { $null }
            LastBackupTime     = if ($backupInfo) { $backupInfo.LastBackupTime } else { $null }
            PolicyName         = if ($backupInfo) { $backupInfo.PolicyName } else { $null }
            HealthStatus       = if ($backupInfo) { $backupInfo.HealthStatus } else { $null }
        }
        $inventory.Add($vmInventory)
        
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
            # Only set EOLDate if legacy agent is actually present (FAIL status)
            # This ensures deprecated-components table only shows VMs that actually have the deprecated agent
            $eolDate = if ($legacyMmaPresent) { $legacyMmaControl.eolDate } else { $null }
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
                -EOLDate $eolDate
            $findings.Add($finding)
        }
        
        # Control: Azure Monitor Agent (AMA) Installed
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
        
        # Control: VM Backup Enabled (ASB)
        $backupControl = $controlLookup["VM Backup Enabled"]
        if ($backupControl) {
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
    
    # Return both findings and inventory
    return [PSCustomObject]@{
        Findings  = $findings
        Inventory = $inventory
    }
}
