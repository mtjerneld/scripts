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

        # Determine if vault uses RBAC
        $usesRbac = if ($vault.EnableRbacAuthorization) { $true } else { $false }

        # Control: Expiration Date Set for All Keys (RBAC or Non-RBAC)
        $keysRbacControl = $controlLookup["Expiration Date Set for All Keys in RBAC Key Vaults"]
        $keysNonRbacControl = $controlLookup["Expiration Date Set for All Keys in Non-RBAC Key Vaults"]

        if (($usesRbac -and $keysRbacControl) -or (-not $usesRbac -and $keysNonRbacControl)) {
            $controlsEvaluated++
            $control = if ($usesRbac) { $keysRbacControl } else { $keysNonRbacControl }
            $allKeysHaveExpiration = $true
            $keyCount = 0
            $keysWithoutExpiration = 0
            $status = "PASS"
            
            try {
                $keys = Invoke-AzureApiWithRetry {
                    Get-AzKeyVaultKey -VaultName $vault.VaultName -ErrorAction SilentlyContinue
                }
                if ($keys) {
                    $keyCount = @($keys).Count
                    foreach ($key in $keys) {
                        if (-not $key.ExpiresOn) {
                            $allKeysHaveExpiration = $false
                            $keysWithoutExpiration++
                        }
                    }
                }
            }
            catch {
                Write-Verbose "Could not check key expiration for vault $($vault.VaultName): $_"
                $allKeysHaveExpiration = $false
                $status = "ERROR"
            }
            
            if ($status -ne "ERROR") {
                $status = if ($allKeysHaveExpiration) { "PASS" } else { "FAIL" }
            }
            
            $currentValue = if ($status -eq "ERROR") { 
                "Unable to check (access denied or vault unavailable)" 
            } elseif ($keyCount -eq 0) {
                "No keys found"
            } elseif ($allKeysHaveExpiration) {
                "All $keyCount key(s) have expiration dates"
            } else {
                "$keysWithoutExpiration of $keyCount key(s) missing expiration dates"
            }
            
            $remediationCmd = $control.remediationCommand -replace '\{name\}', $vault.VaultName -replace '\{rg\}', $vault.ResourceGroupName
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $vault.ResourceGroupName `
                -ResourceType "Microsoft.KeyVault/vaults" `
                -ResourceName $vault.VaultName `
                -ResourceId $vault.ResourceId `
                -ControlId $control.controlId `
                -ControlName $control.controlName `
                -Category $control.category `
                -Frameworks $control.frameworks `
                -Severity $control.severity `
                -CisLevel $control.level `
                -CurrentValue $currentValue `
                -ExpectedValue $control.expectedValue `
                -Status $status `
                -RemediationSteps $control.businessImpact `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }

        # Control: Expiration Date Set for All Secrets (RBAC or Non-RBAC)
        $secretsRbacControl = $controlLookup["Expiration Date Set for All Secrets in RBAC Key Vaults"]
        $secretsNonRbacControl = $controlLookup["Expiration Date Set for All Secrets in Non-RBAC Key Vaults"]

        if (($usesRbac -and $secretsRbacControl) -or (-not $usesRbac -and $secretsNonRbacControl)) {
            $controlsEvaluated++
            $control = if ($usesRbac) { $secretsRbacControl } else { $secretsNonRbacControl }
            $allSecretsHaveExpiration = $true
            $secretCount = 0
            $secretsWithoutExpiration = 0
            $status = "PASS"
            
            try {
                $secrets = Invoke-AzureApiWithRetry {
                    Get-AzKeyVaultSecret -VaultName $vault.VaultName -ErrorAction SilentlyContinue
                }
                if ($secrets) {
                    $secretCount = @($secrets).Count
                    foreach ($secret in $secrets) {
                        if (-not $secret.ExpiresOn) {
                            $allSecretsHaveExpiration = $false
                            $secretsWithoutExpiration++
                        }
                    }
                }
            }
            catch {
                Write-Verbose "Could not check secret expiration for vault $($vault.VaultName): $_"
                $allSecretsHaveExpiration = $false
                $status = "ERROR"
            }
            
            if ($status -ne "ERROR") {
                $status = if ($allSecretsHaveExpiration) { "PASS" } else { "FAIL" }
            }
            
            $currentValue = if ($status -eq "ERROR") { 
                "Unable to check (access denied or vault unavailable)" 
            } elseif ($secretCount -eq 0) {
                "No secrets found"
            } elseif ($allSecretsHaveExpiration) {
                "All $secretCount secret(s) have expiration dates"
            } else {
                "$secretsWithoutExpiration of $secretCount secret(s) missing expiration dates"
            }
            
            $remediationCmd = $control.remediationCommand -replace '\{name\}', $vault.VaultName -replace '\{rg\}', $vault.ResourceGroupName
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $vault.ResourceGroupName `
                -ResourceType "Microsoft.KeyVault/vaults" `
                -ResourceName $vault.VaultName `
                -ResourceId $vault.ResourceId `
                -ControlId $control.controlId `
                -ControlName $control.controlName `
                -Category $control.category `
                -Frameworks $control.frameworks `
                -Severity $control.severity `
                -CisLevel $control.level `
                -CurrentValue $currentValue `
                -ExpectedValue $control.expectedValue `
                -Status $status `
                -RemediationSteps $control.businessImpact `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
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





