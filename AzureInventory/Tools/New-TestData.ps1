<#
.SYNOPSIS
    Generates dummy test data for all report types to enable rapid HTML/CSS testing.

.DESCRIPTION
    Creates realistic dummy datasets for each report type so you can test HTML/CSS changes
    without running full Azure scans. Each function generates data matching the expected
    structure for the corresponding Export-*Report function.

.EXAMPLE
    # Generate test data for Security Report
    $auditResult = New-TestSecurityData
    Export-SecurityReport -AuditResult $auditResult -OutputPath "test-security.html"

.EXAMPLE
    # Generate test data for all reports
    . .\Tools\New-TestData.ps1
    $vmData = New-TestVMBackupData
    $changeData = New-TestChangeTrackingData
    $costData = New-TestCostTrackingData
    # ... etc
#>

function New-TestSecurityData {
    [CmdletBinding()]
    param(
        [int]$FindingCount = 50
    )
    
    $findings = [System.Collections.Generic.List[PSObject]]::new()
    $categories = @('Storage', 'AppService', 'VM', 'Network', 'SQL', 'KeyVault')
    $severities = @('Critical', 'High', 'Medium', 'Low')
    $statuses = @('PASS', 'FAIL')
    $subscriptions = @('Sub-Prod-001', 'Sub-Dev-002', 'Sub-Test-003')
    
    # Track which categories have at least one failed finding
    $categoryHasFailed = @{}
    foreach ($cat in $categories) {
        $categoryHasFailed[$cat] = $false
    }
    
    for ($i = 0; $i -lt $FindingCount; $i++) {
        # Ensure all findings have: subscription, category, severity, and framework
        $severity = $severities[$i % $severities.Count]
        $category = $categories[$i % $categories.Count]
        
        # Ensure each category has at least one failed finding
        # If this category doesn't have a failed finding yet, make this one FAIL
        # Otherwise, use the normal distribution (1/3 FAIL, 2/3 PASS)
        if (-not $categoryHasFailed[$category]) {
            $status = 'FAIL'
            $categoryHasFailed[$category] = $true
        } else {
            $status = if ($i % 3 -eq 0) { 'FAIL' } else { 'PASS' }
        }
        
        # Subscription: Use consistent index for both ID and Name
        $subIndex = $i % 3
        $subscriptionId = "sub-$subIndex"
        $subscriptionName = $subscriptions[$subIndex]
        
        # Assign CIS Level: Only L1 (skip L2 for now)
        # Distribute: 70% L1, 30% null (no CIS level)
        $cisLevel = $null
        if ($i % 10 -lt 7) {
            $cisLevel = "L1"
        }
        
        # Assign Frameworks: Mix of CIS only, ASB only, and CIS+ASB
        # 40% CIS only, 30% ASB only, 30% CIS+ASB
        $frameworkMod = $i % 10
        if ($frameworkMod -lt 4) {
            $frameworks = @("CIS")
        } elseif ($frameworkMod -lt 7) {
            $frameworks = @("ASB")
        } else {
            $frameworks = @("CIS", "ASB")
        }
        
        $finding = [PSCustomObject]@{
            ResourceId = "/subscriptions/12345/resourceGroups/RG-$category/providers/Microsoft.$category/resource-$i"
            ResourceName = "resource-$category-$i"
            ResourceType = "Microsoft.$category/resource"
            ResourceGroup = "RG-$category"
            Category = $category                    # Required: Category
            ControlId = "CTRL-$category-$($i % 10)"
            ControlName = "Control $category $($i % 10)"
            Status = $status
            Severity = $severity                    # Required: Severity
            Description = "Test finding description for $category resource $i"
            Remediation = "Test remediation steps for finding $i"
            SubscriptionId = $subscriptionId        # Required: Subscription ID
            SubscriptionName = $subscriptionName    # Required: Subscription Name
            CisLevel = $cisLevel
            Frameworks = $frameworks               # Required: Framework (always has at least CIS)
        }
        $findings.Add($finding)
    }
    
    # Add specific test findings for newly implemented controls
    # Storage - File Share Controls
    $fileShareControls = @(
        @{ ControlName = "Soft Delete for Azure File Shares"; ControlId = "10.1.1"; Status = "FAIL"; CurrentValue = "Disabled" }
        @{ ControlName = "Soft Delete for Azure File Shares"; ControlId = "10.1.1"; Status = "PASS"; CurrentValue = "Enabled" }
        @{ ControlName = "SMB Protocol Version 3.1.1 or Higher"; ControlId = "10.1.2"; Status = "PASS"; CurrentValue = "SMB3.1.1 or higher" }
        @{ ControlName = "SMB Protocol Version 3.1.1 or Higher"; ControlId = "10.1.2"; Status = "FAIL"; CurrentValue = "SMB version below 3.1.1" }
        @{ ControlName = "SMB Channel Encryption AES-256-GCM"; ControlId = "10.1.3"; Status = "PASS"; CurrentValue = "AES-256-GCM encryption enabled" }
        @{ ControlName = "SMB Channel Encryption AES-256-GCM"; ControlId = "10.1.3"; Status = "FAIL"; CurrentValue = "SMB channel encryption not enabled" }
    )
    
    # Storage - Cross Tenant Replication
    $crossTenantFindings = @(
        @{ ControlName = "Cross Tenant Replication Disabled"; ControlId = "10.3.8"; Status = "PASS"; CurrentValue = "Disabled" }
        @{ ControlName = "Cross Tenant Replication Disabled"; ControlId = "10.3.8"; Status = "FAIL"; CurrentValue = "Enabled" }
    )
    
    # Storage - Private Endpoints
    $privateEndpointFindings = @(
        @{ ControlName = "Storage Private Endpoints"; ControlId = "NS-2"; Status = "PASS"; CurrentValue = "Private endpoint configured" }
        @{ ControlName = "Storage Private Endpoints"; ControlId = "NS-2"; Status = "FAIL"; CurrentValue = "No private endpoint configured" }
    )
    
    # SQL - Threat Detection
    $threatDetectionFindings = @(
        @{ ControlName = "Enable Threat Detection"; ControlId = "LT-1"; Status = "PASS"; CurrentValue = "Enabled" }
        @{ ControlName = "Enable Threat Detection"; ControlId = "LT-1"; Status = "FAIL"; CurrentValue = "Disabled" }
    )
    
    # Network - Flow Logs
    $flowLogFindings = @(
        @{ ControlName = "Network Security Groups Flow Logs Enabled"; ControlId = "8.7"; Status = "PASS"; CurrentValue = "Flow logs enabled" }
        @{ ControlName = "Network Security Groups Flow Logs Enabled"; ControlId = "8.7"; Status = "FAIL"; CurrentValue = "Flow logs not enabled" }
    )
    
    # VM - Disk Encryption
    $diskEncryptionFindings = @(
        @{ ControlName = "VM Disk Encryption"; ControlId = "DP-4"; Status = "PASS"; CurrentValue = "Encryption enabled" }
        @{ ControlName = "VM Disk Encryption"; ControlId = "DP-4"; Status = "FAIL"; CurrentValue = "Encryption not enabled" }
    )
    
    # KeyVault - Key/Secret Expiration
    $keyExpirationFindings = @(
        @{ ControlName = "Expiration Date Set for All Keys in RBAC Key Vaults"; ControlId = "9.3.1"; Status = "PASS"; CurrentValue = "All 5 key(s) have expiration dates" }
        @{ ControlName = "Expiration Date Set for All Keys in Non-RBAC Key Vaults"; ControlId = "9.3.2"; Status = "FAIL"; CurrentValue = "2 of 3 key(s) missing expiration dates" }
        @{ ControlName = "Expiration Date Set for All Secrets in RBAC Key Vaults"; ControlId = "9.3.3"; Status = "PASS"; CurrentValue = "All 8 secret(s) have expiration dates" }
        @{ ControlName = "Expiration Date Set for All Secrets in Non-RBAC Key Vaults"; ControlId = "9.3.4"; Status = "FAIL"; CurrentValue = "1 of 4 secret(s) missing expiration dates" }
    )
    
    # Monitor - Log Analytics Retention
    $retentionFindings = @(
        @{ ControlName = "Log Analytics Workspace Retention Period"; ControlId = "7.1.4"; Status = "PASS"; CurrentValue = "365 days" }
        @{ ControlName = "Log Analytics Workspace Retention Period"; ControlId = "7.1.4"; Status = "FAIL"; CurrentValue = "30 days" }
    )
    
    # Combine all new control findings
    $allNewControlFindings = @()
    $allNewControlFindings += $fileShareControls
    $allNewControlFindings += $crossTenantFindings
    $allNewControlFindings += $privateEndpointFindings
    $allNewControlFindings += $threatDetectionFindings
    $allNewControlFindings += $flowLogFindings
    $allNewControlFindings += $diskEncryptionFindings
    $allNewControlFindings += $keyExpirationFindings
    $allNewControlFindings += $retentionFindings
    
    # Create findings for each new control
    $findingIndex = $FindingCount
    foreach ($controlData in $allNewControlFindings) {
        $category = switch -Wildcard ($controlData.ControlName) {
            "*File Share*" { "Storage"; break }
            "*Cross Tenant*" { "Storage"; break }
            "*Private Endpoint*" { "Storage"; break }
            "*Threat Detection*" { "SQL"; break }
            "*Flow Log*" { "Network"; break }
            "*Disk Encryption*" { "VM"; break }
            "*Secret*" { "KeyVault"; break }  # Check Secret before Key to avoid matching both
            "*Key*" { "KeyVault"; break }
            "*Retention*" { "Monitor"; break }
            default { "Storage" }
        }
        
        $severity = switch ($controlData.Status) {
            "FAIL" { if ($category -eq "Storage" -or $category -eq "KeyVault") { "Medium" } else { "High" } }
            "PASS" { "Low" }
            default { "Medium" }
        }
        
        $subIndex = $findingIndex % 3
        $subscriptionId = "sub-$subIndex"
        $subscriptionName = $subscriptions[$subIndex]
        
        $finding = [PSCustomObject]@{
            ResourceId = "/subscriptions/12345/resourceGroups/RG-$category/providers/Microsoft.$category/resource-$findingIndex"
            ResourceName = "resource-$category-$findingIndex"
            ResourceType = "Microsoft.$category/resource"
            ResourceGroup = "RG-$category"
            Category = $category
            ControlId = $controlData.ControlId
            ControlName = $controlData.ControlName
            Status = $controlData.Status
            Severity = $severity
            Description = "Test finding for $($controlData.ControlName)"
            Remediation = "Test remediation steps for $($controlData.ControlName)"
            SubscriptionId = $subscriptionId
            SubscriptionName = $subscriptionName
            CisLevel = "L1"
            Frameworks = @("CIS")
            CurrentValue = $controlData.CurrentValue
        }
        $findings.Add($finding)
        $findingIndex++
    }
    
    # Calculate L1 scores based on findings (skip L2 for now)
    $l1Findings = $findings | Where-Object { $_.CisLevel -eq "L1" }
    $l1Total = $l1Findings.Count
    $l1Passed = @($l1Findings | Where-Object { $_.Status -eq 'PASS' }).Count
    $l1Score = if ($l1Total -gt 0) { [math]::Round(($l1Passed / $l1Total) * 100, 1) } else { 0 }
    
    # L2 is skipped for now - set to null
    $l2Score = $null
    $l2Total = 0
    $l2Passed = 0
    
    # Calculate OverallScore from findings (for consistency, even though it will be recalculated in report)
    $overallPassed = @($findings | Where-Object { $_.Status -eq 'PASS' }).Count
    $overallScore = if ($FindingCount -gt 0) { [math]::Round(($overallPassed / $FindingCount) * 100, 1) } else { 0 }
    
    $complianceScores = [PSCustomObject]@{
        OverallScore = $overallScore  # Calculated from findings for consistency
        L1Score = $l1Score
        L2Score = $l2Score
        TotalChecks = $FindingCount
        PassedChecks = $overallPassed
        ScoresByCategory = @{
            'Storage' = 85.0
            'AppService' = 70.0
            'VM' = 65.0
            'Network' = 80.0
            'SQL' = 75.0
            'KeyVault' = 90.0
        }
    }
    
    # Create subscription objects matching the format used in Test-SecurityReport and livedata
    # Format: Array of objects with Id and Name properties (not just strings)
    $subscriptionsScanned = @()
    $subscriptionNames = @{}
    $subscriptionData = @(
        @{ Id = "sub-0"; Name = "Sub-Prod-001" }
        @{ Id = "sub-1"; Name = "Sub-Dev-002" }
        @{ Id = "sub-2"; Name = "Sub-Test-003" }
    )
    
    foreach ($subData in $subscriptionData) {
        $subscriptionsScanned += [PSCustomObject]@{
            Id   = $subData.Id
            Name = $subData.Name
        }
        $subscriptionNames[$subData.Id] = $subData.Name
    }
    
    $auditResult = [PSCustomObject]@{
        TenantId = "test-tenant-12345"
        Findings = $findings
        EOLFindings = @()
        VMInventory = @()
        AdvisorRecommendations = @()
        ChangeTrackingData = @()
        NetworkInventory = @()
        CostTrackingData = @{}
        ComplianceScores = $complianceScores
        ScanStartTime = (Get-Date).AddHours(-2)
        ScanEndTime = Get-Date
        SubscriptionsScanned = $subscriptionsScanned  # Array of objects with Id and Name properties (matching livedata format)
        SubscriptionNames = $subscriptionNames    # Hashtable mapping ID to Name
        TotalResources = 150
        Errors = @()
    }
    
    return $auditResult
}

function New-TestVMBackupData {
    [CmdletBinding()]
    param(
        [int]$VMCount = 30
    )
    
    $vmInventory = [System.Collections.Generic.List[PSObject]]::new()
    $subscriptions = @('Sub-Prod-001', 'Sub-Dev-002', 'Sub-Test-003')
    $subscriptionIds = @('sub-0', 'sub-1', 'sub-2')
    $osTypes = @('Windows', 'Linux')
    $powerStates = @('running', 'stopped', 'deallocated', 'running', 'running', 'deallocated')  # More running VMs
    $vaults = @('vault-prod-001', 'vault-prod-002', 'vault-dev-001', 'vault-prod-003', 'vault-dev-002')
    $vmSizes = @('Standard_B2s', 'Standard_D2s_v3', 'Standard_D4s_v3', 'Standard_B4ms', 'Standard_DS2_v2')
    $policies = @('DefaultPolicy', 'DailyBackupPolicy', 'WeeklyBackupPolicy', 'ProductionBackupPolicy')
    # Health statuses: More Passed (80%), some Failed (20%), few null (only for unprotected)
    # Using 18 Passed and 2 Failed to get ~90% Passed distribution (random variation may give ~80%)
    $healthStatusesForProtected = @('Passed', 'Passed', 'Passed', 'Passed', 'Passed', 'Passed', 'Passed', 'Passed', 'Passed', 'Passed', 'Passed', 'Passed', 'Passed', 'Passed', 'Passed', 'Passed', 'Passed', 'Passed', 'Failed', 'Failed')
    $healthStatusesForUnprotected = @('Passed', 'Failed', $null, $null)  # Unprotected can have null
    $protectionStatuses = @('Protected', 'Protected', 'Protected', 'ProtectionStopped', 'ProtectionError')  # Mostly Protected
    $lastBackupStatuses = @('Completed', 'Completed', 'Completed', 'Completed', 'CompletedWithWarnings', 'Failed')  # Mostly successful
    $provisioningStates = @('Succeeded', 'Updating', 'Creating')
    $resourceGroups = @('RG-Prod-VM', 'RG-Dev-VM', 'RG-Test-VM', 'RG-Shared-VM')
    $locations = @('eastus', 'westus', 'westeurope', 'northeurope')
    
    # Use random seed for more variation, but make it deterministic based on VMCount
    $random = [System.Random]::new(42)
    
    for ($i = 0; $i -lt $VMCount; $i++) {
        $subIndex = $random.Next(0, 3)  # Random subscription
        # Mix backup status: ~65% protected, ~35% unprotected
        $backupEnabled = ($random.Next(0, 100) -lt 65)
        
        # Power state: More variation, not just modulo
        $powerStateIndex = $random.Next(0, $powerStates.Count)
        $powerState = $powerStates[$powerStateIndex]
        
        # Vault and backup info
        $vaultName = if ($backupEnabled) { $vaults[$random.Next(0, $vaults.Count)] } else { $null }
        $lastBackup = if ($backupEnabled) { 
            (Get-Date).AddDays(-$random.Next(0, 8)).AddHours(-$random.Next(0, 24)) 
        } else { 
            $null 
        }
        
        # Health status: Backups ALWAYS have a health status (never null for protected VMs)
        if ($backupEnabled) {
            $healthStatus = $healthStatusesForProtected[$random.Next(0, $healthStatusesForProtected.Count)]
        } else {
            $healthStatus = $healthStatusesForUnprotected[$random.Next(0, $healthStatusesForUnprotected.Count)]
        }
        
        $protectionStatus = if ($backupEnabled) { 
            $protectionStatuses[$random.Next(0, $protectionStatuses.Count)] 
        } else { 
            $null 
        }
        
        $lastBackupStatus = if ($backupEnabled -and $lastBackup) { 
            $lastBackupStatuses[$random.Next(0, $lastBackupStatuses.Count)] 
        } else { 
            $null 
        }
        
        $policyName = if ($backupEnabled) { 
            $policies[$random.Next(0, $policies.Count)] 
        } else { 
            $null 
        }
        
        # Get resource group once to use in both ResourceGroup and ResourceId
        $resourceGroup = $resourceGroups[$random.Next(0, $resourceGroups.Count)]
        $vmName = "VM-$($i.ToString().PadLeft(3, '0'))"
        
        # Match exact structure from Get-AzureVirtualMachineFindings.ps1
        $vm = [PSCustomObject]@{
            SubscriptionId     = $subscriptionIds[$subIndex]
            SubscriptionName   = $subscriptions[$subIndex]
            VMName             = $vmName
            ResourceGroup      = $resourceGroup
            ResourceId         = "/subscriptions/$($subscriptionIds[$subIndex])/resourceGroups/$resourceGroup/providers/Microsoft.Compute/virtualMachines/$vmName"
            Location           = $locations[$random.Next(0, $locations.Count)]
            VMSize             = $vmSizes[$random.Next(0, $vmSizes.Count)]
            OsType             = $osTypes[$random.Next(0, $osTypes.Count)]
            PowerState         = $powerState
            ProvisioningState  = $provisioningStates[$random.Next(0, $provisioningStates.Count)]
            BackupEnabled      = $backupEnabled
            VaultName          = $vaultName
            ProtectionStatus   = $protectionStatus
            LastBackupStatus   = $lastBackupStatus
            LastBackupTime     = $lastBackup
            PolicyName         = $policyName
            HealthStatus       = $healthStatus
        }
        $vmInventory.Add($vm)
    }
    
    return $vmInventory
}

function New-TestChangeTrackingData {
    [CmdletBinding()]
    param(
        [int]$ChangeCount = 40
    )
    
    $changes = @()
    $changeTypes = @('Create', 'Update', 'Delete', 'Action')
    $resourceTypes = @(
        'Microsoft.Storage/storageAccounts',
        'Microsoft.Compute/virtualMachines',
        'Microsoft.Network/networkSecurityGroups',
        'Microsoft.KeyVault/vaults',
        'Microsoft.Authorization/roleAssignments',
        'Microsoft.Network/networkSecurityGroups/securityRules',
        'Microsoft.Network/firewallPolicies/ruleCollectionGroups',
        'Microsoft.Network/publicIPAddresses',
        'Microsoft.Network/privateEndpoints',
        'Microsoft.KeyVault/vaults/secrets',
        'Microsoft.KeyVault/vaults/keys',
        'Microsoft.Storage/storageAccounts/regenerateKey',
        'Microsoft.Sql/servers/firewallRules',
        'Microsoft.Sql/servers/administrators',
        'Microsoft.DocumentDB/databaseAccounts/firewallRules',
        'Microsoft.Web/sites/config',
        'Microsoft.Authorization/locks',
        'Microsoft.Authorization/policyAssignments',
        'Microsoft.Authorization/policyExemptions',
        'Microsoft.Insights/diagnosticSettings'
    )
    $subscriptions = @('Sub-Prod-001', 'Sub-Dev-002', 'Sub-Test-003')
    $securityFlags = @('high', 'medium', $null, $null)
    $resourceCategories = @('Storage', 'Compute', 'Networking', 'Security', 'Databases', 'Identity', 'Containers', 'Web', 'Other', 'Governance', 'Monitoring')
    $callerTypes = @('User', 'ServicePrincipal', 'ManagedIdentity', 'System', 'Application')
    $clientTypes = @('Azure Portal', 'Azure PowerShell', 'Azure CLI', 'REST API', $null)
    $random = [System.Random]::new(42)
    
    # Spread changes across the last 14 days
    $today = (Get-Date).Date
    $maxDaysAgo = 13
    
    for ($i = 0; $i -lt $ChangeCount; $i++) {
        $changeType = $changeTypes[$i % $changeTypes.Count]
        $resourceType = $resourceTypes[$i % $resourceTypes.Count]
        $securityFlag = $securityFlags[$i % $securityFlags.Count]
        
        # Spread dates across last 14 days (more recent = more changes)
        $daysAgo = $random.Next(0, $maxDaysAgo + 1)
        $hoursAgo = $random.Next(0, 24)
        $minutesAgo = $random.Next(0, 60)
        $changeTime = $today.AddDays(-$daysAgo).AddHours(-$hoursAgo).AddMinutes(-$minutesAgo)
        
        # Determine category and operation based on resource type
        $category = switch -Wildcard ($resourceType) {
            "*Storage*" { "Storage" }
            "*Compute*" { "Compute" }
            "*Network*" { "Networking" }
            "*KeyVault*" { "Security" }
            "*Sql*" { "Databases" }
            "*DocumentDB*" { "Databases" }
            "*Web*" { "Web" }
            "*Authorization*" { "Identity" }
            "*Insights*" { "Monitoring" }
            "*Management*" { "Governance" }
            default { $resourceCategories[$random.Next(0, $resourceCategories.Count)] }
        }
        
        # Generate appropriate operation name based on resource type and change type
        $operation = switch -Wildcard ($resourceType) {
            "*roleAssignments*" { 
                if ($changeType -eq 'Delete') { "Microsoft.Authorization/roleAssignments/delete" }
                else { "Microsoft.Authorization/roleAssignments/write" }
            }
            "*securityRules*" { 
                if ($changeType -eq 'Delete') { "Microsoft.Network/networkSecurityGroups/securityRules/delete" }
                else { "Microsoft.Network/networkSecurityGroups/securityRules/write" }
            }
            "*firewallRules*" {
                if ($resourceType -like "*Sql*") {
                    if ($changeType -eq 'Delete') { "Microsoft.Sql/servers/firewallRules/delete" }
                    else { "Microsoft.Sql/servers/firewallRules/write" }
                } else {
                    if ($changeType -eq 'Delete') { "Microsoft.DocumentDB/databaseAccounts/firewallRules/delete" }
                    else { "Microsoft.DocumentDB/databaseAccounts/firewallRules/write" }
                }
            }
            "*privateEndpoints*" {
                if ($changeType -eq 'Delete') { "Microsoft.Network/privateEndpoints/delete" }
                else { "Microsoft.Network/privateEndpoints/write" }
            }
            "*publicIPAddresses*" { "Microsoft.Network/publicIPAddresses/write" }
            "*KeyVault/vaults/secrets*" {
                if ($changeType -eq 'Delete') { "Microsoft.KeyVault/vaults/secrets/delete" }
                else { "Microsoft.KeyVault/vaults/secrets/write" }
            }
            "*KeyVault/vaults/keys*" {
                if ($changeType -eq 'Delete') { "Microsoft.KeyVault/vaults/keys/delete" }
                elseif ($changeType -eq 'Action') { "Microsoft.KeyVault/vaults/keys/rotate/action" }
                else { "Microsoft.KeyVault/vaults/keys/write" }
            }
            "*KeyVault/vaults*" { "Microsoft.KeyVault/vaults/accessPolicies/write" }
            "*storageAccounts/regenerateKey*" { "Microsoft.Storage/storageAccounts/regenerateKey/action" }
            "*storageAccounts*" { "Microsoft.Storage/storageAccounts/write" }
            "*firewallPolicies*" { "Microsoft.Network/firewallPolicies/ruleCollectionGroups/write" }
            "*Sql/servers/administrators*" { "Microsoft.Sql/servers/administrators/write" }
            "*Web/sites/config*" { "Microsoft.Web/sites/config/write" }
            "*Authorization/locks*" {
                if ($changeType -eq 'Delete') { "Microsoft.Authorization/locks/delete" }
                else { "Microsoft.Authorization/locks/write" }
            }
            "*Authorization/policyAssignments*" {
                if ($changeType -eq 'Delete') { "Microsoft.Authorization/policyAssignments/delete" }
                else { "Microsoft.Authorization/policyAssignments/write" }
            }
            "*Authorization/policyExemptions*" {
                if ($changeType -eq 'Delete') { "Microsoft.Authorization/policyExemptions/delete" }
                else { "Microsoft.Authorization/policyExemptions/write" }
            }
            "*Insights/diagnosticSettings*" {
                if ($changeType -eq 'Delete') { "Microsoft.Insights/diagnosticSettings/delete" }
                else { "Microsoft.Insights/diagnosticSettings/write" }
            }
            default { "$resourceType/$($changeType.ToLower())" }
        }
        
        $callerType = $callerTypes[$random.Next(0, $callerTypes.Count)]
        $clientType = $clientTypes[$random.Next(0, $clientTypes.Count)]
        
        # Generate caller based on caller type
        $caller = switch ($callerType) {
            'ServicePrincipal' { ([guid]::NewGuid()).ToString() }
            'ManagedIdentity' { "systemAssignedIdentity" }
            'User' { "user$($i % 10)@example.com" }
            default { "system@azure.com" }
        }
        
        # Determine security flag based on operation (using the new enhanced patterns)
        $securityFlag = $null
        $securityReason = $null
        if ($operation -like "*roleAssignments*" -or 
            $operation -like "*securityRules*" -or 
            $operation -like "*firewallRules*" -or
            $operation -like "*privateEndpoints*" -or
            $operation -like "*publicIPAddresses*" -or
            $operation -like "*KeyVault*" -or
            $operation -like "*regenerateKey*" -or
            $operation -like "*administrators*" -or
            $operation -like "*locks/delete*" -or
            $operation -like "*policyAssignments*") {
            $securityFlag = 'high'
            $securityReason = switch -Wildcard ($operation) {
                "*roleAssignments*" { "RBAC role assignment - verify permissions" }
                "*securityRules*" { "NSG security rule change - verify security rules" }
                "*firewallRules*" { "Firewall rule change - verify access rules" }
                "*privateEndpoints*" { "Private endpoint change - verify security posture" }
                "*publicIPAddresses*" { "Public IP address created - verify exposure" }
                "*KeyVault*" { "Key Vault access policy or secret change - verify access policies" }
                "*regenerateKey*" { "Storage account key regeneration - verify key rotation process" }
                "*administrators*" { "SQL server administrator change - verify access rules" }
                "*locks*" { "Resource lock removal - verify compliance impact" }
                "*policyAssignments*" { "Policy assignment change - verify governance impact" }
                default { "Security-sensitive operation: $operation" }
            }
        }
        elseif ($operation -like "*policyExemptions*" -or 
                $operation -like "*diagnosticSettings*" -or
                $operation -like "*networkSecurityGroups/write*" -or
                $operation -like "*KeyVault/vaults/write*") {
            $securityFlag = 'medium'
            $securityReason = switch -Wildcard ($operation) {
                "*policyExemptions*" { "Policy exemption created - verify compliance" }
                "*diagnosticSettings*" { "Diagnostic settings deleted - verify logging coverage" }
                "*networkSecurityGroups*" { "NSG configuration change - verify network security" }
                "*KeyVault/vaults/write*" { "Key Vault configuration change - verify access policies" }
                default { "Security-sensitive operation: $operation" }
            }
        }
        
        # For Update operations, sometimes include changed properties
        $hasChangeDetails = ($changeType -eq 'Update') -and ($random.Next(0, 100) -lt 60)
        $changedProperties = if ($hasChangeDetails) {
            @(
                [PSCustomObject]@{
                    PropertyPath = "properties.setting1"
                    PreviousValue = "old-value-$i"
                    NewValue = "new-value-$i"
                    ChangeCategory = "User"
                },
                [PSCustomObject]@{
                    PropertyPath = "tags.Environment"
                    PreviousValue = "Dev"
                    NewValue = "Prod"
                    ChangeCategory = "User"
                }
            )
        } else {
            $null
        }
        
        # Build resource ID with proper structure for sub-resources
        $resourceId = if ($resourceType -like "*/*/*") {
            # Sub-resource (e.g., Microsoft.Network/networkSecurityGroups/securityRules)
            $parts = $resourceType -split '/'
            $parentType = "$($parts[0])/$($parts[1])"
            $subResourceType = $parts[2]
            "/subscriptions/12345/resourceGroups/RG-$($i % 5)/providers/$parentType/nsg-$i/$subResourceType/rule-$i"
        } else {
            "/subscriptions/12345/resourceGroups/RG-$($i % 5)/providers/$resourceType/resource-$i"
        }
        
        $change = [PSCustomObject]@{
            ChangeTime = $changeTime
            ChangeType = $changeType
            ResourceId = $resourceId
            ResourceName = "resource-$i"
            ResourceType = $resourceType
            ResourceCategory = $category
            SubscriptionId = "sub-$($i % 3)"
            SubscriptionName = $subscriptions[$i % $subscriptions.Count]
            ResourceGroup = "RG-$($i % 5)"
            Operation = $operation
            Caller = $caller
            CallerType = $callerType
            ClientType = $clientType
            SecurityFlag = $securityFlag
            SecurityReason = $securityReason
            ChangeSource = "ChangeAnalysis"
            HasChangeDetails = $hasChangeDetails
            ChangedProperties = $changedProperties
        }
        $changes += $change
    }
    
    return $changes
}

function New-TestCostTrackingData {
    [CmdletBinding()]
    param(
        [int]$DayCount = 30
    )
    
    $bySubscription = @{
        'sub-prod-001' = @{
            Name = 'Sub-Prod-001'
            SubscriptionId = 'sub-prod-001'
            CostLocal = 12500.50
            CostUSD = 12500.50
            Currency = 'USD'
            ItemCount = 15
        }
        'sub-dev-002' = @{
            Name = 'Sub-Dev-002'
            SubscriptionId = 'sub-dev-002'
            CostLocal = 3200.75
            CostUSD = 3200.75
            Currency = 'USD'
            ItemCount = 8
        }
        'sub-test-003' = @{
            Name = 'Sub-Test-003'
            SubscriptionId = 'sub-test-003'
            CostLocal = 850.25
            CostUSD = 850.25
            Currency = 'USD'
            ItemCount = 5
        }
    }
    
    $byMeterCategory = @{
        'Virtual Machines' = @{
            MeterCategory = 'Virtual Machines'
            CostLocal = 8500.00
            CostUSD = 8500.00
        }
        'Storage' = @{
            MeterCategory = 'Storage'
            CostLocal = 3200.50
            CostUSD = 3200.50
        }
        'Networking' = @{
            MeterCategory = 'Networking'
            CostLocal = 1800.25
            CostUSD = 1800.25
        }
        'SQL Database' = @{
            MeterCategory = 'SQL Database'
            CostLocal = 1200.00
            CostUSD = 1200.00
        }
        'App Service' = @{
            MeterCategory = 'App Service'
            CostLocal = 850.75
            CostUSD = 850.75
        }
    }
    
    # Generate realistic resource names per subscription (inspired by live data patterns)
    $subscriptionResources = @{
        'Sub-Prod-001' = @{
            VMs = @('prod-web01', 'prod-db01', 'prod-app01', 'prod-dc01', 'prod-sql01', 'prod-api01')
            Storage = @('storprod01', 'storprod02', 'storprodbackup', 'storproddiag')
            SQL = @('sql-prod-primary', 'sql-prod-secondary', 'sql-prod-reporting')
            AppService = @('app-prod-main', 'app-prod-api', 'app-prod-admin')
            Network = @('vnet-prod-east', 'vnet-prod-west', 'lb-prod-main')
        }
        'Sub-Dev-002' = @{
            VMs = @('dev-web01', 'dev-db01', 'dev-test01', 'dev-build01')
            Storage = @('stordev01', 'stordev02', 'stordevtest')
            SQL = @('sql-dev-main', 'sql-dev-test')
            AppService = @('app-dev-main', 'app-dev-staging')
            Network = @('vnet-dev-main', 'vnet-dev-test')
        }
        'Sub-Test-003' = @{
            VMs = @('test-web01', 'test-db01')
            Storage = @('stortest01', 'stortest02')
            SQL = @('sql-test-main')
            AppService = @('app-test-main')
            Network = @('vnet-test-main')
        }
    }
    
    # Define subscriptions list (used for top resources and daily trend)
    $subscriptions = @('Sub-Prod-001', 'Sub-Dev-002', 'Sub-Test-003')
    
    # Build top resources list with realistic names distributed across subscriptions
    $topResources = @()
    $resourceIndex = 0
    foreach ($subName in $subscriptions) {
        $subResources = $subscriptionResources[$subName]
        # Add top VM from each subscription
        if ($subResources.VMs.Count -gt 0) {
            $vmName = $subResources.VMs[0]
            $topResources += [PSCustomObject]@{
                ResourceId = "/subscriptions/sub-$($subName.ToLower())/resourceGroups/rg-$($subName.ToLower())-vms/providers/Microsoft.Compute/virtualMachines/$vmName"
                ResourceName = $vmName
                ResourceGroup = "rg-$($subName.ToLower())-vms"
                ResourceType = 'Microsoft.Compute/virtualMachines'
                SubscriptionName = $subName
                SubscriptionId = "sub-$($subName.ToLower())"
                Cost = [math]::Round(2000 + (Get-Random -Minimum -500 -Maximum 1000), 2)
                Currency = 'USD'
            }
        }
        # Add top storage from each subscription
        if ($subResources.Storage.Count -gt 0) {
            $storName = $subResources.Storage[0]
            $topResources += [PSCustomObject]@{
                ResourceId = "/subscriptions/sub-$($subName.ToLower())/resourceGroups/rg-$($subName.ToLower())-storage/providers/Microsoft.Storage/storageAccounts/$storName"
                ResourceName = $storName
                ResourceGroup = "rg-$($subName.ToLower())-storage"
                ResourceType = 'Microsoft.Storage/storageAccounts'
                SubscriptionName = $subName
                SubscriptionId = "sub-$($subName.ToLower())"
                Cost = [math]::Round(1500 + (Get-Random -Minimum -300 -Maximum 600), 2)
                Currency = 'USD'
            }
        }
    }
    # Sort by cost descending and take top 20
    $topResources = $topResources | Sort-Object Cost -Descending | Select-Object -First 20
    
    # Generate daily trend with proper structure
    $dailyTrend = @()
    $categories = @('Virtual Machines', 'Storage', 'Networking', 'SQL Database', 'App Service')
    $subscriptions = @('Sub-Prod-001', 'Sub-Dev-002', 'Sub-Test-003')
    $subIds = @('sub-prod-001', 'sub-dev-002', 'sub-test-003')
    
    # Meters must match categoryMeters used in RawData so Ctrl+click filtering works
    # (chart shows meters from DailyTrend.ByMeter, tables show meters from RawData - they must be consistent)
    $meters = @(
        'D2s v3', 'D4s v3', 'Standard_B2s', 'Standard_D2s_v3',           # Virtual Machines
        'Standard_LRS', 'Standard_GRS', 'Premium_LRS', 'Hot Tier',       # Storage
        'Data Transfer', 'VPN Gateway', 'Load Balancer', 'Public IP',   # Networking
        'DTU - S2', 'DTU - S3', 'vCore', 'Elastic Pool',                 # SQL Database
        'Basic B1', 'Standard S1', 'Premium P1', 'Free F1'               # App Service
    )
    
    # Track resource costs over time to create realistic increases
    $halfwayPoint = [math]::Floor($DayCount / 2)
    
    # Define different trend patterns for categories (realistic: some grow faster, some slower)
    # Each category gets a unique trend multiplier to create variation
    $categoryTrends = @{
        'Virtual Machines' = 0.6    # High growth (60% increase in second half)
        'Storage' = 0.3              # Moderate growth (30% increase)
        'Networking' = 0.4          # Moderate-high growth (40% increase)
        'SQL Database' = 0.2        # Low growth (20% increase)
        'App Service' = 0.5         # High growth (50% increase)
    }
    
    # Define different trend patterns for subscriptions (realistic: prod grows slower, dev/test can vary)
    $subscriptionTrends = @{
        'Sub-Prod-001' = 0.3       # Production: stable, moderate growth (30%)
        'Sub-Dev-002' = 0.7         # Dev: more volatile, higher growth (70%)
        'Sub-Test-003' = 0.2        # Test: stable, low growth (20%)
    }
    
    # Define currency and exchange rate for realistic testing
    $currencyCode = 'SEK'
    $exchangeRate = 10.5 # 1 USD = 10.5 SEK
    
    # Initialize totals for aggregation across all days
    $totalBySubscription = @{}
    $totalByMeterCategory = @{}

    for ($i = $DayCount - 1; $i -ge 0; $i--) {
        $date = (Get-Date).AddDays(-$i)
        $dateString = $date.ToString('yyyy-MM-dd')
        $baseCost = 500 + (Get-Random -Minimum -50 -Maximum 100)
        
        # Calculate base trend multiplier for this day (applies to overall cost)
        $baseTrendMultiplier = 1.0
        if ($i -lt $halfwayPoint) {
            $daysFromHalfway = $halfwayPoint - $i
            $baseTrendMultiplier = 1.0 + ($daysFromHalfway / $DayCount) * 0.4  # Base 40% increase
        }
        
        # Build category breakdown and subscription breakdown simultaneously
        $byCategory = @{}
        
        # Initialize byCategory entries first
        foreach ($catName in $categories) {
            $byCategory[$catName] = @{
                CostLocal = 0
                CostUSD = 0
                BySubscription = @{}
            }
        }

        # Build subscription breakdown for this day
        $dayBySubscription = @{}
        foreach ($s in $subscriptions) {
            $dayBySubscription[$s] = @{
                CostLocal = 0
                CostUSD = 0
                ByCategory = @{}
            }
        }
        
        $subCosts = @(0.6, 0.3, 0.1) # Distribution percentages
        $categoryCosts = @(0.35, 0.20, 0.15, 0.15, 0.15) # Distribution percentages
        
        foreach ($subIndex in 0..($subscriptions.Count - 1)) {
            $subName = $subscriptions[$subIndex]
            $subBaseCost = $baseCost * $subCosts[$subIndex]
            
            # Apply subscription-specific trend
            $subTrendMultiplier = 1.0
            if ($i -lt $halfwayPoint -and $subscriptionTrends.ContainsKey($subName)) {
                $daysFromHalfway = $halfwayPoint - $i
                $subTrendFactor = $subscriptionTrends[$subName]
                $subTrendMultiplier = 1.0 + ($daysFromHalfway / $halfwayPoint) * $subTrendFactor
            }
            $subCost = [math]::Round($subBaseCost * $subTrendMultiplier, 2)
            
            # Populate category breakdown for this subscription (with combined trends)
            foreach ($catIndex in 0..($categories.Count - 1)) {
                $catName = $categories[$catIndex]
                $catBaseCost = $baseCost * $categoryCosts[$catIndex] * $subCosts[$subIndex]
                
                # Apply both category and subscription trends
                $combinedTrendMultiplier = 1.0
                if ($i -lt $halfwayPoint) {
                    $daysFromHalfway = $halfwayPoint - $i
                    $catTrendFactor = if ($categoryTrends.ContainsKey($catName)) { $categoryTrends[$catName] } else { 0.4 }
                    $subTrendFactor = if ($subscriptionTrends.ContainsKey($subName)) { $subscriptionTrends[$subName] } else { 0.4 }
                    # Combine trends (average with slight weighting)
                    $combinedTrendFactor = ($catTrendFactor * 0.6 + $subTrendFactor * 0.4)
                    $combinedTrendMultiplier = 1.0 + ($daysFromHalfway / $halfwayPoint) * $combinedTrendFactor
                }
                $catCost = [math]::Round($catBaseCost * $combinedTrendMultiplier, 2)
                $catCostUSD = [math]::Round($catCost / $exchangeRate, 2)
                
                $dayBySubscription[$subName].ByCategory[$catName] = @{
                    CostLocal = $catCost
                    CostUSD = $catCostUSD
                }
                
                # Accumulate actual category costs to subscription total to ensure consistency
                $dayBySubscription[$subName].CostLocal += $catCost
                $dayBySubscription[$subName].CostUSD += $catCostUSD
                
                # Accumulate to daily category total
                $byCategory[$catName].CostLocal += $catCost
                $byCategory[$catName].CostUSD += $catCostUSD
                
                # Accumulate to daily category subscription breakdown
                if (-not $byCategory[$catName].BySubscription.ContainsKey($subName)) {
                    $byCategory[$catName].BySubscription[$subName] = @{
                        CostLocal = 0
                        CostUSD = 0
                    }
                }
                $byCategory[$catName].BySubscription[$subName].CostLocal += $catCost
                $byCategory[$catName].BySubscription[$subName].CostUSD += $catCostUSD
            }
        }
        
        # Build meter breakdown for all meters
        # Map meters to their correct categories (meters are grouped by 4 per category)
        $meterToCategory = @{
            'D2s v3' = 'Virtual Machines'; 'D4s v3' = 'Virtual Machines'; 'Standard_B2s' = 'Virtual Machines'; 'Standard_D2s_v3' = 'Virtual Machines'
            'Standard_LRS' = 'Storage'; 'Standard_GRS' = 'Storage'; 'Premium_LRS' = 'Storage'; 'Hot Tier' = 'Storage'
            'Data Transfer' = 'Networking'; 'VPN Gateway' = 'Networking'; 'Load Balancer' = 'Networking'; 'Public IP' = 'Networking'
            'DTU - S2' = 'SQL Database'; 'DTU - S3' = 'SQL Database'; 'vCore' = 'SQL Database'; 'Elastic Pool' = 'SQL Database'
            'Basic B1' = 'App Service'; 'Standard S1' = 'App Service'; 'Premium P1' = 'App Service'; 'Free F1' = 'App Service'
        }
        $byMeter = @{}
        foreach ($meterIndex in 0..($meters.Count - 1)) {
            $meterName = $meters[$meterIndex]
            $meterCategory = $meterToCategory[$meterName]
            # Distribute costs across meters: higher index = lower cost (creates natural ranking)
            $costFactor = 0.15 - ($meterIndex * 0.006)  # Range from ~0.15 to ~0.03
            $meterBaseCost = $baseCost * [math]::Max(0.02, $costFactor)
            
            # Apply category-specific trend to meter (meters follow their category's trend)
            $meterTrendMultiplier = 1.0
            if ($i -lt $halfwayPoint -and $categoryTrends.ContainsKey($meterCategory)) {
                $daysFromHalfway = $halfwayPoint - $i
                $catTrendFactor = $categoryTrends[$meterCategory]
                $meterTrendMultiplier = 1.0 + ($daysFromHalfway / $halfwayPoint) * $catTrendFactor
            }
            $meterCost = [math]::Round($meterBaseCost * $meterTrendMultiplier, 2)
            
            # Build subscription breakdown for meter with subscription-specific trends
            $meterBySubscription = @{}
            
            # Distribute costs across subscriptions
            # Ensure total adds up to ~100% regardless of subscription count
            $subCount = $subscriptions.Count
            
            foreach ($subIndex in 0..($subscriptions.Count - 1)) {
                $subName = $subscriptions[$subIndex]
                
                # Create uneven distribution if multiple subscriptions
                $share = if ($subCount -eq 1) { 1.0 } 
                         elseif ($subCount -eq 2) { if ($subIndex -eq 0) { 0.65 } else { 0.35 } }
                         elseif ($subCount -eq 3) { if ($subIndex -eq 0) { 0.55 } elseif ($subIndex -eq 1) { 0.30 } else { 0.15 } }
                         else { 1.0 / $subCount }
                
                $subBaseCost = $meterCost * $share
                
                # Apply subscription-specific trend on top of category trend
                $subTrendMultiplier = 1.0
                if ($i -lt $halfwayPoint -and $subscriptionTrends.ContainsKey($subName)) {
                    $daysFromHalfway = $halfwayPoint - $i
                    $subTrendFactor = $subscriptionTrends[$subName]
                    $subTrendMultiplier = 1.0 + ($daysFromHalfway / $halfwayPoint) * ($subTrendFactor * 0.5)  # Scale down to avoid too extreme
                }
                $subCost = [math]::Round($subBaseCost * $subTrendMultiplier, 2)
                
                $meterBySubscription[$subName] = @{
                    CostLocal = $subCost
                    CostUSD = [math]::Round($subCost / $exchangeRate, 2)
                }
            }
            
            $byMeter[$meterName] = @{
                CostLocal = $meterCost
                CostUSD = [math]::Round($meterCost / $exchangeRate, 2)
                ByCategory = @{
                    $meterCategory = @{
                        CostLocal = $meterCost
                        CostUSD = [math]::Round($meterCost / $exchangeRate, 2)
                    }
                }
                BySubscription = $meterBySubscription
            }
        }
        
        # Build resource breakdown using subscription-specific resources
        # Include multiple resources per subscription to match real data patterns
        $byResource = @{}
        $resourceIndex = 0
        foreach ($subName in $subscriptions) {
            $subResources = $subscriptionResources[$subName]
            # Add multiple VMs from each subscription (up to 3-4 per subscription)
            $vmsToAdd = [math]::Min($subResources.VMs.Count, 4)
            for ($vmIdx = 0; $vmIdx -lt $vmsToAdd; $vmIdx++) {
                $vmName = $subResources.VMs[$vmIdx]
                $baseVmCost = $baseCost * 0.15 * (0.6 - ($resourceIndex * 0.05) - ($vmIdx * 0.05))
                # Create increasing trend for some resources in second half (recent days have higher costs)
                if ($i -lt $halfwayPoint) {
                    $daysFromHalfway = $halfwayPoint - $i
                    $trendMultiplier = 1.0 + ($daysFromHalfway / $halfwayPoint) * (0.4 + ($resourceIndex * 0.1) + ($vmIdx * 0.1))
                    $baseVmCost = $baseVmCost * $trendMultiplier
                }
                $vmCost = [math]::Round($baseVmCost, 2)
                $vmCostUSD = [math]::Round($vmCost / $exchangeRate, 2)
                if ($vmCost -gt 0.01) {
                    $byResource[$vmName] = @{
                        CostLocal = $vmCost
                        CostUSD = $vmCostUSD
                        ByCategory = @{
                            'Virtual Machines' = @{
                                CostLocal = $vmCost
                                CostUSD = $vmCostUSD
                            }
                        }
                        BySubscription = @{
                            $subName = @{
                                CostLocal = $vmCost
                                CostUSD = $vmCostUSD
                            }
                        }
                        ByMeter = @{
                            # Assume VM cost comes from a primary meter for simplicity in test data
                            'D2s v3' = @{
                                CostLocal = $vmCost
                                CostUSD = $vmCostUSD
                            }
                        }
                    }
                }
            }
            # Add storage resources
            $storToAdd = [math]::Min($subResources.Storage.Count, 2)
            for ($storIdx = 0; $storIdx -lt $storToAdd; $storIdx++) {
                $storName = $subResources.Storage[$storIdx]
                $baseStorCost = $baseCost * 0.12 * (0.6 - ($resourceIndex * 0.05) - ($storIdx * 0.05))
                
                # Apply combined trend: Storage category trend + subscription trend + resource variation
                if ($i -lt $halfwayPoint) {
                    $daysFromHalfway = $halfwayPoint - $i
                    $storCategoryTrend = if ($categoryTrends.ContainsKey('Storage')) { $categoryTrends['Storage'] } else { 0.3 }
                    # Combine category trend (60%), subscription trend (30%), and resource variation (10%)
                    $combinedTrendFactor = ($storCategoryTrend * 0.6 + $subTrendFactor * 0.3 + (0.2 + ($resourceIndex * 0.05) + ($storIdx * 0.05)) * 0.1)
                    $trendMultiplier = 1.0 + ($daysFromHalfway / $halfwayPoint) * $combinedTrendFactor
                    $baseStorCost = $baseStorCost * $trendMultiplier
                }
                $storCost = [math]::Round($baseStorCost, 2)
                $storCostUSD = [math]::Round($storCost / $exchangeRate, 2)
                if ($storCost -gt 0.01) {
                    $byResource[$storName] = @{
                        CostLocal = $storCost
                        CostUSD = $storCostUSD
                        ByCategory = @{
                            'Storage' = @{
                                CostLocal = $storCost
                                CostUSD = $storCostUSD
                            }
                        }
                        BySubscription = @{
                            $subName = @{
                                CostLocal = $storCost
                                CostUSD = $storCostUSD
                            }
                        }
                        ByMeter = @{
                            # Assume Storage cost comes from a primary meter
                            'Standard_LRS' = @{
                                CostLocal = $storCost
                                CostUSD = $storCostUSD
                            }
                        }
                    }
                }
            }
            $resourceIndex++
        }
        
        # Calculate total cost for this day (sum of all categories)
        $dayTotalCost = 0
        $dayTotalCostUSD = 0
        foreach ($cat in $byCategory.Values) {
            $dayTotalCost += $cat.CostLocal
            $dayTotalCostUSD += $cat.CostUSD
        }
        
        $dailyTrend += @{
            Date = $date
            DateString = $dateString
            TotalCostLocal = [math]::Round($dayTotalCost, 2)
            TotalCostUSD = [math]::Round($dayTotalCostUSD, 2)
            ByCategory = $byCategory
            BySubscription = $dayBySubscription
            ByMeter = $byMeter
            ByResource = $byResource
        }
    }
    
    # Re-calculate totals from DailyTrend to ensure 100% consistency
    $totalBySubscription = @{}
    $totalByMeterCategory = @{}

    foreach ($day in $dailyTrend) {
        # Aggregate Subscriptions
        foreach ($subKey in $day.BySubscription.Keys) {
            if (-not $totalBySubscription.ContainsKey($subKey)) {
                # Find subscription ID
                $subIndex = $subscriptions.IndexOf($subKey)
                $subId = if ($subIndex -ge 0) { $subIds[$subIndex] } else { "unknown-id" }

                $totalBySubscription[$subKey] = @{
                    Name = $subKey
                    SubscriptionId = $subId
                    CostLocal = 0
                    CostUSD = 0
                    Currency = $currencyCode
                }
            }
            $totalBySubscription[$subKey].CostLocal += $day.BySubscription[$subKey].CostLocal
            $totalBySubscription[$subKey].CostUSD += $day.BySubscription[$subKey].CostUSD
        }

        # Aggregate Categories
        foreach ($catKey in $day.ByCategory.Keys) {
            if (-not $totalByMeterCategory.ContainsKey($catKey)) {
                $totalByMeterCategory[$catKey] = @{
                    CostLocal = 0
                    CostUSD = 0
                }
            }
            $totalByMeterCategory[$catKey].CostLocal += $day.ByCategory[$catKey].CostLocal
            $totalByMeterCategory[$catKey].CostUSD += $day.ByCategory[$catKey].CostUSD
        }
    }

    # Generate RawData for detailed drilldown sections with subscription-specific resources
    $rawData = @()
    # subIds is already defined at the top
    
    # Category to resource type mapping
    $categoryToResourceType = @{
        'Virtual Machines' = 'Microsoft.Compute/virtualMachines'
        'Storage' = 'Microsoft.Storage/storageAccounts'
        'Networking' = 'Microsoft.Network/virtualNetworks'
        'SQL Database' = 'Microsoft.Sql/servers'
        'App Service' = 'Microsoft.Web/sites'
    }
    
    # Category to resource name array mapping
    $categoryToResourceKey = @{
        'Virtual Machines' = 'VMs'
        'Storage' = 'Storage'
        'Networking' = 'Network'
        'SQL Database' = 'SQL'
        'App Service' = 'AppService'
    }
    
    # Meter names per category
    $categoryMeters = @{
        'Virtual Machines' = @('D2s v3', 'D4s v3', 'Standard_B2s', 'Standard_D2s_v3')
        'Storage' = @('Standard_LRS', 'Standard_GRS', 'Premium_LRS', 'Hot Tier')
        'Networking' = @('Data Transfer', 'VPN Gateway', 'Load Balancer', 'Public IP')
        'SQL Database' = @('DTU - S2', 'DTU - S3', 'vCore', 'Elastic Pool')
        'App Service' = @('Basic B1', 'Standard S1', 'Premium P1', 'Free F1')
    }
    
    $entryCount = 0
    foreach ($subIndex in 0..($subscriptions.Count - 1)) {
        $subName = $subscriptions[$subIndex]
        $subId = $subIds[$subIndex]
        $subResources = $subscriptionResources[$subName]
        
        # Generate resources for each category
        foreach ($catName in $categories) {
            $resourceKey = $categoryToResourceKey[$catName]
            $resourceType = $categoryToResourceType[$catName]
            $catMeters = $categoryMeters[$catName]
            
            # Get resources for this category from subscription-specific list
            if ($subResources.ContainsKey($resourceKey)) {
                $catResources = $subResources[$resourceKey]
                # Use subscription's share (60/30/10) of the category cost
                $subShares = @(0.6, 0.3, 0.1)
                $catCostForSub = $totalByMeterCategory[$catName].CostLocal * $subShares[$subIndex]
                $catCost = [math]::Round($catCostForSub, 2)
                
                # Create 2-4 resources per category per subscription
                $resourcesToCreate = [math]::Min($catResources.Count, 4)
                for ($resIdx = 0; $resIdx -lt $resourcesToCreate; $resIdx++) {
                    $resName = $catResources[$resIdx]
                    $meterName = $catMeters[$resIdx % $catMeters.Count]
                    
                    # Calculate cost per resource (distribute category cost)
                    $resCost = [math]::Round($catCost / $resourcesToCreate * (1 + (Get-Random -Minimum -0.2 -Maximum 0.3)), 2)
                    
                    # Determine resource group based on subscription and category
                    $rgName = "rg-$($subName.ToLower())-$($resourceKey.ToLower())"
                    
                    if ($resCost -gt 0.01) {
                        # Live data collector does not return Quantity/UnitOfMeasure
                        # To match production behavior, we exclude them from test data too

                        $rawData += [PSCustomObject]@{
                            SubscriptionId = $subId
                            SubscriptionName = $subName
                            ResourceId = "/subscriptions/$subId/resourceGroups/$rgName/providers/$resourceType/$resName"
                            ResourceName = $resName
                            ResourceGroup = $rgName
                            ResourceType = $resourceType
                            MeterCategory = $catName
                            MeterSubCategory = "Standard"
                            Meter = $meterName
                            CostLocal = $resCost
                            CostUSD = [math]::Round($resCost / $exchangeRate, 2)
                            Currency = $currencyCode
                        }
                        $entryCount++
                    }
                }
            }
        }
    }
    
    # Collect all unique resource names from rawData
    $allUniqueResourceNames = $rawData | Select-Object -ExpandProperty ResourceName -Unique | Sort-Object
    
    # Generate TopResources from RawData
    $topResources = $rawData | Group-Object ResourceId | ForEach-Object {
        $group = $_.Group
        $first = $group[0]
        @{
            ResourceId = $first.ResourceId
            ResourceName = $first.ResourceName
            ResourceGroup = $first.ResourceGroup
            ResourceType = $first.ResourceType
            SubscriptionName = $first.SubscriptionName
            SubscriptionId = $first.SubscriptionId
            MeterCategory = $first.MeterCategory
            CostLocal = [math]::Round(($group | Measure-Object -Property CostLocal -Sum).Sum, 2)
            CostUSD = [math]::Round(($group | Measure-Object -Property CostUSD -Sum).Sum, 2)
            ItemCount = $group.Count
        }
    } | Sort-Object CostUSD -Descending | Select-Object -First 20

    # Calculate real total cost from daily trend (this is correct - matches graphs)
    $realTotalCost = 0
    $realTotalCostUSD = 0
    foreach ($day in $dailyTrend) {
        $realTotalCost += $day.TotalCostLocal
        $realTotalCostUSD += $day.TotalCostUSD
    }

    $costData = @{
        GeneratedAt = Get-Date
        PeriodStart = (Get-Date).AddDays(-$DayCount)
        PeriodEnd = Get-Date
        DaysToInclude = $DayCount
        TotalCostLocal = [math]::Round($realTotalCost, 2)
        TotalCostUSD = [math]::Round($realTotalCostUSD, 2)
        Currency = $currencyCode
        BySubscription = $totalBySubscription
        ByMeterCategory = $totalByMeterCategory
        TopResources = $topResources
        DailyTrend = $dailyTrend
        RawData = $rawData
        AllUniqueResourceNames = $allUniqueResourceNames
        SubscriptionCount = 3
    }
    
    if (-not $totalBySubscription) { Write-Warning "New-TestCostTrackingData: BySubscription is null!" }
    if ($totalBySubscription.Count -eq 0) { Write-Warning "New-TestCostTrackingData: BySubscription is empty!" }
    
    return $costData
}

function New-TestEOLData {
    [CmdletBinding()]
    param(
        [int]$EOLCount = 20
    )
    
    $eolFindings = @()
    $components = @('Windows Server 2012 R2', 'Windows Server 2016', 'SQL Server 2014', 'Azure Functions v1', 'Classic Storage Account', 'Azure Service Manager (ASM)', 'Azure AD Graph API', 'Azure AD Authentication Library (ADAL)')
    $subscriptions = @('Sub-Prod-001', 'Sub-Dev-002', 'Sub-Test-003')
    $statuses = @('Deprecated', 'Retiring', 'RETIRED', 'ANNOUNCED')
    $resourceTypes = @('Microsoft.Compute/virtualMachines', 'Microsoft.Storage/storageAccounts', 'Microsoft.Web/sites', 'Microsoft.Sql/servers', 'Microsoft.Network/virtualNetworks')
    
    # Create a mix of dates that will result in different severities:
    # - Some past dates (Critical - overdue)
    # - Some within 30 days (Critical)
    # - Some within 90 days (High)
    # - Some within 180 days (Medium)
    # - Some beyond 180 days (Low)
    $dateOffsets = @(
        -30,   # Past due - Critical
        -15,   # Past due - Critical
        10,    # Critical (< 30 days)
        25,    # Critical (< 30 days)
        45,    # High (30-90 days)
        75,    # High (30-90 days)
        120,   # Medium (90-180 days)
        150,   # Medium (90-180 days)
        200,   # Low (> 180 days)
        300,   # Low (> 180 days)
        450,   # Low (> 180 days)
        600,   # Low (> 180 days)
        800,   # Low (> 180 days)
        1000,  # Low (> 180 days)
        1200,  # Low (> 180 days)
        1500,  # Low (> 180 days)
        1800,  # Low (> 180 days)
        2100,  # Low (> 180 days)
        2400,  # Low (> 180 days)
        2700   # Low (> 180 days)
    )
    
    for ($i = 0; $i -lt $EOLCount; $i++) {
        $component = $components[$i % $components.Count]
        $daysOffset = $dateOffsets[$i % $dateOffsets.Count]
        $eolDate = (Get-Date).AddDays($daysOffset)
        $deadlineStr = $eolDate.ToString('yyyy-MM-dd')
        $daysUntil = [math]::Round(($eolDate - (Get-Date)).TotalDays)
        
        # Calculate severity based on daysUntil (matching Get-AzureEOLStatus.ps1 logic)
        $severity = "Low"
        $status = "ANNOUNCED"
        
        if ($daysUntil -lt 0) {
            $severity = "Critical"
            $status = "RETIRED"
        }
        elseif ($daysUntil -lt 30) {
            $severity = "Critical"
            $status = "DEPRECATED"
        }
        elseif ($daysUntil -lt 90) {
            $severity = "High"
            $status = "DEPRECATED"
        }
        elseif ($daysUntil -lt 180) {
            $severity = "Medium"
            $status = "ANNOUNCED"
        }
        else {
            $severity = "Low"
            $status = "ANNOUNCED"
        }
        
        $subIndex = $i % 3
        $subscriptionId = "sub-$subIndex"
        $subscriptionName = $subscriptions[$subIndex]
        $rgIndex = $i % 5
        $resourceType = $resourceTypes[$i % $resourceTypes.Count]
        $resourceName = if ($resourceType -like '*virtualMachines*') { "VM-EOL-$i" } 
                        elseif ($resourceType -like '*storageAccounts*') { "stgeol$i" }
                        elseif ($resourceType -like '*sites*') { "app-eol-$i" }
                        elseif ($resourceType -like '*servers*') { "sql-eol-$i" }
                        else { "resource-eol-$i" }
        
        # ActionRequired should include a URL (like real data format) - this will be converted to "Review retirement notice" link
        # Real EOL data only has a Link field, no separate migration guide
        $retirementNoticeUrl = "https://azure.microsoft.com/updates/$($component.ToLower().Replace(' ', '-'))-retirement-notice/"
        $actionRequired = "Review retirement notice: $retirementNoticeUrl"
        # No separate migration guide - real data only has the retirement notice link
        $migrationGuide = ""
        # References can be empty or contain the same link
        $references = @()
        
        $finding = [PSCustomObject]@{
            Id = [guid]::NewGuid().ToString()
            SubscriptionId = $subscriptionId
            SubscriptionName = $subscriptionName
            ResourceGroup = "RG-$rgIndex"
            ResourceType = $resourceType
            ResourceName = $resourceName
            ResourceId = "/subscriptions/$subscriptionId/resourceGroups/RG-$rgIndex/providers/$resourceType/$resourceName"
            Component = $component
            Status = $status
            Deadline = $deadlineStr
            Severity = $severity
            DaysUntilDeadline = $daysUntil
            ActionRequired = $actionRequired
            MigrationGuide = $migrationGuide
            References = $references
            ScanTimestamp = Get-Date
        }
        $eolFindings += $finding
    }
    
    return $eolFindings
}

function New-TestNetworkInventoryData {
    [CmdletBinding()]
    param(
        [int]$VNetCount = 10
    )
    
    $networkInventory = [System.Collections.Generic.List[PSObject]]::new()
    $subscriptions = @('Sub-Prod-001', 'Sub-Dev-002', 'Sub-Test-003')
    $locations = @('eastus', 'westus', 'westeurope', 'northeurope')
    
    for ($i = 0; $i -lt $VNetCount; $i++) {
        $subnetCount = 2 + ($i % 4)
        $subnets = [System.Collections.Generic.List[PSObject]]::new()
        $subIndex = $i % 3
        
        for ($j = 0; $j -lt $subnetCount; $j++) {
            # Determine subnet name
            $subnetName = if ($j -eq 0 -and $i % 3 -eq 0) { "GatewaySubnet" } else { "Subnet-$j" }
            
            # GatewaySubnet should never have NSG
            $isGatewaySubnet = ($subnetName -eq "GatewaySubnet")
            $hasNSG = if ($isGatewaySubnet) { $false } else { ($j % 2 -eq 0) }
            $nsgId = if ($hasNSG) { "/subscriptions/sub-$subIndex/resourceGroups/RG-Network/providers/Microsoft.Network/networkSecurityGroups/nsg-vnet$i-subnet$j" } else { $null }
            $nsgName = if ($hasNSG) { "nsg-vnet$i-subnet$j" } else { $null }
            
            # Generate NSG risks for some subnets
            $nsgRisks = @()
            if ($hasNSG -and ($j % 3 -eq 0)) {
                # Create some risky NSG rules
                $riskSeverities = @('Critical', 'High', 'Medium')
                $riskSeverity = $riskSeverities[$j % $riskSeverities.Count]
                $riskPorts = @(3389, 22, 1433, 3306, 8080)
                $riskPort = $riskPorts[$j % $riskPorts.Count]
                $portNames = @{ 3389 = "RDP"; 22 = "SSH"; 1433 = "SQL Server"; 3306 = "MySQL"; 8080 = "HTTP Alt" }
                
                $nsgRisks += [PSCustomObject]@{
                    Severity = $riskSeverity
                    RuleName = "Allow-$riskPort"
                    Direction = "Inbound"
                    Port = $riskPort.ToString()
                    PortName = $portNames[$riskPort]
                    Source = "0.0.0.0/0"
                    Destination = "Any"
                    Protocol = "TCP"
                    Priority = 1000 + $j
                    Description = "Open $($portNames[$riskPort]) port to internet"
                    NsgName = $nsgName
                }
            }
            
            # Generate connected devices (NICs, Load Balancers, etc.)
            $connectedDevices = [System.Collections.Generic.List[PSObject]]::new()
            $deviceCount = 2 + ($j % 3)
            $deviceTypes = @('NIC', 'LoadBalancer', 'ApplicationGateway', 'Bastion')
            
            for ($d = 0; $d -lt $deviceCount; $d++) {
                $deviceType = $deviceTypes[$d % $deviceTypes.Count]
                $connectedDevices.Add([PSCustomObject]@{
                    Type = $deviceType
                    Name = "$deviceType-vnet$i-subnet$j-dev$d"
                    ResourceId = "/subscriptions/sub-$subIndex/resourceGroups/RG-Network/providers/Microsoft.Network/$($deviceType.ToLower())/$deviceType-vnet$i-subnet$j-dev$d"
                    PrivateIP = "10.$i.$j.$($d + 10)"
                })
            }
            
            # Service endpoints for some subnets
            $serviceEndpoints = ""
            $serviceEndpointsList = [System.Collections.Generic.List[string]]::new()
            if ($j % 4 -eq 0) {
                $services = @('Microsoft.Storage', 'Microsoft.Sql', 'Microsoft.KeyVault')
                $serviceEndpointsList.Add($services[$j % $services.Count])
                $serviceEndpoints = $serviceEndpointsList -join ", "
            }
            
            $subnetObj = [PSCustomObject]@{
                Name = $subnetName
                Id = "/subscriptions/sub-$subIndex/resourceGroups/RG-Network/providers/Microsoft.Network/virtualNetworks/VNet-$i/subnets/Subnet-$j"
                AddressPrefix = "10.$i.$j.0/24"
                ServiceEndpoints = $serviceEndpoints
                ServiceEndpointsList = $serviceEndpointsList
                NsgId = $nsgId
                NsgName = $nsgName
                NsgRules = $null  # Not needed for test data
                NsgRisks = $nsgRisks
                RouteTableId = if ($j % 5 -eq 0) { "/subscriptions/sub-$subIndex/resourceGroups/RG-Network/providers/Microsoft.Network/routeTables/rt-vnet$i-subnet$j" } else { $null }
                RouteTableName = if ($j % 5 -eq 0) { "rt-vnet$i-subnet$j" } else { $null }
                Routes = $null
                ConnectedDevices = $connectedDevices
            }
            $subnets.Add($subnetObj)
        }
        
        # Generate peerings
        $peerings = [System.Collections.Generic.List[PSObject]]::new()
        if ($i -gt 0 -and $i % 2 -eq 0) {
            # Create peering to previous VNet
            # Make some peerings disconnected (when i % 5 == 0)
            $peeringState = if ($i % 5 -eq 0) { "Disconnected" } else { "Connected" }
            $peerings.Add([PSCustomObject]@{
                Name = "peering-to-vnet$($i-1)"
                RemoteVnetId = "/subscriptions/sub-$subIndex/resourceGroups/RG-Network/providers/Microsoft.Network/virtualNetworks/VNet-$($i-1)"
                RemoteVnetName = "VNet-$($i-1)"
                State = $peeringState
                AllowForwardedTraffic = $true
                AllowGatewayTransit = $false
                UseRemoteGateways = $false
                IsVirtualWANHub = $false
                RemoteHubId = $null
            })
        }
        
        # Generate gateways for some VNets
        $gateways = [System.Collections.Generic.List[PSObject]]::new()
        if ($i % 3 -eq 0) {
            $gatewayType = if ($i % 6 -eq 0) { "ExpressRoute" } else { "VPN" }
            $connections = [System.Collections.Generic.List[PSObject]]::new()
            
            # Add some connections
            if ($i % 2 -eq 0) {
                $connections.Add([PSCustomObject]@{
                    Name = "s2s-connection-$i"
                    Id = "/subscriptions/sub-$subIndex/resourceGroups/RG-Network/providers/Microsoft.Network/connections/s2s-connection-$i"
                    ConnectionStatus = if ($i % 4 -eq 0) { "Disconnected" } else { "Connected" }
                    ConnectionType = "IPsec"
                    RemoteNetwork = [PSCustomObject]@{
                        Type = "OnPremises"
                        Name = "OnPrem-Network-$i"
                        AddressSpace = "192.168.$i.0/24"
                        GatewayIpAddress = "203.0.113.$i"
                    }
                    RemoteNetworkName = "OnPrem-Network-$i"
                })
            }
            
            $gateways.Add([PSCustomObject]@{
                Name = "gw-vnet-$i"
                Id = "/subscriptions/sub-$subIndex/resourceGroups/RG-Network/providers/Microsoft.Network/virtualNetworkGateways/gw-vnet-$i"
                Type = $gatewayType
                Sku = if ($gatewayType -eq "ExpressRoute") { "Standard" } else { "VpnGw1" }
                VpnType = if ($gatewayType -eq "VPN") { "RouteBased" } else { $null }
                PublicIp = "/subscriptions/sub-$subIndex/resourceGroups/RG-Network/providers/Microsoft.Network/publicIPAddresses/pip-gw-vnet-$i"
                Connections = $connections
                P2SAddressPools = $null
                P2STunnelType = $null
                P2SAuthType = $null
            })
        }
        
        $vnet = [PSCustomObject]@{
            Type = "VNet"
            Id = "/subscriptions/sub-$subIndex/resourceGroups/RG-Network/providers/Microsoft.Network/virtualNetworks/VNet-$i"
            Name = "VNet-$i"
            ResourceGroup = "RG-Network"
            Location = $locations[$i % $locations.Count]
            AddressSpace = "10.$i.0.0/16"
            SubscriptionId = "sub-$subIndex"
            SubscriptionName = $subscriptions[$subIndex]
            DnsServers = if ($i % 3 -eq 0) { "8.8.8.8, 8.8.4.4" } else { "" }
            Tags = "Environment=Test;Owner=NetworkTeam"
            Subnets = $subnets
            Peerings = $peerings
            Gateways = $gateways
            Firewalls = [System.Collections.Generic.List[PSObject]]::new()
        }
        $networkInventory.Add($vnet)
    }
    
    # Add a Virtual WAN Hub
    $hub = [PSCustomObject]@{
        Type = "VirtualWANHub"
        Id = "/subscriptions/sub-0/resourceGroups/RG-Network/providers/Microsoft.Network/virtualHubs/hub-central"
        Name = "hub-central"
        ResourceGroup = "RG-Network"
        Location = "eastus"
        SubscriptionId = "sub-0"
        SubscriptionName = $subscriptions[0]
        AddressPrefix = "10.100.0.0/16"
        VpnConnections = @(
            [PSCustomObject]@{
                Name = "vpn-connection-1"
                ConnectionStatus = "Connected"
                RemoteSiteName = "OnPrem-Site-1"
                RemoteSiteAddressSpace = "192.168.100.0/24"
            },
            [PSCustomObject]@{
                Name = "vpn-connection-2"
                ConnectionStatus = "Disconnected"
                RemoteSiteName = "OnPrem-Site-2"
                RemoteSiteAddressSpace = "192.168.200.0/24"
            }
        )
        ExpressRouteConnections = @(
            [PSCustomObject]@{
                Name = "er-connection-1"
                ConnectionStatus = "Connected"
            },
            [PSCustomObject]@{
                Name = "er-connection-2"
                ConnectionStatus = "Disconnected"
            }
        )
        Peerings = @(
            [PSCustomObject]@{
                VNetName = "VNet-0"
                State = "Disconnected"
            }
        )
    }
    $networkInventory.Add($hub)
    
    # Add an Azure Firewall
    $firewall = [PSCustomObject]@{
        Type = "AzureFirewall"
        Id = "/subscriptions/sub-0/resourceGroups/RG-Network/providers/Microsoft.Network/azureFirewalls/fw-prod-01"
        Name = "fw-prod-01"
        ResourceGroup = "RG-Network"
        Location = "eastus"
        SubscriptionId = "sub-0"
        SubscriptionName = $subscriptions[0]
        VNetId = "/subscriptions/sub-0/resourceGroups/RG-Network/providers/Microsoft.Network/virtualNetworks/VNet-0"
        VNetName = "VNet-0"
        VirtualHubId = $null
        VirtualHubName = $null
        SubnetId = "/subscriptions/sub-0/resourceGroups/RG-Network/providers/Microsoft.Network/virtualNetworks/VNet-0/subnets/AzureFirewallSubnet"
        PublicIPs = @("/subscriptions/sub-0/resourceGroups/RG-Network/providers/Microsoft.Network/publicIPAddresses/pip-fw-prod-01")
        PrivateIP = "10.0.1.4"
        FirewallPolicyId = "/subscriptions/sub-0/resourceGroups/RG-Network/providers/Microsoft.Network/firewallPolicies/fw-policy-prod"
        ThreatIntelMode = "Alert"
        SkuTier = "Standard"
        Zones = @()
        DeploymentType = "VNet"
    }
    $networkInventory.Add($firewall)
    
    return $networkInventory
}

function New-TestRBACData {
    [CmdletBinding()]
    param(
        [int]$PrincipalCount = 25
    )
    
    $principals = [System.Collections.Generic.List[PSObject]]::new()
    $principalTypes = @('User', 'Group', 'ServicePrincipal', 'ManagedIdentity')
    
    # Define hierarchy: Tenant Root → Management Groups → Subscriptions
    $subscriptions = @(
        [PSCustomObject]@{ Id = "sub-0"; Name = "Sub-Prod-001"; MgId = "MG-Prod" }
        [PSCustomObject]@{ Id = "sub-1"; Name = "Sub-Dev-002"; MgId = "MG-Dev" }
        [PSCustomObject]@{ Id = "sub-2"; Name = "Sub-Test-003"; MgId = "MG-Test" }
    )
    
    $managementGroups = @(
        [PSCustomObject]@{ Id = "MG-Prod"; Name = "Production MG"; Parent = $null }
        [PSCustomObject]@{ Id = "MG-Dev"; Name = "Development MG"; Parent = $null }
        [PSCustomObject]@{ Id = "MG-Test"; Name = "Test MG"; Parent = $null }
    )
    
    $roles = @('Owner', 'Contributor', 'Reader', 'Storage Blob Data Contributor', 'Key Vault Secrets User', 'User Access Administrator')
    
    $firstNames = @('Anders', 'Maria', 'John', 'Anna', 'Erik', 'Lisa', 'Karl', 'Emma', 'Peter', 'Sara', 'David', 'Julia', 'Mikael', 'Hanna', 'Lars', 'Elin')
    $lastNames = @('Carlsson', 'Andersson', 'Johansson', 'Nilsson', 'Eriksson', 'Larsson', 'Olsson', 'Persson', 'Svensson', 'Gustafsson', 'Pettersson', 'Jonsson', 'Jansson', 'Hansson', 'Bengtsson', 'Danielsson')
    
    # Function to determine if a role includes another role's permissions
    function Test-RoleIncludesRole {
        param([string]$RoleA, [string]$RoleB)
        # Owner includes everything
        if ($RoleA -eq 'Owner') { return $true }
        # Contributor includes Reader
        if ($RoleA -eq 'Contributor' -and $RoleB -eq 'Reader') { return $true }
        # Same role
        if ($RoleA -eq $RoleB) { return $true }
        return $false
    }
    
    # Function to test if scope A is ancestor of scope B
    function Test-IsAncestorScope {
        param([string]$AncestorScope, [string]$DescendantScope)
        if ($AncestorScope -eq $DescendantScope) { return $true }
        if ($AncestorScope -eq '/') { return $true }  # Root is ancestor of everything
        
        # MG ancestor of subscription
        $mgMatch = [regex]::Match($AncestorScope, '/managementGroups/(.+)$')
        $subMatch = [regex]::Match($DescendantScope, '^/subscriptions/([^/]+)')
        if ($mgMatch.Success -and $subMatch.Success) {
            $mgId = $mgMatch.Groups[1].Value
            $subId = $subMatch.Groups[1].Value
            $sub = $subscriptions | Where-Object { $_.Id -eq $subId }
            if ($sub -and $sub.MgId -eq $mgId) { return $true }
        }
        
        # Subscription ancestor of RG/Resource
        $ancestorSubMatch = [regex]::Match($AncestorScope, '^/subscriptions/([^/]+)$')
        $descendantSubMatch = [regex]::Match($DescendantScope, '^/subscriptions/([^/]+)/')
        if ($ancestorSubMatch.Success -and $descendantSubMatch.Success) {
            $ancestorSubId = $ancestorSubMatch.Groups[1].Value
            $descendantSubId = $descendantSubMatch.Groups[1].Value
            return $ancestorSubId -eq $descendantSubId
        }
        
        # RG ancestor of Resource
        if ($AncestorScope -match '/resourceGroups/([^/]+)$' -and $DescendantScope -match '/resourceGroups/([^/]+)/') {
            return $AncestorScope -eq ($DescendantScope -replace '/providers/.+$', '')
        }
        
        return $false
    }
    
    for ($i = 0; $i -lt $PrincipalCount; $i++) {
        $principalType = $principalTypes[$i % $principalTypes.Count]
        $numAssignments = 1 + ($i % 3)
        $uniqueRoles = @()
        $uniqueSubs = @()
        $principalAssignments = @()
        $hasPrivileged = $false
        
        # Create assignments at different scope levels for some principals to test redundancy
        $createRedundant = ($i % 7 -eq 0)  # Every 7th principal gets redundant assignments
        
        for ($j = 0; $j -lt $numAssignments; $j++) {
            $roleName = $roles[$j % $roles.Count]
            $subIndex = $i % 3
            $sub = $subscriptions[$subIndex]
            $subName = $sub.Name
            $mgId = $sub.MgId
            $mg = $managementGroups | Where-Object { $_.Id -eq $mgId }
            
            if ($uniqueRoles -notcontains $roleName) {
                $uniqueRoles += $roleName
            }
            if ($uniqueSubs -notcontains $subName) {
                $uniqueSubs += $subName
            }
            
            $isPrivileged = $roleName -in @('Owner', 'User Access Administrator')
            if ($isPrivileged) { $hasPrivileged = $true }
            
            # Determine scope level and format ScopeRaw
            $scopeRaw = $null
            $scopeType = $null
            $scopeName = $null
            
            if ($createRedundant -and $j -eq 0 -and $roleName -eq 'Owner') {
                # First assignment at MG level (will make subscription-level assignments redundant)
                $scopeRaw = "/providers/Microsoft.Management/managementGroups/$mgId"
                $scopeType = "Management Group"
                $scopeName = $mg.Name
                $uniqueSubs = @($subscriptions | Where-Object { $_.MgId -eq $mgId } | ForEach-Object { $_.Name })
            }
            elseif ($createRedundant -and $j -eq 1) {
                # Second assignment at Subscription level (redundant if Owner is at MG)
                $scopeRaw = "/subscriptions/$($sub.Id)"
                $scopeType = "Subscription"
                $scopeName = $subName
            }
            else {
                # Regular subscription-level assignment
                $scopeRaw = "/subscriptions/$($sub.Id)"
                $scopeType = "Subscription"
                $scopeName = $subName
            }
            
            $principalAssignments += @{
                Role = $roleName
                ScopeType = $scopeType
                ScopeName = $scopeName
                ScopeRaw = $scopeRaw
                Subscriptions = if ($scopeType -eq "Management Group") { 
                    @($subscriptions | Where-Object { $_.MgId -eq $mgId } | ForEach-Object { $_.Name })
                } else { 
                    @($subName) 
                }
                SubscriptionCount = if ($scopeType -eq "Management Group") {
                    ($subscriptions | Where-Object { $_.MgId -eq $mgId }).Count
                } else {
                    1
                }
                IsRedundant = $false
                RedundantReason = $null
                IsPrivileged = $isPrivileged
            }
        }
        
        # Detect redundancy: check if any assignment is redundant due to ancestor scope with including role
        for ($a = 0; $a -lt $principalAssignments.Count; $a++) {
            for ($b = 0; $b -lt $principalAssignments.Count; $b++) {
                if ($a -eq $b) { continue }
                
                $assignmentA = $principalAssignments[$a]
                $assignmentB = $principalAssignments[$b]
                
                # Check if B's scope is ancestor of A's scope
                if (Test-IsAncestorScope -AncestorScope $assignmentB.ScopeRaw -DescendantScope $assignmentA.ScopeRaw) {
                    # Check if B's role includes A's role
                    if (Test-RoleIncludesRole -RoleA $assignmentB.Role -RoleB $assignmentA.Role) {
                        # Assignment A is redundant
                        $principalAssignments[$a].IsRedundant = $true
                        if ($assignmentB.ScopeRaw -eq $assignmentA.ScopeRaw) {
                            $principalAssignments[$a].RedundantReason = "Covered by $($assignmentB.Role) at same scope"
                        } else {
                            $otherScopeName = if ($assignmentB.ScopeType -eq "Management Group") { 
                                "MG: $($assignmentB.ScopeName)" 
                            } else { 
                                $assignmentB.ScopeName 
                            }
                            if ($assignmentB.Role -eq $assignmentA.Role) {
                                $principalAssignments[$a].RedundantReason = "Same role at $otherScopeName"
                            } else {
                                $principalAssignments[$a].RedundantReason = "$($assignmentB.Role) at $otherScopeName"
                            }
                        }
                    }
                }
            }
        }
        
        # Generate display name based on type
        $displayName = switch ($principalType) {
            'User' { 
                $firstName = $firstNames[$i % $firstNames.Count]
                $lastName = $lastNames[$i % $lastNames.Count]
                "$firstName $lastName"
            }
            'Group' { 
                if ($i % 5 -eq 0) {
                    "Security Team $i"
                } elseif ($i % 5 -eq 1) {
                    "Developers Group $i"
                } elseif ($i % 5 -eq 2) {
                    "Admins Group $i"
                } else {
                    "Group $i"
                }
            }
            'ServicePrincipal' { 
                "App Service Principal $i"
            }
            'ManagedIdentity' { 
                "Managed Identity $i"
            }
            default { "$principalType $i" }
        }
        
        # Generate UPN/AppId based on type
        $upn = if ($principalType -eq 'User') {
            $firstName = $firstNames[$i % $firstNames.Count].ToLower()
            $lastName = $lastNames[$i % $lastNames.Count].ToLower()
            "$firstName.$lastName@example.com"
        } else { $null }
        
        $appId = if ($principalType -in @('ServicePrincipal', 'ManagedIdentity')) {
            [Guid]::NewGuid().ToString()
        } else { $null }
        
        $principal = [PSCustomObject]@{
            PrincipalId = [Guid]::NewGuid().ToString()
            PrincipalDisplayName = $displayName
            PrincipalType = $principalType
            PrincipalUPN = $upn
            AppId = $appId
            IsOrphaned = ($i % 10 -eq 0)
            IsExternal = ($i % 5 -eq 0) -and ($principalType -eq 'User')
            HasPrivilegedRoles = $hasPrivileged
            
            # Summary stats
            AssignmentCount = $numAssignments
            RoleCount = $uniqueRoles.Count
            SubscriptionCount = $uniqueSubs.Count
            UniqueRoles = $uniqueRoles
            UniqueSubscriptions = $uniqueSubs
            
            # Assignments array
            Assignments = $principalAssignments
        }
        $principals.Add($principal)
    }
    
    # Calculate statistics from actual data
    $privilegedCount = @($principals | Where-Object { $_.HasPrivilegedRoles }).Count
    $orphanedCount = @($principals | Where-Object { $_.IsOrphaned }).Count
    $externalCount = @($principals | Where-Object { $_.IsExternal }).Count
    
    # Count redundant assignments
    $redundantCount = 0
    foreach ($principal in $principals) {
        foreach ($assignment in $principal.Assignments) {
            if ($assignment.IsRedundant) {
                $redundantCount++
            }
        }
    }
    
    $statistics = [PSCustomObject]@{
        TotalPrincipals = $principals.Count
        ByRiskTier = @{
            Privileged = $privilegedCount
            Write = 0
            Read = 0
        }
        OrphanedCount = $orphanedCount
        ExternalCount = $externalCount
        RedundantCount = $redundantCount
        CustomRoleCount = 0
    }
    
    # Build AccessMatrix from principals
    $accessMatrix = @{}
    $scopeTypes = @('Tenant Root', 'Management Group', 'Subscription', 'Resource Group', 'Resource')
    
    foreach ($principal in $principals) {
        foreach ($assignment in $principal.Assignments) {
            $roleName = $assignment.Role
            if (-not $accessMatrix.ContainsKey($roleName)) {
                $isPrivileged = $assignment.IsPrivileged
                $accessMatrix[$roleName] = @{
                    'Tenant Root' = 0
                    'Management Group' = 0
                    'Subscription' = 0
                    'Resource Group' = 0
                    'Resource' = 0
                    Total = 0
                    Unique = 0
                    IsPrivileged = $isPrivileged
                }
            }
            
            $scopeType = $assignment.ScopeType
            if ($accessMatrix[$roleName].ContainsKey($scopeType)) {
                $accessMatrix[$roleName][$scopeType]++
                $accessMatrix[$roleName].Total++
            }
        }
    }
    
    # Count unique principals per role (excluding redundant assignments)
    foreach ($roleName in $accessMatrix.Keys) {
        $uniquePrincipals = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($principal in $principals) {
            foreach ($assignment in $principal.Assignments) {
                if ($assignment.Role -eq $roleName -and -not $assignment.IsRedundant) {
                    $uniquePrincipals.Add($principal.PrincipalId) | Out-Null
                }
            }
        }
        $accessMatrix[$roleName].Unique = $uniquePrincipals.Count
    }
    
    
    # Create orphaned assignments (simplified)
    $orphanedAssignments = @()
    foreach ($principal in ($principals | Where-Object { $_.IsOrphaned })) {
        foreach ($assignment in $principal.Assignments) {
            $orphanedAssignments += [PSCustomObject]@{
                PrincipalId = $principal.PrincipalId
                PrincipalType = $principal.PrincipalType
                PrincipalDisplayName = $principal.PrincipalDisplayName
                RoleDefinitionName = $assignment.Role
                Scope = $assignment.ScopeRaw
                ScopeType = $assignment.ScopeType
                SubscriptionName = if ($assignment.Subscriptions.Count -gt 0) { $assignment.Subscriptions[0] } else { $null }
            }
        }
    }
    
    # Create metadata
    $metadata = [PSCustomObject]@{
        TenantId = "test-tenant-12345"
        CollectionTime = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
        Duration = 0
        SubscriptionsScanned = 3
        SubscriptionNames = @('Sub-Prod-001', 'Sub-Dev-002', 'Sub-Test-003')
        UnresolvedPrincipalCount = $orphanedCount
        TotalPrincipalCount = $PrincipalCount
        ResolvedPercentage = 100 - [math]::Round(($orphanedCount / $PrincipalCount) * 100, 1)
        LacksEntraIdAccess = $false
    }
    
    $rbacData = [PSCustomObject]@{
        Metadata = $metadata
        Statistics = $statistics
        Principals = $principals
        AccessMatrix = $accessMatrix
        CustomRoles = @()
        OrphanedAssignments = $orphanedAssignments
        Assignments = @()  # Keep for backward compatibility
    }
    
    return $rbacData
}

function New-TestAdvisorData {
    [CmdletBinding()]
    param(
        [int]$RecommendationCount = 40
    )
    
    $recommendations = [System.Collections.Generic.List[PSObject]]::new()
    $subscriptions = @('Sub-Prod-001', 'Sub-Dev-002', 'Sub-Test-003')
    $subscriptionIds = @('sub-0', 'sub-1', 'sub-2')
    
    # Use random seed for deterministic but varied data
    $random = [System.Random]::new(42)
    
    # Define recommendation templates for each category
    $costRecommendations = @(
        @{
            RecommendationTypeId = "e26426e4-4d5c-4b3c-8f3e-123456789abc"
            Label = "Purchase Reserved Instances to save money over pay-as-you-go costs"
            Problem = "You have virtual machines that are running continuously. You can save money by purchasing Reserved Instances."
            Solution = "Purchase Reserved Instances to reduce your costs. Reserved Instances provide significant discounts compared to pay-as-you-go pricing."
            ImpactedField = "Microsoft.Compute/virtualMachines"
            ResourceType = "Microsoft.Compute/virtualMachines"
            ExtendedProps = @{
                vmSize = "Standard_D2s_v3"
                term = "P3Y"
                lookbackPeriod = 60
                targetResourceCount = 5
                annualSavingsAmount = 12500.00
                savingsAmount = 1041.67
                savingsCurrency = "USD"
                scope = "Single"
                region = "eastus"
            }
        },
        @{
            RecommendationTypeId = "e26426e4-4d5c-4b3c-8f3e-123456789def"
            Label = "Purchase Savings Plans to save money over pay-as-you-go costs"
            Problem = "You have compute resources that are running continuously. You can save money by purchasing Savings Plans."
            Solution = "Purchase Savings Plans to reduce your costs. Savings Plans provide significant discounts compared to pay-as-you-go pricing."
            ImpactedField = "Microsoft.Compute/virtualMachines"
            ResourceType = "Microsoft.Compute/virtualMachines"
            ExtendedProps = @{
                term = "P1Y"
                lookbackPeriod = 30
                annualSavingsAmount = 8500.00
                savingsAmount = 708.33
                savingsCurrency = "USD"
            }
        },
        @{
            RecommendationTypeId = "e26426e4-4d5c-4b3c-8f3e-123456789ghi"
            Label = "Right-size or shut down underutilized virtual machines"
            Problem = "Your virtual machines are underutilized. You can reduce costs by right-sizing or shutting down unused VMs."
            Solution = "Right-size your virtual machines to match your workload requirements, or shut down VMs that are not in use."
            ImpactedField = "Microsoft.Compute/virtualMachines"
            ResourceType = "Microsoft.Compute/virtualMachines"
            ExtendedProps = @{
                currentSku = "Standard_D4s_v3"
                targetSku = "Standard_D2s_v3"
                MaxCpuP95 = 25
                MaxMemoryP95 = 30
                region = "westus"
                annualSavingsAmount = 3200.00
                savingsAmount = 266.67
                savingsCurrency = "USD"
            }
        },
        @{
            RecommendationTypeId = "e26426e4-4d5c-4b3c-8f3e-123456789jkl"
            Label = "Use Azure Hybrid Benefit for Windows Server"
            Problem = "You are running Windows Server VMs without Azure Hybrid Benefit, which could save you money."
            Solution = "Enable Azure Hybrid Benefit for your Windows Server VMs to reduce licensing costs."
            ImpactedField = "Microsoft.Compute/virtualMachines"
            ResourceType = "Microsoft.Compute/virtualMachines"
            ExtendedProps = @{
                annualSavingsAmount = 1800.00
                savingsAmount = 150.00
                savingsCurrency = "USD"
            }
        },
        @{
            RecommendationTypeId = "e26426e4-4d5c-4b3c-8f3e-123456789mno"
            Label = "Optimize storage account access tier"
            Problem = "Your storage account has blobs that could be moved to a cooler access tier to reduce costs."
            Solution = "Move infrequently accessed blobs to the Cool or Archive tier to reduce storage costs."
            ImpactedField = "Microsoft.Storage/storageAccounts"
            ResourceType = "Microsoft.Storage/storageAccounts"
            ExtendedProps = @{
                currentAccessTier = "Hot"
                recommendedAccessTier = "Cool"
                blobCount = 1250
                totalSizeInGB = 500
                annualSavingsAmount = 950.00
                savingsAmount = 79.17
                savingsCurrency = "USD"
            }
        }
    )
    
    $performanceRecommendations = @(
        @{
            RecommendationTypeId = "e26426e4-4d5c-4b3c-8f3e-223456789abc"
            Label = "Improve App Service availability by adding a deployment slot"
            Problem = "Your App Service app doesn't have a deployment slot configured, which can impact availability during deployments."
            Solution = "Add a deployment slot to enable zero-downtime deployments and improve availability."
            ImpactedField = "Microsoft.Web/sites"
            ResourceType = "Microsoft.Web/sites"
            ExtendedProps = @{
                currentSku = "Basic"
                recommendedSku = "Standard"
            }
        },
        @{
            RecommendationTypeId = "e26426e4-4d5c-4b3c-8f3e-223456789def"
            Label = "Improve SQL Database performance by upgrading service tier"
            Problem = "Your SQL Database is experiencing performance issues and could benefit from a service tier upgrade."
            Solution = "Upgrade your SQL Database service tier to improve performance and handle increased workload."
            ImpactedField = "Microsoft.Sql/servers/databases"
            ResourceType = "Microsoft.Sql/servers/databases"
            ExtendedProps = @{
                ServerName = "sqlserver-prod-01"
                DatabaseName = "ProductionDB"
                Current_SKU = "S2"
                Recommended_SKU = "S4"
                Current_DTU = 50
                Recommended_DTU = 200
                DatabaseSize = 5000
            }
        },
        @{
            RecommendationTypeId = "e26426e4-4d5c-4b3c-8f3e-223456789ghi"
            Label = "Improve Cosmos DB performance by adjusting throughput"
            Problem = "Your Cosmos DB container has low throughput utilization and could be optimized."
            Solution = "Adjust the provisioned throughput to match your actual usage patterns."
            ImpactedField = "Microsoft.DocumentDB/databaseAccounts"
            ResourceType = "Microsoft.DocumentDB/databaseAccounts"
            ExtendedProps = @{
                currentProvisionedThroughput = 400
                recommendedProvisionedThroughput = 200
            }
        }
    )
    
    $securityRecommendations = @(
        @{
            RecommendationTypeId = "e26426e4-4d5c-4b3c-8f3e-323456789abc"
            Label = "Enable Azure Defender for Storage"
            Problem = "Your storage accounts don't have Azure Defender enabled, which could leave them vulnerable to threats."
            Solution = "Enable Azure Defender for Storage to detect and respond to potential security threats."
            ImpactedField = "Microsoft.Storage/storageAccounts"
            ResourceType = "Microsoft.Storage/storageAccounts"
            ExtendedProps = @{}
        },
        @{
            RecommendationTypeId = "e26426e4-4d5c-4b3c-8f3e-323456789def"
            Label = "Enable Azure Defender for SQL"
            Problem = "Your SQL databases don't have Azure Defender enabled, which could leave them vulnerable to SQL injection attacks."
            Solution = "Enable Azure Defender for SQL to detect and respond to potential security threats."
            ImpactedField = "Microsoft.Sql/servers"
            ResourceType = "Microsoft.Sql/servers"
            ExtendedProps = @{}
        },
        @{
            RecommendationTypeId = "e26426e4-4d5c-4b3c-8f3e-323456789ghi"
            Label = "Enable Azure Defender for App Service"
            Problem = "Your App Service apps don't have Azure Defender enabled, which could leave them vulnerable to web application attacks."
            Solution = "Enable Azure Defender for App Service to detect and respond to potential security threats."
            ImpactedField = "Microsoft.Web/sites"
            ResourceType = "Microsoft.Web/sites"
            ExtendedProps = @{}
        }
    )
    
    $reliabilityRecommendations = @(
        @{
            RecommendationTypeId = "e26426e4-4d5c-4b3c-8f3e-423456789abc"
            Label = "Improve availability by using availability zones"
            Problem = "Your virtual machines are not using availability zones, which could impact availability during datacenter failures."
            Solution = "Deploy your virtual machines across availability zones to improve availability and resilience."
            ImpactedField = "Microsoft.Compute/virtualMachines"
            ResourceType = "Microsoft.Compute/virtualMachines"
            ExtendedProps = @{
                region = "eastus"
            }
        },
        @{
            RecommendationTypeId = "e26426e4-4d5c-4b3c-8f3e-423456789def"
            Label = "Improve availability by configuring backup"
            Problem = "Your virtual machines don't have backup configured, which could result in data loss during failures."
            Solution = "Configure Azure Backup for your virtual machines to protect against data loss."
            ImpactedField = "Microsoft.Compute/virtualMachines"
            ResourceType = "Microsoft.Compute/virtualMachines"
            ExtendedProps = @{}
        }
    )
    
    $operationalExcellenceRecommendations = @(
        @{
            RecommendationTypeId = "e26426e4-4d5c-4b3c-8f3e-523456789abc"
            Label = "Use Resource Manager templates for deployment"
            Problem = "Your resources are not deployed using Resource Manager templates, which can make management and consistency difficult."
            Solution = "Use Resource Manager templates to deploy and manage your resources consistently."
            ImpactedField = "Microsoft.Resources/subscriptions"
            ResourceType = "Microsoft.Resources/subscriptions"
            ExtendedProps = @{}
        },
        @{
            RecommendationTypeId = "e26426e4-4d5c-4b3c-8f3e-523456789def"
            Label = "Enable diagnostic logs"
            Problem = "Your resources don't have diagnostic logs enabled, which makes troubleshooting difficult."
            Solution = "Enable diagnostic logs for your resources to improve monitoring and troubleshooting capabilities."
            ImpactedField = "Microsoft.Storage/storageAccounts"
            ResourceType = "Microsoft.Storage/storageAccounts"
            ExtendedProps = @{}
        }
    )
    
    # Combine all recommendation templates
    $allTemplates = @()
    $allTemplates += $costRecommendations | ForEach-Object { $_ | Add-Member -NotePropertyName 'Category' -NotePropertyValue 'Cost' -PassThru }
    $allTemplates += $performanceRecommendations | ForEach-Object { $_ | Add-Member -NotePropertyName 'Category' -NotePropertyValue 'Performance' -PassThru }
    $allTemplates += $securityRecommendations | ForEach-Object { $_ | Add-Member -NotePropertyName 'Category' -NotePropertyValue 'Security' -PassThru }
    $allTemplates += $reliabilityRecommendations | ForEach-Object { $_ | Add-Member -NotePropertyName 'Category' -NotePropertyValue 'Reliability' -PassThru }
    $allTemplates += $operationalExcellenceRecommendations | ForEach-Object { $_ | Add-Member -NotePropertyName 'Category' -NotePropertyValue 'OperationalExcellence' -PassThru }
    
    # Generate recommendations
    $recIndex = 0
    while ($recommendations.Count -lt $RecommendationCount) {
        $template = $allTemplates[$recIndex % $allTemplates.Count]
        $subIndex = $random.Next(0, 3)
        
        # Create multiple resources per recommendation type (to test grouping)
        $resourcesPerType = if ($template.Category -eq 'Cost') { 3 } else { 2 }
        
        for ($r = 0; $r -lt $resourcesPerType -and $recommendations.Count -lt $RecommendationCount; $r++) {
            $resourceNum = $recIndex * 10 + $r
            
            # Determine impact based on category and index
            $impact = if ($recIndex % 3 -eq 0) { 'High' } elseif ($recIndex % 3 -eq 1) { 'Medium' } else { 'Low' }
            
            # Build resource ID based on resource type
            $resourceName = switch -Wildcard ($template.ResourceType) {
                "*virtualMachines*" { "vm-prod-$resourceNum" }
                "*storageAccounts*" { "storageprod$resourceNum" }
                "*sites*" { "app-prod-$resourceNum" }
                "*sql*" { "sqldb-prod-$resourceNum" }
                "*documentdb*" { "cosmos-prod-$resourceNum" }
                default { "resource-$resourceNum" }
            }
            
            $resourceGroup = "RG-$($template.Category)-$($subIndex + 1)"
            $resourceId = "/subscriptions/$($subscriptionIds[$subIndex])/resourceGroups/$resourceGroup/providers/$($template.ResourceType)/$resourceName"
            
            # Extract savings from ExtendedProps if available (note: template uses ExtendedProps, not ExtendedProperties)
            $potentialSavings = $null
            $monthlySavings = $null
            $savingsCurrency = "USD"
            if ($template.ExtendedProps -and $template.ExtendedProps.Count -gt 0) {
                if ($template.ExtendedProps.annualSavingsAmount) {
                    $potentialSavings = [decimal]$template.ExtendedProps.annualSavingsAmount
                }
                if ($template.ExtendedProps.savingsAmount) {
                    $monthlySavings = [decimal]$template.ExtendedProps.savingsAmount
                }
                if ($template.ExtendedProps.savingsCurrency) {
                    $savingsCurrency = $template.ExtendedProps.savingsCurrency
                }
            }
            
            # Format technical details (matching Format-ExtendedPropertiesDetails logic)
            $technicalDetails = @()
            if ($template.ExtendedProps -and $template.ExtendedProps.Count -gt 0) {
                if ($template.ImpactedField -like "*virtualMachines*") {
                    if ($template.ExtendedProps.currentSku) { $technicalDetails += "Current SKU: $($template.ExtendedProps.currentSku)" }
                    if ($template.ExtendedProps.targetSku) { $technicalDetails += "Recommended SKU: $($template.ExtendedProps.targetSku)" }
                    if ($template.ExtendedProps.MaxCpuP95) { $technicalDetails += "CPU P95: $($template.ExtendedProps.MaxCpuP95)%" }
                    if ($template.ExtendedProps.MaxMemoryP95) { $technicalDetails += "Memory P95: $($template.ExtendedProps.MaxMemoryP95)%" }
                    if ($template.ExtendedProps.region) { $technicalDetails += "Region: $($template.ExtendedProps.region)" }
                    if ($template.ExtendedProps.vmSize) { $technicalDetails += "VM Size: $($template.ExtendedProps.vmSize)" }
                    if ($template.ExtendedProps.term) { $technicalDetails += "Term: $($template.ExtendedProps.term)" }
                    if ($template.ExtendedProps.lookbackPeriod) { $technicalDetails += "Lookback: $($template.ExtendedProps.lookbackPeriod) days" }
                    if ($template.ExtendedProps.targetResourceCount) { $technicalDetails += "Quantity: $($template.ExtendedProps.targetResourceCount)" }
                    if ($template.ExtendedProps.scope) { $technicalDetails += "Scope: $($template.ExtendedProps.scope)" }
                }
                elseif ($template.ImpactedField -like "*storageAccounts*") {
                    if ($template.ExtendedProps.currentAccessTier) { $technicalDetails += "Tier: $($template.ExtendedProps.currentAccessTier) → $($template.ExtendedProps.recommendedAccessTier)" }
                    if ($template.ExtendedProps.blobCount) { $technicalDetails += "Blobs: $($template.ExtendedProps.blobCount)" }
                    if ($template.ExtendedProps.totalSizeInGB) { $technicalDetails += "Size: $($template.ExtendedProps.totalSizeInGB) GB" }
                }
                elseif ($template.ImpactedField -like "*sql*") {
                    if ($template.ExtendedProps.ServerName) { $technicalDetails += "Server: $($template.ExtendedProps.ServerName)" }
                    if ($template.ExtendedProps.DatabaseName) { $technicalDetails += "Database: $($template.ExtendedProps.DatabaseName)" }
                    if ($template.ExtendedProps.Current_SKU) { $technicalDetails += "SKU: $($template.ExtendedProps.Current_SKU) → $($template.ExtendedProps.Recommended_SKU)" }
                    if ($template.ExtendedProps.Current_DTU) { $technicalDetails += "DTU: $($template.ExtendedProps.Current_DTU) → $($template.ExtendedProps.Recommended_DTU)" }
                    if ($template.ExtendedProps.DatabaseSize) { $technicalDetails += "Size: $($template.ExtendedProps.DatabaseSize) MB" }
                }
                elseif ($template.ImpactedField -like "*documentdb*" -or $template.ImpactedField -like "*cosmosdb*") {
                    if ($template.ExtendedProps.currentProvisionedThroughput) { $technicalDetails += "RU/s: $($template.ExtendedProps.currentProvisionedThroughput) → $($template.ExtendedProps.recommendedProvisionedThroughput)" }
                }
                elseif ($template.ImpactedField -like "*sites*") {
                    if ($template.ExtendedProps.currentSku) { $technicalDetails += "SKU: $($template.ExtendedProps.currentSku) → $($template.ExtendedProps.recommendedSku)" }
                    if ($template.ExtendedProps.currentNumberOfWorkers) { $technicalDetails += "Workers: $($template.ExtendedProps.currentNumberOfWorkers) → $($template.ExtendedProps.recommendedNumberOfWorkers)" }
                }
            }
            
            $technicalDetailsStr = if ($technicalDetails.Count -gt 0) { $technicalDetails -join " | " } else { $null }
            
            # Build recommendation object matching Convert-AdvisorRecommendation output exactly
            $recommendation = [PSCustomObject]@{
                SubscriptionId       = $subscriptionIds[$subIndex]
                SubscriptionName     = $subscriptions[$subIndex]
                RecommendationId     = "/subscriptions/$($subscriptionIds[$subIndex])/providers/Microsoft.Advisor/recommendations/$($template.RecommendationTypeId)-$resourceNum"
                RecommendationTypeId = $template.RecommendationTypeId
                Category             = $template.Category
                Impact               = $impact
                Risk                 = if ($template.Category -eq 'Security') { 'Error' } else { 'Warning' }
                Control              = $null
                Label                = $template.Label
                ImpactedField        = $template.ImpactedField
                ResourceId           = $resourceId
                ResourceName         = $resourceName
                ResourceGroup        = $resourceGroup
                ResourceType         = $template.ResourceType
                Problem              = $template.Problem
                Solution             = $template.Solution
                Description          = "$($template.Problem) $($template.Solution)"
                LongDescription      = "Detailed description: $($template.Problem). Recommended action: $($template.Solution). This recommendation helps improve your Azure resource configuration."
                PotentialBenefits    = "Improved $($template.Category.ToLower()) and cost optimization"
                LearnMoreLink        = "https://learn.microsoft.com/azure/advisor/advisor-overview"
                PotentialSavings     = $potentialSavings
                MonthlySavings       = $monthlySavings
                SavingsCurrency      = $savingsCurrency
                LastUpdated          = (Get-Date).AddDays(-$random.Next(0, 30)).ToString("o")
                Remediation          = "Follow the steps in the Azure Portal to implement this recommendation."
                Actions              = @(
                    @{
                        actionType = "Microsoft.Advisor/recommendations/action"
                        actionUrl = "https://portal.azure.com/#resource$resourceId"
                    }
                )
                TechnicalDetails     = $technicalDetailsStr
                ExtendedProperties   = if ($template.ExtendedProps -and $template.ExtendedProps.Count -gt 0) { 
                    # Clone hashtable properly
                    $extPropsClone = @{}
                    foreach ($key in $template.ExtendedProps.Keys) {
                        $extPropsClone[$key] = $template.ExtendedProps[$key]
                    }
                    $extPropsClone
                } else { 
                    @{} 
                }
            }
            
            $recommendations.Add($recommendation)
        }
        
        $recIndex++
    }
    
    return $recommendations
}

function New-TestAllData {
    <#
    .SYNOPSIS
        Generates test data for all report types at once.
    
    .DESCRIPTION
        Creates a hashtable containing test data for all report types, ready to use
        for testing all reports.
    #>
    
    Write-Host "Generating test data for all report types..." -ForegroundColor Cyan
    
    return @{
        Security = New-TestSecurityData
        VMBackup = New-TestVMBackupData
        ChangeTracking = New-TestChangeTrackingData
        CostTracking = New-TestCostTrackingData
        EOL = New-TestEOLData
        NetworkInventory = New-TestNetworkInventoryData
        RBAC = New-TestRBACData
        Advisor = New-TestAdvisorData
    }
}

function Test-SingleReport {
    <#
    .SYNOPSIS
        Quick test function to generate a single report with dummy data.
    
    .DESCRIPTION
        Generates test data and creates a single report for rapid HTML/CSS iteration.
        Perfect for fixing one page at a time.
    
    .PARAMETER ReportType
        Type of report to generate: Security, VMBackup, ChangeTracking, CostTracking, EOL, NetworkInventory, RBAC, Advisor, Dashboard
    
    .PARAMETER OutputPath
        Path for the HTML report output (defaults to test-output\<ReportType>.html)
    
    .PARAMETER Help
        Display help information including all available parameters and report types
    
    .EXAMPLE
        Test-SingleReport -Help
        Test-SingleReport -ReportType Security
        Test-SingleReport -ReportType VMBackup -OutputPath "test-vm.html"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [ValidateSet('Security','VMBackup','ChangeTracking','CostTracking','EOL','NetworkInventory','RBAC','Advisor','Dashboard','All')]
        [string]$ReportType,
        [Parameter(Mandatory=$false)]
        [string]$OutputPath,
        [Parameter(Mandatory=$false)]
        [switch]$Help
    )
    
    # Show help if requested
    if ($Help) {
        Write-Host "`n=== Test-SingleReport - Help ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "SYNOPSIS" -ForegroundColor Yellow
        Write-Host "  Quick test function to generate a single report with dummy data for rapid HTML/CSS iteration." -ForegroundColor White
        Write-Host ""
        Write-Host "PARAMETERS" -ForegroundColor Yellow
        Write-Host "  -ReportType <String>" -ForegroundColor White
        Write-Host "      Type of report to generate. Required when generating a report." -ForegroundColor Gray
        Write-Host ""
        Write-Host "  -OutputPath <String>" -ForegroundColor White
        Write-Host "      Optional. Path for the HTML report output." -ForegroundColor Gray
        Write-Host "      If not specified, defaults to: test-output\<ReportType>.html" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  -Help [Switch]" -ForegroundColor White
        Write-Host "      Display this help information." -ForegroundColor Gray
        Write-Host ""
        Write-Host "AVAILABLE REPORT TYPES" -ForegroundColor Yellow
        Write-Host "  - Security          - Security audit report" -ForegroundColor White
        Write-Host "  - VMBackup          - VM backup status report" -ForegroundColor White
        Write-Host "  - ChangeTracking    - Change tracking report" -ForegroundColor White
        Write-Host "  - CostTracking      - Cost tracking report" -ForegroundColor White
        Write-Host "  - EOL               - End of Life report" -ForegroundColor White
        Write-Host "  - NetworkInventory  - Network inventory report" -ForegroundColor White
        Write-Host "  - RBAC              - Role-Based Access Control report" -ForegroundColor White
        Write-Host "  - Advisor           - Azure Advisor recommendations report" -ForegroundColor White
        Write-Host "  - Dashboard         - Comprehensive dashboard report" -ForegroundColor White
        Write-Host "  - All                - Generate all reports including Dashboard" -ForegroundColor White
        Write-Host ""
        Write-Host "USAGE EXAMPLES" -ForegroundColor Yellow
        Write-Host "  # Show this help" -ForegroundColor Gray
        Write-Host "  Test-SingleReport -Help" -ForegroundColor White
        Write-Host ""
        Write-Host "  # Generate Security report with default output path" -ForegroundColor Gray
        Write-Host "  Test-SingleReport -ReportType Security" -ForegroundColor White
        Write-Host ""
        Write-Host "  # Generate VMBackup report with custom output path" -ForegroundColor Gray
        Write-Host "  Test-SingleReport -ReportType VMBackup -OutputPath `"test-vm.html`"" -ForegroundColor White
        Write-Host ""
        Write-Host "  # Generate CostTracking report" -ForegroundColor Gray
        Write-Host "  Test-SingleReport -ReportType CostTracking" -ForegroundColor White
        Write-Host ""
        Write-Host "  # Generate Dashboard report" -ForegroundColor Gray
        Write-Host "  Test-SingleReport -ReportType Dashboard" -ForegroundColor White
        Write-Host ""
        Write-Host "  # Generate all reports including Dashboard" -ForegroundColor Gray
        Write-Host "  Test-SingleReport -ReportType All" -ForegroundColor White
        Write-Host ""
        Write-Host "NOTES" -ForegroundColor Yellow
        Write-Host "  - The function automatically reloads the module to ensure latest code is used" -ForegroundColor Gray
        Write-Host "  - Reports are generated with realistic dummy data for testing purposes" -ForegroundColor Gray
        Write-Host "  - Generated reports will automatically open in your default browser" -ForegroundColor Gray
        Write-Host ""
        return
    }
    
    # Require ReportType if Help is not specified
    if (-not $ReportType) {
        Write-Host "`nError: -ReportType is required. Use -Help to see available options." -ForegroundColor Red
        Write-Host "  Example: Test-SingleReport -Help" -ForegroundColor Yellow
        Write-Host ""
        return
    }
    
    # Check if required export functions are available (don't reload - user should run Init-Local.ps1 first)
    if ($ReportType -eq 'All') {
        $requiredFunctions = @('Export-SecurityReport', 'Export-VMBackupReport', 'Export-ChangeTrackingReport', 
                              'Export-CostTrackingReport', 'Export-EOLReport', 'Export-NetworkInventoryReport', 
                              'Export-RBACReport', 'Export-AdvisorReport', 'Export-DashboardReport')
        $missingFunctions = @()
        foreach ($func in $requiredFunctions) {
            if (-not (Get-Command $func -ErrorAction SilentlyContinue)) {
                $missingFunctions += $func
            }
        }
        if ($missingFunctions.Count -gt 0) {
            Write-Error "Required functions not available: $($missingFunctions -join ', '). Please run 'Init-Local.ps1' first."
            return
        }
    } else {
        $requiredFunction = switch ($ReportType) {
            'Security' { 'Export-SecurityReport' }
            'VMBackup' { 'Export-VMBackupReport' }
            'ChangeTracking' { 'Export-ChangeTrackingReport' }
            'CostTracking' { 'Export-CostTrackingReport' }
            'EOL' { 'Export-EOLReport' }
            'NetworkInventory' { 'Export-NetworkInventoryReport' }
            'RBAC' { 'Export-RBACReport' }
            'Advisor' { 'Export-AdvisorReport' }
            'Dashboard' { 'Export-DashboardReport' }
        }
        if (-not (Get-Command $requiredFunction -ErrorAction SilentlyContinue)) {
            Write-Error "Function $requiredFunction not available. Please run 'Init-Local.ps1' first."
            return
        }
    }
    
    # Verify the required functions are available (after reload if needed)
    if ($ReportType -eq 'All') {
        $requiredFunctions = @(
            'Export-SecurityReport',
            'Export-VMBackupReport',
            'Export-ChangeTrackingReport',
            'Export-CostTrackingReport',
            'Export-EOLReport',
            'Export-NetworkInventoryReport',
            'Export-RBACReport',
            'Export-AdvisorReport',
            'Export-DashboardReport'
        )
        $missingFunctions = @()
        foreach ($func in $requiredFunctions) {
            if (-not (Get-Command $func -ErrorAction SilentlyContinue)) {
                $missingFunctions += $func
            }
        }
        if ($missingFunctions.Count -gt 0) {
            Write-Error "Required functions not available: $($missingFunctions -join ', '). Please run Init-Local.ps1 first."
            return
        }
    } else {
        $requiredFunction = switch ($ReportType) {
            'Security' { 'Export-SecurityReport' }
            'VMBackup' { 'Export-VMBackupReport' }
            'ChangeTracking' { 'Export-ChangeTrackingReport' }
            'CostTracking' { 'Export-CostTrackingReport' }
            'EOL' { 'Export-EOLReport' }
            'NetworkInventory' { 'Export-NetworkInventoryReport' }
            'RBAC' { 'Export-RBACReport' }
            'Advisor' { 'Export-AdvisorReport' }
            'Dashboard' { 'Export-DashboardReport' }
        }
        
        if (-not (Get-Command $requiredFunction -ErrorAction SilentlyContinue)) {
            Write-Error "Function $requiredFunction not available. Please run Init-Local.ps1 first."
            return
        }
    }
    
    # For "All", OutputPath is ignored - all reports go to test-output directory
    if ($ReportType -ne 'All') {
        if (-not $OutputPath) {
            # Default to test-output directory (project root/test-output)
            # $PSScriptRoot is Tools/, so parent is project root
            $projectRoot = Split-Path $PSScriptRoot -Parent
            $testOutputDir = Join-Path $projectRoot "test-output"
            if (-not (Test-Path $testOutputDir)) {
                New-Item -ItemType Directory -Path $testOutputDir -Force | Out-Null
            }
            $OutputPath = Join-Path $testOutputDir "$($ReportType.ToLower()).html"
        }
    } else {
        # For "All", ensure test-output directory exists
        $projectRoot = Split-Path $PSScriptRoot -Parent
        $testOutputDir = Join-Path $projectRoot "test-output"
        if (-not (Test-Path $testOutputDir)) {
            New-Item -ItemType Directory -Path $testOutputDir -Force | Out-Null
        }
    }
    
    # Ensure output path is absolute (resolve relative paths) - only for non-All types
    if ($ReportType -ne 'All') {
        if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
            $OutputPath = Join-Path (Get-Location).Path $OutputPath
        }
        
        # Ensure output directory exists
        $outputDir = Split-Path -Parent $OutputPath
        if ($outputDir -and -not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        }
        
        Write-Host "`n=== Testing $ReportType Report ===" -ForegroundColor Cyan
        Write-Host "Generating test data..." -ForegroundColor Yellow
        Write-Host "Output path: $OutputPath" -ForegroundColor Gray
    } else {
        Write-Host "`n=== Generating All Reports ===" -ForegroundColor Cyan
        Write-Host "Generating all test data..." -ForegroundColor Yellow
        Write-Host "Output directory: $testOutputDir" -ForegroundColor Gray
    }
    
    $tenantId = "test-tenant-12345"
    
    switch ($ReportType) {
        'Security' {
            $data = New-TestSecurityData
            Export-SecurityReport -AuditResult $data -OutputPath $OutputPath
        }
        'VMBackup' {
            $data = New-TestVMBackupData
            Export-VMBackupReport -VMInventory $data -OutputPath $OutputPath -TenantId $tenantId
        }
        'ChangeTracking' {
            $data = New-TestChangeTrackingData -ChangeCount 75
            Export-ChangeTrackingReport -ChangeTrackingData $data -OutputPath $OutputPath -TenantId $tenantId
        }
        'CostTracking' {
            $data = New-TestCostTrackingData
            Export-CostTrackingReport -CostTrackingData $data -OutputPath $OutputPath -TenantId $tenantId
        }
        'EOL' {
            $data = New-TestEOLData
            Export-EOLReport -EOLFindings $data -OutputPath $OutputPath -TenantId $tenantId
        }
        'NetworkInventory' {
            $data = New-TestNetworkInventoryData
            Export-NetworkInventoryReport -NetworkInventory $data -OutputPath $OutputPath -TenantId $tenantId
        }
        'RBAC' {
            $data = New-TestRBACData
            Export-RBACReport -RBACData $data -OutputPath $OutputPath -TenantId $tenantId
        }
        'Advisor' {
            $data = New-TestAdvisorData
            Export-AdvisorReport -AdvisorRecommendations $data -OutputPath $OutputPath -TenantId $tenantId
        }
        'Dashboard' {
            # Dashboard needs all report data, so generate all reports first
            Write-Host "Generating all test data for dashboard..." -ForegroundColor Yellow
            $allTestData = New-TestAllData
            
            # Create a mock AuditResult object
            $auditResult = [PSCustomObject]@{
                TenantId = $tenantId
                TotalResources = 100
                SubscriptionsScanned = @(
                    [PSCustomObject]@{ Id = "sub-0"; Name = "Sub-Prod-001" },
                    [PSCustomObject]@{ Id = "sub-1"; Name = "Sub-Dev-002" },
                    [PSCustomObject]@{ Id = "sub-2"; Name = "Sub-Test-003" }
                )
                Findings = $allTestData.Security.Findings
                VMInventory = $allTestData.VMBackup
                AdvisorRecommendations = $allTestData.Advisor
                ChangeTrackingData = $allTestData.ChangeTracking
                NetworkInventory = $allTestData.NetworkInventory
                CostTrackingData = $allTestData.CostTracking
                RBACInventory = $allTestData.RBAC
                EOLSummary = [PSCustomObject]@{
                    TotalFindings = $allTestData.EOL.Count
                    ComponentCount = @($allTestData.EOL | Select-Object -ExpandProperty Component -Unique).Count
                    CriticalCount = @($allTestData.EOL | Where-Object { $_.Severity -eq 'Critical' }).Count
                    HighCount = @($allTestData.EOL | Where-Object { $_.Severity -eq 'High' }).Count
                    MediumCount = @($allTestData.EOL | Where-Object { $_.Severity -eq 'Medium' }).Count
                    LowCount = @($allTestData.EOL | Where-Object { $_.Severity -eq 'Low' }).Count
                    SoonestDeadline = ($allTestData.EOL | Sort-Object EOLDate | Select-Object -First 1).EOLDate
                }
                ToolVersion = "2.0.0"
                ScanEndTime = Get-Date
            }
            
            # Generate all detail reports first to get their report data
            $tempOutputDir = Join-Path (Split-Path $OutputPath -Parent) "dashboard-temp"
            if (-not (Test-Path $tempOutputDir)) {
                New-Item -ItemType Directory -Path $tempOutputDir -Force | Out-Null
            }
            
            Write-Host "Generating detail reports to collect metadata..." -ForegroundColor Yellow
            $securityReportData = $null
            $vmBackupReportData = $null
            $advisorReportData = $null
            $changeTrackingReportData = $null
            $networkInventoryReportData = $null
            $costTrackingReportData = $null
            $rbacReportData = $null
            
            try {
                $securityResult = Export-SecurityReport -AuditResult $allTestData.Security -OutputPath (Join-Path $tempOutputDir "security.html")
                if ($securityResult -is [hashtable]) { $securityReportData = $securityResult }
            } catch { Write-Warning "Security report generation failed: $_" }
            
            try {
                $vmBackupResult = Export-VMBackupReport -VMInventory $allTestData.VMBackup -OutputPath (Join-Path $tempOutputDir "vm-backup.html") -TenantId $tenantId
                if ($vmBackupResult -is [hashtable]) { $vmBackupReportData = $vmBackupResult }
            } catch { Write-Warning "VM Backup report generation failed: $_" }
            
            try {
                $advisorResult = Export-AdvisorReport -AdvisorRecommendations $allTestData.Advisor -OutputPath (Join-Path $tempOutputDir "advisor.html") -TenantId $tenantId
                if ($advisorResult -is [hashtable]) { $advisorReportData = $advisorResult }
            } catch { Write-Warning "Advisor report generation failed: $_" }
            
            try {
                $changeTrackingResult = Export-ChangeTrackingReport -ChangeTrackingData $allTestData.ChangeTracking -OutputPath (Join-Path $tempOutputDir "change-tracking.html") -TenantId $tenantId
                if ($changeTrackingResult -is [hashtable]) { $changeTrackingReportData = $changeTrackingResult }
            } catch { Write-Warning "Change Tracking report generation failed: $_" }
            
            try {
                $networkInventoryResult = Export-NetworkInventoryReport -NetworkInventory $allTestData.NetworkInventory -OutputPath (Join-Path $tempOutputDir "network.html") -TenantId $tenantId
                if ($networkInventoryResult -is [hashtable]) { $networkInventoryReportData = $networkInventoryResult }
            } catch { Write-Warning "Network Inventory report generation failed: $_" }
            
            try {
                $costTrackingResult = Export-CostTrackingReport -CostTrackingData $allTestData.CostTracking -OutputPath (Join-Path $tempOutputDir "cost-tracking.html") -TenantId $tenantId
                if ($costTrackingResult -is [hashtable]) { $costTrackingReportData = $costTrackingResult }
            } catch { Write-Warning "Cost Tracking report generation failed: $_" }
            
            try {
                $rbacResult = Export-RBACReport -RBACData $allTestData.RBAC -OutputPath (Join-Path $tempOutputDir "rbac.html") -TenantId $tenantId
                if ($rbacResult -is [hashtable]) { $rbacReportData = $rbacResult }
            } catch { Write-Warning "RBAC report generation failed: $_" }
            
            # Generate dashboard with all report data
            Export-DashboardReport `
                -AuditResult $auditResult `
                -VMInventory $allTestData.VMBackup `
                -AdvisorRecommendations $allTestData.Advisor `
                -SecurityReportData $securityReportData `
                -VMBackupReportData $vmBackupReportData `
                -AdvisorReportData $advisorReportData `
                -ChangeTrackingReportData $changeTrackingReportData `
                -NetworkInventoryReportData $networkInventoryReportData `
                -CostTrackingReportData $costTrackingReportData `
                -RBACReportData $rbacReportData `
                -OutputPath $OutputPath `
                -TenantId $tenantId
            
            # Clean up temp directory
            if (Test-Path $tempOutputDir) {
                Remove-Item $tempOutputDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        'All' {
            # Generate all individual reports first, then Dashboard
            Write-Host "`nGenerating all individual reports..." -ForegroundColor Yellow
            $allTestData = New-TestAllData
            
            # Generate all individual reports to test-output directory
            $reportPaths = @{}
            
            try {
                $securityPath = Join-Path $testOutputDir "security.html"
                Export-SecurityReport -AuditResult $allTestData.Security -OutputPath $securityPath
                $reportPaths['Security'] = $securityPath
                Write-Host "  [OK] Security report: $securityPath" -ForegroundColor Green
            } catch { Write-Warning "Security report generation failed: $_" }
            
            try {
                $vmBackupPath = Join-Path $testOutputDir "vm-backup.html"
                Export-VMBackupReport -VMInventory $allTestData.VMBackup -OutputPath $vmBackupPath -TenantId $tenantId
                $reportPaths['VMBackup'] = $vmBackupPath
                Write-Host "  [OK] VM Backup report: $vmBackupPath" -ForegroundColor Green
            } catch { Write-Warning "VM Backup report generation failed: $_" }
            
            try {
                $changeTrackingPath = Join-Path $testOutputDir "change-tracking.html"
                Export-ChangeTrackingReport -ChangeTrackingData $allTestData.ChangeTracking -OutputPath $changeTrackingPath -TenantId $tenantId
                $reportPaths['ChangeTracking'] = $changeTrackingPath
                Write-Host "  [OK] Change Tracking report: $changeTrackingPath" -ForegroundColor Green
            } catch { Write-Warning "Change Tracking report generation failed: $_" }
            
            try {
                $costTrackingPath = Join-Path $testOutputDir "cost-tracking.html"
                Export-CostTrackingReport -CostTrackingData $allTestData.CostTracking -OutputPath $costTrackingPath -TenantId $tenantId
                $reportPaths['CostTracking'] = $costTrackingPath
                Write-Host "  [OK] Cost Tracking report: $costTrackingPath" -ForegroundColor Green
            } catch { Write-Warning "Cost Tracking report generation failed: $_" }
            
            try {
                $eolPath = Join-Path $testOutputDir "eol.html"
                Export-EOLReport -EOLFindings $allTestData.EOL -OutputPath $eolPath -TenantId $tenantId
                $reportPaths['EOL'] = $eolPath
                Write-Host "  [OK] EOL report: $eolPath" -ForegroundColor Green
            } catch { Write-Warning "EOL report generation failed: $_" }
            
            try {
                $networkInventoryPath = Join-Path $testOutputDir "network.html"
                Export-NetworkInventoryReport -NetworkInventory $allTestData.NetworkInventory -OutputPath $networkInventoryPath -TenantId $tenantId
                $reportPaths['NetworkInventory'] = $networkInventoryPath
                Write-Host "  [OK] Network Inventory report: $networkInventoryPath" -ForegroundColor Green
            } catch { Write-Warning "Network Inventory report generation failed: $_" }
            
            try {
                $rbacPath = Join-Path $testOutputDir "rbac.html"
                Export-RBACReport -RBACData $allTestData.RBAC -OutputPath $rbacPath -TenantId $tenantId
                $reportPaths['RBAC'] = $rbacPath
                Write-Host "  [OK] RBAC report: $rbacPath" -ForegroundColor Green
            } catch { Write-Warning "RBAC report generation failed: $_" }
            
            try {
                $advisorPath = Join-Path $testOutputDir "advisor.html"
                Export-AdvisorReport -AdvisorRecommendations $allTestData.Advisor -OutputPath $advisorPath -TenantId $tenantId
                $reportPaths['Advisor'] = $advisorPath
                Write-Host "  [OK] Advisor report: $advisorPath" -ForegroundColor Green
            } catch { Write-Warning "Advisor report generation failed: $_" }
            
            # Now generate Dashboard
            Write-Host "`nGenerating Dashboard report..." -ForegroundColor Yellow
            
            # Create a mock AuditResult object for Dashboard
            $auditResult = [PSCustomObject]@{
                TenantId = $tenantId
                TotalResources = 100
                SubscriptionsScanned = @(
                    [PSCustomObject]@{ Id = "sub-0"; Name = "Sub-Prod-001" },
                    [PSCustomObject]@{ Id = "sub-1"; Name = "Sub-Dev-002" },
                    [PSCustomObject]@{ Id = "sub-2"; Name = "Sub-Test-003" }
                )
                Findings = $allTestData.Security.Findings
                VMInventory = $allTestData.VMBackup
                AdvisorRecommendations = $allTestData.Advisor
                ChangeTrackingData = $allTestData.ChangeTracking
                NetworkInventory = $allTestData.NetworkInventory
                CostTrackingData = $allTestData.CostTracking
                RBACInventory = $allTestData.RBAC
                EOLSummary = [PSCustomObject]@{
                    TotalFindings = $allTestData.EOL.Count
                    ComponentCount = @($allTestData.EOL | Select-Object -ExpandProperty Component -Unique).Count
                    CriticalCount = @($allTestData.EOL | Where-Object { $_.Severity -eq 'Critical' }).Count
                    HighCount = @($allTestData.EOL | Where-Object { $_.Severity -eq 'High' }).Count
                    MediumCount = @($allTestData.EOL | Where-Object { $_.Severity -eq 'Medium' }).Count
                    LowCount = @($allTestData.EOL | Where-Object { $_.Severity -eq 'Low' }).Count
                    SoonestDeadline = ($allTestData.EOL | Sort-Object EOLDate | Select-Object -First 1).EOLDate
                }
                ToolVersion = "2.0.0"
                ScanEndTime = Get-Date
            }
            
            # Generate all detail reports to temp directory to collect metadata for Dashboard
            $tempOutputDir = Join-Path $testOutputDir "dashboard-temp"
            if (-not (Test-Path $tempOutputDir)) {
                New-Item -ItemType Directory -Path $tempOutputDir -Force | Out-Null
            }
            
            Write-Host "Generating detail reports to collect metadata..." -ForegroundColor Yellow
            $securityReportData = $null
            $vmBackupReportData = $null
            $advisorReportData = $null
            $changeTrackingReportData = $null
            $networkInventoryReportData = $null
            $costTrackingReportData = $null
            $rbacReportData = $null
            
            try {
                $securityResult = Export-SecurityReport -AuditResult $allTestData.Security -OutputPath (Join-Path $tempOutputDir "security.html")
                if ($securityResult -is [hashtable]) { $securityReportData = $securityResult }
            } catch { Write-Warning "Security report generation failed: $_" }
            
            try {
                $vmBackupResult = Export-VMBackupReport -VMInventory $allTestData.VMBackup -OutputPath (Join-Path $tempOutputDir "vm-backup.html") -TenantId $tenantId
                if ($vmBackupResult -is [hashtable]) { $vmBackupReportData = $vmBackupResult }
            } catch { Write-Warning "VM Backup report generation failed: $_" }
            
            try {
                $advisorResult = Export-AdvisorReport -AdvisorRecommendations $allTestData.Advisor -OutputPath (Join-Path $tempOutputDir "advisor.html") -TenantId $tenantId
                if ($advisorResult -is [hashtable]) { $advisorReportData = $advisorResult }
            } catch { Write-Warning "Advisor report generation failed: $_" }
            
            try {
                $changeTrackingResult = Export-ChangeTrackingReport -ChangeTrackingData $allTestData.ChangeTracking -OutputPath (Join-Path $tempOutputDir "change-tracking.html") -TenantId $tenantId
                if ($changeTrackingResult -is [hashtable]) { $changeTrackingReportData = $changeTrackingResult }
            } catch { Write-Warning "Change Tracking report generation failed: $_" }
            
            try {
                $networkInventoryResult = Export-NetworkInventoryReport -NetworkInventory $allTestData.NetworkInventory -OutputPath (Join-Path $tempOutputDir "network.html") -TenantId $tenantId
                if ($networkInventoryResult -is [hashtable]) { $networkInventoryReportData = $networkInventoryResult }
            } catch { Write-Warning "Network Inventory report generation failed: $_" }
            
            try {
                $costTrackingResult = Export-CostTrackingReport -CostTrackingData $allTestData.CostTracking -OutputPath (Join-Path $tempOutputDir "cost-tracking.html") -TenantId $tenantId
                if ($costTrackingResult -is [hashtable]) { $costTrackingReportData = $costTrackingResult }
            } catch { Write-Warning "Cost Tracking report generation failed: $_" }
            
            try {
                $rbacResult = Export-RBACReport -RBACData $allTestData.RBAC -OutputPath (Join-Path $tempOutputDir "rbac.html") -TenantId $tenantId
                if ($rbacResult -is [hashtable]) { $rbacReportData = $rbacResult }
            } catch { Write-Warning "RBAC report generation failed: $_" }
            
            # Generate dashboard
            $dashboardPath = Join-Path $testOutputDir "index.html"
            Export-DashboardReport `
                -AuditResult $auditResult `
                -VMInventory $allTestData.VMBackup `
                -AdvisorRecommendations $allTestData.Advisor `
                -SecurityReportData $securityReportData `
                -VMBackupReportData $vmBackupReportData `
                -AdvisorReportData $advisorReportData `
                -ChangeTrackingReportData $changeTrackingReportData `
                -NetworkInventoryReportData $networkInventoryReportData `
                -CostTrackingReportData $costTrackingReportData `
                -RBACReportData $rbacReportData `
                -OutputPath $dashboardPath `
                -TenantId $tenantId
            
            $reportPaths['Dashboard'] = $dashboardPath
            Write-Host "  [OK] Dashboard report: $dashboardPath" -ForegroundColor Green
            
            # Clean up temp directory
            if (Test-Path $tempOutputDir) {
                Remove-Item $tempOutputDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            
            # Open only the Dashboard report
            Write-Host "`n[OK] All reports generated successfully!" -ForegroundColor Green
            if ($reportPaths.ContainsKey('Dashboard')) {
                $dashboardPath = $reportPaths['Dashboard']
                if (Test-Path $dashboardPath) {
                    $fullPath = (Resolve-Path $dashboardPath).Path
                    Write-Host "Opening Dashboard report..." -ForegroundColor Yellow
                    Start-Process $fullPath -ErrorAction SilentlyContinue
                }
            }
            return
        }
    }
    
    # Safety check: if ReportType is "All", we should have returned already
    if ($ReportType -eq 'All') {
        return
    }
    
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        Write-Host "`n[OK] Report generated: $OutputPath" -ForegroundColor Green
        Write-Host "Open the file in your browser to test CSS changes!" -ForegroundColor Yellow
        
        # Try to open the file
        if ($OutputPath -and (Test-Path $OutputPath -ErrorAction SilentlyContinue)) {
            $fullPath = (Resolve-Path $OutputPath).Path
            Start-Process $fullPath -ErrorAction SilentlyContinue
        }
    }
}

# Functions are available after dot-sourcing this script
# Usage: . .\Tools\New-TestData.ps1

