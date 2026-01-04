# Init-Local.ps1 - Initiera och ladda alla modulfunktioner
# Kör detta skript för att ladda alla funktioner direkt utan att behöva installera modulen
# Laddar automatiskt om funktioner om de redan finns
# 
# VIKTIGT: Du MÅSTE köra med punkt och mellanslag:
#   . .\Init-Local.ps1
# 
# Om du kör .\Init-Local.ps1 (utan punkt) fungerar det INTE!

param()

$ModuleRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }

# Load .env file if it exists (to get OPENAI_MODEL, OPENAI_API_KEY, AZURE_*, etc.)
$envFilePath = Join-Path $ModuleRoot ".env"
if (Test-Path $envFilePath) {
    Write-Verbose "Loading .env file: $envFilePath"
    $envVarsLoaded = 0
    Get-Content $envFilePath -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
        $line = $_.Trim() -replace '^["\x27](.*)["\x27]$', '$1'
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { return }
        
        if ($line -match '^([^=]+)=(.*)$') {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            $value = $value -replace '^["\x27](.*)["\x27]$', '$1'
            
            # Load Azure and OpenAI environment variables
            if ($key -match '^(AZURE_|OPENAI_)') {
                Set-Item -Path "env:$key" -Value $value -ErrorAction SilentlyContinue
                $envVarsLoaded++
                Write-Verbose "Loaded $key from .env file"
            }
        }
    }
    if ($envVarsLoaded -gt 0) {
        Write-Verbose "Loaded $envVarsLoaded environment variable(s) from .env file"
    }
}

# Varna om skriptet körs utan dot-source
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.Line -notmatch '^\s*\.\s+') {
    Write-Host "`n[ERROR] Script must be run with dot-source!" -ForegroundColor Red
    Write-Host "Use: . .\Init-Local.ps1" -ForegroundColor Yellow
    Write-Host "(Note the dot and space before the script name)`n" -ForegroundColor Yellow
    Write-Host "Current command: $($MyInvocation.Line)" -ForegroundColor Gray
    return
}

Write-Host "Initializing module - loading all functions..." -ForegroundColor Cyan

# Ta bort alla befintliga funktioner från modulen först
Write-Host "  Removing existing functions..." -ForegroundColor Gray
$functionsToRemove = @(
    # Public functions
    'Connect-AuditEnvironment',
    'Invoke-AzureSecurityAudit',
    'Export-SecurityReport',
    'Export-DashboardReport',
    'Export-VMBackupReport',
    'Export-AdvisorReport',
    'Export-ChangeTrackingReport',
    'Export-NetworkInventoryReport',
    'Export-CostTrackingReport',
    'Export-EOLReport',
    'Export-RBACReport',
    'Invoke-AzureArchitectAgent',
    # Helper functions
    'Get-SubscriptionContext',
    'Invoke-AzureApiWithRetry',
    'Invoke-WithSuppressedWarnings',
    'Invoke-WithErrorHandling',
    'New-SecurityFinding',
    'New-EOLFinding',
    'Get-SubscriptionDisplayName',
    'Get-FindingsBySeverity',
    'Parse-ResourceId',
    'Encode-Html',
    'Get-CostSavingsFromRecommendations',
    'Get-DictionaryValue',
    'Get-ReportStylesheet',
    'Get-ReportNavigation',
    'Get-ReportScript',
    'Get-SubscriptionsToScan',
    'Invoke-ScannerForSubscription',
    'Collect-AdvisorRecommendations',
    'Collect-ChangeTrackingData',
    'Collect-NetworkInventory',
    'Collect-CostData',
    'Get-NsgRiskAnalysis',
    'Generate-AuditReports',
    # AI helper functions
    'Invoke-OpenAIAnalysis',
    'ConvertFrom-OpenAIResponseJson',
    'Get-FirstResponsesOutputText',
    'ConvertTo-AdvisorAIInsights',
    'ConvertTo-CostAIInsights',
    'ConvertTo-SecurityAIInsights',
    'ConvertTo-RBACAIInsights',
    'ConvertTo-NetworkAIInsights',
    'ConvertTo-EOLAIInsights',
    'ConvertTo-ChangeTrackingAIInsights',
    'ConvertTo-VMBackupAIInsights',
    'ConvertTo-CostTrackingAIInsights',
    'ConvertTo-CombinedPayload',
    'Get-ImplementationComplexity',
    'Get-RemediationEffort',
    # Config functions
    'Get-ControlDefinitions',
    # Scanner functions
    'Get-AzureStorageFindings',
    'Get-AzureAppServiceFindings',
    'Get-AzureVirtualMachineFindings',
    'Get-AzureArcFindings',
    'Get-AzureMonitorFindings',
    'Get-AzureNetworkFindings',
    'Get-AzureSqlDatabaseFindings',
    'Get-AzureKeyVaultFindings',
    'Get-AzureEOLStatus',
    # Collector functions
    'Get-AzureAdvisorRecommendations',
    'Get-AzureChangeAnalysis',
    'Get-AzureChangeTracking',  # Deprecated - kept for Get-AzureActivityLogViaRestApi
    'Get-AzureActivityLogViaRestApi',
    'Convert-AdvisorRecommendation',
    'Group-AdvisorRecommendations',
    'Format-ExtendedPropertiesDetails',
    'Get-AzureNetworkInventory',
    'Get-AzureCostData',
    'Get-AzureRBACInventory',
    # Test functions
    'Test-ChangeTracking',
    'Test-EOLTracking',
    'Test-CostTracking',
    'Test-SecurityReport',
    'Test-Advisor',
    'Test-VMBackup',
    'Test-RBAC',
    # Test data functions
    'New-TestSecurityData',
    'New-TestVMBackupData',
    'New-TestChangeTrackingData',
    'New-TestCostTrackingData',
    'New-TestEOLData',
    'New-TestNetworkInventoryData',
    'New-TestRBACData',
    'New-TestAdvisorData',
    'New-TestAllData',
    'Test-SingleReport',
    'Test-RetryAIAnalysis'
)

foreach ($funcName in $functionsToRemove) {
    # Force removal - try even if Get-Command doesn't find it (handles edge cases)
    $existed = Get-Command $funcName -ErrorAction SilentlyContinue
    Remove-Item "Function:\$funcName" -Force -ErrorAction SilentlyContinue
    if ($existed) {
        Write-Verbose "Removed: $funcName"
    }
}

# Ta bort modulen också om den är laddad
Get-Module AzureSecurityAudit | Remove-Module -Force -ErrorAction SilentlyContinue

Write-Host "  Loading functions..." -ForegroundColor Gray

# Validate CSS structure exists (required for reports)
Write-Host "  Validating CSS structure..." -ForegroundColor Gray
$stylesPath = Join-Path $ModuleRoot "Config\Styles"
$requiredCoreFiles = @("_variables.css", "_base.css", "_navigation.css", "_layout.css")
$componentsPath = Join-Path $stylesPath "_components"
$requiredComponents = @("tables.css", "badges.css", "cards.css", "sections.css", "filters.css", "buttons.css", "progress-bars.css", "stats.css", "links.css", "hero.css", "score-circle.css")

if (-not (Test-Path $stylesPath)) {
    Write-Warning "CSS styles directory not found: $stylesPath"
    Write-Warning "Reports may not render correctly. Please ensure Config/Styles/ directory structure exists."
} else {
    $missingFiles = @()
    foreach ($file in $requiredCoreFiles) {
        $filePath = Join-Path $stylesPath $file
        if (-not (Test-Path $filePath)) {
            $missingFiles += $file
        }
    }
    if (Test-Path $componentsPath) {
        foreach ($file in $requiredComponents) {
            $filePath = Join-Path $componentsPath $file
            if (-not (Test-Path $filePath)) {
                $missingFiles += $file
            }
        }
    } else {
        Write-Warning "CSS components directory not found: $componentsPath"
    }
    if ($missingFiles.Count -gt 0) {
        Write-Warning "Missing CSS files: $($missingFiles -join ', ')"
        Write-Warning "Reports may not render correctly."
    } else {
        Write-Verbose "CSS structure validated successfully"
    }
}

# Ladda alla dependencies i rätt ordning
# 1. Helpers (grundläggande helper-funktioner, inkluderar konstanter och definitioner)
Write-Host "  Loading Private Helpers..." -ForegroundColor Gray
Get-ChildItem -Path "$ModuleRoot\Private\Helpers\*.ps1" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { 
    $file = $_  # Capture file reference BEFORE try/catch
    try {
        . $file.FullName
        Write-Verbose "Loaded: $($file.Name)"
    }
    catch {
        Write-Warning "Failed to load $($file.Name): $_"
    }
}

# 2. Scanners (använder helpers)
Write-Host "  Loading Private Scanners..." -ForegroundColor Gray
Get-ChildItem -Path "$ModuleRoot\Private\Scanners\*.ps1" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { 
    $file = $_  # Capture file reference BEFORE try/catch
    try {
        . $file.FullName
        Write-Verbose "Loaded: $($file.Name)"
    }
    catch {
        Write-Warning "Failed to load $($file.Name): $_"
    }
}

# 3. Collectors (använder helpers)
Write-Host "  Loading Private Collectors..." -ForegroundColor Gray
Get-ChildItem -Path "$ModuleRoot\Private\Collectors\*.ps1" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { 
    $file = $_  # Capture file reference BEFORE try/catch
    Write-Verbose "    Attempting: $($file.Name)"
    try {
        # Load by reading content and creating scriptblock (bypasses execution policy issues)
        $content = Get-Content $file.FullName -Raw -ErrorAction Stop
        $scriptBlock = [scriptblock]::Create($content)
        . $scriptBlock
        Write-Verbose "Loaded: $($file.Name)"
    }
    catch {
        # Fallback to direct dot-sourcing
        try {
            . $file.FullName -ErrorAction Stop
            Write-Verbose "Loaded: $($file.Name)"
        }
        catch {
            Write-Warning "Failed to load $($file.Name): $_"
        }
    }
}

# 5. Public Functions (använder allt ovanstående)
Write-Host "  Loading Public Functions..." -ForegroundColor Gray
Get-ChildItem -Path "$ModuleRoot\Public\*.ps1" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { 
    $file = $_  # Capture file reference BEFORE try/catch
    try {
        . $file.FullName
        Write-Verbose "Loaded: $($file.Name)"
    }
    catch {
        Write-Warning "Failed to load $($file.Name): $_"
    }
}

# 6. Test Data Functions (for test data generation)
Write-Host "  Loading Test Data Functions..." -ForegroundColor Gray
$testDataScript = Join-Path $ModuleRoot "Tools\New-TestData.ps1"
if (Test-Path $testDataScript) {
    try {
        # Ensure Test functions are removed before loading to force refresh
        Get-Command New-Test* -ErrorAction SilentlyContinue | ForEach-Object { 
            Remove-Item "Function:\$($_.Name)" -Force -ErrorAction SilentlyContinue 
        }
        
        . $testDataScript
        Write-Verbose "Loaded: New-TestData.ps1"
    }
    catch {
        Write-Warning "Failed to load test data functions: $_"
    }
} else {
    Write-Warning "Test data script not found: $testDataScript"
}

# 7. Interactive Helpers
Write-Host "  Loading Interactive Helpers..." -ForegroundColor Gray
$retryScript = Join-Path $ModuleRoot "Tools\Test-RetryAIAnalysis.ps1"
if (Test-Path $retryScript) {
    try {
        . $retryScript
        Write-Verbose "Loaded: Test-RetryAIAnalysis.ps1"
    }
    catch {
        Write-Warning "Failed to load interactive helpers: $_"
    }
}

Write-Host "`n[OK] All functions loaded! Module initialized and ready to use." -ForegroundColor Green
# Summary of loaded functions (backend + interactive) – printed last so that all Test-* are defined
Write-Host "`nBackend / core functions (auto-loaded):" -ForegroundColor Cyan
$backendFunctions = @()

# Public exports
Get-ChildItem -Path "$ModuleRoot\Public\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
    $funcName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
    $backendFunctions += $funcName
}

# Collector entrypoints
Get-ChildItem -Path "$ModuleRoot\Private\Collectors\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
    $funcName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
    $backendFunctions += $funcName
}

$backendFunctions = $backendFunctions | Sort-Object -Unique
foreach ($funcName in $backendFunctions) {
    if (Get-Command $funcName -ErrorAction SilentlyContinue) {
        Write-Host "  - $funcName [OK]" -ForegroundColor Green
    } else {
        Write-Host "  - $funcName [MISSING]" -ForegroundColor Red
    }
}

Write-Host "`nInteractive / test functions:" -ForegroundColor Cyan

$userFunctions = @(
    'Connect-AuditEnvironment',
    'Start-AzureGovernanceAudit',
    'Invoke-AzureArchitectAgent',
    'Test-RetryAIAnalysis'
)

foreach ($funcName in $userFunctions) {
    if (Get-Command $funcName -ErrorAction SilentlyContinue) {
        Write-Host "  - $funcName [OK]" -ForegroundColor Green
    } else {
        Write-Host "  - $funcName [MISSING]" -ForegroundColor Red
    }
}

Write-Host "`nTip: Common commands:" -ForegroundColor Cyan
Write-Host "  - Connect-AuditEnvironment                      # Sign in to Azure" -ForegroundColor Gray
Write-Host "  - Start-AzureGovernanceAudit                    # Full audit (live data, all reports)" -ForegroundColor Gray
Write-Host "  - Start-AzureGovernanceAudit -Mode Test         # Full audit with mock data" -ForegroundColor Gray
Write-Host "  - Start-AzureGovernanceAudit -ReportType CostTracking -Mode Test" -ForegroundColor Gray
Write-Host "  - Start-AzureGovernanceAudit -AI                # Full audit with AI analysis" -ForegroundColor Gray
Write-Host "  - Start-AzureGovernanceAudit -Help              # Show all options" -ForegroundColor Gray

