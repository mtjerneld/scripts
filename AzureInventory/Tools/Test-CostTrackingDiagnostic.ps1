# Quick diagnostic script to check Cost Tracking data structure
# Run this to see what's happening with the data

. .\Tools\New-TestData.ps1
. .\Init-Local.ps1

Write-Host "`n=== COST TRACKING DATA DIAGNOSTIC ===" -ForegroundColor Cyan
Write-Host ""

# Generate test data
Write-Host "Generating test data..." -ForegroundColor Yellow
$testData = New-TestCostTrackingData

Write-Host "`n1. Top-level structure:" -ForegroundColor Green
Write-Host "   Has DailyTrend: $($testData.DailyTrend -ne $null)"
Write-Host "   DailyTrend type: $($testData.DailyTrend.GetType().FullName)"

if ($testData.DailyTrend) {
    Write-Host "   DailyTrend count: $($testData.DailyTrend.Count)"
    
    if ($testData.DailyTrend.Count -gt 0) {
        Write-Host "`n2. First day structure:" -ForegroundColor Green
        $firstDay = $testData.DailyTrend[0]
        Write-Host "   First day type: $($firstDay.GetType().FullName)"
        Write-Host "   Properties: $($firstDay.PSObject.Properties.Name -join ', ')"
        Write-Host "   DateString: '$($firstDay.DateString)'"
        Write-Host "   Date: $($firstDay.Date)"
        Write-Host "   Date type: $($firstDay.Date.GetType().FullName)"
        Write-Host "   TotalCostLocal: $($firstDay.TotalCostLocal)"
        Write-Host "   Has ByCategory: $($firstDay.ByCategory -ne $null)"
        Write-Host "   Has BySubscription: $($firstDay.BySubscription -ne $null)"
        Write-Host "   Has ByResource: $($firstDay.ByResource -ne $null)"
        
        if ($firstDay.ByCategory) {
            Write-Host "   ByCategory keys: $($firstDay.ByCategory.Keys -join ', ')"
        }
        
        Write-Host "`n3. Testing export function:" -ForegroundColor Green
        $outputPath = "test-output\costtracking-diagnostic.html"
        try {
            Export-CostTrackingReport -CostTrackingData $testData -OutputPath $outputPath -TenantId "test-tenant"
            Write-Host "   Export succeeded: $outputPath" -ForegroundColor Green
            
            # Check the HTML for chart data
            $html = Get-Content $outputPath -Raw
            if ($html -match 'const chartLabels = \[(.*?)\];') {
                $labels = $matches[1]
                $labelCount = ($labels -split ',').Count
                Write-Host "   Chart labels found: $labelCount labels" -ForegroundColor Green
                Write-Host "   First 5 labels: $($labels.Substring(0, [Math]::Min(100, $labels.Length)))..." -ForegroundColor Gray
            } else {
                Write-Host "   WARNING: No chartLabels found in HTML!" -ForegroundColor Red
            }
            
            if ($html -match 'const rawDailyData = (.*?);') {
                $rawData = $matches[1]
                if ($rawData -match '"date":null') {
                    Write-Host "   WARNING: Found null dates in rawDailyData!" -ForegroundColor Red
                } else {
                    Write-Host "   rawDailyData appears valid" -ForegroundColor Green
                }
            }
        } catch {
            Write-Host "   ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "   Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
        }
    } else {
        Write-Host "   ERROR: DailyTrend is empty!" -ForegroundColor Red
    }
} else {
    Write-Host "   ERROR: DailyTrend is null!" -ForegroundColor Red
}

Write-Host "`n=== END DIAGNOSTIC ===" -ForegroundColor Cyan

