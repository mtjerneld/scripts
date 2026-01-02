<#
.SYNOPSIS
    Captures real cost data and saves it for test data comparison.

.DESCRIPTION
    Runs the real cost data collection and saves:
    1. Full data structure as JSON (for detailed comparison)
    2. Schema/structure analysis (showing keys and types without values)
    3. Sample entries from each section

.PARAMETER OutputPath
    Directory to save the captured data. Default: ./test-output/real-data-sample

.PARAMETER DaysToInclude
    Number of days to collect. Default: 7 (smaller for faster collection)

.EXAMPLE
    .\Save-RealCostDataSample.ps1
    .\Save-RealCostDataSample.ps1 -DaysToInclude 14 -OutputPath "./my-samples"
#>
[CmdletBinding()]
param(
    [string]$OutputPath = "./test-output/real-data-sample",
    [int]$DaysToInclude = 7
)

# Import the module
$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module "$moduleRoot\AzureSecurityAudit.psd1" -Force

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Host "`n=== Capturing Real Cost Data Sample ===" -ForegroundColor Cyan
Write-Host "Output: $OutputPath" -ForegroundColor Gray
Write-Host "Days: $DaysToInclude" -ForegroundColor Gray

# Check Azure connection
$context = Get-AzContext
if (-not $context) {
    Write-Host "`nNot connected to Azure. Running Connect-AuditEnvironment..." -ForegroundColor Yellow
    Connect-AuditEnvironment
    $context = Get-AzContext
}

if (-not $context) {
    Write-Error "Failed to connect to Azure. Please run Connect-AuditEnvironment first."
    exit 1
}

Write-Host "`nConnected as: $($context.Account.Id)" -ForegroundColor Green
Write-Host "Tenant: $($context.Tenant.Id)" -ForegroundColor Gray

# Get subscriptions
Write-Host "`nGetting subscriptions..." -ForegroundColor Gray
$subscriptions = Get-AzSubscription -TenantId $context.Tenant.Id | Where-Object { $_.State -eq 'Enabled' }
Write-Host "Found $($subscriptions.Count) enabled subscriptions" -ForegroundColor Green

# Collect cost data
Write-Host "`nCollecting cost data (this may take a few minutes)..." -ForegroundColor Yellow
$costData = Collect-CostData -Subscriptions $subscriptions -DaysToInclude $DaysToInclude

if (-not $costData) {
    Write-Error "Failed to collect cost data"
    exit 1
}

Write-Host "`nCost data collected successfully!" -ForegroundColor Green

# Save full data as JSON (with depth for nested structures)
$fullDataPath = Join-Path $OutputPath "cost-data-full.json"
Write-Host "`nSaving full data to: $fullDataPath" -ForegroundColor Gray
$costData | ConvertTo-Json -Depth 10 | Out-File -FilePath $fullDataPath -Encoding UTF8
Write-Host "  Size: $([math]::Round((Get-Item $fullDataPath).Length / 1KB, 2)) KB" -ForegroundColor Gray

# Create structure analysis
function Get-ObjectStructure {
    param($Object, $Depth = 0, $MaxDepth = 5, $MaxItems = 3)

    if ($Depth -gt $MaxDepth) { return "[MAX DEPTH]" }

    if ($null -eq $Object) { return "null" }

    $type = $Object.GetType()

    if ($Object -is [string]) { return "string: `"$($Object.Substring(0, [Math]::Min(50, $Object.Length)))...`"" }
    if ($Object -is [int] -or $Object -is [long]) { return "int: $Object" }
    if ($Object -is [decimal] -or $Object -is [double] -or $Object -is [float]) { return "decimal: $Object" }
    if ($Object -is [bool]) { return "bool: $Object" }
    if ($Object -is [DateTime]) { return "DateTime: $($Object.ToString('yyyy-MM-dd HH:mm:ss'))" }

    if ($Object -is [System.Collections.IList]) {
        $result = @{
            "_type" = "Array[$($Object.Count) items]"
            "_samples" = @()
        }
        $count = 0
        foreach ($item in $Object) {
            if ($count -ge $MaxItems) {
                $result._samples += "[... $($Object.Count - $count) more items]"
                break
            }
            $result._samples += Get-ObjectStructure -Object $item -Depth ($Depth + 1) -MaxDepth $MaxDepth -MaxItems $MaxItems
            $count++
        }
        return $result
    }

    if ($Object -is [hashtable] -or $Object -is [System.Collections.IDictionary]) {
        $result = @{ "_type" = "Hashtable[$($Object.Count) keys]" }
        $count = 0
        foreach ($key in $Object.Keys) {
            if ($count -ge $MaxItems -and $Object.Count -gt $MaxItems) {
                $result["_remaining"] = "$($Object.Count - $count) more keys: $(($Object.Keys | Select-Object -Skip $count | Select-Object -First 10) -join ', ')..."
                break
            }
            $result[$key] = Get-ObjectStructure -Object $Object[$key] -Depth ($Depth + 1) -MaxDepth $MaxDepth -MaxItems $MaxItems
            $count++
        }
        return $result
    }

    if ($Object -is [PSCustomObject]) {
        $result = @{ "_type" = "PSCustomObject" }
        $props = $Object.PSObject.Properties
        $count = 0
        foreach ($prop in $props) {
            if ($count -ge $MaxItems -and $props.Count -gt $MaxItems) {
                $result["_remaining"] = "$($props.Count - $count) more properties"
                break
            }
            $result[$prop.Name] = Get-ObjectStructure -Object $prop.Value -Depth ($Depth + 1) -MaxDepth $MaxDepth -MaxItems $MaxItems
            $count++
        }
        return $result
    }

    return "[$($type.Name)]: $Object"
}

Write-Host "`nAnalyzing structure..." -ForegroundColor Gray
$structure = Get-ObjectStructure -Object $costData -MaxDepth 6 -MaxItems 2

$structurePath = Join-Path $OutputPath "cost-data-structure.json"
$structure | ConvertTo-Json -Depth 15 | Out-File -FilePath $structurePath -Encoding UTF8
Write-Host "Structure saved to: $structurePath" -ForegroundColor Gray

# Save specific samples for easy comparison
$samples = @{
    "_description" = "Sample entries from real cost data for comparison with test data"
    "_generatedAt" = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    # Top-level keys
    "TopLevelKeys" = @($costData.Keys | Sort-Object)

    # BySubscription sample (first entry)
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

    # DailyTrend sample (first day)
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

# Create a comparison-ready minimal version
$minimal = @{
    "_description" = "Minimal real data for direct comparison"

    # Just the structure, no actual cost values
    "BySubscription_Structure" = @{}
    "DailyTrend_Structure" = @{}
}

# Get first BySubscription entry structure
if ($costData.BySubscription.Count -gt 0) {
    $firstSubKey = $costData.BySubscription.Keys | Select-Object -First 1
    $firstSub = $costData.BySubscription[$firstSubKey]
    $minimal.BySubscription_Structure = @{
        "KeyExample" = $firstSubKey
        "KeyType" = $firstSubKey.GetType().Name
        "Properties" = @($firstSub.Keys | Sort-Object)
    }
}

# Get first DailyTrend entry structure
if ($costData.DailyTrend.Count -gt 0) {
    $firstDay = $costData.DailyTrend[0]
    $minimal.DailyTrend_Structure = @{
        "TopLevelProperties" = @($firstDay.Keys | Sort-Object)
    }

    # ByCategory structure
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

    # BySubscription structure
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

    # ByMeter structure
    if ($firstDay.ByMeter.Count -gt 0) {
        $firstMeterKey = $firstDay.ByMeter.Keys | Select-Object -First 1
        $firstMeter = $firstDay.ByMeter[$firstMeterKey]
        $minimal.DailyTrend_Structure["ByMeter"] = @{
            "KeyExample" = $firstMeterKey
            "Properties" = @($firstMeter.Keys | Sort-Object)
        }
    }

    # ByResource structure
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
Write-Host "Files created:" -ForegroundColor Cyan
Write-Host "  1. cost-data-full.json - Complete data (for detailed inspection)" -ForegroundColor White
Write-Host "  2. cost-data-structure.json - Structure analysis with types" -ForegroundColor White
Write-Host "  3. cost-data-samples.json - Sample entries for comparison" -ForegroundColor White
Write-Host "  4. cost-data-minimal-structure.json - Minimal structure for quick comparison" -ForegroundColor White
Write-Host "`nCompare these with test data to identify structural differences." -ForegroundColor Yellow
