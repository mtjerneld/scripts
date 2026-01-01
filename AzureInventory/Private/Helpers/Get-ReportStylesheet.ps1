<#
.SYNOPSIS
    Generates common CSS stylesheet for audit reports.

.DESCRIPTION
    Returns the common CSS variables and base styles used across all audit reports.
    This includes dark mode theme variables, navigation styles, and common layout elements.
    CSS is now loaded from modular component files in Config/Styles/.

.EXAMPLE
    $css = Get-ReportStylesheet
#>
function Get-ReportStylesheet {
    [CmdletBinding()]
    param()
    
    $moduleRoot = $PSScriptRoot -replace '\\Private\\Helpers$', ''
    $stylesPath = Join-Path $moduleRoot "Config\Styles"
    
    $css = ""
    
    # Read core files in order
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
    
    # Read all components (sorted alphabetically for consistency)
    $componentsPath = Join-Path $stylesPath "_components"
    if (Test-Path $componentsPath) {
        Get-ChildItem $componentsPath -Filter "*.css" | Sort-Object Name | ForEach-Object {
            $css += (Get-Content $_.FullName -Raw) + "`n"
        }
    }
    
    # Read report-specific styles (should be empty initially)
    $reportsPath = Join-Path $stylesPath "_reports"
    if (Test-Path $reportsPath) {
        Get-ChildItem $reportsPath -Filter "*.css" | Sort-Object Name | ForEach-Object {
            $css += (Get-Content $_.FullName -Raw) + "`n"
        }
    }
    
    # Add utility classes that are used across reports
    $css += @"
/* Utility classes */
.metric-row {
    display: flex;
    justify-content: space-between;
    padding: 12px 0;
    border-bottom: 1px solid var(--border-color);
}

.metric-row:last-child {
    border-bottom: none;
}

.metric-label {
    color: var(--text-secondary);
}

.metric-value {
    font-weight: 600;
}

.metric-value.critical { color: var(--accent-red); }
.metric-value.high { color: #ff9f43; }
.metric-value.medium { color: var(--accent-yellow); }
.metric-value.low { color: var(--accent-blue); }
.metric-value.green { color: var(--accent-green); }
.metric-value.red { color: var(--accent-red); }

.vault-link {
    color: var(--accent-blue);
    text-decoration: none;
}

.vault-link:hover {
    text-decoration: underline;
}

h2 {
    color: var(--text);
    font-size: 1.3rem;
    margin: 30px 0 20px 0;
    font-weight: 600;
}

/* Status classes */
.status-ok {
    color: var(--success);
    font-weight: 600;
}

.status-fail {
    color: var(--danger);
    font-weight: 600;
}

.status-warn {
    color: var(--warning);
    font-weight: 600;
}

/* Security report specific row styles */
.control-row,
.resource-row {
    transition: opacity 0.2s, transform 0.2s;
}

.control-row.hidden,
.resource-row.hidden {
    display: none;
}

.control-row:hover,
.resource-row:hover {
    background-color: var(--bg);
}

.resource-detail-row {
    background-color: var(--bg);
}

.resource-detail-control-row {
    cursor: pointer;
    transition: background-color 0.2s;
}

.resource-detail-control-row:hover {
    background-color: var(--bg-hover);
}

.resource-detail-control-row.expanded {
    background-color: var(--bg-hover);
}

.control-detail-row {
    cursor: pointer;
    transition: background-color 0.2s;
}

.control-detail-row:hover {
    background-color: var(--bg-hover);
}

.control-detail-row.expanded {
    background-color: var(--bg-hover);
}

.control-resources-row {
    background-color: var(--bg);
}

.control-resources-row.hidden {
    display: none;
}

.resource-detail-row.hidden {
    display: none;
}

.resource-row.expanded {
    background-color: var(--bg-hover);
}

.control-row.expanded {
    background-color: var(--bg-hover);
}

/* Remediation styles */
.remediation-row {
    background-color: var(--bg);
}

.remediation-content {
    padding: 1rem;
    background-color: var(--bg);
    border-left: 3px solid var(--accent-blue);
}

.remediation-section {
    margin-bottom: 1.5rem;
}

.remediation-section:last-child {
    margin-bottom: 0;
}

.remediation-section h4 {
    margin-top: 0;
    margin-bottom: 0.5rem;
    font-size: 1rem;
    color: var(--text);
    font-weight: 600;
}

.remediation-section p {
    margin: 0.5rem 0;
    color: var(--text-secondary);
    line-height: 1.6;
}

.remediation-section pre {
    background-color: var(--bg-primary);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    padding: 1rem;
    overflow-x: auto;
    margin: 0.5rem 0;
}

.remediation-section code {
    font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
    font-size: 0.85rem;
    color: var(--text);
}

.remediation-section ul {
    margin: 0.5rem 0;
    padding-left: 1.5rem;
}

.remediation-section li {
    margin: 0.25rem 0;
    color: var(--text-secondary);
}

.reference-links {
    list-style: none;
    padding-left: 0;
}

.reference-links li {
    margin: 0.5rem 0;
}

.reference-links a {
    color: var(--accent-blue);
    text-decoration: none;
}

.reference-links a:hover {
    text-decoration: underline;
}

/* Header severity summary */
.header-severity-summary {
    display: flex;
    gap: 0.5rem;
    flex-wrap: wrap;
    margin-left: auto;
}

.score-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 1.5rem;
    margin-bottom: 2rem;
}

.score-display {
    text-align: center;
    padding: 20px;
}
"@
    
    return $css
}

