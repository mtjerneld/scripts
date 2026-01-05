# Granskning: Phases 1–2 (Cost Tracking Engine)

Jag har gått igenom den senaste `cost-tracking.html` du bifogade och den överensstämmer i stort med planen (engine + factRows + engine-baserade summary cards och chart). **Men just nu finns två rena JavaScript-syntaxfel som gör att scriptet inte kan parsas/köras**, vilket i praktiken blockerar all interaktivitet (filter, klick, uppdatering av cards/chart).

## 1) Blockerande syntaxfel i `updateResourceSelectionVisual()`

I HTML-filen finns detta (ogiltigt JS):

- `document.querySelectorAll([data-resource-id=""]).forEach(...`  
- dessutom finns en lös rad `escape(resourceId);`

Detta måste vara en sträng/selector – och ska använda din `safeResourceId` från `CSS.escape()`.

### Åtgärd (ersätt kodblocket)
Ersätt hela innersta delen i loopen med:

```js
engine.state.picks.resourceIds.forEach(resourceId => {
  const safeResourceId = CSS.escape(resourceId);
  document.querySelectorAll(`[data-resource-id="${safeResourceId}"]`).forEach(el => {
    el.classList.add('chart-selected');
  });
});
```

Och ta bort raden:

```js
escape(resourceId);
```

## 2) Blockerande syntaxfel i `updateChart()` fallback-dataset

I HTML-filen finns:

```js
datasets = [{
  label: Total Cost (SEK),
  ...
}];
```

`label` måste vara en sträng:

### Åtgärd
Byt till:

```js
datasets = [{
  label: 'Total Cost (SEK)',
  data: trend.map(d => d.local),
  backgroundColor: chartColors[0],
  borderColor: chartColors[0],
  borderWidth: 1
}];
```

## 3) Snabb sanity-check efter fix

1. Öppna rapporten och kolla Console: **inga** `Uncaught SyntaxError`.
2. Sätt `window.DEBUG_COST_REPORT = true` i console.
3. Klicka en resource-rad (t.ex. `timekeepercustomertodataverse`).
   - Summary cards ska visa **exakt** den raden (inte totalen).
   - Chart ska uppdateras och summan ska matcha totals (DEBUG-loggen ska säga “Validation passed”).

## Cursor-instruktion (copy/paste)

> Search i `cost-tracking.html` efter `document.querySelectorAll([data-resource-id=""])` och fixa selektorn till template-string med `safeResourceId` enligt ovan. Ta bort raden `escape(resourceId);`.  
> Search efter `label: Total Cost (SEK)` och ändra till `label: 'Total Cost (SEK)'`.  
> Spara, öppna HTML, verifiera att inga SyntaxError finns i console och att klick på en resource-rad ändrar totals och chart.

