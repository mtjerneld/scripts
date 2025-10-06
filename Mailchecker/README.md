# Mailchecker

A comprehensive PowerShell script for checking email security configurations including MX records, SPF, DKIM, MTA-STS, DMARC, and TLS-RPT for any domain.

## Features

This tool performs a complete email security audit by checking:

- **MX Records**: Mail exchange server configuration
- **SPF (Sender Policy Framework)**: Email authentication and DNS lookup validation
- **DKIM (DomainKeys Identified Mail)**: Digital signature verification across multiple selectors
- **MTA-STS (Mail Transfer Agent Strict Transport Security)**: HTTPS policy enforcement
- **DMARC (Domain-based Message Authentication, Reporting and Conformance)**: Email authentication policy
- **TLS-RPT (TLS Reporting)**: TLS connection reporting configuration

## Recent Improvements

- **Summary HTML Reports**: Added `-SummaryHtml` switch for consolidated HTML tables in bulk mode with overview statistics
- **Comprehensive Help System**: Added `-Help` switch with Linux man-page style documentation
- **Bulk Domain Checking**: Added ability to check multiple domains from input files with CSV export
- **Unified Result Objects**: All security checks now return structured result objects for better consistency
- **Simplified HTML Generation**: Clean, maintainable HTML report generation using unified result objects
- **Streamlined Parameters**: Removed redundant `-HtmlOutput` parameter - use `-Html` for auto-generated timestamped reports
- **Enhanced Code Structure**: Eliminated duplicate code and improved maintainability with modular `Invoke-DomainCheck` function
- **Better Error Handling**: More robust DNS resolution with automatic fallback between multiple servers
- **CSV Export**: Bulk results can be exported to CSV for further analysis and reporting

## Requirements

- Windows PowerShell 5.1 or PowerShell Core 6+
- Internet connectivity for DNS queries and HTTPS requests
- Optional: `Resolve-DnsName` cmdlet (falls back to `nslookup` if unavailable)

## Usage

### Basic Usage

```powershell
# Show comprehensive help information
.\mailchecker.ps1 -Help

# Check a single domain
.\mailchecker.ps1 -Domain example.com
```

### Advanced Usage

```powershell
# Check with custom DKIM selectors
.\mailchecker.ps1 -Domain example.com -Selectors "default,s1,google,mail"

# Use specific DNS servers
.\mailchecker.ps1 -Domain example.com -DnsServer @("8.8.8.8", "1.1.1.1")

# Generate HTML report (auto-generated filename with timestamp)
.\mailchecker.ps1 -Domain example.com -Html
```

### Bulk Domain Checking

```powershell
# Check multiple domains from a file
.\mailchecker.ps1 -BulkFile domains.txt

# Export results to CSV
.\mailchecker.ps1 -BulkFile domains.txt -Csv

# Generate consolidated summary HTML table (quick overview)
.\mailchecker.ps1 -BulkFile domains.txt -SummaryHtml

# Generate individual HTML reports for all domains
.\mailchecker.ps1 -BulkFile domains.txt -Html

# Combine summary HTML with individual reports
.\mailchecker.ps1 -BulkFile domains.txt -SummaryHtml -Html

# Full export: CSV + Summary HTML + Individual HTML reports
.\mailchecker.ps1 -BulkFile domains.txt -Csv -SummaryHtml -Html
```

### Parameters

| Parameter | Type | Description | Default |
|-----------|------|-------------|---------|
| `-Domain` | String | Domain to check (e.g., example.com) | Prompted if not provided |
| `-BulkFile` | String | File containing domains to check (one per line) | - |
| `-Selectors` | String | Comma-separated DKIM selectors to test | `"default,s1,s2,selector1,selector2,google,mail,k1"` |
| `-DnsServer` | String[] | DNS server(s) to query first | Falls back to 8.8.8.8 and 1.1.1.1 |
| `-Html` | Switch | Generate HTML report(s) with auto-generated timestamped filename | - |
| `-Csv` | Switch | Export bulk results to CSV file (only with `-BulkFile`) | - |
| `-SummaryHtml` | Switch | Generate consolidated HTML summary table (only with `-BulkFile`) | - |
| `-Help` | Switch | Show comprehensive help information and exit | - |

## Output

### Console Output

The script provides color-coded console output with:
- ✅ **Green**: Successful configurations
- ❌ **Red**: Failed or missing configurations  
- ⚠️ **Yellow**: Warnings and recommendations
- ℹ️ **Cyan**: Informational messages

### HTML Reports

When using `-Html`, the script generates comprehensive HTML reports with auto-generated filenames:

**Individual Reports** (format: `domain-yyyyMMdd-HHmmss.html`):
- Summary table with all check results
- Detailed sections for each security component
- Color-coded status indicators with icons (✅❌⚠️)
- Warnings and recommendations
- Timestamp and domain information

**Summary HTML Report** (bulk mode with `-SummaryHtml`, format: `bulk-summary-yyyyMMdd-HHmmss.html`):
- Overview statistics (all OK, minor issues, major issues)
- Consolidated table with all domains as rows
- Color-coded icons for quick visual scanning (✅ Yes / ❌ No / ⚠️ N/A)
- Sticky table headers for easy scrolling
- Perfect for quick assessment of multiple domains

### CSV Export

When using `-Csv` with bulk checking, results are exported in CSV format (format: `bulk-results-yyyyMMdd-HHmmss.csv`):
- One row per domain
- Boolean columns for each security check
- N/A values for non-applicable checks
- Easy to import into Excel or other analysis tools

## Strict Profile Severity Policy

This tool uses a **strict security profile** by default, providing clear severity ratings for each check:

### Severity Levels

- ✅ **PASS** (Green): Configuration meets strict security standards
- ⚠️ **WARN** (Yellow): Configuration exists but is not fully enforced or uses deprecated mechanisms
- ❌ **FAIL** (Red): Critical configuration is missing or has serious issues
- ℹ️ **N/A** (Blue): Not applicable (e.g., domain has no MX records for receive-only checks)

### Security Checks & Severity Ratings

#### DMARC (Domain-based Message Authentication)
- **Missing record** → ❌ FAIL
- **`p=none`** (monitoring only) → ⚠️ WARN
- **`p=quarantine`** → ⚠️ WARN (not fully enforced)
- **`p=reject`** → ✅ PASS (fully enforced)

*Additional issues shown in "Reason" field:*
- `pct<100`: Not all messages subject to policy
- `sp` missing: Subdomain policy not set
- `rua`/`ruf` missing: No reporting addresses
- `adkim`/`aspf` relaxed: Consider strict alignment

#### MTA-STS (Mail Transfer Agent Strict Transport Security)
- **Missing** (for domains with MX) → ❌ FAIL
- **`mode=testing`** → ⚠️ WARN
- **`mode=enforce`** with valid policy → ✅ PASS
- **Missing** (for domains without MX) → ℹ️ N/A

#### TLS-RPT (TLS Reporting)
- **Missing** → ⚠️ WARN (recommended but optional)
- **Configured** → ✅ PASS
- **Missing** (for domains without MX) → ℹ️ N/A

#### SPF (Sender Policy Framework)
- **Missing** → ❌ FAIL
- **Multiple SPF records** → ❌ FAIL (RFC violation)
- **>10 DNS lookups** → ❌ FAIL (exceeds RFC limit)
- **Uses `ptr` mechanism** → ⚠️ WARN (deprecated)
- **Uses `~all`** (soft fail) → ⚠️ WARN (not recommended for production)
- **Valid with `-all`** → ✅ PASS

#### MX Records
- **Present** → ✅ PASS (shows actual MX records)
- **Missing** → ℹ️ N/A (domain may be send-only)

#### DKIM (DomainKeys Identified Mail)
- **No valid selectors found** → ❌ FAIL
- **At least one valid selector** → ✅ PASS
- **Not applicable** (no MX and no SPF mechanisms) → ℹ️ N/A

### Overall Status

The script calculates an **overall status** for each domain:
- **PASS**: All checks passed
- **WARN**: At least one warning, no failures
- **FAIL**: At least one critical failure

### Reason Field

Each check includes a **Reason** field with concise details:
- **Console output**: Shows "Overall Status" and "Reason" in summary
- **CSV export**: Includes "Status" and "Reason" columns
- **HTML reports**: Displays Status and Reason in summary table

Example reasons:
- `DMARC: p=quarantine; pct=100; sp=missing; adkim=r; aspf=s; rua=ok`
- `SPF: valid (5 lookups)`
- `MTA-STS: mode=testing`
- `TLS-RPT: missing`

## Examples

### Check a domain with default settings
```powershell
.\mailchecker.ps1 -Domain google.com
```

### Check with custom selectors for Office 365
```powershell
.\mailchecker.ps1 -Domain contoso.com -Selectors "selector1,selector2-contoso-com"
```

### Generate HTML report
```powershell
.\mailchecker.ps1 -Domain example.com -Html
# Creates: example.com-20231201-143022.html
```

### Bulk checking examples
```powershell
# Check domains from file with CSV export
.\mailchecker.ps1 -BulkFile domains.txt -Csv
# Creates: bulk-results-20231201-143022.csv

# Generate consolidated summary HTML table
.\mailchecker.ps1 -BulkFile domains.txt -SummaryHtml
# Creates: bulk-summary-20231201-143022.html

# Generate individual HTML reports for all domains
.\mailchecker.ps1 -BulkFile domains.txt -Html
# Creates: domain1-20231201-143022.html, domain2-20231201-143022.html, etc.

# Full export with all formats
.\mailchecker.ps1 -BulkFile domains.txt -Csv -SummaryHtml -Html
# Creates: CSV + summary HTML + individual HTML files for each domain
```

### Use specific DNS servers
```powershell
.\mailchecker.ps1 -Domain example.com -DnsServer @("208.67.222.222", "208.67.220.220")
```

## Troubleshooting

### Common Issues

1. **No MX records found**: Domain may not be configured for email (shown as N/A, not a failure)
2. **SPF exceeds 10 DNS lookups**: Simplify SPF record or use redirect (❌ FAIL)
3. **DKIM no valid selectors**: Check actual selector used in email headers (❌ FAIL)
4. **MTA-STS in testing mode**: Change policy to `mode: enforce` (⚠️ WARN)
5. **DMARC p=none or p=quarantine**: Update policy to `p=reject` for full enforcement (⚠️ WARN)
6. **TLS-RPT missing**: Add TLS-RPT record for encryption monitoring (⚠️ WARN)

### DNS Resolution Issues

The script automatically falls back between multiple DNS servers:
1. User-specified servers (`-DnsServer`)
2. Google DNS (8.8.8.8)
3. Cloudflare DNS (1.1.1.1)

### Finding DKIM Selectors

To find the correct DKIM selector for a domain:
1. Send a test email from the domain
2. Check the email headers for `DKIM-Signature`
3. Look for the `s=` parameter (e.g., `s=selector1`)
4. Use that selector with the `-Selectors` parameter

## Input File Format (domains.txt)

For bulk checking, create a text file with one domain per line:

```
example.com
test.org
# This is a comment
another-domain.se

domain-with-whitespace.com
```

**Notes:**
- Empty lines are ignored
- Lines starting with `#` are treated as comments
- Leading/trailing whitespace is automatically trimmed
- Domains are converted to lowercase

## File Structure

```
Mailchecker/
├── mailchecker.ps1          # Main PowerShell script
├── README.md                # This documentation
├── domains.txt              # Example input file for bulk checking
├── domain-*.html            # Individual HTML reports (timestamped)
├── bulk-summary-*.html      # Consolidated HTML summary reports (timestamped)
└── bulk-results-*.csv       # CSV exports (timestamped)
```

## License

This script is provided as-is for educational and administrative purposes. Use responsibly and in accordance with your organization's policies.

## Contributing

Feel free to submit issues, feature requests, or pull requests to improve the tool's functionality and accuracy.
