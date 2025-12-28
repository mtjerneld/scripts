<#
.SYNOPSIS
    Converts security analysis data into AI-ready JSON insights.

.DESCRIPTION
    Extracts and structures the most important security compliance insights
    for AI analysis, focusing on critical/high severity findings and
    compliance gaps.

.PARAMETER Findings
    Array of security finding objects (from security scanners).

.PARAMETER TopN
    Number of top findings to include (default: 20).

.PARAMETER CriticalOnly
    Include only Critical and High severity findings (default: true).

.EXAMPLE
    $insights = ConvertTo-SecurityAIInsights -Findings $allFindings -TopN 25
#>
function ConvertTo-SecurityAIInsights {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Findings,
        
        [Parameter(Mandatory = $false)]
        [int]$TopN = 20,
        
        [Parameter(Mandatory = $false)]
        [bool]$CriticalOnly = $true
    )
    
    Write-Verbose "Converting security data to AI insights (TopN: $TopN, CriticalOnly: $CriticalOnly)"
    
    # Filter to FAIL findings only (these are the issues)
    $failedFindings = @($Findings | Where-Object { $_.Status -eq 'FAIL' })
    
    if ($failedFindings.Count -eq 0) {
        Write-Verbose "No failed security findings found"
        return @{
            domain = "security_compliance"
            generated_at = (Get-Date).ToString("o")
            summary = @{
                total_findings = 0
                critical_count = 0
                high_count = 0
                medium_count = 0
                low_count = 0
                average_compliance_score = 100
                customers_below_80_percent = 0
                total_customers_assessed = 0
            }
            critical_issues = @()
            compliance_gaps = @{
                customers_below_threshold = @()
                worst_performing_controls = @()
            }
            by_customer = @()
            by_severity = @()
            by_cis_section = @()
        }
    }
    
    # Filter findings by severity if requested
    $filteredFindings = if ($CriticalOnly) {
        @($failedFindings | Where-Object { $_.Severity -in @('Critical', 'High') })
    } else {
        $failedFindings
    }
    
    # Calculate summary statistics
    $totalFindings = $failedFindings.Count
    $criticalCount = @($failedFindings | Where-Object { $_.Severity -eq 'Critical' }).Count
    $highCount = @($failedFindings | Where-Object { $_.Severity -eq 'High' }).Count
    $mediumCount = @($failedFindings | Where-Object { $_.Severity -eq 'Medium' }).Count
    $lowCount = $totalFindings - $criticalCount - $highCount - $mediumCount
    
    # Calculate compliance scores per customer (subscription)
    $customerScores = @()
    $uniqueCustomers = $failedFindings | Select-Object -ExpandProperty SubscriptionName -Unique
    
    foreach ($customer in $uniqueCustomers) {
        $customerFindings = @($failedFindings | Where-Object { $_.SubscriptionName -eq $customer })
        $customerPassed = @($Findings | Where-Object { $_.SubscriptionName -eq $customer -and $_.Status -eq 'PASS' })
        $totalChecks = $customerFindings.Count + $customerPassed.Count
        
        if ($totalChecks -gt 0) {
            $score = [math]::Round(($customerPassed.Count / $totalChecks) * 100, 1)
        } else {
            $score = 100  # No checks = perfect score
        }
        
        $customerScores += [PSCustomObject]@{
            Customer = $customer
            Score = $score
        }
    }
    
    $avgComplianceScore = if ($customerScores.Count -gt 0) {
        [math]::Round(($customerScores | Measure-Object -Property Score -Average).Average, 1)
    } else { 
        100 
    }
    
    # Group findings by control for affected resources count
    $findingsByControl = $filteredFindings | Group-Object -Property ControlId
    
    $insights = @{
        domain = "security_compliance"
        generated_at = (Get-Date).ToString("o")
        
        summary = @{
            total_findings = $totalFindings
            critical_count = $criticalCount
            high_count = $highCount
            medium_count = $mediumCount
            low_count = $lowCount
            average_compliance_score = $avgComplianceScore
            customers_below_80_percent = @($customerScores | Where-Object { $_.Score -lt 80 }).Count
            total_customers_assessed = $customerScores.Count
        }
        
        critical_issues = @($findingsByControl |
            ForEach-Object {
                $controlFindings = $_.Group
                $firstFinding = $controlFindings[0]
                $affectedResources = ($controlFindings | Select-Object -ExpandProperty ResourceName -Unique).Count
                $affectedResourceTypes = ($controlFindings | Select-Object -ExpandProperty ResourceType -Unique)
                
                [PSCustomObject]@{
                    Customer = $firstFinding.SubscriptionName
                    Subscription = $firstFinding.SubscriptionName
                    ControlId = $firstFinding.ControlId
                    ControlName = $firstFinding.ControlName
                    Description = "$($firstFinding.ControlName) - Current: $($firstFinding.CurrentValue), Expected: $($firstFinding.ExpectedValue)"
                    Severity = $firstFinding.Severity
                    AffectedResources = $affectedResources
                    AffectedResourceTypes = @($affectedResourceTypes)
                    CISBenchmark = "CIS Azure $($firstFinding.ControlId)"
                    RemediationEffort = Get-RemediationEffort -Finding @{
                        ControlId = $firstFinding.ControlId
                        Severity = $firstFinding.Severity
                        AffectedResources = $affectedResources
                    }
                    RemediationGuidance = $firstFinding.RemediationSteps
                    AffectedCustomers = ($controlFindings | Select-Object -ExpandProperty SubscriptionName -Unique).Count
                }
            } |
            Sort-Object @{
                Expression = {
                    # Sort by severity (Critical=0, High=1) then by affected resources
                    if ($_.Severity -eq 'Critical') { 0 } else { 1 }
                }
            }, @{
                Expression = { $_.AffectedResources }
                Descending = $true
            } |
            Select-Object -First $TopN |
            ForEach-Object {
                @{
                    customer = $_.Customer
                    subscription = $_.Subscription
                    control_id = $_.ControlId
                    control_name = $_.ControlName
                    description = $_.Description
                    severity = $_.Severity
                    affected_resources = $_.AffectedResources
                    affected_resource_types = $_.AffectedResourceTypes
                    cis_benchmark = $_.CISBenchmark
                    remediation_effort = $_.RemediationEffort
                    remediation_guidance = $_.RemediationGuidance
                    affected_customers = $_.AffectedCustomers
                }
            })
        
        compliance_gaps = @{
            customers_below_threshold = @($customerScores | 
                Where-Object { $_.Score -lt 80 } |
                Sort-Object Score |
                ForEach-Object {
                    $customerName = $_.Customer
                    $customerFindings = $failedFindings | Where-Object { $_.SubscriptionName -eq $customerName }
                    
                    @{
                        customer = $customerName
                        score = $_.Score
                        critical_findings = @($customerFindings | Where-Object { $_.Severity -eq 'Critical' }).Count
                        high_findings = @($customerFindings | Where-Object { $_.Severity -eq 'High' }).Count
                    }
                })
            
            worst_performing_controls = @($failedFindings |
                Group-Object -Property ControlId |
                Sort-Object Count -Descending |
                Select-Object -First 10 |
                ForEach-Object {
                    $controlFindings = $_.Group
                    $firstFinding = $controlFindings[0]
                    
                    @{
                        control_id = $_.Name
                        control_name = $firstFinding.ControlName
                        failure_count = $_.Count
                        customers_affected = ($controlFindings | Select-Object -ExpandProperty SubscriptionName -Unique).Count
                        total_resources_affected = ($controlFindings | Select-Object -ExpandProperty ResourceName -Unique).Count
                        cis_benchmark = "CIS Azure $($firstFinding.ControlId)"
                    }
                })
        }
        
        by_customer = @($customerScores |
            Sort-Object Score |
            Select-Object -First 10 |
            ForEach-Object {
                $customerName = $_.Customer
                $customerFindings = $failedFindings | Where-Object { $_.SubscriptionName -eq $customerName }
                
                @{
                    customer = $customerName
                    compliance_score = $_.Score
                    total_findings = $customerFindings.Count
                    critical_findings = @($customerFindings | Where-Object { $_.Severity -eq 'Critical' }).Count
                    high_findings = @($customerFindings | Where-Object { $_.Severity -eq 'High' }).Count
                    worst_control_areas = @($customerFindings |
                        Group-Object -Property { if ($_.ControlId) { $_.ControlId.Split('.')[0] } else { "Unknown" } } |
                        Sort-Object Count -Descending |
                        Select-Object -First 3 |
                        ForEach-Object {
                            $sectionName = switch ($_.Name) {
                                "1" { "Identity and Access Management" }
                                "2" { "Storage Accounts" }
                                "3" { "Networking" }
                                "4" { "Virtual Machines" }
                                "5" { "Logging and Monitoring" }
                                "6" { "Azure SQL Database" }
                                "7" { "Other Database Services" }
                                "8" { "Key Vault" }
                                "9" { "App Service" }
                                default { "Section $($_.Name)" }
                            }
                            
                            @{
                                cis_section = $_.Name
                                section_name = $sectionName
                                finding_count = $_.Count
                            }
                        })
                }
            })
        
        by_severity = @($failedFindings |
            Group-Object -Property Severity |
            ForEach-Object {
                @{
                    severity = $_.Name
                    count = $_.Count
                    percentage = [math]::Round(($_.Count / $totalFindings) * 100, 1)
                    customers_affected = ($_.Group | Select-Object -ExpandProperty SubscriptionName -Unique).Count
                }
            })
        
        by_cis_section = @($failedFindings |
            Group-Object -Property { if ($_.ControlId) { $_.ControlId.Split('.')[0] } else { "Unknown" } } |
            Sort-Object Count -Descending |
            ForEach-Object {
                $sectionName = switch ($_.Name) {
                    "1" { "Identity and Access Management" }
                    "2" { "Storage Accounts" }
                    "3" { "Networking" }
                    "4" { "Virtual Machines" }
                    "5" { "Logging and Monitoring" }
                    "6" { "Azure SQL Database" }
                    "7" { "Other Database Services" }
                    "8" { "Key Vault" }
                    "9" { "App Service" }
                    default { "Section $($_.Name)" }
                }
                
                @{
                    section_number = $_.Name
                    section_name = $sectionName
                    finding_count = $_.Count
                    critical_count = @($_.Group | Where-Object { $_.Severity -eq 'Critical' }).Count
                }
            })
    }
    
    Write-Verbose "Security insights generated: $($insights.summary.total_findings) findings ($($insights.summary.critical_count) critical, $($insights.summary.high_count) high)"
    
    return $insights
}

