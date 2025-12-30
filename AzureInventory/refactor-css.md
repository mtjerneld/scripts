# CSS Refaktorering - Planering

## Bakgrund

HTML-rapporterna i projektet har inkonsekvent styling. CSS hanteras på flera ställen:
- `Private/Helpers/Get-ReportStylesheet.ps1` (~1700 rader) - central stylesheet
- Varje `Export-*Report.ps1` har inline CSS efter `Get-ReportStylesheet`-anropet
- Vissa komponenter (tabeller, badges, cards) stylas olika i olika rapporter

**Resultat:** Tabeller ser olika ut i olika rapporter, inkonsekvent design.

## Nuvarande struktur

```
Private/Helpers/Get-ReportStylesheet.ps1
├── CSS-variabler (:root)
├── Base styles (body, scrollbar, container)
├── Navigation (.report-nav)
├── Summary cards
├── Dashboard-specifikt
├── VM Backup-specifikt
├── Advisor-specifikt
├── Security-specifikt (via -IncludeReportSpecific)
└── ~1700 rader totalt

Public/Export-*Report.ps1
└── <style>
    ├── $(Get-ReportStylesheet)
    └── /* Report-specific */ (100-500 rader inline per rapport)
```

### Rapporter och deras CSS-hantering

| Fil | Rader | CSS-källa |
|-----|-------|-----------|
| Export-CostTrackingReport.ps1 | 2699 | Get-ReportStylesheet + inline |
| Export-NetworkInventoryReport.ps1 | 3390 | Get-ReportStylesheet + inline |
| Export-RBACReport.ps1 | 2067 | Get-ReportStylesheet + inline |
| Export-EOLReport.ps1 | 1674 | Get-ReportStylesheet + inline |
| Export-ChangeTrackingReport.ps1 | 1115 | Get-ReportStylesheet + inline |
| Export-SecurityReport.ps1 | 950 | Get-ReportStylesheet(-IncludeReportSpecific) + inline |
| Export-DashboardReport.ps1 | 617 | Get-ReportStylesheet + inline |
| Export-VMBackupReport.ps1 | 322 | Get-ReportStylesheet + inline |
| Get-AzureAdvisorRecommendations.ps1 | 608 | Get-ReportStylesheet (collector, ej Public) |

## Mål

1. **Konsekvent design** - Samma komponent ser likadan ut i alla rapporter
2. **Enklare underhåll** - Ändra en CSS-fil, påverka alla rapporter
3. **Separation of concerns** - CSS separerat från PowerShell-logik
4. **DRY** - Ingen duplicerad CSS
5. **Minimera rapport-specifik CSS** - Maximera återanvändbara komponenter

## Design-princip: Komponenter först

**Princip:** Försök alltid göra styling till en återanvändbar komponent. Endast om något är *verkligen* unikt och används *endast* i en rapport → rapport-specifik CSS.

### Analys: Vad är egentligen rapport-specifikt?

| Rapport | "Unikt" idag | Kan generaliseras till komponent? |
|---------|--------------|-----------------------------------|
| Dashboard | Hero section, report-links | `.hero` → komponent, `.link-grid` → komponent |
| Security | Compliance scores circle | `.score-circle` → komponent (återanvänds?) |
| VM Backup | Protection progress bar | `.progress-bar` → komponent |
| Cost | Spending breakdown | Tabeller + cards (redan komponenter) |
| Network | Topology sections | Expandable sections (redan komponent) |
| RBAC | Role hierarchy | Tabeller + sections (redan komponenter) |
| EOL | Lifecycle timeline | `.timeline` → komponent eller tabell |
| Advisor | Recommendation cards | `.expandable-card` → komponent |
| Change | Change diff display | Tabeller + badges (redan komponenter) |

**Slutsats:** De flesta "unika" styles kan generaliseras. `_reports/`-mappen börjar tom.

## Ny struktur (Hybrid-approach)

```
Config/
└── Styles/
    ├── _variables.css          # CSS-variabler (färger, spacing, radier, shadows)
    ├── _base.css               # body, *, scrollbar, .hidden, .text-muted
    ├── _navigation.css         # .report-nav, .nav-brand, .nav-link
    ├── _layout.css             # .container, .page-header, .metadata, .footer
    ├── _components/
    │   ├── cards.css           # .card, .summary-card, .score-card, .quick-stat
    │   ├── tables.css          # .data-table (ersätter alla tabell-varianter)
    │   ├── badges.css          # .badge med modifiers (--success, --danger, etc.)
    │   ├── filters.css         # .filter-section, .filter-group, inputs, selects
    │   ├── sections.css        # .expandable-section (subscription, category, rec)
    │   ├── buttons.css         # .btn, .link
    │   ├── progress-bars.css   # .progress-bar (protection, compliance)
    │   ├── hero.css            # .hero (dashboard, kan återanvändas)
    │   └── score-circle.css    # .score-circle (compliance visualization)
    └── _reports/
        └── (TOM - läggs till endast vid behov efter konsolidering)

Private/Helpers/
└── Get-ReportStylesheet.ps1    # Läser och kombinerar CSS-filer
```

## Implementation - Steg för steg

### Fas 1: Inventering och konsolidering (FÖRST)

Innan CSS extraheras, inventera exakt vilka klasser som används och konsolidera dem.

#### 1.1 Tabell-inventering (FAKTISK)

**Hittade tabell-klasser:**
| Klass | Fil | Rad | Ny klass |
|-------|-----|-----|----------|
| `.vm-table` | Export-VMBackupReport.ps1 | 171 | `.data-table` |
| `.change-table` | Export-ChangeTrackingReport.ps1 | 588, 742 | `.data-table` |
| `.controls-table` | Export-SecurityReport.ps1 | 365 | `.data-table` |
| `.control-resources-table` | Export-SecurityReport.ps1 | 456 | `.data-table` |
| `.resource-summary-table` | Export-SecurityReport.ps1 | 677 | `.data-table` |
| `.resource-issues-table` | Export-SecurityReport.ps1 | 750 | `.data-table` |
| `.device-table` | Export-NetworkInventoryReport.ps1 | 1085, 1145, 1179, 1214, 1712, 1836 | `.data-table` |
| `.risk-table` | Export-NetworkInventoryReport.ps1 | 1784 | `.data-table` |
| `.risk-summary-table` | Export-NetworkInventoryReport.ps1 | 995 | `.data-table` |
| `.cost-table.resource-table` | Export-CostTrackingReport.ps1 | 689, 869 | `.data-table` |
| `.resources-table` | Get-AzureAdvisorRecommendations.ps1 | 431 | `.data-table` |
| `.data-table.matrix-table` | Export-RBACReport.ps1 | 1522 | `.data-table` (behåll matrix-modifier?) |
| `.eol-resource-table` | Export-EOLReport.ps1 | 684 | `.data-table` |

**Totalt:** 13+ unika tabell-klasser → konsolideras till `.data-table`

**Gemensam tabell-struktur:**
```css
.data-table {
    width: 100%;
    border-collapse: collapse;
}
.data-table th {
    background: var(--bg-hover);
    padding: 12px 16px;
    text-align: left;
    font-weight: 600;
    font-size: 0.8rem;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    color: var(--text-muted);
    border-bottom: 1px solid var(--border-color);
}
.data-table td {
    padding: 14px 16px;
    border-bottom: 1px solid var(--border-color);
    font-size: 0.9rem;
}
.data-table tr:last-child td { border-bottom: none; }
.data-table tr:hover td { background: var(--bg-hover); }

/* Modifiers */
.data-table--compact th, .data-table--compact td { padding: 10px 12px; }
.data-table--sticky-header thead { position: sticky; top: 0; z-index: 10; }
```

#### 1.2 Badge-inventering (FAKTISK)

**Hittade badge-klasser:**
| Klass | Fil | Kontext | Ny klass |
|-------|-----|---------|----------|
| `.status-badge.protected` | Export-VMBackupReport.ps1:221 | Backup OK | `.badge.badge--success` |
| `.status-badge.unprotected` | Export-VMBackupReport.ps1:221 | Backup saknas | `.badge.badge--danger` |
| `.status-badge.$powerClass` | Export-VMBackupReport.ps1:220 | running/stopped | `.badge.badge--*` |
| `.status-badge.$healthClass` | Export-VMBackupReport.ps1:225 | healthy/warning | `.badge.badge--*` |
| `.os-badge` | Export-VMBackupReport.ps1:218 | Windows/Linux | `.badge.badge--neutral` |
| `.impact-badge.high/medium/low` | Get-AzureAdvisorRecommendations.ps1:280-282,317 | Impact | `.badge.badge--danger/warning/info` |
| `.security-badge.high/medium` | Export-ChangeTrackingReport.ps1:863-864 | Security flag | `.badge.badge--danger/warning` |
| `.badge.badge-type` | Export-RBACReport.ps1:168+ | PrincipalType | `.badge.badge--neutral` |
| `.badge.badge-orphaned` | Export-RBACReport.ps1:168+ | Orphaned | `.badge.badge--danger` |
| `.badge.badge-external` | Export-RBACReport.ps1:169 | External | `.badge.badge--warning` |
| `.badge.badge-critical` | Export-RBACReport.ps1:171+ | Privileged | `.badge.badge--danger` |
| `.risk-badge.$severity` | Export-NetworkInventoryReport.ps1:1028,1809 | Risk level | `.badge.badge--*` |
| `.badge-gw` | Export-NetworkInventoryReport.ps1:1493 | Gateway type | `.badge.badge--neutral` |
| `.badge.badge-firewall` | Export-NetworkInventoryReport.ps1:1622 | Firewall | `.badge.badge--info` |
| `.badge.severity-$sev` | Export-EOLReport.ps1:656,673-675 | EOL severity | `.badge.badge--*` |
| `.badge.status-$status` | Get-EOLReportSection.ps1:129 | EOL status | `.badge.badge--*` |

**Totalt:** 16+ badge-varianter → konsolideras till `.badge` med modifiers

**Gemensam badge-struktur:**
```css
.badge {
    display: inline-block;
    padding: 4px 10px;
    border-radius: 4px;
    font-size: 0.8rem;
    font-weight: 500;
}

/* Semantic modifiers */
.badge--success { background: rgba(0, 210, 106, 0.15); color: var(--accent-green); }
.badge--danger { background: rgba(255, 107, 107, 0.15); color: var(--accent-red); }
.badge--warning { background: rgba(254, 202, 87, 0.15); color: var(--accent-yellow); }
.badge--warning-high { background: rgba(255, 159, 67, 0.15); color: var(--accent-orange); }
.badge--info { background: rgba(84, 160, 255, 0.15); color: var(--accent-blue); }
.badge--neutral { background: var(--bg-hover); color: var(--text-secondary); }

/* Aliases för specifika användningsfall */
.badge--critical { @extend .badge--danger; }
.badge--high { @extend .badge--warning-high; }
.badge--medium { @extend .badge--warning; }
.badge--low { @extend .badge--info; }
.badge--protected, .badge--healthy, .badge--running { @extend .badge--success; }
.badge--unprotected, .badge--orphaned { @extend .badge--danger; }
.badge--external { @extend .badge--warning; }
```

**OBS:** CSS har ingen @extend - använd samma bakgrund/färg direkt eller använd CSS-variabler.

#### 1.3 Section/Expandable-inventering (FAKTISK)

**Hittade expandable patterns:**
| Klass | Fil | Rader | Ny klass |
|-------|-----|-------|----------|
| `.subscription-section` + `.subscription-header` | Export-VMBackupReport.ps1 | 160-161 | `.expandable` + `.expandable__header` |
| `.subscription-section` + `.subscription-header` | Export-NetworkInventoryReport.ps1 | 1417-1418 | `.expandable` + `.expandable__header` |
| `.category-section` + `.category-header` | Get-AzureAdvisorRecommendations.ps1 | 271-272 | `.expandable` + `.expandable__header` |
| `.category-header` | Export-CostTrackingReport.ps1 | 583, 597, 739, 916, 930 | `.expandable__header` |
| `.subcategory-header` | Export-CostTrackingReport.ps1 | 724, 902 | `.expandable__header` |
| `.meter-header` | Export-CostTrackingReport.ps1 | 570, 680, 709, 860, 888 | `.expandable__header` |
| `.rec-card` + `.rec-header` | Get-AzureAdvisorRecommendations.ps1 | 307, 311 | `.expandable` + `.expandable__header` |
| `.section` + `.section-header` | Export-RBACReport.ps1 | 1627+, 1678+ | `.expandable` + `.expandable__header` |
| `.section` + `.section-header` | RBAC-handoff/Export-RBACReport.ps1 | 661+, 711+, 779+ | `.expandable` + `.expandable__header` |
| `.vnet-header` | Export-NetworkInventoryReport.ps1 | 1444 | `.expandable__header` |
| `.subnet-header` | Export-NetworkInventoryReport.ps1 | 1696 | `.expandable__header` |
| `.risk-summary-section` + `.risk-summary-header` | Export-NetworkInventoryReport.ps1 | 979-980 | `.expandable` + `.expandable__header` |
| `.eol-card-header` | Export-EOLReport.ps1 | 669 | `.expandable__header` |
| `.custom-role-header` | Export-RBACReport.ps1 | 1832 | `.expandable__header` |
| `.principal-view-header` | Export-RBACReport.ps1 | 245, 1712 | `.expandable__header` |
| `.resources-section` + `.resources-header` | Get-AzureAdvisorRecommendations.ps1 | 423-424 | `.expandable` + `.expandable__header` |

**Totalt:** 16+ expandable patterns → konsolideras till `.expandable`

**Gemensam expandable-struktur:**
```css
.expandable {
    border: 1px solid var(--border-color);
    border-radius: 10px;
    overflow: hidden;
    margin-bottom: 16px;
}

.expandable__header {
    padding: 14px 20px;
    cursor: pointer;
    display: flex;
    justify-content: space-between;
    align-items: center;
    background: var(--bg-secondary);
    transition: background 0.2s ease;
}

.expandable__header:hover {
    background: var(--bg-hover);
}

.expandable__content {
    padding: 0;
}

.expandable--collapsed .expandable__content {
    display: none;
}

.expandable__title {
    font-weight: 600;
    font-size: 1.1rem;
}

.expandable__icon {
    width: 0;
    height: 0;
    border-left: 5px solid var(--text-muted);
    border-top: 4px solid transparent;
    border-bottom: 4px solid transparent;
    transition: transform 0.2s;
}

.expandable:not(.expandable--collapsed) .expandable__icon {
    transform: rotate(90deg);
}

/* Size variants */
.expandable--small .expandable__header { padding: 10px 16px; }
.expandable--small .expandable__title { font-size: 0.95rem; }
```

#### 1.4 Card-inventering (FAKTISK)

**Hittade card patterns:**
| Klass | Fil | Rader | Ny klass |
|-------|-----|-------|----------|
| `.summary-card` | Export-VMBackupReport.ps1 | 74-94 | `.card.card--summary` |
| `.summary-card.*` | Export-SecurityReport.ps1 | 113-127 | `.card.card--summary.card--*` |
| `.summary-card.*-border` | Export-NetworkInventoryReport.ps1 | 932-958 | `.card.card--summary` |
| `.summary-card` | Export-ChangeTrackingReport.ps1 | 463-475 | `.card.card--summary` |
| `.summary-card` | Export-CostTrackingReport.ps1 | 1583-1600 | `.card.card--summary` |
| `.summary-card` | Export-EOLReport.ps1 | 1041-1061 | `.card.card--summary` |
| `.summary-card` | Get-AzureAdvisorRecommendations.ps1 | 134-158 | `.card.card--summary` |
| `.summary-card` | Export-RBACReport.ps1 | 1498-1515 | `.card.card--summary` |
| `.summary-card` | RBAC-handoff/Export-RBACReport.ps1 | 545-588 | `.card.card--summary` |
| `.card` + `.card-header/body` | Export-DashboardReport.ps1 | 326-509 | `.card` (behåll) |
| `.score-card` | Export-SecurityReport.ps1 | 156-173 | `.card.card--score` |
| `.category-score-card` | Export-SecurityReport.ps1 | 196 | `.card.card--score.card--small` |
| `.category-card` | Export-CostTrackingReport.ps1 | 582, 596, 738, 915, 929 | `.card` |
| `.meter-card` | Export-CostTrackingReport.ps1 | 569, 679, 708, 859, 887 | `.card.card--small` |
| `.eol-card` | Export-EOLReport.ps1 | 668 | `.card` |
| `.eol-card` | Get-EOLReportSection.ps1 | 47-62 | `.card.card--summary` |
| `.custom-role-card` | Export-RBACReport.ps1 | 1831 | `.card` |
| `.cross-sub-card` | RBAC-handoff/Export-RBACReport.ps1 | 682 | `.card` |

**Totalt:** 18+ card-varianter → konsolideras till `.card` med modifiers

**Gemensam card-struktur:**
```css
.card {
    background: var(--bg-surface);
    border: 1px solid var(--border-color);
    border-radius: 12px;
    overflow: hidden;
}

.card__header {
    padding: 20px 24px;
    border-bottom: 1px solid var(--border-color);
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.card__title {
    font-weight: 600;
    font-size: 1.1rem;
}

.card__body {
    padding: 24px;
}

/* Summary card variant */
.card--summary {
    padding: 20px;
    text-align: center;
    transition: transform 0.2s ease, box-shadow 0.2s ease;
}

.card--summary:hover {
    transform: translateY(-2px);
    box-shadow: var(--shadow-md);
}

.card--summary .card__value {
    font-size: 1.8rem;
    font-weight: 700;
    line-height: 1.2;
}

.card--summary .card__label {
    color: var(--text-muted);
    font-size: 0.75rem;
    margin-top: 6px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

/* Color variants for summary cards */
.card--summary.card--success .card__value { color: var(--accent-green); }
.card--summary.card--danger .card__value { color: var(--accent-red); }
.card--summary.card--warning .card__value { color: var(--accent-yellow); }
.card--summary.card--info .card__value { color: var(--accent-blue); }

/* Score card variant */
.card--score {
    padding: 1.5rem;
    text-align: center;
}

.card--score .card__value {
    font-size: 2.5rem;
    font-weight: 700;
}

/* Size variants */
.card--small { padding: 12px 16px; }
.card--small .card__value { font-size: 1.5rem; }
```

#### 1.5 Progress bar & Score circle inventering (FAKTISK)

**Hittade:**
| Klass | Fil | Användning | Kommentar |
|-------|-----|------------|-----------|
| `.protection-bar` | Get-ReportStylesheet.ps1 | VMBackup protection % | `.progress-bar` |
| `.protection-bar-fill` | Get-ReportStylesheet.ps1 | Fill element | `.progress-bar__fill` |
| `.score-circle` | Get-ReportStylesheet.ps1 | Security compliance | Behåll som specialkomponent |

**Gemensam progress-bar:**
```css
.progress-bar {
    background: var(--bg-surface);
    padding: 20px 24px;
    border-radius: 12px;
    margin-bottom: 30px;
    border: 1px solid var(--border-color);
}

.progress-bar__label {
    display: flex;
    justify-content: space-between;
    margin-bottom: 10px;
    font-size: 0.9rem;
}

.progress-bar__track {
    height: 12px;
    background: var(--bg-hover);
    border-radius: 6px;
    overflow: hidden;
}

.progress-bar__fill {
    height: 100%;
    background: linear-gradient(90deg, var(--accent-green), #00b359);
    border-radius: 6px;
    transition: width 0.5s ease;
}
```

#### 1.6 Filter-inventering (FAKTISK)

**Hittade filter-klasser:**
| Klass | Fil | Rader | Ny klass |
|-------|-----|-------|----------|
| `.filters` | RBAC-handoff/Export-RBACReport.ps1 | 191-192 | `.filter-section` |
| `.filters-row` | RBAC-handoff/Export-RBACReport.ps1 | 200-207 | `.filter-section__row` |
| `.filter-group` | RBAC-handoff/Export-RBACReport.ps1 | 207-231 | `.filter-group` (behåll) |
| `.filter-stats` | RBAC-handoff/Export-RBACReport.ps1 | 236 | `.filter-section__stats` |
| `.global-filter-bar` | Export-CostTrackingReport.ps1 | 1037-1046 | `.filter-section.filter-section--collapsible` |
| `.subscription-filter-container` | Export-CostTrackingReport.ps1 | 1054 | `.filter-section__content` |
| `.filter-actions` | Export-CostTrackingReport.ps1 | 1082-1088 | `.filter-section__actions` |
| `.filter-bar` | Export-CostTrackingReport.ps1 | 1525-1542 | `.filter-section.filter-section--inline` |
| `.filtered-out` | RBAC/CostTracking | flera | `.is-filtered-out` (state) |

**Totalt:** 9+ filter-varianter → konsolideras till `.filter-section`

**Gemensam filter-struktur:**
```css
.filter-section {
    background: var(--bg-surface);
    border: 1px solid var(--border-color);
    border-radius: 12px;
    padding: 16px 20px;
    margin-bottom: 20px;
}

.filter-section__row {
    display: flex;
    flex-wrap: wrap;
    gap: 16px;
    align-items: flex-end;
}

.filter-group {
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.filter-group label {
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    color: var(--text-muted);
}

.filter-group input,
.filter-group select {
    padding: 10px 14px;
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: 8px;
    color: var(--text-primary);
    font-size: 0.9rem;
}

.filter-group input:focus,
.filter-group select:focus {
    outline: none;
    border-color: var(--accent-blue);
}

.filter-section__stats {
    margin-left: auto;
    color: var(--text-muted);
    font-size: 0.85rem;
}

.filter-section__actions {
    display: flex;
    gap: 8px;
}

/* State for filtered items */
.is-filtered-out {
    display: none !important;
}

/* Modifiers */
.filter-section--collapsible .filter-section__content {
    display: none;
}

.filter-section--collapsible.is-expanded .filter-section__content {
    display: block;
}

.filter-section--inline {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 12px 16px;
}
```

#### 1.7 Button-inventering (FAKTISK)

**Hittade button-klasser:**
| Klass | Fil | Rader | Ny klass |
|-------|-----|-------|----------|
| `.filter-btn` | Export-CostTrackingReport.ps1 | 1088-1099 | `.btn.btn--secondary` |
| `.diagram-btn` | Export-NetworkInventoryReport.ps1 | 440-451 | `.btn.btn--secondary` |
| `.diagram-fullscreen-close` | Export-NetworkInventoryReport.ps1 | 1304 | `.btn.btn--close` |
| `.btn-clear` | Get-ReportStylesheet.ps1 | 1157-1168 | `.btn.btn--ghost` |
| `.pagination button` | Export-ChangeTrackingReport.ps1 | 415-429 | `.btn.btn--pagination` |

**Totalt:** 5+ button-varianter → konsolideras till `.btn`

**Gemensam button-struktur:**
```css
.btn {
    padding: 8px 16px;
    border: 1px solid var(--border-color);
    border-radius: 6px;
    background: var(--bg-surface);
    color: var(--text-primary);
    font-size: 0.85rem;
    cursor: pointer;
    transition: all 0.2s ease;
}

.btn:hover {
    background: var(--bg-hover);
    border-color: var(--accent-blue);
}

.btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
}

/* Variants */
.btn--primary {
    background: var(--accent-blue);
    border-color: var(--accent-blue);
    color: white;
}

.btn--primary:hover {
    background: #4590e6;
}

.btn--secondary {
    background: var(--bg-secondary);
}

.btn--ghost {
    background: transparent;
    border-color: transparent;
    color: var(--text-muted);
}

.btn--ghost:hover {
    color: var(--text-primary);
    background: var(--bg-hover);
}

.btn--close {
    background: var(--accent-red);
    border-color: var(--accent-red);
    color: white;
}

.btn--close:hover {
    background: #e55;
}

/* Size variants */
.btn--small {
    padding: 6px 12px;
    font-size: 0.8rem;
}
```

#### 1.8 Hero-inventering (FAKTISK)

**Hittade hero-klasser:**
| Klass | Fil | Rader | Kommentar |
|-------|-----|-------|-----------|
| `.hero` | Get-ReportStylesheet.ps1 | 263-279 | Dashboard-header |
| `.hero h1` | Get-ReportStylesheet.ps1 | 272 | Titel |
| `.hero .subtitle` | Get-ReportStylesheet.ps1 | 279 | Undertitel |
| `.hero .metadata` | Get-ReportStylesheet.ps1 | 138 | Metadata-text |

**Kommentar:** Hero finns redan som komponent i Get-ReportStylesheet. Behåll som `.hero` → flytta till `_components/hero.css`.

#### 1.9 Score-circle inventering (FAKTISK)

**Hittade score-circle användningar:**
| Klass | Fil | Rader | Användning |
|-------|-----|-------|------------|
| `.score-circle` | Get-ReportStylesheet.ps1 | 356-368 | CSS definition |
| `.score-circle` | Export-DashboardReport.ps1 | 333, 368, 399, 429, 485, 511 | Security & backup scores |
| `.compliance-scores-section` | Get-ReportStylesheet.ps1 | 1338-1353 | Security rapport |

**Kommentar:** Score-circle är en specialkomponent (conic-gradient cirkel). Behåll som `.score-circle` → flytta till `_components/score-circle.css`.

#### 1.10 Quick-stats inventering (FAKTISK)

**Hittade quick-stats klasser:**
| Klass | Fil | Rader | Ny klass |
|-------|-----|-------|----------|
| `.quick-stats` | Get-ReportStylesheet.ps1 | 418-425 | `.stats-grid` |
| `.quick-stat` | Get-ReportStylesheet.ps1 | 425-439 | `.stat-item` |
| `.quick-stat .value` | Get-ReportStylesheet.ps1 | 433 | `.stat-item__value` |
| `.quick-stat .label` | Get-ReportStylesheet.ps1 | 439 | `.stat-item__label` |

**Kommentar:** Quick-stats är en variant av summary cards. Kan konsolideras med card-komponenten eller behållas som separat stat-komponent.

**Gemensam stats-struktur:**
```css
.stats-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
    gap: 16px;
}

.stat-item {
    text-align: center;
    padding: 12px;
}

.stat-item__value {
    font-size: 1.5rem;
    font-weight: 700;
    color: var(--text-primary);
}

.stat-item__label {
    font-size: 0.75rem;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.5px;
    margin-top: 4px;
}
```

#### 1.11 Report-links inventering (FAKTISK)

**Hittade report-links klasser:**
| Klass | Fil | Rader | Ny klass |
|-------|-----|-------|----------|
| `.report-links` | Get-ReportStylesheet.ps1 | 445-451 | `.link-grid` |
| `.report-link` | Get-ReportStylesheet.ps1 | 451-464 | `.link-card` |
| `.report-link` (hover) | Get-ReportStylesheet.ps1 | 464 | `.link-card:hover` |
| `.report-link` | Export-DashboardReport.ps1 | 546-595 | Dashboard navigation |

**Kommentar:** Report-links är en variant av card-links. Används endast på Dashboard för navigation till rapporter.

**Gemensam link-card struktur:**
```css
.link-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 16px;
}

.link-card {
    display: block;
    padding: 20px;
    background: var(--bg-surface);
    border: 1px solid var(--border-color);
    border-radius: 12px;
    text-decoration: none;
    color: var(--text-primary);
    transition: all 0.2s ease;
}

.link-card:hover {
    transform: translateY(-2px);
    box-shadow: var(--shadow-md);
    border-color: var(--accent-blue);
}

.link-card__icon {
    font-size: 2rem;
    margin-bottom: 12px;
}

.link-card__title {
    font-weight: 600;
    font-size: 1rem;
}

.link-card__description {
    font-size: 0.85rem;
    color: var(--text-muted);
    margin-top: 6px;
}
```

#### 1.12 Sammanfattning av inventering

| Komponent | Antal varianter | Konsolideras till |
|-----------|-----------------|-------------------|
| **Tabeller** | 13+ | `.data-table` |
| **Badges** | 16+ | `.badge.badge--*` |
| **Expandables** | 16+ | `.expandable` |
| **Cards** | 18+ | `.card.card--*` |
| **Progress bars** | 2 | `.progress-bar` |
| **Filters** | 9+ | `.filter-section` |
| **Buttons** | 5+ | `.btn.btn--*` |
| **Hero** | 1 | `.hero` (behåll) |
| **Score circles** | 1 | `.score-circle` (behåll) |
| **Quick stats** | 1 | `.stats-grid` / `.stat-item` |
| **Report links** | 1 | `.link-grid` / `.link-card` |

**Totalt:** ~80+ CSS-klasser → ~15 konsoliderade komponenter

### Fas 2: Skapa CSS-filstruktur

1. Skapa `Config/Styles/` mappen och undermappar
2. Extrahera CSS-variabler från Get-ReportStylesheet till `_variables.css`
3. Extrahera base styles till `_base.css`
4. Extrahera navigation till `_navigation.css`
5. Extrahera layout till `_layout.css`
6. Skapa komponent-filer med konsoliderade klasser från Fas 1

```
Config/Styles/
├── _variables.css
├── _base.css
├── _navigation.css
├── _layout.css
└── _components/
    ├── tables.css          # .data-table (13+ varianter)
    ├── badges.css          # .badge med modifiers (16+ varianter)
    ├── cards.css           # .card med modifiers (18+ varianter)
    ├── sections.css        # .expandable (16+ varianter)
    ├── filters.css         # .filter-section (9+ varianter)
    ├── buttons.css         # .btn med modifiers (5+ varianter)
    ├── progress-bars.css   # .progress-bar
    ├── stats.css           # .stats-grid, .stat-item
    ├── links.css           # .link-grid, .link-card
    ├── hero.css            # .hero
    └── score-circle.css    # .score-circle
```

### Fas 3: Uppdatera Get-ReportStylesheet.ps1

```powershell
function Get-ReportStylesheet {
    [CmdletBinding()]
    param()

    $moduleRoot = $PSScriptRoot -replace '\\Private\\Helpers$', ''
    $stylesPath = Join-Path $moduleRoot "Config\Styles"

    # Läs core-filer i ordning
    $css = ""

    $coreFiles = @(
        "_variables.css",
        "_base.css",
        "_navigation.css",
        "_layout.css"
    )

    foreach ($file in $coreFiles) {
        $filePath = Join-Path $stylesPath $file
        if (Test-Path $filePath) {
            $css += (Get-Content $filePath -Raw) + "`n"
        }
    }

    # Läs alla komponenter
    $componentsPath = Join-Path $stylesPath "_components"
    if (Test-Path $componentsPath) {
        Get-ChildItem $componentsPath -Filter "*.css" | Sort-Object Name | ForEach-Object {
            $css += (Get-Content $_.FullName -Raw) + "`n"
        }
    }

    # Läs rapport-specifika om de finns (ska normalt vara tomt)
    $reportsPath = Join-Path $stylesPath "_reports"
    if (Test-Path $reportsPath) {
        Get-ChildItem $reportsPath -Filter "*.css" | ForEach-Object {
            $css += (Get-Content $_.FullName -Raw) + "`n"
        }
    }

    return $css
}
```

**Notera:** Ingen `-IncludeReports` parameter behövs längre eftersom vi maximerar komponenter.

### Fas 4: Uppdatera HTML-klassnamn i rapporterna

För varje rapport, uppdatera HTML att använda nya klassnamn.

**Exempel - VMBackup:**
```html
<!-- Före -->
<table class="vm-table">
<span class="status-badge protected">

<!-- Efter -->
<table class="data-table data-table--hover">
<span class="badge badge--success">
```

**Exempel - Security:**
```html
<!-- Före -->
<table class="controls-table">
<span class="status-badge critical">

<!-- Efter -->
<table class="data-table data-table--hover data-table--sticky-header">
<span class="badge badge--danger">
```

**Exempel - Expandable sections:**
```html
<!-- Före -->
<div class="subscription-section">
    <div class="subscription-header">

<!-- Efter -->
<div class="expandable">
    <div class="expandable__header">
```

### Fas 5: Ta bort inline CSS från rapporterna

Varje Export-rapport ska endast ha:
```powershell
$html = @"
<style>
$(Get-ReportStylesheet)
</style>
"@
```

Ingen rapport-specifik CSS inline. Om något verkligen behövs, lägg det i `_reports/` (men målet är att detta ska vara tomt).

### Fas 6: Verifiera och justera

1. Kör varje Test-funktion och öppna rapporten
2. Jämför visuellt med originalet
3. Justera komponent-CSS vid behov
4. Om något måste vara rapport-unikt:
   - Försök först generalisera till komponent
   - Om verkligen omöjligt → lägg i `_reports/{rapport}.css`

## Rapporter att uppdatera

Alla dessa filer behöver uppdateras:

1. `Public/Export-DashboardReport.ps1`
2. `Public/Export-SecurityReport.ps1`
3. `Public/Export-VMBackupReport.ps1`
4. `Public/Export-ChangeTrackingReport.ps1`
5. `Public/Export-CostTrackingReport.ps1`
6. `Public/Export-EOLReport.ps1`
7. `Public/Export-NetworkInventoryReport.ps1`
8. `Public/Export-RBACReport.ps1`
9. `Private/Collectors/Get-AzureAdvisorRecommendations.ps1` (genererar Advisor HTML)

## Testning

Efter varje fas:
1. Kör `Test-SecurityReport` - verifiera att rapporten ser korrekt ut
2. Kör `Invoke-AzureSecurityAudit` - verifiera alla rapporter genereras
3. Öppna varje HTML-fil och kontrollera:
   - Navigation fungerar
   - Tabeller har konsekvent styling
   - Badges har rätt färger
   - Expandable sections fungerar
   - Dark mode theme är korrekt

## CSS-variabler (referens)

Behåll dessa befintliga variabler i `_variables.css`:

```css
:root {
    /* Backgrounds */
    --bg-primary: #0f0f1a;
    --bg-secondary: #1a1a2e;
    --bg-surface: #252542;
    --bg-hover: #2d2d4a;

    /* Text */
    --text-primary: #e8e8e8;
    --text-secondary: #b8b8b8;
    --text-muted: #888;

    /* Accent colors */
    --accent-blue: #54a0ff;
    --accent-green: #00d26a;
    --accent-red: #ff6b6b;
    --accent-yellow: #feca57;
    --accent-orange: #ff9f43;
    --accent-purple: #9b59b6;
    --accent-cyan: #06b6d4;

    /* Semantic */
    --success: var(--accent-green);
    --danger: var(--accent-red);
    --warning: var(--accent-yellow);
    --info: var(--accent-blue);

    /* Border & shadows */
    --border-color: #3d3d5c;
    --radius-sm: 8px;
    --radius-md: 12px;
    --shadow-sm: 0 2px 4px rgba(0, 0, 0, 0.3);
    --shadow-md: 0 4px 12px rgba(0, 0, 0, 0.4);
    --shadow-lg: 0 8px 24px rgba(0, 0, 0, 0.5);
}
```

## Prioritetsordning

1. **Tabeller** (13+ varianter) - Störst visuell inkonsistens, används i alla rapporter
2. **Badges** (16+ varianter) - Används överallt, många duplicerade färgscheman
3. **Cards** (18+ varianter) - Flera överlappande implementationer
4. **Expandables** (16+ varianter) - Duplicerade expand/collapse patterns
5. **Filters** (9+ varianter) - Inkonsekvent filter-UI
6. **Buttons** (5+ varianter) - Olika knapp-styles i olika rapporter
7. **Progress bars, Stats, Links, Hero, Score-circle** - Relativt enkla, flytta från Get-ReportStylesheet

## Noteringar

- Behåll befintlig dark mode - ingen light mode behövs
- JavaScript för expand/collapse ska fortsätta fungera
- Navigation mellan rapporter ska vara konsekvent
- Responsiv design ska bevaras
