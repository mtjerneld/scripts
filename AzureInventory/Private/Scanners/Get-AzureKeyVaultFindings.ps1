<#
.SYNOPSIS
    Scans Azure Key Vaults for CIS security compliance.

.DESCRIPTION
    Checks Key Vaults against CIS Azure Foundations Benchmark controls:
    - Purge Protection Enabled
    - Soft Delete Enabled
    - RBAC Authorization
    - Firewall Rules (Default Deny)

.PARAMETER SubscriptionId
    Azure subscription ID to scan.

.PARAMETER SubscriptionName
    Human-readable subscription name.

.PARAMETER IncludeLevel2
    Include Level 2 controls in the scan.

.OUTPUTS
    Array of SecurityFinding objects.
#>
function Get-AzureKeyVaultFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionName,
        
        [switch]$IncludeLevel2
    )
    
    $findings = [System.Collections.Generic.List[PSObject]]::new()
    $eolFindings = [System.Collections.Generic.List[PSObject]]::new()
    
    # Track metadata for consolidated output
    $uniqueResourcesScanned = @{}
    $controlsEvaluated = 0
    
    # Load enabled controls from JSON
    $controls = Get-ControlsForCategory -Category "KeyVault" -IncludeLevel2:$IncludeLevel2
    if ($null -eq $controls -or $controls.Count -eq 0) {
        Write-Verbose "No enabled KeyVault controls found in configuration for subscription $SubscriptionName"
        return @{
            Findings = $findings
            EOLFindings = $eolFindings
            ResourceCount = 0
            ControlCount = 0
            FailureCount = 0
            EOLCount = 0
        }
    }
    Write-Verbose "Loaded $($controls.Count) KeyVault control(s) from configuration"
    
    # Create lookup hashtable for quick control access
    $controlLookup = @{}
    foreach ($control in $controls) {
        $controlLookup[$control.controlName] = $control
    }
    
    try {
        $vaults = Invoke-AzureApiWithRetry {
            Get-AzKeyVault -ErrorAction Stop
        }
    }
    catch {
        Write-Warning "Failed to retrieve Key Vaults in subscription $SubscriptionName : $_"
        return @{
            Findings = $findings
            EOLFindings = $eolFindings
            ResourceCount = 0
            ControlCount = 0
            FailureCount = 0
            EOLCount = 0
        }
    }
    
    if (-not $vaults -or @($vaults).Count -eq 0) {
        Write-Verbose "No Key Vaults found in subscription $SubscriptionName"
        return @{
            Findings = $findings
            EOLFindings = $eolFindings
            ResourceCount = 0
            ControlCount = 0
            FailureCount = 0
            EOLCount = 0
        }
    }
    
    foreach ($vault in $vaults) {
        Write-Verbose "Scanning Key Vault: $($vault.VaultName)"
        
        # Track this resource as scanned
        $resourceKey = if ($vault.Id) { $vault.Id } else { "$($vault.ResourceGroupName)/$($vault.VaultName)" }
        if (-not $uniqueResourcesScanned.ContainsKey($resourceKey)) {
            $uniqueResourcesScanned[$resourceKey] = $true
        }
        
        # 1. Purge Protection
        $purgeControl = $controlLookup["Key Vault Purge Protection"]
        if ($purgeControl) {
            $controlsEvaluated++
            $purgeProtection = if ($vault.EnablePurgeProtection) { $true } else { $false }
            $status = if ($purgeProtection) { "PASS" } else { "FAIL" }
            
            $remediationCmd = $purgeControl.remediationCommand -replace '\{name\}', $vault.VaultName -replace '\{rg\}', $vault.ResourceGroupName
            
            $findings.Add((New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $vault.ResourceGroupName `
                -ResourceType "Microsoft.KeyVault/vaults" `
                -ResourceName $vault.VaultName `
                -ResourceId $vault.ResourceId `
                -ControlId $purgeControl.controlId `
                -ControlName $purgeControl.controlName `
                -Category $purgeControl.category `
                -Frameworks $purgeControl.frameworks `
                -Severity $purgeControl.severity `
                -CisLevel $purgeControl.level `
                -CurrentValue $(if ($purgeProtection) { "Enabled" } else { "Disabled" }) `
                -ExpectedValue $purgeControl.expectedValue `
                -Status $status `
                -RemediationSteps $purgeControl.businessImpact `
                -RemediationCommand $remediationCmd))
        }

        # 2. Soft Delete
        $softDeleteControl = $controlLookup["Key Vault Soft Delete"]
        if ($softDeleteControl) {
            $controlsEvaluated++
            # Soft delete is enabled by default in newer API versions and can't be disabled, 
            # but older vaults might not have it. The property is usually EnableSoftDelete.
            $softDelete = if ($vault.EnableSoftDelete) { $true } else { $false }
            $status = if ($softDelete) { "PASS" } else { "FAIL" }
            
            $remediationCmd = $softDeleteControl.remediationCommand -replace '\{name\}', $vault.VaultName -replace '\{rg\}', $vault.ResourceGroupName
            
            $findings.Add((New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $vault.ResourceGroupName `
                -ResourceType "Microsoft.KeyVault/vaults" `
                -ResourceName $vault.VaultName `
                -ResourceId $vault.ResourceId `
                -ControlId $softDeleteControl.controlId `
                -ControlName $softDeleteControl.controlName `
                -Category $softDeleteControl.category `
                -Frameworks $softDeleteControl.frameworks `
                -Severity $softDeleteControl.severity `
                -CisLevel $softDeleteControl.level `
                -CurrentValue $(if ($softDelete) { "Enabled" } else { "Disabled" }) `
                -ExpectedValue $softDeleteControl.expectedValue `
                -Status $status `
                -RemediationSteps $softDeleteControl.businessImpact `
                -RemediationCommand $remediationCmd))
        }

        # 3. RBAC Authorization
        $rbacControl = $controlLookup["Key Vault RBAC"]
        if ($rbacControl) {
            $controlsEvaluated++
            $rbac = if ($vault.EnableRbacAuthorization) { $true } else { $false }
            $status = if ($rbac) { "PASS" } else { "FAIL" }
            
            $remediationCmd = $rbacControl.remediationCommand -replace '\{name\}', $vault.VaultName -replace '\{rg\}', $vault.ResourceGroupName
            
            $findings.Add((New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $vault.ResourceGroupName `
                -ResourceType "Microsoft.KeyVault/vaults" `
                -ResourceName $vault.VaultName `
                -ResourceId $vault.ResourceId `
                -ControlId $rbacControl.controlId `
                -ControlName $rbacControl.controlName `
                -Category $rbacControl.category `
                -Frameworks $rbacControl.frameworks `
                -Severity $rbacControl.severity `
                -CisLevel $rbacControl.level `
                -CurrentValue $(if ($rbac) { "RBAC" } else { "Access Policies" }) `
                -ExpectedValue $rbacControl.expectedValue `
                -Status $status `
                -RemediationSteps $rbacControl.businessImpact `
                -RemediationCommand $remediationCmd))
        }

        # 4. Firewall (Network Acls)
        $firewallControl = $controlLookup["Key Vault Firewall"]
        if ($firewallControl) {
            $controlsEvaluated++
            $defaultAction = if ($vault.NetworkRuleSet -and $vault.NetworkRuleSet.DefaultAction) { $vault.NetworkRuleSet.DefaultAction } else { "Allow" }
            $status = if ($defaultAction -eq "Deny") { "PASS" } else { "FAIL" }
            
            $remediationCmd = $firewallControl.remediationCommand -replace '\{name\}', $vault.VaultName -replace '\{rg\}', $vault.ResourceGroupName
            
            $findings.Add((New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $vault.ResourceGroupName `
                -ResourceType "Microsoft.KeyVault/vaults" `
                -ResourceName $vault.VaultName `
                -ResourceId $vault.ResourceId `
                -ControlId $firewallControl.controlId `
                -ControlName $firewallControl.controlName `
                -Category $firewallControl.category `
                -Frameworks $firewallControl.frameworks `
                -Severity $firewallControl.severity `
                -CisLevel $firewallControl.level `
                -CurrentValue $defaultAction `
                -ExpectedValue $firewallControl.expectedValue `
                -Status $status `
                -RemediationSteps $firewallControl.businessImpact `
                -RemediationCommand $remediationCmd))
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





