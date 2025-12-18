<#
.SYNOPSIS
    Scans Azure SQL Databases and Servers for CIS security compliance (P0 and P1 controls).

.DESCRIPTION
    Checks SQL Servers and Databases against CIS Azure Foundations Benchmark controls:
    P0: TLS 1.2, No allow-all firewall, Auditing enabled, TDE enabled
    P1: Azure AD admin, Defender for SQL, Azure AD-only authentication

.PARAMETER SubscriptionId
    Azure subscription ID to scan.

.PARAMETER SubscriptionName
    Human-readable subscription name.

.OUTPUTS
    Array of SecurityFinding objects.
#>
function Get-AzureSqlDatabaseFindings {
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
                    if ($mapping.resourceType -eq "Microsoft.Sql/servers") {
                        $resourceTypeMapping["Microsoft.Sql/servers"] = $mapping
                        break
                    }
                }
            }
        }
        catch {
            Write-Verbose "Failed to load ResourceTypeMapping: $_"
        }
    }
    
    # Load enabled controls from JSON
    $controls = Get-ControlsForCategory -Category "SQL" -IncludeLevel2:$IncludeLevel2
    if ($null -eq $controls -or $controls.Count -eq 0) {
        Write-Verbose "No enabled SQL controls found in configuration"
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
    
    try {
        $sqlServers = Invoke-AzureApiWithRetry {
            Get-AzSqlServer -ErrorAction Stop
        }
    }
    catch {
        Write-Warning "Failed to retrieve SQL servers in subscription $SubscriptionName : $_"
        return @{
            Findings = $findings
            EOLFindings = $eolFindings
            ResourceCount = 0
            ControlCount = 0
            FailureCount = 0
            EOLCount = 0
        }
    }
    
    if (-not $sqlServers) {
        Write-Verbose "No SQL servers found in subscription $SubscriptionName"
        return @{
            Findings = $findings
            EOLFindings = $eolFindings
            ResourceCount = 0
            ControlCount = 0
            FailureCount = 0
            EOLCount = 0
        }
    }
    
    foreach ($server in $sqlServers) {
        Write-Verbose "Scanning SQL server: $($server.ServerName)"
        
        # Track this resource as scanned
        $resourceKey = if ($server.Id) { $server.Id } else { "$($server.ResourceGroupName)/$($server.ServerName)" }
        if (-not $uniqueResourcesScanned.ContainsKey($resourceKey)) {
            $uniqueResourcesScanned[$resourceKey] = $true
        }
        
        # Control: SQL Server - TLS Version
        $tlsControl = $controlLookup["SQL Server - TLS Version"]
        if ($tlsControl) {
            $controlsEvaluated++
            $minTlsVersion = if ($server.MinimalTlsVersion) { $server.MinimalTlsVersion } else { "1.0" }
            $tlsStatus = if ($minTlsVersion -ge "1.2") { "PASS" } else { "FAIL" }
            
            $remediationCmd = $tlsControl.remediationCommand -replace '\{serverName\}', $server.ServerName -replace '\{rg\}', $server.ResourceGroupName
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $server.ResourceGroupName `
                -ResourceType "Microsoft.Sql/servers" `
                -ResourceName $server.ServerName `
                -ResourceId $server.ResourceId `
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
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }
        
        # Control 4.1.2: SQL Firewall - No Allow All
        # This control checks for:
        # 1. Allow-all internet rule (0.0.0.0-255.255.255.255) - Critical risk
        # 2. Allow Azure Services rule (0.0.0.0-0.0.0.0) - Medium risk (still a security concern)
        $firewallControl = $controlLookup["SQL Firewall - No Allow All"]
        if ($firewallControl) {
            $controlsEvaluated++
            try {
                $firewallRules = Invoke-AzureApiWithRetry {
                    Get-AzSqlServerFirewallRule -ResourceGroupName $server.ResourceGroupName -ServerName $server.ServerName -ErrorAction SilentlyContinue
                }
                $allowAllInternet = $false
                $allowAzureServices = $false
                $problematicRuleName = $null
                
                if ($firewallRules) {
                    foreach ($rule in $firewallRules) {
                        # Check for Allow-all internet (0.0.0.0-255.255.255.255)
                        if ($rule.StartIpAddress -eq "0.0.0.0" -and $rule.EndIpAddress -eq "255.255.255.255") {
                            $allowAllInternet = $true
                            $problematicRuleName = $rule.FirewallRuleName
                            break
                        }
                        # Check for Allow Azure Services (0.0.0.0-0.0.0.0)
                        # This is also a security risk as it allows all Azure services to access the server
                        elseif ($rule.StartIpAddress -eq "0.0.0.0" -and $rule.EndIpAddress -eq "0.0.0.0") {
                            $allowAzureServices = $true
                            if (-not $problematicRuleName) {
                                $problematicRuleName = $rule.FirewallRuleName
                            }
                        }
                    }
                }
                
                $allowAllRule = $allowAllInternet -or $allowAzureServices
                
                # Build descriptive current value
                $currentValue = if ($allowAllInternet) {
                    "Allow-all internet rule present (0.0.0.0-255.255.255.255) - Critical risk"
                } elseif ($allowAzureServices) {
                    "Allow Azure Services rule present (0.0.0.0-0.0.0.0) - Security risk"
                } else {
                    "No allow-all rules found"
                }
            }
            catch {
                $allowAllRule = $false
                $currentValue = "Unable to check firewall rules"
                $problematicRuleName = $null
            }
            
            $firewallStatus = if (-not $allowAllRule) { "PASS" } else { "FAIL" }
            
            # Update remediation command with actual rule name if found
            $remediationCmd = $firewallControl.remediationCommand -replace '\{serverName\}', $server.ServerName -replace '\{rg\}', $server.ResourceGroupName
            if ($problematicRuleName) {
                $remediationCmd = $remediationCmd -replace '\{ruleName\}', $problematicRuleName
            } else {
                $remediationCmd = $remediationCmd -replace '\{ruleName\}', '<rule-name>'
            }
            
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $server.ResourceGroupName `
                -ResourceType "Microsoft.Sql/servers" `
                -ResourceName $server.ServerName `
                -ResourceId $server.ResourceId `
                -ControlId $firewallControl.controlId `
                -ControlName $firewallControl.controlName `
                -Category $firewallControl.category `
                -Frameworks $firewallControl.frameworks `
                -Severity $firewallControl.severity `
                -CisLevel $firewallControl.level `
                -CurrentValue $currentValue `
                -ExpectedValue $firewallControl.expectedValue `
                -Status $firewallStatus `
                -RemediationSteps $firewallControl.businessImpact `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }
        
        # Control 4.1.1: SQL Auditing Enabled
        $auditControl = $controlLookup["SQL Auditing Enabled"]
        if ($auditControl) {
            $controlsEvaluated++
            try {
                $auditing = Invoke-AzureApiWithRetry {
                    Get-AzSqlServerAuditing -ResourceGroupName $server.ResourceGroupName -ServerName $server.ServerName -ErrorAction SilentlyContinue
                }
                $auditingEnabled = if ($auditing) { $auditing.AuditState -eq "Enabled" } else { $false }
            }
            catch {
                $auditingEnabled = $false
            }
            
            $auditStatus = if ($auditingEnabled) { "PASS" } else { "FAIL" }
            
            $remediationCmd = $auditControl.remediationCommand -replace '\{rg\}', $server.ResourceGroupName -replace '\{serverName\}', $server.ServerName -replace '\{storageAccount\}', '<storageAccountName>'
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $server.ResourceGroupName `
                -ResourceType "Microsoft.Sql/servers" `
                -ResourceName $server.ServerName `
                -ResourceId $server.ResourceId `
                -ControlId $auditControl.controlId `
                -ControlName $auditControl.controlName `
                -Category $auditControl.category `
                -Frameworks $auditControl.frameworks `
                -Severity $auditControl.severity `
                -CisLevel $auditControl.level `
                -CurrentValue $(if ($auditingEnabled) { "Enabled" } else { "Disabled" }) `
                -ExpectedValue $auditControl.expectedValue `
                -Status $auditStatus `
                -RemediationSteps $auditControl.businessImpact `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }
        
        # Control 4.1.5: Transparent Data Encryption (TDE) (check databases)
        $tdeControl = $controlLookup["Transparent Data Encryption (TDE)"]
        if ($tdeControl) {
            $controlsEvaluated++
            try {
                $databases = Invoke-AzureApiWithRetry {
                    Get-AzSqlDatabase -ResourceGroupName $server.ResourceGroupName -ServerName $server.ServerName -ErrorAction SilentlyContinue
                }
                if ($databases) {
                    foreach ($db in $databases) {
                        try {
                            $tde = Invoke-AzureApiWithRetry {
                                Get-AzSqlDatabaseTransparentDataEncryption -ResourceGroupName $server.ResourceGroupName -ServerName $server.ServerName -DatabaseName $db.DatabaseName -ErrorAction SilentlyContinue
                            }
                            $tdeEnabled = if ($tde) { $tde.State -eq "Enabled" } else { $false }
                        }
                        catch {
                            $tdeEnabled = $false
                        }
                        
                        $tdeStatus = if ($tdeEnabled) { "PASS" } else { "FAIL" }
                        
                        $remediationCmd = $tdeControl.remediationCommand -replace '\{rg\}', $server.ResourceGroupName -replace '\{serverName\}', $server.ServerName -replace '\{dbName\}', $db.DatabaseName
                        $finding = New-SecurityFinding `
                            -SubscriptionId $SubscriptionId `
                            -SubscriptionName $SubscriptionName `
                            -ResourceGroup $server.ResourceGroupName `
                            -ResourceType "Microsoft.Sql/servers/databases" `
                            -ResourceName "$($server.ServerName)/$($db.DatabaseName)" `
                            -ResourceId $db.ResourceId `
                            -ControlId $tdeControl.controlId `
                            -ControlName $tdeControl.controlName `
                            -Category $tdeControl.category `
                            -Frameworks $tdeControl.frameworks `
                            -Severity $tdeControl.severity `
                            -CisLevel $tdeControl.level `
                            -CurrentValue $(if ($tdeEnabled) { "Enabled" } else { "Disabled" }) `
                            -ExpectedValue $tdeControl.expectedValue `
                            -Status $tdeStatus `
                            -RemediationSteps $tdeControl.businessImpact `
                            -RemediationCommand $remediationCmd
                        $findings.Add($finding)
                    }
                }
            }
            catch {
                Write-Verbose "Could not check TDE for server $($server.ServerName): $_"
            }
        }
        
        # P1 Control 4.1.4: Azure AD Admin Configured
        try {
            $adAdmin = Invoke-AzureApiWithRetry {
                Get-AzSqlServerActiveDirectoryAdministrator -ResourceGroupName $server.ResourceGroupName -ServerName $server.ServerName -ErrorAction SilentlyContinue
            }
            $adAdminConfigured = if ($adAdmin -and $adAdmin.AdministratorType -eq "ActiveDirectory") { $true } else { $false }
        }
        catch {
            $adAdminConfigured = $false
        }
        
        # Control: Azure AD Admin Configured
        $adAdminControl = $controlLookup["Azure AD Admin Configured"]
        if ($adAdminControl) {
            $controlsEvaluated++
            $adAdminStatus = if ($adAdminConfigured) { "PASS" } else { "FAIL" }
            $remediationCmd = $adAdminControl.remediationCommand -replace '\{rg\}', $server.ResourceGroupName -replace '\{serverName\}', $server.ServerName
            
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $server.ResourceGroupName `
                -ResourceType "Microsoft.Sql/servers" `
                -ResourceName $server.ServerName `
                -ResourceId $server.ResourceId `
                -ControlId $adAdminControl.controlId `
                -ControlName $adAdminControl.controlName `
                -Category $adAdminControl.category `
                -Frameworks $adAdminControl.frameworks `
                -Severity $adAdminControl.severity `
                -CisLevel $adAdminControl.level `
                -CurrentValue $(if ($adAdminConfigured) { "Configured" } else { "Not configured" }) `
                -ExpectedValue $adAdminControl.expectedValue `
                -Status $adAdminStatus `
                -RemediationSteps $adAdminControl.businessImpact `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }
        
        # P1 Control 4.2.1: Defender for SQL (DISABLED - Commercial Feature)
        # This control is disabled as it requires a commercial subscription ($15/server/month)
        # Uncomment the code below to enable this check:
        <#
        try {
            $defender = Invoke-AzureApiWithRetry {
                Get-AzSqlServerAdvancedThreatProtectionSetting -ResourceGroupName $server.ResourceGroupName -ServerName $server.ServerName -ErrorAction SilentlyContinue
            }
            $defenderEnabled = if ($defender) { $defender.State -eq "Enabled" } else { $false }
        }
        catch {
            $defenderEnabled = $false
        }
        
        $defenderStatus = if ($defenderEnabled) { "PASS" } else { "FAIL" }
        
        $finding = New-SecurityFinding `
            -SubscriptionId $SubscriptionId `
            -SubscriptionName $SubscriptionName `
            -ResourceGroup $server.ResourceGroupName `
            -ResourceType "Microsoft.Sql/servers" `
            -ResourceName $server.ServerName `
            -ResourceId $server.ResourceId `
            -ControlId "4.2.1" `
            -ControlName "Defender for SQL" `
            -Category "SQL" `
            -Severity "High" `
            -CurrentValue $(if ($defenderEnabled) { "Enabled" } else { "Disabled" }) `
            -ExpectedValue "Enabled" `
            -Status $defenderStatus `
            -RemediationSteps "Enable Microsoft Defender for SQL to detect anomalous activities and potential threats." `
            -RemediationCommand "az sql server threat-policy update --resource-group $($server.ResourceGroupName) --server $($server.ServerName) --state Enabled"
        $findings.Add($finding)
        #>
        
        # Control: Azure AD-Only Authentication
        $adOnlyControl = $controlLookup["Azure AD-Only Authentication"]
        if ($adOnlyControl) {
            $controlsEvaluated++
            try {
                $adOnlyAuth = Invoke-AzureApiWithRetry {
                    Get-AzSqlServerActiveDirectoryOnlyAuthentication -ResourceGroupName $server.ResourceGroupName -ServerName $server.ServerName -ErrorAction SilentlyContinue
                }
                $adOnlyEnabled = if ($adOnlyAuth) { $adOnlyAuth.AzureADOnlyAuthentication } else { $false }
            }
            catch {
                $adOnlyEnabled = $false
            }
            
            $adOnlyStatus = if ($adOnlyEnabled) { "PASS" } else { "FAIL" }
            $remediationCmd = $adOnlyControl.remediationCommand -replace '\{rg\}', $server.ResourceGroupName -replace '\{serverName\}', $server.ServerName
            
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $server.ResourceGroupName `
                -ResourceType "Microsoft.Sql/servers" `
                -ResourceName $server.ServerName `
                -ResourceId $server.ResourceId `
                -ControlId $adOnlyControl.controlId `
                -ControlName $adOnlyControl.controlName `
                -Category $adOnlyControl.category `
                -Frameworks $adOnlyControl.frameworks `
                -Severity $adOnlyControl.severity `
                -CisLevel $adOnlyControl.level `
                -CurrentValue $adOnlyEnabled.ToString() `
                -ExpectedValue $adOnlyControl.expectedValue `
                -Status $adOnlyStatus `
                -RemediationSteps $adOnlyControl.businessImpact `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }
        
        # EOL Checking: Check if this SQL Server matches any deprecation rules
        if ($deprecationRules -and $deprecationRules.Count -gt 0) {
            $mapping = if ($resourceTypeMapping.ContainsKey("Microsoft.Sql/servers")) {
                $resourceTypeMapping["Microsoft.Sql/servers"]
            } else {
                $null
            }
            
            $eolStatus = Test-ResourceEOLStatus `
                -Resource $server `
                -ResourceType "Microsoft.Sql/servers" `
                -DeprecationRules $deprecationRules `
                -ResourceTypeMapping @{ "Microsoft.Sql/servers" = $mapping }
            
            if ($eolStatus.Matched -and $eolStatus.Rule) {
                $rule = $eolStatus.Rule
                $eolFinding = New-EOLFinding `
                    -SubscriptionId $SubscriptionId `
                    -SubscriptionName $SubscriptionName `
                    -ResourceGroup $server.ResourceGroupName `
                    -ResourceType "Microsoft.Sql/servers" `
                    -ResourceName $server.ServerName `
                    -ResourceId $server.ResourceId `
                    -Component $rule.component `
                    -Status $rule.status `
                    -Deadline $eolStatus.Deadline `
                    -Severity $eolStatus.Severity `
                    -DaysUntilDeadline $eolStatus.DaysUntilDeadline `
                    -ActionRequired $rule.actionRequired `
                    -MigrationGuide $rule.migrationGuide `
                    -References $(if ($rule.references) { $rule.references } else { @() })
                $eolFindings.Add($eolFinding)
            }
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


