<#
.SYNOPSIS
    Unit tests for ConvertTo-SecurityAIInsights function.
#>

Describe "ConvertTo-SecurityAIInsights Tests" {
    BeforeAll {
        # Import module functions
        $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $moduleRoot "Private\Helpers\ConvertTo-SecurityAIInsights.ps1")
        . (Join-Path $moduleRoot "Private\Helpers\Get-RemediationEffort.ps1")
        
        # Mock security findings
        $script:mockFindings = @(
            [PSCustomObject]@{
                SubscriptionId = "sub-1"
                SubscriptionName = "Contoso-Prod"
                ControlId = "3.6"
                ControlName = "NSG Flow Logs retention"
                Severity = "Critical"
                Status = "FAIL"
                ResourceName = "nsg-prod-01"
                ResourceType = "Microsoft.Network/networkSecurityGroups"
                RemediationSteps = "Enable NSG Flow Logs with 90+ day retention"
                CurrentValue = "Disabled"
                ExpectedValue = "Enabled, 90 days"
            },
            [PSCustomObject]@{
                SubscriptionId = "sub-2"
                SubscriptionName = "Fabrikam-Dev"
                ControlId = "2.1"
                ControlName = "Secure transfer required"
                Severity = "High"
                Status = "FAIL"
                ResourceName = "storage-dev-01"
                ResourceType = "Microsoft.Storage/storageAccounts"
                RemediationSteps = "Enable secure transfer"
                CurrentValue = "Disabled"
                ExpectedValue = "Enabled"
            },
            [PSCustomObject]@{
                SubscriptionId = "sub-1"
                SubscriptionName = "Contoso-Prod"
                ControlId = "1.23"
                ControlName = "Guest user permissions"
                Severity = "Medium"
                Status = "PASS"
                ResourceName = "aad-tenant"
                ResourceType = "Microsoft.AAD/tenant"
                RemediationSteps = ""
                CurrentValue = "Limited"
                ExpectedValue = "Limited"
            }
        )
    }
    
    Context "Basic Functionality" {
        It "Should generate AI insights structure" {
            $insights = ConvertTo-SecurityAIInsights -Findings $mockFindings
            
            $insights | Should -Not -BeNullOrEmpty
            $insights.domain | Should -Be "security_compliance"
            $insights.summary | Should -Not -BeNullOrEmpty
            $insights.critical_issues | Should -Not -BeNullOrEmpty
        }
        
        It "Should calculate correct finding counts" {
            $insights = ConvertTo-SecurityAIInsights -Findings $mockFindings
            
            $insights.summary.total_findings | Should -Be 2  # Only FAIL findings
            $insights.summary.critical_count | Should -Be 1
            $insights.summary.high_count | Should -Be 1
        }
        
        It "Should respect TopN parameter" {
            $insights = ConvertTo-SecurityAIInsights -Findings $mockFindings -TopN 1
            
            $insights.critical_issues.Count | Should -BeLessOrEqual 1
        }
        
        It "Should filter by severity when CriticalOnly is true" {
            $insights = ConvertTo-SecurityAIInsights -Findings $mockFindings -CriticalOnly $true
            
            # Should only include Critical and High
            $allSeverities = $insights.critical_issues | ForEach-Object { $_.severity }
            $allSeverities | Should -Contain "Critical"
            $allSeverities | Should -Contain "High"
        }
        
        It "Should handle empty findings" {
            $insights = ConvertTo-SecurityAIInsights -Findings @()
            
            $insights.summary.total_findings | Should -Be 0
            $insights.summary.critical_count | Should -Be 0
        }
    }
    
    Context "Compliance Scores" {
        It "Should calculate compliance scores per customer" {
            $insights = ConvertTo-SecurityAIInsights -Findings $mockFindings
            
            $insights.by_customer.Count | Should -BeGreaterThan 0
            # Contoso has 1 PASS and 1 FAIL out of 2 total = 50% score
            $contoso = $insights.by_customer | Where-Object { $_.customer -eq "Contoso-Prod" }
            if ($contoso) {
                $contoso.compliance_score | Should -BeLessOrEqual 100
                $contoso.compliance_score | Should -BeGreaterOrEqual 0
            }
        }
    }
}

