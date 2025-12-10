<#
.SYNOPSIS
    Generates a consolidated HTML report for Azure Advisor recommendations.

.DESCRIPTION
    Creates an interactive HTML report showing Azure Advisor recommendations
    grouped by recommendation type (not by resource), with expandable sections
    showing affected resources. This dramatically reduces report size when
    many resources have the same recommendation.

.PARAMETER AdvisorRecommendations
    Array of Advisor recommendation objects from Get-AzureAdvisorRecommendations.

.PARAMETER OutputPath
    Path for the HTML report output.

.PARAMETER TenantId
    Azure Tenant ID for display in report.

.OUTPUTS
    String path to the generated HTML report.
#>
function Export-AdvisorReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$AdvisorRecommendations,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        
        [string]$TenantId = "Unknown"
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    
    # Ensure AdvisorRecommendations is an array (handle null/empty cases)
    if ($null -eq $AdvisorRecommendations) {
        $AdvisorRecommendations = @()
    } else {
        $AdvisorRecommendations = @($AdvisorRecommendations)
    }
    
    Write-Verbose "Export-AdvisorReport: Processing $($AdvisorRecommendations.Count) recommendations"
    
    # Group recommendations by type
    $groupedRecs = Group-AdvisorRecommendations -Recommendations $AdvisorRecommendations
    
    # Calculate statistics
    $totalRecs = $groupedRecs.Count
    $totalResources = ($groupedRecs | Measure-Object -Property AffectedResourceCount -Sum).Sum
    if (-not $totalResources) { $totalResources = 0 }
    
    # Group by category
    $costRecs = @($groupedRecs | Where-Object { $_.Category -eq 'Cost' })
    $securityRecs = @($groupedRecs | Where-Object { $_.Category -eq 'Security' })
    $reliabilityRecs = @($groupedRecs | Where-Object { $_.Category -eq 'Reliability' -or $_.Category -eq 'HighAvailability' })
    $operationalRecs = @($groupedRecs | Where-Object { $_.Category -eq 'OperationalExcellence' })
    $performanceRecs = @($groupedRecs | Where-Object { $_.Category -eq 'Performance' })
    
    # Calculate savings by strategy (RI and SP are ALTERNATIVE strategies, not additive)
    $riRecs = @($costRecs | Where-Object { 
        $_.Problem -like "*reserved instance*" -or 
        $_.Solution -like "*reserved instance*"
    })
    $spRecs = @($costRecs | Where-Object { 
        $_.Problem -like "*savings plan*" -or 
        $_.Solution -like "*savings plan*"
    })
    $otherCostRecs = @($costRecs | Where-Object { 
        $_.Problem -notlike "*reserved instance*" -and 
        $_.Solution -notlike "*reserved instance*" -and
        $_.Problem -notlike "*savings plan*" -and 
        $_.Solution -notlike "*savings plan*"
    })
    
    # Calculate totals for each strategy
    $riTotal = ($riRecs | Where-Object { $_.TotalSavings } | Measure-Object -Property TotalSavings -Sum).Sum
    if (-not $riTotal) { $riTotal = 0 }
    
    $spTotal = ($spRecs | Where-Object { $_.TotalSavings } | Measure-Object -Property TotalSavings -Sum).Sum
    if (-not $spTotal) { $spTotal = 0 }
    
    $otherCostTotal = ($otherCostRecs | Where-Object { $_.TotalSavings } | Measure-Object -Property TotalSavings -Sum).Sum
    if (-not $otherCostTotal) { $otherCostTotal = 0 }
    
    # Total savings = max(RI, SP) + other cost savings (RI and SP are alternatives)
    $totalSavings = [Math]::Max($riTotal, $spTotal) + $otherCostTotal
    
    $savingsCurrency = ($costRecs | Where-Object { $_.SavingsCurrency } | Select-Object -First 1).SavingsCurrency
    if (-not $savingsCurrency) { $savingsCurrency = "USD" }
    
    # Determine recommended strategy
    $recommendedStrategy = if ($spTotal -gt $riTotal) { "Savings Plans" } elseif ($riTotal -gt 0) { "Reserved Instances" } else { $null }
    $recommendedSavings = [Math]::Max($riTotal, $spTotal)
    
    # Get unique subscriptions for filter
    $allSubscriptions = @($AdvisorRecommendations | Select-Object -ExpandProperty SubscriptionName -Unique | Sort-Object)
    
    # Encode-Html is now imported from Private/Helpers/Encode-Html.ps1
    
    # Start building HTML
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure Advisor Recommendations Report</title>
    <style>
$(Get-ReportStylesheet)
    </style>
</head>
<body>
$(Get-ReportNavigation -ActivePage "Advisor")
    
    <div class="container">
        <div class="page-header">
            <h1>Advisor Recommendations</h1>
            <p class="subtitle">Consolidated view - $totalRecs unique recommendations affecting $totalResources resources</p>
        </div>
        
        <div class="summary-cards">
            <div class="summary-card total">
                <div class="value">$totalRecs</div>
                <div class="label">Recommendations</div>
            </div>
            <div class="summary-card resources">
                <div class="value">$totalResources</div>
                <div class="label">Affected Resources</div>
            </div>
            <div class="summary-card cost">
                <div class="value">$($costRecs.Count)</div>
                <div class="label">Cost</div>
            </div>
            <div class="summary-card security">
                <div class="value">$($securityRecs.Count)</div>
                <div class="label">Security</div>
            </div>
            <div class="summary-card reliability">
                <div class="value">$($reliabilityRecs.Count)</div>
                <div class="label">Reliability</div>
            </div>
            <div class="summary-card performance">
                <div class="value">$($performanceRecs.Count)</div>
                <div class="label">Performance</div>
            </div>
            <div class="summary-card savings">
                <div class="value">$savingsCurrency $([math]::Round($totalSavings, 0))/yr</div>
                <div class="label">Potential Savings</div>
            </div>
        </div>
        
        $(if ($riTotal -gt 0 -or $spTotal -gt 0) {
            $strategyHtml = @"
        <div style="background: var(--bg-surface); border-radius: 12px; padding: 24px; margin-bottom: 30px; border: 1px solid var(--border-color);">
            <h2 style="margin-top: 0; margin-bottom: 20px; font-size: 1.3rem; color: var(--accent-yellow);">Cost Optimization Strategies</h2>
            <p style="color: var(--text-muted); margin-bottom: 20px; font-size: 0.9rem;">Reserved Instances and Savings Plans are <strong>alternative strategies</strong>, not cumulative. Choose the approach that best fits your workload patterns.</p>
            
            <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; margin-bottom: 20px;">
                $(if ($riTotal -gt 0) {
                    $riRecommended = if ($recommendedStrategy -eq "Reserved Instances") { '<span style="color: var(--accent-green); font-weight: 600; margin-left: 10px;">&#10003; RECOMMENDED</span>' } else { '' }
                    @"
                <div style="background: var(--bg-secondary); padding: 20px; border-radius: 8px; border: 1px solid var(--border-color);">
                    <h3 style="margin-top: 0; margin-bottom: 10px; color: var(--accent-blue);">Strategy A: Reserved Instances$riRecommended</h3>
                    <div style="font-size: 1.5rem; font-weight: 700; color: var(--accent-green); margin: 10px 0;">$savingsCurrency $([math]::Round($riTotal, 0))/yr</div>
                    <p style="color: var(--text-secondary); font-size: 0.9rem; margin: 10px 0 0 0;">Purchase RIs for specific VM sizes. Best for stable, predictable workloads.</p>
                </div>
"@
                })
                
                $(if ($spTotal -gt 0) {
                    $spRecommended = if ($recommendedStrategy -eq "Savings Plans") { '<span style="color: var(--accent-green); font-weight: 600; margin-left: 10px;">&#10003; RECOMMENDED</span>' } else { '' }
                    @"
                <div style="background: var(--bg-secondary); padding: 20px; border-radius: 8px; border: 1px solid var(--border-color);">
                    <h3 style="margin-top: 0; margin-bottom: 10px; color: var(--accent-blue);">Strategy B: Savings Plans$spRecommended</h3>
                    <div style="font-size: 1.5rem; font-weight: 700; color: var(--accent-green); margin: 10px 0;">$savingsCurrency $([math]::Round($spTotal, 0))/yr</div>
                    <p style="color: var(--text-secondary); font-size: 0.9rem; margin: 10px 0 0 0;">Commitment on compute spend. Best for dynamic, mixed workloads.</p>
                </div>
"@
                })
            </div>
            
            $(if ($recommendedStrategy) {
                $savingsDiff = [Math]::Abs($spTotal - $riTotal)
                if ($savingsDiff -gt 0) {
                    @"
            <div style="background: rgba(0, 210, 106, 0.1); border-left: 4px solid var(--accent-green); padding: 15px; border-radius: 6px; margin-top: 15px;">
                <strong style="color: var(--accent-green);">Recommendation:</strong> 
                <span style="color: var(--text-primary);">$recommendedStrategy provides $savingsCurrency $([math]::Round($savingsDiff, 0)) more annual savings compared to the alternative strategy.</span>
            </div>
"@
                }
            })
            
            <p style="color: var(--text-muted); font-size: 0.85rem; margin-top: 20px; margin-bottom: 0; font-style: italic;">Note: These strategies are alternatives, not cumulative. You can also use a hybrid approach (RIs for stable VMs + Savings Plan for dynamic workloads) with detailed analysis.</p>
        </div>
"@
            $strategyHtml
        } else { '' })
        
        <div class="filter-section">
            <div class="filter-group">
                <label>Search:</label>
                <input type="text" id="searchFilter" placeholder="Search recommendations...">
            </div>
            <div class="filter-group">
                <label>Impact:</label>
                <select id="impactFilter">
                    <option value="all">All Impacts</option>
                    <option value="high">High</option>
                    <option value="medium">Medium</option>
                    <option value="low">Low</option>
                </select>
            </div>
            <div class="filter-group">
                <label>Subscription:</label>
                <select id="subscriptionFilter">
                    <option value="all">All Subscriptions</option>
"@

    # Add subscription options
    foreach ($sub in $allSubscriptions) {
        $html += "                    <option value=`"$(($sub).ToLower())`">$sub</option>`n"
    }

    $html += @"
                </select>
            </div>
        </div>
"@

    if ($totalRecs -eq 0) {
        $html += @"
        <div class="no-data">
            <h2>No Recommendations Found</h2>
            <p>Azure Advisor has no recommendations for your subscriptions. Great job!</p>
        </div>
"@
    }
    else {
        # Generate sections for each category
        $categories = @(
            @{ Name = "Cost"; Icon = "cost"; Recs = $costRecs; Label = "Cost Optimization" }
            @{ Name = "Security"; Icon = "security"; Recs = $securityRecs; Label = "Security" }
            @{ Name = "Reliability"; Icon = "reliability"; Recs = $reliabilityRecs; Label = "Reliability" }
            @{ Name = "OperationalExcellence"; Icon = "operational"; Recs = $operationalRecs; Label = "Operational Excellence" }
            @{ Name = "Performance"; Icon = "performance"; Recs = $performanceRecs; Label = "Performance" }
        )
        
        foreach ($cat in $categories) {
            if ($cat.Recs.Count -eq 0) { continue }
            
            $catResourceCount = ($cat.Recs | Measure-Object -Property AffectedResourceCount -Sum).Sum
            $catHighCount = ($cat.Recs | ForEach-Object { $_.ImpactDistribution.High } | Measure-Object -Sum).Sum
            $catMediumCount = ($cat.Recs | ForEach-Object { $_.ImpactDistribution.Medium } | Measure-Object -Sum).Sum
            $catLowCount = ($cat.Recs | ForEach-Object { $_.ImpactDistribution.Low } | Measure-Object -Sum).Sum
            
            $html += @"
        
        <div class="category-section" data-category="$($cat.Name.ToLower())">
            <div class="category-header collapsed" onclick="toggleCategory(this)">
                <div class="category-title">
                    <span class="expand-icon"></span>
                    <span class="category-icon $($cat.Icon)">$($cat.Recs.Count)</span>
                    <span>$($cat.Label)</span>
                    <span style="color: var(--text-muted); font-weight: normal; font-size: 0.85rem;">($catResourceCount resources)</span>
                </div>
                <div class="category-stats">
                    <span class="impact-badge high">$catHighCount High</span>
                    <span class="impact-badge medium">$catMediumCount Med</span>
                    <span class="impact-badge low">$catLowCount Low</span>
                </div>
            </div>
            <div class="category-content">
"@
            
            foreach ($rec in $cat.Recs) {
                $impactClass = $rec.Impact.ToLower()
                $escapedProblem = Encode-Html $rec.Problem
                $escapedSolution = Encode-Html $rec.Solution
                $escapedDescription = Encode-Html $rec.Description
                $escapedLongDescription = Encode-Html $rec.LongDescription
                $escapedBenefits = Encode-Html $rec.PotentialBenefits
                $escapedRemediation = Encode-Html $rec.Remediation
                
                # Subscriptions as data attribute for filtering
                $subsLower = ($rec.AffectedSubscriptions | ForEach-Object { $_.ToLower() }) -join ','
                $searchable = "$escapedProblem $escapedSolution $escapedDescription".ToLower()
                
                $savingsDisplay = ""
                if ($rec.TotalSavings -and $rec.TotalSavings -gt 0) {
                    $savingsDisplay = "$($rec.SavingsCurrency) $([math]::Round($rec.TotalSavings, 0))/yr"
                }
                
                $html += @"
                <div class="rec-card" 
                     data-impact="$impactClass" 
                     data-subscriptions="$subsLower"
                     data-searchable="$searchable">
                    <div class="rec-header" onclick="toggleRec(this.parentElement)">
                        <span class="rec-expand"></span>
                        <div class="rec-main">
                            <div class="rec-problem">$escapedProblem</div>
                            <div class="rec-meta">
                                <span class="rec-meta-item">
                                    <span class="impact-badge $impactClass">$($rec.Impact)</span>
                                </span>
"@
                if ($rec.AffectedSubscriptions.Count -gt 1) {
                    $html += @"
                                <span class="rec-meta-item">$($rec.AffectedSubscriptions.Count) subscriptions</span>
"@
                }
                elseif ($rec.AffectedSubscriptions.Count -eq 1) {
                    $html += @"
                                <span class="rec-meta-item">$($rec.AffectedSubscriptions[0])</span>
"@
                }
                $html += @"
                            </div>
                        </div>
                        <div class="rec-stats">
"@
                if ($savingsDisplay) {
                    $html += "                            <span class='savings-badge'>$savingsDisplay</span>`n"
                }
                $html += @"
                            <span class="resource-count">$($rec.AffectedResourceCount) resource$(if ($rec.AffectedResourceCount -ne 1) { 's' })</span>
                        </div>
                    </div>
                    <div class="rec-details">
"@
                
                # Description section
                $descriptionText = if ($escapedLongDescription -and $escapedLongDescription -ne $escapedProblem) {
                    $escapedLongDescription
                } elseif ($escapedDescription -and $escapedDescription -ne $escapedProblem) {
                    $escapedDescription
                } else {
                    $escapedProblem
                }
                
                $html += @"
                        <div class="detail-section">
                            <div class="detail-title">Description</div>
                            <div class="detail-content">$descriptionText</div>
                        </div>
"@
                
                # Technical Details section (if available)
                if ($rec.AffectedResources -and ($rec.AffectedResources | Where-Object { $_.TechnicalDetails })) {
                    $html += @"
                        <div class="detail-section">
                            <div class="detail-title">Technical Details</div>
                            <div class="detail-content" style="font-family: 'Consolas', monospace; font-size: 0.9em;">
"@
                    foreach ($resource in ($rec.AffectedResources | Where-Object { $_.TechnicalDetails })) {
                    $escapedDetails = Encode-Html $resource.TechnicalDetails
                    $escapedResName = Encode-Html $resource.ResourceName
                        $html += "                                <div><strong>${escapedResName}:</strong> $escapedDetails</div>`n"
                    }
                    $html += @"
                            </div>
                        </div>
"@
                }
                
                # Solution section
                if ($escapedSolution -and $escapedSolution -ne "See Azure Portal for remediation steps") {
                    $html += @"
                        <div class="detail-section">
                            <div class="detail-title">Recommended Action</div>
                            <div class="detail-content">$escapedSolution</div>
                        </div>
"@
                }
                
                # Benefits section
                if ($escapedBenefits) {
                    $html += @"
                        <div class="detail-section">
                            <div class="detail-title">Potential Benefits</div>
                            <div class="detail-content">$escapedBenefits</div>
                        </div>
"@
                }
                
                # Remediation section
                if ($escapedRemediation -and $escapedRemediation -ne $escapedSolution) {
                    $html += @"
                        <div class="detail-section">
                            <div class="detail-title">Remediation Steps</div>
                            <div class="detail-content">$escapedRemediation</div>
                        </div>
"@
                }
                
                # Learn more link
                if ($rec.LearnMoreLink) {
                    $escapedLink = Encode-Html $rec.LearnMoreLink
                    $html += @"
                        <div class="detail-section">
                            <div class="detail-content">
                                <a href="$escapedLink" target="_blank">Learn more →</a>
                            </div>
                        </div>
"@
                }
                
                # Affected resources table
                $html += @"
                        <div class="resources-section" onclick="toggleResources(event, this)">
                            <div class="resources-header">
                                <span class="resources-title">
                                    <span class="rec-expand"></span>
                                    Affected Resources ($($rec.AffectedResourceCount))
                                </span>
                            </div>
                            <div class="resources-table-wrapper">
                                <table class="resources-table">
                                    <thead>
                                        <tr>
                                            <th>Resource Name</th>
                                            <th>Resource Group</th>
                                            <th>Subscription</th>
                                            <th>Technical Details</th>
"@
                if ($cat.Name -eq "Cost") {
                    $html += "                                            <th>Monthly</th>`n"
                    $html += "                                            <th>Annual</th>`n"
                }
                $html += @"
                                        </tr>
                                    </thead>
                                    <tbody>
"@
                
                foreach ($resource in ($rec.AffectedResources | Sort-Object SubscriptionName, ResourceGroup, ResourceName)) {
                    $escapedResName = Encode-Html $resource.ResourceName
                    $escapedResGroup = Encode-Html $resource.ResourceGroup
                    $escapedSubName = Encode-Html $resource.SubscriptionName
                    $escapedTechDetails = Encode-Html $resource.TechnicalDetails
                    
                    $html += @"
                                        <tr>
                                            <td class="resource-name">$escapedResName</td>
                                            <td>$escapedResGroup</td>
                                            <td>$escapedSubName</td>
                                            <td style="font-family: 'Consolas', monospace; font-size: 0.85em;">$escapedTechDetails</td>
"@
                    if ($cat.Name -eq "Cost") {
                        $resMonthlySavings = if ($resource.MonthlySavings -and $resource.MonthlySavings -gt 0) {
                            "$($resource.SavingsCurrency) $([math]::Round($resource.MonthlySavings, 0))/mo"
                        } else { "-" }
                        $resAnnualSavings = if ($resource.PotentialSavings -and $resource.PotentialSavings -gt 0) {
                            "$($resource.SavingsCurrency) $([math]::Round($resource.PotentialSavings, 0))/yr"
                        } else { "-" }
                        $html += "                                            <td style='color: var(--accent-green);'>$resMonthlySavings</td>`n"
                        $html += "                                            <td style='color: var(--accent-green);'>$resAnnualSavings</td>`n"
                    }
                    $html += "                                        </tr>`n"
                }
                
                $html += @"
                                    </tbody>
                                </table>
                            </div>
                        </div>
                    </div>
                </div>
"@
            }
            
            $html += @"
            </div>
        </div>
"@
        }
    }
    
    # JavaScript - using placeholder for && to avoid PowerShell issues
    $jsCode = @'
    </div>
    
    <script>
        function toggleCategory(header) {
            header.classList.toggle('collapsed');
        }
        
        function toggleRec(card) {
            card.classList.toggle('expanded');
        }
        
        function toggleResources(event, section) {
            event.stopPropagation();
            section.classList.toggle('expanded');
        }
        
        // Filtering
        const searchFilter = document.getElementById('searchFilter');
        const impactFilter = document.getElementById('impactFilter');
        const subscriptionFilter = document.getElementById('subscriptionFilter');
        
        function applyFilters() {
            const searchText = searchFilter.value.toLowerCase();
            const impactValue = impactFilter.value;
            const subscriptionValue = subscriptionFilter.value;
            
            document.querySelectorAll('.category-section').forEach(section => {
                let visibleCards = 0;
                
                section.querySelectorAll('.rec-card').forEach(card => {
                    const searchable = card.getAttribute('data-searchable');
                    const impact = card.getAttribute('data-impact');
                    const subs = card.getAttribute('data-subscriptions');
                    
                    const searchMatch = searchText === '' || searchable.includes(searchText);
                    const impactMatch = impactValue === 'all' || impact === impactValue;
                    const subMatch = subscriptionValue === 'all' || subs.includes(subscriptionValue);
                    
                    if (searchMatch PLACEHOLDER_AND impactMatch PLACEHOLDER_AND subMatch) {
                        card.style.display = '';
                        visibleCards++;
                    } else {
                        card.style.display = 'none';
                        card.classList.remove('expanded');
                    }
                });
                
                section.style.display = visibleCards === 0 ? 'none' : '';
            });
        }
        
        searchFilter.addEventListener('input', applyFilters);
        impactFilter.addEventListener('change', applyFilters);
        subscriptionFilter.addEventListener('change', applyFilters);
    </script>
</body>
</html>
'@
    $jsCode = $jsCode -replace 'PLACEHOLDER_AND', '&&'
    $html += $jsCode
    
    # Write to file
    $html | Out-File -FilePath $OutputPath -Encoding UTF8
    
    # Calculate advisor counts
    $advisorCount = $totalRecs
    $advisorHighCount = @($groupedRecs | Where-Object { $_.Impact -eq 'High' }).Count
    
    # Return both path and calculated savings data for reuse in Dashboard
    return @{
        OutputPath = $OutputPath
        AdvisorCount = $advisorCount
        AdvisorHighCount = $advisorHighCount
        TotalSavings = $totalSavings
        SavingsCurrency = $savingsCurrency
        RiTotal = $riTotal
        SpTotal = $spTotal
        OtherCostTotal = $otherCostTotal
        RecommendedStrategy = $recommendedStrategy
    }
}

