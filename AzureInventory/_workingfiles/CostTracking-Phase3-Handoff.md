# Cost Tracking Report - Phase 3 Handoff Document

**Date:** 2024-12-19  
**Status:** Phase 3 - Incremental Table Migration (In Progress)  
**Primary File:** `Public/Export-CostTrackingReport.ps1`

---

## Executive Summary

This document provides context for continuing work on **Phase 3** of the Cost Tracking report refactor. Phase 3 focuses on incremental migration of tables to the new data engine, with emphasis on robust key normalization, click handlers, and UI synchronization.

**Key Achievement:** Successfully implemented dynamic re-aggregation for "Cost by Meter Category" section, Explorer-style selection logic, and fixed critical expand-state and encoding bugs.

---

## Current State

### ✅ Completed (Recent Work)

1. **Dynamic Re-aggregation of "Cost by Meter Category"**
   - Implemented `renderCostByMeterCategory()` function that dynamically builds the category hierarchy from `engine.getScopeRowIds()`
   - Meter Category now reflects subscription scope (filter), NOT picks (resource selections)
   - Replaces static PowerShell-generated HTML with dynamic JavaScript rendering
   - Preserves expand/collapse state (no display manipulation in render function)

2. **Explorer Selection Logic for Resource Picks**
   - Implemented Windows Explorer-style selection:
     - **Ctrl/Cmd-click**: Toggle (multi-select)
     - **Single-click**: Replace selection, or clear if already selected
   - Direct manipulation of `engine.state.picks.resourceKeys` (not via `togglePick()`)
   - Clears other pick dimensions to avoid split-brain state

3. **Fixed Critical Bugs**
   - **Expand-state preservation**: Removed all `display` manipulation from `renderCostByMeterCategory()` - expand/collapse now controlled solely by toggle handlers
   - **Encoding issue**: Fixed arrow symbols (↑↓→) in Cost Trend by using HTML entities (`&#8593;`, `&#8595;`, `&#8594;`) instead of Unicode characters
   - **Initial load bug**: Fixed `getScopeRowIds()` to return all rows when scope is empty (uses `null` instead of empty Set for "no filter" state)
   - **Collapse on click**: Added `e.stopPropagation()` to prevent resource clicks from collapsing parent expandable sections

4. **Subscription Scope Normalization**
   - Normalized engine scope: when all subscriptions are selected, scope is empty Set (same as no filter)
   - GUID-based filtering throughout (moved from subscription names to IDs)
   - Hard hide of subscription cards and rows not in scope

5. **UI Filtering Improvements**
   - `applySubscriptionScopeToTables()` - filters table rows by subscription GUID
   - `applySubscriptionScopeToCards()` - hides subscription cards not in scope
   - Both use `display: none` exclusively (no `visibility` manipulation)

---

## Architecture Overview

### Data Flow

```
PowerShell (Export-CostTrackingReport.ps1)
  ↓
  Generates factRows (canonical data structure)
  ↓
  Embeds as JSON: <script type="application/json" id="factRowsJson">
  ↓
JavaScript Engine (createEngine)
  ↓
  Builds indices: bySubscriptionId, byResourceKey, byMeterCategory, etc.
  ↓
  Maintains state: scope (AND logic) + picks (UNION logic)
  ↓
UI Components
  - Summary Cards: engine.sumCosts(engine.getActiveRowIds())
  - Chart: engine.trendByDay(engine.getActiveRowIds())
  - Meter Category: engine.getScopeRowIds() (scope-only, ignores picks)
  - Tables: Filtered by scope via applySubscriptionScopeToTables()
```

### Key Concepts

1. **factRows**: Canonical data structure (one row per day/resource/meter cost)
   - Precomputed keys: `subscriptionKey`, `resourceKey`, `meterKey`, `dateKey`
   - Lower camelCase field names
   - Includes all rows (even those without ResourceId)

2. **Engine State**
   - `scope`: AND logic (subscription filter, day range)
   - `picks`: UNION logic (resource selections, category selections)
   - `getActiveRowIds()`: Returns `scope ∩ picks` (intersection)
   - `getScopeRowIds()`: Returns scope-only (ignores picks)

3. **DOM Index (`window.domIndex`)**
   - `Map<resourceKey, Element[]>` for efficient highlighting
   - Rebuilt after dynamic renders via `initDomIndex()`
   - Used by `updateResourceSelectionVisual()`

4. **Key Semantics**
   - `data-resource-key`: Canonical key (always present on clickable rows)
   - `data-resource-id`: Azure ResourceId (only if exists)
   - `data-subscription`: Subscription GUID (ID-first approach)

---

## File Structure

### Primary File
- **`Public/Export-CostTrackingReport.ps1`** (~6200 lines)
  - PowerShell data collection and HTML generation
  - Embedded JavaScript for UI and data engine
  - Key sections:
    - Lines ~156-175: `factRows` generation (PowerShell)
    - Lines ~1850-2350: Engine initialization (`createEngine`)
    - Lines ~2049-2103: `getScopeRowIds()` function
    - Lines ~3439-3500: Resource click handler (Explorer selection)
    - Lines ~4524-4809: `renderCostByMeterCategory()` function
    - Lines ~4872-4932: `updateSummaryCards()` function

### Supporting Files
- **`Config/Styles/_reports/cost-tracking-report.css`**: Report-specific styles
- **`Config/ControlDefinitions.json`**: Control definitions (for security report, not directly used in cost tracking)

---

## Key Functions Reference

### Engine Functions
```javascript
const engine = createEngine(factRows);

// Scope management
engine.setScopeSubscriptions(subscriptionIds); // Array of GUIDs
engine.getScopeRowIds(); // Returns Set of rowIds matching scope (ignores picks)

// Selection management
engine.state.picks.resourceKeys; // Set of selected resource keys
engine.getActiveRowIds(); // Returns Set of rowIds matching scope ∩ picks

// Aggregation
engine.sumCosts(rowIds); // Returns { local, usd }
engine.trendByDay(rowIds); // Returns array of { day, local, usd }
```

### UI Functions
```javascript
// Dynamic rendering
renderCostByMeterCategory(); // Re-renders Meter Category from engine.getScopeRowIds()

// DOM management
initDomIndex(); // Rebuilds window.domIndex Map
updateResourceSelectionVisual(); // Updates row highlighting from engine.state.picks

// UI updates
updateSummaryCards(); // Updates summary cards from engine
updateChart(); // Updates chart from engine
applySubscriptionScopeToTables(); // Filters table rows by subscription scope
applySubscriptionScopeToCards(); // Hides subscription cards not in scope
```

---

## Recent Changes (Last Session)

### 1. Removed Display Manipulation from `renderCostByMeterCategory()`
**Location:** Lines ~4524-4809

**Change:** Removed all code that manipulated `expandableContent.style.display` or `expandable.classList`. Render function now only updates `container.innerHTML`.

**Rationale:** Expand/collapse state should be controlled solely by toggle handlers (`toggleSection`, `handleCategorySelection`, etc.), not by render functions.

**Impact:** Meter Category section no longer collapses when resources are picked.

### 2. Implemented Explorer Selection Logic
**Location:** Lines ~3439-3500

**Change:** Replaced `engine.togglePick()` with direct manipulation of `engine.state.picks.resourceKeys` using Explorer-style logic:
- Ctrl/Cmd-click: Toggle
- Single-click: Replace or clear if already selected

**Rationale:** More intuitive user experience, matches Windows Explorer behavior.

**Impact:** Better UX for resource selection, prevents accidental multi-select.

### 3. Added `stopPropagation()` to Resource Click Handler
**Location:** Line ~3448

**Change:** Added `e.stopPropagation()` immediately after identifying resource row click.

**Rationale:** Prevents click from bubbling to parent expandable handlers, which could collapse sections.

**Impact:** Resource clicks no longer collapse parent expandable sections.

### 4. Fixed Encoding for Arrow Symbols
**Location:** Line ~4926

**Change:** Changed from Unicode characters (`'↑'`, `'↓'`, `'→'`) to HTML entities (`'&#8593;'`, `'&#8595;'`, `'&#8594;'`).

**Rationale:** HTML entities are more robust across different encodings.

**Impact:** Arrow symbols now display correctly in Cost Trend card.

### 5. Fixed `getScopeRowIds()` Return Logic
**Location:** Lines ~2078, ~2103

**Change:** Changed from returning empty Set to using `null` to indicate "no filter applied", then returning `new Set(allRowIds)` when `scopeRowIds === null`.

**Rationale:** Distinguishes between "no filter" (should return all rows) and "filter applied but matched nothing" (should return empty Set).

**Impact:** Meter Category now renders correctly on initial load.

---

## Known Issues / TODOs

### High Priority
1. **Test Explorer Selection Logic**
   - Verify Ctrl/Cmd-click toggles correctly
   - Verify single-click replace/clear behavior
   - Test edge cases (clicking same resource multiple times)

2. **Verify Meter Category Doesn't Re-render on Picks**
   - Confirm `renderCostByMeterCategory()` is NOT called in resource click handler
   - Meter Category should only update when subscription scope changes

3. **Test Expand-State Preservation**
   - Expand Meter Category section
   - Pick a resource
   - Verify section remains expanded
   - Test with other expandable sections

### Medium Priority
4. **Performance Testing**
   - Test with large datasets (1000+ factRows)
   - Verify `initDomIndex()` performance
   - Check `renderCostByMeterCategory()` performance with many categories

5. **Edge Cases**
   - Test with empty factRows
   - Test with no subscriptions
   - Test with resources that have no ResourceId

### Low Priority / Future Work
6. **Phase 4: Complete Table Migration**
   - Migrate remaining static tables to dynamic rendering
   - Remove `rawDailyData` dependency
   - Clean up legacy code

7. **Additional Features**
   - Export selected data to CSV
   - Print-friendly view
   - Keyboard navigation for resource selection

---

## Testing Guide

### Manual Testing Checklist

#### 1. Explorer Selection Logic
- [ ] Single-click resource → should select (replace previous)
- [ ] Single-click same resource again → should deselect
- [ ] Ctrl-click resource → should add to selection (multi-select)
- [ ] Ctrl-click selected resource → should remove from selection
- [ ] Verify other picks (categories, meters) are cleared when resource is selected

#### 2. Expand-State Preservation
- [ ] Expand "Cost by Meter Category"
- [ ] Click a resource in any table
- [ ] Verify Meter Category remains expanded
- [ ] Test with other expandable sections (Subscription, Top Resources)

#### 3. Subscription Filtering
- [ ] Select 1 subscription → verify only that subscription's data shows
- [ ] Select all subscriptions → verify all data shows (scope should be empty)
- [ ] Verify subscription cards are hidden when not in scope
- [ ] Verify table rows are filtered correctly

#### 4. Meter Category Dynamic Rendering
- [ ] Change subscription filter → verify Meter Category updates
- [ ] Pick a resource → verify Meter Category does NOT change
- [ ] Clear subscription filter → verify Meter Category shows all data

#### 5. Summary Cards and Chart
- [ ] Pick resources → verify summary cards update
- [ ] Pick resources → verify chart updates
- [ ] Change subscription filter → verify both update
- [ ] Verify totals match between cards and chart

### Console Testing

```javascript
// Check engine state
console.log({
  scopeIds: Array.from(engine.state.scope.subscriptionIds),
  pickedKeys: Array.from(engine.state.picks.resourceKeys),
  activeRowIds: engine.getActiveRowIds().size,
  scopeRowIds: engine.getScopeRowIds().size
});

// Check DOM index
console.log({
  hasDomIndex: !!window.domIndex,
  mapSize: window.domIndex?.byResourceKey?.size
});

// Test specific resource
const key = "/subscriptions/.../resourcegroups/.../providers/.../...";
const nodes = window.domIndex?.byResourceKey?.get(key) || [];
console.log({ nodeCount: nodes.length });
```

---

## Debugging Tips

### Enable Debug Mode
```javascript
window.DEBUG_COST_REPORT = true;
```

This enables additional console logging in:
- `renderCostByMeterCategory()`
- `updateSummaryCards()`
- Resource click handler

### Common Issues

1. **Meter Category is empty on load**
   - Check: `engine.getScopeRowIds().size` should equal `factRows.length` when no filters
   - Check: `factRows` is loaded correctly
   - Check: `getScopeRowIds()` returns `new Set(allRowIds)` when scope is empty

2. **Resource clicks don't work**
   - Check: `window.domIndex` exists and has entries
   - Check: Rows have `data-resource-key` attribute
   - Check: Click handler is not blocked by other event listeners

3. **Expand-state not preserved**
   - Check: No `display` manipulation in `renderCostByMeterCategory()`
   - Check: Toggle handlers are working correctly
   - Check: CSS classes are not being reset

4. **Selection highlighting not working**
   - Check: `initDomIndex()` is called after dynamic renders
   - Check: `updateResourceSelectionVisual()` is called after selection changes
   - Check: CSS for `.selected` class is correct

---

## Code Patterns

### Adding a New Dynamic Renderer

1. Create render function:
```javascript
function renderMySection() {
    const container = document.getElementById('mySectionRoot');
    if (!container) return;
    
    // Get data from engine
    const rowIds = engine.getScopeRowIds(); // or getActiveRowIds()
    
    // Build HTML
    let html = '';
    // ... build HTML ...
    
    // Render (NO display manipulation)
    container.innerHTML = html;
    
    // Re-index and update visuals
    initDomIndex();
    updateResourceSelectionVisual();
}
```

2. Hook into state changes:
```javascript
// In filterBySubscription()
renderMySection();

// In resource click handler (if needed)
renderMySection();
```

### Adding a New Pick Dimension

1. Add to engine state (line ~2012):
```javascript
picks: {
    // ... existing ...
    myNewDimension: new Set()
}
```

2. Update `getActiveRowIds()` to include new dimension
3. Clear in resource click handler (if using strict policy):
```javascript
engine.state.picks.myNewDimension.clear();
```

---

## Next Steps

### Immediate (Next Session)
1. Test Explorer selection logic thoroughly
2. Verify expand-state preservation works in all scenarios
3. Test with real data (not just test data)

### Short-term (Phase 3 Completion)
1. Migrate remaining static tables to dynamic rendering
2. Remove `rawDailyData` dependency where possible
3. Add comprehensive error handling

### Long-term (Phase 4+)
1. Complete table migration
2. Remove all legacy code
3. Performance optimization
4. Additional features (export, print, etc.)

---

## Important Notes

1. **Never manipulate `display` in render functions** - use toggle handlers only
2. **Meter Category is scope-only** - don't call `renderCostByMeterCategory()` on pick events
3. **Always re-index DOM after dynamic renders** - call `initDomIndex()` after `innerHTML` changes
4. **Use GUIDs for subscriptions** - not names (ID-first approach)
5. **Clear other picks when selecting resources** - prevents split-brain state

---

## Contact / Questions

If you encounter issues or need clarification:
1. Check this handoff document first
2. Review recent git commits for context
3. Check `CLAUDE.md` for project overview
4. Review `FIXPLAN-CostTrackingChart.md` for Phase 1-2 context

---

**Last Updated:** 2024-12-19  
**Status:** Phase 3 - Incremental Migration (Active)
