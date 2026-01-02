<#
.SYNOPSIS
    Saves test cost data structure for comparison with real data.

.DESCRIPTION
    Generates test data and saves it in the same format as Save-RealCostDataSample.ps1
    for direct comparison.

.PARAMETER OutputPath
    Directory to save the captured data. Default: ./test-output/test-data-sample

.EXAMPLE
    .\Save-TestCostDataSample.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputPath = "./test-output/test-data-sample"
)

# Import test data generator
$scriptRoot = $PSScriptRoot
. "$scriptRoot\New-TestData.ps1"

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Host "`n=== Capturing Test Cost Data Sample ===" -ForegroundColor Cyan
Write-Host "Output: $OutputPath" -ForegroundColor Gray

# Generate test data
Write-Host "`nGenerating test cost data..." -ForegroundColor Gray
$costData = New-TestCostTrackingData -DayCount 7

if (-not $costData) {
    Write-Error "Failed to generate test data"
    exit 1
}

Write-Host "Test data generated!" -ForegroundColor Green

# Save full data as JSON
$fullDataPath = Join-Path $OutputPath "cost-data-full.json"
Write-Host "`nSaving full data to: $fullDataPath" -ForegroundColor Gray
$costData | ConvertTo-Json -Depth 10 | Out-File -FilePath $fullDataPath -Encoding UTF8
Write-Host "  Size: $([math]::Round((Get-Item $fullDataPath).Length / 1KB, 2)) KB" -ForegroundColor Gray

# Save specific samples (same format as real data script)
$samples = @{
    "_description" = "Sample entries from TEST cost data for comparison with real data"
    "_generatedAt" = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    # Top-level keys
    "TopLevelKeys" = @($costData.Keys | Sort-Object)

    # BySubscription sample
    "BySubscription_Keys" = @($costData.BySubscription.Keys | Select-Object -First 5)
    "BySubscription_FirstEntry" = if ($costData.BySubscription.Count -gt 0) {
        $firstKey = $costData.BySubscription.Keys | Select-Object -First 1
        @{
            "Key" = $firstKey
            "Value" = $costData.BySubscription[$firstKey]
        }
    } else { $null }

    # ByMeterCategory sample
    "ByMeterCategory_Keys" = @($costData.ByMeterCategory.Keys | Select-Object -First 10)
    "ByMeterCategory_FirstEntry" = if ($costData.ByMeterCategory.Count -gt 0) {
        $firstKey = $costData.ByMeterCategory.Keys | Select-Object -First 1
        @{
            "Key" = $firstKey
            "Value" = $costData.ByMeterCategory[$firstKey]
        }
    } else { $null }

    # DailyTrend sample
    "DailyTrend_Count" = $costData.DailyTrend.Count
    "DailyTrend_FirstDay" = if ($costData.DailyTrend.Count -gt 0) {
        $firstDay = $costData.DailyTrend[0]
        @{
            "Date" = $firstDay.Date
            "DateString" = $firstDay.DateString
            "TotalCostLocal" = $firstDay.TotalCostLocal
            "TotalCostUSD" = $firstDay.TotalCostUSD
            "ByCategory_Keys" = @($firstDay.ByCategory.Keys)
            "ByCategory_FirstEntry" = if ($firstDay.ByCategory.Count -gt 0) {
                $catKey = $firstDay.ByCategory.Keys | Select-Object -First 1
                @{
                    "Key" = $catKey
                    "Value" = $firstDay.ByCategory[$catKey]
                }
            } else { $null }
            "BySubscription_Keys" = @($firstDay.BySubscription.Keys)
            "BySubscription_FirstEntry" = if ($firstDay.BySubscription.Count -gt 0) {
                $subKey = $firstDay.BySubscription.Keys | Select-Object -First 1
                @{
                    "Key" = $subKey
                    "Value" = $firstDay.BySubscription[$subKey]
                }
            } else { $null }
            "ByMeter_Keys" = @($firstDay.ByMeter.Keys | Select-Object -First 10)
            "ByMeter_FirstEntry" = if ($firstDay.ByMeter.Count -gt 0) {
                $meterKey = $firstDay.ByMeter.Keys | Select-Object -First 1
                @{
                    "Key" = $meterKey
                    "Value" = $firstDay.ByMeter[$meterKey]
                }
            } else { $null }
            "ByResource_Keys" = @($firstDay.ByResource.Keys | Select-Object -First 10)
            "ByResource_FirstEntry" = if ($firstDay.ByResource.Count -gt 0) {
                $resKey = $firstDay.ByResource.Keys | Select-Object -First 1
                @{
                    "Key" = $resKey
                    "Value" = $firstDay.ByResource[$resKey]
                }
            } else { $null }
        }
    } else { $null }

    # TopResources sample
    "TopResources_Count" = $costData.TopResources.Count
    "TopResources_FirstEntry" = if ($costData.TopResources.Count -gt 0) {
        $costData.TopResources[0]
    } else { $null }
}

$samplesPath = Join-Path $OutputPath "cost-data-samples.json"
$samples | ConvertTo-Json -Depth 10 | Out-File -FilePath $samplesPath -Encoding UTF8
Write-Host "Samples saved to: $samplesPath" -ForegroundColor Gray

# Create minimal structure (same format as real data script)
$minimal = @{
    "_description" = "Minimal TEST data for direct comparison"

    "BySubscription_Structure" = @{}
    "DailyTrend_Structure" = @{}
}

if ($costData.BySubscription.Count -gt 0) {
    $firstSubKey = $costData.BySubscription.Keys | Select-Object -First 1
    $firstSub = $costData.BySubscription[$firstSubKey]
    $minimal.BySubscription_Structure = @{
        "KeyExample" = $firstSubKey
        "KeyType" = $firstSubKey.GetType().Name
        "Properties" = @($firstSub.Keys | Sort-Object)
    }
}

if ($costData.DailyTrend.Count -gt 0) {
    $firstDay = $costData.DailyTrend[0]
    # Handle both hashtable and PSCustomObject
    $firstDayKeys = if ($firstDay -is [hashtable]) {
        @($firstDay.Keys | Sort-Object)
    } else {
        @($firstDay.PSObject.Properties.Name | Sort-Object)
    }
    $minimal.DailyTrend_Structure = @{
        "TopLevelProperties" = $firstDayKeys
    }

    if ($firstDay.ByCategory.Count -gt 0) {
        $firstCatKey = $firstDay.ByCategory.Keys | Select-Object -First 1
        $firstCat = $firstDay.ByCategory[$firstCatKey]
        $minimal.DailyTrend_Structure["ByCategory"] = @{
            "KeyExample" = $firstCatKey
            "Properties" = @($firstCat.Keys | Sort-Object)
            "BySubscription_ValueType" = if ($firstCat.BySubscription -and $firstCat.BySubscription.Count -gt 0) {
                $subKey = $firstCat.BySubscription.Keys | Select-Object -First 1
                $subVal = $firstCat.BySubscription[$subKey]
                @{
                    "KeyExample" = $subKey
                    "ValueType" = $subVal.GetType().Name
                    "Properties" = if ($subVal -is [hashtable]) { @($subVal.Keys) } else { "direct value: $subVal" }
                }
            } else { "empty" }
        }
    }

    if ($firstDay.BySubscription.Count -gt 0) {
        $firstSubKey = $firstDay.BySubscription.Keys | Select-Object -First 1
        $firstSub = $firstDay.BySubscription[$firstSubKey]
        $minimal.DailyTrend_Structure["BySubscription"] = @{
            "KeyExample" = $firstSubKey
            "Properties" = @($firstSub.Keys | Sort-Object)
            "ByCategory_ValueType" = if ($firstSub.ByCategory -and $firstSub.ByCategory.Count -gt 0) {
                $catKey = $firstSub.ByCategory.Keys | Select-Object -First 1
                $catVal = $firstSub.ByCategory[$catKey]
                @{
                    "KeyExample" = $catKey
                    "ValueType" = $catVal.GetType().Name
                    "Properties" = if ($catVal -is [hashtable]) { @($catVal.Keys) } else { "direct value: $catVal" }
                }
            } else { "empty" }
        }
    }

    if ($firstDay.ByMeter.Count -gt 0) {
        $firstMeterKey = $firstDay.ByMeter.Keys | Select-Object -First 1
        $firstMeter = $firstDay.ByMeter[$firstMeterKey]
        $minimal.DailyTrend_Structure["ByMeter"] = @{
            "KeyExample" = $firstMeterKey
            "Properties" = @($firstMeter.Keys | Sort-Object)
        }
    }

    if ($firstDay.ByResource.Count -gt 0) {
        $firstResKey = $firstDay.ByResource.Keys | Select-Object -First 1
        $firstRes = $firstDay.ByResource[$firstResKey]
        $minimal.DailyTrend_Structure["ByResource"] = @{
            "KeyExample" = $firstResKey
            "Properties" = @($firstRes.Keys | Sort-Object)
        }
    }
}

$minimalPath = Join-Path $OutputPath "cost-data-minimal-structure.json"
$minimal | ConvertTo-Json -Depth 10 | Out-File -FilePath $minimalPath -Encoding UTF8
Write-Host "Minimal structure saved to: $minimalPath" -ForegroundColor Gray

Write-Host "`n=== Done ===" -ForegroundColor Green
Write-Host "Files created in $OutputPath" -ForegroundColor Cyan
Write-Host "`nTo compare with real data:" -ForegroundColor Yellow
Write-Host "  1. Run: .\Save-RealCostDataSample.ps1" -ForegroundColor White
Write-Host "  2. Compare the cost-data-minimal-structure.json files" -ForegroundColor White
Write-Host "  3. Look for differences in:" -ForegroundColor White
Write-Host "     - Key names and types" -ForegroundColor Gray
Write-Host "     - Property names" -ForegroundColor Gray
Write-Host "     - Nested object structures" -ForegroundColor Gray
