<#
.SYNOPSIS
    Generates JavaScript code for interactive report functionality.

.DESCRIPTION
    Returns JavaScript code for filtering, searching, and expanding/collapsing
    sections in HTML reports.

.PARAMETER ScriptType
    Type of script to generate: "SecurityReport", "Dashboard", "VMBackup", or "Advisor".

.EXAMPLE
    $script = Get-ReportScript -ScriptType "SecurityReport"
#>
function Get-ReportScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('SecurityReport', 'Dashboard', 'VMBackup', 'Advisor')]
        [string]$ScriptType
    )
    
    switch ($ScriptType) {
        'SecurityReport' {
            return @"
        // Interactive filtering and row expansion
        (function() {
            // Wait for DOM to be fully loaded
            function initFilters() {
                const severityFilter = document.getElementById('severityFilter');
                const categoryFilter = document.getElementById('categoryFilter');
                const frameworkFilter = document.getElementById('frameworkFilter');
                const subscriptionFilter = document.getElementById('subscriptionFilter');
                const searchFilter = document.getElementById('searchFilter');
                const clearFiltersBtn = document.getElementById('clearFilters');
                const resultCount = document.getElementById('resultCount');
                
                // Get all filterable elements
                const subscriptionBoxes = document.querySelectorAll('.subscription-box:not(.category-box)');
                const categoryBoxes = document.querySelectorAll('.category-box');
                const controlRows = document.querySelectorAll('.control-row');
                const resourceRows = document.querySelectorAll('.resource-row');
                
                if (!severityFilter || !categoryFilter || !frameworkFilter || !subscriptionFilter || !searchFilter || !clearFiltersBtn || !resultCount) {
                    return;
                }
                
                function updateFilters() {
                    const selectedSeverity = severityFilter.value.toLowerCase();
                    const selectedCategory = categoryFilter.value.toLowerCase();
                    const selectedFramework = frameworkFilter.value.toLowerCase();
                    const selectedSubscription = subscriptionFilter.value.toLowerCase();
                    const searchText = searchFilter.value.toLowerCase().trim();
                    
                    let visibleCount = 0;
                    
                    // Filter subscription boxes (Failed Controls by Subscription)
                    subscriptionBoxes.forEach(box => {
                        // Always show deprecated-components box (special section)
                        const deprecatedHeader = box.querySelector('[data-subscription-id="deprecated-components"]');
                        const isDeprecatedBox = deprecatedHeader !== null || 
                                               box.hasAttribute('data-always-visible') ||
                                               box.id === 'deprecated-components';
                        if (isDeprecatedBox) {
                            box.style.display = 'block';
                            box.style.visibility = 'visible';
                            box.style.opacity = '1';
                            return;
                        }
                        
                        const boxSubscription = box.getAttribute('data-subscription-lower') || '';
                        const searchableText = box.getAttribute('data-searchable') || '';
                        
                        const subscriptionMatch = selectedSubscription === 'all' || boxSubscription === selectedSubscription;
                        const searchMatch = searchText === '' || searchableText.includes(searchText);
                        
                        // Check if any resource rows inside match ALL active filters
                        const resourceRowsInBox = box.querySelectorAll('.resource-row');
                        let hasMatchingResource = false;
                        let visibleResourceCount = 0;
                        
                        // First pass: determine which resource rows match
                        resourceRowsInBox.forEach(row => {
                            const resourceKey = row.getAttribute('data-resource-key');
                            let visibleControlCount = 0;
                            
                            if (resourceKey) {
                                const detailRow = document.querySelector('.resource-detail-row[data-resource-key="' + resourceKey + '"]');
                                if (detailRow) {
                                    const controlDetailRows = detailRow.querySelectorAll('.control-detail-row');
                                    
                                    controlDetailRows.forEach(controlRow => {
                                        const controlSeverity = controlRow.getAttribute('data-severity-lower') || '';
                                        const controlCategory = controlRow.getAttribute('data-category-lower') || '';
                                        const controlFrameworks = controlRow.getAttribute('data-frameworks') || '';
                                        const controlSearchable = controlRow.getAttribute('data-searchable') || '';
                                        
                                        const controlSeverityMatch = selectedSeverity === 'all' || controlSeverity === selectedSeverity;
                                        const controlCategoryMatch = selectedCategory === 'all' || controlCategory === selectedCategory;
                                        const controlFrameworkMatch = selectedFramework === 'all' || controlFrameworks.includes(selectedFramework);
                                        const controlSearchMatch = searchText === '' || controlSearchable.includes(searchText);
                                        
                                        if (controlSeverityMatch && controlCategoryMatch && controlFrameworkMatch && controlSearchMatch) {
                                            controlRow.classList.remove('hidden');
                                            visibleControlCount++;
                                        } else {
                                            controlRow.classList.add('hidden');
                                            controlRow.classList.remove('expanded');
                                            const controlDetailKey = controlRow.getAttribute('data-control-detail-key');
                                            if (controlDetailKey) {
                                                const remediationRow = document.querySelector('.remediation-row[data-parent-control-detail-key="' + controlDetailKey + '"]');
                                                if (remediationRow) {
                                                    remediationRow.classList.add('hidden');
                                                }
                                            }
                                        }
                                    });
                                }
                            }
                            
                            const rowShouldShow = visibleControlCount > 0;
                            
                            if (rowShouldShow) {
                                hasMatchingResource = true;
                                row.classList.remove('hidden');
                                visibleResourceCount++;
                                visibleCount++;
                            } else {
                                row.classList.add('hidden');
                                row.classList.remove('expanded');
                                if (resourceKey) {
                                    const detailRow = document.querySelector('.resource-detail-row[data-resource-key="' + resourceKey + '"]');
                                    if (detailRow) {
                                        detailRow.classList.add('hidden');
                                    }
                                }
                            }
                        });
                        
                        if (subscriptionMatch && searchMatch && hasMatchingResource) {
                            box.style.display = 'block';
                            // Ensure content is still hidden if header is collapsed
                            const subscriptionId = box.querySelector('.subscription-header')?.getAttribute('data-subscription-id');
                            if (subscriptionId) {
                                const content = document.getElementById(subscriptionId);
                                if (content) {
                                    const header = box.querySelector('.subscription-header');
                                    if (header && header.classList.contains('collapsed')) {
                                        content.style.display = 'none';
                                    }
                                }
                            }
                        } else {
                            box.style.display = 'none';
                        }
                    });
                    
                    // Filter category boxes (Failed Controls by Category)
                    categoryBoxes.forEach(box => {
                        const boxSeverity = box.getAttribute('data-severity-lower') || '';
                        const boxCategory = box.getAttribute('data-category-lower') || '';
                        const searchableText = box.getAttribute('data-searchable') || '';
                        
                        const severityMatch = selectedSeverity === 'all' || boxSeverity === selectedSeverity;
                        const categoryMatch = selectedCategory === 'all' || boxCategory === selectedCategory;
                        const searchMatch = searchText === '' || searchableText.includes(searchText);
                        
                        const controlRowsInBox = box.querySelectorAll('.control-row');
                        let hasMatchingControl = false;
                        let hasMatchingSubscription = false;
                        
                        controlRowsInBox.forEach(row => {
                            const rowSeverity = row.getAttribute('data-severity-lower') || '';
                            const rowCategory = row.getAttribute('data-category-lower') || '';
                            const rowFrameworks = row.getAttribute('data-frameworks') || '';
                            const rowSearchable = row.getAttribute('data-searchable') || '';
                            
                            const rowSeverityMatch = selectedSeverity === 'all' || rowSeverity === selectedSeverity;
                            const rowCategoryMatch = selectedCategory === 'all' || rowCategory === selectedCategory;
                            const rowFrameworkMatch = selectedFramework === 'all' || rowFrameworks.includes(selectedFramework);
                            const rowSearchMatch = searchText === '' || rowSearchable.includes(searchText);
                            
                            // Check subscription match - subscription names are in the searchable text
                            let rowSubscriptionMatch = true;
                            if (selectedSubscription !== 'all') {
                                // Extract subscription names from searchable text or check resource detail rows
                                // Subscription names are included in the searchable text (lowercased)
                                rowSubscriptionMatch = rowSearchable.includes(selectedSubscription);
                                
                                // Also check resource detail rows for this control
                                if (!rowSubscriptionMatch) {
                                    const controlKey = row.getAttribute('data-control-key');
                                    if (controlKey) {
                                        const resourcesRow = document.querySelector('.control-resources-row[data-control-key="' + controlKey + '"]');
                                        if (resourcesRow) {
                                            const resourceDetailRows = resourcesRow.querySelectorAll('.resource-detail-control-row');
                                            for (let resourceRow of resourceDetailRows) {
                                                const resourceSearchable = resourceRow.getAttribute('data-searchable') || '';
                                                if (resourceSearchable.includes(selectedSubscription)) {
                                                    rowSubscriptionMatch = true;
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            
                            if (rowSeverityMatch && rowCategoryMatch && rowFrameworkMatch && rowSearchMatch && rowSubscriptionMatch) {
                                hasMatchingControl = true;
                                hasMatchingSubscription = true;
                            }
                        });
                        
                        // Also check if the box itself has subscription match in its searchable text
                        const boxSubscriptionMatch = selectedSubscription === 'all' || searchableText.includes(selectedSubscription) || hasMatchingSubscription;
                        
                        if (severityMatch && categoryMatch && searchMatch && boxSubscriptionMatch && hasMatchingControl) {
                            box.style.display = 'block';
                            // Ensure content is still hidden if header is collapsed
                            const categoryId = box.querySelector('.category-header')?.getAttribute('data-category-id');
                            if (categoryId) {
                                const content = document.getElementById(categoryId);
                                if (content) {
                                    const header = box.querySelector('.category-header');
                                    if (header && header.classList.contains('collapsed')) {
                                        content.style.display = 'none';
                                    }
                                }
                            }
                            controlRowsInBox.forEach(row => {
                                const rowSeverity = row.getAttribute('data-severity-lower') || '';
                                const rowCategory = row.getAttribute('data-category-lower') || '';
                                const rowFrameworks = row.getAttribute('data-frameworks') || '';
                                const rowSearchable = row.getAttribute('data-searchable') || '';
                                
                                const rowSeverityMatch = selectedSeverity === 'all' || rowSeverity === selectedSeverity;
                                const rowCategoryMatch = selectedCategory === 'all' || rowCategory === selectedCategory;
                                const rowFrameworkMatch = selectedFramework === 'all' || rowFrameworks.includes(selectedFramework);
                                const rowSearchMatch = searchText === '' || rowSearchable.includes(searchText);
                                
                                // Check subscription match - subscription names are in the searchable text
                                let rowSubscriptionMatch = true;
                                if (selectedSubscription !== 'all') {
                                    // Subscription names are included in the searchable text (lowercased)
                                    rowSubscriptionMatch = rowSearchable.includes(selectedSubscription);
                                    
                                    // Also check resource detail rows for this control
                                    if (!rowSubscriptionMatch) {
                                        const controlKey = row.getAttribute('data-control-key');
                                        if (controlKey) {
                                            const resourcesRow = document.querySelector('.control-resources-row[data-control-key="' + controlKey + '"]');
                                            if (resourcesRow) {
                                                const resourceDetailRows = resourcesRow.querySelectorAll('.resource-detail-control-row');
                                                for (let resourceRow of resourceDetailRows) {
                                                    const resourceSearchable = resourceRow.getAttribute('data-searchable') || '';
                                                    if (resourceSearchable.includes(selectedSubscription)) {
                                                        rowSubscriptionMatch = true;
                                                        break;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                
                                if (rowSeverityMatch && rowCategoryMatch && rowFrameworkMatch && rowSearchMatch && rowSubscriptionMatch) {
                                    row.classList.remove('hidden');
                                    visibleCount++;
                                    // Keep resources row collapsed - only expand on click
                                    // But filter the individual resource rows inside if searching
                                    const controlKey = row.getAttribute('data-control-key');
                                    if (controlKey && searchText !== '') {
                                        const resourcesRow = document.querySelector('.control-resources-row[data-control-key="' + controlKey + '"]');
                                        if (resourcesRow) {
                                            // Only filter if the resources row is already expanded
                                            if (!resourcesRow.classList.contains('hidden')) {
                                                const resourceDetailRows = resourcesRow.querySelectorAll('.resource-detail-control-row');
                                                resourceDetailRows.forEach(resourceRow => {
                                                    const resourceSearchable = resourceRow.getAttribute('data-searchable') || '';
                                                    const resourceSearchMatch = resourceSearchable.includes(searchText);
                                                    if (resourceSearchMatch) {
                                                        resourceRow.classList.remove('hidden');
                                                    } else {
                                                        resourceRow.classList.add('hidden');
                                                        const resourceDetailKey = resourceRow.getAttribute('data-resource-detail-key');
                                                        if (resourceDetailKey) {
                                                            const remediationRow = document.querySelector('.remediation-row[data-parent-resource-detail-key="' + resourceDetailKey + '"]');
                                                            if (remediationRow) {
                                                                remediationRow.classList.add('hidden');
                                                            }
                                                        }
                                                    }
                                                });
                                            }
                                        }
                                    }
                                } else {
                                    row.classList.add('hidden');
                                    const controlKey = row.getAttribute('data-control-key');
                                    if (controlKey) {
                                        const resourcesRow = document.querySelector('.control-resources-row[data-control-key="' + controlKey + '"]');
                                        if (resourcesRow) {
                                            resourcesRow.classList.add('hidden');
                                        }
                                    }
                                    row.classList.remove('expanded');
                                }
                            });
                        } else {
                            box.style.display = 'none';
                        }
                    });
                    
                    // Helper function to recalculate severity card values based on subscription filter
                    function recalculateSeverityCards(selectedSub) {
                        const severityCards = document.querySelectorAll('.summary-card[data-severity]');
                        
                        severityCards.forEach(card => {
                            const severity = card.getAttribute('data-severity');
                            const cardSubscriptions = card.getAttribute('data-subscription') || '';
                            const originalValue = card.getAttribute('data-original-value') || '0';
                            const valueElement = card.querySelector('.summary-card-value');
                            
                            // Check if subscription matches
                            let subscriptionMatch = true;
                            if (selectedSubscription !== 'all' && cardSubscriptions) {
                                const subscriptionList = cardSubscriptions.toLowerCase().split('|');
                                subscriptionMatch = subscriptionList.includes(selectedSubscription);
                            }
                            
                            // Show/hide card based on subscription match
                            if (subscriptionMatch) {
                                card.style.display = '';
                                
                                // Update value based on subscription filter
                                if (selectedSub === 'all' || typeof subscriptionSeverityCounts === 'undefined') {
                                    // Show original value
                                    if (valueElement) valueElement.textContent = originalValue;
                                } else {
                                    // Look up subscription-specific count
                                    const subNameLower = selectedSub.toLowerCase();
                                    let subData = null;
                                    
                                    for (const [subName, data] of Object.entries(subscriptionSeverityCounts)) {
                                        if (subName.toLowerCase() === subNameLower) {
                                            subData = data;
                                            break;
                                        }
                                    }
                                    
                                    if (subData && valueElement) {
                                        const count = subData[severity] || 0;
                                        valueElement.textContent = count;
                                    } else if (valueElement) {
                                        valueElement.textContent = '0';
                                    }
                                }
                            } else {
                                card.style.display = 'none';
                            }
                        });
                    }
                    
                    // Helper function to recalculate score card values based on subscription filter
                    function recalculateScoreCard(card, selectedSub) {
                        const scoreValue = card.querySelector('.score-value');
                        const scoreDetails = card.querySelector('.score-details');
                        
                        if (selectedSub === 'all' || typeof subscriptionScores === 'undefined') {
                            // Show original values
                            const totalChecks = card.getAttribute('data-total-checks') || '0';
                            const passedChecks = card.getAttribute('data-passed-checks') || '0';
                            const overallScore = card.getAttribute('data-overall-score') || '0';
                            
                            if (scoreValue) scoreValue.textContent = overallScore + '%';
                            if (scoreDetails) scoreDetails.textContent = passedChecks + ' / ' + totalChecks + ' checks passed';
                            return;
                        }
                        
                        // For specific subscription, look up scores from subscriptionScores object
                        const subNameLower = selectedSub.toLowerCase();
                        let subData = null;
                        
                        // Find matching subscription (case-insensitive)
                        for (const [subName, data] of Object.entries(subscriptionScores)) {
                            if (subName.toLowerCase() === subNameLower) {
                                subData = data;
                                break;
                            }
                        }
                        
                        if (subData) {
                            // Determine which card type this is
                            if (card.classList.contains('overall-score')) {
                                // Overall score card
                                const score = subData.Score || 0;
                                const total = subData.Total || 0;
                                const passed = subData.Passed || 0;
                                
                                if (scoreValue) scoreValue.textContent = score + '%';
                                if (scoreDetails) scoreDetails.textContent = passed + ' / ' + total + ' checks passed';
                            } else if (card.classList.contains('l1-score')) {
                                // L1 score card
                                const score = subData.L1Score || 0;
                                const total = subData.L1Total || 0;
                                const passed = subData.L1Passed || 0;
                                
                                if (scoreValue) scoreValue.textContent = score + '%';
                                if (scoreDetails) scoreDetails.textContent = passed + ' / ' + total + ' checks passed';
                            } else if (card.classList.contains('l2-score')) {
                                // L2 score card
                                const score = subData.L2Score || 0;
                                const total = subData.L2Total || 0;
                                const passed = subData.L2Passed || 0;
                                
                                if (scoreValue) scoreValue.textContent = score + '%';
                                if (scoreDetails) scoreDetails.textContent = passed + ' / ' + total + ' checks passed';
                            } else if (card.classList.contains('asb-score')) {
                                // ASB score card
                                const score = subData.AsbScore || 0;
                                const total = subData.AsbTotal || 0;
                                const passed = subData.AsbPassed || 0;
                                
                                if (scoreValue) scoreValue.textContent = score + '%';
                                if (scoreDetails) scoreDetails.textContent = passed + ' / ' + total + ' checks passed';
                            }
                        } else {
                            // Subscription not found, show zeros or original values
                            if (scoreValue) scoreValue.textContent = '0%';
                            if (scoreDetails) scoreDetails.textContent = '0 / 0 checks passed';
                        }
                    }
                    
                    // Filter score cards (Overall Score, L1, L2, Category cards)
                    // Only filter by subscription - other filters don't affect score cards
                    const scoreCards = document.querySelectorAll('.score-card, .category-score-card');
                    let visibleScoreCards = 0;
                    let visibleMainScoreCards = 0; // Overall, L1, L2
                    let visibleCategoryScoreCards = 0;
                    
                    scoreCards.forEach(card => {
                        const cardSubscriptions = card.getAttribute('data-subscription') || '';
                        const isCategoryCard = card.classList.contains('category-score-card');
                        
                        // Only filter by subscription - ignore category, severity, framework, and search filters
                        let subscriptionMatch = true;
                        if (selectedSubscription !== 'all' && cardSubscriptions) {
                            // Check if the selected subscription is in the card's subscription list
                            // Subscriptions are pipe-separated, so split and check
                            const subscriptionList = cardSubscriptions.toLowerCase().split('|');
                            subscriptionMatch = subscriptionList.includes(selectedSubscription);
                        }
                        
                        if (subscriptionMatch) {
                            card.style.display = '';
                            visibleScoreCards++;
                            if (isCategoryCard) {
                                visibleCategoryScoreCards++;
                            } else {
                                visibleMainScoreCards++;
                                // Recalculate score for main cards based on subscription filter
                                recalculateScoreCard(card, selectedSubscription);
                            }
                        } else {
                            card.style.display = 'none';
                        }
                    });
                    
                    // Update severity cards based on subscription filter
                    recalculateSeverityCards(selectedSubscription);
                    
                    // Hide/show "Security Compliance Score" section header and main score grid
                    // Only hide if subscription filter hides all main cards
                    const complianceSection = document.querySelector('.compliance-scores-section');
                    const complianceHeader = complianceSection ? complianceSection.querySelector('h3') : null;
                    const scoreGrid = document.querySelector('.score-grid');
                    const categoryScoresHeader = document.querySelector('h4');
                    
                    if (complianceSection) {
                        if (visibleMainScoreCards > 0) {
                            if (complianceHeader) complianceHeader.style.display = '';
                            if (scoreGrid) scoreGrid.style.display = '';
                        } else {
                            if (complianceHeader) complianceHeader.style.display = 'none';
                            if (scoreGrid) scoreGrid.style.display = 'none';
                        }
                    }
                    
                    // Hide/show "Scores by Category" header and category scores grid
                    // Only hide if subscription filter hides all category cards
                    if (categoryScoresHeader && categoryScoresHeader.textContent.includes('Scores by Category')) {
                        if (visibleCategoryScoreCards > 0) {
                            categoryScoresHeader.style.display = '';
                            const categoryScoresGrid = categoryScoresHeader.nextElementSibling;
                            if (categoryScoresGrid && categoryScoresGrid.classList.contains('category-scores-grid')) {
                                categoryScoresGrid.style.display = '';
                            }
                        } else {
                            categoryScoresHeader.style.display = 'none';
                            const categoryScoresGrid = categoryScoresHeader.nextElementSibling;
                            if (categoryScoresGrid && categoryScoresGrid.classList.contains('category-scores-grid')) {
                                categoryScoresGrid.style.display = 'none';
                            }
                        }
                    }
                    
                    // Hide entire compliance section if subscription filter hides all cards
                    if (complianceSection && visibleScoreCards === 0) {
                        complianceSection.style.display = 'none';
                    } else if (complianceSection) {
                        complianceSection.style.display = '';
                    }
                    
                    // Update visible count, keep total count unchanged
                    const visibleCountSpan = document.getElementById('visibleCount');
                    if (visibleCountSpan) {
                        visibleCountSpan.textContent = visibleCount;
                    } else {
                        // Fallback for old structure
                        resultCount.textContent = 'Showing ' + visibleCount + ' items';
                    }
                    
                    // Ensure control-resources-row is hidden if control-row is not expanded
                    controlRows.forEach(row => {
                        const controlKey = row.getAttribute('data-control-key');
                        if (controlKey) {
                            const resourcesRow = document.querySelector('.control-resources-row[data-control-key="' + controlKey + '"]');
                            if (resourcesRow) {
                                if (!row.classList.contains('expanded')) {
                                    resourcesRow.classList.add('hidden');
                                }
                            }
                        }
                    });
                }
                
                function clearFilters() {
                    severityFilter.value = 'all';
                    categoryFilter.value = 'all';
                    frameworkFilter.value = 'all';
                    subscriptionFilter.value = 'all';
                    searchFilter.value = '';
                    updateFilters();
                }
                
                severityFilter.addEventListener('change', updateFilters);
                categoryFilter.addEventListener('change', updateFilters);
                frameworkFilter.addEventListener('change', updateFilters);
                subscriptionFilter.addEventListener('change', updateFilters);
                searchFilter.addEventListener('input', updateFilters);
                clearFiltersBtn.addEventListener('click', clearFilters);
                
                const summaryCards = document.querySelectorAll('.summary-card[data-severity]');
                summaryCards.forEach(card => {
                    card.style.cursor = 'pointer';
                    card.addEventListener('click', function() {
                        const severity = this.getAttribute('data-severity');
                        if (severity) {
                            severityFilter.value = severity;
                            updateFilters();
                            const filtersSection = document.querySelector('h2');
                            if (filtersSection) {
                                filtersSection.scrollIntoView({ behavior: 'smooth', block: 'start' });
                            }
                        }
                    });
                });
                
                // Make category score cards clickable to filter by category
                const categoryScoreCards = document.querySelectorAll('.category-score-card');
                categoryScoreCards.forEach(card => {
                    card.style.cursor = 'pointer';
                    card.addEventListener('click', function() {
                        const category = this.getAttribute('data-category');
                        const categoryLower = this.getAttribute('data-category-lower');
                        if (category && categoryFilter) {
                            // Set the category filter to the clicked category
                            categoryFilter.value = category;
                            updateFilters();
                            // Scroll to filters section
                            const filtersSection = document.querySelector('.section-box h2');
                            if (filtersSection) {
                                filtersSection.scrollIntoView({ behavior: 'smooth', block: 'start' });
                            }
                        }
                    });
                });

                // --- EOL Tracking filters ---
                const eolSearch = document.getElementById('eol-search');
                const eolSeverityFilter = document.getElementById('eol-severity-filter');
                const eolStatusFilter = document.getElementById('eol-status-filter');
                const eolResultCount = document.getElementById('eol-result-count');
                const eolItems = document.querySelectorAll('.eol-item');

                function updateEolFilters() {
                    if (!eolItems || eolItems.length === 0 || !eolResultCount) {
                        return;
                    }
                    const sev = eolSeverityFilter ? eolSeverityFilter.value.toLowerCase() : 'all';
                    const stat = eolStatusFilter ? eolStatusFilter.value.toLowerCase() : 'all';
                    const text = eolSearch ? eolSearch.value.toLowerCase().trim() : '';

                    let visible = 0;
                    eolItems.forEach(item => {
                        const itemSev = (item.getAttribute('data-severity') || '').toLowerCase();
                        const itemStat = (item.getAttribute('data-status') || '').toLowerCase();
                        const searchable = (item.getAttribute('data-searchable') || '').toLowerCase();

                        const sevMatch = (sev === 'all') || (itemSev === sev);
                        const statMatch = (stat === 'all') || (itemStat === stat);
                        const textMatch = (text === '') || searchable.includes(text);

                        if (sevMatch && statMatch && textMatch) {
                            item.style.display = 'block';
                            visible++;
                        } else {
                            item.style.display = 'none';
                        }
                    });

                    eolResultCount.textContent = 'Showing ' + visible + ' components';
                }

                if (eolSearch) {
                    eolSearch.addEventListener('input', updateEolFilters);
                }
                if (eolSeverityFilter) {
                    eolSeverityFilter.addEventListener('change', updateEolFilters);
                }
                if (eolStatusFilter) {
                    eolStatusFilter.addEventListener('change', updateEolFilters);
                }
                
                // Initialize: Hide all detail rows and nested rows FIRST, before setting up event listeners
                const allResourceDetailRows = document.querySelectorAll('.resource-detail-row');
                allResourceDetailRows.forEach(detailRow => {
                    detailRow.classList.add('hidden');
                });
                
                const allControlResourcesRows = document.querySelectorAll('.control-resources-row');
                allControlResourcesRows.forEach(resourcesRow => {
                    resourcesRow.classList.add('hidden');
                });
                
                const allRemediationRows = document.querySelectorAll('.remediation-row');
                allRemediationRows.forEach(remediationRow => {
                    remediationRow.classList.add('hidden');
                });
                
                // Remove expanded state from all rows
                resourceRows.forEach(row => {
                    row.classList.remove('expanded');
                });
                
                controlRows.forEach(row => {
                    row.classList.remove('expanded');
                });
                
                const allResourceDetailControlRows = document.querySelectorAll('.resource-detail-control-row');
                allResourceDetailControlRows.forEach(row => {
                    row.classList.remove('expanded');
                    // Ensure associated remediation-row is hidden
                    const resourceDetailKey = row.getAttribute('data-resource-detail-key');
                    if (resourceDetailKey) {
                        // Find the next sibling remediation-row
                        let nextSibling = row.nextElementSibling;
                        while (nextSibling) {
                            if (nextSibling.classList.contains('remediation-row') && 
                                nextSibling.getAttribute('data-parent-resource-detail-key') === resourceDetailKey) {
                                nextSibling.classList.add('hidden');
                                break;
                            }
                            nextSibling = nextSibling.nextElementSibling;
                        }
                    }
                });
                
                const allControlDetailRows = document.querySelectorAll('.control-detail-row');
                allControlDetailRows.forEach(row => {
                    row.classList.remove('expanded');
                    // Ensure associated remediation-row is hidden
                    const controlDetailKey = row.getAttribute('data-control-detail-key');
                    if (controlDetailKey) {
                        // Find the next sibling remediation-row
                        let nextSibling = row.nextElementSibling;
                        while (nextSibling) {
                            if (nextSibling.classList.contains('remediation-row') && 
                                nextSibling.getAttribute('data-parent-control-detail-key') === controlDetailKey) {
                                nextSibling.classList.add('hidden');
                                break;
                            }
                            nextSibling = nextSibling.nextElementSibling;
                        }
                    }
                });
                
                // Collapse all subscription and category boxes by default
                const allSubscriptionContents = document.querySelectorAll('.subscription-content:not(.category-content)');
                allSubscriptionContents.forEach(content => {
                    content.style.display = 'none';
                });
                
                const allCategoryContents = document.querySelectorAll('.category-content');
                allCategoryContents.forEach(content => {
                    content.style.display = 'none';
                });
                
                // Mark all subscription and category headers as collapsed
                const allSubscriptionHeaders = document.querySelectorAll('.subscription-header:not(.category-header)');
                allSubscriptionHeaders.forEach(header => {
                    header.classList.add('collapsed');
                });
                
                const allCategoryHeaders = document.querySelectorAll('.category-header');
                allCategoryHeaders.forEach(header => {
                    header.classList.add('collapsed');
                });
                
                // Ensure control-resources-row is hidden when control-row is not expanded
                controlRows.forEach(row => {
                    const controlKey = row.getAttribute('data-control-key');
                    if (controlKey) {
                        const resourcesRow = document.querySelector('.control-resources-row[data-control-key="' + controlKey + '"]');
                        if (resourcesRow && !row.classList.contains('expanded')) {
                            resourcesRow.classList.add('hidden');
                        }
                    }
                });
                
                // Initialize filters first
                updateFilters();
                
                // Subscription expand/collapse handlers
                const subscriptionHeaders = document.querySelectorAll('.subscription-header:not(.category-header)');
                subscriptionHeaders.forEach(header => {
                    header.addEventListener('click', function() {
                        const subscriptionId = this.getAttribute('data-subscription-id');
                        const content = document.getElementById(subscriptionId);
                        if (content) {
                            const isHidden = content.style.display === 'none' || content.style.display === '';
                            content.style.display = isHidden ? 'block' : 'none';
                            this.classList.toggle('collapsed', !isHidden);
                        }
                    });
                });
                
                // Ensure deprecated-components header is always clickable and visible
                const deprecatedHeader = document.querySelector('[data-subscription-id="deprecated-components"]');
                if (deprecatedHeader) {
                    deprecatedHeader.style.display = 'flex';
                    deprecatedHeader.style.cursor = 'pointer';
                    const deprecatedBox = deprecatedHeader.closest('.subscription-box');
                    if (deprecatedBox) {
                        deprecatedBox.style.display = 'block';
                        deprecatedBox.style.visibility = 'visible';
                        deprecatedBox.style.opacity = '1';
                    }
                }
                
                // Also ensure deprecated-components box is excluded from filter hiding
                const deprecatedBoxElement = document.querySelector('.subscription-box [data-subscription-id="deprecated-components"]')?.closest('.subscription-box');
                if (deprecatedBoxElement) {
                    deprecatedBoxElement.setAttribute('data-always-visible', 'true');
                }
                
                // Category expand/collapse handlers
                // Use event delegation and check that we're NOT clicking on a control-row
                document.addEventListener('click', function(event) {
                    const categoryHeader = event.target.closest('.category-header');
                    if (categoryHeader) {
                        // Make sure we're NOT clicking on a control-row inside the category
                        const controlRow = event.target.closest('.control-row');
                        if (!controlRow) {
                            // Only handle if clicking directly on header, not on control-row
                            event.stopPropagation();
                            const categoryId = categoryHeader.getAttribute('data-category-id');
                            const content = document.getElementById(categoryId);
                            if (content) {
                                const isCollapsed = categoryHeader.classList.contains('collapsed');
                                if (isCollapsed) {
                                    // Expanding - remove collapsed class and show content
                                    categoryHeader.classList.remove('collapsed');
                                    // Force display block to override CSS
                                    content.style.display = 'block';
                                    content.style.setProperty('display', 'block', 'important');
                                } else {
                                    // Collapsing - add collapsed class and hide content
                                    categoryHeader.classList.add('collapsed');
                                    content.style.display = 'none';
                                    content.style.setProperty('display', 'none', 'important');
                                }
                            }
                        }
                    }
                }, true); // Use capture phase
                
                // Resource row click handlers (for "Failed Controls by Subscription" section)
                resourceRows.forEach(row => {
                    row.addEventListener('click', function(event) {
                        // Stop event from bubbling to parent elements
                        event.stopPropagation();
                        const resourceKey = this.getAttribute('data-resource-key');
                        const detailRow = document.querySelector('.resource-detail-row[data-resource-key="' + resourceKey + '"]');
                        if (detailRow) {
                            detailRow.classList.toggle('hidden');
                            this.classList.toggle('expanded');
                        }
                    });
                });
                
                // Control row click handlers (Category & Control table) - expand/collapse resources
                // Use event delegation to ensure it works even when categories are collapsed
                // Must check control-row and stop propagation BEFORE category-header handles it
                document.addEventListener('click', function(event) {
                    // First check if click is on or inside a control-row
                    const controlRow = event.target.closest('.control-row');
                    if (controlRow) {
                        // Make sure we're not clicking on category-header itself
                        const clickedOnHeader = event.target.closest('.category-header');
                        // Only process if we're clicking on the control-row, not the header
                        if (!clickedOnHeader || clickedOnHeader !== controlRow.closest('.category-header')) {
                            event.stopPropagation();
                            event.preventDefault();
                            const controlKey = controlRow.getAttribute('data-control-key');
                            if (controlKey) {
                                const resourcesRow = document.querySelector('.control-resources-row[data-control-key="' + controlKey + '"]');
                                if (resourcesRow) {
                                    resourcesRow.classList.toggle('hidden');
                                    controlRow.classList.toggle('expanded');
                                    return false; // Stop here, don't let category-header handle it
                                }
                            }
                        }
                    }
                }, true); // Use capture phase to catch events before they bubble
                
                // Control detail row click handlers (Subscription Details table) - expand/collapse remediation
                const controlDetailRows = document.querySelectorAll('.control-detail-row');
                controlDetailRows.forEach(row => {
                    row.addEventListener('click', function(event) {
                        // Stop event from bubbling to parent elements (like resource-row)
                        event.stopPropagation();
                        const controlDetailKey = this.getAttribute('data-control-detail-key');
                        // Find the NEXT sibling remediation-row (more reliable than querySelector)
                        let nextSibling = this.nextElementSibling;
                        while (nextSibling) {
                            if (nextSibling.classList.contains('remediation-row') && 
                                nextSibling.getAttribute('data-parent-control-detail-key') === controlDetailKey) {
                                nextSibling.classList.toggle('hidden');
                                this.classList.toggle('expanded');
                                break;
                            }
                            nextSibling = nextSibling.nextElementSibling;
                        }
                    });
                });
                
                // Resource detail control row click handlers (Failed Controls by Category table) - expand/collapse remediation
                const resourceDetailControlRows = document.querySelectorAll('.resource-detail-control-row');
                resourceDetailControlRows.forEach(row => {
                    row.addEventListener('click', function(event) {
                        // Stop event from bubbling to parent elements
                        event.stopPropagation();
                        const resourceDetailKey = this.getAttribute('data-resource-detail-key');
                        // Find the NEXT sibling remediation-row (more reliable than querySelector)
                        let nextSibling = this.nextElementSibling;
                        while (nextSibling) {
                            if (nextSibling.classList.contains('remediation-row') && 
                                nextSibling.getAttribute('data-parent-resource-detail-key') === resourceDetailKey) {
                                nextSibling.classList.toggle('hidden');
                                this.classList.toggle('expanded');
                                break;
                            }
                            nextSibling = nextSibling.nextElementSibling;
                        }
                    });
                });
            }
            
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', initFilters);
            } else {
                initFilters();
            }

            // EOL section toggle helpers (used by Get-EOLReportSection)
            window.toggleEolSection = function() {
                const content = document.getElementById('eol-content');
                const icon = document.getElementById('eol-toggle-icon');
                if (!content || !icon) return;
                const isHidden = content.style.display === 'none';
                content.style.display = isHidden ? 'block' : 'none';
                icon.textContent = isHidden ? '▼' : '▲';
            };

            window.toggleEolItemDetails = function(headerEl) {
                const container = headerEl.closest('.eol-item');
                if (!container) return;
                const details = container.querySelector('.eol-item-details');
                const icon = headerEl.querySelector('.expand-icon');
                if (!details || !icon) return;
                const isHidden = details.style.display === 'none';
                details.style.display = isHidden ? 'block' : 'none';
                icon.textContent = isHidden ? '▲' : '▼';
            };
        })();
"@
        }
        default {
            return ""
        }
    }
}
