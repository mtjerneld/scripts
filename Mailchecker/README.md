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

## Requirements

- Windows PowerShell 5.1 or PowerShell Core 6+
- Internet connectivity for DNS queries and HTTPS requests
- Optional: `Resolve-DnsName` cmdlet (falls back to `nslookup` if unavailable)

## Usage

### Basic Usage

```powershell
.\mailchecker.ps1 -Domain example.com
```

### Advanced Usage

```powershell
# Check with custom DKIM selectors
.\mailchecker.ps1 -Domain example.com -Selectors "default,s1,google,mail"

# Use specific DNS servers
.\mailchecker.ps1 -Domain example.com -DnsServer @("8.8.8.8", "1.1.1.1")

# Generate HTML report
.\mailchecker.ps1 -Domain example.com -Html

# Generate HTML report to specific file
.\mailchecker.ps1 -Domain example.com -HtmlOutput "report.html"
```

### Parameters

| Parameter | Type | Description | Default |
|-----------|------|-------------|---------|
| `-Domain` | String | Domain to check (e.g., example.com) | Prompted if not provided |
| `-Selectors` | String | Comma-separated DKIM selectors to test | `"default,s1,s2,selector1,selector2,google,mail,k1"` |
| `-DnsServer` | String[] | DNS server(s) to query first | Falls back to 8.8.8.8 and 1.1.1.1 |
| `-Html` | Switch | Generate HTML report with timestamp | - |
| `-HtmlOutput` | String | Generate HTML report to specific file | - |

## Output

### Console Output

The script provides color-coded console output with:
- ✅ **Green**: Successful configurations
- ❌ **Red**: Failed or missing configurations  
- ⚠️ **Yellow**: Warnings and recommendations
- ℹ️ **Cyan**: Informational messages

### HTML Reports

When using `-Html` or `-HtmlOutput`, the script generates a comprehensive HTML report including:
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

## File Structure

```
Mailchecker/
├── mailchecker.ps1          # Main PowerShell script
├── README.md                # This documentation
└── *.html                   # Generated HTML reports (timestamped)
```

## License

This script is provided as-is for educational and administrative purposes. Use responsibly and in accordance with your organization's policies.

## Contributing

Feel free to submit issues, feature requests, or pull requests to improve the tool's functionality and accuracy.
