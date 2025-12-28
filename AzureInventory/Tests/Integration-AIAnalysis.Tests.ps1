<#
.SYNOPSIS
    Integration test for AI analysis workflow.

.DESCRIPTION
    Tests the complete AI analysis workflow with mock data.
    Use -UseRealAPI to test with actual OpenAI API (will incur cost).
#>

param(
    [switch]$UseRealAPI,
    [string]$OutputPath = "$PSScriptRoot\..\TestOutputs"
)

Describe "AI Analysis Integration Tests" {
    BeforeAll {
        $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        
        # Import all required functions
        . (Join-Path $moduleRoot "Private\Helpers\ConvertTo-CostAIInsights.ps1")
        . (Join-Path $moduleRoot "Private\Helpers\ConvertTo-SecurityAIInsights.ps1")
        . (Join-Path $moduleRoot "Private\Helpers\ConvertTo-CombinedPayload.ps1")
        . (Join-Path $moduleRoot "Private\Helpers\Get-ImplementationComplexity.ps1")
        . (Join-Path $moduleRoot "Private\Helpers\Get-RemediationEffort.ps1")
        
        if ($UseRealAPI) {
            . (Join-Path $moduleRoot "Private\Helpers\Invoke-OpenAIAnalysis.ps1")
            . (Join-Path $moduleRoot "Private\Helpers\ConvertFrom-OpenAIResponseJson.ps1")
            . (Join-Path $moduleRoot "Public\Invoke-AzureArchitectAgent.ps1")
        }
        
        if (-not (Test-Path $OutputPath)) {
            New-Item -Path $OutputPath -ItemType Directory | Out-Null
        }
    }
    
    Context "Data Conversion" {
        It "Should convert cost data to insights" {
            $mockCostRecs = @(
                [PSCustomObject]@{
                    SubscriptionName = "Test-Sub"
                    Category = "Cost"
                    PotentialSavings = 5000
                    Impact = "High"
                    Problem = "Test problem"
                    Solution = "Test solution"
                    ResourceName = "test-resource"
                }
            )
            
            $insights = ConvertTo-CostAIInsights -AdvisorRecommendations $mockCostRecs
            $insights.summary.total_potential_savings_annual | Should -Be 5000
        }
        
        It "Should convert security data to insights" {
            $mockFindings = @(
                [PSCustomObject]@{
                    SubscriptionName = "Test-Sub"
                    ControlId = "3.6"
                    ControlName = "Test Control"
                    Severity = "Critical"
                    Status = "FAIL"
                    ResourceName = "test-resource"
                    ResourceType = "Microsoft.Network/networkSecurityGroups"
                    RemediationSteps = "Fix it"
                    CurrentValue = "Bad"
                    ExpectedValue = "Good"
                }
            )
            
            $insights = ConvertTo-SecurityAIInsights -Findings $mockFindings
            $insights.summary.critical_count | Should -Be 1
        }
        
        It "Should combine insights into payload" {
            $costInsights = @{
                domain = "cost_optimization"
                summary = @{ recommendation_count = 5 }
            }
            $secInsights = @{
                domain = "security_compliance"
                summary = @{ total_findings = 10 }
            }
            
            $payload = ConvertTo-CombinedPayload -CostInsights $costInsights -SecurityInsights $secInsights -SubscriptionCount 3
            
            $payload.cost_optimization | Should -Not -BeNullOrEmpty
            $payload.security_compliance | Should -Not -BeNullOrEmpty
            $payload.report_metadata.modules_analyzed.Count | Should -Be 2
        }
    }
    
    Context "AI Agent Call" {
        It "Should call AI agent with real API if UseRealAPI is set" -Skip:(!$UseRealAPI) {
            if ([string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
                Write-Warning "OPENAI_API_KEY not set. Skipping real API test."
                return
            }
            
            $mockPayload = @{
                report_metadata = @{
                    generated_at = (Get-Date).ToString("o")
                    subscription_count = 1
                    modules_analyzed = @("cost_optimization")
                }
                cost_optimization = @{
                    summary = @{
                        total_potential_savings_annual = 1000
                        recommendation_count = 1
                    }
                }
            }
            
            $json = $mockPayload | ConvertTo-Json -Depth 10
            
            $result = Invoke-AzureArchitectAgent `
                -GovernanceDataJson $json `
                -ApiKey $env:OPENAI_API_KEY `
                -OutputPath $OutputPath
            
            $result.Success | Should -Be $true
            $result.Analysis | Should -Not -BeNullOrEmpty
        }
    }
}

