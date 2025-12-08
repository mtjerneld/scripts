<#
.SYNOPSIS
    Connects to Azure and validates environment for security auditing.

.DESCRIPTION
    Wrapper around Connect-AzAccount that validates required modules and RBAC permissions
    for performing security audits. Supports interactive login, Service Principal, and Managed Identity.
    
    Service Principal credentials can be provided via:
    - .env file (AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET)
    - Environment variables
    - Parameters

.PARAMETER EnvFile
    Path to .env file containing Azure credentials (default: .env in current directory).

.PARAMETER TenantId
    Entra ID (formerly Azure AD) Tenant ID (optional, can be in .env file).
    Find this in Azure Portal > Entra ID > Overview, or use: (Get-AzContext).Tenant.Id

.PARAMETER ApplicationId
    Service Principal Application (Client) ID (optional, can be in .env file).

.PARAMETER ClientSecret
    Service Principal Client Secret (optional, can be in .env file).

.PARAMETER UseManagedIdentity
    Use Managed Identity for authentication (for Azure VMs/ARC).

.PARAMETER AccountId
    Account ID for interactive authentication (optional).

.EXAMPLE
    Connect-AuditEnvironment
    
.EXAMPLE
    Connect-AuditEnvironment -EnvFile "C:\Config\.env"
    
.EXAMPLE
    Connect-AuditEnvironment -TenantId "tenant-id" -ApplicationId "app-id" -ClientSecret "secret"
#>
function Connect-AuditEnvironment {
    [CmdletBinding()]
    param(
        [string]$EnvFile = ".env",
        
        [string]$TenantId,
        
        [string]$ApplicationId,
        
        [string]$ClientSecret,
        
        [switch]$UseManagedIdentity,
        
        [string]$AccountId
    )
    
    # Check for NuGet provider (required for module installation)
    $nugetProvider = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
    if (-not $nugetProvider) {
        Write-Host ''
        Write-Host '=== MISSING: NuGet Package Provider ===' -ForegroundColor Red
        Write-Host 'NuGet provider is required to install PowerShell modules.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'To install, run:' -ForegroundColor Cyan
        Write-Host '  Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force' -ForegroundColor White
        Write-Host ''
        Write-Host 'Would you like to install it now? (Y/N): ' -ForegroundColor Yellow -NoNewline
        $response = Read-Host
        if ($response -eq 'Y' -or $response -eq 'y') {
            try {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser
                Write-Host 'NuGet provider installed successfully!' -ForegroundColor Green
            }
            catch {
                $errorMsg = $_.Exception.Message
                Write-Host ('Failed to install NuGet provider: ' + $errorMsg) -ForegroundColor Red
                Write-Host 'Please install manually and try again.' -ForegroundColor Yellow
                return
            }
        }
        else {
            Write-Host 'Please install NuGet provider and try again.' -ForegroundColor Yellow
            return
        }
    }
    
    # Check for required Az modules
    $requiredModules = @(
        'Az.Accounts',
        'Az.Resources',
        'Az.Storage',
        'Az.Websites',
        'Az.Compute',
        'Az.Sql',
        'Az.Network',
        'Az.Monitor',
        'Az.ConnectedMachine'
    )
    
    $missingModules = @()
    $installedModules = @()
    
    foreach ($module in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            $missingModules += $module
        }
        else {
            $installedModules += $module
        }
    }
    
    if ($missingModules.Count -gt 0) {
        Write-Host ''
        Write-Host '=== MISSING: Azure PowerShell Modules ===' -ForegroundColor Red
        Write-Host 'The following Az modules are missing:' -ForegroundColor Yellow
        foreach ($module in $missingModules) {
            Write-Host ('  - ' + $module) -ForegroundColor White
        }
        Write-Host ''
        Write-Host 'Installed modules:' -ForegroundColor Green
        foreach ($module in $installedModules) {
            Write-Host ('  [OK] ' + $module) -ForegroundColor Green
        }
        Write-Host ''
        Write-Host 'To install all missing modules, run:' -ForegroundColor Cyan
        Write-Host '  Install-Module Az -Force -AllowClobber -Scope CurrentUser' -ForegroundColor White
        Write-Host ''
        Write-Host 'Or install individually:' -ForegroundColor Cyan
        $moduleList = $missingModules -join ', '
        Write-Host ('  Install-Module ' + $moduleList + ' -Force -Scope CurrentUser') -ForegroundColor White
        Write-Host ''
        Write-Host 'Would you like to install the Az module now? (Y/N): ' -ForegroundColor Yellow -NoNewline
        $response = Read-Host
        if ($response -eq 'Y' -or $response -eq 'y') {
            try {
                Write-Host ''
                Write-Host 'Installing Az module (this may take a few minutes)...' -ForegroundColor Cyan
                Install-Module Az -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
                Write-Host 'Az module installed successfully!' -ForegroundColor Green
                Write-Host 'Please restart your PowerShell session or run: Import-Module Az -Force' -ForegroundColor Yellow
            }
            catch {
                $errorMsg = $_.Exception.Message
                Write-Host ('Failed to install Az module: ' + $errorMsg) -ForegroundColor Red
                Write-Host 'Please install manually and try again.' -ForegroundColor Yellow
                return
            }
        }
        else {
            Write-Host 'Please install the required modules and try again.' -ForegroundColor Yellow
            Write-Host 'Run: Install-Module Az -Force -AllowClobber -Scope CurrentUser' -ForegroundColor White
            return
        }
    }
    else {
        Write-Host '[OK] All required Az modules are installed' -ForegroundColor Green
    }
    
    # Resolve .env file path (support relative and absolute paths)
    $envFilePath = $EnvFile
    if (-not [System.IO.Path]::IsPathRooted($envFilePath)) {
        $envFilePath = Join-Path (Get-Location).Path $envFilePath
    }
    
    # Load environment variables from .env file if it exists
    if (Test-Path $envFilePath) {
        Write-Host ''
        Write-Host ('Loading environment from: ' + $envFilePath) -ForegroundColor Cyan
        $envVarsLoaded = 0
        $loadedKeys = @()
        Get-Content $envFilePath -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
            # Remove surrounding quotes from the entire line first (handles files saved with quotes)
            $line = $_.Trim() -replace '^["\x27](.*)["\x27]$', '$1'
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { return }
            
            if ($line -match '^([^=]+)=(.*)$') {
                $key = $Matches[1].Trim()
                $value = $Matches[2].Trim()
                
                # Remove surrounding quotes from value if present
                $value = $value -replace '^["\x27](.*)["\x27]$', '$1'
                
                # Only load Azure-related environment variables
                if ($key -match '^AZURE_') {
                    Set-Item -Path "env:$key" -Value $value -ErrorAction SilentlyContinue
                    $envVarsLoaded++
                    $loadedKeys += $key
                    Write-Verbose "Loaded $key from .env file"
                }
            }
        }
        if ($envVarsLoaded -gt 0) {
            Write-Host ('[OK] Loaded ' + $envVarsLoaded + ' environment variable(s) from .env file: ' + ($loadedKeys -join ', ')) -ForegroundColor Green
        }
        else {
            Write-Host '[WARNING] .env file found but no AZURE_* variables were loaded' -ForegroundColor Yellow
            Write-Host '  Check that your .env file contains lines like:' -ForegroundColor Gray
            Write-Host '    AZURE_TENANT_ID=your-tenant-id' -ForegroundColor Gray
            Write-Host '    AZURE_CLIENT_ID=your-client-id' -ForegroundColor Gray
            Write-Host '    AZURE_CLIENT_SECRET=your-client-secret' -ForegroundColor Gray
        }
    }
    else {
        Write-Host ''
        Write-Host ('No .env file found at: ' + $envFilePath) -ForegroundColor Yellow
        Write-Host 'Using interactive authentication or parameters.' -ForegroundColor Gray
    }
    
    # Get credentials from parameters, environment variables, or .env file (in that order)
    $tenantIdToUse = $TenantId
    if (-not $tenantIdToUse) {
        $tenantIdToUse = $env:AZURE_TENANT_ID
    }
    
    $appIdToUse = $ApplicationId
    if (-not $appIdToUse) {
        $appIdToUse = $env:AZURE_CLIENT_ID
    }
    
    $secretToUse = $ClientSecret
    if (-not $secretToUse) {
        $secretToUse = $env:AZURE_CLIENT_SECRET
    }
    
    # Debug: Show which authentication method will be used
    Write-Host ''
    Write-Host '=== Authentication Method Detection ===' -ForegroundColor Cyan
    Write-Host ('  Tenant ID found: ' + (-not [string]::IsNullOrWhiteSpace($tenantIdToUse))) -ForegroundColor Gray
    Write-Host ('  Client ID found: ' + (-not [string]::IsNullOrWhiteSpace($appIdToUse))) -ForegroundColor Gray
    Write-Host ('  Client Secret found: ' + (-not [string]::IsNullOrWhiteSpace($secretToUse))) -ForegroundColor Gray
    
    if ($UseManagedIdentity) {
        Write-Host 'Method: Managed Identity (switch specified)' -ForegroundColor Green
    }
    elseif ($tenantIdToUse -and $appIdToUse -and $secretToUse) {
        Write-Host 'Method: Service Principal (credentials found)' -ForegroundColor Green
        Write-Host ('  Tenant ID: ' + $tenantIdToUse.Substring(0, [Math]::Min(8, $tenantIdToUse.Length)) + '...') -ForegroundColor Gray
        Write-Host ('  Client ID: ' + $appIdToUse.Substring(0, [Math]::Min(8, $appIdToUse.Length)) + '...') -ForegroundColor Gray
    }
    elseif ($AccountId -and $tenantIdToUse) {
        Write-Host 'Method: Interactive (specific account)' -ForegroundColor Green
    }
    elseif ($tenantIdToUse) {
        Write-Host 'Method: Interactive (specific tenant)' -ForegroundColor Green
    }
    else {
        Write-Host 'Method: Interactive (browser login - no credentials found)' -ForegroundColor Yellow
        Write-Host '  To use Service Principal, ensure .env file contains:' -ForegroundColor Gray
        Write-Host '    AZURE_TENANT_ID=your-tenant-id' -ForegroundColor Gray
        Write-Host '    AZURE_CLIENT_ID=your-client-id' -ForegroundColor Gray
        Write-Host '    AZURE_CLIENT_SECRET=your-client-secret' -ForegroundColor Gray
    }
    
    # Verify Az.Accounts module is available and loaded
    if (-not (Get-Module -ListAvailable -Name 'Az.Accounts')) {
        Write-Host ''
        Write-Host '[ERROR] Az.Accounts module is not installed' -ForegroundColor Red
        Write-Host 'Please install Az modules first:' -ForegroundColor Yellow
        Write-Host '  Install-Module Az -Force -AllowClobber -Scope CurrentUser' -ForegroundColor White
        Write-Host ''
        Write-Host 'Then run Connect-AuditEnvironment again.' -ForegroundColor Yellow
        return
    }
    
    if (-not (Get-Module -Name 'Az.Accounts')) {
        Write-Host ''
        Write-Host 'Loading Az.Accounts module...' -ForegroundColor Cyan
        try {
            Import-Module Az.Accounts -Force -ErrorAction Stop
        }
        catch {
            $errorMsg = $_.Exception.Message
            Write-Host ('Failed to load Az.Accounts module: ' + $errorMsg) -ForegroundColor Red
            Write-Host 'Please ensure Az modules are properly installed.' -ForegroundColor Yellow
            return
        }
    }
    
    # Connect to Azure
    Write-Host ''
    Write-Host '=== Connecting to Azure ===' -ForegroundColor Cyan
    try {
        if ($UseManagedIdentity) {
            # Use Managed Identity (for Azure VMs/ARC)
            Write-Host 'Using authentication method: Managed Identity' -ForegroundColor Cyan
            $null = Connect-AzAccount -Identity -ErrorAction Stop
        }
        elseif ($tenantIdToUse -and $appIdToUse -and $secretToUse) {
            # Service Principal authentication
            Write-Host 'Using authentication method: Service Principal' -ForegroundColor Cyan
            
            # Ensure values are properly trimmed and have no hidden characters
            $tenantIdToUse = $tenantIdToUse.Trim()
            $appIdToUse = $appIdToUse.Trim()
            $secretToUse = $secretToUse.Trim()
            
            # Validate GUID format for Tenant ID and Client ID
            $guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            if ($tenantIdToUse -notmatch $guidPattern) {
                Write-Host '[WARNING] Tenant ID does not appear to be a valid GUID format' -ForegroundColor Yellow
                Write-Host ('  Tenant ID: ' + $tenantIdToUse + ' (length: ' + $tenantIdToUse.Length + ')') -ForegroundColor Gray
            }
            if ($appIdToUse -notmatch $guidPattern) {
                Write-Host '[WARNING] Client ID does not appear to be a valid GUID format' -ForegroundColor Yellow
                Write-Host ('  Client ID: ' + $appIdToUse + ' (length: ' + $appIdToUse.Length + ')') -ForegroundColor Gray
            }
            
            Write-Host ('  Tenant ID: ' + $tenantIdToUse) -ForegroundColor Gray
            Write-Host ('  Client ID: ' + $appIdToUse) -ForegroundColor Gray
            Write-Host ('  Client Secret: ' + ('*' * [Math]::Min(20, $secretToUse.Length)) + ' (length: ' + $secretToUse.Length + ')') -ForegroundColor Gray
            
            try {
                $secureSecret = ConvertTo-SecureString $secretToUse -AsPlainText -Force
                $credential = New-Object System.Management.Automation.PSCredential($appIdToUse, $secureSecret)
                
                # Try connecting with explicit TenantId parameter
                Write-Host 'Connecting to Azure with Service Principal...' -ForegroundColor Cyan
                $null = Connect-AzAccount -ServicePrincipal -Credential $credential -TenantId $tenantIdToUse -ErrorAction Stop
            }
            catch {
                # If the above fails, try with Tenant parameter (some versions use this)
                Write-Host 'Retrying with Tenant parameter instead of TenantId...' -ForegroundColor Yellow
                $null = Connect-AzAccount -ServicePrincipal -Credential $credential -Tenant $tenantIdToUse -ErrorAction Stop
            }
        }
        elseif ($AccountId -and $tenantIdToUse) {
            # Interactive with specific account and tenant
            Write-Host 'Using authentication method: Interactive (specific account)' -ForegroundColor Cyan
            $null = Connect-AzAccount -AccountId $AccountId -TenantId $tenantIdToUse -ErrorAction Stop
        }
        elseif ($tenantIdToUse) {
            # Interactive with specific tenant
            Write-Host 'Using authentication method: Interactive (specific tenant)' -ForegroundColor Cyan
            $null = Connect-AzAccount -TenantId $tenantIdToUse -ErrorAction Stop
        }
        else {
            # Interactive authentication (default)
            Write-Host 'Using authentication method: Interactive (browser login)' -ForegroundColor Cyan
            $null = Connect-AzAccount -ErrorAction Stop
        }
        
        Write-Host ''
        Write-Host '[OK] Successfully connected to Azure!' -ForegroundColor Green
        
        # Get context information (suppress any automatic formatting by using [void])
        [void]($azContext = Get-AzContext)
        
        if ($azContext) {
            # Show Subscription if available and not empty
            if ($azContext.Subscription -and $azContext.Subscription.Id -and -not [string]::IsNullOrWhiteSpace($azContext.Subscription.Id)) {
                $subscriptionName = ''
                if ($azContext.Subscription.Name -and -not [string]::IsNullOrWhiteSpace($azContext.Subscription.Name)) {
                    $subscriptionName = $azContext.Subscription.Name
                }
                $subscriptionId = $azContext.Subscription.Id
                if ($subscriptionName) {
                    Write-Host ('  Subscription: ' + $subscriptionName + ' ' + $subscriptionId) -ForegroundColor White
                }
                else {
                    Write-Host ('  Subscription ID: ' + $subscriptionId) -ForegroundColor White
                }
            }
            else {
                # Only show warning if no subscription is selected
                Write-Host '  Note: No subscription selected. Use Set-AzContext to select one, or specify in Invoke-AzureSecurityAudit.' -ForegroundColor Yellow
            }
            
            # Show Account if available and not empty
            if ($azContext.Account -and $azContext.Account.Id -and -not [string]::IsNullOrWhiteSpace($azContext.Account.Id)) {
                Write-Host ('  Account: ' + $azContext.Account.Id) -ForegroundColor White
            }
        }
        
        # Don't return the context object to prevent PowerShell's automatic formatting
        # If you need the context, use: Get-AzContext
        # This prevents the automatic formatting that shows empty Tenant ID, Subscription, etc.
        return
    }
    catch {
        Write-Host ''
        Write-Host '[ERROR] Failed to connect to Azure' -ForegroundColor Red
        $errorMsg = $_.Exception.Message
        Write-Host ('Error: ' + $errorMsg) -ForegroundColor Red
        Write-Host ''
        Write-Host 'Authentication options:' -ForegroundColor Yellow
        Write-Host '  1. Interactive: Connect-AuditEnvironment' -ForegroundColor White
        Write-Host '  2. Service Principal with .env: Create .env file with:' -ForegroundColor White
        Write-Host '     AZURE_TENANT_ID=your-tenant-id' -ForegroundColor Gray
        Write-Host '     AZURE_CLIENT_ID=your-client-id' -ForegroundColor Gray
        Write-Host '     AZURE_CLIENT_SECRET=your-client-secret' -ForegroundColor Gray
        Write-Host '  3. Service Principal with parameters:' -ForegroundColor White
        Write-Host '     Connect-AuditEnvironment -TenantId tenant-id -ApplicationId app-id -ClientSecret secret' -ForegroundColor Gray
        Write-Host '  4. Managed Identity: Connect-AuditEnvironment -UseManagedIdentity' -ForegroundColor White
        throw
    }
}

