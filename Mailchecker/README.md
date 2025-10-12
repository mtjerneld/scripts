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

- **AI-Powered Analysis**: ChatGPT integration for strategic remediation plans and actionable recommendations
- **Clean Output Directory**: All reports default to `output/` folder to keep main directory clean
- **Template Architecture**: All HTML/CSS/JS extracted to organized `templates/` folder (547 lines reduction, 14.5% smaller!)
- **Domain Existence Check**: Distinguishes between non-existent domains (no NS records) and existing domains without MX (send-only)
- **Full HTML Export**: Complete report structure with index page, individual domain reports, CSV, and assets - all in one command
- **Smart MX Display**: MX records shown inline in summary table with line breaks for easy reading
- **Concise Issues**: Streamlined issue descriptions focusing only on actual problems (no informational noise)
- **Auto-Open Reports**: `-OpenReport` switch automatically opens generated reports in default browser
- **JSON Export**: Optional `-Json` switch for structured JSON export of all results
- **Azure Upload**: Direct upload to Azure Blob Storage with static website hosting
- **Strict Security Profile**: PASS/WARN/FAIL severity ratings with comprehensive reason fields
- **Comprehensive Help System**: Concise `-Help` output with quick examples and reference to README
- **Bulk Domain Checking**: Process multiple domains from input files with full reporting
- **Unified Result Objects**: All security checks return structured result objects for consistency
- **Enhanced Code Structure**: Modular `Invoke-DomainCheck` function with improved maintainability
- **Better Error Handling**: Robust DNS resolution with automatic fallback between multiple servers

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

The `-FullHtmlExport` mode creates a complete, professional report structure with an index page linking to individual domain reports:

```powershell
# Basic usage - console output only
.\mailchecker.ps1 -BulkFile domains.txt

# Full HTML export (auto-creates output/domains-timestamp/ folder)
.\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport

# Full HTML export with AI analysis
.\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -ChatGPT

# Full HTML export to specific directory
.\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -OutputPath ./reports

# Full HTML export with auto-open in browser
.\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -OpenReport

# Complete export with JSON and AI analysis
.\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -Json -ChatGPT -OpenReport
```

### AI-Powered Analysis (Optional)

Generate strategic remediation plans and actionable recommendations using ChatGPT:

```powershell
# Enable AI analysis (requires OPENAI_API_KEY in .env)
.\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -ChatGPT

# AI analysis with auto-open
.\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -ChatGPT -OpenReport
```

**Setup (one-time):**
1. Add to your `.env` file:
   ```
   OPENAI_API_KEY=sk-proj-...your-key...
   OPENAI_MODEL=gpt-4o-mini               # optional, defaults to gpt-4o-mini
   OPENAI_MAX_OUTPUT_TOKENS=8000          # optional
   OPENAI_TIMEOUT_SECONDS=60              # optional
   ```
2. Run with `-ChatGPT` switch

**AI Analysis includes:**
- Strategic remediation plan prioritized by impact
- Per-domain specific recommendations
- Estimated timeline and resource requirements
- Comprehensive markdown report
- Links to relevant documentation

The analysis is saved to `output/*/analysis/index.html` with full JSON response preserved for auditing.

### Azure Cloud Upload

Upload reports directly to Azure Blob Storage with static website hosting:

```powershell
# Upload to Azure (requires .env configuration)
.\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -UploadToAzure

# Upload with custom Run ID
.\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -UploadToAzure -AzureRunId "2025-q1-audit"

# Upload with AI analysis
.\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -ChatGPT -UploadToAzure -OpenReport
```

**Setup (one-time):**
1. Add to your `.env` file:
   ```
   AZURE_STORAGE_ACCOUNT=mailsecurityreports
   AZURE_STORAGE_KEY=your-key-here==
   AZURE_WEB_ZONE=z1  # optional, defaults to z1
   ```
2. Run with `-UploadToAzure` switch

**Features:**
- Automatic AzCopy installation check (install via winget if needed)
- Uploads to `$web/reports/<runId>/` in your storage account
- Generates unique Run ID: `yyyyMMdd-HHmmss-random6`
- Prints public URLs for sharing
- Verifies upload with HTTP HEAD request
- Keeps local copy even if upload fails

**Security Notes:**
- `.env` file is in `.gitignore` (never committed)
- Account key gives full access - rotate regularly
- Consider using SAS tokens (scoped, time-limited) for production
- For CI/CD: Use Azure Key Vault or GitHub Actions secrets

**Output structure:**
```
output/domains-20251008-142315/
├─ index.html              ← Summary with MX records and concise issues
├─ bulk-results-*.csv      ← CSV export (always included)
├─ results.json            ← JSON export (if -Json specified)
├─ analysis/
│  └─ index.html           ← AI analysis and remediation plan (if -ChatGPT)
├─ assets/
│  ├─ style.css            ← Modern responsive styles
│  ├─ app.js               ← Interactive features (sorting)
│  ├─ analysis.css         ← AI analysis styles
│  └─ analysis.js          ← AI analysis scripts
└─ domains/
   ├─ example.com.html     ← Individual domain reports
   ├─ google.com.html
   └─ ...
```

**Summary table includes:**
- Domain name (clickable link to detailed report)
- MX records (inline with line breaks)
- Overall status (PASS/WARN/FAIL)
- Individual check badges (SPF, DKIM, MTA-STS, DMARC, TLS-RPT)
- Concise issues (only actual problems, line-separated)

### Parameters

| Parameter | Type | Description | Default |
|-----------|------|-------------|---------|
| `-Domain` | String | Domain to check (e.g., example.com) | Prompted if not provided |
| `-BulkFile` | String | File containing domains to check (one per line) | - |
| `-Selectors` | String | Comma-separated DKIM selectors to test | `"default,s1,s2,selector1,selector2,google,mail,k1"` |
| `-DnsServer` | String[] | DNS server(s) to query first | Falls back to 8.8.8.8 and 1.1.1.1 |
| `-Html` | Switch | Generate HTML report for single domain | - |
| `-OutputPath` | String | Directory where output files will be saved | `output/` (auto-generates timestamped subfolder) |
| `-FullHtmlExport` | Switch | Create complete HTML export: index, domain reports, CSV, assets | - |
| `-OpenReport` | Switch | Automatically open generated index.html in default browser (requires `-FullHtmlExport`) | - |
| `-Json` | Switch | Export results to JSON format (with `-FullHtmlExport`) | - |
| `-ChatGPT` | Switch | Generate AI-powered analysis with remediation plan (requires OPENAI_API_KEY in .env) | - |
| `-UploadToAzure` | Switch | Upload report to Azure Blob Storage (requires `-FullHtmlExport`) | - |
| `-AzureRunId` | String | Custom Run ID for Azure upload | Auto-generated: `yyyyMMdd-HHmmss-random6` |
| `-EnvFile` | String | Path to .env file for configuration | `.env` |
| `-Help` | Switch | Show concise help information and exit | - |

## Output

### Console Output

The script provides color-coded console output with:
- ✅ **Green**: Successful configurations
- ❌ **Red**: Failed or missing configurations  
- ⚠️ **Yellow**: Warnings and recommendations
- ℹ️ **Cyan**: Informational messages

### HTML Reports

**Single Domain** (with `-Html`):
- Individual HTML report with detailed analysis
- Summary table with all check results
- Detailed sections for each security component
- Color-coded status indicators with icons
- Warnings and recommendations

**Bulk Domains** (with `-FullHtmlExport`):
- **index.html**: Summary table with all domains
  - MX records displayed inline with line breaks
  - Overall status per domain (PASS/WARN/FAIL)
  - Individual check badges (✅/⚠️/❌)
  - Concise issues (only actual problems, line-separated)
  - Domain overview statistics
  - Clickable links to detailed reports
- **domains/**: Individual HTML report for each domain
- **CSV**: Automatically included (bulk-results-*.csv)
- **JSON**: Optional structured export (results.json)
- **Assets**: Modern CSS and interactive JavaScript

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

#### MX Records & Domain Existence
- **Present** → ✅ PASS (shows actual MX records)
- **Missing, but domain exists** (has NS records) → ℹ️ N/A (domain may be send-only)
- **Domain does not exist** (NXDOMAIN) → ❌ FAIL
- **DNS misconfigured** (SERVFAIL) → ⚠️ WARN

*The tool performs DNS queries to distinguish between different failure scenarios:*

**DNS Error Types:**
1. **NXDOMAIN** (Non-Existent Domain): Domain is not registered or doesn't exist in DNS
   - All email security checks marked as **N/A** (not applicable)
   
2. **DNS Misconfigured** (SERVFAIL/No response/Timeout): Domain might exist but DNS is not working
   - Server failure (SERVFAIL)
   - No response from server
   - Connection timeout
   - Nameservers not responding
   - Lame delegation (nameservers don't accept queries for the domain)
   - Network connectivity issues
   - **Email security checks still performed** as records may exist despite NS issues
   - *Any DNS error that is not NXDOMAIN is treated as DNS misconfiguration*

**Special handling by DNS error type:**
- **NXDOMAIN domains**: All email security checks (SPF, DKIM, DMARC, MTA-STS, TLS-RPT) are marked as **N/A** since the domain doesn't exist
- **SERVFAIL domains**: Email security checks are **still performed** as the domain may exist in the registry and have email security records, even if NS resolution fails

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
# Basic full HTML export (auto-creates output/domains-timestamp/ folder)
.\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport
# Creates: output\domains-20251008-142315\
#   ├─ index.html (summary with MX records and issues)
#   ├─ domains\*.html (individual detailed reports)
#   ├─ assets\style.css & app.js
#   └─ bulk-results-*.csv (always included)

# With AI-powered analysis and remediation plan
.\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -ChatGPT
# Adds: analysis/index.html with strategic recommendations

# Full export with automatic browser open
.\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -OpenReport
# Opens index.html in your default browser automatically

# Full export to specific directory
.\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -OutputPath "./reports"
# Creates: ./reports/index.html with all reports

# Complete export with JSON and AI analysis
.\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -Json -ChatGPT -OpenReport
# Creates full HTML structure + results.json + AI analysis + opens in browser

# Upload to Azure cloud storage
.\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -UploadToAzure
# Uploads to Azure Blob Storage with public URL

# Console output only (no HTML/CSV)
.\mailchecker.ps1 -BulkFile domains.txt
# Displays results in console, suggests using -FullHtmlExport for reports
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

### Project Structure
```
Mailchecker/
├── mailchecker.ps1          # Main PowerShell script (3,235 lines)
├── README.md                # This documentation
├── .gitignore               # Git ignore patterns
├── domains.txt              # Example input file
├── templates/               # Presentation templates (organized by type)
│   ├── html/               # HTML templates (5 files)
│   │   ├── analysis.html
│   │   ├── domain-report.html
│   │   └── index.html (+ error pages)
│   ├── css/                # CSS stylesheets (2 files)
│   │   ├── style.css       (main stylesheet)
│   │   └── analysis.css    (AI analysis styles)
│   └── js/                 # JavaScript files (2 files)
│       ├── app.js          (table interactions)
│       └── analysis.js     (AI analysis scripts)
├── prompts/                # AI prompts for ChatGPT
│   └── agent.md
├── schema/                 # JSON schemas
│   └── analysis.schema.json
├── BulkFiles/              # Domain list files
└── output/                 # Default output directory (gitignored)
```

### Generated Output Structure (with `-FullHtmlExport`)
```
output/domains-20251008-142315/
├── index.html              # Summary: MX records, status badges, concise issues
├── bulk-results-*.csv      # CSV export (always included)
├── results.json            # JSON export (if -Json specified)
├── analysis/               # AI analysis (if -ChatGPT specified)
│   └── index.html          # Strategic remediation plan
├── assets/                 # Styling and interactive features (copied from templates)
│   ├── style.css           # Modern responsive CSS
│   ├── app.js              # Table sorting functionality
│   ├── analysis.css        # AI analysis styles
│   └── analysis.js         # AI analysis scripts
└── domains/                # Individual detailed reports
    ├── example.com.html
    ├── google.com.html
    ├── microsoft.com.html
    └── ...
```

## License

This script is provided as-is for educational and administrative purposes. Use responsibly and in accordance with your organization's policies.

## Contributing

Feel free to submit issues, feature requests, or pull requests to improve the tool's functionality and accuracy.
