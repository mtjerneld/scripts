<#
.SYNOPSIS
    Unit tests for ConvertTo-CostAIInsights function.
#>

Describe "ConvertTo-CostAIInsights Tests" {
    BeforeAll {
        # Import module functions
        $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $moduleRoot "Private\Helpers\ConvertTo-CostAIInsights.ps1")
        . (Join-Path $moduleRoot "Private\Helpers\Get-ImplementationComplexity.ps1")
        
        # Mock recommendation data
        $script:mockRecommendations = @(
            [PSCustomObject]@{
                SubscriptionId = "sub-1"
                SubscriptionName = "Contoso-Prod"
                Category = "Cost"
                Impact = "High"
                PotentialSavings = 12000
                MonthlySavings = 1000
                SavingsCurrency = "USD"
                Problem = "VM oversized"
                Solution = "Right-size to D4s v5"
                ResourceName = "vm-prod-01"
                TechnicalDetails = "Current: D16s_v5, Recommended: D8s_v5"
            },
            [PSCustomObject]@{
                SubscriptionId = "sub-2"
                SubscriptionName = "Fabrikam-Dev"
                Category = "Cost"
                Impact = "Medium"
                PotentialSavings = 3600
                MonthlySavings = 300
                SavingsCurrency = "USD"
                Problem = "VM unused"
                Solution = "Shutdown or delete"
                ResourceName = "vm-dev-02"
                TechnicalDetails = "Idle for 30 days"
            }
        )
    }
    
    Context "Basic Functionality" {
        It "Should generate AI insights structure" {
            $insights = ConvertTo-CostAIInsights -AdvisorRecommendations $mockRecommendations
            
            $insights | Should -Not -BeNullOrEmpty
            $insights.domain | Should -Be "cost_optimization"
            $insights.summary | Should -Not -BeNullOrEmpty
            $insights.top_opportunities | Should -Not -BeNullOrEmpty
        }
        
        It "Should calculate correct total savings" {
            $insights = ConvertTo-CostAIInsights -AdvisorRecommendations $mockRecommendations
            
            $insights.summary.total_potential_savings_annual | Should -Be 15600
            $insights.summary.total_potential_savings_monthly | Should -Be 1300
        }
        
        It "Should respect TopN parameter" {
            $insights = ConvertTo-CostAIInsights -AdvisorRecommendations $mockRecommendations -TopN 1
            
            $insights.top_opportunities.Count | Should -Be 1
            $insights.top_opportunities[0].annual_savings | Should -Be 12000
        }
        
        It "Should filter by minimum savings" {
            $insights = ConvertTo-CostAIInsights -AdvisorRecommendations $mockRecommendations -MinSavings 5000
            
            $insights.summary.recommendation_count | Should -Be 1
            $insights.summary.total_potential_savings_annual | Should -Be 12000
        }
        
        It "Should handle empty recommendations" {
            $insights = ConvertTo-CostAIInsights -AdvisorRecommendations @()
            
            $insights.summary.recommendation_count | Should -Be 0
            $insights.summary.total_potential_savings_annual | Should -Be 0
        }
    }
    
    Context "Grouping" {
        It "Should group by category correctly" {
            $insights = ConvertTo-CostAIInsights -AdvisorRecommendations $mockRecommendations
            
            $insights.by_category.Count | Should -BeGreaterThan 0
        }
        
        It "Should group by customer correctly" {
            $insights = ConvertTo-CostAIInsights -AdvisorRecommendations $mockRecommendations
            
            $insights.by_customer.Count | Should -BeGreaterThan 0
            $contoso = $insights.by_customer | Where-Object { $_.customer -eq "Contoso-Prod" }
            if ($contoso) {
                $contoso.total_potential_savings_annual | Should -Be 12000
            }
        }
    }
}

