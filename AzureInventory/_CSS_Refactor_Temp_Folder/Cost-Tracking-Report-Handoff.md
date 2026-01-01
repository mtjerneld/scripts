# Cost Tracking Report - CSS Refactoring Handoff

## Overview

This document provides a handoff for refactoring the **Cost Tracking Report** (`Public/Export-CostTrackingReport.ps1`) to align with the new CSS framework. This report has not yet been migrated and requires a comprehensive CSS refactoring following the patterns established in other reports.

## Current Status

- **Report File**: `Public/Export-CostTrackingReport.ps1`
- **CSS File**: `Config/Styles/_reports/cost-tracking-report.css` (does not exist yet - needs to be created)
- **Status**: ❌ Not yet migrated to new CSS framework
- **Inline Styles Found**: At least 1 instance (`style="cursor: pointer;"` on line 984)
- **Legacy Classes**: Uses custom classes like `summary-card`, `subscription-checkbox`, `cost-value`, `meter-card`, `category-card`, etc.

## Key References

### Primary Documentation

1. **CSS Refactoring Lessons Learned**: `_CSS_Refactor_Temp_Folder/CSS-Refactor-lessons-learned.md`
   - Comprehensive guide with patterns from Network Inventory, Security, VM Backup, Change Tracking, and Advisor reports
   - **Critical Section**: "Change Tracking Report - CSS Framework Migration Lessons Learned" (lines ~1772-2316)
   - **Key Pattern**: "Section Boxes for ALL Major Sections" - Every major section must be wrapped in `<div class="section-box">` with `<h2>` title

2. **Testing Guide**: `test-output/README-TestReports.md`
   - How to generate test reports with dummy data
   - Command: `Test-SingleReport -ReportType CostTracking`
   - Test data generator: `Tools/New-TestData.ps1`

### Recently Migrated Reports (Reference Examples)

1. **Change Tracking Report** (`Public/Export-ChangeTrackingReport.ps1`)
   - Most recently migrated - best reference for current patterns
   - Uses `section-box` for all major sections
   - Implements stacked bar charts with legend
   - Dynamic filter updates across multiple sections

2. **VM Backup Report** (`Public/Export-VMBackupReport.ps1`)
   - Good example of dynamic summary cards with JavaScript updates
   - Filter integration patterns
   - Progress bar implementation

3. **Advisor Report** (`Public/Export-AdvisorReport.ps1`)
   - Subscription-scoped filtering patterns
   - Dynamic cell updates in filtered tables
   - Alternative strategies handling (not cumulative)

4. **Security Report** (`Public/Export-SecurityReport.ps1`)
   - Summary cards with border colors
   - Expandable sections with BEM pattern
   - Clickable elements with cursor pointer

## Current Report Structure

Based on initial analysis, the Cost Tracking report includes:

1. **Summary Cards** (lines ~998-1015)
   - Uses `summary-card` class (needs border color modifiers)
   - Likely needs to be wrapped in `section-box` with `<h2>Cost Overview</h2>`

2. **Daily Cost Breakdown** (line ~1022)
   - Has `<h2>Daily Cost Breakdown</h2>` but may not be wrapped in `section-box`
   - Likely contains a trend chart (stacked bar chart)

3. **Subscription Filter** (line ~984)
   - Has `onclick="toggleSubscriptionFilter(this)"` with inline `style="cursor: pointer;"`
   - Needs to be moved to CSS

4. **Expandable Sections**
   - Uses `expandable__header`, `category-header`, `meter-header`
   - Uses `category-content`, `category-card`, `meter-card`
   - May need migration to full BEM pattern (`.expandable`, `.expandable__header`, `.expandable__content`)

5. **Tables**
   - Uses `cost-value` class
   - May need migration to `.data-table` with modifiers

## Migration Checklist

### Phase 1: Initial Assessment

- [ ] Generate test report: `Test-SingleReport -ReportType CostTracking`
- [ ] Review current HTML structure in browser
- [ ] Search for all `style="` attributes in `Export-CostTrackingReport.ps1`
- [ ] Identify all major sections that need `section-box` wrappers
- [ ] List all custom CSS classes that need migration
- [ ] Check for any existing CSS files that might conflict

### Phase 2: Create Report-Specific CSS File

- [ ] Create `Config/Styles/_reports/cost-tracking-report.css`
- [ ] Add header comment: `/* Cost Tracking Report Specific Styles */`
- [ ] Document which styles are report-specific vs could be generalized

### Phase 3: Section Box Wrappers (CRITICAL)

**This is the most important step - don't skip it!**

- [ ] Wrap summary cards in `<div class="section-box"><h2>Cost Overview</h2>`
- [ ] Wrap Daily Cost Breakdown in `<div class="section-box"><h2>Daily Cost Breakdown</h2>`
- [ ] Wrap any other major sections in `section-box` with descriptive `<h2>` titles
- [ ] Verify all sections have consistent spacing and borders

**Reference**: See "Change Tracking Report - CSS Framework Migration Lessons Learned" → "Section Boxes for ALL Major Sections" in the lessons learned document.

### Phase 4: Summary Cards

- [ ] Update summary cards to use border color modifiers:
  - `summary-card blue-border`
  - `summary-card green-border`
  - `summary-card purple-border`
  - etc.
- [ ] Ensure cards use `summary-card-value` and `summary-card-label` structure
- [ ] Verify border color classes are defined in `Config/Styles/_components/cards.css`
- [ ] If not, add them to the component CSS file (not report-specific)

**Reference**: See "Hero Section / Summary Cards Best Practices" in lessons learned document.

### Phase 5: Remove Inline Styles

- [ ] Find all `style="cursor: pointer;"` and move to CSS
- [ ] Find all other inline styles
- [ ] Move static styles to CSS files:
  - Component styles → `Config/Styles/_components/`
  - Report-specific styles → `Config/Styles/_reports/cost-tracking-report.css`
- [ ] Keep only dynamic inline styles (e.g., chart heights, calculated widths)

**Reference**: See "Moving Inline Styles to CSS Files" in lessons learned document.

### Phase 6: Tables

- [ ] Identify all tables in the report
- [ ] Migrate to `.data-table` with appropriate modifiers:
  - `data-table--sticky-header` (if needed)
  - `data-table--compact` (if needed)
- [ ] Remove old table class names
- [ ] Update column widths to use CSS with `:nth-child()` selectors

**Reference**: See "1. Table Classes → `.data-table`" in lessons learned document.

### Phase 7: Expandable Sections

- [ ] Review current expandable section structure
- [ ] Migrate to BEM pattern if needed:
  - `.expandable` (parent)
  - `.expandable__header` (header)
  - `.expandable__content` (content)
  - `.expandable--collapsed` (modifier for collapsed state)
- [ ] Ensure JavaScript toggle functions work with new structure
- [ ] Move `cursor: pointer` from inline to CSS

**Reference**: See "3. Expandable Sections → `.expandable` (BEM Pattern)" in lessons learned document.

### Phase 8: Trend Chart (If Applicable)

- [ ] Review chart structure
- [ ] If stacked bar chart, implement using:
  - `.chart-bar-stack` (container with dynamic height)
  - `.chart-bar-segment` (individual segments)
  - `.chart-legend` (legend for color mapping)
- [ ] Ensure chart is wrapped in `.trend-chart` container
- [ ] Add legend if showing multiple series

**Reference**: See "Change Tracking Report" → "Stacked Bar Charts with Legend" in lessons learned document.

### Phase 9: Filters

- [ ] Review filter section structure
- [ ] Ensure filters stay on one row (use `flex-wrap: nowrap` and `overflow-x: auto`)
- [ ] Move filter styles to CSS
- [ ] If filters update multiple sections, implement JavaScript update functions:
  - `updateSummaryCards()`
  - `updateTrendChart()`
  - etc.

**Reference**: See "Change Tracking Report" → "Filter Section on One Row" and "Dynamic Filter Updates Across Multiple Sections" in lessons learned document.

### Phase 10: Testing

- [ ] Generate test report: `Test-SingleReport -ReportType CostTracking`
- [ ] Verify all sections are wrapped in `section-box`
- [ ] Verify summary cards have correct border colors
- [ ] Verify no inline styles remain (except dynamic values)
- [ ] Verify all tables use `.data-table`
- [ ] Verify expandable sections work correctly
- [ ] Verify filters work and update all relevant sections
- [ ] Verify chart displays correctly (if applicable)
- [ ] Test responsive design (mobile view)
- [ ] Test dark mode colors
- [ ] Compare before/after screenshots

## Common Patterns to Apply

### Summary Cards Pattern

```html
<div class="section-box">
    <h2>Cost Overview</h2>
    <div class="summary-grid">
        <div class="summary-card blue-border">
            <div class="summary-card-value">$1,234.56</div>
            <div class="summary-card-label">Total Cost</div>
        </div>
        <!-- more cards -->
    </div>
</div>
```

### Section Box Pattern

```html
<div class="section-box">
    <h2>Section Title</h2>
    <!-- section content -->
</div>
```

### Expandable Section Pattern

```html
<div class="expandable expandable--collapsed">
    <div class="expandable__header" onclick="toggleFunction()">
        <div class="expandable__title">
            <span class="expand-icon"></span>
            <h3>Section Name</h3>
        </div>
    </div>
    <div class="expandable__content">
        <!-- content -->
    </div>
</div>
```

### Table Pattern

```html
<table class="data-table data-table--sticky-header data-table--compact">
    <thead>
        <tr>
            <th>Column 1</th>
            <th>Column 2</th>
        </tr>
    </thead>
    <tbody>
        <!-- rows -->
    </tbody>
</table>
```

### Stacked Chart Pattern

```html
<div class="trend-chart">
    <div class="chart-bars">
        <div class="chart-bar-stack" style="height: 45%;">
            <div class="chart-bar-segment" style="height: 20%; background: var(--accent-green);"></div>
            <div class="chart-bar-segment" style="height: 30%; background: var(--accent-blue);"></div>
        </div>
    </div>
    <div class="chart-labels">
        <!-- labels -->
    </div>
    <div class="chart-legend">
        <!-- legend items -->
    </div>
</div>
```

## Common Gotchas to Avoid

1. **Missing Section Box Wrappers** - This is the #1 mistake. Every major section needs `section-box`.

2. **Inline Styles** - Don't leave `style="cursor: pointer;"` or other static styles inline. Move to CSS.

3. **Mixing Old and New Classes** - Don't keep old class names "just in case". Remove them completely.

4. **Forgetting Border Color Classes** - Summary card border colors must be defined in CSS. Check `_components/cards.css` first.

5. **Not Testing Filters** - If filters exist, ensure they update all relevant sections (summary cards, charts, tables).

6. **Hardcoding Filter Options** - Populate filters from actual data, not hardcoded values.

## Testing Commands

```powershell
# Load the module and test data generator
. .\Init-Local.ps1
. .\Tools\New-TestData.ps1

# Generate Cost Tracking test report
Test-SingleReport -ReportType CostTracking

# The report will be saved to: test-output/cost-tracking.html
# And automatically opened in your browser
```

## File Locations

- **Report Function**: `Public/Export-CostTrackingReport.ps1`
- **Report-Specific CSS**: `Config/Styles/_reports/cost-tracking-report.css` (create this)
- **Component CSS**: `Config/Styles/_components/` (check existing files)
- **Test Output**: `test-output/cost-tracking.html`
- **Test Data Generator**: `Tools/New-TestData.ps1` (check for `New-TestCostTrackingData` function)

## Questions to Answer

Before starting, answer these questions:

1. **What are all the major sections?** (List them out)
2. **Are there any stacked charts?** (If yes, implement legend)
3. **Do filters update multiple sections?** (If yes, implement update functions)
4. **Are there expandable sections?** (If yes, migrate to BEM pattern)
5. **What summary cards exist?** (List them and assign border colors)
6. **Are there any tables?** (If yes, migrate to `.data-table`)

## Success Criteria

The migration is complete when:

- ✅ All major sections are wrapped in `section-box` with `<h2>` titles
- ✅ All inline styles removed (except dynamic values)
- ✅ Summary cards use border color modifiers
- ✅ All tables use `.data-table` with appropriate modifiers
- ✅ Expandable sections use BEM pattern (if applicable)
- ✅ Filters update all relevant sections (if applicable)
- ✅ Chart has legend (if stacked chart)
- ✅ Report-specific CSS file created and documented
- ✅ Test report generates without errors
- ✅ Visual appearance matches or improves upon original
- ✅ All interactive elements work correctly

## Next Steps After Completion

1. Update this handoff document with any additional patterns discovered
2. Add a "Cost Tracking Report" section to `CSS-Refactor-lessons-learned.md`
3. Document any new patterns that could be reused in other reports
4. Update the testing checklist if new test scenarios are needed

## Support

If you encounter issues:

1. **Check the lessons learned document** - Most patterns are documented there
2. **Reference other migrated reports** - Look at Change Tracking, VM Backup, or Advisor reports
3. **Review component CSS files** - Check `Config/Styles/_components/` for existing patterns
4. **Test incrementally** - Make one change at a time and test

Good luck! 🎨

