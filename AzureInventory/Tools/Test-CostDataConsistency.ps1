
. .\Tools\New-TestData.ps1

Write-Host "Generating Cost Tracking Data..."
$data = New-TestCostTrackingData

Write-Host "TotalCostLocal from Data: $($data.TotalCostLocal)"

# 1. Check DailyTrend Consistency
$sumDailyTotal = 0
$sumCategoryTotal = 0
$sumSubscriptionTotal = 0

foreach ($day in $data.DailyTrend) {
    $sumDailyTotal += $day.TotalCostLocal
    
    $dayCatTotal = 0
    foreach ($cat in $day.ByCategory.Values) {
        $dayCatTotal += $cat.CostLocal
    }
    $sumCategoryTotal += $dayCatTotal
    
    $daySubTotal = 0
    if ($day.BySubscription) {
        foreach ($sub in $day.BySubscription.Values) {
            $daySubTotal += $sub.CostLocal
        }
    }
    $sumSubscriptionTotal += $daySubTotal
}

Write-Host "Sum of Daily TotalCostLocal: $sumDailyTotal"
Write-Host "Sum of Daily Category Costs: $sumCategoryTotal"
Write-Host "Sum of Daily Subscription Costs: $sumSubscriptionTotal"

if ([math]::Abs($sumCategoryTotal - $sumSubscriptionTotal) -gt 0.1) {
    Write-Error "Mismatch in DailyTrend: Category sum != Subscription sum!"
} else {
    Write-Host "DailyTrend Consistency: OK" -ForegroundColor Green
}

# 2. Simulate Export-CostTrackingReport Logic for rawDailyData
Write-Host "`nSimulating Export Logic..."
$simulatedJSTotal = 0
$allCategories = $data.ByMeterCategory.Keys | Sort-Object

foreach ($day in $data.DailyTrend) {
    $dayTotal = 0
    
    foreach ($category in $allCategories) {
        $catCost = 0
        $catSubs = @{}
        
        # Logic from Export-CostTrackingReport.ps1
        if ($day.BySubscription) {
            foreach ($subName in $day.BySubscription.Keys) {
                $subData = $day.BySubscription[$subName]
                
                if ($subData.ByCategory -and $subData.ByCategory.ContainsKey($category)) {
                    $subCatCost = $subData.ByCategory[$category].CostLocal
                    $catCost += [math]::Round($subCatCost, 2)
                }
            }
        }
        
        # JS Logic: Sum of subscriptions
        $dayTotal += $catCost
    }
    
    $simulatedJSTotal += $dayTotal
}

Write-Host "Simulated JS Total (Sum of all subscriptions in all categories): $simulatedJSTotal"

if ([math]::Abs($simulatedJSTotal - $data.TotalCostLocal) -gt 1.0) {
    Write-Error "Mismatch! Simulated JS Total ($simulatedJSTotal) != TotalCostLocal ($($data.TotalCostLocal))"
    Write-Host "Difference: $($simulatedJSTotal - $data.TotalCostLocal)"
} else {
    Write-Host "Export Logic Consistency: OK" -ForegroundColor Green
}
