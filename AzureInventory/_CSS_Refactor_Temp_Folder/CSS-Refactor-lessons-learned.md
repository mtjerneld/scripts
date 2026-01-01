# Network Inventory Report - CSS Framework Migration Lessons Learned

## Overview

This document captures lessons learned from migrating the Network Inventory report (`Export-NetworkInventoryReport.ps1`) to the new CSS framework. Use this as a reference when migrating other reports.

## Key Migration Patterns

### 1. Table Classes → `.data-table`

**Old Pattern:**
```html
<table class="device-table">
<table class="risk-table">
<table class="risk-summary-table">
```

**New Pattern:**
```html
<table class="data-table data-table--sticky-header data-table--compact">
```

**Key Points:**
- All tables now use `.data-table` as the base class
- Use modifiers for specific behaviors:
  - `data-table--sticky-header` - For tables that need sticky headers when scrolling
  - `data-table--compact` - For tables with less padding (8px instead of 14px)
  - `data-table--extra-compact` - For very dense tables (6px padding)
- The old class names (`device-table`, `risk-table`, etc.) are **removed** - don't keep them for "backward compatibility" as they create confusion

**Common Mistake:**
```html
<!-- WRONG - mixing old and new -->
<table class="device-table data-table">

<!-- CORRECT -->
<table class="data-table data-table--compact">
```

### 2. Badge Classes → `.badge` with Semantic Modifiers

**Old Pattern:**
```html
<span class="risk-badge critical">
<span class="status-badge protected">
<span class="badge-gw">
```

**New Pattern:**
```html
<span class="badge badge--danger">Critical</span>
<span class="badge badge--success">Protected</span>
<span class="badge badge--neutral badge--small">VPN</span>
```

**Severity Mapping:**
- `critical` → `badge--danger` (red)
- `high` → `badge--high` (orange) 
- `medium` → `badge--warning` (yellow)
- `low` → `badge--info` (blue)

**Status Mapping:**
- `protected` / `healthy` / `running` → `badge--success` (green)
- `unprotected` / `orphaned` → `badge--danger` (red)
- `stopped` / `deallocated` → `badge--warning` (yellow)
- Generic/neutral → `badge--neutral` (gray)

**Key Points:**
- Always use **two classes**: base `.badge` + modifier `.badge--*`
- Use semantic modifiers (e.g., `badge--danger`) rather than status-specific ones (e.g., `badge--critical`)
- Size modifiers: `badge--small` for smaller badges
- The old `risk-badge` class is **removed** - use `badge` with severity modifiers

**Common Mistake:**
```html
<!-- WRONG - missing base class -->
<span class="badge--danger">Critical</span>

<!-- WRONG - using old class name -->
<span class="risk-badge critical">Critical</span>

<!-- CORRECT -->
<span class="badge badge--danger">Critical</span>
```

### 3. Expandable Sections → `.expandable` (BEM Pattern)

**Old Pattern:**
```html
<div class="subscription-section">
    <div class="subscription-header" onclick="toggleSubscription('id')">
        <span class="expand-icon"></span>
        <h3>Subscription Name</h3>
    </div>
    <div class="subscription-content" id="id" style="display: none;">
        <!-- content -->
    </div>
</div>
```

**New Pattern:**
```html
<div class="expandable expandable--collapsed">
    <div class="expandable__header" onclick="toggleSubscription('id')">
        <div class="expandable__title">
            <span class="expand-icon"></span>
            <h3>Subscription Name</h3>
        </div>
        <div class="expandable__badges">
            <!-- badges go here -->
        </div>
    </div>
    <div class="expandable__content" id="id" style="display: none;">
        <!-- content -->
    </div>
</div>
```

**Key Points:**
- Use BEM naming: `.expandable`, `.expandable__header`, `.expandable__content`, `.expandable__title`, `.expandable__badges`
- Add `expandable--collapsed` class for initially collapsed sections
- The `expand-icon` class is used for the expand/collapse icon
- JavaScript toggle functions should:
  1. Toggle `expandable--collapsed` class on the parent `.expandable`
  2. CSS automatically handles `display: none` via `.expandable--collapsed .expandable__content`

**Note:**
- The CSS framework may include legacy support for `.subscription-section`, `.subscription-header`, etc. in some reports
- Always use `.expandable` for new code - it's the standard pattern

**Common Mistake:**
```html
<!-- WRONG - mixing BEM with legacy -->
<div class="expandable">
    <div class="subscription-header">

<!-- CORRECT -->
<div class="expandable">
    <div class="expandable__header">
```

### 4. Summary Cards → `.summary-card`

**Current Pattern:**
```html
<div class="summary-card blue-border">
    <div class="summary-card-value">10</div>
    <div class="summary-card-label">VNets</div>
</div>
```

**Key Points:**
- Summary cards use `.summary-card` with color-border modifiers
- This is the **current standard** - use this pattern for consistency
- Color borders: `blue-border`, `green-border`, `purple-border`, `teal-border`, `gray-border`, `red-border`, `orange-border`
- **Important:** All border color classes must be defined in CSS (see "Border Color Classes" section)
- Number comes first, then label
- All numbers use white text - only borders are colored

### 5. Section Headers → Keep Legacy for Now

**Current Pattern:**
```html
<div class="vnet-header" onclick="toggleVNet('id')">
<div class="subnet-header" onclick="toggleSubnet('id')">
```

**Key Points:**
- VNet and subnet headers are still using legacy class names
- These work with the existing JavaScript toggle functions
- Consider migrating to `.expandable__header` in the future, but it's not critical
- The CSS framework provides styling for these legacy classes

## JavaScript Compatibility

### Toggle Functions for Expandable Sections

**Standard Pattern:**
```javascript
function toggleSubscription(id) {
    const content = document.getElementById(id);
    const parent = content.closest('.expandable');
    
    if (parent) {
        parent.classList.toggle('expandable--collapsed');
        // CSS handles display:none via .expandable--collapsed .expandable__content
    }
}
```

**Key Points:**
- Use `.expandable` pattern consistently
- Toggle `expandable--collapsed` class on the parent
- CSS handles the display state automatically
- The `expand-icon` rotation is handled by CSS, not JavaScript
- Keep JavaScript simple - let CSS do the heavy lifting

## Common Gotchas and Pitfalls

### 1. **Missing Base Classes**

**Problem:**
```html
<!-- Missing base .badge class -->
<span class="badge--danger">Critical</span>
```

**Solution:**
Always include the base class:
```html
<span class="badge badge--danger">Critical</span>
```

### 2. **Incorrect Modifier Names**

**Problem:**
```html
<!-- Using old severity names directly -->
<span class="badge badge--critical">
```

**Solution:**
Use semantic modifiers:
```html
<span class="badge badge--danger">  <!-- for critical -->
<span class="badge badge--high">     <!-- for high -->
```

### 3. **Mixing Old and New Classes**

**Problem:**
```html
<!-- Keeping old class "just in case" -->
<table class="device-table data-table">
```

**Solution:**
Remove old classes completely:
```html
<table class="data-table data-table--compact">
```

### 4. **Incorrect BEM Structure**

**Problem:**
```html
<!-- Wrong BEM nesting -->
<div class="expandable">
    <div class="subscription-header">  <!-- should be expandable__header -->
```

**Solution:**
Use proper BEM structure:
```html
<div class="expandable">
    <div class="expandable__header">
        <div class="expandable__title">
```

### 5. **Forgetting Collapsed State**

**Problem:**
```html
<!-- Missing collapsed class, content always visible -->
<div class="expandable">
    <div class="expandable__content">  <!-- visible by default -->
```

**Solution:**
Add collapsed class for initially hidden content:
```html
<div class="expandable expandable--collapsed">
    <div class="expandable__content">  <!-- hidden by default -->
```

### 6. **Inline Styles Overriding CSS**

**Problem:**
```html
<!-- Inline style prevents CSS from working -->
<div class="expandable__content" style="display: block;">
```

**Solution:**
Let CSS handle display state, or use JavaScript to toggle classes:
```html
<div class="expandable__content" id="content-id" style="display: none;">
<!-- JavaScript toggles expandable--collapsed class, CSS handles display -->
```

## Testing Checklist

When migrating a report, verify:

- [ ] All tables use `.data-table` with appropriate modifiers
- [ ] All badges use `.badge` + semantic modifier (e.g., `badge--danger`)
- [ ] Expandable sections use `.expandable` with BEM structure
- [ ] JavaScript toggle functions work with new class structure
- [ ] No old class names remain (search for: `device-table`, `risk-table`, `risk-badge`, etc.)
- [ ] Visual appearance matches original (screenshots before/after)
- [ ] All interactive elements (expand/collapse, filters) still work
- [ ] Responsive design still works on mobile
- [ ] Dark mode colors are correct (no hardcoded colors)

## Search and Replace Patterns

Use these patterns to find and replace old classes:

### Tables
```powershell
# Find old table classes
class="device-table"
class="risk-table"
class="risk-summary-table"

# Replace with
class="data-table data-table--sticky-header data-table--compact"
```

### Badges
```powershell
# Find old badge patterns
class="risk-badge critical"
class="risk-badge high"
class="status-badge protected"

# Replace with
class="badge badge--danger"
class="badge badge--high"
class="badge badge--success"
```

### Expandable Sections
```powershell
# Find old subscription sections
class="subscription-section"
class="subscription-header"

# Replace with
class="expandable"
class="expandable__header"
```

## Best Practices

### 1. **Use Semantic Modifiers**

Prefer semantic meaning over status:
```html
<!-- Good -->
<span class="badge badge--danger">Critical Risk</span>

<!-- Less ideal -->
<span class="badge badge--critical">Critical Risk</span>
```

### 2. **Combine Modifiers When Needed**

```html
<!-- Small danger badge -->
<span class="badge badge--danger badge--small">!</span>

<!-- Compact sticky table -->
<table class="data-table data-table--sticky-header data-table--compact">
```

### 3. **Keep JavaScript Simple**

Let CSS handle as much as possible:
```javascript
// Good - toggle class, CSS handles display
element.classList.toggle('expandable--collapsed');

// Less ideal - manually setting display
element.style.display = element.style.display === 'none' ? 'block' : 'none';
```

### 4. **Test Incrementally**

- Migrate one section at a time
- Test after each section
- Keep old code commented until fully verified

### 5. **Document Report-Specific Needs**

If something truly can't use the framework components, document why:
```powershell
# Network Inventory has custom network diagram - uses report-specific CSS
# This is acceptable as it's unique to this report
```

## Migration Order Recommendation

When migrating other reports, follow this order:

1. **Tables** - Easiest, most visible impact
2. **Badges** - Quick wins, improves consistency
3. **Expandable Sections** - More complex, requires JavaScript updates
4. **Summary Cards** - Use current `.summary-card` pattern (already standardized)
5. **Report-Specific** - Only if truly unique

## Files to Reference

- **CSS Components:**
  - `Config/Styles/_components/tables.css` - Table styles
  - `Config/Styles/_components/badges.css` - Badge styles
  - `Config/Styles/_components/sections.css` - Expandable sections

- **Example Implementation:**
  - `Public/Export-NetworkInventoryReport.ps1` - Fully migrated example

- **Planning Document:**
  - `_CSS_Refactor_Temp_Folder/refactor-css.md` - Overall refactoring plan

## Questions to Ask Before Migrating

1. **Does this component exist in the framework?**
   - Check `Config/Styles/_components/` for available components
   - If not, can it be generalized? (prefer generalization over report-specific)

2. **Is this truly report-specific?**
   - Network diagram: Yes (report-specific)
   - Table of data: No (use `.data-table`)
   - Badge showing status: No (use `.badge`)

3. **Will JavaScript break?**
   - Check all `onclick` handlers
   - Verify toggle functions work with new class structure
   - Test all interactive elements

4. **Are there edge cases?**
   - Empty states
   - Very long content
   - Mobile responsiveness
   - Dark mode colors

## Hero Section / Summary Cards Best Practices

### Wrapping Summary Cards in Section Box

**Pattern:**
```html
<div class="section-box">
    <h2>Network Overview</h2>
    <div class="summary-grid">
        <!-- summary cards -->
    </div>
</div>
```

**Key Points:**
- Always wrap summary cards in a `section-box` with a descriptive title
- This matches the pattern used in SecurityReport and provides consistent structure
- The title helps users understand what the metrics represent

### Summary Card Structure

**Current Pattern:**
```html
<div class="summary-card blue-border">
    <div class="summary-card-value">10</div>
    <div class="summary-card-label">VNets</div>
</div>
```

**Key Points:**
- **Number above description** - Value comes first, then label
- **White text for all numbers** - Don't color the numbers, only the border
- **Border colors define the card** - Use border-color classes, not text colors

### Border Color Classes

**Important:** All border color classes must be defined in CSS:

```css
/* In Config/Styles/_components/cards.css */
.summary-card.blue-border {
    border-color: var(--accent-blue);
}

.summary-card.green-border {
    border-color: var(--accent-green);
}

.summary-card.purple-border {
    border-color: var(--accent-purple);
}

.summary-card.teal-border {
    border-color: var(--accent-cyan);
}

.summary-card.gray-border {
    border-color: var(--text-muted);
}

.summary-card.red-border {
    border-color: var(--accent-red);
}

.summary-card.orange-border {
    border-color: var(--accent-orange);
}
```

**Common Mistake:**
```html
<!-- WRONG - border class not defined, no border color -->
<div class="summary-card blue-border">

<!-- WRONG - using inline style instead of class -->
<div class="summary-card" style="border-color: var(--network-orange);">

<!-- CORRECT -->
<div class="summary-card orange-border">
```

### Removing Redundant Cards

**Best Practice:**
- Don't duplicate information in summary cards that's already shown in dedicated sections
- Example: Remove "NSGs" and "Security Risks" cards if they're already covered in "Issues found" section
- Keep summary cards focused on high-level metrics

## Moving Inline Styles to CSS Files

### Principle: No Inline Styles in Export Modules

**Goal:** All styling should be in CSS files, not inline in PowerShell-generated HTML.

### Common Inline Styles to Move

#### 1. Expandable Section Spacing

**Before:**
```html
<div class="expandable expandable--collapsed" style="margin-bottom: 15px;">
```

**After:**
```html
<div class="expandable expandable--collapsed">
```

**CSS (in sections.css):**
```css
.expandable {
    margin-bottom: 16px; /* Standard spacing */
}
```

#### 2. SVG Icon Styles

**Before:**
```html
<svg style="vertical-align: middle; margin-right: 8px;">
```

**After:**
```html
<svg>
```

**CSS (in sections.css):**
```css
.expandable__title svg {
    vertical-align: middle;
    margin-right: 8px;
    flex-shrink: 0;
}
```

#### 3. H4 Heading Styles

**Before:**
```html
<h4 style="margin:5px 0;">ExpressRoute Connections</h4>
```

**After:**
```html
<h4>ExpressRoute Connections</h4>
```

**CSS (in sections.css):**
```css
.peering-section h4,
.expandable h4 {
    margin: 5px 0 !important;
}
```

#### 4. Status Colors

**Before:**
```html
<td style="color: $statusColor;">Connected</td>
```

**After:**
```html
<td class="status-connected">Connected</td>
```

**PowerShell:**
```powershell
$statusClass = if ($conn.Status -eq "Connected") { "status-connected" } else { "status-disconnected" }
```

**CSS (in tables.css):**
```css
.data-table .status-connected,
.data-table td.status-connected {
    color: #2ecc71;
}

.data-table .status-disconnected,
.data-table td.status-disconnected {
    color: #e74c3c;
}
```

### When Inline Styles Are Acceptable

**Only use inline styles for:**
1. **Dynamic values** that can't be predetermined:
   ```html
   <div style="background-color: $subColor;">  <!-- Subscription color from data -->
   ```
2. **JavaScript-controlled display** (temporary, should be replaced with class toggles):
   ```html
   <div style="display: none;" id="content-id">  <!-- JavaScript will toggle -->
   ```
3. **Text alignment** (if truly one-off):
   ```html
   <td style="text-align:center;">  <!-- Consider creating utility class -->
   ```

### Migration Checklist for Inline Styles

- [ ] Search for all `style="` attributes in the export module
- [ ] Identify which can be moved to CSS classes
- [ ] Create appropriate CSS classes in component files
- [ ] Replace inline styles with classes
- [ ] Test that visual appearance is unchanged
- [ ] Document any remaining inline styles and why they're necessary

## Status Color Classes Pattern

### Creating Reusable Status Classes

**Pattern:**
```css
/* In Config/Styles/_components/tables.css */
.data-table .status-connected,
.data-table td.status-connected {
    color: #2ecc71; /* Green for connected/healthy */
}

.data-table .status-disconnected,
.data-table td.status-disconnected {
    color: #e74c3c; /* Red for disconnected/unhealthy */
}
```

**Usage in PowerShell:**
```powershell
# Instead of:
$statusColor = if ($conn.Status -eq "Connected") { "#2ecc71" } else { "#e74c3c" }
$html += "<td style='color: $statusColor;'>$status</td>"

# Use:
$statusClass = if ($conn.Status -eq "Connected") { "status-connected" } else { "status-disconnected" }
$html += "<td class='$statusClass'>$status</td>"
```

**Benefits:**
- Consistent colors across all reports
- Easy to update globally
- Works with dark mode automatically
- No hardcoded color values in PowerShell

## CSS File Organization

### Removing Unused CSS Files

**Principle:** All CSS should be in `Config/Styles/` - remove any CSS files outside this structure.

**Files to Check:**
- `assets/style.css` - ❌ Remove if unused
- `Templates/assets/style.css` - ❌ Remove if unused
- Any other `.css` files outside `Config/Styles/`

**Verification Process:**
1. Search all PowerShell files for references to the CSS file
2. Check if `Get-ReportStylesheet` references it (it shouldn't)
3. Verify no HTML files link to it
4. If unused, delete it

**Result:** All CSS centralized in `Config/Styles/` makes maintenance easier and prevents confusion.

## Summary

The Network Inventory report migration taught us:

1. **Consistency is key** - Use framework components everywhere possible
2. **BEM naming works** - Makes structure clear and maintainable
3. **Semantic modifiers** - Better than status-specific (e.g., `badge--danger` vs `badge--critical`)
4. **Test thoroughly** - JavaScript compatibility is critical
5. **Remove old classes** - Don't keep them "just in case"
6. **Document exceptions** - If something can't use framework, explain why
7. **Wrap summary cards in sections** - Use `section-box` with descriptive titles
8. **Define all CSS classes** - Border color classes must be defined, don't assume they exist
9. **Move inline styles to CSS** - Keep PowerShell focused on data, CSS on presentation
10. **Use status classes** - Create reusable status color classes instead of inline styles
11. **Centralize CSS** - All CSS should be in `Config/Styles/`, remove unused files elsewhere

Use this document as a reference when migrating other reports to avoid repeating the same mistakes and to ensure consistency across all reports.

---

## Security Report - CSS Framework Migration Lessons Learned

### Overview

This section captures lessons learned from migrating the Security Report (`Export-SecurityReport.ps1`) to the new CSS framework, with a focus on removing inline styles and using report-specific CSS files.

### Key Migration Patterns for Security Report

#### 1. Moving Inline Styles to Report-Specific CSS

**Principle:** All inline `style="..."` attributes should be moved to CSS files. Use `Config/Styles/_reports/security-report.css` for report-specific styles.

**Before:**
```html
<div class="summary-card critical" style="cursor: pointer;">
<div class="category-score-card" style="cursor: pointer;">
<tr class="control-row" style="cursor: pointer;">
<h4 style="margin-top: 2rem; margin-bottom: 1rem;">Failed Controls by Severity</h4>
<div class="subscription-content" style="display: none;">
```

**After:**
```html
<div class="summary-card critical">
<div class="category-score-card">
<tr class="control-row">
<h4>Failed Controls by Severity</h4>
<div class="subscription-content">
```

**CSS (in `Config/Styles/_reports/security-report.css`):**
```css
/* Clickable elements - all interactive cards and rows should have pointer cursor */
.summary-card[data-severity],
.summary-card[data-subscription] {
    cursor: pointer;
}

.category-score-card[data-category] {
    cursor: pointer;
}

.control-row,
.resource-detail-control-row,
.control-detail-row,
.resource-row {
    cursor: pointer;
}

/* Collapsed content - subscription-content should be hidden when header is collapsed */
.subscription-header.collapsed + .subscription-content {
    display: none;
}
```

**Key Points:**
- Use attribute selectors (e.g., `[data-severity]`) to target specific interactive elements
- All clickable elements should have `cursor: pointer` in CSS, not inline
- H4 margin styles are already defined in `sections.css` for `.section-box h4` - remove inline styles
- Collapsed content display is handled by CSS selectors, not inline styles

#### 2. Report-Specific CSS File Structure

**Location:** `Config/Styles/_reports/security-report.css`

**Purpose:** Contains styles that are specific to the Security Report and not used elsewhere.

**Pattern:**
```css
/* Security Report Specific Styles */

/* Clickable elements - all interactive cards and rows should have pointer cursor */
.summary-card[data-severity],
.summary-card[data-subscription] {
    cursor: pointer;
}

/* ... more report-specific styles ... */

/* Note: subscription-header and category-header already have cursor: pointer in sections.css */
/* Note: h4 margin styles are already defined in sections.css for .section-box h4 */
/* Note: category-header.collapsed + .category-content display: none is already in sections.css */
```

**Key Points:**
- `Get-ReportStylesheet` automatically includes all CSS files from `_reports/` folder
- Add comments explaining why styles are report-specific
- Reference existing styles in component files to avoid duplication
- Keep report-specific CSS minimal - prefer generalizing to component files when possible

#### 3. Score Cards and Category Score Cards

**Pattern:**
```html
<!-- Overall/L1/L2/ASB Score Cards -->
<div class="score-card score-excellent">
    <div class="score-label">Overall Score</div>
    <div class="score-value">85%</div>
    <div class="score-details">29 of 50 checks passed</div>
</div>

<!-- Category Score Cards -->
<div class="category-score-card score-good" data-category="AppService">
    <div class="category-score-label">AppService</div>
    <div class="category-score-value">75%</div>
</div>
```

**Key Points:**
- Score cards use `.score-card` with color classes: `score-excellent`, `score-good`, `score-fair`, `score-poor`
- Category score cards use `.category-score-card` with the same color classes
- All score cards should have consistent background color (`var(--bg)`) and hover effects
- Category score cards are clickable and should have `cursor: pointer` (handled in report-specific CSS)

#### 4. Legacy Subscription/Category Headers

**Current Pattern:**
```html
<div class="subscription-header category-header collapsed" data-category-id="$categoryId">
    <span class="expand-icon"></span>
    <h3>Category Name</h3>
    <span class="header-severity-summary">Severity badges</span>
</div>
<div class="subscription-content category-content" id="$categoryId">
    <!-- content -->
</div>
```

**Key Points:**
- Security Report uses legacy `.subscription-header` and `.category-header` classes
- These are supported by `sections.css` for backward compatibility
- `cursor: pointer` is already defined in `sections.css` for these headers - don't add inline styles
- Collapsed state is handled by CSS: `.category-header.collapsed + .category-content { display: none; }`
- For subscription-content, add to report-specific CSS: `.subscription-header.collapsed + .subscription-content { display: none; }`

#### 5. Removing Inline Styles Checklist

**Common Inline Styles to Remove:**

1. **Cursor Pointer:**
   ```html
   <!-- Remove -->
   <div style="cursor: pointer;">
   
   <!-- Add to CSS -->
   .clickable-element { cursor: pointer; }
   ```

2. **Display None:**
   ```html
   <!-- Remove -->
   <div style="display: none;">
   
   <!-- Use CSS selector -->
   .collapsed + .content { display: none; }
   ```

3. **Margin/Padding:**
   ```html
   <!-- Remove -->
   <h4 style="margin-top: 2rem; margin-bottom: 1rem;">
   
   <!-- Already in sections.css -->
   .section-box h4 { margin-top: 2rem; margin-bottom: 1rem; }
   ```

**Migration Process:**
1. Search for all `style="` attributes in the export module
2. Identify which can be moved to CSS classes
3. Check if styles already exist in component CSS files
4. Create report-specific CSS file if needed
5. Replace inline styles with classes or remove if already handled
6. Test that visual appearance is unchanged

#### 6. Consistent Card Styling

**Problem:** Different card types had inconsistent background colors and hover effects.

**Solution:** Ensure all cards in a section use the same styling:

```css
/* In Config/Styles/_components/cards.css */

/* Score cards (Overall, L1, L2, ASB) */
.score-card {
    background: var(--bg);  /* Darker background */
    /* ... */
}

.score-card:hover {
    transform: translateY(-2px);
    box-shadow: var(--shadow-md);
}

/* Category score cards */
.category-score-card {
    background-color: var(--bg);  /* Same darker background */
    /* ... */
}

.category-score-card:hover {
    transform: translateY(-2px);
    box-shadow: var(--shadow-md);  /* Same hover effect */
}

/* Summary cards (Failed Controls by Severity) */
.summary-card {
    background: var(--bg);  /* Same darker background */
    /* ... */
}

.summary-card:hover {
    transform: translateY(-2px);
    box-shadow: var(--shadow-md);  /* Same hover effect */
}
```

**Key Points:**
- All cards in the same section should have the same background color
- All cards should have the same hover effect (transform + box-shadow)
- Use CSS variables (`var(--bg)`) for consistency
- Update all card types together to maintain visual consistency

### Common Gotchas for Security Report

#### 1. **H4 Margin Styles Already Defined**

**Problem:**
```html
<!-- Redundant inline style -->
<h4 style="margin-top: 2rem; margin-bottom: 1rem;">Failed Controls by Severity</h4>
```

**Solution:**
The margin is already defined in `sections.css`:
```css
.section-box h4 {
    margin-top: 2rem;
    margin-bottom: 1rem;
}
```

Simply remove the inline style - it's already handled by CSS.

#### 2. **Cursor Pointer on Headers**

**Problem:**
```html
<!-- Redundant inline style -->
<div class="subscription-header" style="cursor: pointer;">
```

**Solution:**
`cursor: pointer` is already defined in `sections.css`:
```css
.subscription-header,
.category-header {
    cursor: pointer;
}
```

Remove the inline style - it's already handled.

#### 3. **Collapsed Content Display**

**Problem:**
```html
<!-- Inline style for collapsed state -->
<div class="subscription-content" style="display: none;">
```

**Solution:**
Use CSS selector for collapsed state:
```css
/* In report-specific CSS */
.subscription-header.collapsed + .subscription-content {
    display: none;
}
```

**Note:** `.category-header.collapsed + .category-content` is already in `sections.css`, but subscription-content needs to be added to report-specific CSS.

#### 4. **Clickable Table Rows**

**Problem:**
```html
<!-- Inline style on every row -->
<tr class="control-row" style="cursor: pointer;">
```

**Solution:**
Add to report-specific CSS:
```css
.control-row,
.resource-detail-control-row,
.control-detail-row,
.resource-row {
    cursor: pointer;
}
```

#### 5. **Attribute Selectors for Interactive Elements**

**Pattern:**
Use attribute selectors to target elements that should be clickable:

```css
/* Target summary cards with data attributes */
.summary-card[data-severity],
.summary-card[data-subscription] {
    cursor: pointer;
}

/* Target category score cards with data attributes */
.category-score-card[data-category] {
    cursor: pointer;
}
```

**Benefits:**
- Only elements with the data attribute get the cursor
- No need to add a separate class
- Works with existing HTML structure

### Testing Checklist for Security Report

When removing inline styles, verify:

- [ ] All clickable elements show pointer cursor on hover
- [ ] Collapsed sections hide/show correctly
- [ ] H4 headings have correct margins
- [ ] All cards have consistent background colors
- [ ] All cards have consistent hover effects
- [ ] No inline `style="` attributes remain (except for dynamic values)
- [ ] Visual appearance matches original
- [ ] All interactive elements (filters, expand/collapse) still work

### Search Patterns for Security Report

**Find inline styles:**
```powershell
# Search for inline styles
grep -r 'style="' Public/Export-SecurityReport.ps1

# Common patterns to find:
style="cursor: pointer;"
style="display: none;"
style="margin-top: 2rem; margin-bottom: 1rem;"
```

**Replace with CSS classes:**
1. Create appropriate CSS rules in `Config/Styles/_reports/security-report.css`
2. Remove inline `style="..."` attributes
3. Test that functionality is unchanged

### Best Practices for Security Report

#### 1. **Use Report-Specific CSS Sparingly**

Only use `_reports/security-report.css` for styles that are truly Security Report-specific. If a style could be used in other reports, consider:
- Adding it to a component CSS file (e.g., `cards.css`, `sections.css`)
- Generalizing it to work across reports

#### 2. **Reference Existing Styles**

Before adding new CSS, check if it already exists:
- Check `Config/Styles/_components/` for existing styles
- Check `Config/Styles/_reports/` for other report-specific styles
- Add comments referencing existing styles to avoid duplication

#### 3. **Document Why Styles Are Report-Specific**

```css
/* Security Report Specific Styles */

/* Note: subscription-header and category-header already have cursor: pointer in sections.css */
/* Note: h4 margin styles are already defined in sections.css for .section-box h4 */
/* Note: category-header.collapsed + .category-content display: none is already in sections.css */
```

#### 4. **Test After Each Change**

- Remove inline styles incrementally
- Test after each removal
- Verify visual appearance matches original
- Check that interactive elements still work

### Summary: Security Report Migration

The Security Report migration taught us:

1. **Remove all inline styles** - Move to CSS files for maintainability
2. **Use report-specific CSS** - `_reports/security-report.css` for Security Report-only styles
3. **Check existing styles first** - Many styles already exist in component CSS files
4. **Use attribute selectors** - Target interactive elements with data attributes
5. **Consistent card styling** - All cards in a section should have the same background and hover effects
6. **Document existing styles** - Add comments referencing styles in component files
7. **Test incrementally** - Remove inline styles one section at a time
8. **No redundant styles** - Don't duplicate styles that already exist in component CSS

Use these patterns when migrating other reports to ensure consistency and maintainability.

---

## VM Backup Report - CSS Framework Migration Lessons Learned

### Overview

This section captures lessons learned from migrating the VM Backup Report (`Export-VMBackupReport.ps1`) to the new CSS framework, with a focus on dynamic summary cards, filter integration, and handling Azure status values.

### Key Migration Patterns for VM Backup Report

#### 1. Dynamic Summary Cards with JavaScript

**Pattern:** Summary cards can be updated dynamically based on filter selections using JavaScript.

**Implementation:**
```javascript
function updateSummaryCards() {
    // Collect filtered VMs
    const filteredVMs = document.querySelectorAll('.vm-row:not(.hidden)');
    
    // Calculate statistics from filtered data
    const total = filteredVMs.length;
    const protected = filteredVMs.filter(r => r.getAttribute('data-backup') === 'protected').length;
    // ... more calculations
    
    // Update summary cards by index (more reliable than class selectors)
    const cards = document.querySelectorAll('.summary-grid .summary-card');
    if (cards.length >= 6) {
        cards[0].querySelector('.summary-card-value').textContent = total;
        cards[1].querySelector('.summary-card-value').textContent = protected;
        // ... update all cards
    }
}
```

**Key Points:**
- Use index-based card selection when multiple cards share the same border color class
- Recalculate statistics from visible (non-hidden) rows after filtering
- Update progress bar width and label text dynamically
- Call `updateSummaryCards()` after `applyFilters()` when subscription filter changes

#### 2. Filter Integration with Summary Cards

**Pattern:** Filters should update summary cards to reflect filtered data.

**Implementation:**
```javascript
subscriptionFilter.addEventListener('change', () => { 
    applyFilters(); 
    updateSummaryCards(); 
});
```

**Key Points:**
- Always call `updateSummaryCards()` after `applyFilters()` when filters change
- Calculate statistics from filtered/visible rows, not all rows
- Handle edge cases (no visible rows, null values, etc.)

#### 3. Populating Filters from Data

**Pattern:** Dynamic filters should be populated from actual data values, not hardcoded.

**PowerShell:**
```powershell
# Get unique HealthStatus values for filter
$healthStatuses = @($VMInventory | Where-Object { $_.HealthStatus } | 
    Select-Object -ExpandProperty HealthStatus -Unique | Sort-Object)

# Add health status options
foreach ($health in $healthStatuses) {
    $html += "<option value=`"$($health.ToLower())`">$health</option>"
}
```

**Key Points:**
- Extract unique values from actual data
- Use lowercase for filter values (for consistent matching)
- Display original case in option text
- Handle null/empty values appropriately

#### 4. Handling Azure Status Values

**Pattern:** Only treat explicit "Passed" as OK; everything else is a problem.

**Problem:** Azure can return various status values (Passed, Failed, Action required, etc.) that we can't predict.

**Solution:**
```powershell
# Only 'Passed' is OK, everything else is treated as an issue
$healthClass = if ($vm.HealthStatus -eq 'Passed') { 'passed' } else { 'failed' }

# Calculate backup issues
$backupIssues = @($VMInventory | Where-Object { 
    $_.BackupEnabled -and (
        (-not $_.HealthStatus -or $_.HealthStatus -ne 'Passed') -or
        ($_.LastBackupStatus -and $_.LastBackupStatus -ne 'Completed')
    )
}).Count
```

**Key Points:**
- Don't assume we know all possible status values
- Use explicit "Passed" check, treat everything else as failed
- Include null/empty values as issues
- Apply same logic in JavaScript for dynamic updates

#### 5. JavaScript Template Literals in PowerShell

**Problem:** PowerShell interprets `${variable}` as PowerShell variable expansion, not JavaScript template literals.

**Before (Broken):**
```javascript
progressLabel.textContent = `${protected} of ${total} VMs protected (${protectionRate}%)`;
// PowerShell expands ${protected} before output, causing JavaScript syntax errors
```

**After (Fixed):**
```javascript
progressLabel.textContent = protected + ' of ' + total + ' VMs protected (' + protectionRate + '%)';
// Use string concatenation instead
```

**Key Points:**
- Avoid template literals in JavaScript embedded in PowerShell
- Use string concatenation instead: `var1 + ' text ' + var2`
- Test JavaScript in browser console if functions don't work

#### 6. Progress Bar Color Updates

**Pattern:** Progress bars can use semantic colors (green for good, red for bad).

**Implementation:**
```css
.progress-bar__track {
    background: var(--accent-red); /* Red for unprotected/uncovered */
}

.progress-bar__fill {
    background: var(--accent-green); /* Green for protected/covered */
}
```

**Key Points:**
- Use CSS variables for consistency with other components
- Match progress bar colors with summary card colors (e.g., same green/red as stats)
- Update progress bar width dynamically via JavaScript: `progressFill.style.width = protectionRate + '%'`

#### 7. Test Data Must Match Real Data Structure Exactly

**Pattern:** Test data must use exact same property names and structure as real Azure data.

**Critical Properties:**
- `VMName` (not `Name`)
- `OsType` (not `OSType`)
- `VaultName` (not `BackupVaultName`)
- `PolicyName` (not `BackupPolicyName`)
- `HealthStatus` (values: "Passed", "Failed", "Action required", etc.)
- `LastBackupStatus` (values: "Completed", "Failed", etc.)

**Key Points:**
- Test data structure must match exactly - property names are case-sensitive
- Include all fields that the report uses (even if null)
- Use realistic status values that match Azure's actual responses
- Test with various status combinations to ensure robustness

#### 8. Null Safety in JavaScript

**Pattern:** Always check for null before accessing properties or calling methods.

**Implementation:**
```javascript
const healthFilter = document.getElementById('healthFilter');
const healthValue = healthFilter ? healthFilter.value : 'all';

// Set up event listeners only if elements exist
if (healthFilter) {
    healthFilter.addEventListener('change', () => { applyFilters(); updateSummaryCards(); });
}
```

**Key Points:**
- Check if elements exist before using them
- Provide default values for null cases
- Don't assume all filters will always exist (e.g., health filter might not exist if no health data)

#### 9. Table Structure in Subscription Sections

**Pattern:** Use one table per subscription section, not a global table for all subscriptions.

**Implementation:**
```html
<div class="expandable expandable--collapsed subscription-section">
    <div class="expandable__header">
        <!-- Subscription header -->
    </div>
    <div class="expandable__content subscription-content">
        <table class="data-table data-table--sticky-header data-table--compact">
            <!-- Table for this subscription's VMs -->
        </table>
    </div>
</div>
```

**Key Points:**
- Each subscription section has its own table inside `.expandable__content`
- Use standard table modifiers: `data-table--sticky-header` and `data-table--compact`
- This matches the pattern used in Security Report and Network Inventory
- Tables are scoped to their subscription section, making filtering and organization easier

### Common Gotchas for VM Backup Report

#### 1. **JavaScript Syntax Errors from PowerShell Interpolation**

**Problem:**
```javascript
// This breaks because PowerShell expands ${variable}
textContent = `${value} text`;
```

**Solution:**
```javascript
// Use string concatenation
textContent = value + ' text';
```

#### 2. **Multiple Cards with Same Border Color**

**Problem:** When multiple summary cards use the same border color class (e.g., `red-border`), class selectors become ambiguous.

**Solution:** Use index-based selection:
```javascript
const cards = document.querySelectorAll('.summary-grid .summary-card');
cards[0].querySelector('.summary-card-value').textContent = total;
cards[1].querySelector('.summary-card-value').textContent = protected;
// ... etc
```

#### 3. **Filter Values Must Match Data Attributes**

**Problem:** Filter values must match `data-*` attribute values exactly (case-sensitive).

**Solution:**
- Use lowercase for filter values: `value="$($health.ToLower())"`
- Use lowercase for data attributes: `data-health="$healthValue"`
- Match in JavaScript: `health === healthValue` (both lowercase)

#### 4. **Calculating Statistics from Filtered Data**

**Problem:** Summary cards should reflect filtered data, not all data.

**Solution:**
- Only count visible rows: `.vm-row:not(.hidden)`
- Recalculate after every filter change
- Handle empty filtered results gracefully

### Testing Checklist for VM Backup Report

When migrating a report with dynamic filters, verify:

- [ ] All summary cards update when subscription filter changes
- [ ] Progress bar updates when subscription filter changes
- [ ] All filters work independently and together
- [ ] Filter values match data attribute values (case-sensitive)
- [ ] Summary cards show correct values for filtered data
- [ ] JavaScript functions don't throw errors (check browser console)
- [ ] Expandable sections still work after filter changes
- [ ] Test with various status values (Passed, Failed, Action required, null)
- [ ] Test with empty/null health status values
- [ ] Test with no data scenarios

### Summary: VM Backup Report Migration

The VM Backup Report migration taught us:

1. **Dynamic summary cards** - Update cards based on filtered data using JavaScript
2. **Filter integration** - Filters should update summary cards, not just hide rows
3. **Populate filters from data** - Extract unique values from actual data, don't hardcode
4. **Handle unknown status values** - Only treat explicit "Passed" as OK, everything else is a problem
5. **Avoid template literals in PowerShell** - Use string concatenation instead
6. **Use index-based card selection** - When multiple cards share border color classes
7. **Test data must match exactly** - Property names and structure must be identical to real data
8. **Null safety in JavaScript** - Always check for null before accessing properties
9. **Progress bar colors** - Use semantic colors matching summary card colors
10. **Test JavaScript thoroughly** - Check browser console for errors, test all filter combinations
11. **No CSS in export modules** - All CSS must be in CSS files, not in PowerShell export modules (except dynamic values)
12. **One table per subscription** - Each subscription section has its own table with standard modifiers (`data-table--sticky-header data-table--compact`)

Use these patterns when migrating other reports with dynamic filtering and summary cards.

---

## Advisor Report - CSS Framework Migration Lessons Learned

### Overview

This section captures lessons learned from migrating the Advisor Report (`Export-AdvisorReport.ps1`) to the new CSS framework, with a focus on subscription-scoped filtering, dynamic summary card recalculation, and handling alternative cost strategies (RI vs Savings Plans).

### Key Migration Patterns for Advisor Report

#### 1. Subscription-Scoped Filtering with Per-Subscription Breakdown

**Pattern:** When filtering by subscription, all data (summary cards, recommendations, L3 resource tables) should reflect only that subscription's values, not just hide/show elements.

**PowerShell Implementation:**
```powershell
# Calculate per-subscription breakdown for each grouped recommendation
$subBreakdown = @{}
foreach ($res in $group.Group) {
    $subName = $res.SubscriptionName
    if (-not $subName) { continue }
    $subNameLower = $subName.ToLower()
    if (-not $subBreakdown.ContainsKey($subNameLower)) {
        $subBreakdown[$subNameLower] = @{ resources = 0; savings = 0 }
    }
    $subBreakdown[$subNameLower].resources++
    if ($res.PotentialSavings) {
        $subBreakdown[$subNameLower].savings += $res.PotentialSavings
    }
}

# Add to grouped recommendation object
$groupedRec = [PSCustomObject]@{
    # ... other properties ...
    SubBreakdown = $subBreakdown
}

# Output as JSON data attribute
$subBreakdownJson = ($rec.SubBreakdown | ConvertTo-Json -Compress) -replace '"', '&quot;'
$html += @"<tr class="rec-row" data-sub-breakdown="$subBreakdownJson" ...>"
```

**JavaScript Implementation:**
```javascript
// Use breakdown values when filtering by subscription
if (filterBySubscription) {
    const breakdownStr = recRow.getAttribute('data-sub-breakdown');
    if (breakdownStr) {
        const breakdown = JSON.parse(breakdownStr.replace(/&quot;/g, '"'));
        if (breakdown[subscriptionValue]) {
            resources = breakdown[subscriptionValue].resources || 0;
            savings = breakdown[subscriptionValue].savings || 0;
        } else {
            resources = 0;
            savings = 0;
        }
    }
}
```

**Key Points:**
- Store per-subscription breakdown as JSON in `data-sub-breakdown` attribute
- Use breakdown values when filtering by subscription, totals when showing all
- Update visible cell values dynamically (resource count, savings) based on filtered subscription
- Filter L3 resource table rows by subscription using `data-subscription` attribute

#### 2. Alternative Strategies (Not Cumulative) in JavaScript

**Pattern:** When calculating totals, treat alternative strategies (e.g., RI vs Savings Plans) as mutually exclusive, not additive.

**Problem:** JavaScript was summing all savings, including both RI and SP, when they should be alternatives.

**Solution:**
```javascript
// Track RI, SP, and other cost savings separately
let riSavings = 0;
let spSavings = 0;
let otherCostSavings = 0;

// Categorize savings based on problem text
if (rowCategory === 'cost' && savings > 0) {
    if (problemText.includes('reserved instance')) {
        riSavings += savings;
    } else if (problemText.includes('savings plan')) {
        spSavings += savings;
    } else {
        otherCostSavings += savings;
    }
}

// Calculate total: max(RI, SP) + other (RI and SP are alternatives)
const totalSavings = Math.max(riSavings, spSavings) + otherCostSavings;
```

**Key Points:**
- Match PowerShell logic: `$totalSavings = [Math]::Max($riTotal, $spTotal) + $otherCostTotal`
- Categorize recommendations by problem text to identify RI vs SP vs other
- Always use `Math.max()` for alternative strategies, never sum them
- Apply same logic when filtering by subscription

#### 3. Dynamic Cell Updates in Filtered Tables

**Pattern:** When filtering by subscription, update visible cell values (resource count, savings) to reflect filtered data.

**Implementation:**
```javascript
// Update the visible resource count in the row
const resourceCell = recRow.querySelector('td:nth-child(4)');
if (resourceCell) resourceCell.textContent = resources;

// Update savings cell if present
const savingsCell = recRow.querySelector('td:nth-child(3)');
if (savingsCell && savings > 0) {
    const formatNumber = (n) => n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
    const formatted = formatNumber(Math.round(savings));
    savingsCell.textContent = '$ ' + formatted;
} else if (savingsCell && savings === 0) {
    savingsCell.textContent = '-';
}
```

**Key Points:**
- Use `querySelector` with `:nth-child()` to target specific cells
- Format numbers with thousand separators (spaces, not commas)
- Update both resource count and savings cells dynamically
- Handle zero values appropriately (show "-" for savings)

#### 4. Filtering L3 Resource Tables by Subscription

**Pattern:** When filtering by subscription, hide individual resource rows in L3 tables that don't match the selected subscription.

**Implementation:**
```javascript
// Filter L3 resource table rows by subscription
detailRow.querySelectorAll('tbody tr[data-subscription]').forEach(resourceRow => {
    const resSub = (resourceRow.getAttribute('data-subscription') || '').toLowerCase();
    if (!filterBySubscription || resSub === subscriptionValue) {
        resourceRow.classList.remove('hidden');
        visibleResourceCount++;
    } else {
        resourceRow.classList.add('hidden');
    }
});

// Update the "Affected Resources (X)" count
const visibleResources = detailRow.querySelectorAll('tbody tr[data-subscription]:not(.hidden)').length;
const resourcesHeader = detailRow.querySelector('.detail-title');
if (resourcesHeader && resourcesHeader.textContent.includes('Affected Resources')) {
    resourcesHeader.textContent = `Affected Resources (${visibleResources})`;
}
```

**Key Points:**
- Add `data-subscription` attribute to each resource row in L3 tables
- Use lowercase for consistent matching
- Update resource count in header dynamically
- Hide/show rows using `.hidden` class

#### 5. Hiding Sections When Data Isn't Recalculated

**Pattern:** Hide sections that show aggregate data when filtering by subscription if the data isn't recalculated.

**Example:**
```javascript
// Hide cost strategies section when filtering by subscription (data isn't recalculated)
const costStrategiesSection = document.querySelector('.cost-strategies-section');
if (costStrategiesSection) {
    if (subscriptionValue === 'all' || subscriptionValue === '') {
        costStrategiesSection.classList.remove('hidden');
    } else {
        costStrategiesSection.classList.add('hidden');
    }
}
```

**Key Points:**
- Only show aggregate sections when viewing all subscriptions
- Hide sections that would show misleading data when filtered
- Prefer hiding over showing incorrect data

#### 6. Table Column Widths in CSS

**Pattern:** Move table column width styles from inline to CSS.

**Before:**
```html
<th style="width: 40px;"></th>
<th style="width: 120px;">Savings</th>
```

**After:**
```html
<th></th>
<th>Savings</th>
```

**CSS (in report-specific CSS):**
```css
/* Column widths for recommendation table */
.rec-table th:nth-child(1),
.rec-table td:nth-child(1) {
    width: 40px;
}

.rec-table th:nth-child(3),
.rec-table td:nth-child(3) {
    width: 120px;
}
```

**Key Points:**
- Use `:nth-child()` selectors to target specific columns
- Apply to both `th` and `td` for consistency
- Keep column widths in report-specific CSS file

### Common Gotchas for Advisor Report

#### 1. **Alternative Strategies Being Added Instead of Max**

**Problem:**
```javascript
// WRONG - adds RI and SP together
totalSavings += riSavings + spSavings;
```

**Solution:**
```javascript
// CORRECT - RI and SP are alternatives
totalSavings = Math.max(riSavings, spSavings) + otherCostSavings;
```

#### 2. **Not Updating Visible Cell Values**

**Problem:** Summary cards update but table cells still show original values when filtering.

**Solution:** Update both summary cards AND visible table cells:
```javascript
// Update summary cards
updateEl('summary-total-savings', totalSavings);

// Also update visible cells in rows
const savingsCell = recRow.querySelector('td:nth-child(3)');
if (savingsCell) savingsCell.textContent = '$ ' + formatNumber(savings);
```

#### 3. **L3 Resource Tables Not Filtering**

**Problem:** Resource tables show all resources even when filtering by subscription.

**Solution:** Add `data-subscription` to each resource row and filter:
```html
<tr data-subscription="$($resource.SubscriptionName.ToLower())">
```

#### 4. **JSON Escaping in Data Attributes**

**Problem:** JSON in data attributes breaks HTML parsing.

**Solution:** Escape quotes:
```powershell
$subBreakdownJson = ($rec.SubBreakdown | ConvertTo-Json -Compress) -replace '"', '&quot;'
```

And unescape in JavaScript:
```javascript
const breakdown = JSON.parse(breakdownStr.replace(/&quot;/g, '"'));
```

### Testing Checklist for Advisor Report

When implementing subscription-scoped filtering, verify:

- [ ] Summary cards show correct values when filtering by subscription
- [ ] Recommendation rows show correct resource count and savings for selected subscription
- [ ] L3 resource tables show only resources from selected subscription
- [ ] "Affected Resources (X)" count updates correctly
- [ ] Total savings uses max(RI, SP) + other, not sum of all
- [ ] Cost Optimization Strategies section hides when filtering by subscription
- [ ] All filters work together (search + impact + subscription)
- [ ] Switching between subscriptions updates all values correctly
- [ ] "All Subscriptions" shows aggregate values correctly

### Summary: Advisor Report Migration

The Advisor Report migration taught us:

1. **Subscription-scoped filtering** - Store per-subscription breakdown and use it when filtering
2. **Alternative strategies** - Use `Math.max()` for RI/SP, never sum them
3. **Dynamic cell updates** - Update visible table cells, not just summary cards
4. **L3 table filtering** - Filter individual resource rows by subscription
5. **Hide aggregate sections** - Hide sections that show non-recalculated data when filtering
6. **Move column widths to CSS** - Use `:nth-child()` selectors for table column widths
7. **JSON in data attributes** - Escape quotes properly for HTML attributes
8. **Recalculate everything** - Summary cards, table cells, resource counts all need updates
9. **Test with real data** - Subscription filtering must work with actual multi-subscription data

Use these patterns when implementing subscription-scoped filtering in other reports.

---

## CSS Organization Principle

### No CSS in Export Modules

**Principle:** All CSS styling must be in CSS files (`Config/Styles/`), not in PowerShell export modules. The only exception is dynamic inline styles that depend on calculated values.

**Acceptable Inline Styles:**
```html
<!-- Dynamic width based on calculated value -->
<div class="progress-bar__fill" style="width: $protectionRate%"></div>

<!-- Dynamic background color from data -->
<div style="background-color: $subColor;"></div>
```

**NOT Acceptable:**
```html
<!-- Static styles that should be in CSS -->
<div style="cursor: pointer; margin-bottom: 15px;">
<h4 style="margin-top: 2rem; margin-bottom: 1rem;">
<table style="border-collapse: collapse;">
```

**Migration Process:**
1. Search for all `style="` attributes in the export module
2. Identify which are dynamic (depend on calculated values) vs static
3. Move static styles to appropriate CSS files:
   - Component styles → `Config/Styles/_components/`
   - Report-specific styles → `Config/Styles/_reports/[report-name].css`
4. Keep only dynamic inline styles in PowerShell
5. Document any remaining inline styles and why they're necessary

**Benefits:**
- Centralized styling - easier to maintain and update
- Consistent appearance across reports
- Better performance (CSS caching)
- Easier to test and debug
- Follows separation of concerns (data in PowerShell, presentation in CSS)

**Report-Specific CSS Files:**
- Location: `Config/Styles/_reports/[report-name].css`
- Purpose: Styles that are truly specific to one report only
- When to use: Only when a style cannot be generalized to a component
- When NOT to use: If a style could be used in other reports, add it to component CSS instead

**Example Structure:**
```
Config/Styles/
├── _components/          # Reusable components (tables, badges, cards, etc.)
│   ├── tables.css
│   ├── badges.css
│   └── ...
├── _reports/             # Report-specific styles (use sparingly)
│   ├── security-report.css
│   ├── vm-backup-report.css
│   ├── change-tracking-report.css
│   └── ...
└── _variables.css        # CSS variables and theme
```

---

## Change Tracking Report - CSS Framework Migration Lessons Learned

### Overview

This section captures lessons learned from migrating the Change Tracking Report (`Export-ChangeTrackingReport.ps1`) to the new CSS framework, with a focus on section organization, stacked bar charts, dynamic filter updates, and comprehensive section wrapping.

### Key Migration Patterns for Change Tracking Report

#### 1. **Section Boxes for ALL Major Sections (Critical Design Guideline)**

**Pattern:** Every major section of the report must be wrapped in a `<div class="section-box">` with a descriptive `<h2>` title.

**Initial Mistake:**
We initially missed wrapping several sections in `section-box`, which broke visual consistency and spacing.

**Correct Pattern:**
```html
<!-- Change Overview -->
<div class="section-box">
    <h2>Change Overview</h2>
    <div class="summary-grid">
        <!-- summary cards -->
    </div>
</div>

<!-- Changes Over Time -->
<div class="section-box">
    <h2>Changes Over Time (14 days)</h2>
    <div class="trend-chart">
        <!-- chart -->
    </div>
</div>

<!-- Top 5 Insights -->
<div class="section-box">
    <h2>Top 5</h2>
    <div class="insights-grid">
        <!-- insights panels -->
    </div>
</div>

<!-- Security-Sensitive Operations -->
<div class="section-box" id="security-alerts-section">
    <h2>Security-Sensitive Operations</h2>
    <!-- content -->
</div>

<!-- Filters -->
<div class="section-box">
    <h2>Filters</h2>
    <div class="filter-section">
        <!-- filters -->
    </div>
</div>

<!-- Change Log -->
<div class="section-box">
    <h2>Change Log</h2>
    <div id="table-container">
        <!-- table -->
    </div>
</div>
```

**Key Points:**
- **Every major section** gets a `section-box` wrapper
- Each section has a descriptive `<h2>` title
- This provides consistent spacing, borders, and background
- Sections are visually separated and easy to scan
- **This is a critical design guideline** - don't skip it for any section

**Common Mistake:**
```html
<!-- WRONG - missing section-box wrapper -->
<div class="trend-chart">
    <h2>Changes Over Time</h2>
    <!-- chart -->
</div>

<!-- CORRECT -->
<div class="section-box">
    <h2>Changes Over Time (14 days)</h2>
    <div class="trend-chart">
        <!-- chart -->
    </div>
</div>
```

#### 2. Stacked Bar Charts with Legend

**Pattern:** Trend charts can show multiple data series stacked on top of each other (e.g., Create/Update/Delete/Action changes by day).

**HTML Structure:**
```html
<div class="trend-chart">
    <div class="chart-bars">
        <div class="chart-bar-stack" style="height: 45%;">
            <div class="chart-bar-segment" style="height: 20%; background: var(--accent-green);"></div>
            <div class="chart-bar-segment" style="height: 30%; background: var(--accent-blue);"></div>
            <div class="chart-bar-segment" style="height: 10%; background: var(--accent-red);"></div>
            <div class="chart-bar-segment" style="height: 40%; background: var(--accent-orange);"></div>
        </div>
        <!-- more bars -->
    </div>
    <div class="chart-labels">
        <!-- date labels -->
    </div>
    <div class="chart-legend">
        <div class="chart-legend-item">
            <div class="chart-legend-color chart-legend-color--create"></div>
            <span>Create</span>
        </div>
        <!-- more legend items -->
    </div>
</div>
```

**CSS (in report-specific CSS):**
```css
.trend-chart .chart-bar-stack {
    flex: 1;
    display: flex;
    flex-direction: column;
    justify-content: flex-end;
    min-height: 4px;
    border-radius: 3px 3px 0 0;
    overflow: hidden;
}

.trend-chart .chart-bar-segment {
    width: 100%;
    min-height: 1px;
}

.chart-legend {
    display: flex;
    justify-content: center;
    gap: 20px;
    margin-top: 15px;
    flex-wrap: wrap;
}

.chart-legend-item {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 0.85rem;
}

.chart-legend-color {
    width: 16px;
    height: 16px;
    border-radius: 3px;
    flex-shrink: 0;
}
```

**Key Points:**
- Stack container (`.chart-bar-stack`) has dynamic `height` based on total value
- Each segment (`.chart-bar-segment`) has `height` as percentage of stack total
- Stack uses `flex-direction: column` with `justify-content: flex-end` to align to bottom
- Legend shows color mapping for each series
- Use CSS variables for colors (e.g., `var(--accent-green)`)
- Set `min-height` on stack to ensure visibility even for zero values

**PowerShell Implementation:**
```powershell
# Calculate total for the day
$dayTotal = ($dayData.Types.Values | Measure-Object -Sum).Sum

# Set stack height based on max count
$stackHeight = if ($maxCount -gt 0) { ($dayTotal / $maxCount) * 100 } else { 0 }
$html += "<div class='chart-bar-stack' style='height: $stackHeight%;'>"

# Add segments for each type
foreach ($type in $allChangeTypes) {
    $count = if ($dayData.Types.ContainsKey($type)) { $dayData.Types[$type] } else { 0 }
    $segmentHeight = if ($dayTotal -gt 0) { ($count / $dayTotal) * 100 } else { 0 }
    $color = switch ($type) {
        'Create' { 'var(--accent-green)' }
        'Update' { 'var(--accent-blue)' }
        'Delete' { 'var(--accent-red)' }
        'Action' { 'var(--accent-orange)' }
    }
    $html += "<div class='chart-bar-segment' style='height: $segmentHeight%; background: $color;'></div>"
}
```

#### 3. Dynamic Filter Updates Across Multiple Sections

**Pattern:** When a filter changes (e.g., subscription), update multiple sections simultaneously: summary cards, trend chart, and insights.

**JavaScript Implementation:**
```javascript
function applyFilters() {
    // ... filter logic ...
    
    // Update all sections that depend on filters
    updateSummaryCards();
    updateTrendChart();
    updateTop5Insights();
}

function updateSummaryCards() {
    // Recalculate from filtered data
    const filteredChanges = document.querySelectorAll('.change-row:not(.hidden)');
    const creates = Array.from(filteredChanges).filter(r => 
        r.getAttribute('data-type') === 'Create').length;
    // ... calculate other metrics ...
    
    // Update summary cards by ID
    document.getElementById('summary-creates').textContent = creates;
    document.getElementById('summary-updates').textContent = updates;
    // ... etc
}

function updateTrendChart() {
    // Recalculate daily totals from filtered data
    // Regenerate chart bars with new data
}

function updateTop5Insights() {
    // Recalculate top 5 from filtered data
    // Update each insights panel
}
```

**Key Points:**
- Subscription filter should update: Change Overview (summary cards), Changes Over Time (chart), Top 5 (insights), and Change Log (table)
- Recalculate statistics from visible/filtered rows, not all rows
- Update elements by ID for reliability (e.g., `summary-creates`)
- Call all update functions after `applyFilters()`

#### 4. Top 5 Insights Pattern with Dynamic Grid

**Pattern:** Display top N items (e.g., top 5 resource types, categories, callers) in a grid layout with dynamic column sizing.

**HTML Structure:**
```html
<div class="section-box">
    <h2>Top 5</h2>
    <div class="insights-grid">
        <div class="insights-panel" id="insights-resource-types">
            <h3>Changed Resource Types</h3>
            <ul class="insights-list">
                <li><strong>Microsoft.Network/networkSecurityGroups</strong> (10 changes)</li>
                <!-- more items -->
            </ul>
        </div>
        <!-- more panels -->
    </div>
</div>
```

**CSS:**
```css
.insights-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(250px, auto));
    gap: 20px;
    margin-top: 15px;
}

.insights-panel {
    /* When inside section-box, no need for background/border/padding */
    padding: 0;
}

.insights-list li {
    word-break: break-word;
    overflow-wrap: break-word;
}
```

**Key Points:**
- Use `repeat(auto-fit, minmax(250px, auto))` for dynamic column sizing
- Columns grow based on content, but maintain minimum width
- Add `word-break: break-word` to handle long resource type names
- When inside `section-box`, remove redundant padding/border from panels
- Limit to top 5 using `Select-Object -First 5` in PowerShell

**PowerShell:**
```powershell
$topResourceTypes = $ChangeTrackingData | 
    Group-Object ResourceType | 
    Sort-Object Count -Descending | 
    Select-Object -First 5
```

#### 5. Filter Section on One Row

**Pattern:** Keep all filters on a single row, with horizontal scrolling if needed.

**CSS:**
```css
.section-box .filter-section {
    flex-wrap: nowrap;
    overflow-x: auto;
}

.section-box .filter-section .filter-group {
    flex-shrink: 0;
}

.section-box .filter-section .filter-group input {
    width: 180px;
}

.section-box .filter-section .filter-group select {
    min-width: 140px;
    max-width: 200px;
}
```

**Key Points:**
- Use `flex-wrap: nowrap` to prevent wrapping
- Add `overflow-x: auto` for horizontal scrolling on small screens
- Set `flex-shrink: 0` on filter groups to prevent compression
- Set fixed/min/max widths on inputs and selects for consistent sizing

#### 6. Table Column Widths in CSS

**Pattern:** Move table column width styles from inline to CSS using `:nth-child()` selectors.

**CSS:**
```css
/* Change Log Table Column Widths */
#mainChangeTable th:nth-child(1),
#mainChangeTable td:nth-child(1) {
    width: 160px; /* Time column */
    min-width: 160px;
}

#mainChangeTable th:nth-child(2),
#mainChangeTable td:nth-child(2) {
    width: 120px; /* Type column */
    min-width: 120px;
}

/* Apply same widths to Security-Sensitive Operations table */
#security-alerts-section .data-table th:nth-child(1),
#security-alerts-section .data-table td:nth-child(1) {
    width: 160px;
    min-width: 160px;
}
```

**Key Points:**
- Use `:nth-child()` to target specific columns
- Apply to both `th` and `td` for consistency
- Set both `width` and `min-width` for better control
- Apply same widths to multiple tables if they share column structure

#### 7. Type Filter Dynamic Population

**Pattern:** Populate filter options from actual data values, not hardcoded.

**PowerShell:**
```powershell
# Get unique change types from data
$allChangeTypes = @($ChangeTrackingData | 
    Where-Object { $_.ChangeType } | 
    Select-Object -ExpandProperty ChangeType -Unique | 
    Sort-Object)

# Generate filter options
$html += "<select id='typeFilter'>"
$html += "<option value='all'>All Types</option>"
foreach ($type in $allChangeTypes) {
    $html += "<option value='$($type.ToLower())'>$type</option>"
}
$html += "</select>"
```

**Key Points:**
- Extract unique values from actual data
- Use lowercase for filter values (for consistent matching)
- Display original case in option text
- Handle null/empty values appropriately

#### 8. Terminology Consistency

**Pattern:** Use consistent terminology throughout the report.

**Changes:**
- "Security Alerts" → "Sensitive Operations" (section title, summary card label)
- "Security" column → "Sensitivity" column (table headers)
- "Alert" column → "Sensitivity" column (security-sensitive operations table)

**Key Points:**
- Update all references consistently
- Update summary card labels, section titles, and table column headers
- Update JavaScript variable names and comments
- Ensure terminology is clear and accurate

#### 9. Pagination Implementation

**Pattern:** Implement pagination for long tables (e.g., Change Log with 75+ rows).

**HTML Structure:**
```html
<div class="pagination" id="pagination" style="display: none;">
    <button id="prevPage" onclick="changePage(-1)">Previous</button>
    <span class="page-info" id="pageInfo">Page 1 of 2</span>
    <button id="nextPage" onclick="changePage(1)">Next</button>
</div>
```

**CSS:**
```css
.pagination {
    display: flex;
    justify-content: center;
    align-items: center;
    gap: 15px;
    margin-top: 20px;
    padding: 15px 0;
}

.pagination button {
    background: var(--bg-surface);
    border: 1px solid var(--border-color);
    color: var(--text);
    padding: 8px 16px;
    border-radius: 6px;
    cursor: pointer;
}

.pagination button:disabled {
    opacity: 0.5;
    cursor: not-allowed;
}
```

**Key Points:**
- Hide pagination when not needed (single page)
- Show page info (e.g., "Page 1 of 2")
- Disable Previous/Next buttons at boundaries
- Update visible rows based on current page

### Common Gotchas for Change Tracking Report

#### 1. **Missing Section Box Wrappers**

**Problem:**
```html
<!-- Sections not wrapped in section-box -->
<div class="trend-chart">
    <h2>Changes Over Time</h2>
```

**Solution:**
```html
<!-- Wrap every major section -->
<div class="section-box">
    <h2>Changes Over Time (14 days)</h2>
    <div class="trend-chart">
```

#### 2. **Stack Chart Height Not Set**

**Problem:** Stacked chart bars are only 3px high because container height isn't set.

**Solution:** Set `height` on `.chart-bar-stack` based on total value:
```html
<div class="chart-bar-stack" style="height: 45%;">
```

#### 3. **Filter Not Updating All Sections**

**Problem:** Subscription filter only updates table, not summary cards or chart.

**Solution:** Call all update functions:
```javascript
subscriptionFilter.addEventListener('change', () => {
    applyFilters();
    updateSummaryCards();
    updateTrendChart();
    updateTop5Insights();
});
```

#### 4. **Long Text Wrapping in Insights**

**Problem:** Long resource type names wrap unnecessarily.

**Solution:** Add word-break CSS:
```css
.insights-list li {
    word-break: break-word;
    overflow-wrap: break-word;
}
```

#### 5. **Filters Wrapping to Multiple Rows**

**Problem:** Filter elements wrap when they could fit on one row.

**Solution:** Use `flex-wrap: nowrap` and `overflow-x: auto`:
```css
.filter-section {
    flex-wrap: nowrap;
    overflow-x: auto;
}
```

### Testing Checklist for Change Tracking Report

When migrating a report with multiple sections and dynamic filters, verify:

- [ ] All major sections are wrapped in `section-box` with `<h2>` titles
- [ ] Stacked chart bars have correct heights and show all segments
- [ ] Chart legend displays all series with correct colors
- [ ] Subscription filter updates summary cards, chart, and insights
- [ ] Type filter is populated from actual data values
- [ ] Top 5 insights show correct top items from filtered data
- [ ] Filters stay on one row (with horizontal scroll if needed)
- [ ] Table column widths are set in CSS (not inline)
- [ ] Pagination works correctly for long tables
- [ ] Terminology is consistent throughout (Sensitive Operations, not Security Alerts)
- [ ] All sections have consistent spacing and styling

### Summary: Change Tracking Report Migration

The Change Tracking Report migration taught us:

1. **Section boxes for ALL sections** - Every major section must be wrapped in `section-box` with `<h2>` title (critical design guideline)
2. **Stacked bar charts** - Use `.chart-bar-stack` with dynamic height and `.chart-bar-segment` for segments
3. **Chart legends** - Add legends to explain color mapping for stacked charts
4. **Dynamic filter updates** - Filters should update multiple sections (summary cards, chart, insights, table)
5. **Top 5 insights pattern** - Use grid with `repeat(auto-fit, minmax(250px, auto))` for dynamic columns
6. **Word-break handling** - Add `word-break: break-word` for long text in insights
7. **Filters on one row** - Use `flex-wrap: nowrap` and `overflow-x: auto`
8. **Column widths in CSS** - Use `:nth-child()` selectors for table column widths
9. **Dynamic filter population** - Populate filters from actual data, not hardcoded
10. **Terminology consistency** - Use consistent terms throughout (Sensitive Operations, Sensitivity)
11. **Pagination** - Implement pagination for long tables with proper button states
12. **Test data structure** - Ensure test data matches real data structure exactly (e.g., `ChangeTime` not `Timestamp`)

Use these patterns when migrating reports with multiple sections, dynamic charts, and comprehensive filtering.

