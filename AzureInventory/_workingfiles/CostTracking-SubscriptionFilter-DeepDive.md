# Djupanalys: varför subscription-filter inte påverkar engine (Phase 1–2)

## Vad symptomet säger
Du ser att:

- `document.querySelectorAll('.subscription-checkbox input[type="checkbox"]').length` = 5 (så DOM:en hittas)
- men `engine.state.scope.subscriptionNames.size` (och/eller `subscriptionIds.size`) ligger kvar på 0 efter val
- och `engine.getActiveRowIds().size` ändras inte (dvs. scope appliceras inte)

Det innebär nästan alltid att **engine aldrig får in någon “scope”-data**, eller att den scope-datan **inte matchar index** och därför blir “tom” och i praktiken behandlas som “ingen scope”.

## Mest sannolika rotorsak i din HTML
Din checkbox-markup använder `data-subid` (subscription-id), medan den ursprungliga Phase 1–2-koden ofta läser `data-subscription` (namn).

I din engine är dessutom `subscriptionIds` kommenterad som *Checkbox selections*, och `subscriptionNames` som “compat”. Det är alltså mer robust att använda **ID** som scope.

**Konsekvens:** Om du läser fel attribut (eller bara namn som inte matchar exakt) blir scope-setet tomt → engine tolkar det som “ingen scope” → alla rader inkluderas.

## Rekommenderad fix (inom Phase 2, inte Phase 3–4)

### 1) Sätt scope på subscriptionIds (primärt) – och ev. names sekundärt
Byt `filterBySubscription()` till att:

- läsa `data-subid`
- skicka ID:n till `engine.setScopeSubscriptions([...])`
- (valfritt) även skicka namn till `engine.setScopeSubscriptionNames([...])` så att legacy och debug blir enklare

**Patch (JS):**
```js
function filterBySubscription() {
  const checkboxes = document.querySelectorAll('.subscription-checkbox input[type="checkbox"]');

  const selectedSubIds = [];
  const selectedSubNames = [];

  checkboxes.forEach(cb => {
    if (!cb.checked) return;

    const subId = cb.getAttribute('data-subid');
    if (subId) selectedSubIds.push(subId);

    // display name (ofta i value)
    const name = cb.value || cb.getAttribute('value');
    if (name) selectedSubNames.push(name);
  });

  // Single source of truth
  engine.setScopeSubscriptions(selectedSubIds);

  // Optional (compat/debug)
  engine.setScopeSubscriptionNames(selectedSubNames);

  // Legacy (tills den tas bort)
  selectedSubscriptions = new Set(selectedSubNames);

  // UI refresh
  updateSummaryCards();
  updateChart();
  applySearchAndSubscriptionFilters();

  // Debug (tillfälligt)
  console.debug('filterBySubscription()', {
    checked: checkboxes.length,
    selectedSubIds,
    selectedSubNames,
    scopeIdsSize: engine.state.scope.subscriptionIds.size,
    scopeNamesSize: engine.state.scope.subscriptionNames.size
  });
}
```

### 2) Säkerställ att index bygger både bySubscriptionId och bySubscriptionName
Din engine ska indexera båda (den verkar redan göra det). Om du vill dubbelkolla i koden:

- `index.bySubscriptionId.set(row.subscriptionId, new Set())`
- `index.bySubscriptionName.set(row.subscriptionName, new Set())`

## Tester du kan köra direkt i konsolen (för att validera Phase 1–2)

> Kör testen efter att du bockat i EN subscription.

### Test 1 — Checkboxar är faktiskt i “checked” state
```js
Array.from(document.querySelectorAll('.subscription-checkbox input[type="checkbox"]'))
  .map(cb => ({ checked: cb.checked, subid: cb.getAttribute('data-subid'), value: cb.value }))
```
Förväntat: minst en rad med `checked: true` och ett `subid`.

### Test 2 — Scope-set i engine uppdateras
```js
engine.state.scope.subscriptionIds.size
Array.from(engine.state.scope.subscriptionIds)
```
Förväntat: size > 0 (om du valt något). (Om 0 men du har checked:true i Test 1 → handlern körs inte, eller patchen är inte i den HTML du testar.)

### Test 3 — ActiveRowIds matchar brute filter på subscriptionId
```js
const picked = new Set(Array.from(engine.state.scope.subscriptionIds));
const brute = new Set();

factRows.forEach((r, i) => {
  if (!picked.size || picked.has(r.subscriptionId)) brute.add(i);
});

console.log({
  eng: engine.getActiveRowIds().size,
  brute: brute.size,
  diff: engine.getActiveRowIds().size - brute.size
});
```
Förväntat: `diff: 0` och eng/brute ska minska när du väljer en subscription.

### Test 4 — Summary cards matchar sumCosts() för active rows
```js
const active = engine.getActiveRowIds();
const s = engine.sumCosts(active);
console.log(s);
```
Förväntat: samma totals som korten (avrundning i presentation kan ge +-0.01).

## Varför “Clear Chart Selections” inte syns vid resursval (just nu)
I Phase 1–2 är det vanligt att knappen fortfarande tittar på **legacy selection state** (t.ex. `chartSelections`) och inte på `engine.state.picks`.

Alltså: **resurs-picks fungerar i engine**, men UI-komponenten som visar “Clear Chart Selections” har ännu inte kopplats om.

Det här är typiskt en Phase 3–4-sak (när all selection-state flyttar helt till engine).

## Varför du kan selektera resurs i Subscription-tabellen men inte Meter Category-tabellen
Samma logik: click-handlern i Phase 1–2 är ofta bara kopplad till de rader som fått rätt `data-*` attribut och/eller ligger i den container som event delegation tittar på.

Meter Category-tabellen saknar sannolikt (ännu) `data-resource-id` på raderna eller hamnar utanför handlerns “scope”.
Det är rimligt att låta detta ligga till Phase 3–4 om det ingår där.

---
Om du vill kan jag (utan att tjuvstarta Phase 3–4) ge en **minsta möjliga patch** som *endast* kopplar om “Clear Chart Selections” till engine.picks, men det är egentligen en Phase 3-grej.
