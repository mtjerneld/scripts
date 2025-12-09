# Test-SubscriptionAccess.ps1
# Run this after Connect-AuditEnvironment to diagnose subscription access issues

Write-Host ""
Write-Host "=== Subscription Access Diagnostic ===" -ForegroundColor Cyan

# Get current context
$currentContext = Get-AzContext
if (-not $currentContext) {
    Write-Host "ERROR: Not connected to Azure. Run Connect-AuditEnvironment first." -ForegroundColor Red
    return
}

Write-Host "Current Tenant: $($currentContext.Tenant.Id)" -ForegroundColor Gray
Write-Host ""

# Get subscriptions
$subs = Get-AzSubscription -TenantId $currentContext.Tenant.Id | Where-Object { $_.State -eq 'Enabled' }

Write-Host "Found $($subs.Count) enabled subscription(s)" -ForegroundColor Yellow
Write-Host ""

$accessibleCount = 0
$inaccessibleCount = 0

foreach ($sub in $subs) {
    Write-Host "--- $($sub.Name) ---" -ForegroundColor White
    Write-Host "  ID: $($sub.Id)" -ForegroundColor Gray
    Write-Host "  Name property empty: $([string]::IsNullOrWhiteSpace($sub.Name))" -ForegroundColor Gray
    
    try {
        $ctx = Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop -WarningAction SilentlyContinue
        
        if ($ctx.Subscription.Id -ne $sub.Id) {
            Write-Host "  Context switch: FAILED (context mismatch)" -ForegroundColor Red
            $inaccessibleCount++
            continue
        }
        
        Write-Host "  Context switch: OK" -ForegroundColor Green
        
        # Try to list resources
        try {
            $resources = Get-AzResource -ErrorAction Stop
            $resourceCount = if ($resources) { @($resources).Count } else { 0 }
            Write-Host "  Resources found: $resourceCount" -ForegroundColor $(if ($resourceCount -gt 0) { 'Green' } else { 'Yellow' })
            $accessibleCount++
        }
        catch {
            if ($_.Exception.Message -match 'AuthorizationFailed|Forbidden|does not have authorization') {
                Write-Host "  Resources: NO READ PERMISSION" -ForegroundColor Red
                Write-Host "    You need Reader role on this subscription" -ForegroundColor Yellow
                $inaccessibleCount++
            }
            else {
                Write-Host "  Resources: ERROR - $($_.Exception.Message)" -ForegroundColor Red
                $inaccessibleCount++
            }
        }
    }
    catch {
        Write-Host "  Context switch: FAILED" -ForegroundColor Red
        Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Yellow
        $inaccessibleCount++
    }
    Write-Host ""
}

Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "Accessible subscriptions: $accessibleCount" -ForegroundColor Green
Write-Host "Inaccessible subscriptions: $inaccessibleCount" -ForegroundColor $(if ($inaccessibleCount -gt 0) { 'Red' } else { 'Green' })

if ($inaccessibleCount -gt 0) {
    Write-Host ""
    Write-Host "To fix permission issues:" -ForegroundColor Yellow
    Write-Host "  1. Ask an Azure admin to grant you 'Reader' role on the subscriptions" -ForegroundColor White
    Write-Host "  2. Or run the audit only on specific subscriptions:" -ForegroundColor White
    Write-Host "     Invoke-AzureSecurityAudit -SubscriptionIds 'sub-id-1', 'sub-id-2'" -ForegroundColor Gray
}


