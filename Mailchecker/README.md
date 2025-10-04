## Mailchecker.ps1

Quick external mail hygiene checker for a domain. The script performs DNS and HTTP checks for common email authentication and transport security records:

- MX records
- SPF (v=spf1)
- DKIM (by selector)
- DMARC (_dmarc)
- MTA-STS (_mta-sts and HTTPS policy)
- SMTP TLS Reporting (TLS-RPT)

### Requirements

- Windows PowerShell (the script uses `Resolve-DnsName` when available). If `Resolve-DnsName` is not present the script falls back to `nslookup`.
- Network access to the DNS servers you query and to `https://mta-sts.<domain>/.well-known/mta-sts.txt` for MTA-STS checks.

No external modules are required.

### Location

The script file is `mailchecker.ps1` in this folder. Use that filename when running examples below.

### Parameters

- `-Domain` (string) — Domain to check (e.g. `example.com`). If omitted the script will prompt you.
- `-Selectors` (string) — Comma-separated DKIM selectors to probe. Defaults to `default,s1,s2,selector1,selector2,google,mail,k1`.
- `-DnsServer` (string[]) — One or more DNS servers (IP or hostname) to query first. The script always falls back to 8.8.8.8 and 1.1.1.1.

### Examples

Run an interactive check (you'll be prompted for the domain):

```powershell
.\mailchecker.ps1
```

Run non-interactively for `contoso.com`:

```powershell
.\\mailchecker.ps1 -Domain contoso.com
```

Specify custom DKIM selectors:

```powershell
.\\mailchecker.ps1 -Domain contoso.com -Selectors "s1,google"
```

Use specific DNS resolvers (query these first):

```powershell
.\\mailchecker.ps1 -Domain contoso.com -DnsServer 192.0.2.53,8.8.8.8
```

### Output

The script prints human-readable sections for each check and a final boolean summary. Colors are used to highlight status:

- Green — OK / present
- Yellow — warning / informational
- Red — FAIL / missing or broken

Notes:
- DKIM checks probe TXT records at `<selector>._domainkey.<domain>` for the presence of `v=DKIM1` and a `p=` public key value. The script accepts a list of selectors; it does not attempt to discover active selectors from message headers.
- SPF checks count DNS-lookups (includes, a, mx, ptr, exists, redirect) and warns if the total is > 10.
- MTA-STS requires both a `_mta-sts` TXT record and a reachable HTTPS policy at `https://mta-sts.<domain>/.well-known/mta-sts.txt`.

### Troubleshooting

- If you get odd DNS results on Windows, ensure the account running the script can reach the DNS server(s) configured and that firewalls permit DNS/HTTPS.
- If `Resolve-DnsName` is unavailable the script will use `nslookup` as a fallback; output formats may differ slightly.

### License

Add your preferred license file to this repository. This README does not impose a license.

### Contributing

Small fixes and improvements welcome. Please open a PR that updates `mailchecker.ps1` and this README together when changing behavior.
