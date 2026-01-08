# Phase 5.1 – Micro-cleanup & sanity gates (post-regenererad HTML)

**Mål:** Städa bort kvarvarande “legacy” som fortfarande läcker in i *genererad* `cost-tracking.html`, så att Phase 5 verkligen är **engine-only** och lättare att testa/felsöka.

## A) Kritisk: två `updateChart()` i output (MÅSTE BORT)
I genererad `cost-tracking.html` finns **2 st** `function updateChart(`. (Den sista vinner – men ni har kvar ett stort dött block och risk för regression.)

**Åtgärd:**
- Behåll **endast** den “senaste”/avsedda `updateChart()`-implementationen.
- Radera den andra helt (inkl ev hjälpare som bara den använder).

**Gate:**
- `rg "function updateChart\(" cost-tracking.html` → **exakt 1 träff**  
- (Bonus) `rg "updateChart\(" cost-tracking.html` ska inte visa gamla init-kedjor som kör chart 2 gånger i onödan.

## B) Ta bort dead `categoryFilter` (UI + state + funktioner)
Ni har fortfarande:
- `<select id="categoryFilter" onchange="filterChartCategory()">`
- `let currentCategoryFilter = 'all';`
- `function filterChartCategory() { currentCategoryFilter = ...; refreshUIFromState(...) }`

Men **ingen** av era engine-baserade chart/renderers använder `currentCategoryFilter` → dropdown gör inget.

**Åtgärd (Phase 5-konsekvent):**
- Ta bort hela categoryFilter-dropdownen ur HTML-output.
- Ta bort `currentCategoryFilter` + `filterChartCategory()`.

**Gate:**
- `rg "categoryFilter|currentCategoryFilter|filterChartCategory" cost-tracking.html` → **0 hits**

## C) Ta bort statiska `datasetsBy*` + `populateCategoryFilter()` + `getFilteredDayTotal()` (100% obsolet)
I output finns fortfarande statiska arrays:
- `const datasetsByCategory = [...]`
- `const datasetsBySubscription = [...]`
- `const datasetsByMeter = [...]`
- `const datasetsByResource = [...]`

Samt:
- `populateCategoryFilter()` (använder `datasetsByCategory`)
- `getFilteredDayTotal(...)` (använder `selectedSubscriptions`-semantik)

De används inte av engine-pipelinen (endast definitioner kvar).

**Åtgärd:**
- Radera samtliga `datasetsBy*`-konstanter från PS-generatorn.
- Radera `populateCategoryFilter()` och dess call i init.
- Radera `getFilteredDayTotal(...)` (och allt som bara finns för den).

**Gates:**
- `rg "datasetsBy(Category|Subscription|Meter|Resource)" cost-tracking.html` → **0 hits**
- `rg "populateCategoryFilter|getFilteredDayTotal" cost-tracking.html` → **0 hits**

## D) Döda `selectedSubscriptions` helt (risk för framtida scope-buggar)
I output finns fortfarande:
- `let selectedSubscriptions = new Set();`
- `selectedSubscriptions = new Set(selectedSubNames); // Legacy (tills den tas bort)`

Det är en dubbelkälla jämfört med engine scope (`engine.state.scope.subscriptionIds`) och riskerar mismatch (namn vs GUID) om någon råkar återanvända den.

**Åtgärd:**
- Ta bort `selectedSubscriptions`-variabeln.
- Ta bort alla rader som skriver till den.

**Gate:**
- `rg "selectedSubscriptions" cost-tracking.html` → **0 hits**

## E) Ta bort initiala dubbel-anrop (små men viktiga)
I DOMContentLoaded/init-sekvensen kör ni fortfarande:
- `updateChart();` (trots att `refreshUIFromState()` gör RAF-updateChart)
- `renderCostByMeterCategory();` (trots att `refreshUIFromState({skip:false})` gör rerender)

**Åtgärd:**
- Låt init göra:
  1) `initChart()`
  2) `initDomIndex()` *(om ni fortfarande vill ha index direkt)*
  3) `refreshUIFromState({ skipMeterCategoryRerender: false })`
- Ta bort manuella `updateChart()` och `renderCostByMeterCategory()` i init.

*(Om ni vill: lägg `initDomIndex()` inne i refresh när ni rerenderar, se punkt F.)*

**Gate:**
- `rg "populateCategoryFilter\(\)|renderCostByMeterCategory\(\);\s*$|\supdateChart\(\);" cost-tracking.html`  
  → ska inte visa init-dubletter (undantag: där det är korrekt/avsiktligt).

## F) (Rekommenderad) Re-index direkt efter MeterCategory-rerender i refresh-pipelinen
`refreshUIFromState()` rerenderar Meter Category **före** visuals (bra), men om `renderCostByMeterCategory()` bygger om DOM så blir `domIndex` potentiellt stale tills nästa explicit `initDomIndex()`.

**Åtgärd (enkel & säker):**
- Inne i `refreshUIFromState()`:
  - efter `renderCostByMeterCategory()` → kör `initDomIndex()` **innan** `updateResourceSelectionVisual()` / `updateHeaderSelectionVisual()`.

**Gate:**
- Manuell: ctrl-click/val i headers ska *alltid* ge korrekt visual feedback direkt efter en rerender utan att kräva extra klick.

---

# Snabb sanity-check (efter regenerering)
Kör dessa i console:

```js
(() => ({
  updateChartDefs: (document.documentElement.innerHTML.match(/function\s+updateChart\s*\(/g)||[]).length,
  hasCategoryFilter: !!document.getElementById('categoryFilter'),
  hasSelectedSubscriptions: (document.documentElement.innerHTML.includes('selectedSubscriptions')),
  hasDatasetsBy: /datasetsBy(Category|Subscription|Meter|Resource)/.test(document.documentElement.innerHTML),
}))();
```

**Förväntat efter Phase 5.1:**
- `updateChartDefs: 1`
- `hasCategoryFilter: false`
- `hasSelectedSubscriptions: false`
- `hasDatasetsBy: false`
