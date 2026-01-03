
$ErrorActionPreference = "Stop"

. .\Init-Local.ps1

try {
    Write-Host "Loading data..."
    . .\Tools\New-TestData.ps1
    $data = New-TestCostTrackingData
    Write-Host "Data loaded."
    
    $outputPath = "d:\Dev\scripts\AzureInventory\test-output\debug-cost.html"
    Write-Host "Exporting to $outputPath..."
    
    Export-CostTrackingReport -CostTrackingData $data -OutputPath $outputPath -TenantId "debug-tenant"
    
    if (Test-Path $outputPath) {
        Write-Host "SUCCESS: File created at $outputPath" -ForegroundColor Green
    } else {
        Write-Error "FAILURE: File was not created at $outputPath"
    }
} catch {
    Write-Error "CRITICAL FAILURE: $_"
    Write-Error $_.ScriptStackTrace
}
