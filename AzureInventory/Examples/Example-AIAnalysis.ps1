<#
.SYNOPSIS
    Example script demonstrating AI-powered Azure governance analysis.

.DESCRIPTION
    Shows how to use the AI analysis features of AzureSecurityAudit module
    to get intelligent recommendations and strategic insights.

.EXAMPLE
    .\Example-AIAnalysis.ps1
#>

# Prerequisites check
if (-not (Get-Module Az.Accounts -ListAvailable)) {
    Write-Error "Azure PowerShell module not found. Install with: Install-Module Az"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
    Write-Warning "OPENAI_API_KEY environment variable not set."
    Write-Host "Set it with: `$env:OPENAI_API_KEY = 'your-key'" -ForegroundColor Yellow
    Write-Host "Or pass it via -OpenAIKey parameter" -ForegroundColor Yellow
    Write-Host ""
    $useAI = Read-Host "Continue without AI analysis? (y/n)"
    if ($useAI -ne 'y') {
        exit 0
    }
}

# Configuration
$config = @{
    OutputPath = ".\Reports\AI_Analysis_$(Get-Date -Format 'yyyy-MM-dd')"
    OpenAIModel = "gpt-4o-mini"  # or "gpt-5-mini" for latest
    AICostTopN = 15               # Top cost opportunities
    AISecurityTopN = 20            # Top security findings
}

# Connect to Azure (if not already connected)
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Host "Connecting to Azure..." -ForegroundColor Cyan
        Connect-AzAccount
    }
    Write-Host "Connected to Azure as: $($context.Account.Id)" -ForegroundColor Green
}
catch {
    Write-Error "Failed to connect to Azure: $_"
    exit 1
}

# Get subscriptions (filter if needed)
Write-Host "`nGetting subscriptions..." -ForegroundColor Cyan
$subscriptions = Get-AzSubscription | Where-Object {
    # Optional: Filter to specific subscriptions
    # $_.Name -like "Prod-*" -or $_.Name -like "Dev-*"
    $true
}

Write-Host "Found $($subscriptions.Count) subscriptions" -ForegroundColor Green
Write-Host ""

# Run comprehensive analysis with AI
Write-Host "Starting comprehensive governance analysis with AI..." -ForegroundColor Cyan
Write-Host "This may take 5-10 minutes depending on portfolio size..." -ForegroundColor Gray
Write-Host ""

try {
    $params = @{
        SubscriptionIds = $subscriptions.Id
        OutputPath = $config.OutputPath
        ExportJson = $true
    }
    
    # Add AI parameters if API key is available
    if (-not [string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
        $params.AI = $true
        $params.OpenAIKey = $env:OPENAI_API_KEY
        $params.OpenAIModel = $config.OpenAIModel
        $params.AICostTopN = $config.AICostTopN
        $params.AISecurityTopN = $config.AISecurityTopN
        
        Write-Host "AI Analysis: Enabled" -ForegroundColor Green
        Write-Host "  Model: $($config.OpenAIModel)" -ForegroundColor Gray
        Write-Host "  Cost TopN: $($config.AICostTopN)" -ForegroundColor Gray
        Write-Host "  Security TopN: $($config.AISecurityTopN)" -ForegroundColor Gray
        Write-Host ""
    } else {
        Write-Host "AI Analysis: Disabled (no API key)" -ForegroundColor Yellow
        Write-Host ""
    }
    
    $result = Invoke-AzureSecurityAudit @params -PassThru
    
    # Display summary
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Analysis Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    
    Write-Host "Security Analysis:" -ForegroundColor White
    Write-Host "  Total Findings: $($result.Findings.Count)" -ForegroundColor Gray
    Write-Host "  Critical: $($result.FindingsBySeverity.Critical)" -ForegroundColor $(if ($result.FindingsBySeverity.Critical -gt 0) { 'Red' } else { 'Green' })
    Write-Host "  High: $($result.FindingsBySeverity.High)" -ForegroundColor $(if ($result.FindingsBySeverity.High -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host ""
    
    if ($result.AdvisorRecommendations) {
        $costRecs = $result.AdvisorRecommendations | Where-Object { $_.Category -eq 'Cost' }
        $totalSavings = ($costRecs | Where-Object { $_.PotentialSavings } | Measure-Object -Property PotentialSavings -Sum).Sum
        Write-Host "Cost Analysis:" -ForegroundColor White
        Write-Host "  Recommendations: $($costRecs.Count)" -ForegroundColor Gray
        if ($totalSavings -and $totalSavings -gt 0) {
            Write-Host "  Potential Savings: `$$([math]::Round($totalSavings, 0))/yr" -ForegroundColor Green
        }
        Write-Host ""
    }
    
    if ($result.AIAnalysis -and $result.AIAnalysis.Success) {
        Write-Host "AI Analysis:" -ForegroundColor White
        Write-Host "  Model: $($result.AIAnalysis.Metadata.Model)" -ForegroundColor Gray
        Write-Host "  Tokens: ~$($result.AIAnalysis.Metadata.TokenUsage.Input)" -ForegroundColor Gray
        Write-Host "  Estimated Cost: `$$($result.AIAnalysis.Metadata.EstimatedCost.ToString('F4'))" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  AI Analysis Report saved to output folder" -ForegroundColor Green
        Write-Host ""
        
        # Show preview of AI analysis
        if ($result.AIAnalysis.Analysis) {
            $preview = $result.AIAnalysis.Analysis.Substring(0, [Math]::Min(500, $result.AIAnalysis.Analysis.Length))
            Write-Host "AI Analysis Preview:" -ForegroundColor Cyan
            Write-Host "-------------------" -ForegroundColor Gray
            Write-Host $preview -ForegroundColor White
            if ($result.AIAnalysis.Analysis.Length -gt 500) {
                Write-Host "..." -ForegroundColor Gray
                Write-Host "(Full analysis saved to file)" -ForegroundColor Gray
            }
            Write-Host ""
        }
    }
    
    Write-Host "All reports saved to: $($config.OutputPath)" -ForegroundColor Green
    
    # Optionally open reports
    $openReports = Read-Host "Open dashboard in browser? (y/n)"
    if ($openReports -eq 'y') {
        $dashboardPath = Join-Path $config.OutputPath "index.html"
        if (Test-Path $dashboardPath) {
            Start-Process $dashboardPath
        }
    }
}
catch {
    Write-Error "Analysis failed: $_"
    Write-Error $_.ScriptStackTrace
    exit 1
}

