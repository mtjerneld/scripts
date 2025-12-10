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
                        controlRowsInBox.forEach(row => {
                            const rowSeverity = row.getAttribute('data-severity-lower') || '';
                            const rowCategory = row.getAttribute('data-category-lower') || '';
                            const rowFrameworks = row.getAttribute('data-frameworks') || '';
                            const rowSearchable = row.getAttribute('data-searchable') || '';
                            
                            const rowSeverityMatch = selectedSeverity === 'all' || rowSeverity === selectedSeverity;
                            const rowCategoryMatch = selectedCategory === 'all' || rowCategory === selectedCategory;
                            const rowFrameworkMatch = selectedFramework === 'all' || rowFrameworks.includes(selectedFramework);
                            const rowSearchMatch = searchText === '' || rowSearchable.includes(searchText);
                            
                            if (rowSeverityMatch && rowCategoryMatch && rowFrameworkMatch && rowSearchMatch) {
                                hasMatchingControl = true;
                            }
                        });
                        
                        if (severityMatch && categoryMatch && searchMatch && hasMatchingControl) {
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
                                
                                if (rowSeverityMatch && rowCategoryMatch && rowFrameworkMatch && rowSearchMatch) {
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
                    
                    resultCount.textContent = 'Showing ' + visibleCount + ' items';
                    
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
                const categoryHeaders = document.querySelectorAll('.category-header');
                categoryHeaders.forEach(header => {
                    header.addEventListener('click', function() {
                        const categoryId = this.getAttribute('data-category-id');
                        const content = document.getElementById(categoryId);
                        if (content) {
                            const isHidden = content.style.display === 'none';
                            content.style.display = isHidden ? 'block' : 'none';
                            this.classList.toggle('collapsed', !isHidden);
                        }
                    });
                });
                
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
                controlRows.forEach(row => {
                    row.addEventListener('click', function() {
                        const controlKey = this.getAttribute('data-control-key');
                        if (controlKey) {
                            const resourcesRow = document.querySelector('.control-resources-row[data-control-key="' + controlKey + '"]');
                            if (resourcesRow) {
                                resourcesRow.classList.toggle('hidden');
                                this.classList.toggle('expanded');
                            }
                        }
                    });
                });
                
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
        })();
"@
        }
        default {
            return ""
        }
    }
}
