# Test-Local.ps1 - Snabb testning utan modul
# Kör detta skript för att ladda alla funktioner direkt för snabb testning
# Laddar automatiskt om funktioner om de redan finns
# 
# VIKTIGT: Du MÅSTE köra med punkt och mellanslag:
#   . .\Test-Local.ps1
# 
# Om du kör .\Test-Local.ps1 (utan punkt) fungerar det INTE!

param()

$ModuleRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }

# Varna om skriptet körs utan dot-source
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.Line -notmatch '^\s*\.\s+') {
    Write-Host "`n[ERROR] Script must be run with dot-source!" -ForegroundColor Red
    Write-Host "Use: . .\Test-Local.ps1" -ForegroundColor Yellow
    Write-Host "(Note the dot and space before the script name)`n" -ForegroundColor Yellow
    Write-Host "Current command: $($MyInvocation.Line)" -ForegroundColor Gray
    return
}

Write-Host "Reloading all functions for local testing..." -ForegroundColor Cyan

# Ta bort alla befintliga funktioner från modulen först
Write-Host "  Removing existing functions..." -ForegroundColor Gray
$functionsToRemove = @(
    'Connect-AuditEnvironment',
    'Invoke-AzureSecurityAudit',
    'Export-SecurityReport',
    'Get-SubscriptionContext',
    'Invoke-AzureApiWithRetry',
    'New-SecurityFinding',
    'Get-ControlDefinitions',
    'Get-StorageAccountFindings',
    'Get-AppServiceFindings',
    'Get-VirtualMachineFindings',
    'Get-AzureArcFindings',
    'Get-AzureMonitorFindings',
    'Get-NetworkSecurityFindings',
    'Get-SqlDatabaseFindings'
)

foreach ($funcName in $functionsToRemove) {
    if (Get-Command $funcName -ErrorAction SilentlyContinue) {
        Remove-Item "Function:\$funcName" -ErrorAction SilentlyContinue
        Write-Verbose "Removed: $funcName"
    }
}

# Ta bort modulen också om den är laddad
Get-Module AzureSecurityAudit | Remove-Module -Force -ErrorAction SilentlyContinue

Write-Host "  Loading functions..." -ForegroundColor Gray

# Ladda alla dependencies i rätt ordning
Write-Host "  Loading Private Helpers..." -ForegroundColor Gray
Get-ChildItem -Path "$ModuleRoot\Private\Helpers\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object { 
    . $_.FullName
    Write-Verbose "Loaded: $($_.Name)"
}

Write-Host "  Loading Private Scanners..." -ForegroundColor Gray
Get-ChildItem -Path "$ModuleRoot\Private\Scanners\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object { 
    . $_.FullName
    Write-Verbose "Loaded: $($_.Name)"
}

Write-Host "  Loading Private Config..." -ForegroundColor Gray
Get-ChildItem -Path "$ModuleRoot\Private\Config\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object { 
    . $_.FullName
    Write-Verbose "Loaded: $($_.Name)"
}

Write-Host "  Loading Public Functions..." -ForegroundColor Gray
Get-ChildItem -Path "$ModuleRoot\Public\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object { 
    . $_.FullName
    Write-Verbose "Loaded: $($_.Name)"
}

Write-Host "`n[OK] All functions loaded! Ready to test." -ForegroundColor Green
Write-Host "Available functions:" -ForegroundColor Cyan
$loadedFunctions = @()
Get-ChildItem -Path "$ModuleRoot\Public\*.ps1" | ForEach-Object {
    $funcName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
    if (Get-Command $funcName -ErrorAction SilentlyContinue) {
        Write-Host "  - $funcName [OK]" -ForegroundColor Green
        $loadedFunctions += $funcName
    } else {
        Write-Host "  - $funcName [MISSING]" -ForegroundColor Red
    }
}

if ($loadedFunctions.Count -eq 0) {
    Write-Host "`n[WARNING] No functions were loaded!" -ForegroundColor Yellow
    Write-Host "Make sure you run this script with: . .\Test-Local.ps1" -ForegroundColor Yellow
    Write-Host "(Note the dot and space before the script name)" -ForegroundColor Yellow
} else {
    Write-Host "`nTip: You can also define this function in your PowerShell profile:" -ForegroundColor Cyan
    Write-Host '  function Reload-Audit { . .\Test-Local.ps1 }' -ForegroundColor Gray
    Write-Host "Then just run: Reload-Audit" -ForegroundColor Gray
}

