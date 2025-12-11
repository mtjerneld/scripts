<#
.SYNOPSIS
    Scans Azure Storage Accounts for CIS security compliance (Level 1 and Level 2 controls).

.DESCRIPTION
    Checks Storage Accounts against CIS Azure Foundations Benchmark controls:
    Level 1 (L1): TLS 1.2, HTTPS only, Public blob access, Network default deny
    Level 2 (L2): Infrastructure encryption, Azure services bypass, Customer-Managed Keys (for critical data only)

.PARAMETER SubscriptionId
    Azure subscription ID to scan.

.PARAMETER SubscriptionName
    Human-readable subscription name.

.PARAMETER IncludeLevel2
    Include Level 2 controls in the scan. Level 2 controls are recommended only for critical data or high-security environments.

.PARAMETER CriticalStorageAccounts
    Array of storage account names that contain critical data. Used for Level 2 CMK control (3.12).

.OUTPUTS
    Array of SecurityFinding objects.
#>
function Get-StorageAccountFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionName,
        
        [switch]$IncludeLevel2,
        
        [string[]]$CriticalStorageAccounts = @()
    )
    
    $findings = [System.Collections.Generic.List[PSObject]]::new()
    
    # Load enabled controls from JSON
    $controls = Get-ControlsForCategory -Category "Storage" -IncludeLevel2:$IncludeLevel2
    if ($null -eq $controls -or $controls.Count -eq 0) {
        Write-Verbose "No enabled Storage controls found in configuration for subscription $SubscriptionName"
        return $findings
    }
    Write-Verbose "Loaded $($controls.Count) Storage control(s) from configuration"
    
    # Create lookup hashtable for quick control access
    $controlLookup = @{}
    foreach ($control in $controls) {
        $controlLookup[$control.controlName] = $control
    }
    Write-Verbose "Control lookup created with keys: $($controlLookup.Keys -join ', ')"
    
    try {
        $storageAccounts = Invoke-AzureApiWithRetry {
            Get-AzStorageAccount -ErrorAction Stop
        }
    }
    catch {
        Write-Warning "Failed to retrieve storage accounts in subscription $SubscriptionName : $_"
        return $findings
    }
    
    # Check if storageAccounts is null or empty array
    if ($null -eq $storageAccounts -or ($storageAccounts -is [System.Array] -and $storageAccounts.Count -eq 0)) {
        Write-Verbose "No storage accounts found in subscription $SubscriptionName"
        return $findings
    }
    
    foreach ($sa in $storageAccounts) {
        # Skip if essential properties are missing
        if ([string]::IsNullOrWhiteSpace($sa.StorageAccountName) -or [string]::IsNullOrWhiteSpace($sa.ResourceGroupName)) {
            Write-Verbose "Skipping storage account with missing name or resource group"
            continue
        }
        
        Write-Verbose "Scanning storage account: $($sa.StorageAccountName)"
        
        # Construct ResourceId if missing
        $resourceId = $sa.Id
        if ([string]::IsNullOrWhiteSpace($resourceId)) {
            # Fallback: construct ResourceId from components
            $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$($sa.ResourceGroupName)/providers/Microsoft.Storage/storageAccounts/$($sa.StorageAccountName)"
            Write-Verbose "Constructed ResourceId for $($sa.StorageAccountName): $resourceId"
        }
        
        # Get network rules once for reuse
        $networkRules = $null
        try {
            $networkRules = Invoke-AzureApiWithRetry {
                Get-AzStorageAccountNetworkRuleSet -ResourceGroupName $sa.ResourceGroupName -Name $sa.StorageAccountName -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Verbose "Could not get network rules for $($sa.StorageAccountName): $_"
        }
        
        # Control: Minimum TLS Version 1.2
        $tlsControl = $controlLookup["Minimum TLS Version 1.2"]
        if ($tlsControl) {
            # Define valid TLS versions explicitly to avoid any scope/loading issues with constants
            $validTlsVersions = @("TLS1_2", "TLS1_3")
            
            # Get TLS version with fallback
            $minTlsVersion = if ($sa.MinimumTlsVersion) { "$($sa.MinimumTlsVersion)" } else { "TLS1_0" }
            
            # Debugging
            Write-Verbose "Storage Account: $($sa.StorageAccountName) - MinimumTlsVersion: '$minTlsVersion'"
            
            $tlsStatus = if ($minTlsVersion -in $validTlsVersions) { "PASS" } else { "FAIL" }
            
            # Check for legacy versions for EOL date
            $legacyVersions = @("TLS1_0", "TLS1_1")
            $eolDate = if ($minTlsVersion -in $legacyVersions) { $tlsControl.eolDate } else { $null }
            
            $remediationCmd = $tlsControl.remediationCommand -replace '\{name\}', $sa.StorageAccountName -replace '\{rg\}', $sa.ResourceGroupName
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $sa.ResourceGroupName `
                -ResourceType "Microsoft.Storage/storageAccounts" `
                -ResourceName $sa.StorageAccountName `
                -ResourceId $resourceId `
                -ControlId $tlsControl.controlId `
                -ControlName $tlsControl.controlName `
                -Category $tlsControl.category `
                -Frameworks $tlsControl.frameworks `
                -Severity $tlsControl.severity `
                -CisLevel $tlsControl.level `
                -CurrentValue $minTlsVersion `
                -ExpectedValue $tlsControl.expectedValue `
                -Status $tlsStatus `
                -RemediationSteps $tlsControl.businessImpact `
                -RemediationCommand $remediationCmd `
                -EOLDate $eolDate
            $findings.Add($finding)
        }
        
        # Control: Secure Transfer Required
        $httpsControl = $controlLookup["Secure Transfer Required"]
        if ($httpsControl) {
            $httpsOnly = if ($sa.EnableHttpsTrafficOnly) { $sa.EnableHttpsTrafficOnly } else { $false }
            $httpsStatus = if ($httpsOnly) { "PASS" } else { "FAIL" }
            
            $remediationCmd = $httpsControl.remediationCommand -replace '\{name\}', $sa.StorageAccountName -replace '\{rg\}', $sa.ResourceGroupName
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $sa.ResourceGroupName `
                -ResourceType "Microsoft.Storage/storageAccounts" `
                -ResourceName $sa.StorageAccountName `
                -ResourceId $resourceId `
                -ControlId $httpsControl.controlId `
                -ControlName $httpsControl.controlName `
                -Category $httpsControl.category `
                -Frameworks $httpsControl.frameworks `
                -Severity $httpsControl.severity `
                -CisLevel $httpsControl.level `
                -CurrentValue $httpsOnly.ToString() `
                -ExpectedValue $httpsControl.expectedValue `
                -Status $httpsStatus `
                -RemediationSteps $httpsControl.businessImpact `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }
        
        # Control: Public Blob Access
        $publicAccessControl = $controlLookup["Public Blob Access"]
        if ($publicAccessControl) {
            $publicAccess = if ($null -ne $sa.AllowBlobPublicAccess) { $sa.AllowBlobPublicAccess } else { $true }
            $publicStatus = if (-not $publicAccess) { "PASS" } else { "FAIL" }
            
            $remediationCmd = $publicAccessControl.remediationCommand -replace '\{name\}', $sa.StorageAccountName -replace '\{rg\}', $sa.ResourceGroupName
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $sa.ResourceGroupName `
                -ResourceType "Microsoft.Storage/storageAccounts" `
                -ResourceName $sa.StorageAccountName `
                -ResourceId $resourceId `
                -ControlId $publicAccessControl.controlId `
                -ControlName $publicAccessControl.controlName `
                -Category $publicAccessControl.category `
                -Frameworks $publicAccessControl.frameworks `
                -Severity $publicAccessControl.severity `
                -CisLevel $publicAccessControl.level `
                -CurrentValue $publicAccess.ToString() `
                -ExpectedValue $publicAccessControl.expectedValue `
                -Status $publicStatus `
                -RemediationSteps $publicAccessControl.businessImpact `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }
        
        # Control: Soft Delete for Blobs
        $softDeleteControl = $controlLookup["Soft Delete for Blobs"]
        if ($softDeleteControl) {
            $softDeleteEnabled = $false
            try {
                $blobProps = Invoke-AzureApiWithRetry {
                    Get-AzStorageBlobServiceProperty -ResourceGroupName $sa.ResourceGroupName -StorageAccountName $sa.StorageAccountName -ErrorAction SilentlyContinue
                }
                if ($blobProps -and $blobProps.DeleteRetentionPolicy -and $blobProps.DeleteRetentionPolicy.Enabled) {
                    $softDeleteEnabled = $true
                }
            }
            catch {
                Write-Verbose "Could not get blob service properties for $($sa.StorageAccountName): $_"
            }
            
            $softDeleteStatus = if ($softDeleteEnabled) { "PASS" } else { "FAIL" }
            $remediationCmd = $softDeleteControl.remediationCommand -replace '\{name\}', $sa.StorageAccountName -replace '\{rg\}', $sa.ResourceGroupName
            
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $sa.ResourceGroupName `
                -ResourceType "Microsoft.Storage/storageAccounts" `
                -ResourceName $sa.StorageAccountName `
                -ResourceId $resourceId `
                -ControlId $softDeleteControl.controlId `
                -ControlName $softDeleteControl.controlName `
                -Category $softDeleteControl.category `
                -Frameworks $softDeleteControl.frameworks `
                -Severity $softDeleteControl.severity `
                -CisLevel $softDeleteControl.level `
                -CurrentValue $(if ($softDeleteEnabled) { "Enabled" } else { "Disabled" }) `
                -ExpectedValue $softDeleteControl.expectedValue `
                -Status $softDeleteStatus `
                -RemediationSteps $softDeleteControl.businessImpact `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }

        # Control: Default Network Access
        $networkControl = $controlLookup["Default Network Access"]
        if ($networkControl) {
            $defaultAction = if ($networkRules) { $networkRules.DefaultAction } else { "Allow" }
            $networkStatus = if ($defaultAction -eq "Deny") { "PASS" } else { "FAIL" }
            
            $remediationCmd = $networkControl.remediationCommand -replace '\{name\}', $sa.StorageAccountName -replace '\{rg\}', $sa.ResourceGroupName
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $sa.ResourceGroupName `
                -ResourceType "Microsoft.Storage/storageAccounts" `
                -ResourceName $sa.StorageAccountName `
                -ResourceId $resourceId `
                -ControlId $networkControl.controlId `
                -ControlName $networkControl.controlName `
                -Category $networkControl.category `
                -Frameworks $networkControl.frameworks `
                -Severity $networkControl.severity `
                -CisLevel $networkControl.level `
                -CurrentValue $defaultAction `
                -ExpectedValue $networkControl.expectedValue `
                -Status $networkStatus `
                -RemediationSteps $networkControl.businessImpact `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }
        
        # Control: Storage Account Kind (Legacy Detection)
        $kindControl = $controlLookup["Storage Account Kind (Legacy Detection)"]
        if ($kindControl) {
            $kindStatus = if ($sa.Kind -eq "StorageV2") { "PASS" } else { "FAIL" }
            $eolDate = if ($sa.Kind -in @('Storage', 'BlobStorage')) { $kindControl.eolDate } else { $null }
            
            $remediationCmd = $kindControl.remediationCommand -replace '\{name\}', $sa.StorageAccountName -replace '\{rg\}', $sa.ResourceGroupName
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $sa.ResourceGroupName `
                -ResourceType "Microsoft.Storage/storageAccounts" `
                -ResourceName $sa.StorageAccountName `
                -ResourceId $resourceId `
                -ControlId $kindControl.controlId `
                -ControlName $kindControl.controlName `
                -Category $kindControl.category `
                -Frameworks $kindControl.frameworks `
                -Severity $kindControl.severity `
                -CisLevel $kindControl.level `
                -CurrentValue $sa.Kind `
                -ExpectedValue $kindControl.expectedValue `
                -Status $kindStatus `
                -RemediationSteps $kindControl.businessImpact `
                -RemediationCommand $remediationCmd `
                -EOLDate $eolDate
            $findings.Add($finding)
        }
        
        # Level 2 Controls - Only check if control is enabled and IncludeLevel2 is specified
        # Control: Infrastructure Encryption
        $infraEncryptionControl = $controlLookup["Infrastructure Encryption"]
        if ($infraEncryptionControl) {
            try {
                $encryption = Invoke-AzureApiWithRetry {
                    Get-AzStorageAccountEncryption -ResourceGroupName $sa.ResourceGroupName -Name $sa.StorageAccountName -ErrorAction SilentlyContinue
                }
                $infraEncryption = if ($encryption -and $encryption.RequireInfrastructureEncryption) { $encryption.RequireInfrastructureEncryption } else { $false }
            }
            catch {
                $infraEncryption = $false
            }
            
            $infraStatus = if ($infraEncryption) { "PASS" } else { "FAIL" }
            
            $remediationCmd = $infraEncryptionControl.remediationCommand -replace '\{name\}', $sa.StorageAccountName -replace '\{rg\}', $sa.ResourceGroupName
            $note = if ($infraEncryptionControl.note) { $infraEncryptionControl.note } else { "Level 2 - Required only for critical data" }
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $sa.ResourceGroupName `
                -ResourceType "Microsoft.Storage/storageAccounts" `
                -ResourceName $sa.StorageAccountName `
                -ResourceId $resourceId `
                -ControlId $infraEncryptionControl.controlId `
                -ControlName $infraEncryptionControl.controlName `
                -Category $infraEncryptionControl.category `
                -Frameworks $infraEncryptionControl.frameworks `
                -Severity $infraEncryptionControl.severity `
                -CisLevel $infraEncryptionControl.level `
                -CurrentValue $infraEncryption.ToString() `
                -ExpectedValue $infraEncryptionControl.expectedValue `
                -Status $infraStatus `
                -RemediationSteps $infraEncryptionControl.businessImpact `
                -RemediationCommand $remediationCmd `
                -Note $note
            $findings.Add($finding)
        }
        
        # Control: Azure Services Bypass
        $bypassControl = $controlLookup["Azure Services Bypass"]
        if ($bypassControl) {
            $bypass = if ($networkRules) { $networkRules.Bypass } else { "None" }
            $azureServicesBypass = $bypass -match "AzureServices"
            $bypassStatus = if ($azureServicesBypass) { "PASS" } else { "FAIL" }
            
            $remediationCmd = $bypassControl.remediationCommand -replace '\{name\}', $sa.StorageAccountName -replace '\{rg\}', $sa.ResourceGroupName
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $sa.ResourceGroupName `
                -ResourceType "Microsoft.Storage/storageAccounts" `
                -ResourceName $sa.StorageAccountName `
                -ResourceId $resourceId `
                -ControlId $bypassControl.controlId `
                -ControlName $bypassControl.controlName `
                -Category $bypassControl.category `
                -Frameworks $bypassControl.frameworks `
                -Severity $bypassControl.severity `
                -CisLevel $bypassControl.level `
                -CurrentValue $bypass `
                -ExpectedValue $bypassControl.expectedValue `
                -Status $bypassStatus `
                -RemediationSteps $bypassControl.businessImpact `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }
        
        # Control: Customer-Managed Keys (for critical data only)
        $cmkControl = $controlLookup["Customer-Managed Keys"]
        if ($cmkControl) {
            # Only check if no CriticalStorageAccounts specified, or if this account is in the list
            $shouldCheckCMK = $true
            if ($CriticalStorageAccounts.Count -gt 0) {
                $shouldCheckCMK = $CriticalStorageAccounts -contains $sa.StorageAccountName
            }
            
            if ($shouldCheckCMK) {
                try {
                    $encryption = Invoke-AzureApiWithRetry {
                        Get-AzStorageAccountEncryption -ResourceGroupName $sa.ResourceGroupName -Name $sa.StorageAccountName -ErrorAction SilentlyContinue
                    }
                    $keySource = if ($encryption -and $encryption.Encryption.KeySource) { $encryption.Encryption.KeySource } else { "Microsoft.Storage" }
                }
                catch {
                    $keySource = "Microsoft.Storage"
                }
                
                $cmkStatus = if ($keySource -eq "Microsoft.Keyvault") { "PASS" } else { "FAIL" }
                
                $cmkNote = if ($cmkControl.note) { $cmkControl.note } else { "Level 2 - Required only for critical data" }
                if ($CriticalStorageAccounts.Count -gt 0 -and $shouldCheckCMK) {
                    $cmkNote = "Level 2 - Required for critical data (account marked as critical)"
                }
                
                $remediationCmd = $cmkControl.remediationCommand -replace '\{name\}', $sa.StorageAccountName -replace '\{rg\}', $sa.ResourceGroupName
                $finding = New-SecurityFinding `
                    -SubscriptionId $SubscriptionId `
                    -SubscriptionName $SubscriptionName `
                    -ResourceGroup $sa.ResourceGroupName `
                    -ResourceType "Microsoft.Storage/storageAccounts" `
                    -ResourceName $sa.StorageAccountName `
                    -ResourceId $resourceId `
                    -ControlId $cmkControl.controlId `
                    -ControlName $cmkControl.controlName `
                    -Category $cmkControl.category `
                    -Frameworks $cmkControl.frameworks `
                    -Severity $cmkControl.severity `
                    -CisLevel $cmkControl.level `
                    -CurrentValue $keySource `
                    -ExpectedValue $cmkControl.expectedValue `
                    -Status $cmkStatus `
                    -RemediationSteps $cmkControl.businessImpact `
                    -RemediationCommand $remediationCmd `
                    -Note $cmkNote
                $findings.Add($finding)
            }
        }
    }
    
    return $findings
}
