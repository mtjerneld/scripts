# Chart Selection Feature - Fix Plan

## Problem Summary
The Ctrl+Click chart selection/filtering feature in the Cost Tracking report is not working properly:
1. Clicking on lower levels (L3/L4 - subcategory/meter) partially works
2. Clicking on higher levels (L1/L2 - subscription/category) causes page hang
3. Chart reloads but doesn't show filtered data

## Root Cause Analysis

### Issue 1: Missing Data Attributes on Subcategory Elements [FIXED]
**Status:** Fixed by Cursor

### Issue 2: Cascading Update Calls Causing Page Hang (CRITICAL) [FIXED]
**Status:** Fixed by Cursor
**File:** `Public/Export-CostTrackingReport.ps1`
**Location:** Lines 2928-3248 (selection functions)

**Problem:** Every selection function calls `updateChartSelectionsVisual()` and `updateChartWithSelections()` at the end. When hierarchical selection cascades down:

```
selectSubscription()
  → selectCategory() [calls update]
    → selectSubcategory() [calls update]
      → selectMeter() [calls update]
        → selectResource() [calls update]
```

With 3 subscriptions × 5 categories × 3 subcategories × 4 meters × 10 resources = **hundreds of update calls**, causing the hang.

### Issue 3: querySelectorAll Matches Too Many Elements [FIXED]
**Status:** Fixed by Cursor
**File:** `Public/Export-CostTrackingReport.ps1`
**Location:** Lines 2933, 3020, 3107, 3178

When `selectSubscription` runs `querySelectorAll('[data-subscription="Sub-Dev-002"]')`, it matches:
- Subscription card (1)
- All category cards with that subscription (5+)
- All subcategory drilldowns with that subscription (15+)
- All meter cards with that subscription (60+)
- All meter headers with that subscription (60+)
- All resource rows with that subscription (600+)

Each match triggers `getCategoryFromElement()` → `selectCategory()`, so the same category gets selected multiple times through different DOM paths.

---

## Fix Steps

### Step 1: Create Internal Selection Functions (No Update)
Create `_internal` versions that don't call update functions:

```javascript
// Internal versions - no update calls
function _selectSubscriptionInternal(subscription) {
    if (!subscription) return;
    chartSelections.subscriptions.add(subscription);
}

function _selectCategoryInternal(category, subscription) {
    if (!category) return;
    if (!chartSelections.categories.has(category)) {
        chartSelections.categories.set(category, new Set());
    }
    chartSelections.categories.get(category).add(subscription);
}

function _selectSubcategoryInternal(subcategory, category, subscription) {
    if (!subcategory) return;
    const key = createSelectionKey(category, subscription || '');
    if (!chartSelections.subcategories.has(subcategory)) {
        chartSelections.subcategories.set(subcategory, new Set());
    }
    chartSelections.subcategories.get(subcategory).add(key);
}

function _selectMeterInternal(meter, subcategory, category, subscription) {
    if (!meter) return;
    const key = createSelectionKey(subcategory, category, subscription);
    if (!chartSelections.meters.has(meter)) {
        chartSelections.meters.set(meter, new Set());
    }
    chartSelections.meters.get(meter).add(key);
}

function _selectResourceInternal(resource, meter, subcategory, category, subscription) {
    if (!resource) return;
    const key = createSelectionKey(meter, subcategory, category, subscription);
    if (!chartSelections.resources.has(resource)) {
        chartSelections.resources.set(resource, new Set());
    }
    chartSelections.resources.get(resource).add(key);
}
```

### Step 2: Refactor Hierarchical Selection to Use Specific Selectors
Instead of querying all elements with data-subscription, query only direct children:

```javascript
function selectSubscription(subscription) {
    if (!subscription) return;
    _selectSubscriptionInternal(subscription);

    // Only select category-cards that are DIRECT children (not all elements with data-subscription)
    const subscriptionCard = document.querySelector('.subscription-card[data-subscription="' + subscription + '"]');
    if (subscriptionCard) {
        // Find category cards within this subscription's content
        subscriptionCard.querySelectorAll(':scope > .category-content > .category-card[data-category]').forEach(catCard => {
            const category = catCard.getAttribute('data-category');
            if (category) {
                _selectCategoryWithChildren(category, subscription);
            }
        });
    }

    updateChartSelectionsVisual();
    updateChartWithSelections();
}

function _selectCategoryWithChildren(category, subscription) {
    _selectCategoryInternal(category, subscription);

    // Find the category card and get its subcategories
    const selector = '.category-card[data-category="' + category + '"][data-subscription="' + subscription + '"]';
    const categoryCard = document.querySelector(selector);
    if (categoryCard) {
        categoryCard.querySelectorAll(':scope > .category-content > .subcategory-drilldown[data-subcategory]').forEach(subcatEl => {
            const subcategory = subcatEl.getAttribute('data-subcategory');
            if (subcategory) {
                _selectSubcategoryWithChildren(subcategory, category, subscription);
            }
        });
    }
}

function _selectSubcategoryWithChildren(subcategory, category, subscription) {
    _selectSubcategoryInternal(subcategory, category, subscription);

    // Find meters within this subcategory
    const selector = '.subcategory-drilldown[data-subcategory="' + subcategory + '"][data-category="' + category + '"][data-subscription="' + subscription + '"]';
    const subcatEl = document.querySelector(selector);
    if (subcatEl) {
        subcatEl.querySelectorAll(':scope > .subcategory-content > .meter-card[data-meter]').forEach(meterEl => {
            const meter = meterEl.getAttribute('data-meter');
            if (meter) {
                _selectMeterWithChildren(meter, subcategory, category, subscription);
            }
        });
    }
}

function _selectMeterWithChildren(meter, subcategory, category, subscription) {
    _selectMeterInternal(meter, subcategory, category, subscription);

    // Find resources within this meter
    const selector = '.meter-card[data-meter="' + meter + '"][data-subcategory="' + subcategory + '"][data-category="' + category + '"][data-subscription="' + subscription + '"]';
    const meterEl = document.querySelector(selector);
    if (meterEl) {
        meterEl.querySelectorAll('tr[data-resource]').forEach(resEl => {
            const resource = resEl.getAttribute('data-resource');
            if (resource) {
                _selectResourceInternal(resource, meter, subcategory, category, subscription);
            }
        });
    }
}
```

### Step 3: Update Public Selection Functions
Modify the public selection functions to use internal helpers and only call update once:

```javascript
function selectCategory(category, subscription) {
    if (!category) return;
    _selectCategoryWithChildren(category, subscription);
    updateChartSelectionsVisual();
    updateChartWithSelections();
}

function selectSubcategory(subcategory, category, subscription) {
    if (!subcategory) return;
    _selectSubcategoryWithChildren(subcategory, category, subscription);
    updateChartSelectionsVisual();
    updateChartWithSelections();
}

function selectMeter(meter, subcategory, category, subscription) {
    if (!meter) return;
    _selectMeterWithChildren(meter, subcategory, category, subscription);
    updateChartSelectionsVisual();
    updateChartWithSelections();
}

function selectResource(resource, meter, subcategory, category, subscription) {
    if (!resource) return;
    _selectResourceInternal(resource, meter, subcategory, category, subscription);
    updateChartSelectionsVisual();
    updateChartWithSelections();
}
```

### Step 4: Do the Same for Deselect Functions
Apply the same pattern to deselect functions - use internal helpers, only update once at the end.

---

## Testing Plan

1. Regenerate test data: `pwsh -Command "Import-Module .\AzureSecurityAudit.psd1 -Force; .\Tools\New-TestData.ps1"`
2. Generate cost tracking report: `pwsh -Command ".\Tools\Test-SingleReport.ps1 -ReportType CostTracking"`
3. Open `test-output/costtracking.html` in browser
4. Test Ctrl+Click on each level:
   - **L1 Subscription**: Should NOT hang, should highlight subscription + all children, chart should filter
   - **L2 Category**: Should NOT hang, should highlight category + children, chart should filter
   - **L3 Subcategory**: Should highlight + children, chart should filter
   - **L4 Meter**: Should highlight + children, chart should filter
   - **L5 Resource**: Should highlight row, chart should filter
5. Verify:
   - No page hang on any level
   - Elements get `.chart-selected` class applied
   - Clear button appears
   - Chart updates to show only selected data
   - Ctrl+Click again deselects (toggle behavior)

---

## Summary of Changes

| Location | Change |
|----------|--------|
| Lines ~2928-2942 | Replace `selectSubscription` with version using internal helpers |
| Lines ~3012-3030 | Replace `selectCategory` with version using internal helpers |
| Lines ~3098-3117 | Replace `selectSubcategory` with version using internal helpers |
| Lines ~3169-3188 | Replace `selectMeter` with version using internal helpers |
| Lines ~3223-3233 | Replace `selectResource` with version using internal helpers |
| New functions | Add `_selectXxxInternal` and `_selectXxxWithChildren` helpers |
| Deselect functions | Same pattern for deselect |

---

## Key Principles

1. **Single Update**: Only call `updateChartSelectionsVisual()` and `updateChartWithSelections()` ONCE per user action
2. **Targeted Queries**: Use `:scope >` selector to get direct children only, not all descendants
3. **No Duplicate Selection**: Query specific element types (`.category-card`, `.subcategory-drilldown`, etc.) not just data attributes
4. **Internal vs Public**: Internal functions handle data structure updates; public functions handle UI updates

---

## Issue 4: Filter Logic Inverted (Shows Everything EXCEPT Selected) [FIXED]
**Status:** Fixed by Cursor

**File:** `Public/Export-CostTrackingReport.ps1`
**Location:** Lines 1991-2026 (filterRawDailyDataBySelections - category filtering)

**Problem:** When a category is selected, other categories are still included because the `else if` branch doesn't check if there are active category selections.

**Current (broken) logic:**
```javascript
Object.keys(day.categories || {}).forEach(cat => {
    const catSubs = chartSelections.categories.get(cat);
    if (catSubs && catSubs.size > 0) {
        // Category IS selected - include it ✓
    } else if (!selectedSubs || ...) {
        // Category NOT selected, but still included if no subscription filter! ✗
        filteredDay.categories[cat] = catData;
    }
});
```

**Fixed logic:**
```javascript
Object.keys(day.categories || {}).forEach(cat => {
    const catData = day.categories[cat];
    const catSubs = chartSelections.categories.get(cat);

    // Check if there are ANY category selections active
    const hasCategorySelections = chartSelections.categories.size > 0;

    if (catSubs && catSubs.size > 0) {
        // This category IS selected - include it (filtered by selected subscriptions)
        const filteredBySub = {};
        let catTotal = 0;
        catSubs.forEach(sub => {
            if (catData.bySubscription && catData.bySubscription[sub]) {
                filteredBySub[sub] = catData.bySubscription[sub];
                catTotal += catData.bySubscription[sub];
            }
        });
        if (catTotal > 0) {
            filteredDay.categories[cat] = { total: catTotal, bySubscription: filteredBySub };
        }
    } else if (!hasCategorySelections) {
        // No category selections active - include based on subscription filter only
        if (selectedSubs) {
            const filteredBySub = {};
            let catTotal = 0;
            selectedSubs.forEach(sub => {
                if (catData.bySubscription && catData.bySubscription[sub]) {
                    filteredBySub[sub] = catData.bySubscription[sub];
                    catTotal += catData.bySubscription[sub];
                }
            });
            if (catTotal > 0) {
                filteredDay.categories[cat] = { total: catTotal, bySubscription: filteredBySub };
            }
        } else {
            filteredDay.categories[cat] = catData;
        }
    }
    // else: category selections exist but this category is NOT selected - exclude it
});
```

**The same pattern needs to be applied to:**
- Subscription filtering (lines 2028-2055)
- Meter filtering (lines 2057-2089)
- Resource filtering (lines 2091-2127)

**Key change:** Add a check for whether there are active selections at each level. If there ARE selections and this item is NOT selected, exclude it. Only include unselected items when there are NO selections at that level.

---

## Issue 5: "Stacked by Subscription" Shows Empty Graph When Nothing Selected

**File:** `Public/Export-CostTrackingReport.ps1`
**Location:** buildFilteredDatasets function (lines ~2385-2620)

**Problem:** When no Ctrl+click selections and no checkbox selections are active, switching to "Stacked by Subscription" view shows an empty chart.

**Expected behavior:** Should show all subscriptions stacked by their total costs.

**Root cause analysis:**
- `filterRawDailyDataBySelections` has correct early return at lines 1971-1973 (when no selections, returns original data)
- The Issue 4 fix added `hasCategorySelections` checks in `buildFilteredDatasets`
- When `dimension === 'subscriptions'` and `hasCategorySelections === false` and `categoryFilter === 'all'`:
  - Should use `value = dimData.total || 0` (line 2461)
  - This SHOULD work, so the issue might be:
    1. `dimData` is undefined (subscriptions not in rawDailyData)
    2. `dimData.total` is 0 or undefined
    3. Something else in the Issue 4 fix broke the base case

**Quick fix to try:**
The Issue 4 fix might have accidentally broken something. Check if the second pass (lines 2519-2614) in `buildFilteredDatasets` has similar logic that was changed. Line 2537-2558 handles subscriptions in the second pass:

```javascript
} else if (dimension === 'subscriptions') {
    const hasCategorySelections = chartSelections.categories.size > 0;

    if (hasCategorySelections) {
        // This should NOT execute when hasCategorySelections is false
        ...
    } else if (categoryFilter === 'all') {
        value = dimData.total || 0;  // This should execute
    } else {
        ...
    }
}
```

**Debugging steps:**
Add console.log at line 2521:
```javascript
topKeys.forEach(key => {
    const keyData = data.map((day, dayIndex) => {
        const dimData = day[dimension] && day[dimension][key];
        console.log(`Day ${dayIndex}, ${dimension}[${key}]:`, dimData);  // ADD THIS
        if (!dimData) return 0;
```

Also add console.log at line 2507-2508:
```javascript
if (totalCost > 0) {
    console.log(`Adding ${key} with totalCost ${totalCost}`);  // ADD THIS
    keyTotals.push({ key: key, totalCost: totalCost });
}
```

**Verify the data structure:** Open browser console and run:
```javascript
console.log('rawDailyData[0].subscriptions:', rawDailyData[0]?.subscriptions);
```

This should show the subscriptions object. If it's empty/undefined, the issue is in the PowerShell data generation.

---

## Issue 6: Top 15 Stacking Not Recalculated on Filter Change

**File:** `Public/Export-CostTrackingReport.ps1`
**Location:** buildFilteredDatasets function

**Problem:** When chart selections change, the Top 15 items for "Stacked by Meter" and "Stacked by Resource" views should be recalculated based on the filtered data, but they currently use the original ranking.

**Current behavior:** Top 15 is calculated from full dataset, then filter is applied (may result in fewer than 15 or wrong items).

**Expected behavior:** Filter the data first, THEN calculate which 15 items have the highest cost in the filtered subset.

**Fix approach:** The `buildFilteredDatasets` function already receives `dataSource` which is filtered. But the filtering logic within the function (lines 2418-2502) also needs to respect the chart selections when calculating totals for sorting.

Currently, the first loop (lines 2398-2510) calculates totals, and the `keyTotals` array is then sorted. This SHOULD already be based on filtered data since `dataSource` is passed in. But verify that:
1. The filtering in `filterRawDailyDataBySelections` correctly filters meters/resources
2. The totals calculation respects the filtered data structure
