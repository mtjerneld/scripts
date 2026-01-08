# PR1 Checklista - Phase 5 (Engine-only UI state + Central refresh/hardening)

## Verifiering innan merge till PR2

### 1. Refresh-pipeline: ingen dubbel definition
- [ ] Gamla `syncUIFromEngine()` är antingen:
  - Byt namn till `syncUIFromEngine_OLD` OCH raderad efter migration, ELLER
  - Raderad direkt när alias införs
- [ ] Grep: `syncUIFromEngine_OLD` = 0 hits (eller aldrig skapad om direkt raderad)
- [ ] Alias-funktioner (`syncUIFromEngine`, `refreshFromEngine`) pekar till `refreshUIFromState()`
- [ ] Alla callsites använder antingen alias eller `refreshUIFromState()` direkt

### 2. Refresh-ordning: render före visuals
- [ ] `refreshUIFromState()` följer exakt ordning:
  1. `updateSummaryCards()`
  2. `renderCostByMeterCategory()` (om inte skip)
  3. `updateResourceSelectionVisual()`
  4. `updateHeaderSelectionVisual()`
  5. `updateChart()` via RAF (sist)
- [ ] Meter Category rerender kommer **före** visual updates (annars "blåser bort" markeringsklasser)

### 3. skipMeterCategoryRerender: maskinell konvention
- [ ] Alla callsites har explicit `skipMeterCategoryRerender: true/false` (aldrig undefined)
- [ ] Scope/picks-ändringar använder `skipMeterCategoryRerender: false`
- [ ] Expand/collapse eller ren visual-sync använder `skipMeterCategoryRerender: true`
- [ ] Granska PR: varje `skip=true` har tydlig anledning (expand/collapse/visual-only)

### 4. Clear button: engine-only (ingen chartSelections)
- [ ] `updateClearSelectionsButtonVisibility()` har **0 referenser** till `chartSelections`
- [ ] Endast kontrollerar: `Object.values(engine.state.picks).some(s => s?.size > 0)`
- [ ] `clearAllChartSelections()` har **0 referenser** till `chartSelections.*.clear()`
- [ ] Clear-funktionen anropar `refreshUIFromState()` (inte legacy update-funktioner)
- [ ] Överväg att byta namn till `clearAllPicks()` (valfritt men rekommenderat)

### 5. Event handlers: alla går via refreshUIFromState
- [ ] Resource click handler → `refreshUIFromState()`
- [ ] Header selection handlers (category/meter/subcategory) → `refreshUIFromState()`
- [ ] Chart view change handler → `refreshUIFromState()`
- [ ] Scope change handlers (subscription filter, etc.) → `refreshUIFromState()`
- [ ] **Inga ad hoc-kedjor** som kallar `updateChart()` / `updateSummaryCards()` direkt från handlers
- [ ] Grep: inga direkta `updateChart()`-anrop från event handlers (endast från `refreshUIFromState()`)

---

## Runtime sanity (kör efter kodändringar)

- [ ] Clear button syns/döljs korrekt baserat på engine picks
- [ ] Ctrl/Cmd picks (headers + resources) fungerar som i Phase 4
- [ ] Ctrl-click storm känns responsivt (RAF förhindrar överdrivna chart-uppdateringar)
- [ ] UI hamnar inte ur sync (visuals matchar engine state)
- [ ] Meter Category expand/collapse bevaras vid picks-ändringar (när `skip=true`)

---

## Grep-gates (kör innan merge)

```bash
# Inga direkta updateChart() från handlers (endast via refreshUIFromState)
rg -n "updateChart\(\)" Public/Export-CostTrackingReport.ps1 | grep -v "refreshUIFromState\|function updateChart"

# Inga syncUIFromEngine_OLD kvar
rg -n "syncUIFromEngine_OLD" Public/Export-CostTrackingReport.ps1

# Clear button ska inte referera chartSelections
rg -n "chartSelections" Public/Export-CostTrackingReport.ps1 | grep -i "clear\|button\|visibility"
```

---

## What changed (3 bullets för PR-beskrivning)

1. **Central refresh pipeline:** Skapade `refreshUIFromState()` med korrekt ordning (render före visuals) och RAF-debouncing för chart
2. **Engine-only state:** Clear button och clear-funktioner använder endast engine state (ingen `chartSelections`)
3. **Alias-migration:** Gamla `syncUIFromEngine()`/`refreshFromEngine()` aliasas till `refreshUIFromState()` för säker migration
