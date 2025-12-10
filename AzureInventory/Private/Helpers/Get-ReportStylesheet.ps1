<#
.SYNOPSIS
    Generates common CSS stylesheet for audit reports.

.DESCRIPTION
    Returns the common CSS variables and base styles used across all audit reports.
    This includes dark mode theme variables, navigation styles, and common layout elements.

.PARAMETER IncludeReportSpecific
    If specified, includes additional report-specific styles (for Security Report).

.EXAMPLE
    $css = Get-ReportStylesheet
#>
function Get-ReportStylesheet {
    [CmdletBinding()]
    param(
        [switch]$IncludeReportSpecific
    )
    
    $css = @"
        /* Dark Mode Theme - Common Variables */
        :root {
            --bg-primary: #0f0f1a;
            --bg-secondary: #1a1a2e;
            --surface: #252542;
            --bg: #1f1f35;
            --bg-hover: #2d2d4a;
            --text: #e8e8e8;
            --text-secondary: #b8b8b8;
            --text-muted: #888;
            --border: #3d3d5c;
            --pri-600: #54a0ff;
            --pri-700: #2e86de;
            --info: #54a0ff;
            --success: #00d26a;
            --warning: #feca57;
            --danger: #ff6b6b;
            --radius-sm: 8px;
            --radius-md: 12px;
            --shadow-sm: 0 2px 4px rgba(0, 0, 0, 0.3);
            --shadow-md: 0 4px 12px rgba(0, 0, 0, 0.4);
            --shadow-lg: 0 8px 24px rgba(0, 0, 0, 0.5);
            --background: #1a1a2e;
            --bg-surface: #252542;
            --bg-resource: #1e1e36;
            --accent-green: #00d26a;
            --accent-red: #ff6b6b;
            --accent-yellow: #feca57;
            --accent-blue: #54a0ff;
            --accent-purple: #9b59b6;
            --accent-orange: #ff9f43;
            --border-color: #3d3d5c;
            --text-primary: #e8e8e8;
        }
        
        * {
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif;
            background-color: var(--bg-primary);
            color: var(--text);
            margin: 0;
            padding: 0;
            line-height: 1.6;
        }
        
        /* Generic helper to hide any element flagged as hidden in JS */
        .hidden {
            display: none !important;
        }
        
        /* Navigation */
        .report-nav {
            background: var(--bg-secondary);
            padding: 15px 30px;
            display: flex;
            gap: 10px;
            align-items: center;
            border-bottom: 1px solid var(--border-color);
            position: sticky;
            top: 0;
            z-index: 100;
        }
        
        .nav-brand {
            font-weight: 600;
            font-size: 1.1rem;
            color: var(--accent-blue);
            margin-right: 30px;
        }
        
        .nav-link {
            color: var(--text-muted);
            text-decoration: none;
            padding: 8px 16px;
            border-radius: 6px;
            transition: all 0.2s ease;
            font-size: 0.9rem;
        }
        
        .nav-link:hover {
            background: var(--bg-surface);
            color: var(--text-primary);
        }
        
        .nav-link.active {
            background: var(--accent-blue);
            color: white;
        }
        
        /* Container */
        .container {
            max-width: 1600px;
            margin: 0 auto;
            padding: 30px;
        }
        
        /* Page Header */
        .page-header {
            margin-bottom: 30px;
        }
        
        .page-header h1 {
            font-size: 2rem;
            font-weight: 600;
            margin-bottom: 8px;
        }
        
        .page-header .subtitle {
            color: var(--text-muted);
            font-size: 0.9rem;
        }
        
        .metadata {
            display: flex;
            flex-wrap: wrap;
            gap: 20px;
            color: var(--text-muted);
            font-size: 0.9rem;
        }
        
        .metadata p {
            margin: 0;
        }
        
        .metadata strong {
            color: var(--text-secondary);
        }
        
        /* Scrollbar */
        ::-webkit-scrollbar {
            width: 8px;
            height: 8px;
        }
        
        ::-webkit-scrollbar-track {
            background: var(--bg-primary);
        }
        
        ::-webkit-scrollbar-thumb {
            background: var(--border-color);
            border-radius: 4px;
        }
        
        ::-webkit-scrollbar-thumb:hover {
            background: var(--text-muted);
        }
"@
    
    if ($IncludeReportSpecific) {
        # Add Security Report specific styles
        $css += @"
        
        /* Security Report Specific Styles */
        h2 {
            color: var(--text);
            font-size: 1.3rem;
            margin: 30px 0 20px 0;
            font-weight: 600;
        }
        
        .summary-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        
        .summary-card {
            background: var(--surface);
            border-radius: var(--radius-md);
            padding: 24px;
            text-align: center;
            border: 1px solid var(--border);
            transition: transform 0.2s ease, box-shadow 0.2s ease;
        }
        
        .summary-card:hover {
            transform: translateY(-2px);
            box-shadow: var(--shadow-md);
        }
        
        .summary-card-label {
            font-size: 0.85rem;
            color: var(--text-muted);
            text-transform: uppercase;
            letter-spacing: 0.5px;
            margin-bottom: 8px;
        }
        
        .summary-card-value {
            font-size: 2.5rem;
            font-weight: 700;
            line-height: 1.2;
        }
        
        .summary-card.critical .summary-card-value { color: var(--danger); }
        .summary-card.high .summary-card-value { color: #ff9f43; }
        .summary-card.medium .summary-card-value { color: var(--warning); }
        .summary-card.low .summary-card-value { color: var(--info); }
        
        /* Status badges */
        .status-badge {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 4px;
            font-size: 0.8rem;
            font-weight: 600;
        }
        
        .status-badge.critical {
            background: rgba(255, 107, 107, 0.15);
            color: var(--danger);
        }
        
        .status-badge.high {
            background: rgba(255, 159, 67, 0.15);
            color: #ff9f43;
        }
        
        .status-badge.medium {
            background: rgba(254, 202, 87, 0.15);
            color: var(--warning);
        }
        
        .status-badge.low {
            background: rgba(84, 160, 255, 0.15);
            color: var(--info);
        }
        
        /* Filter Controls */
        .filter-controls {
            display: flex;
            flex-wrap: wrap;
            gap: 1rem;
            align-items: center;
            margin-bottom: 1.5rem;
            padding: 1rem;
            background-color: var(--bg);
            border-radius: var(--radius-sm);
            border: 1px solid var(--border);
        }
        
        .filter-group {
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }
        
        .filter-group label {
            font-weight: 500;
            color: var(--text);
            white-space: nowrap;
        }
        
        .filter-select,
        .filter-input {
            padding: 0.5rem 1rem;
            border: 1px solid var(--border);
            border-radius: var(--radius-sm);
            background-color: var(--surface);
            color: var(--text);
            font-size: 0.9rem;
            transition: all 0.2s;
        }
        
        .filter-input {
            min-width: 200px;
            cursor: text;
        }
        
        .filter-select {
            cursor: pointer;
        }
        
        .filter-select:hover,
        .filter-input:hover {
            border-color: var(--pri-600);
        }
        
        .filter-select:focus,
        .filter-input:focus {
            outline: none;
            border-color: var(--pri-600);
            box-shadow: 0 0 0 3px rgba(0, 120, 212, 0.1);
        }
        
        .btn-clear {
            padding: 0.5rem 1rem;
            background-color: var(--text-muted);
            color: white;
            border: none;
            border-radius: var(--radius-sm);
            cursor: pointer;
            font-size: 0.9rem;
            transition: background-color 0.2s;
        }
        
        .btn-clear:hover {
            background-color: var(--text);
        }
        
        .result-count {
            font-weight: 500;
            color: var(--text-muted);
            padding: 0.5rem 1rem;
            background-color: var(--surface);
            border-radius: var(--radius-sm);
            border: 1px solid var(--border);
        }
        
        /* Tables */
        .controls-table,
        .resource-summary-table {
            width: 100%;
            border-collapse: collapse;
        }
        
        .controls-table thead,
        .resource-summary-table thead {
            background-color: var(--bg);
            position: sticky;
            top: 0;
            z-index: 10;
        }
        
        .controls-table th,
        .resource-summary-table th {
            padding: 0.75rem;
            text-align: left;
            font-weight: 600;
            color: var(--text);
            border-bottom: 2px solid var(--border);
        }
        
        .controls-table td,
        .resource-summary-table td {
            padding: 0.75rem;
            border-bottom: 1px solid var(--border);
            word-wrap: break-word;
            word-break: break-word;
            overflow-wrap: break-word;
        }
        
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
        
        /* Subscription/Category Boxes */
        .subscription-box,
        .category-box {
            margin-bottom: 1.5rem;
            border: 1px solid var(--border);
            border-radius: var(--radius-sm);
            background-color: var(--surface);
            overflow: hidden;
        }
        
        .subscription-header,
        .category-header {
            display: flex;
            align-items: center;
            gap: 0.5rem;
            padding: 1rem;
            background-color: var(--bg);
            border-bottom: 1px solid var(--border);
            transition: background-color 0.2s;
            cursor: pointer;
        }
        
        .subscription-header:hover,
        .category-header:hover {
            background-color: var(--bg-hover);
        }
        
        .subscription-header h3,
        .category-header h3 {
            margin: 0;
            flex: 1;
            font-size: 1.1rem;
            font-weight: 600;
        }
        
        .expand-icon {
            width: 0;
            height: 0;
            border-left: 6px solid var(--text-muted);
            border-top: 5px solid transparent;
            border-bottom: 5px solid transparent;
            border-right: none;
            display: inline-block;
            transition: transform 0.2s;
            margin-right: 0.5rem;
            vertical-align: middle;
            flex-shrink: 0;
        }
        
        .subscription-header:not(.collapsed) .expand-icon,
        .category-header:not(.collapsed) .expand-icon {
            border-left: 5px solid transparent;
            border-right: 5px solid transparent;
            border-top: 6px solid var(--text-muted);
            border-bottom: none;
        }
        
        .subscription-content,
        .category-content {
            padding: 1rem;
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
        
        /* Responsive */
        @media (max-width: 768px) {
            .filter-controls {
                flex-direction: column;
                align-items: stretch;
            }
            
            .filter-group {
                flex-direction: column;
                align-items: stretch;
            }
            
            .filter-select,
            .btn-clear {
                width: 100%;
            }
            
            .controls-table,
            .resource-summary-table {
                font-size: 0.85rem;
            }
            
            .controls-table th,
            .controls-table td,
            .resource-summary-table th,
            .resource-summary-table td {
                padding: 0.5rem;
            }
        }
        
        /* Compliance Scores Section */
        .compliance-scores-section {
            margin: 2rem 0;
            padding: 1.5rem;
            background-color: var(--surface);
            border-radius: var(--radius-md);
            border: 1px solid var(--border);
        }
        
        .compliance-scores-section h3 {
            margin-top: 0;
            margin-bottom: 1.5rem;
            font-size: 1.2rem;
            color: var(--text);
        }
        
        .compliance-scores-section h4 {
            margin-top: 2rem;
            margin-bottom: 1rem;
            font-size: 1rem;
            color: var(--text-secondary);
        }
        
        .score-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 1.5rem;
            margin-bottom: 2rem;
        }
        
        .score-card {
            background-color: var(--bg);
            border: 1px solid var(--border);
            border-radius: var(--radius-md);
            padding: 1.5rem;
            text-align: center;
            transition: transform 0.2s ease, box-shadow 0.2s ease;
        }
        
        .score-card:hover {
            transform: translateY(-2px);
            box-shadow: var(--shadow-md);
        }
        
        .score-label {
            font-size: 0.9rem;
            color: var(--text-muted);
            text-transform: uppercase;
            letter-spacing: 0.5px;
            margin-bottom: 0.5rem;
        }
        
        .score-value {
            font-size: 2.5rem;
            font-weight: 700;
            line-height: 1.2;
            margin: 0.5rem 0;
        }
        
        .score-details {
            font-size: 0.85rem;
            color: var(--text-secondary);
            margin-top: 0.5rem;
        }
        
        .score-card.score-excellent .score-value { color: var(--success); }
        .score-card.score-good .score-value { color: var(--accent-blue); }
        .score-card.score-fair .score-value { color: var(--warning); }
        .score-card.score-poor .score-value { color: var(--danger); }
        
        .category-scores-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
            gap: 1rem;
        }
        
        .category-score-card {
            background-color: var(--bg);
            border: 1px solid var(--border);
            border-radius: var(--radius-sm);
            padding: 1rem;
            text-align: center;
            transition: transform 0.2s ease;
        }
        
        .category-score-card:hover {
            transform: translateY(-2px);
        }
        
        .category-score-label {
            font-size: 0.85rem;
            color: var(--text-muted);
            margin-bottom: 0.5rem;
        }
        
        .category-score-value {
            font-size: 1.8rem;
            font-weight: 700;
        }
        
        .category-score-card.score-excellent .category-score-value { color: var(--success); }
        .category-score-card.score-good .category-score-value { color: var(--accent-blue); }
        .category-score-card.score-fair .category-score-value { color: var(--warning); }
        .category-score-card.score-poor .category-score-value { color: var(--danger); }
        
        /* Control Resources Table */
        .control-resources-table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 0.5rem;
        }
        
        .control-resources-table thead {
            background-color: var(--bg);
        }
        
        .control-resources-table th {
            padding: 0.75rem;
            text-align: left;
            font-weight: 600;
            color: var(--text);
            border-bottom: 2px solid var(--border);
            font-size: 0.9rem;
        }
        
        .control-resources-table td {
            padding: 0.75rem;
            border-bottom: 1px solid var(--border);
            font-size: 0.9rem;
            word-wrap: break-word;
            word-break: break-word;
            overflow-wrap: break-word;
        }
        
        .control-resources-table tr:hover {
            background-color: var(--bg);
        }
        
        /* Resource Issues Table */
        .resource-issues-table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 0.5rem;
        }
        
        .resource-issues-table thead {
            background-color: var(--bg);
        }
        
        .resource-issues-table th {
            padding: 0.75rem;
            text-align: left;
            font-weight: 600;
            color: var(--text);
            border-bottom: 2px solid var(--border);
            font-size: 0.9rem;
        }
        
        .resource-issues-table td {
            padding: 0.75rem;
            border-bottom: 1px solid var(--border);
            font-size: 0.9rem;
            word-wrap: break-word;
            word-break: break-word;
            overflow-wrap: break-word;
        }
        
        .resource-issues-table tr:hover {
            background-color: var(--bg);
        }
        
        /* Remediation Styles */
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
        
        /* Header Severity Summary */
        .header-severity-summary {
            display: flex;
            gap: 0.5rem;
            flex-wrap: wrap;
            margin-left: auto;
        }
        
        .severity-count {
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 0.8rem;
            font-weight: 600;
        }
        
        .severity-count.critical {
            background: rgba(255, 107, 107, 0.15);
            color: var(--danger);
        }
        
        .severity-count.high {
            background: rgba(255, 159, 67, 0.15);
            color: #ff9f43;
        }
        
        .severity-count.medium {
            background: rgba(254, 202, 87, 0.15);
            color: var(--warning);
        }
        
        .severity-count.low {
            background: rgba(84, 160, 255, 0.15);
            color: var(--info);
        }
        
        /* Footer */
        .footer {
            margin-top: 3rem;
            padding-top: 1.5rem;
            border-top: 1px solid var(--border);
            text-align: center;
            color: var(--text-muted);
            font-size: 0.85rem;
        }
        
        .footer p {
            margin: 0;
        }
        
        /* Resource Detail Rows */
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
"@
    }
    
    return $css
}

