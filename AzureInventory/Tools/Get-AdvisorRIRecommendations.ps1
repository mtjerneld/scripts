# Get Azure Advisor Reserved Instance recommendations
# CORRECTED - Shows recommendations as alternatives, not additive

param(
    [Parameter(Mandatory=$false)]
    [string]$TenantId,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('7','30','60')]
    [string]$PreferredLookback = '60'
)

$context = Get-AzContext
if (-not $context) {
    Write-Error "Not connected to Azure. Run Connect-AzAccount first."
    exit
}

if (-not $TenantId) {
    $TenantId = $context.Tenant.Id
    Write-Host "Using current tenant: $TenantId" -ForegroundColor Cyan
} else {
    Write-Host "Using specified tenant: $TenantId" -ForegroundColor Cyan
    Connect-AzAccount -TenantId $TenantId -WarningAction SilentlyContinue | Out-Null
    $context = Get-AzContext
}

Write-Host "Account: $($context.Account.Id)" -ForegroundColor Green
Write-Host "Preferred lookback: $PreferredLookback days" -ForegroundColor Cyan
Write-Host ""

Write-Host "Retrieving subscriptions..." -ForegroundColor Cyan
$subscriptions = Get-AzSubscription -TenantId $TenantId | 
    Where-Object { 
        $_.State -eq 'Enabled' -and 
        $_.TenantId -eq $TenantId
    }

if ($subscriptions.Count -eq 0) {
    Write-Error "No enabled subscriptions found in tenant $TenantId"
    exit
}

Write-Host "Found $($subscriptions.Count) enabled subscriptions" -ForegroundColor Green
Write-Host ""

$allRecommendations = @()
$startTime = Get-Date

foreach ($sub in $subscriptions) {
    $subIndex = [array]::IndexOf($subscriptions, $sub) + 1
    Write-Host "[$subIndex/$($subscriptions.Count)] Scanning: $($sub.Name)" -ForegroundColor Cyan
    
    try {
        Set-AzContext -SubscriptionId $sub.Id -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
        
        $recommendations = Get-AzAdvisorRecommendation -WarningAction SilentlyContinue -ErrorAction Stop | 
            Where-Object { 
                $_.Category -eq 'Cost' -and 
                $_.ShortDescriptionSolution -like "*reserved instance*" 
            }
        
        Write-Host "  Found $($recommendations.Count) RI recommendations" -ForegroundColor Gray
        
        foreach ($rec in $recommendations) {
            $extProps = $null
            if ($rec.ExtendedProperty) {
                try {
                    $extProps = $rec.ExtendedProperty | ConvertFrom-Json
                } catch {
                    Write-Warning "  Could not parse ExtendedProperty for recommendation $($rec.Name)"
                }
            }
            
            if ($extProps) {
                $annualSavings = 0
                if ($extProps.annualSavingsAmount) {
                    $annualSavings = [decimal]$extProps.annualSavingsAmount
                }
                
                $allRecommendations += [PSCustomObject]@{
                    TenantId = $TenantId
                    SubscriptionName = $sub.Name
                    SubscriptionId = $sub.Id
                    ImpactedResource = $rec.ImpactedValue
                    Impact = $rec.Impact
                    Description = $rec.ShortDescriptionSolution
                    VMSize = $extProps.vmSize
                    Term = $extProps.term
                    Lookback = $extProps.lookbackPeriod
                    Region = $extProps.location
                    Scope = $extProps.scope
                    AnnualSavings = $annualSavings
                    MonthlySavings = [math]::Round($annualSavings / 12, 2)
                    Currency = $extProps.savingsCurrency
                    Quantity = $extProps.targetResourceCount
                    LastUpdated = $rec.LastUpdated
                    RecommendationId = $rec.Name
                }
            }
        }
    }
    catch {
        Write-Warning "  Error: $($_.Exception.Message)"
    }
}

$endTime = Get-Date
$duration = ($endTime - $startTime).TotalSeconds

Write-Host ""
Write-Host "=== RESULTS ===" -ForegroundColor Green
Write-Host "Scan completed in $([math]::Round($duration, 1)) seconds" -ForegroundColor Gray
Write-Host ""

if ($allRecommendations.Count -gt 0) {
    # Export ALL recommendations
    $tenantShort = $TenantId.Substring(0,8)
    $outputFile = "AdvisorRI_${tenantShort}_ALL_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $allRecommendations | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
    Write-Host "Exported ALL recommendations ($($allRecommendations.Count)) to: $outputFile" -ForegroundColor Gray
    Write-Host ""
    
    # Filter to preferred lookback for analysis
    $preferred = $allRecommendations | Where-Object { $_.Lookback -eq $PreferredLookback }
    
    if ($preferred.Count -eq 0) {
        Write-Host "No recommendations with $PreferredLookback day lookback. Using all data." -ForegroundColor Yellow
        $preferred = $allRecommendations
    }
    
    Write-Host "=== ACTIONABLE RECOMMENDATIONS ($PreferredLookback-day lookback) ===" -ForegroundColor Cyan
    Write-Host ""
    
    # Group by Subscription + VMSize to show alternatives
    $grouped = $preferred | Group-Object SubscriptionName, VMSize | Sort-Object Name
    
    $totalP1Y = 0
    $totalP3Y = 0
    
    foreach ($group in $grouped) {
        $parts = $group.Name -split ', '
        $subName = $parts[0]
        $vmSize = $parts[1]
        
        Write-Host "$subName - $vmSize" -ForegroundColor Yellow
        
        # Show P1Y option
        $p1y = $group.Group | Where-Object { $_.Term -eq 'P1Y' } | Select-Object -First 1
        if ($p1y) {
            Write-Host "  1 Year:  $($p1y.AnnualSavings) $($p1y.Currency)/year (qty: $($p1y.Quantity))" -ForegroundColor Green
            $totalP1Y += $p1y.AnnualSavings
        }
        
        # Show P3Y option
        $p3y = $group.Group | Where-Object { $_.Term -eq 'P3Y' } | Select-Object -First 1
        if ($p3y) {
            Write-Host "  3 Years: $($p3y.AnnualSavings) $($p3y.Currency)/year (qty: $($p3y.Quantity))" -ForegroundColor Cyan
            $totalP3Y += $p3y.AnnualSavings
        }
        
        Write-Host ""
    }
    
    Write-Host "=== TOTAL POTENTIAL SAVINGS ($PreferredLookback-day lookback) ===" -ForegroundColor Green
    $currency = $preferred[0].Currency
    Write-Host "If choosing 1-year terms:  $([math]::Round($totalP1Y, 2)) $currency/year" -ForegroundColor Green
    Write-Host "If choosing 3-year terms:  $([math]::Round($totalP3Y, 2)) $currency/year" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "NOTE: These are ALTERNATIVES - you choose either 1Y or 3Y per VM size, not both." -ForegroundColor Yellow
    
    Write-Host ""
    Write-Host "=== BREAKDOWN BY SUBSCRIPTION ($PreferredLookback-day, P1Y) ===" -ForegroundColor Cyan
    $p1yBreakdown = $preferred | Where-Object { $_.Term -eq 'P1Y' } | 
        Group-Object SubscriptionName | 
        Sort-Object Name
    
    if ($p1yBreakdown) {
        $p1yBreakdown | ForEach-Object {
            $savings = ($_.Group | Measure-Object -Property AnnualSavings -Sum).Sum
            Write-Host "  $($_.Name): $([math]::Round($savings, 2)) $currency/year" -ForegroundColor Gray
        }
    } else {
        Write-Host "  (No P1Y recommendations found)" -ForegroundColor Gray
    }
    
    Write-Host ""
    Write-Host "=== BREAKDOWN BY SUBSCRIPTION ($PreferredLookback-day, P3Y) ===" -ForegroundColor Cyan
    $p3yBreakdown = $preferred | Where-Object { $_.Term -eq 'P3Y' } | 
        Group-Object SubscriptionName | 
        Sort-Object Name
    
    if ($p3yBreakdown) {
        $p3yBreakdown | ForEach-Object {
            $savings = ($_.Group | Measure-Object -Property AnnualSavings -Sum).Sum
            Write-Host "  $($_.Name): $([math]::Round($savings, 2)) $currency/year" -ForegroundColor Gray
        }
    } else {
        Write-Host "  (No P3Y recommendations found)" -ForegroundColor Gray
    }
    
    Write-Host ""
    Write-Host "=== TOP 5 OPPORTUNITIES (P1Y, $PreferredLookback-day) ===" -ForegroundColor Cyan
    $top5P1Y = $preferred | 
        Where-Object { $_.Term -eq 'P1Y' } |
        Sort-Object -Property AnnualSavings -Descending |
        Select-Object -First 5
    
    if ($top5P1Y) {
        $top5P1Y | Format-Table SubscriptionName, VMSize, Quantity, AnnualSavings, Currency -AutoSize
    } else {
        Write-Host "  (No P1Y recommendations found)" -ForegroundColor Gray
    }
    
    Write-Host ""
    Write-Host "=== TOP 5 OPPORTUNITIES (P3Y, $PreferredLookback-day) ===" -ForegroundColor Cyan
    $top5P3Y = $preferred | 
        Where-Object { $_.Term -eq 'P3Y' } |
        Sort-Object -Property AnnualSavings -Descending |
        Select-Object -First 5
    
    if ($top5P3Y) {
        $top5P3Y | Format-Table SubscriptionName, VMSize, Quantity, AnnualSavings, Currency -AutoSize
    } else {
        Write-Host "  (No P3Y recommendations found)" -ForegroundColor Gray
    }
    
    Write-Host ""
    Write-Host "=== CONFIDENCE COMPARISON ===" -ForegroundColor Cyan
    Write-Host "Shows how stable recommendations are across lookback periods:"
    Write-Host ""
    
    # Group by Subscription + VMSize + Term
    $allRecommendations | 
        Group-Object SubscriptionName, VMSize, Term |
        Select-Object -First 3 |
        ForEach-Object {
            $parts = $_.Name -split ', '
            Write-Host "$($parts[0]) - $($parts[1]) - $($parts[2])" -ForegroundColor Yellow
            $_.Group | 
                Sort-Object Lookback |
                ForEach-Object {
                    Write-Host "  $($_.Lookback) days: $($_.AnnualSavings) $($_.Currency)/year"
                }
            Write-Host ""
        }
    
} else {
    Write-Host "No Reserved Instance recommendations found." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "TIP: Run with -PreferredLookback 30 or -PreferredLookback 7 to see different confidence levels" -ForegroundColor Cyan