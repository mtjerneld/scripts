# Debug Azure Advisor API Access
# Troubleshoots 401 Unauthorized errors

$context = Get-AzContext
if (-not $context) {
    Write-Error "Not connected to Azure. Run Connect-AzAccount first."
    exit
}

Write-Host "=== CONTEXT INFO ===" -ForegroundColor Cyan
Write-Host "Tenant: $($context.Tenant.Id)"
Write-Host "Account: $($context.Account.Id)"
Write-Host "Subscription: $($context.Subscription.Name)"
Write-Host "Subscription ID: $($context.Subscription.Id)"
Write-Host ""

# Test 1: Check role assignments
Write-Host "=== TEST 1: Role Assignments ===" -ForegroundColor Cyan
try {
    $roles = Get-AzRoleAssignment -SignInName $context.Account.Id -ErrorAction Stop |
        Where-Object { $_.Scope -like "*$($context.Subscription.Id)*" }
    
    if ($roles) {
        $roles | Select-Object RoleDefinitionName, Scope | Format-Table -AutoSize
    } else {
        Write-Host "No roles found for current subscription" -ForegroundColor Yellow
    }
} catch {
    Write-Warning "Could not retrieve role assignments: $($_.Exception.Message)"
}
Write-Host ""

# Test 2: Check Advisor resource provider registration
Write-Host "=== TEST 2: Advisor Resource Provider ===" -ForegroundColor Cyan
try {
    $advisorProvider = Get-AzResourceProvider -ProviderNamespace Microsoft.Advisor -ErrorAction Stop
    Write-Host "Registration State: $($advisorProvider.RegistrationState)" -ForegroundColor $(if($advisorProvider.RegistrationState -eq 'Registered'){'Green'}else{'Yellow'})
    
    if ($advisorProvider.RegistrationState -ne 'Registered') {
        Write-Host "TIP: Run 'Register-AzResourceProvider -ProviderNamespace Microsoft.Advisor'" -ForegroundColor Yellow
    }
} catch {
    Write-Warning "Could not check resource provider: $($_.Exception.Message)"
}
Write-Host ""

# Test 3: Get fresh token with explicit resource
Write-Host "=== TEST 3: Access Token Details ===" -ForegroundColor Cyan
try {
    $tokenInfo = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
    Write-Host "Token Type: $($tokenInfo.Type)"
    Write-Host "Token expires: $($tokenInfo.ExpiresOn)"
    Write-Host "User ID: $($tokenInfo.UserId)"
    
    # Decode token to see claims (basic info only)
    $token = $tokenInfo.Token
    Write-Host "Token length: $($token.Length) characters"
} catch {
    Write-Warning "Could not get token: $($_.Exception.Message)"
}
Write-Host ""

# Test 4: Try direct API call with detailed error
Write-Host "=== TEST 4: Direct API Call ===" -ForegroundColor Cyan
try {
    $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type' = 'application/json'
    }
    
    $subId = $context.Subscription.Id
    $uri = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.Advisor/recommendations?api-version=2020-01-01"
    
    Write-Host "Calling: $uri" -ForegroundColor Gray
    Write-Host ""
    
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
    
    Write-Host "SUCCESS! Found $($response.value.Count) total recommendations" -ForegroundColor Green
    
    # Count by category
    $byCat = $response.value | Group-Object { $_.properties.category }
    foreach ($cat in $byCat) {
        Write-Host "  $($cat.Name): $($cat.Count)" -ForegroundColor Gray
    }
    
} catch {
    Write-Host "FAILED with error:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    
    if ($_.Exception.Response) {
        Write-Host ""
        Write-Host "Response Status: $($_.Exception.Response.StatusCode)" -ForegroundColor Yellow
        Write-Host "Response Status Description: $($_.Exception.Response.StatusDescription)" -ForegroundColor Yellow
        
        try {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $reader.BaseStream.Position = 0
            $responseBody = $reader.ReadToEnd()
            Write-Host "Response Body:" -ForegroundColor Yellow
            Write-Host $responseBody -ForegroundColor Gray
        } catch {
            Write-Host "Could not read response body"
        }
    }
}
Write-Host ""

# Test 5: Try with cmdlet for comparison
Write-Host "=== TEST 5: Try Az Cmdlet ===" -ForegroundColor Cyan
try {
    $recommendations = Get-AzAdvisorRecommendation -ErrorAction Stop
    Write-Host "SUCCESS! Cmdlet found $($recommendations.Count) recommendations" -ForegroundColor Green
} catch {
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Test 6: Check if we can read basic resources
Write-Host "=== TEST 6: Basic Resource Read Test ===" -ForegroundColor Cyan
try {
    $rgs = Get-AzResourceGroup -ErrorAction Stop
    Write-Host "SUCCESS! Can read resource groups ($($rgs.Count) found)" -ForegroundColor Green
} catch {
    Write-Host "FAILED: Cannot read resource groups" -ForegroundColor Red
}
Write-Host ""

Write-Host "=== RECOMMENDATIONS ===" -ForegroundColor Cyan
Write-Host "If Test 4 failed with 401:"
Write-Host "1. Try: Disconnect-AzAccount; Connect-AzAccount -TenantId $($context.Tenant.Id)"
Write-Host "2. Verify Advisor RP is registered: Register-AzResourceProvider -ProviderNamespace Microsoft.Advisor"
Write-Host "3. Check if you need explicit 'Advisor Reader' role (not just 'Reader')"
Write-Host "4. Wait 5-10 minutes after role assignment changes"