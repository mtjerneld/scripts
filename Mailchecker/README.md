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

# Generate HTML reports for all domains
.\mailchecker.ps1 -BulkFile domains.txt -Html

# Combine CSV export and HTML reports
.\mailchecker.ps1 -BulkFile domains.txt -Csv -Html
```

### Parameters

| Parameter | Type | Description | Default |
|-----------|------|-------------|---------|
| `-Domain` | String | Domain to check (e.g., example.com) | Prompted if not provided |
| `-BulkFile` | String | File containing domains to check (one per line) | - |
| `-Selectors` | String | Comma-separated DKIM selectors to test | `"default,s1,s2,selector1,selector2,google,mail,k1"` |
| `-DnsServer` | String[] | DNS server(s) to query first | Falls back to 8.8.8.8 and 1.1.1.1 |
| `-Html` | Switch | Generate HTML report with auto-generated timestamped filename | - |
| `-Csv` | Switch | Export bulk results to CSV file | - |
| `-Help` | Switch | Show comprehensive help information and exit | - |

## Output

### Console Output

The script provides color-coded console output with:
- ✅ **Green**: Successful configurations
- ❌ **Red**: Failed or missing configurations  
- ⚠️ **Yellow**: Warnings and recommendations
- ℹ️ **Cyan**: Informational messages

### HTML Reports

When using `-Html`, the script generates a comprehensive HTML report with an auto-generated filename (format: `domain-yyyyMMdd-HHmmss.html`) including:
- Summary table with all check results
- Detailed sections for each security component
- Color-coded status indicators
- Warnings and recommendations
- Timestamp and domain information

## Security Checks Explained

### MX Records
- Verifies mail exchange servers are properly configured
- Lists all MX records with preferences
- Ensures domain can receive email

### SPF (Sender Policy Framework)
- Checks for `v=spf1` records
- Validates DNS lookup count (warns if >10)
- Identifies soft fail (`~all`) vs hard fail (`-all`) policies
- Analyzes include/redirect mechanisms

### DKIM (DomainKeys Identified Mail)
- Tests multiple common selectors
- Validates `v=DKIM1` and `p=` (public key) presence
- Detects test mode (`t=y`) and strict mode (`t=s`)
- Identifies revoked keys (`p=;`)

### MTA-STS (Mail Transfer Agent Strict Transport Security)
- Checks `_mta-sts` TXT record for `v=STSv1`
- Fetches HTTPS policy from `https://mta-sts.domain/.well-known/mta-sts.txt`
- Validates `mode=enforce` vs `mode=testing`
- Analyzes MX patterns and max_age settings

### DMARC (Domain-based Message Authentication)
- Checks `_dmarc` TXT record for `v=DMARC1`
- Validates policy enforcement (`p=reject` or `p=quarantine`)
- Identifies testing mode (`p=none`)
- Analyzes reporting addresses (`rua`, `ruf`)

### TLS-RPT (TLS Reporting)
- Checks `_smtp._tls` TXT record for `v=TLSRPTv1`
- Validates reporting addresses
- Optional but recommended for TLS monitoring

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

# Generate HTML reports for all domains
.\mailchecker.ps1 -BulkFile domains.txt -Html
# Creates: domain1-20231201-143022.html, domain2-20231201-143022.html, etc.
```

### Use specific DNS servers
```powershell
.\mailchecker.ps1 -Domain example.com -DnsServer @("208.67.222.222", "208.67.220.220")
```

## Troubleshooting

### Common Issues

1. **No MX records found**: Domain may not be configured for email
2. **SPF exceeds 10 DNS lookups**: Simplify SPF record or use redirect
3. **DKIM no valid selectors**: Check actual selector used in email headers
4. **MTA-STS in testing mode**: Change policy to `mode: enforce`
5. **DMARC p=none**: Update policy to `p=quarantine` or `p=reject`

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
├── *.html                   # Generated HTML reports (timestamped)
└── bulk-results-*.csv       # Generated CSV exports (timestamped)
```

## License

This script is provided as-is for educational and administrative purposes. Use responsibly and in accordance with your organization's policies.

## Contributing

Feel free to submit issues, feature requests, or pull requests to improve the tool's functionality and accuracy.
