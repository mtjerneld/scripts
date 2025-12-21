<#
.SYNOPSIS
    Scans Azure App Services (Web Apps) for CIS security compliance (P0 and P1 controls).

.DESCRIPTION
    Checks App Services against CIS Azure Foundations Benchmark controls:
    P0: Minimum TLS 1.2, HTTPS only, FTP disabled
    P1: Authentication enabled, Managed Identity, Remote debugging disabled

.PARAMETER SubscriptionId
    Azure subscription ID to scan.

.PARAMETER SubscriptionName
    Human-readable subscription name.

.OUTPUTS
    Array of SecurityFinding objects.
#>
function Get-AzureAppServiceFindings {
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
    $controls = Get-ControlsForCategory -Category "AppService" -IncludeLevel2:$IncludeLevel2
    if ($null -eq $controls -or $controls.Count -eq 0) {
        Write-Verbose "No enabled AppService controls found in configuration for subscription $SubscriptionName"
        return @{
            Findings = $findings
            EOLFindings = $eolFindings
            ResourceCount = 0
            ControlCount = 0
            FailureCount = 0
            EOLCount = 0
        }
    }
    Write-Verbose "Loaded $($controls.Count) AppService control(s) from configuration"
    
    # Create lookup hashtable for quick control access
    $controlLookup = @{}
    foreach ($control in $controls) {
        $controlLookup[$control.controlName] = $control
    }
    Write-Verbose "Control lookup created with keys: $($controlLookup.Keys -join ', ')"
    
    $webApps = @()
    
    # Try Get-AzWebApp first
    try {
        $webApps = Invoke-AzureApiWithRetry {
            Get-AzWebApp -ErrorAction Stop
        }
        Write-Verbose "Get-AzWebApp returned $($webApps.Count) web app(s)"
    }
    catch {
        Write-Verbose "Get-AzWebApp failed, trying Get-AzResource as fallback: $_"
        
        # Fallback: Use Get-AzResource to find web apps
        try {
            $webAppResources = Invoke-AzureApiWithRetry {
                Get-AzResource -ResourceType "Microsoft.Web/sites" -ErrorAction Stop
            }
            
            if ($webAppResources) {
                Write-Verbose "Get-AzResource found $($webAppResources.Count) web app resource(s)"
                
                # Convert resources to web app objects by getting each one
                foreach ($resource in $webAppResources) {
                    try {
                        $webApp = Invoke-AzureApiWithRetry {
                            Get-AzWebApp -ResourceGroupName $resource.ResourceGroupName -Name $resource.Name -ErrorAction SilentlyContinue
                        }
                        if ($webApp) {
                            $webApps += $webApp
                        }
                    }
                    catch {
                        Write-Verbose "Could not get web app $($resource.Name): $_"
                    }
                }
            }
        }
        catch {
            Write-Warning "Failed to retrieve web apps in subscription $SubscriptionName using both methods: $_"
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
    }
    
    # Handle case where no web apps found
    if ($null -eq $webApps) {
        Write-Verbose "No web apps found in subscription $SubscriptionName (Get-AzWebApp returned null)"
        return @{
            Findings = $findings
            EOLFindings = $eolFindings
            ResourceCount = 0
            ControlCount = 0
            FailureCount = 0
            EOLCount = 0
        }
    }
    
    # Convert to array if single object
    if ($webApps -isnot [System.Array]) {
        $webApps = @($webApps)
    }
    
    if ($webApps.Count -eq 0) {
        Write-Verbose "No web apps found in subscription $SubscriptionName (empty array)"
        return @{
            Findings = $findings
            EOLFindings = $eolFindings
            ResourceCount = 0
            ControlCount = 0
            FailureCount = 0
            EOLCount = 0
        }
    }
    
    Write-Verbose "Found $($webApps.Count) web app(s) in subscription $SubscriptionName"
    
    $skippedCount = 0
    $processedCount = 0
    
    # Helper function to extract ResourceGroupName from ResourceId
    function Get-ResourceGroupFromId {
        param([string]$ResourceId)
        if ([string]::IsNullOrWhiteSpace($ResourceId)) {
            return $null
        }
        # ResourceId format: /subscriptions/{subId}/resourceGroups/{rgName}/providers/...
        if ($ResourceId -match '/resourceGroups/([^/]+)/') {
            return $matches[1]
        }
        return $null
    }
    
    foreach ($app in $webApps) {
        Write-Verbose "Scanning web app: $($app.Name)"
        
        # Track this resource as scanned (after we get resourceGroupName)
        
        # Get ResourceGroupName from property or extract from ResourceId
        $resourceGroupName = $app.ResourceGroupName
        if ([string]::IsNullOrWhiteSpace($resourceGroupName) -and $app.Id) {
            $resourceGroupName = Get-ResourceGroupFromId -ResourceId $app.Id
            Write-Verbose "Extracted ResourceGroupName '$resourceGroupName' from ResourceId for web app $($app.Name)"
        }
        
        # Skip if ResourceGroupName is still empty
        if ([string]::IsNullOrWhiteSpace($resourceGroupName)) {
            Write-Warning "Skipping web app $($app.Name) - ResourceGroupName is empty and could not be extracted from ResourceId"
            $skippedCount++
            continue
        }
        
        $processedCount++
        
        # Track this resource as scanned
        $resourceKey = if ($app.Id) { $app.Id } else { "$resourceGroupName/$($app.Name)" }
        if (-not $uniqueResourcesScanned.ContainsKey($resourceKey)) {
            $uniqueResourcesScanned[$resourceKey] = $true
        }
        
        # Get web app configuration - REQUIRED for TLS version
        # Use REST API directly since Get-AzWebAppConfig doesn't exist
        $webAppConfig = $null
        try {
            # Use REST API to get web app config
            $restUri = "/subscriptions/$SubscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/sites/$($app.Name)/config/web?api-version=2022-03-01"
            $restResult = Invoke-AzureApiWithRetry {
                # Suppress informational output from Invoke-AzRestMethod (blue box in PowerShell)
                $null = $ProgressPreference
                Invoke-AzRestMethod -Method Get -Path $restUri -ErrorAction Stop 6>$null
            }
            if ($restResult -and $restResult.Content) {
                $configJson = $restResult.Content | ConvertFrom-Json
                $allProps = $configJson.properties | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | Sort-Object
                Write-Verbose "Web app $($app.Name): REST API config properties: $($allProps -join ', ')"
                
                # Check for FTP-related properties (can be ftpsState, ftpState, or ftpEnabled)
                $ftpsStateValue = $null
                # Try ftpsState first (most common)
                if ($configJson.properties.PSObject.Properties.Name -contains 'ftpsState') {
                    $ftpsStateValue = $configJson.properties.ftpsState
                    Write-Verbose "Web app $($app.Name): Found ftpsState property = '$ftpsStateValue'"
                }
                # Try ftpState as fallback
                elseif ($configJson.properties.PSObject.Properties.Name -contains 'ftpState') {
                    $ftpsStateValue = $configJson.properties.ftpState
                    Write-Verbose "Web app $($app.Name): Found ftpState property = '$ftpsStateValue'"
                }
                # Try ftpEnabled as last resort
                elseif ($configJson.properties.PSObject.Properties.Name -contains 'ftpEnabled') {
                    # If ftpEnabled is true, FTP is enabled (AllAllowed), otherwise Disabled
                    $ftpsStateValue = if ($configJson.properties.ftpEnabled) { "AllAllowed" } else { "Disabled" }
                    Write-Verbose "Web app $($app.Name): Found ftpEnabled property = $($configJson.properties.ftpEnabled), resolved to '$ftpsStateValue'"
                }
                else {
                    Write-Verbose "Web app $($app.Name): No FTP-related properties found. Available properties: $($allProps -join ', ')"
                }
                
                Write-Verbose "Web app $($app.Name): FTP state detection - ftpsState: $($configJson.properties.ftpsState), ftpState: $($configJson.properties.ftpState), ftpEnabled: $($configJson.properties.ftpEnabled), resolved: $ftpsStateValue"
                
                # Create a PSCustomObject that mimics the structure we expect
                $webAppConfig = [PSCustomObject]@{
                    SiteConfig = [PSCustomObject]@{
                        MinTlsVersion = $configJson.properties.minTlsVersion
                        FtpsState = $ftpsStateValue
                        RemoteDebuggingEnabled = $configJson.properties.remoteDebuggingEnabled
                    }
                }
                Write-Verbose "Web app $($app.Name): Successfully retrieved web app config via REST API. MinTlsVersion: $($configJson.properties.minTlsVersion), FtpsState: $ftpsStateValue, RemoteDebuggingEnabled: $($configJson.properties.remoteDebuggingEnabled)"
            }
        }
        catch {
            Write-Warning "Could not get web app config for $($app.Name): $_"
            Write-Verbose "Error details: $($_.Exception.Message)"
            $webAppConfig = $null
        }
        
        # Control: Minimum TLS 1.2
        $tlsControl = $controlLookup["App Service - Minimum TLS 1.2"]
        if ($tlsControl) {
            $controlsEvaluated++
            # MinTlsVersion is in SiteConfig.MinTlsVersion property
            $minTlsVersion = $null
            
            if ($webAppConfig) {
                # Check SiteConfig property structure
                if ($webAppConfig.SiteConfig) {
                    # Primary location: SiteConfig.MinTlsVersion
                    if ($webAppConfig.SiteConfig.MinTlsVersion) {
                        $minTlsVersion = $webAppConfig.SiteConfig.MinTlsVersion
                        Write-Verbose "Web app $($app.Name): Found MinTlsVersion in webAppConfig.SiteConfig.MinTlsVersion = '$minTlsVersion'"
                    }
                    else {
                        # Try to inspect SiteConfig object
                        $siteConfigProps = $webAppConfig.SiteConfig | Get-Member -MemberType Property | Select-Object -ExpandProperty Name
                        Write-Verbose "Web app $($app.Name): SiteConfig exists but MinTlsVersion not found. Available properties: $($siteConfigProps -join ', ')"
                        
                        # Try alternative property names
                        if ($webAppConfig.SiteConfig.PSObject.Properties.Name -contains 'MinTlsVersion') {
                            $minTlsVersion = $webAppConfig.SiteConfig.MinTlsVersion
                        }
                        elseif ($webAppConfig.SiteConfig.PSObject.Properties.Name -contains 'MinimumTlsVersion') {
                            $minTlsVersion = $webAppConfig.SiteConfig.MinimumTlsVersion
                        }
                    }
                }
                # Fallback: Direct property (unlikely but possible)
                if ([string]::IsNullOrWhiteSpace($minTlsVersion) -and $webAppConfig.MinTlsVersion) {
                    $minTlsVersion = $webAppConfig.MinTlsVersion
                    Write-Verbose "Web app $($app.Name): Found MinTlsVersion in webAppConfig.MinTlsVersion = '$minTlsVersion'"
                }
            }
            else {
                Write-Verbose "Web app $($app.Name): webAppConfig is null, cannot retrieve MinTlsVersion"
            }
            
            # Default to 1.0 if not found
            if ([string]::IsNullOrWhiteSpace($minTlsVersion)) {
                $minTlsVersion = "1.0"
                Write-Verbose "Web app $($app.Name): MinTlsVersion not found, defaulting to '1.0'"
            }
            
            $tlsStatus = if ($minTlsVersion -ge "1.2") { "PASS" } else { "FAIL" }
            Write-Verbose "Web app $($app.Name): Final MinTlsVersion = '$minTlsVersion', Status = $tlsStatus"
            
            $remediationCmd = $tlsControl.remediationCommand -replace '\{name\}', $app.Name -replace '\{rg\}', $resourceGroupName
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $resourceGroupName `
                -ResourceType "Microsoft.Web/sites" `
                -ResourceName $app.Name `
                -ResourceId $app.Id `
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
        
        # Control: HTTPS Only
        $httpsControl = $controlLookup["App Service - HTTPS Only"]
        if ($httpsControl) {
            $controlsEvaluated++
            $httpsOnly = if ($app.HttpsOnly -ne $null) { $app.HttpsOnly } else { $false }
            $httpsStatus = if ($httpsOnly) { "PASS" } else { "FAIL" }
            
            $remediationCmd = $httpsControl.remediationCommand -replace '\{name\}', $app.Name -replace '\{rg\}', $resourceGroupName
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $resourceGroupName `
                -ResourceType "Microsoft.Web/sites" `
                -ResourceName $app.Name `
                -ResourceId $app.Id `
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
        
        # Control: FTP Disabled
        $ftpControl = $controlLookup["App Service - FTP Disabled"]
        if ($ftpControl) {
            $controlsEvaluated++
            $ftpsState = $null
            if ($webAppConfig -and $webAppConfig.SiteConfig) {
                $ftpsState = $webAppConfig.SiteConfig.FtpsState
                Write-Verbose "Web app $($app.Name): FtpsState from config = '$ftpsState'"
            }
            
            # Default to AllAllowed if not found (most permissive = worst case)
            if ([string]::IsNullOrWhiteSpace($ftpsState)) {
                $ftpsState = "AllAllowed"
                Write-Verbose "Web app $($app.Name): FtpsState not found, defaulting to 'AllAllowed'"
            }
            
            $ftpStatus = if ($ftpsState -in @("Disabled", "FtpsOnly")) { "PASS" } else { "FAIL" }
            Write-Verbose "Web app $($app.Name): FTP check - State: '$ftpsState', Status: $ftpStatus"
            
            $remediationCmd = $ftpControl.remediationCommand -replace '\{name\}', $app.Name -replace '\{rg\}', $resourceGroupName
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $resourceGroupName `
                -ResourceType "Microsoft.Web/sites" `
                -ResourceName $app.Name `
                -ResourceId $app.Id `
                -ControlId $ftpControl.controlId `
                -ControlName $ftpControl.controlName `
                -Category $ftpControl.category `
                -Frameworks $ftpControl.frameworks `
                -Severity $ftpControl.severity `
                -CisLevel $ftpControl.level `
                -CurrentValue $ftpsState `
                -ExpectedValue $ftpControl.expectedValue `
                -Status $ftpStatus `
                -RemediationSteps $ftpControl.businessImpact `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }
        
        # Control: Remote Debugging Disabled
        $remoteDebugControl = $controlLookup["App Service - Remote Debugging Disabled"]
        if ($remoteDebugControl) {
            $controlsEvaluated++
            $remoteDebugging = if ($webAppConfig -and $webAppConfig.SiteConfig -and $webAppConfig.SiteConfig.RemoteDebuggingEnabled) { 
                $webAppConfig.SiteConfig.RemoteDebuggingEnabled 
            } else { 
                $false 
            }
            $remoteDebugStatus = if (-not $remoteDebugging) { "PASS" } else { "FAIL" }
            
            $remediationCmd = $remoteDebugControl.remediationCommand -replace '\{name\}', $app.Name -replace '\{rg\}', $resourceGroupName
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $resourceGroupName `
                -ResourceType "Microsoft.Web/sites" `
                -ResourceName $app.Name `
                -ResourceId $app.Id `
                -ControlId $remoteDebugControl.controlId `
                -ControlName $remoteDebugControl.controlName `
                -Category $remoteDebugControl.category `
                -Frameworks $remoteDebugControl.frameworks `
                -Severity $remoteDebugControl.severity `
                -CisLevel $remoteDebugControl.level `
                -CurrentValue $remoteDebugging.ToString() `
                -ExpectedValue $remoteDebugControl.expectedValue `
                -Status $remoteDebugStatus `
                -RemediationSteps $remoteDebugControl.businessImpact `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }
        
        # Control: Authentication Enabled (9.1)
        $authControl = $controlLookup["App Service - Authentication Enabled"]
        if ($authControl) {
            try {
                $authSettings = Invoke-AzureApiWithRetry {
                    Get-AzWebAppAuthSetting -ResourceGroupName $resourceGroupName -Name $app.Name -ErrorAction SilentlyContinue
                }
                $authEnabled = if ($authSettings) { 
                    $authSettings.Enabled 
                } else { 
                    $false 
                }
            }
            catch {
                Write-Verbose "Could not get auth settings for $($app.Name): $_"
                $authEnabled = $false
            }
            
            $authStatus = if ($authEnabled) { "PASS" } else { "FAIL" }
            
            $remediationCmd = $authControl.remediationCommand -replace '\{name\}', $app.Name -replace '\{rg\}', $resourceGroupName
            $finding = New-SecurityFinding `
                -SubscriptionId $SubscriptionId `
                -SubscriptionName $SubscriptionName `
                -ResourceGroup $resourceGroupName `
                -ResourceType "Microsoft.Web/sites" `
                -ResourceName $app.Name `
                -ResourceId $app.Id `
                -ControlId $authControl.controlId `
                -ControlName $authControl.controlName `
                -Category $authControl.category `
                -Frameworks $authControl.frameworks `
                -Severity $authControl.severity `
                -CisLevel $authControl.level `
                -CurrentValue $authEnabled.ToString() `
                -ExpectedValue $authControl.expectedValue `
                -Status $authStatus `
                -RemediationSteps $authControl.businessImpact `
                -RemediationCommand $remediationCmd
            $findings.Add($finding)
        }
    }
    
    if ($skippedCount -gt 0) {
        Write-Warning "Skipped $skippedCount web app(s) due to empty ResourceGroupName"
    }
    
    if ($processedCount -eq 0 -and $webApps.Count -gt 0) {
        Write-Warning "No web apps were processed (all had empty ResourceGroupName)"
    }
    
    if ($findings.Count -eq 0 -and $webApps.Count -gt 0) {
        Write-Warning "AppService scan found $($webApps.Count) web app(s) but generated 0 findings - this may indicate a problem"
    }
    else {
        Write-Verbose "AppService scan completed: $($findings.Count) findings, $($eolFindings.Count) EOL findings from $processedCount web app(s)"
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

