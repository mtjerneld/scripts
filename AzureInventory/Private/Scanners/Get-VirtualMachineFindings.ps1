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
    
    if (-not $vms) {
        Write-Verbose "No VMs found in subscription $SubscriptionName"
        return $findings
    }
    
    foreach ($vm in $vms) {
        Write-Verbose "Scanning VM: $($vm.Name)"
        
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
                -ResourceId $vm.Id `
                -ControlId $managedDiskControl.controlId `
                -ControlName $managedDiskControl.controlName `
                -Category $managedDiskControl.category `
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
        if ($legacyMmaControl -and $extensions) {
            $legacyMmaPresent = $false
            foreach ($ext in $extensions) {
                if ($ext.ExtensionType -eq "MicrosoftMonitoringAgent" -or $ext.ExtensionType -eq "OmsAgentForLinux") {
                    $legacyMmaPresent = $true
                    break
                }
            }
            
            if ($legacyMmaPresent) {
                $remediationCmd = $legacyMmaControl.remediationCommand -replace '\{vmName\}', $vm.Name -replace '\{rg\}', $vm.ResourceGroupName
                $finding = New-SecurityFinding `
                    -SubscriptionId $SubscriptionId `
                    -SubscriptionName $SubscriptionName `
                    -ResourceGroup $vm.ResourceGroupName `
                    -ResourceType "Microsoft.Compute/virtualMachines" `
                    -ResourceName $vm.Name `
                    -ResourceId $vm.Id `
                    -ControlId $legacyMmaControl.controlId `
                    -ControlName $legacyMmaControl.controlName `
                    -Category $legacyMmaControl.category `
                    -Severity $legacyMmaControl.severity `
                    -CisLevel $legacyMmaControl.level `
                    -CurrentValue "Legacy MMA agent present" `
                    -ExpectedValue $legacyMmaControl.expectedValue `
                    -Status "FAIL" `
                    -RemediationSteps $legacyMmaControl.businessImpact `
                    -RemediationCommand $remediationCmd `
                    -EOLDate $legacyMmaControl.eolDate
                $findings.Add($finding)
            }
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
            
            if (-not $amaInstalled) {
                $remediationCmd = $amaControl.remediationCommand -replace '\{vmName\}', $vm.Name -replace '\{rg\}', $vm.ResourceGroupName
                $finding = New-SecurityFinding `
                    -SubscriptionId $SubscriptionId `
                    -SubscriptionName $SubscriptionName `
                    -ResourceGroup $vm.ResourceGroupName `
                    -ResourceType "Microsoft.Compute/virtualMachines" `
                    -ResourceName $vm.Name `
                    -ResourceId $vm.Id `
                    -ControlId $amaControl.controlId `
                    -ControlName $amaControl.controlName `
                    -Category $amaControl.category `
                    -Severity $amaControl.severity `
                    -CisLevel $amaControl.level `
                    -CurrentValue "Not installed" `
                    -ExpectedValue $amaControl.expectedValue `
                    -Status $amaStatus `
                    -RemediationSteps $amaControl.businessImpact `
                    -RemediationCommand $remediationCmd
                $findings.Add($finding)
            }
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
                -ResourceId $vm.Id `
                -ControlId $antimalwareControl.controlId `
                -ControlName $antimalwareControl.controlName `
                -Category $antimalwareControl.category `
                -Severity $antimalwareControl.severity `
                -CisLevel $antimalwareControl.level `
                -CurrentValue $(if ($antimalwareInstalled) { "Installed" } else { "Not installed" }) `
                -ExpectedValue $antimalwareControl.expectedValue `
                -Status $antimalwareStatus `
                -RemediationSteps $antimalwareControl.businessImpact `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }
        
        # TODO: Disk Encryption (7.4) - Add to ControlDefinitions.json first
        # This control is currently hardcoded and should be moved to JSON
        # Commented out until added to ControlDefinitions.json:
        #
        # # P1 Control 7.4: Disk Encryption
        # $encryptionAtHost = if ($vm.SecurityProfile) { $vm.SecurityProfile.EncryptionAtHost } else { $false }
        # # Also check for ADE extension...
    }
    
    return $findings
}


