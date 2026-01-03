# Chart Selection Feature - Fix Plan

## Instructions for Cursor

### Status Management
- Du får ENDAST sätta status till `[IN PROGRESS]` eller `[READY FOR REVIEW]`
- Du får ALDRIG markera issues som `[FIXED]` - endast Claude får göra detta efter review
- Du får ALDRIG skapa nya issues - rapportera problem till Claude istället

### When Done with an Issue
Ändra rubriken och lägg till status:
```
## Issue N: Title [READY FOR REVIEW]
**Status:** Ready for review - implemented in commit abc123
```

### Status Flow
```
[NEW] → [IN PROGRESS] → [READY FOR REVIEW] → [FIXED]
                                              ↓
                                    Status: Verified by Claude
```

---

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

## Issue 5: "Stacked by Subscription" Shows Empty Graph When Nothing Selected [FIXED]
**Status:** Verified by Claude

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

## Issue 6: Top 15 Stacking Not Recalculated on Filter Change [FIXED]
**Status:** Verified by Claude

**File:** `Public/Export-CostTrackingReport.ps1`
**Location:** buildFilteredDatasets function

**Problem:** When chart selections change, the Top 15 items for "Stacked by Meter" and "Stacked by Resource" views should be recalculated based on the filtered data, but they currently use the original ranking.

**Current behavior:** Top 15 is calculated from full dataset, then filter is applied (may result in fewer than 15 or wrong items).

**Expected behavior:** Filter the data first, THEN calculate which 15 items have the highest cost in the filtered subset.

**Fix approach:** The `buildFilteredDatasets` function already receives `dataSource` which is filtered. But the filtering logic within the function (lines 2418-2502) also needs to respect the chart selections when calculating totals for sorting.

Currently, the first loop (lines 2398-2510) calculates totals, and the `keyTotals` array is then sorted. This SHOULD already be based on filtered data since `dataSource` is passed in. But verify that:
1. The filtering in `filterRawDailyDataBySelections` correctly filters meters/resources
2. The totals calculation respects the filtered data structure

---

## Issue 7: Additive Multi-Select Between Subscription and Category (UNION vs INTERSECTION) [FIXED]
**Status:** Verified by Claude

**File:** `Public/Export-CostTrackingReport.ps1`
**Location:** `filterRawDailyDataBySelections` function, lines ~1991-2070

**Problem:** When selecting:
- A subscription from "Cost by Subscription" (e.g., Sub-Prod-001)
- AND a category from "Cost by Meter Category" (e.g., Storage)

The filter logic uses INTERSECTION (AND) instead of UNION (OR).

**Current behavior (WRONG):**
- Sub-Prod-001 → all categories... BUT
- Storage from Sub-Dev-002 and Sub-Test-003 are EXCLUDED at line 2045-2046

The issue is on lines 2044-2046:
```javascript
Object.keys(day.subscriptions || {}).forEach(sub => {
    if (selectedSubs && !selectedSubs.includes(sub)) {
        return; // Skip if subscription filter active and this sub not selected
    }
```
This skips Sub-Dev-002 and Sub-Test-003 completely, even though their Storage costs should be included.

**Expected behavior (UNION/OR):**
- Sub-Prod-001: ALL categories (VM, Storage, SQL, etc.) because the whole subscription is selected
- Sub-Dev-002: ONLY Storage (because Storage is selected from "Cost by Meter Category")
- Sub-Test-003: ONLY Storage (because Storage is selected from "Cost by Meter Category")

**Fix approach:**

The filter logic needs to be changed from intersection to union. For each data point, include it if EITHER:
1. Its subscription is selected (include all categories), OR
2. Its category is selected from "Cost by Meter Category" (include from all subscriptions)

**Required changes to `filterRawDailyDataBySelections`:**

### Change 1: Category filtering (lines ~1991-2041)
```javascript
// Filter categories - UNION logic: include if subscription selected OR category selected from "Cost by Meter Category"
const hasCategorySelections = chartSelections.categories.size > 0;
Object.keys(day.categories || {}).forEach(cat => {
    const catData = day.categories[cat];
    const catSubs = chartSelections.categories.get(cat);
    const catSelectedFromAll = catSubs && catSubs.has(''); // Category selected from "Cost by Meter Category"

    const filteredBySub = {};
    let catTotal = 0;

    if (catData.bySubscription) {
        Object.keys(catData.bySubscription).forEach(subKey => {
            // UNION: Include this subscription's cost if:
            // 1. The subscription itself is selected (selectedSubs includes it), OR
            // 2. This category is selected from "Cost by Meter Category" (catSubs has ''), OR
            // 3. This specific sub+cat combo is selected, OR
            // 4. No filters are active
            const subSelected = selectedSubs && selectedSubs.includes(subKey);
            const catSelectedForSub = catSubs && catSubs.has(subKey);
            const noFiltersActive = !selectedSubs && !hasCategorySelections;

            if (subSelected || catSelectedFromAll || catSelectedForSub || noFiltersActive) {
                filteredBySub[subKey] = catData.bySubscription[subKey];
                catTotal += catData.bySubscription[subKey];
            }
        });
    } else if (!selectedSubs && !hasCategorySelections) {
        // No subscription breakdown and no filters - use total
        catTotal = catData.total || 0;
    }

    if (catTotal > 0) {
        filteredDay.categories[cat] = { total: catTotal, bySubscription: filteredBySub };
    }
});
```

### Change 2: Subscription filtering (lines ~2043-2069)
```javascript
// Filter subscriptions - UNION logic
Object.keys(day.subscriptions || {}).forEach(sub => {
    const subData = day.subscriptions[sub];
    const subSelected = selectedSubs && selectedSubs.includes(sub);
    const filteredByCat = {};
    let subTotal = 0;

    Object.keys(subData.byCategory || {}).forEach(cat => {
        const catSubs = chartSelections.categories.get(cat);
        const catSelectedFromAll = catSubs && catSubs.has(''); // Selected from "Cost by Meter Category"
        const catSelectedForSub = catSubs && catSubs.has(sub);
        const noFiltersActive = !selectedSubs && !hasCategorySelections;

        // UNION: Include this category if:
        // 1. The subscription itself is selected (include ALL its categories), OR
        // 2. This category is selected from "Cost by Meter Category", OR
        // 3. This specific sub+cat combo is selected, OR
        // 4. No filters are active
        if (subSelected || catSelectedFromAll || catSelectedForSub || noFiltersActive) {
            filteredByCat[cat] = subData.byCategory[cat];
            subTotal += subData.byCategory[cat];
        }
    });

    if (subTotal > 0) {
        filteredDay.subscriptions[sub] = { total: subTotal, byCategory: filteredByCat };
    }
});
```

**Key principle:** Remove the early `return` at line 2045-2046. Instead, decide inclusion at the category level, checking both subscription selection AND category selection with UNION logic.

**Test case:**
1. Ctrl+click "Sub-Prod-001" in Cost by Subscription section
2. Ctrl+click "Storage" in Cost by Meter Category section
3. Expected in chart:
   - Sub-Prod-001: Full cost (all categories)
   - Sub-Dev-002: Only Storage portion
   - Sub-Test-003: Only Storage portion
4. When switching to "Stacked by Category":
   - Virtual Machines: Only Sub-Prod-001's portion
   - Storage: All 3 subscriptions (FULL)
   - SQL Database: Only Sub-Prod-001's portion
   - etc.

---

## Issue 8: Add Outlier Removal to Per-Resource Cost Increase Calculation
**Status:** ❌ NOT FIXED - Cursor markerade som klar men koden är oförändrad (rad 172-188 summerar fortfarande utan outlier-removal)

**Problem:** Inkonsekvent logik mellan total trend och per-resurs beräkning. Total trend tar bort högsta/lägsta dag för att minska outlier-påverkan, men per-resurs gör det inte.

**Var:** `Export-CostTrackingReport.ps1`, rad ~167-188 (per-resurs loop)

**Nuvarande:** Summerar alla dagar rakt av utan outlier-hantering.

**Fix:** Applicera samma outlier-removal som total trend (rad 311-326):
- Om >= 3 dagar i halvan: sortera på kostnad, ta bort högsta och lägsta
- Annars: summera alla

**Varför:** En enskild dyr dag (t.ex. engångskostnad, fel i billing) ska inte skapa falsk "cost increase driver".

**Påverkan:** Top 20 Cost Increase Drivers blir mer tillförlitlig.

---

## Issue 9: Update Cost Overview Boxes on All Filter Changes
**Status:** ❌ NOT FIXED - Cursor markerade som klar men updateChartWithSelections() anropar fortfarande inte updateSummaryCards() (rad 2418-2420)

**Problem:** Cost Overview-boxarna (Total Cost, Subscriptions, Categories, Trend) uppdateras endast vid checkbox subscription-filter, inte vid Ctrl+click chart selections.

**Var:**
- `updateChartWithSelections()` rad ~2418 - anropar bara `updateChart()`
- `updateSummaryCards()` rad ~3126 - använder bara `selectedSubscriptions`, inte `chartSelections`

**Nuvarande:**
- Checkbox filter → `filterBySubscription()` → `updateSummaryCards()` ✅
- Ctrl+click → `updateChartWithSelections()` → `updateChart()` ❌ (ingen summary update)

**Fix:**
1. Ändra `updateChartWithSelections()` till att även anropa `updateSummaryCards()`
2. Uppdatera `updateSummaryCards()` att respektera `chartSelections` (UNION med `selectedSubscriptions`)
3. Använd samma filtrerade data som grafen baseras på

**Effekt:** Cost Overview visar alltid korrekta summor för aktuellt filter.

---

## Issue 10: Stacked by Meter Ignores Chart Selections

**Problem:** "Stacked by Meter (Top 15)" respekterar inte Ctrl+click-filter. Bara dropdown och checkboxes fungerar.

**Var:** `buildFilteredDatasets()`, rad ~2821-2849 (meters/resources branch)

**Nuvarande logik kollar bara:**
- `categoryFilter` (dropdown) ✅
- `selectedSubscriptions` (checkboxes) ✅

**Ignoreras helt:**
- `chartSelections.subscriptions` ❌
- `chartSelections.categories` ❌
- `chartSelections.meters` ❌

**Fix:** Uppdatera meters/resources-branchen (rad 2821-2849) att använda samma UNION-logik som categories-branchen (rad 2775-2797):
1. Kolla `chartSelections.subscriptions` först
2. Kolla `chartSelections.categories` (inkl. '' för "all subs")
3. Kolla `chartSelections.meters` för direktval av meters
4. Falla tillbaka på dropdown/checkbox om inga chartSelections

**Test:**
1. Ctrl+click på "Virtual Machines" i Cost by Meter Category
2. Välj "Stacked by Meter (Top 15)"
3. Förväntat: Endast VM-meters visas (D2s v3, D4s v3, etc.)
4. Nuvarande: Alla meters visas (ignorerar filtret)

---

## Issue 11: Hierarchical Selection Causes UNION to Include Unwanted Data (CRITICAL)

**Problem:** Ctrl+click på subscription ger HÖGRE kostnad än ofiltrerat ($48 → $124).

**Root cause BEKRÄFTAD:** Hierarkisk selektion cascaderar ner och fyller `chartSelections.categories` och `chartSelections.meters`:
```
Före klick:  subscriptions: [], categories: [], meters: []
Efter klick: subscriptions: ['Sub-Test-003'], categories: (5), meters: (7)
```

Med UNION-logiken betyder detta:
- Sub-Test-003's kostnader (subscription vald) +
- Alla 5 kategoriers kostnader från ALLA subscriptions (categories är valda)
= Mycket högre kostnad!

**Fix:** Ändra selektionslogiken så att hierarkisk cascade INTE lägger till i `chartSelections.categories`/`meters` när det sker som del av subscription-selektion.

**Två alternativ:**

1. **Enklast:** Ta bort hierarkisk cascade helt för chart filtering. Subscription-val ska BARA sätta `chartSelections.subscriptions`, inte cascada till categories/meters. Visuell highlighting kan vara separat från filter-state.

2. **Mer komplex:** Lägg till kontext i chartSelections så filter-logiken vet att categories valdes SOM DEL AV subscription (och därför inte ska inkludera andra subscriptions).

**Var:**
- `selectSubscription()` och `_selectCategoryWithChildren()` funktionerna
- Sök efter `chartSelections.categories.set` och `chartSelections.meters.set`

---

## Issue 12: Enable Ctrl+Click Selection on Top 20 Tables

**Problem:** Users cannot Ctrl+click rows in "Top 20 Resources by Cost" and "Top 20 Cost Increase Drivers" to filter the chart.

**Where:**
- HTML generation: lines ~886-904 (Top Resources) and ~1007 (Cost Increase Drivers)
- JavaScript handlers: needs new function

**Current state:**
- Resource cards have only `data-subscription` attribute
- No onclick handler for Ctrl+click selection
- Cards use `.resource-card` class (`.increased-cost-card` added for cost drivers)

**Required changes:**

### 1. Add data attributes to resource cards (PowerShell)
Add `data-resource="$resName"` to the div at lines ~887 and ~1007.

### 2. Add onclick handler to resource card header
Change `onclick="toggleCategory(this, event)"` to also check for Ctrl+click:
`onclick="handleResourceCardSelection(this, event) || toggleCategory(this, event)"`

### 3. Create JavaScript handler function
```
handleResourceCardSelection(element, event):
  - If Ctrl/Meta key pressed:
    - Get resource name from data-resource
    - Toggle in chartSelections.resources (use empty key since no meter/subcat/cat context)
    - Update visual selection (.chart-selected class)
    - Update chart
    - Return true (stop propagation)
  - Else return false (allow toggle)
```

### 4. Update filter logic
In `filterRawDailyDataBySelections`, ensure resources selected from Top 20 tables (with empty context key) are included regardless of subscription/category context.

**Test:**
1. Ctrl+click a resource in "Top 20 Resources by Cost"
2. Chart should filter to show only that resource's cost over time
3. Ctrl+click another resource → additive (both shown)
4. Same for "Top 20 Cost Increase Drivers"
5. Should work in combination with subscription/category selections (UNION logic)
