<#
.SYNOPSIS
    Compares real and test cost data structures to identify differences.

.DESCRIPTION
    Reads the minimal structure files from both real and test data samples
    and outputs a detailed comparison highlighting differences.

.PARAMETER RealDataPath
    Path to real data sample directory. Default: ./test-output/real-data-sample

.PARAMETER TestDataPath
    Path to test data sample directory. Default: ./test-output/test-data-sample

.EXAMPLE
    .\Compare-CostDataStructures.ps1
#>
[CmdletBinding()]
param(
    [string]$RealDataPath = "./test-output/real-data-sample",
    [string]$TestDataPath = "./test-output/test-data-sample"
)

Write-Host "`n=== Cost Data Structure Comparison ===" -ForegroundColor Cyan

# Check if files exist
$realMinimalPath = Join-Path $RealDataPath "cost-data-minimal-structure.json"
$testMinimalPath = Join-Path $TestDataPath "cost-data-minimal-structure.json"
$realSamplesPath = Join-Path $RealDataPath "cost-data-samples.json"
$testSamplesPath = Join-Path $TestDataPath "cost-data-samples.json"

$missingFiles = @()
if (-not (Test-Path $realMinimalPath)) { $missingFiles += "Real: $realMinimalPath" }
if (-not (Test-Path $testMinimalPath)) { $missingFiles += "Test: $testMinimalPath" }
if (-not (Test-Path $realSamplesPath)) { $missingFiles += "Real samples: $realSamplesPath" }
if (-not (Test-Path $testSamplesPath)) { $missingFiles += "Test samples: $testSamplesPath" }

if ($missingFiles.Count -gt 0) {
    Write-Host "`nMissing files:" -ForegroundColor Red
    $missingFiles | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host "`nPlease run the following scripts first:" -ForegroundColor Yellow
    Write-Host "  .\Save-RealCostDataSample.ps1" -ForegroundColor White
    Write-Host "  .\Save-TestCostDataSample.ps1" -ForegroundColor White
    exit 1
}

# Load data
$realMinimal = Get-Content $realMinimalPath -Raw | ConvertFrom-Json
$testMinimal = Get-Content $testMinimalPath -Raw | ConvertFrom-Json
$realSamples = Get-Content $realSamplesPath -Raw | ConvertFrom-Json
$testSamples = Get-Content $testSamplesPath -Raw | ConvertFrom-Json

$differences = @()

function Compare-Arrays {
    param($Name, $Real, $Test)

    $realSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$Real)
    $testSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$Test)

    $onlyInReal = $Real | Where-Object { -not $testSet.Contains($_) }
    $onlyInTest = $Test | Where-Object { -not $realSet.Contains($_) }

    if ($onlyInReal.Count -gt 0 -or $onlyInTest.Count -gt 0) {
        return @{
            Name = $Name
            OnlyInReal = $onlyInReal
            OnlyInTest = $onlyInTest
        }
    }
    return $null
}

Write-Host "`n--- Top-Level Keys ---" -ForegroundColor Yellow
$topLevelDiff = Compare-Arrays -Name "TopLevelKeys" -Real $realSamples.TopLevelKeys -Test $testSamples.TopLevelKeys
if ($topLevelDiff) {
    if ($topLevelDiff.OnlyInReal) {
        Write-Host "  Only in REAL: $($topLevelDiff.OnlyInReal -join ', ')" -ForegroundColor Red
        $differences += "TopLevelKeys: Missing in test: $($topLevelDiff.OnlyInReal -join ', ')"
    }
    if ($topLevelDiff.OnlyInTest) {
        Write-Host "  Only in TEST: $($topLevelDiff.OnlyInTest -join ', ')" -ForegroundColor Magenta
        $differences += "TopLevelKeys: Extra in test: $($topLevelDiff.OnlyInTest -join ', ')"
    }
} else {
    Write-Host "  OK - Keys match" -ForegroundColor Green
}

Write-Host "`n--- BySubscription Structure ---" -ForegroundColor Yellow
Write-Host "  Real key example: $($realMinimal.BySubscription_Structure.KeyExample)" -ForegroundColor Gray
Write-Host "  Test key example: $($testMinimal.BySubscription_Structure.KeyExample)" -ForegroundColor Gray
Write-Host "  Real key type: $($realMinimal.BySubscription_Structure.KeyType)" -ForegroundColor Gray
Write-Host "  Test key type: $($testMinimal.BySubscription_Structure.KeyType)" -ForegroundColor Gray

$bySubPropsDiff = Compare-Arrays -Name "BySubscription Properties" `
    -Real $realMinimal.BySubscription_Structure.Properties `
    -Test $testMinimal.BySubscription_Structure.Properties
if ($bySubPropsDiff) {
    if ($bySubPropsDiff.OnlyInReal) {
        Write-Host "  Properties only in REAL: $($bySubPropsDiff.OnlyInReal -join ', ')" -ForegroundColor Red
        $differences += "BySubscription: Missing properties: $($bySubPropsDiff.OnlyInReal -join ', ')"
    }
    if ($bySubPropsDiff.OnlyInTest) {
        Write-Host "  Properties only in TEST: $($bySubPropsDiff.OnlyInTest -join ', ')" -ForegroundColor Magenta
        $differences += "BySubscription: Extra properties: $($bySubPropsDiff.OnlyInTest -join ', ')"
    }
} else {
    Write-Host "  OK - Properties match" -ForegroundColor Green
}

Write-Host "`n--- DailyTrend Top-Level Properties ---" -ForegroundColor Yellow
$dailyPropsDiff = Compare-Arrays -Name "DailyTrend Properties" `
    -Real $realMinimal.DailyTrend_Structure.TopLevelProperties `
    -Test $testMinimal.DailyTrend_Structure.TopLevelProperties
if ($dailyPropsDiff) {
    if ($dailyPropsDiff.OnlyInReal) {
        Write-Host "  Properties only in REAL: $($dailyPropsDiff.OnlyInReal -join ', ')" -ForegroundColor Red
        $differences += "DailyTrend: Missing properties: $($dailyPropsDiff.OnlyInReal -join ', ')"
    }
    if ($dailyPropsDiff.OnlyInTest) {
        Write-Host "  Properties only in TEST: $($dailyPropsDiff.OnlyInTest -join ', ')" -ForegroundColor Magenta
        $differences += "DailyTrend: Extra properties: $($dailyPropsDiff.OnlyInTest -join ', ')"
    }
} else {
    Write-Host "  OK - Properties match" -ForegroundColor Green
}

Write-Host "`n--- DailyTrend.ByCategory Structure ---" -ForegroundColor Yellow
if ($realMinimal.DailyTrend_Structure.ByCategory -and $testMinimal.DailyTrend_Structure.ByCategory) {
    $byCatPropsDiff = Compare-Arrays -Name "ByCategory Properties" `
        -Real $realMinimal.DailyTrend_Structure.ByCategory.Properties `
        -Test $testMinimal.DailyTrend_Structure.ByCategory.Properties
    if ($byCatPropsDiff) {
        if ($byCatPropsDiff.OnlyInReal) {
            Write-Host "  Properties only in REAL: $($byCatPropsDiff.OnlyInReal -join ', ')" -ForegroundColor Red
            $differences += "DailyTrend.ByCategory: Missing properties: $($byCatPropsDiff.OnlyInReal -join ', ')"
        }
        if ($byCatPropsDiff.OnlyInTest) {
            Write-Host "  Properties only in TEST: $($byCatPropsDiff.OnlyInTest -join ', ')" -ForegroundColor Magenta
        }
    } else {
        Write-Host "  OK - Properties match" -ForegroundColor Green
    }

    # Check BySubscription value type
    $realByCatSubType = $realMinimal.DailyTrend_Structure.ByCategory.BySubscription_ValueType
    $testByCatSubType = $testMinimal.DailyTrend_Structure.ByCategory.BySubscription_ValueType
    Write-Host "  BySubscription value type:" -ForegroundColor Gray
    Write-Host "    Real: $($realByCatSubType | ConvertTo-Json -Compress)" -ForegroundColor Gray
    Write-Host "    Test: $($testByCatSubType | ConvertTo-Json -Compress)" -ForegroundColor Gray
    if ($realByCatSubType.ValueType -ne $testByCatSubType.ValueType) {
        Write-Host "    MISMATCH in value type!" -ForegroundColor Red
        $differences += "DailyTrend.ByCategory.BySubscription: Type mismatch - Real: $($realByCatSubType.ValueType), Test: $($testByCatSubType.ValueType)"
    }
}

Write-Host "`n--- DailyTrend.BySubscription Structure ---" -ForegroundColor Yellow
if ($realMinimal.DailyTrend_Structure.BySubscription -and $testMinimal.DailyTrend_Structure.BySubscription) {
    Write-Host "  Real key example: $($realMinimal.DailyTrend_Structure.BySubscription.KeyExample)" -ForegroundColor Gray
    Write-Host "  Test key example: $($testMinimal.DailyTrend_Structure.BySubscription.KeyExample)" -ForegroundColor Gray

    $bySubPropsDiff = Compare-Arrays -Name "BySubscription Properties" `
        -Real $realMinimal.DailyTrend_Structure.BySubscription.Properties `
        -Test $testMinimal.DailyTrend_Structure.BySubscription.Properties
    if ($bySubPropsDiff) {
        if ($bySubPropsDiff.OnlyInReal) {
            Write-Host "  Properties only in REAL: $($bySubPropsDiff.OnlyInReal -join ', ')" -ForegroundColor Red
            $differences += "DailyTrend.BySubscription: Missing properties: $($bySubPropsDiff.OnlyInReal -join ', ')"
        }
        if ($bySubPropsDiff.OnlyInTest) {
            Write-Host "  Properties only in TEST: $($bySubPropsDiff.OnlyInTest -join ', ')" -ForegroundColor Magenta
        }
    } else {
        Write-Host "  OK - Properties match" -ForegroundColor Green
    }

    # Check ByCategory value type
    $realBySubCatType = $realMinimal.DailyTrend_Structure.BySubscription.ByCategory_ValueType
    $testBySubCatType = $testMinimal.DailyTrend_Structure.BySubscription.ByCategory_ValueType
    Write-Host "  ByCategory value type:" -ForegroundColor Gray
    Write-Host "    Real: $($realBySubCatType | ConvertTo-Json -Compress)" -ForegroundColor Gray
    Write-Host "    Test: $($testBySubCatType | ConvertTo-Json -Compress)" -ForegroundColor Gray
    if ($realBySubCatType.ValueType -ne $testBySubCatType.ValueType) {
        Write-Host "    MISMATCH in value type!" -ForegroundColor Red
        $differences += "DailyTrend.BySubscription.ByCategory: Type mismatch - Real: $($realBySubCatType.ValueType), Test: $($testBySubCatType.ValueType)"
    }
}

Write-Host "`n--- DailyTrend.ByMeter Structure ---" -ForegroundColor Yellow
if ($realMinimal.DailyTrend_Structure.ByMeter -and $testMinimal.DailyTrend_Structure.ByMeter) {
    $byMeterPropsDiff = Compare-Arrays -Name "ByMeter Properties" `
        -Real $realMinimal.DailyTrend_Structure.ByMeter.Properties `
        -Test $testMinimal.DailyTrend_Structure.ByMeter.Properties
    if ($byMeterPropsDiff) {
        if ($byMeterPropsDiff.OnlyInReal) {
            Write-Host "  Properties only in REAL: $($byMeterPropsDiff.OnlyInReal -join ', ')" -ForegroundColor Red
            $differences += "DailyTrend.ByMeter: Missing properties: $($byMeterPropsDiff.OnlyInReal -join ', ')"
        }
        if ($byMeterPropsDiff.OnlyInTest) {
            Write-Host "  Properties only in TEST: $($byMeterPropsDiff.OnlyInTest -join ', ')" -ForegroundColor Magenta
        }
    } else {
        Write-Host "  OK - Properties match" -ForegroundColor Green
    }
}

Write-Host "`n--- DailyTrend.ByResource Structure ---" -ForegroundColor Yellow
if ($realMinimal.DailyTrend_Structure.ByResource -and $testMinimal.DailyTrend_Structure.ByResource) {
    $byResPropsDiff = Compare-Arrays -Name "ByResource Properties" `
        -Real $realMinimal.DailyTrend_Structure.ByResource.Properties `
        -Test $testMinimal.DailyTrend_Structure.ByResource.Properties
    if ($byResPropsDiff) {
        if ($byResPropsDiff.OnlyInReal) {
            Write-Host "  Properties only in REAL: $($byResPropsDiff.OnlyInReal -join ', ')" -ForegroundColor Red
            $differences += "DailyTrend.ByResource: Missing properties: $($byResPropsDiff.OnlyInReal -join ', ')"
        }
        if ($byResPropsDiff.OnlyInTest) {
            Write-Host "  Properties only in TEST: $($byResPropsDiff.OnlyInTest -join ', ')" -ForegroundColor Magenta
        }
    } else {
        Write-Host "  OK - Properties match" -ForegroundColor Green
    }
}

# Summary
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
if ($differences.Count -eq 0) {
    Write-Host "No structural differences found!" -ForegroundColor Green
} else {
    Write-Host "Found $($differences.Count) difference(s):" -ForegroundColor Red
    $differences | ForEach-Object {
        Write-Host "  - $_" -ForegroundColor Yellow
    }

    # Save differences to file
    $diffPath = Join-Path $TestDataPath "structure-differences.txt"
    $differences | Out-File -FilePath $diffPath -Encoding UTF8
    Write-Host "`nDifferences saved to: $diffPath" -ForegroundColor Gray
}

Write-Host "`nFor detailed comparison, examine:" -ForegroundColor Gray
Write-Host "  Real: $realSamplesPath" -ForegroundColor White
Write-Host "  Test: $testSamplesPath" -ForegroundColor White
