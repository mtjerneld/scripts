# Cost Tracking – Refaktorplan (Cursor-ready, v2)

> Mål: bygga om **Cost Tracking** så att du kan **multiselektera i flera tabeller och på flera nivåer**, och att **kort + diagram** alltid visar kostnader för **alla filtrerade resurser** – men **varje resurs/row räknas bara en gång** även om den matchar flera val samtidigt.

---

## 0) Varför det blir “fel” idag (symptom, inte plåster)

I nuvarande implementation bygger du filtrering på **flera parallella, aggregerade datastrukturer** (categories/subscriptions/meters/resources per dag) och en komplex `chartSelections`-modell där val kan “kaskadera” (förälder→barn) och där logiken ibland blir **union** (OR) och ibland **intersection** (AND). Det gör det lätt att:

- råka välja fler resurser än avsett (barn/relaterade objekt följer med),
- dubbelräkna när flera tabeller påverkar samma aggregerade totals,
- få inkonsekvens p.g.a. blandade datatyper (t.ex. `number` vs `{CostLocal, CostUSD}`), vilket du redan “skyddar” med `getCostValue()` och extra checks. fileciteturn8file2  
- sitta fast i “spaghetti”: varje ny tabell kräver ny speciallogik i filtreringsfunktionen.

**Refaktorn nedan gör att totals och diagram alltid räknas från en enda källa: en canonical fact-tabell.** Då blir “räkna en gång” trivialt (via rowId/resourceId).

---

## 1) Target behavior (exakt semantik)

### 1.1 Grundprincip
Alla klick/val (i alla tabeller och nivåer) ska i slutändan koka ner till en **mängd av rader** i en canonical fact-tabell (eller en mängd resurser om du vill summera per resurs).

- **Totals (SEK/USD):** sum(cost) över *unika fact rows* i mängden.
- **Trend/Chart:** group-by day över *unika fact rows* i mängden.
- **Top lists:** group-by resource över samma mängd.

### 1.2 Kombinera val från flera tabeller
Du har två praktiska alternativ. Jag rekommenderar A.

**A) “Union-of-selections” + “Scope filters” (rekommenderas)**  
- Alla klickval i tabeller/diagram kombineras som **OR** (union).  
- Separata “scope filters” (t.ex. Subscription-checkboxar, datumintervall) kombineras som **AND** (intersection) mot unionen.

Exempel:  
- Du klickar `Category = Storage` i en tabell och `Resource = X` i en annan → resultat = (alla rows som matchar Storage) ∪ (alla rows som matchar Resource X), inom scope (t.ex. valda subscriptions).  
- Om du dessutom kryssar bort en subscription → allt ovan begränsas till scope.

**B) Full boolesk builder (AND/OR per dimensiongrupp)**  
Mer flexibelt men mer UI, och lätt att bygga fel. Börja med A, lägg B senare om du behöver.

---

## 2) Ny arkitektur – tydlig separation

### 2.1 Lager
1. **Generator (PowerShell)**  
   - Hämtar usage/cost data  
   - Normaliserar till **factRows**  
   - Skriver HTML + bäddar in JSON (eller skriver separat `.json`)

2. **Data Engine (JS/TS i reporten)**  
   - Bygger index (dimension → rowIds)
   - Håller selection state
   - Exponerar `getFilteredRowIds()` och aggregatfunktioner

3. **UI Views (tabeller/kort/diagram)**  
   - Renderar från engine-aggregat
   - Skickar “selection intents” till engine
   - *Inga egna summeringar* (allt går via engine)

Detta tar bort behovet av att filtrera en komplex per-dag struktur som `rawDailyData` (som idag bäddas in i HTML). fileciteturn8file3

---

## 3) Canonical data model (det viktigaste)

### 3.1 Fact rows (minsta gemensamma nämnare)
Skapa en enda array:

```js
// rowId = index i arrayen (0..n-1)
factRows[rowId] = {
  day: "2025-12-06",          // YYYY-MM-DD
  subscriptionId: "...",      // GUID
  subscriptionName: "MissionPoint",
  resourceId: "/subscriptions/.../resourceGroups/.../providers/...",
  resourceName: "timekeepercustomertodataverse",
  resourceGroup: "missionpoint_it",
  meterCategory: "Logic Apps",        // eller “ServiceName / MeterCategory”
  meterSubcategory: "Consumption",    // om du har
  meterName: "Consumption Built-in Actions",
  costLocal: 203.10,
  costUSD: 21.34,
  currency: "SEK"
}
```

**Viktigt**  
- Använd **resourceId** som primärnyckel för resurser (namn kan krocka).  
- Om Azure-data saknar USD per rad: räkna fram USD konsekvent (eller lämna 0 och visa bara local).

### 3.2 Dimensioner (för snabba filter och rendering)
Bygg unika listor (kan göras i PS eller JS):

```js
dims = {
  subscriptions: [{id,name}],
  categories: ["Storage","Logic Apps",...],
  meters: ["B DTU","Standard Private Endpoint",...],
  resources: [{resourceId, resourceName, resourceGroup, subscriptionId}],
  days: ["2025-12-01", ...]
}
```

### 3.3 Index (dimension → rowIds)
Bygg i JS när sidan laddar:

```js
index = {
  bySubscriptionId: Map<subscriptionId, Set<rowId>>,
  byCategory: Map<meterCategory, Set<rowId>>,
  byMeter: Map<meterName, Set<rowId>>,
  byResourceId: Map<resourceId, Set<rowId>>,
  byResourceGroup: Map<resourceGroup, Set<rowId>>,
  byDay: Map<day, Set<rowId>>,
}
```

Detta gör filtrering O(k) i antal val, inte O(n) över alla rows.

---

## 4) Selection state (en modell som inte spagettar)

### 4.1 State
```js
state = {
  scope: {
    subscriptionIds: new Set(), // checkboxar
    dayFrom: null,
    dayTo: null,
  },
  picks: {
    resourceIds: new Set(),
    meterNames: new Set(),
    categories: new Set(),
    resourceGroups: new Set(),
    // ev fler
  }
}
```

### 4.2 Union + scope intersection
```js
function getScopeRowIds() {
  // starta med ALLA rows eller day-range först
}

function getPickedRowIdsUnion() {
  // union av alla picks (resourceIds, meters, categories, ...)
}

function getActiveRowIds() {
  const scope = getScopeRowIds();
  const picked = getPickedRowIdsUnion();
  if (picked.size === 0) return scope;
  return intersect(scope, picked);
}
```

**Dedup sker automatiskt** eftersom mängden består av unika `rowId`.

---

## 5) Engine API (konkret och testbar)

### 5.1 `engine.js`
Implementera som ett litet, rent modul-API:

```js
export function createEngine(factRows) {
  const index = buildIndex(factRows);

  const state = createInitialState();

  function togglePick(dimension, value, mode="toggle") { ... }
  function setScopeSubscriptions(subIds) { ... }
  function setScopeDayRange(from,to) { ... }

  function getActiveRowIds() { ... }

  // Aggregation
  function sumCosts(rowIds) { ... }              // returns {local, usd}
  function trendByDay(rowIds) { ... }            // returns [{day,local,usd}]
  function groupByResource(rowIds) { ... }       // returns array sorted desc
  function groupByCategory(rowIds) { ... }
  function groupByMeter(rowIds) { ... }

  return { state, togglePick, setScopeSubscriptions, setScopeDayRange,
           getActiveRowIds, sumCosts, trendByDay, groupByResource, groupByCategory, groupByMeter };
}
```

### 5.2 En enda väg för UI
Alla UI-komponenter ska göra:

1) `rowIds = engine.getActiveRowIds()`  
2) `totals = engine.sumCosts(rowIds)`  
3) `trend = engine.trendByDay(rowIds)`  
4) render

Detta eliminerar att “kort och chart visar olika totals”.

---

## 6) UI: klick, multiselect och tydlighet

### 6.1 Multiselect regler
- Klick utan modifier → replace selection i den dimensionen (valfritt, men ofta bäst UX)  
- Ctrl/Cmd-klick → toggle i dimensionen  
- Shift-klick → range (valfritt senare)

### 6.2 Visual feedback
- Allt som kan klickas måste visa “selected”-state.
- Lägg en “Active filters”-rad som visar chips: `Category: Storage ×` osv.

### 6.3 Tabeller på flera nivåer
Du kan fortsätta ha drilldowns (category → meter → resources), men:
- Drilldown handlar bara om *vad du visar*, inte *hur du räknar*.
- När du klickar “meter” ska engine få `togglePick("meterNames", meterName, ...)`.

**Top-resources och meter-tabeller kan renderas från `groupByResource()` och `groupByMeter()`** – inga specialsummeringar.

---

## 7) PowerShell: ändringar som behövs (generator)

Du har idag en `rawDailyData`-struktur som innehåller nested totals och blandade typer. fileciteturn8file2  
Refaktorn kräver att du istället (eller parallellt i migrationen) exporterar `factRows`.

### 7.1 Minimal PS-ändring (första steget)
1) Bygg `factRows` från din `$rawData` (usage rows) **innan** du skapar `DailyTrend`.
2) `ConvertTo-Json -Depth 6 -Compress` och escape för JS-inbäddning (som du gör idag).

**Utkast (pseudo i PS)**
```powershell
$factRows = foreach ($row in $rawData) {
  [pscustomobject]@{
    day = ($row.Date).ToString("yyyy-MM-dd")
    subscriptionId = $row.SubscriptionId
    subscriptionName = $row.SubscriptionName
    resourceId = $row.ResourceId
    resourceName = $row.ResourceName
    resourceGroup = $row.ResourceGroup
    meterCategory = $row.MeterCategory
    meterSubcategory = $row.MeterSubcategory
    meterName = $row.Meter
    costLocal = [math]::Round($row.CostLocal, 2)
    costUSD   = [math]::Round($row.CostUSD, 2)
    currency  = $currency
  }
}
$factRowsJson = $factRows | ConvertTo-Json -Depth 4 -Compress
```

### 7.2 HTML: bädda in
I HTML (där du idag har `rawDailyData = JSON.parse('...')`) lägger du:

```js
const factRows = JSON.parse('$factRowsJson');
const engine = createEngine(factRows);
```

---

## 8) Migration plan (utan att bränna allt på en gång)

### Fas 1 – Lägg till factRows + engine, men behåll UI
**Mål:** totals/kort räknas från factRows (engine), även om tabellerna fortfarande är gamla.

- Embed `factRows` i HTML.
- Skapa `engine.js` inline i HTML (temporärt).
- Byt ut `updateSummaryCards()` så den använder engine:
  - `rowIds = engine.getActiveRowIds()`
  - `totals = engine.sumCosts(rowIds)`
- Låt `chartSelections` finnas kvar under fas 1, men mappa den till engine-state (tillfälligt).

Acceptance:
- Om du väljer exakt en resurs ska totals = dess summerade kostnad (över period, inom scope).

### Fas 2 – Bygg om chart och top lists mot engine
- Trendchart data = `engine.trendByDay(rowIds)`
- Datasets per kategori/meter/resurs = groupBy-funktioner (inte specialbyggda datastrukturer)

### Fas 3 – Bygg om drilldown-tabeller
- Alla tabeller renderar från engine-aggregat + index.
- Klick uppdaterar engine picks direkt.
- Ta bort `rawDailyData` och all specialfiltrering (t.ex. `filterRawDailyDataBySelections`). fileciteturn8file2

### Fas 4 – Städa/optimera
- Flytta JS till separata filer (om du vill).
- Lägg test-fixtures.
- Lägg “Active filters”-chips och “Clear all”.

---

## 9) Cursor – exakta coding instructions (kopiera som task-lista)

> Nedan är avsiktligt formulerat så att du kan klistra in i Cursor som en “implementation plan”.

### Task 1: Introducera canonical `factRows` i PS-generatorn
1. I `Export-CostTrackingReport.ps1`: skapa `$factRows` från `$rawData` (en rad per cost record).
2. Serialize till `$factRowsJson` och embed i HTML nära där `rawDailyData` embed:as idag.
3. Lägg `console.log('factRows', factRows.length)` i HTML för sanity-check.

**Done när:**
- Reporten laddar utan JS-error.
- `factRows.length` > 0 och rimligt.

### Task 2: Skapa `engine` (inline först)
1. Skapa en `createEngine(factRows)` i en ny `<script>`-sektion.
2. Implementera:
   - `buildIndex()`
   - `getActiveRowIds()` enligt “Union picks + scope intersection”
   - `sumCosts(rowIds)`

**Done när:**
- Du kan i konsolen köra `engine.sumCosts(engine.getActiveRowIds())` och få ett rimligt totalvärde.

### Task 3: Koppla “scope” (subscription-checkboxar) till engine
1. Där checkboxar idag uppdaterar `selectedSubscriptions`, byt till:
   - `engine.setScopeSubscriptions([...])`
2. Uppdatera summary cards med engine totals.

**Done när:**
- Kryssa subscription → totals ändras korrekt.

### Task 4: Koppla resource-click (minsta möjliga)
1. I resource-tabellen: på row-click, använd `resourceId` (lägg in som `data-resource-id`).
2. På click:
   - om Ctrl/Cmd: `engine.togglePick('resourceIds', id, 'toggle')`
   - annars: `engine.togglePick('resourceIds', id, 'replace')`
3. Efter toggle: `renderAll()` (kort + chart).

**Done när:**
- Klick på en resurs ger totals = enbart den resursens kostnad (inom scope).

### Task 5: Flytta chart till engine trend
1. Byt chart-data source till `engine.trendByDay(activeRowIds)`.
2. Valfri breakdown-views:
   - `engine.groupByCategory(activeRowIds)` för stacked.

**Done när:**
- Chart och totals matchar alltid (sum per day = total).

### Task 6: Refaktorera tabeller
1. Bygg tabellmodeller från engine:
   - Category view: `groupByCategory()`
   - Meter view: `groupByMeter()`
   - Resource view: `groupByResource()`
2. Rendera tabeller från dessa modeller.

**Done när:**
- Du kan ta bort `rawDailyData` och all filtreringslogik kopplad till den.

---

## 10) Extra förbättringar (efter att det funkar)

- **Persist selection i URL** (`?subs=...&res=...`) så reporten går att dela.
- **Export-knapp** “Export current selection to CSV”.
- **Performance:** om factRows blir stora, byt Set(rowId) till sorterade arrays + tvåpekars-intersect.

---

## Appendix A – Notering om tabeller som visar “meter-cost”
Det är helt OK att en meter-tabell visar *kostnad inom meter*, men att totals visar *kostnad över alla meters* för den valda resursen. Se till att UI tydligt label:ar det (“Cost within meter” vs “Total for selected resources”). Meter-tabellen i HTML visar redan meter-level rader. fileciteturn8file11
