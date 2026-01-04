# Azure Cost Tracking report – refactor architecture plan (Cursor-ready)

> Scope: Refactor the **Cost Tracking** report so that **multiple selection sources** (multiple tables + multiple levels) can be combined, while **totals and charts reflect costs for the union of all filtered resources** and **each resource is counted only once**, even if it is selected via multiple routes.

This plan assumes your current report is a *static HTML* file with embedded JS (Chart.js) and a generated dataset similar to `rawDailyData`, plus click-handlers that populate a `chartSelections` object.

---

## 1) What “correct” should mean (selection semantics)

### 1.1 Resource-first semantics (recommended)
**A selection anywhere resolves to a set of ResourceKeys.**  
The active filter is the **union** of those resource sets.  
The **chart + total cards** are computed from **all costs for those resources** (full cost of each resource in the time window), and each resource is counted once.

This matches your goal: *“multiselect from these tables (from more than one table and more than one level) and have the chart and total cards show costs for all filtered resources; but of course only counting each once even if it is included in filters on multiple tables”*.

### 1.2 Optional “row-level” semantics (future toggle)
Sometimes you may want: “only show the costs that match the selected category/meter/subcategory”, i.e. filter fact rows, not resources.  
We can add a **Filter Mode toggle** later:

- **Mode A (default): Resource union** (what you asked for)
- **Mode B: Row-level intersection** (classic BI slicing)

Start with Mode A to eliminate double counting and complexity.

---

## 2) Why the current approach breaks (high-level diagnosis)

Your current implementation stores aggregated data per day in nested structures (`day.categories`, `day.meters`, `day.resources`) and then tries to apply a selection model that mixes **union** and **intersection** logic across levels.

That design makes it very easy to:
1) include costs multiple times (because the same cost exists in multiple aggregates), and  
2) accidentally include *more than the intended resource set* when selections come from different tables.

This is visible in the code patterns:
- `rawDailyData` is a nested per-day aggregate object embedded into the HTML.
- `filterRawDailyDataBySelections(rawDailyData)` builds a *new aggregated day* by copying selected parts.
- summary totals sometimes sum categories totals, sometimes sum resources totals, depending on which selections exist.

This “aggregate-on-aggregate” filtering is the main reason single resource selection can still yield very large totals.

**Refactor principle:** *Never filter pre-aggregated data when you need correct set logic.*  
Instead: keep one canonical **fact grain**, and derive aggregates from that.

---

## 3) Proposed target architecture (simple, robust, scalable)

### 3.1 Data layers
1) **Fact table (canonical grain):** one row per (date, resource, meter/subcategory/category, subscription) with both currencies.
2) **Dimensions / indices:** fast lookups to resolve “category X” → resources, “meter Y” → resources, etc.
3) **Precomputed series (optional but recommended):** per-resource daily totals arrays to make chart updates instant.

### 3.2 State model
A single store that holds:
- `selectedTokens`: selection tokens from any table (typed)
- `resolvedResourceSet`: a `Set<ResourceKey>` computed from tokens
- `dateRange` / `currency` / `viewMode`
- derived data: totals, series for chart

### 3.3 Rendering
- Tables only emit selection tokens.
- A single `recompute()` pipeline:
  1) resolve tokens → resource set (union)
  2) aggregate from fact/precomputed series
  3) render totals + chart + selection pills

---

## 4) Data contract (what the exporter should output)

### 4.1 Canonical ResourceKey
You **must** have a stable key that identifies a resource uniquely across the report.

Recommended (works even without full ARM IDs):
```
ResourceKey = `${subscriptionName}::${resourceGroup}::${resourceName}`
```

If you can output the real Azure resourceId, even better:
```
ResourceKey = resourceId   // canonical
```

### 4.2 JSON payloads to embed in the report

#### A) `factRows` (minimum viable)
Array of:
```json
{
  "date": "2026-01-01",
  "subscription": "MissionPoint",
  "resourceKey": "MissionPoint::missionpoint_it::timekeepercustomertodataverse",
  "resourceName": "timekeepercustomertodataverse",
  "resourceGroup": "missionpoint_it",
  "category": "Logic Apps",
  "subcategory": "Logic Apps",
  "meter": "Consumption Data Retention",
  "costLocal": 203.10,
  "costUsd": 21.34
}
```

#### B) `dimResources`
Array of:
```json
{
  "resourceKey": "...",
  "subscription": "...",
  "resourceName": "...",
  "resourceGroup": "...",
  "categories": ["Logic Apps", "Storage"],
  "meters": ["Consumption Data Retention", "Standard Data Transfer Out"]
}
```

#### C) Indices (optional, can be built in JS)
If you want faster load and simpler JS:
```json
{
  "resourcesBySubscription": { "MissionPoint": ["rk1","rk2"] },
  "resourcesByCategory": { "Logic Apps": ["rk3","rk4"] },
  "resourcesByMeter": { "Consumption Data Retention": ["rk3"] },
  "resourcesBySubcategory": { "Rtn Preference: MGN": ["rkX"] }
}
```

#### D) `dailyTotalsByResource` (strongly recommended)
Map:
```json
{
  "dates": ["2025-12-06","2025-12-07", "..."],
  "series": {
     "rk1": { "local": [0.1, 0.2, ...], "usd": [0.01, 0.02, ...] },
     "rk2": { "local": [ ... ], "usd": [ ... ] }
  }
}
```

This makes chart updates `O(#selectedResources * #days)` and avoids scanning all fact rows on every click.

---

## 5) Front-end folder structure (no bundler, ES modules)

Create a `/cost-tracking/` folder next to the HTML (or wherever you export assets).

```
cost-tracking/
  main.js
  data/
    load.js
    normalize.js
    indexes.js
  state/
    store.js
    actions.js
    selectors.js
  filters/
    tokens.js
    resolveResourceSet.js
  metrics/
    aggregateTotals.js
    buildSeries.js
  ui/
    chart.js
    summaryCards.js
    selectionPills.js
    tableBindings.js
  utils/
    format.js
    dom.js
```

And in `cost-tracking.html`:
```html
<script type="module" src="./cost-tracking/main.js"></script>
```

---

## 6) Selection tokens (the core trick that avoids spaghetti)

Every UI click emits a token with a *type* and *payload*.

```ts
type SelectionToken =
  | { type: "RESOURCE"; resourceKey: string }
  | { type: "SUBSCRIPTION"; subscription: string }
  | { type: "CATEGORY"; category: string }
  | { type: "SUBCATEGORY"; subcategory: string }
  | { type: "METER"; meter: string };
```

Your tables can select at any level; the resolver turns tokens into resources.

### 6.1 Token rules
- Tokens are **toggleable** (click again removes).
- Multi-select: always allowed.
- Optional: Shift-click = range select (only for same table).

---

## 7) Resource set resolver (union + dedupe)

### 7.1 Inputs
- `tokens: Set<SelectionToken>`
- `indexes` (maps from dimension value → resourceKeys)

### 7.2 Output
- `Set<ResourceKey>` = union of all token-resolved sets

Pseudo:
```js
export function resolveResourceSet(tokens, indexes) {
  const out = new Set();

  for (const t of tokens) {
    switch (t.type) {
      case "RESOURCE":
        out.add(t.resourceKey);
        break;
      case "SUBSCRIPTION":
        for (const rk of indexes.resourcesBySubscription.get(t.subscription) ?? []) out.add(rk);
        break;
      case "CATEGORY":
        for (const rk of indexes.resourcesByCategory.get(t.category) ?? []) out.add(rk);
        break;
      case "SUBCATEGORY":
        for (const rk of indexes.resourcesBySubcategory.get(t.subcategory) ?? []) out.add(rk);
        break;
      case "METER":
        for (const rk of indexes.resourcesByMeter.get(t.meter) ?? []) out.add(rk);
        break;
    }
  }

  return out;
}
```

### 7.3 Empty selection behavior
If `tokens.size === 0` → treat as “All resources” (i.e. no filtering).

---

## 8) Aggregation strategy (correct totals, no double counting)

### 8.1 Totals
If you have `dailyTotalsByResource`:
- Total Local = sum over selected resource keys and all days
- Total USD = same for usd

If you *don’t* have precomputed series:
- Total Local = sum factRows where `resourceKey ∈ selectedSet` (and date in range)

### 8.2 Chart series
Daily totals series:
- For each day index `i`, sum `series[rk].local[i]` across selected resources.

### 8.3 “Count each resource once”
This is naturally guaranteed because you only ever aggregate using the **resource set** as the outer loop.
Even if 5 tokens include the same rk, it’s still only in the Set once.

---

## 9) UI implementation notes (tables, cards, chart)

### 9.1 Tables
Keep your existing tables, but change click handlers:

- Instead of writing into multiple `chartSelections.*` maps, do:
  - read the row’s `data-resource-key` or dimension value
  - dispatch `toggleToken(...)`

Example:
```html
<tr data-token-type="RESOURCE" data-resource-key="MissionPoint::rg::name">
```

Binding:
```js
table.addEventListener("click", (e) => {
  const tr = e.target.closest("tr[data-token-type]");
  if (!tr) return;

  const type = tr.dataset.tokenType;
  // build token from dataset
  store.dispatch(actions.toggleToken(token));
});
```

### 9.2 Selection pills
Render active tokens as pills:
- “Resource: timekeepercustomertodataverse”
- “Category: Logic Apps”
- “Meter: Consumption Data Retention”
Each pill has an ✕ that removes its token.

### 9.3 Summary cards
Cards render from derived state: `store.select(selectTotalLocal)` etc.

### 9.4 Chart
Chart renders from derived series. No chart-specific selection logic.

---

## 10) Refactor plan (phased, low risk)

### Phase 0 — lock in “truth” test cases
Create a small `tests/fixtures.json` with a few resources/days where you can prove correctness.

Add acceptance tests (manual is ok):
1) Select **one resource** → totals must match that row’s total across date range.
2) Select **resource + its category** → totals must not change (resource already included).
3) Select **category A + category B** → totals = union resources(A) ∪ resources(B).
4) Select **subscription + meter** → totals = union resources(subscription) ∪ resources(meter).
5) Clear tokens → returns to original totals.

### Phase 1 — introduce the store + token system
- Add `state/store.js`, `filters/tokens.js`
- Leave existing `chartSelections` code untouched for now.
- Implement store + logging only.

### Phase 2 — build indexes + resolver
- From existing data payload, build:
  - `dimResources` (if not already available, infer from your current resource table)
  - indexes maps

### Phase 3 — compute totals + chart from resolved resource set
- Keep existing chart/table UI.
- Replace `updateSummaryCards()` and chart data builder to use:
  - `resolvedResourceSet` + `dailyTotalsByResource` (or factRows scan)

At this point the core bug should be gone.

### Phase 4 — migrate tables to emit tokens
- Replace `handleResourceSelection`, `handleMeterSelection`, etc with a single token dispatcher.
- Remove `chartSelections` and `filterRawDailyDataBySelections` entirely.

### Phase 5 — optional improvements
- Filter Mode toggle (resource-union vs row-level)
- Date range picker
- “Only show selected resources” toggle for tables
- Performance: use typed arrays, web workers if needed (likely not necessary)

---

## 11) PowerShell exporter changes (recommended)

### 11.1 Emit ResourceKey consistently
When generating table rows, add `data-resource-key`.
When generating JSON, ensure the same key is used as the key in indices/series.

### 11.2 Output `dailyTotalsByResource`
During export, you already build a resource→meters map. Extend this to also build:

- list of dates
- for each resourceKey: arrays local/usd aligned to date list

This saves a lot of JS complexity.

---

## 12) Cursor instructions (copy/paste prompts)

### 12.1 First prompt: create new architecture skeleton
**Prompt to Cursor:**
> Create a new folder `cost-tracking/` with ES module files as per the plan. Implement a minimal store (subscribe/dispatch), token types, and a resource resolver that uses indexes. Do not modify existing HTML yet; just add console logs to demonstrate the resolver works with a hardcoded sample index.

**Definition of done:**
- `main.js` loads, creates store, logs resolved resource keys for a hardcoded token set.

### 12.2 Second prompt: integrate with existing HTML dataset
**Prompt:**
> Parse the embedded JSON payload(s) currently used for cost tracking and build `dimResources` and indexes maps (subscription/category/meter/subcategory → resourceKeys). Then wire table row clicks for the **resource table only** to emit RESOURCE tokens into the store. On click, log the resolved resource set size and the first 5 keys.

**DoD:**
- Clicking a resource row toggles it in selection.
- Logs reflect selection set changes.

### 12.3 Third prompt: replace total cards calculation
**Prompt:**
> Replace summary cards so that Total Cost (Local/USD) is computed as the sum of costs for the resolved resource set (union semantics). Use either `dailyTotalsByResource` if present, otherwise scan fact rows derived from current rawDailyData. Ensure selecting a single resource updates totals to match that resource’s total.

**DoD:**
- Selecting one resource produces the correct totals.

### 12.4 Fourth prompt: replace chart series calculation
**Prompt:**
> Update the Chart.js dataset builder to use the derived daily totals series for the resolved resource set. Keep existing chart visuals. Confirm series changes when selecting resources.

**DoD:**
- Chart updates on selection and matches totals.

### 12.5 Fifth prompt: migrate remaining tables
**Prompt:**
> Replace all existing per-table selection handlers and chartSelections logic with token dispatching. Implement tokens for SUBSCRIPTION, CATEGORY, SUBCATEGORY, METER. Delete filterRawDailyDataBySelections and any chartSelections state. Ensure multi-table selections work and resources are not double-counted.

**DoD:**
- Multiple selections across multiple tables produce correct totals; no double counting.

---

## 13) Quick sanity check you should add to the UI

Add a small debug line under the summary cards:
- “Selected resources: N”
- “Selection tokens: M”

This makes it obvious whether your current selection is resolving to too many resources.

---

## 14) Acceptance criteria (final)

1) **Single resource correctness**  
Selecting one resource must show totals equal to that resource’s costs (Local and USD) across the visible time window.

2) **Union across sources**  
Selecting resources via multiple tables/layers produces totals equal to the union of their resources.

3) **No double counting**  
If a resource is included via multiple selections, totals do not increase.

4) **Predictable reset**  
Clearing selection returns the report to baseline totals and baseline chart.

---

If you want, I can also produce a **companion “data contract update” patch plan** for `Export-CostTrackingReport.ps1` so it outputs `factRows` and `dailyTotalsByResource` cleanly, but the front-end refactor above can already be done against your existing embedded dataset and then later improved by exporter changes.
