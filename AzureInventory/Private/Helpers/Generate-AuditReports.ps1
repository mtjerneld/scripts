<#
.SYNOPSIS
    Generates all audit reports (HTML and optionally JSON).

.DESCRIPTION
    Creates output folder and generates dashboard, security, VM backup, and Advisor reports.

.PARAMETER AuditResult
    AuditResult object containing all findings and data.

.PARAMETER OutputPath
    Optional custom output path. If not provided, creates default path.

.PARAMETER ExportJson
    Whether to also export findings as JSON.

.OUTPUTS
    Path to the output folder.
#>
function Generate-AuditReports {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$AuditResult,
        
        [Parameter(Mandatory = $false)]
        [string]$OutputPath,
        
        [switch]$ExportJson
    )
    
    $tenantId = $AuditResult.TenantId
    
    # Create output folder structure
    if (-not $OutputPath) {
        # Get module root directory (parent of Public folder)
        $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        
        # Create output folder structure: output/{tenantId}-{datetime}/
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $tenantFolder = if ($tenantId) { $tenantId } else { "unknown-tenant" }
        $outputFolderName = "$tenantFolder-$timestamp"
        # Use nested Join-Path for PowerShell 5.1 compatibility (only accepts 2 args)
        $outputFolder = Join-Path (Join-Path $moduleRoot "output") $outputFolderName
        
        # Create the output folder if it doesn't exist
        if (-not (Test-Path $outputFolder)) {
            New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null
            Write-Verbose "Created output folder: $outputFolder"
        }
    }
    else {
        # Use custom output path
        $outputFolder = $OutputPath
        if (-not [System.IO.Path]::IsPathRooted($outputFolder)) {
            $outputFolder = Join-Path (Get-Location).Path $outputFolder
        }
        
        # Create folder if it doesn't exist
        if (-not (Test-Path $outputFolder)) {
            New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null
        }
    }
    
    Write-Host "`n=== Generating Reports ===" -ForegroundColor Cyan
    Write-Host "Output folder: $outputFolder" -ForegroundColor Gray
    
    # Generate reports
    try {
        Write-Host "  - Dashboard..." -NoNewline
        $dashboardPath = Join-Path $outputFolder "index.html"
        $null = Export-DashboardReport -AuditResult $AuditResult -VMInventory $AuditResult.VMInventory -AdvisorRecommendations $AuditResult.AdvisorRecommendations -OutputPath $dashboardPath -TenantId $tenantId
        Write-Host " OK" -ForegroundColor Green
    }
    catch {
        Write-Host " ERROR: $_" -ForegroundColor Red
    }
    
    try {
        Write-Host "  - Security Audit..." -NoNewline
        $securityReportPath = Join-Path $outputFolder "security.html"
        $null = Export-SecurityReport -AuditResult $AuditResult -OutputPath $securityReportPath
        Write-Host " OK" -ForegroundColor Green
    }
    catch {
        Write-Host " ERROR: $_" -ForegroundColor Red
    }
    
    try {
        Write-Host "  - VM Backup..." -NoNewline
        $vmBackupReportPath = Join-Path $outputFolder "vm-backup.html"
        $null = Export-VMBackupReport -VMInventory $AuditResult.VMInventory -OutputPath $vmBackupReportPath -TenantId $tenantId
        Write-Host " OK" -ForegroundColor Green
    }
    catch {
        Write-Host " ERROR: $_" -ForegroundColor Red
    }
    
    try {
        Write-Host "  - Advisor..." -NoNewline
        $advisorReportPath = Join-Path $outputFolder "advisor.html"
        $null = Export-AdvisorReport -AdvisorRecommendations $AuditResult.AdvisorRecommendations -OutputPath $advisorReportPath -TenantId $tenantId
        Write-Host " OK" -ForegroundColor Green
    }
    catch {
        Write-Host " ERROR: $_" -ForegroundColor Red
    }
    
    # Export JSON if requested
    if ($ExportJson) {
        try {
            Write-Host "  - JSON export..." -NoNewline
            $jsonPath = Join-Path $outputFolder "audit-data.json"
            $AuditResult | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
            Write-Host " OK" -ForegroundColor Green
        }
        catch {
            Write-Host " ERROR: $_" -ForegroundColor Red
        }
    }
    
    return $outputFolder
}

