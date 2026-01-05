# Fix: Subscription-filter -> Engine scope (Phase 1–2)

## Varför filtret inte biter
I `cost-tracking.html` är checkbox-markupen:

- `value="MissionPoint"` (display-namnet)
- `data-subid="..."` (id)
- **ingen** `data-subscription="..."`

Men `filterBySubscription()` i HTML letar efter:

```js
document.querySelectorAll('input[type="checkbox"][data-subscription]')
```

Det returnerar **0** checkboxar → `selectedSubs` blir tom → `engine.setScopeSubscriptionNames([])` → `engine.state.scope.subscriptionNames.size === 0`.

## Patch (JS) – ersätt hela `filterBySubscription()`
Byt ut funktionen i den genererade HTML:en (och i PowerShell-templaten som genererar den) till:

```js
function filterBySubscription() {
  // Hitta ALLA subscriptions-checkboxar i filtret
  const checkboxes = document.querySelectorAll('.subscription-checkbox input[type="checkbox"]');
  const selectedSubs = new Set();

  checkboxes.forEach(cb => {
    if (cb.checked) {
      // I din HTML ligger subscription-namnet i value-attributet
      const subName = (cb.value || '').trim();
      if (subName) selectedSubs.add(subName);
    }
  });

  // Engine scope = single source of truth
  engine.setScopeSubscriptionNames(Array.from(selectedSubs));

  // Legacy (behåll tills ni tar bort övrig legacy-logik)
  selectedSubscriptions = selectedSubs;

  // UI + legacy-tabellfiltrering (behåll tills Phase 3–4)
  filterCategorySections();

  if (document.getElementById('resourceSearch')) {
    filterResources();
  } else {
    recalculateTopResources();
  }

  updateSummaryCards();
  updateChart();
  applySearchAndSubscriptionFilters();
}
```

## Snabbvalidering i DevTools Console
1) Kontrollera att checkboxar hittas:
```js
document.querySelectorAll('.subscription-checkbox input[type="checkbox"]').length
```

2) Efter att du kryssat i en subscription:
```js
engine.state.scope.subscriptionNames.size
Array.from(engine.state.scope.subscriptionNames)
engine.getActiveRowIds().size
```

3) Kontrollera att scope faktiskt ger samma mängd rader som “brute force”:
```js
const picked = new Set(Array.from(engine.state.scope.subscriptionNames));
const brute = new Set();
factRows.forEach((r,i) => { if (!picked.size || picked.has(r.subscriptionName)) brute.add(i); });
console.log({ eng: engine.getActiveRowIds().size, brute: brute.size });
```

## Acceptance (för Phase 1–2)
- Väljer du 1 subscription → Cost Overview + chart visar bara den subscriptionens kostnader.
- Väljer du flera → summerar korrekt, utan dubbelräkning.
- `engine.state.scope.subscriptionNames.size > 0` när du har kryssat i något.
