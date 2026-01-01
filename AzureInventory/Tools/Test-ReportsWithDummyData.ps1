<#
.SYNOPSIS
    Quick test script to generate all reports using dummy test data.

.DESCRIPTION
    Loads test data generator and creates all reports with dummy data for rapid HTML/CSS testing.
    No Azure connection required!

.EXAMPLE
    . .\Tools\Test-ReportsWithDummyData.ps1
    Test-AllReportsWithDummyData -OutputFolder "test-reports"
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$OutputFolder,
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipInit
)

# Define default test output directory (project root/test-output)
if (-not $OutputFolder) {
    $projectRoot = Split-Path $PSScriptRoot -Parent
    $OutputFolder = Join-Path $projectRoot "test-output"
}

# Load module functions if not already loaded
if (-not $SkipInit) {
    Write-Host "Loading module functions..." -ForegroundColor Yellow
    $initScript = Join-Path (Split-Path $PSScriptRoot -Parent) "Init-Local.ps1"
    if (Test-Path $initScript) {
        . $initScript
    } else {
        Write-Warning "Init-Local.ps1 not found. Make sure Export-* functions are loaded."
    }
}

# Load test data generator
$testDataScript = Join-Path $PSScriptRoot "New-TestData.ps1"
if (-not (Test-Path $testDataScript)) {
    Write-Error "Test data generator not found: $testDataScript"
    return
}
. $testDataScript

# Ensure output folder exists
if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    Write-Host "Created output folder: $OutputFolder" -ForegroundColor Green
}

Write-Host "`n=== Generating Test Reports with Dummy Data ===" -ForegroundColor Cyan
Write-Host "Output folder: $OutputFolder`n" -ForegroundColor Gray

# Generate all test data
Write-Host "Generating test data..." -ForegroundColor Yellow
$testData = New-TestAllData
Write-Host "Test data generated successfully!`n" -ForegroundColor Green

# Test Security Report
Write-Host "Generating Security Report..." -ForegroundColor Yellow
try {
    Export-SecurityReport -AuditResult $testData.Security -OutputPath (Join-Path $OutputFolder "security.html")
    Write-Host "  ✓ Security report generated" -ForegroundColor Green
} catch {
    Write-Host "  ✗ Security report failed: $_" -ForegroundColor Red
}

# Test VM Backup Report
Write-Host "Generating VM Backup Report..." -ForegroundColor Yellow
try {
    Export-VMBackupReport -VMInventory $testData.VMBackup -OutputPath (Join-Path $OutputFolder "vm-backup.html") -TenantId "test-tenant-12345"
    Write-Host "  ✓ VM Backup report generated" -ForegroundColor Green
} catch {
    Write-Host "  ✗ VM Backup report failed: $_" -ForegroundColor Red
}

# Test Change Tracking Report
Write-Host "Generating Change Tracking Report..." -ForegroundColor Yellow
try {
    Export-ChangeTrackingReport -ChangeTrackingData $testData.ChangeTracking -OutputPath (Join-Path $OutputFolder "change-tracking.html") -TenantId "test-tenant-12345"
    Write-Host "  ✓ Change Tracking report generated" -ForegroundColor Green
} catch {
    Write-Host "  ✗ Change Tracking report failed: $_" -ForegroundColor Red
}

# Test Cost Tracking Report
Write-Host "Generating Cost Tracking Report..." -ForegroundColor Yellow
try {
    Export-CostTrackingReport -CostTrackingData $testData.CostTracking -OutputPath (Join-Path $OutputFolder "cost-tracking.html") -TenantId "test-tenant-12345"
    Write-Host "  ✓ Cost Tracking report generated" -ForegroundColor Green
} catch {
    Write-Host "  ✗ Cost Tracking report failed: $_" -ForegroundColor Red
}

# Test EOL Report
Write-Host "Generating EOL Report..." -ForegroundColor Yellow
try {
    Export-EOLReport -EOLFindings $testData.EOL -OutputPath (Join-Path $OutputFolder "eol.html") -TenantId "test-tenant-12345"
    Write-Host "  ✓ EOL report generated" -ForegroundColor Green
} catch {
    Write-Host "  ✗ EOL report failed: $_" -ForegroundColor Red
}

# Test Network Inventory Report
Write-Host "Generating Network Inventory Report..." -ForegroundColor Yellow
try {
    Export-NetworkInventoryReport -NetworkInventory $testData.NetworkInventory -OutputPath (Join-Path $OutputFolder "network-inventory.html") -TenantId "test-tenant-12345"
    Write-Host "  ✓ Network Inventory report generated" -ForegroundColor Green
} catch {
    Write-Host "  ✗ Network Inventory report failed: $_" -ForegroundColor Red
}

# Test RBAC Report
Write-Host "Generating RBAC Report..." -ForegroundColor Yellow
try {
    Export-RBACReport -RBACData $testData.RBAC -OutputPath (Join-Path $OutputFolder "rbac.html") -TenantId "test-tenant-12345"
    Write-Host "  ✓ RBAC report generated" -ForegroundColor Green
} catch {
    Write-Host "  ✗ RBAC report failed: $_" -ForegroundColor Red
}

# Test Advisor Report
Write-Host "Generating Advisor Report..." -ForegroundColor Yellow
try {
    Export-AdvisorReport -AdvisorRecommendations $testData.Advisor -OutputPath (Join-Path $OutputFolder "advisor.html") -TenantId "test-tenant-12345"
    Write-Host "  ✓ Advisor report generated" -ForegroundColor Green
} catch {
    Write-Host "  ✗ Advisor report failed: $_" -ForegroundColor Red
}

Write-Host "`n=== Test Reports Generated ===" -ForegroundColor Cyan
Write-Host "All reports saved to: $OutputFolder" -ForegroundColor Green
Write-Host "`nYou can now open the HTML files to test CSS changes!" -ForegroundColor Yellow

