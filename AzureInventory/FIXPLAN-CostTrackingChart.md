# FIXPLAN: Cost Tracking Chart Issues

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

## Background

The Cost Tracking report has multiple bugs in the JavaScript chart filtering logic. When users click table rows to filter (e.g., select subscription "L2", then category "SQL"), the charts show inconsistent values because different code paths use different filtering logic.

**File:** `Public/Export-CostTrackingReport.ps1`
**Affected lines:** ~2041-3567 (JavaScript section)

---

## Issue 1: Undefined Variable in Meter Filtering [FIXED]

**Status:** ✅ Verified by Claude - correctly uses `meter` instead of `key` on line 2241

**Severity:** Critical
**Problem:** Line ~2232 uses undefined variable `key` instead of `meter`
**Where:** `filterRawDailyDataBySelections()` function, meters section

**Current code (approximate line 2232):**
```javascript
if (resourceMeters.has(key)) {  // BUG: 'key' is undefined here
    shouldInclude = true;
```

**Fix:** Change `key` to `meter`:
```javascript
if (resourceMeters.has(meter)) {
    shouldInclude = true;
```

**Test:**
1. Select a resource from Top 20 Resources table
2. Switch to "Top 20 Meters" view
3. Verify meters are correctly filtered to only those used by selected resource

---

## Issue 2: Total Cost Mode Ignores Filter Intersection [FIXED]

**Status:** ✅ Verified by Claude - proper intersection logic with 4 cases (both/sub-only/cat-only/none) on lines 2788-2889

**Severity:** Critical
**Problem:** When subscription AND category are both selected via table clicks, Total Cost shows union instead of intersection
**Where:** `updateChart()` function, lines ~2740-2849 (view === 'total')

**Current behavior:**
- Click "L2" subscription → shows 400kr/day (L2 total)
- Click "SQL" category → shows 900kr/day (ALL SQL, not just L2+SQL)

**Root cause:** Lines 2771-2807 have separate `if/else if` branches for subscription-only vs category-only, but don't properly intersect both when both exist.

**Fix approach:**
The Total Cost calculation should be refactored to:
1. Start with ALL data
2. Filter by subscription selections (if any)
3. Filter by category selections (if any) - INTERSECT, not separate path
4. Filter by resource selections (if any)
5. Calculate totals from the fully filtered result

**Pseudocode for fix:**
```javascript
// In Total Cost mode (view === 'total'):
dates.forEach(date => {
    const dayData = dataToUse[date];
    if (!dayData || !dayData.ByCategory) return;

    let dayTotal = 0;

    Object.entries(dayData.ByCategory).forEach(([cat, catData]) => {
        // Check if category should be included
        const categoryIncluded = !hasCategorySelections || chartSelections.categories.has(cat);
        if (!categoryIncluded) return;

        // Get subscriptions to include for this category
        let subsToInclude;
        if (hasSubscriptionSelections) {
            // Intersect: only subs that are in chartSelections.subscriptions
            subsToInclude = [...chartSelections.subscriptions].filter(sub =>
                catData.bySubscription && catData.bySubscription[sub] !== undefined
            );
        } else if (hasCategorySelections && chartSelections.categories.has(cat)) {
            // Category selected - use its associated subscriptions
            subsToInclude = [...(chartSelections.categories.get(cat) || [])];
        } else {
            // No filters - include all subscriptions
            subsToInclude = Object.keys(catData.bySubscription || {});
        }

        // Sum costs for included subscriptions
        subsToInclude.forEach(sub => {
            const cost = getCostValue(catData.bySubscription?.[sub]);
            dayTotal += cost;
        });
    });

    totalData.push({ x: date, y: dayTotal });
});
```

**Test:**
1. Click subscription "L2" in Subscription table
2. Verify Total Cost shows L2's total
3. Ctrl+click "SQL" in Category table
4. Verify Total Cost shows ONLY L2+SQL intersection (not all SQL)

---

## Issue 3: Top 15/20 Charts Don't Update When Filtered [FIXED]

**Status:** ✅ Verified by Claude - uses pre-filtered data for ranking, properly handles resource/meter selections (lines 2952-3004)

**Severity:** High
**Problem:** Top 15 ranking is calculated from unfiltered or incorrectly filtered data
**Where:** `buildFilteredDatasets()` function, lines ~2909-3134

**Root cause:**
The `keyTotals` array (which determines the top 15) is calculated before chart selections are fully applied. The ranking calculation and the actual chart data use different filtering logic paths.

**Fix approach:**
1. Move the Top 15 ranking calculation AFTER all filters are applied
2. Use the same filtered data for both ranking and rendering
3. Ensure `chartSelections` are applied consistently in `buildFilteredDatasets()`

**Specific changes needed:**
- In `buildFilteredDatasets()`, ensure the `keyTotals` loop (lines ~2909-3100) respects:
  - `chartSelections.subscriptions`
  - `chartSelections.categories`
  - `chartSelections.resources`
  - `chartSelections.meters`
- The filtering logic should match `filterRawDailyDataBySelections()` exactly

**Test:**
1. Select subscription "L2"
2. Switch to "Top 15 by Category" view
3. Verify chart shows only categories present in L2 (not all categories)
4. Verify ranking is based on L2's costs (not global costs)

---

## Issue 4: Category Dropdown Not Combined with Table Selections [FIXED]

**Status:** ✅ Verified by Claude - dropdown intersects with table selections (lines 2586-2610)

**Severity:** High
**Problem:** When user selects items via table Ctrl+click AND changes category dropdown, one filter is ignored
**Where:** Multiple locations in `updateChart()` and `buildFilteredDatasets()`

**Current behavior:**
- `currentCategoryFilter` dropdown sets a category filter
- Ctrl+clicking rows sets `chartSelections.categories`
- These two mechanisms don't combine - one overrides the other

**Fix approach:**
At the start of `updateChart()`, combine dropdown filter with chartSelections:
```javascript
// If category dropdown is set to specific category, add it to chartSelections
if (currentCategoryFilter !== 'all') {
    // Ensure the dropdown category is included in chartSelections
    // But only if no other category selections exist, OR intersect with existing
}
```

**Alternative approach:**
Make the dropdown and chartSelections mutually exclusive - when user changes dropdown, clear chartSelections.categories (and vice versa). Add a visual indicator showing which filter is active.

**Test:**
1. Select "SQL" from category dropdown
2. Ctrl+click "L2" subscription
3. Verify chart shows SQL costs for L2 only

---

## Issue 5: Double Filtering in Total Cost Mode [FIXED - DOCUMENTED]

**Status:** ✅ Verified by Claude - documented as intentional; manual filtering necessary due to UNION vs INTERSECTION logic

**Severity:** Medium
**Problem:** Total Cost mode applies filtering twice with different logic
**Where:** Lines ~2584-2626 and ~2740-2849

**Current flow:**
1. `filterRawDailyDataBySelections()` filters the raw data → `dataToUse`
2. `dataToUse` is passed to chart building
3. BUT Total Cost mode (lines 2740-2849) then manually re-filters by iterating categories/subscriptions again

**Fix approach:**
Total Cost mode should simply sum all values in `dataToUse` without additional filtering:
```javascript
if (view === 'total') {
    dates.forEach(date => {
        const dayData = dataToUse[date];
        if (!dayData) return;

        // Just sum the already-filtered data
        let dayTotal = 0;
        if (dayData.ByCategory) {
            Object.values(dayData.ByCategory).forEach(catData => {
                if (catData.bySubscription) {
                    Object.values(catData.bySubscription).forEach(subCost => {
                        dayTotal += getCostValue(subCost);
                    });
                }
            });
        }
        totalData.push({ x: date, y: dayTotal });
    });
}
```

This requires `filterRawDailyDataBySelections()` to be accurate (see Issues 1-4).

**Note:** Current implementation uses manual filtering because `filterRawDailyDataBySelections()` uses UNION logic while Total Cost mode needs INTERSECTION logic when both subscription and category are selected. Full simplification would require refactoring `filterRawDailyDataBySelections()` to support intersection, which is beyond the scope of these fixes.

**Test:**
1. Apply various filter combinations
2. Verify Total Cost always matches the sum of what's visible in the data tables

---

## Issue 6: Inconsistent Data Type Handling [FIXED]

**Status:** ✅ Verified by Claude - getCostValue() helper on lines 2041-2047, used in Total Cost mode

**Severity:** Medium
**Problem:** Cost values are sometimes objects `{CostLocal: number}` and sometimes direct numbers
**Where:** Throughout the JavaScript, defensive checks like lines 2783-2788

**Current approach:**
```javascript
if (subCost && typeof subCost === 'object' && subCost.CostLocal !== undefined) {
    dayTotal += subCost.CostLocal || 0;
} else if (typeof subCost === 'number') {
    dayTotal += subCost;
}
// else: silently ignored
```

**Fix approach:**
Create a helper function and use it everywhere:
```javascript
function getCostValue(cost) {
    if (cost === null || cost === undefined) return 0;
    if (typeof cost === 'number') return cost;
    if (typeof cost === 'object' && cost.CostLocal !== undefined) return cost.CostLocal || 0;
    console.warn('Unexpected cost type:', typeof cost, cost);
    return 0;
}
```

Then replace all inline type checks with `getCostValue(cost)`.

**Test:**
1. Run with test data
2. Check browser console for warnings
3. Verify no costs are silently dropped

---

## Issue 7: Summary Cards Use UNION Instead of INTERSECTION [FIXED]

**Status:** ✅ Verified by Claude - INTERSECTION logic implemented for summary cards (lines 3662-3753)

**Severity:** Critical
**Problem:** Summary cards (Total Cost SEK/USD at top) use UNION-filtered data, showing wrong totals when both subscription AND category are selected
**Where:** `updateSummaryCards()` function, lines ~3528-3700

**Current behavior:**
- Click "Sub-Prod-001" → summary shows 17,432 SEK (should be 10,747 SEK)
- Click "Virtual Machines" → summary shows 11,280 SEK (should be 3,848 SEK for Sub-Prod-001's VMs only)

**Root cause:**
- `filterRawDailyDataBySelections()` uses UNION logic (lines 2105-2115): `if (subSelected || catSelectedFromAll || ...)`
- Summary cards at line 3668-3669 use: `filteredTotalCostLocal += day.totalCostLocal`
- The `day.totalCostLocal` is calculated from UNION-filtered data, not INTERSECTION

**Why Issue 2 fix didn't help:**
- Issue 2 fixed the Total Cost **chart** by manually recalculating with INTERSECTION logic
- But summary cards still use `day.totalCostLocal` from UNION-filtered data

**Fix approach:**
The `updateSummaryCards()` function needs to use the same INTERSECTION logic as the Total Cost chart. Instead of:
```javascript
dataToUse.forEach(day => {
    filteredTotalCostLocal += day.totalCostLocal || 0;
});
```

It should iterate through categories/subscriptions with INTERSECTION logic (same as lines 2776-2889 in Total Cost chart):
```javascript
// Calculate filtered totals with INTERSECTION logic
let filteredTotalCostLocal = 0;
let filteredTotalCostUSD = 0;

const hasSubscriptionSelections = chartSelections.subscriptions.size > 0;
const hasCategorySelections = chartSelections.categories.size > 0;

dataToUse.forEach(day => {
    Object.entries(day.categories || {}).forEach(([cat, catData]) => {
        // Check if category should be included
        const catSubs = chartSelections.categories.get(cat);
        const categoryIncluded = !hasCategorySelections || (catSubs && catSubs.size > 0);
        if (!categoryIncluded) return;

        // Determine subscriptions to include (INTERSECTION logic)
        let subsToInclude = [];
        if (hasSubscriptionSelections && hasCategorySelections) {
            // INTERSECTION: only subs that match both filters
            if (catSubs.has('')) {
                subsToInclude = Array.from(chartSelections.subscriptions).filter(sub =>
                    catData.bySubscription && catData.bySubscription[sub] !== undefined
                );
            } else {
                subsToInclude = Array.from(catSubs).filter(sub =>
                    chartSelections.subscriptions.has(sub) &&
                    catData.bySubscription && catData.bySubscription[sub] !== undefined
                );
            }
        } else if (hasSubscriptionSelections) {
            subsToInclude = Array.from(chartSelections.subscriptions).filter(sub =>
                catData.bySubscription && catData.bySubscription[sub] !== undefined
            );
        } else if (hasCategorySelections) {
            if (catSubs.has('')) {
                subsToInclude = Object.keys(catData.bySubscription || {});
            } else {
                subsToInclude = Array.from(catSubs).filter(sub =>
                    catData.bySubscription && catData.bySubscription[sub] !== undefined
                );
            }
        } else {
            subsToInclude = Object.keys(catData.bySubscription || {});
        }

        // Sum costs for included subscriptions
        subsToInclude.forEach(sub => {
            const subCost = catData.bySubscription[sub];
            filteredTotalCostLocal += getCostValue(subCost);
            if (subCost && typeof subCost === 'object') {
                filteredTotalCostUSD += subCost.CostUSD || 0;
            }
        });
    });
});
```

**Test:**
1. Click "Sub-Prod-001" → summary should show ~10,747 SEK (subscription total)
2. Click "Virtual Machines" → summary should show ~3,848 SEK (Sub-Prod-001's VMs only)
3. Values should match what's shown in the table

---

## Issue 8: Resource filtering sums entire category cost instead of specific meter cost [FIXED]

**Status:** ✅ Verified by Claude - added `ByMeter` breakdown to `Collect-CostData.ps1` and updated `Export-CostTrackingReport.ps1` to use it

**Severity:** Critical
**Problem:** Selecting a resource that exists under a specific meter incorrectly sums the cost of that resource across its entire category (all meters), leading to inflated totals (e.g., 533 instead of 203)
**Where:** `Collect-CostData.ps1` (collector) and `filterRawDailyDataBySelections` in `Export-CostTrackingReport.ps1`

**Root cause:**
- `Collect-CostData.ps1` aggregated resource costs only by Category and Subscription, losing Meter granularity
- `Export-CostTrackingReport.ps1` filtered by Category when a specific Meter was selected, effectively summing all meters in that category for the resource

**Fix approach:**
1. Update `Collect-CostData.ps1` to include `ByMeter` breakdown in `DailyTrend.ByResource`
2. Update `Export-CostTrackingReport.ps1` to prioritize `ByMeter` when filtering resources with a specific meter context

**Test:**
1. Select a specific meter (e.g., "Actions" under "Logic Apps")
2. Select a resource in that meter
3. Verify summary cards show the cost for that specific meter/resource combo (203), not the total category cost (533)

---

## Priority Order

1. **Issue 1** - Critical bug, simple fix (undefined variable) ✅ FIXED
2. **Issue 2** - Critical bug causing reported symptoms ✅ FIXED
3. **Issue 7** - Critical bug in summary cards (UNION vs INTERSECTION) ✅ FIXED
4. **Issue 8** - Critical bug in resource cost accuracy [NEW] ✅ FIXED
5. **Issue 3** - High impact on Top 15 usability ✅ FIXED
6. **Issue 4** - High impact on filter combination ✅ FIXED
7. **Issue 5** - Medium, cleanup after 1-4 are fixed ✅ FIXED (documented)
8. **Issue 6** - Medium, defensive improvement ✅ FIXED

---

## Testing Procedure

After fixes, test these scenarios:

### Scenario A: Single Subscription Filter
1. Load Cost Tracking report
2. Click subscription "L2" in table
3. Verify: Total Cost shows L2 total only
4. Verify: Top 15 by Category shows only L2's categories
5. Verify: Top 20 Resources shows only L2's resources

### Scenario B: Subscription + Category Intersection
1. Click subscription "L2"
2. Ctrl+click category "SQL"
3. Verify: Total Cost = L2's SQL costs only
4. Verify: Subscription table shows L2 highlighted
5. Verify: Category table shows SQL highlighted

### Scenario C: Multi-Select
1. Ctrl+click subscriptions "L1" and "L2"
2. Verify: Total Cost = L1 + L2 combined
3. Ctrl+click category "SQL"
4. Verify: Total Cost = (L1 + L2) SQL costs only

### Scenario D: Top 15 Updates
1. Select subscription "L2"
2. Switch to "Top 15 by Category"
3. Verify: Only L2's categories appear, ranked by L2's costs
4. Switch to "Top 20 Meters"
5. Verify: Only meters from L2's resources appear
