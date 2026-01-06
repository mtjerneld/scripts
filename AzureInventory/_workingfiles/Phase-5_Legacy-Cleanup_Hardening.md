# Phase 5 – Legacy Cleanup & Hardening (Cost Tracking Refactor)

## Syfte
Phase 4 levererar ny funktionalitet (header-filters + engine-baserade charts). Phase 5 ska:
- göra **engine** till enda *source of truth* för state/filter/chart-data
- rensa ut eller isolera **legacy datamodeller/kodvägar** som kan orsaka regressioner
- minska filstorlek/laddtid och förbättra underhållbarhet

## Guiding principles
- **Inga nya features** i Phase 5 (endast konsolidering, borttagning, hardening).
- Ändra inte semantik utan aktivt beslut:
  - Scope = AND (påverkar allt)
  - Picks = UNION (men “strict policy” begränsar kors-dimension OR i UX)
  - Meter Category = scope-only (tills separat beslut)
- Rensa i små, säkra PR:ar med tydliga “gates”.

---

## P5-1: Engine som enda state-källa i UI (ta bort dubbel-logik)
### Leverans
- Uppdatera UI så att all “selected state” kommer från `engine.state.*`:
  - “Clear selection”-logik ska **endast** utgå från engine scope/picks.
  - Ta bort all runtime-beroende logik på `chartSelections` i produktionsflöde.

### Implementation (checklista)
- [ ] Uppdatera `updateClearSelectionsButtonVisibility()` → engine-only
- [ ] Uppdatera `clearSelections()`/motsv. → clear engine picks + ev scope (enligt befintligt beteende)
- [ ] Ta bort/feature-flagga all kod som läser `chartSelections` i UI-render

### Acceptance
- [ ] Clear-knapp syns/hides korrekt baserat på engine state
- [ ] Inga visuella “selected”-indikatorer baseras på `chartSelections`
- [ ] Snabb sanity: ctrl-click filters + resource picks funkar som i Phase 4

---

## P5-2: Avveckla legacy chart pipeline (engine-only charts)
### Leverans
- `updateChart()` ska vara engine-only för **alla views**.
- Ta bort eller isolera legacy chart-kod:
  - `updateChart_OLD()`
  - `filterRawDailyDataBySelections(...)` och relaterade helpers
  - any “legacy rawDailyData path” som riskerar att återaktiveras

### Implementation (checklista)
- [ ] Radera eller flytta `updateChart_OLD()` bakom `DEBUG_LEGACY` (ej inkluderad i generator / runtime)
- [ ] Radera eller isolera `filterRawDailyDataBySelections(...)`
- [ ] Säkerställ att `updateChart()` aldrig refererar `rawDailyData`

### Acceptance
- [ ] Alla chart views renderar utan exceptions
- [ ] `updateChart()` använder engine-data för total + stacked views
- [ ] Dataset-sortering (stacked-subscription) fortsatt korrekt

---

## P5-3: Minimera eller avveckla `rawDailyData` i output (stor vinst, större risk)
### Leverans (alternativ)
**A) Full borttagning** (om inget längre använder `rawDailyData`)  
**B) Slimming** (om något fortfarande behöver det)
- begränsa fält, komprimera, eller ersätt med engine-komprimerad struktur

### Implementation (checklista)
- [ ] Inventera: finns någon view eller funktion som fortfarande behöver `rawDailyData`?
- [ ] Om nej: sluta serialisera in `rawDailyData` i HTML
- [ ] Om ja: minimera schema (minsta nödvändiga fält) och dokumentera varför

### Acceptance
- [ ] Rapportstorlek minskar mätbart (logga före/efter, ex. KB/MB)
- [ ] Ingen regress i chart views eller tabeller
- [ ] Laddtid i browser förbättras (subjektivt + gärna enkel timing)

---

## P5-4: Standardisera pick-nycklar (canonical keys)
### Leverans
- En canonical pick per dimension (minimera parallella legacy-set):
  - Resource: **`resourceKeys`** (canonical), fasa ut `resourceIds/names/groups` som primär
  - Meter: `meterName` (eller `meterId` om ni har stabilt id)
  - Subcategory: `subscriptionId|category|subcategory`

### Implementation (checklista)
- [ ] Engine normaliserar input direkt till canonical keys
- [ ] Legacy keys (om de fortfarande kommer in) map:as vid input och “släcks” internt
- [ ] Uppdatera visual-sync att endast läsa canonical keys

### Acceptance
- [ ] Engine använder canonical sets internt
- [ ] Grep: ingen ny kod skriver till legacy picksets i runtime
- [ ] Selektion och filter funkar som tidigare (Phase 4 behavior)

---

## P5-5: UI hardening & prestanda
### Leverans
- Central `refreshUIFromState()` som alltid kallar (i rätt ordning):
  1) `updateSummaryCards()`
  2) `updateChart()` (debounced/RAF om behövs)
  3) `updateResourceSelectionVisual()`
  4) `updateHeaderSelectionVisual()`

### Implementation (checklista)
- [ ] Inför debounce/RAF runt `updateChart()` för ctrl-click storm
- [ ] Säkerställ att visual-sync körs efter:
  - scope-change
  - clear selection
  - picks-change (header + resources)

### Acceptance
- [ ] Ctrl-click “storm” känns responsivt
- [ ] UI hamnar inte “out of sync” (ingen felmarkerad header/card)
- [ ] Ingen regress i expand/collapse (render manipulerar inte display)

---

# Out of scope (för att hålla Phase 5 ren)
- Nya charts, nya tabeller, nya workflows eller ny UX
- Byte av semantik (t.ex. picks=AND) utan separat designbeslut
- Större datamodellförändringar som kräver rework av generator/format (lägg i egen fas)

---

# Rekommenderad PR-struktur (säker leverans)
1) **PR1:** P5-1 + P5-5 (engine single source of truth + UI hardening)
2) **PR2:** P5-2 (ta bort legacy chart pipeline)
3) **PR3:** P5-3 + P5-4 (rådata-reduktion + canonical keys)  
   > PR3 kan delas upp om risknivån känns hög.

---

# Acceptance tests (snabba, praktiska)
## A) Grep-gates (kan köras manuellt eller i CI)
- [ ] `chartSelections` används inte i produktionsflöde (tillåtet endast bakom DEBUG)
- [ ] `updateChart_OLD` refereras inte
- [ ] `filterRawDailyDataBySelections` refereras inte i runtime
- [ ] `rawDailyData` serialiseras inte (om P5-3A), eller schema är minimerat (om P5-3B)

## B) Konsoltester (runtime sanity)
1) **Charts renderar engine-only**
   - Byt view mellan: total / stacked-category / stacked-subscription / stacked-meter / stacked-resource
   - Verifiera: fler datasets för stacked-views, inga exceptions

2) **Other stämmer per dag**
   - Summera stacked datasets per dag och jämför mot `engine.trendByDay(engine.getActiveRowIds())`
   - Diff ska vara ~0 (avrundningstolerans)

3) **Scope + picks**
   - Scope 1 subscription → bara den synlig, totals matchar
   - Picks out-of-scope → activeRows=0 (om det är design), men UI visar tydligt läge

---

# Definition of Done (Phase 5)
- Engine är enda state-källa i UI och charts.
- Legacy chart pipeline och selection state är borttagen eller isolerad bakom DEBUG.
- `rawDailyData` är borttagen eller kraftigt minimerad med dokumenterad anledning.
- Canonical keys används konsekvent.
- En uppsättning grep-gates + runtime sanity tests passerar.
