<# 
.SYNOPSIS
  Quick external mail hygiene checker: MX, DKIM, MTA-STS, DMARC, TLS-RPT, SPF.

.PARAMETER Domain
  Domain to check (e.g. example.com). If omitted, you'll be prompted.

.PARAMETER Selectors
  Comma-separated DKIM selectors to test. 
  Defaults include common ones (default,s1,s2,selector1,selector2,google,mail,k1).

.PARAMETER DnsServer
  DNS server(s) to query first (IP or name). Falls back to 8.8.8.8 and 1.1.1.1 automatically.

.EXAMPLE
  .\mailcheck.ps1 -Domain contoso.com -Selectors "mx,default,s1,google" -DnsServer 8.8.8.8
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$false)]
  [string]$Domain,

  [Parameter(Mandatory=$false)]
  [string]$BulkFile,

  [Parameter(Mandatory=$false)]
  [string]$Selectors = "default,s1,s2,selector1,selector2,google,mail,k1",

  [Parameter(Mandatory=$false)]
  [string[]]$DnsServer,
  
  [Parameter(Mandatory=$false)]
  [switch]$Html,
  
  [Parameter(Mandatory=$false)]
  [switch]$Csv,
  
  [Parameter(Mandatory=$false)]
  [switch]$SummaryHtml,
  
  [Parameter(Mandatory=$false)]
  [switch]$Help
)

# Show help if requested
if ($Help) {
    $helpText = @"
MAILCHECKER(1)                    User Commands                    MAILCHECKER(1)

NAME
       mailchecker - Comprehensive email security configuration checker

SYNOPSIS
       .\mailchecker.ps1 [OPTIONS]

DESCRIPTION
       Mailchecker is a PowerShell script that performs comprehensive email security
       audits by checking multiple email authentication and security standards for
       any domain. It supports both single-domain analysis and bulk domain checking
       with CSV export capabilities.

       The tool validates the following email security components:

       MX Records
              Mail Exchange records that define which servers are authorized to
              receive email for the domain.

       SPF (Sender Policy Framework)
              Email authentication mechanism that specifies which mail servers are
              allowed to send messages on behalf of the domain.

       DKIM (DomainKeys Identified Mail)
              Digital signature verification system that proves message authenticity
              and integrity using cryptographic signatures.

       MTA-STS (Mail Transfer Agent - Strict Transport Security)
              Policy mechanism that enforces encrypted mail delivery (TLS) between
              servers, protecting messages from interception.

       DMARC (Domain-based Message Authentication, Reporting and Conformance)
              Email authentication policy that ties SPF and DKIM together and
              instructs receiving servers how to handle authentication failures.

       TLS-RPT (TLS Reporting)
              Reporting mechanism that provides feedback about encryption issues
              in mail delivery for monitoring and troubleshooting.

OPTIONS
       -Domain <domain>
              Single domain to check (e.g., example.com). If neither -Domain nor
              -BulkFile is specified, you will be prompted to enter a domain.

       -BulkFile <file>
              Text file containing domains to check (one per line). Supports
              comments (lines starting with #) and empty lines. Cannot be used
              together with -Domain.

       -Selectors <list>
              Comma-separated list of DKIM selectors to test. Defaults to:
              "default,s1,s2,selector1,selector2,google,mail,k1"

       -DnsServer <servers>
              Array of DNS servers to query first. Falls back to 8.8.8.8 and
              1.1.1.1 automatically if not specified.

       -Html  Generate HTML report with auto-generated timestamped filename
              (format: domain-yyyyMMdd-HHmmss.html)

       -Csv   Export bulk results to CSV file (only applicable with -BulkFile)
              (format: bulk-results-yyyyMMdd-HHmmss.csv)

       -SummaryHtml
              Generate consolidated HTML summary table (only applicable with -BulkFile)
              (format: bulk-summary-yyyyMMdd-HHmmss.html)

       -Help  Show this help information and exit

EXAMPLES
       Single Domain Analysis
              .\mailchecker.ps1 -Domain example.com
                     Check a single domain with full console output

              .\mailchecker.ps1 -Domain example.com -Html
                     Check a single domain and generate HTML report

              .\mailchecker.ps1 -Domain example.com -Selectors "google,mail"
                     Check domain with custom DKIM selectors

       Bulk Domain Checking
              .\mailchecker.ps1 -BulkFile domains.txt
                     Check multiple domains from file

              .\mailchecker.ps1 -BulkFile domains.txt -Csv
                     Check multiple domains and export results to CSV

              .\mailchecker.ps1 -BulkFile domains.txt -Html
                     Check multiple domains and generate HTML reports for each

              .\mailchecker.ps1 -BulkFile domains.txt -Csv -Html
                     Check multiple domains with both CSV export and HTML reports

              .\mailchecker.ps1 -BulkFile domains.txt -SummaryHtml
                     Check multiple domains and generate consolidated HTML summary table

              .\mailchecker.ps1 -BulkFile domains.txt -Csv -SummaryHtml -Html
                     Full export: CSV, summary HTML, and individual HTML reports

       Advanced Usage
              .\mailchecker.ps1 -Domain example.com -DnsServer @("8.8.8.8","1.1.1.1")
                     Use specific DNS servers for queries

              .\mailchecker.ps1 -BulkFile domains.txt -Selectors "custom1,custom2" -Csv
                     Bulk check with custom DKIM selectors and CSV export

INPUT FILE FORMAT (domains.txt)
       Create a text file with one domain per line:

              example.com
              test.org
              # This is a comment (ignored)
              another-domain.se

              domain-with-whitespace.com

       Notes:
       - Empty lines are ignored
       - Lines starting with # are treated as comments
       - Leading/trailing whitespace is automatically trimmed
       - Domains are converted to lowercase

OUTPUT FORMATS
       Console Output
              Color-coded console output with:
              [OK]   Green: Successful configurations
              [FAIL] Red: Failed or missing configurations
              [WARN] Yellow: Warnings and recommendations
              [INFO] Blue: Informational messages

       HTML Reports
              Comprehensive HTML reports including:
              - Summary table with all check results
              - Detailed sections for each security component
              - Color-coded status indicators with icons
              - Warnings and recommendations
              - Timestamp and domain information

       Summary HTML (Bulk Mode)
              Consolidated HTML table showing all domains:
              - One table with all domains as rows
              - Color-coded icons for quick visual scanning
              - Overview statistics (all OK, minor issues, major issues)
              - Sortable and styled for easy analysis

       CSV Export (Bulk Mode)
              Structured CSV file containing summary data for all domains:
              - Domain name
              - Boolean results for each security check
              - N/A values for non-applicable checks
              - Suitable for data analysis and reporting

TROUBLESHOOTING
       Common Issues
              1. No MX records found: Domain may not be configured for email
              2. SPF exceeds 10 DNS lookups: Simplify SPF record or use redirect
              3. DKIM no valid selectors: Check actual selector used in email headers
              4. MTA-STS in testing mode: Change policy to mode: enforce
              5. DMARC p=none: Update policy to p=quarantine or p=reject

       DNS Resolution
              The script automatically falls back between multiple DNS servers:
              1. User-specified servers (-DnsServer)
              2. Google DNS (8.8.8.8)
              3. Cloudflare DNS (1.1.1.1)

       Finding DKIM Selectors
              1. Send a test email from the domain
              2. Check the email headers for DKIM-Signature
              3. Look for the s= parameter (e.g., s=selector1)
              4. Use that selector with the -Selectors parameter

REQUIREMENTS
       - Windows PowerShell 5.1 or PowerShell Core 6+
       - Internet connectivity for DNS queries and HTTPS requests
       - Optional: Resolve-DnsName cmdlet (falls back to nslookup if unavailable)

FILES
       mailchecker.ps1
              Main PowerShell script

       domains.txt
              Example input file for bulk checking

       *.html
              Generated HTML reports (timestamped)

       bulk-results-*.csv
              Generated CSV exports (timestamped)

       bulk-summary-*.html
              Generated summary HTML reports (timestamped)

BUGS
       Report issues and feature requests at the project repository.

AUTHOR
       Written for educational and administrative purposes.

COPYRIGHT
       This script is provided as-is for educational and administrative purposes.
       Use responsibly and in accordance with your organization's policies.

SEE ALSO
       For more information about email security standards:
       - SPF: https://tools.ietf.org/html/rfc7208
       - DKIM: https://tools.ietf.org/html/rfc6376
       - DMARC: https://tools.ietf.org/html/rfc7489
       - MTA-STS: https://tools.ietf.org/html/rfc8461
       - TLS-RPT: https://tools.ietf.org/html/rfc8460

MAILCHECKER(1)                         $(Get-Date -Format 'yyyy-MM-dd')                        MAILCHECKER(1)
"@
    Write-Host $helpText
    exit 0
}

# Validate input parameters
if ($Domain -and $BulkFile) {
    throw "Cannot specify both -Domain and -BulkFile"
}
if (-not $Domain -and -not $BulkFile) {
    $Domain = Read-Host "Enter domain (e.g. example.com)"
}

function New-CheckResult {
    param(
        [string]$Section,
        [string]$Status,  # OK, FAIL, WARN, N/A
        [string[]]$Details = @(),
        [string[]]$Warnings = @(),
        [string[]]$InfoMessages = @(),
        [hashtable]$Data = @{}
    )
    
    return [pscustomobject]@{
        Section = $Section
        Status = $Status
        Details = $Details
        Warnings = $Warnings
        InfoMessages = $InfoMessages
        Data = $Data
    }
}

function Test-MXRecords {
    param([string]$Domain)
    
    $mx = Resolve-MX $Domain
    $details = @()
    $infoMessages = @()
    $status = 'FAIL'
    
    if (@($mx).Count -gt 0) {
        $details = $mx | Sort-Object Preference,NameExchange | 
                   ForEach-Object { "$($_.Preference) $($_.NameExchange)" }
        $status = 'OK'
    } else {
        $details = @("No MX records found via any configured resolver.")
        $infoMessages = @("Info: No MX records is not necessarily an error - domain may only send email (not receive).")
        $status = 'N/A'
    }
    
    return New-CheckResult -Section 'MX Records' -Status $status -Details $details -InfoMessages $infoMessages -Data @{ MXRecords = $mx }
}

function Get-SpfLookups($spf, $checked) {
  if ($checked -contains $spf) { return 0 }
  $checked += $spf
  $count = 0
  $count += ([regex]::Matches($spf, '(?i)include:')).Count
  $count += ([regex]::Matches($spf, '(?i)a(?=\s|:|$)')).Count
  $count += ([regex]::Matches($spf, '(?i)mx(?=\s|:|$)')).Count
  $count += ([regex]::Matches($spf, '(?i)ptr(?=\s|:|$)')).Count
  $count += ([regex]::Matches($spf, '(?i)exists:')).Count
  $count += ([regex]::Matches($spf, '(?i)redirect=')).Count
  # Recursive check for include and redirect
  foreach ($inc in ([regex]::Matches($spf, '(?i)include:([^\s]+)'))) {
    $incDom = $inc.Groups[1].Value
    $incSpf = Resolve-SPF $incDom
    if ($incSpf) { $count += Get-SpfLookups $incSpf $checked }
  }
  foreach ($red in ([regex]::Matches($spf, '(?i)redirect=([^\s]+)'))) {
    $redDom = $red.Groups[1].Value
    $redSpf = Resolve-SPF $redDom
    if ($redSpf) { $count += Get-SpfLookups $redSpf $checked }
  }
  return $count
}

function Test-SPFRecords {
    param([string]$Domain)
    
    $spfRecs = Resolve-SPF $Domain
    $details = @()
    $warnings = @()
    $infoMessages = @()
    $status = 'FAIL'
    $spfHealthy = $true
    
    if (@($spfRecs).Count -gt 0) {
        $i = 1
        foreach ($rec in $spfRecs) {
            $details += "SPF #$i`: $rec"
            
            # Check for soft fail
            if ($rec -match '(?i)\b~all\b') {
                $warnings += "Warning: SPF uses soft fail (~all), which is not recommended for production."
                $spfHealthy = $false
            }
            
            # Count DNS lookups
            $lookupCount = Get-SpfLookups $rec @()
            $infoMessages += "Info: DNS lookups (SPF): $lookupCount"
            
            if ($lookupCount -gt 10) {
                $warnings += "Warning: SPF exceeds 10 DNS lookups!"
                $spfHealthy = $false
            }
            
            $i++
        }
        $status = if ($spfHealthy) { 'OK' } else { 'FAIL' }
    } else {
        $details = @("No SPF (v=spf1) record found at $Domain")
        $spfHealthy = $false
    }
    
    return New-CheckResult -Section 'SPF' -Status $status -Details $details -Warnings $warnings -InfoMessages $infoMessages -Data @{ SPFRecords = $spfRecs; Healthy = $spfHealthy }
}

function Test-DKIMRecords {
    param(
        [string]$Domain,
        [string[]]$Selectors,
        [bool]$HasMX,
        [bool]$HasSpfWithMechanisms
    )
    
    $details = @()
    $warnings = @()
    $infoMessages = @()
    $status = 'FAIL'
    $dkimResults = @()
    
    # Skip DKIM test only if domain has no MX AND (no SPF record OR SPF only has -all)
    if (-not $HasMX -and -not $HasSpfWithMechanisms) {
        $infoMessages += "Not applicable - domain has no mail flow (no MX and no SPF mechanisms)"
        return New-CheckResult -Section 'DKIM' -Status 'N/A' -InfoMessages $infoMessages
    }
    
    # Check DKIM selectors
    foreach($sel in $Selectors){
        $dkimHost = "$sel._domainkey.$Domain"
        $txt = Resolve-Txt $dkimHost
        if ($txt -is [System.Collections.IEnumerable]) { $txt = ($txt -join "") }

        $hasV = $false; $hasP = $false
        if ($txt) {
            $hasV = [bool]($txt -match "(?i)\bv\s*=\s*DKIM1\b")
            $hasP = [bool](($txt -match "(?i)\bp\s*=\s*[^;]+") -or ($txt -match "(?i)\bp\s*=\s*\S+$"))
        }

        $raw = $null
        if ($txt) {
            if ($txt.Length -gt 120) {
                $raw = $txt.Substring(0,120) + "..."
            } else {
                $raw = $txt
            }
        }

        $dkimResults += [pscustomobject]@{
            Selector        = $sel
            Hostname        = $dkimHost
            Found           = ([string]::IsNullOrWhiteSpace($txt) -eq $false)
            Has_V_DKIM1     = $hasV
            Has_PublicKey_p = $hasP
            RawTXT          = $raw
            FullTXT         = $txt
        }
    }

    # Add table to details
    if ($dkimResults.Count -gt 0) {
        $tableLines = $dkimResults | Format-Table -AutoSize | Out-String -Stream
        $details += $tableLines
    }

    # Valid if TXT exists, p= exists, and if v= exists it must be DKIM1
    $validSelectors = $dkimResults | Where-Object {
        $_.Found -and $_.Has_PublicKey_p -and (
            -not $_.Has_V_DKIM1 -or $_.Has_V_DKIM1
        )
    }

    $anyValid = @($validSelectors).Count -gt 0

    # Check for warnings and info messages
    foreach ($dkim in @($validSelectors)) {
        if ($dkim.FullTXT -match '(?i)\bt=y\b') {
            $warnings += "Warning: DKIM selector '$($dkim.Selector)' is in test mode (t=y)."
        }
        if ($dkim.FullTXT -match '(?i)\bt=s\b') {
            $infoMessages += "Info: DKIM selector '$($dkim.Selector)' uses strict mode (t=s) - good security practice that prevents email spoofing from other domains."
        }
        if ($dkim.FullTXT -match '(?i)\bp=\s*;') {
            $warnings += "Warning: DKIM selector '$($dkim.Selector)' has empty key (p=), which means revocation."
        }
    }

    if ($anyValid) {
        $infoMessages += "DKIM validation successful - at least one valid selector found with proper public key."
        $status = 'OK'
    } else {
        $warnings += "DKIM validation failed - no valid selectors found with proper public keys."
        $status = 'FAIL'
    }
    
    return New-CheckResult -Section 'DKIM' -Status $status -Details $details -Warnings $warnings -InfoMessages $infoMessages -Data @{ DKIMResults = $dkimResults; AnyValid = $anyValid }
}

function Test-MTASts {
    param(
        [string]$Domain,
        [bool]$HasMX
    )
    
    $details = @()
    $warnings = @()
    $infoMessages = @()
    $status = 'FAIL'
    
    if (-not $HasMX) {
        $infoMessages += "Not applicable - domain cannot receive email"
        return New-CheckResult -Section 'MTA-STS' -Status 'N/A' -InfoMessages $infoMessages
    }
    
    # MTA-STS logic
    $MtaStsModeTesting = $false
    $MtaStsEnforced = $false
    [string]$mtaStsUrlVal = $null
    [string]$mtaStsBody = $null
    
    $mtaStsTxt = Resolve-Txt "_mta-sts.$Domain"
    if ($mtaStsTxt) {
        $details += "TXT at _mta-sts.$Domain`:"
        $details += $mtaStsTxt
        
        # Parse MTA-STS TXT record
        if ($mtaStsTxt -match '(?i)\bv=STSv1\b') {
            $details += "- v=STSv1 present: True"
            if ($mtaStsTxt -match '(?i)\bid=([^;]+)') {
                $details += "- id: $($Matches[1])"
            }
        } else {
            $details += "- v=STSv1 present: False"
        }
        
        # Fetch HTTPS policy
        $mtaStsUrl = "https://mta-sts.$Domain/.well-known/mta-sts.txt"
        $mtaStsUrlVal = $mtaStsUrl
        $mtaStsBody = Get-HttpText $mtaStsUrl
        
        if ($mtaStsBody) {
            $details += "Fetched policy from $mtaStsUrl"
            $details += $mtaStsBody
            
            # Parse mode from HTTPS policy
            $mode = $null
            foreach ($line in ($mtaStsBody -split "`n")) {
                $trim = $line.Trim()
                if ($trim -match '^(?i)mode\s*:\s*(.+)$') {
                    $mode = $Matches[1].Trim()
                    break
                }
            }
            
            # Set booleans based on mode
            switch -Regex ($mode) {
                '^(?i)enforce$' { $MtaStsEnforced = $true;  $MtaStsModeTesting = $false; break }
                '^(?i)testing$' { $MtaStsEnforced = $false; $MtaStsModeTesting = $true;  break }
                default         { $MtaStsEnforced = $false; $MtaStsModeTesting = $false; break }
            }
            
            if ($MtaStsModeTesting) {
                $warnings += "Warning: MTA-STS is in testing mode (mode=testing) and not enforced (HTTPS policy)."
            }
        } else {
            $details += "Could not fetch HTTPS policy at $mtaStsUrl"
        }
        
        $status = if ($MtaStsEnforced) { 'OK' } else { 'FAIL' }
    } else {
        $details += "No _mta-sts TXT record found."
    }
    
    return New-CheckResult -Section 'MTA-STS' -Status $status -Details $details -Warnings $warnings -InfoMessages $infoMessages -Data @{ 
        MtaStsTxt = $mtaStsTxt; 
        MtaStsBody = $mtaStsBody; 
        MtaStsUrl = $mtaStsUrlVal; 
        MtaStsModeTesting = $MtaStsModeTesting; 
        MtaStsEnforced = $MtaStsEnforced 
    }
}

function Test-DMARC {
    param([string]$Domain)

    $details = @()
    $warnings = @()
    $infoMessages = @()
    $status = 'FAIL'

    $dmarcHost = "_dmarc.$Domain"
    $dmarcTxt = Resolve-Txt $dmarcHost
    $dmarcMap = @{}
    $pVal = $null

    if ($dmarcTxt) {
        $details += "TXT at _dmarc.${Domain}:"
        $details += $dmarcTxt
        $tags = "v","p","sp","rua","ruf","fo","aspf","adkim","pct"
        foreach ($t in $tags) {
            $m = [regex]::Match($dmarcTxt, "(?im)(^|;)\s*$t\s*=\s*([^;]+)")
            if ($m.Success) {
                $val = $m.Groups[2].Value.Trim()
                $dmarcMap[$t] = $val
                $details += "- $t = $val"
                if ($t -eq 'p') { $pVal = $val }
            }
        }
        if ($dmarcMap.ContainsKey('v') -and $dmarcMap.ContainsKey('p')) {
            $infoMessages += "DMARC looks present with required tags (v & p)."
        }
        if ($pVal -and $pVal -match '(?i)^none$') {
            $warnings += "Warning: DMARC is in testing mode only (p=none) and not enforced."
            $status = 'FAIL'
        } elseif ($pVal -and $pVal -match '(?i)^(reject|quarantine)$') {
            $status = 'OK'
        } else {
            $status = 'FAIL'
        }
    } else {
        $details += "No DMARC record found at _dmarc.$Domain"
        $status = 'FAIL'
    }

    return New-CheckResult -Section 'DMARC' -Status $status -Details $details -Warnings $warnings -InfoMessages $infoMessages -Data @{ DmarcMap = $dmarcMap; DmarcTxt = $dmarcTxt; Enforced = ($status -eq 'OK') }
}

function Test-TLSReport {
    param([string]$Domain, [bool]$HasMX)

    $details = @()
    $warnings = @()
    $infoMessages = @()
    $status = 'FAIL'

    if (-not $HasMX) {
        $infoMessages += "Not applicable - domain cannot receive email"
        return New-CheckResult -Section 'SMTP TLS Reporting (TLS-RPT)' -Status 'N/A' -InfoMessages $infoMessages
    }

    $tlsRptHost = "_smtp._tls.$Domain"
    $tlsRptTxt = Resolve-Txt $tlsRptHost

    if ($tlsRptTxt) {
        $details += "TXT at $($tlsRptHost):"
        $details += $tlsRptTxt
        $hasV = [bool]($tlsRptTxt -match "(?i)\bv=TLSRPTv1\b")
        $ruaMatch = [regex]::Match($tlsRptTxt, "(?i)\bru[a]\s*=\s*(mailto:[^,;]+|https?://[^,;]+)")
        if ($hasV) { $details += "- v=TLSRPTv1 present: True" }
        if ($ruaMatch.Success) { $details += ("- rua: {0}" -f $ruaMatch.Groups[1].Value) }
        $status = 'OK'
    } else {
        $details += "No TLS-RPT record found (optional but recommended)."
        $status = 'FAIL'
    }

    return New-CheckResult -Section 'SMTP TLS Reporting (TLS-RPT)' -Status $status -Details $details -Warnings $warnings -InfoMessages $infoMessages -Data @{ TlsRptTxt = $tlsRptTxt }
}

function Write-CheckResult {
    param(
        [Parameter(ValueFromPipeline)]
        $Result
    )
    
    Write-Section $Result.Section
    
    # Details
    foreach ($line in $Result.Details) {
        Write-Host $line
    }
    
    # Info messages
    foreach ($info in $Result.InfoMessages) {
        Write-Host $info -ForegroundColor Cyan
    }
    
    # Warnings
    foreach ($warn in $Result.Warnings) {
        Write-Host $warn -ForegroundColor Yellow
    }
    
    # Status
    $color = switch ($Result.Status) {
        'OK'   { 'Green' }
        'FAIL' { 'Red' }
        'WARN' { 'Yellow' }
        'N/A'  { 'Yellow' }
    }
    Write-Host "$($Result.Section) status: $($Result.Status)" -ForegroundColor $color
}

function ConvertTo-HtmlSection {
    param(
        [Parameter(ValueFromPipeline)]
        $Result
    )
    
    # Get verbose title and info text
    $verboseTitle = $Result.Section
    $infoText = ""
    
    switch ($Result.Section) {
        "MX Records" { 
            $verboseTitle = "MX Records"
            $infoText = "Mail Exchange (MX) records define which servers are authorized to receive email for your domain. Missing or incorrect MX records mean your domain cannot receive mail reliably." 
        }
        "SPF" { 
            $verboseTitle = "SPF (Sender Policy Framework)"
            $infoText = "SPF (Sender Policy Framework) helps prevent email spoofing by specifying which mail servers are allowed to send messages on behalf of your domain. Weak or missing SPF records make it easier for attackers to impersonate your domain." 
        }
        "DKIM" { 
            $verboseTitle = "DKIM (DomainKeys Identified Mail)"
            $infoText = "DKIM (DomainKeys Identified Mail) adds a digital signature to outgoing messages, proving they were not altered in transit and originate from an authorized sender. Without valid DKIM keys, recipients cannot verify the authenticity of your emails." 
        }
        "MTA-STS" { 
            $verboseTitle = "MTA-STS (Mail Transfer Agent - Strict Transport Security)"
            $infoText = "MTA-STS (Mail Transfer Agent - Strict Transport Security) enforces encrypted mail delivery (TLS) between servers, protecting messages from interception. Without MTA-STS, emails may still be sent unencrypted even if your server supports TLS." 
        }
        "DMARC" { 
            $verboseTitle = "DMARC (Domain-based Message Authentication, Reporting and Conformance)"
            $infoText = "DMARC (Domain-based Message Authentication, Reporting and Conformance) ties SPF and DKIM together and instructs receiving servers how to handle messages that fail authentication. A missing or unenforced DMARC policy allows spoofed emails to appear legitimate." 
        }
        "SMTP TLS Reporting (TLS-RPT)" { 
            $verboseTitle = "TLS-RPT (SMTP TLS Reporting)"
            $infoText = "TLS-RPT (SMTP TLS Reporting) provides feedback about encryption issues in mail delivery, helping administrators identify failed or downgraded TLS connections. It is optional but highly recommended for visibility and security monitoring." 
        }
    }
    
    $html = "  <h2>$verboseTitle</h2>`n"
    
    if ($infoText) {
        $html += "  <p>$([System.Web.HttpUtility]::HtmlEncode($infoText))</p>`n"
    }
    
    if ($Result.Details -and $Result.Details.Count -gt 0) {
        $html += "  <pre>"
        foreach ($line in $Result.Details) {
            $html += ([System.Web.HttpUtility]::HtmlEncode($line) + "`n")
        }
        $html += "</pre>`n"
    }
    
    $allMessages = @()
    if ($Result.InfoMessages -and $Result.InfoMessages.Count -gt 0) { $allMessages += $Result.InfoMessages }
    if ($Result.Warnings -and $Result.Warnings.Count -gt 0) { $allMessages += $Result.Warnings }
    if ($allMessages.Count -gt 0) {
        $html += "`n  <div class='info-block'>`n"
        foreach ($msg in $allMessages) {
            $cls = 'status-info'
            $icon = '&#x2139;&#xFE0F; '  # ℹ️
            if ($msg -match '^(?i)\s*Warning:') { 
                $cls = 'status-warn'
                $icon = '&#x26A0;&#xFE0F; '  # ⚠️
            }
            $encodedMsg = [System.Web.HttpUtility]::HtmlEncode($msg)
            $html += ("    <p class='" + $cls + "'>" + $icon + $encodedMsg + "</p>`n")
        }
        $html += "  </div>`n"
    }
    
    $statusText = "$($Result.Section) status: $($Result.Status)"
    $clsFinal = switch ($Result.Status) {
        'OK'   { 'status-ok'; $icon = '&#x2705; ' }    # ✅
        'FAIL' { 'status-fail'; $icon = '&#x274C; ' }  # ❌
        'WARN' { 'status-warn'; $icon = '&#x26A0;&#xFE0F; ' }  # ⚠️
        'N/A'  { 'status-info'; $icon = '&#x2139;&#xFE0F; ' }  # ℹ️
    }
    $encodedStatus = [System.Web.HttpUtility]::HtmlEncode($statusText)
    $html += "  <p class='" + $clsFinal + "'>" + $icon + $encodedStatus + "</p>`n"
    
    return $html
}

function Write-Section($title) {
  Write-Host ""
  Write-Host "=== $title ===" -ForegroundColor White
}

function Write-BoolLine {
  param([string]$Label, $Value)
  if ($Value -is [string] -and $Value -eq "N/A") {
    $color = 'Cyan'
    $text = 'N/A'
  } elseif ($Label -eq 'MX_Records_Present' -and -not $Value) {
    # MX records not present is informational, not an error (domain may only send email)
    $color = 'Cyan'
    $text = 'False'
  } else {
    $color = if ($Value) { 'Green' } else { 'Red' }
    $text  = if ($Value) { 'True' }  else { 'False' }
  }
  Write-Host ("- {0}: " -f $Label) -NoNewline
  Write-Host $text -ForegroundColor $color
}

# Build resolver list
$Resolvers = @()
if ($DnsServer) { $Resolvers += $DnsServer }
$Resolvers += @('8.8.8.8','1.1.1.1')
$Resolvers = $Resolvers | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique

function Resolve-Txt {
  param([string]$Name)

  foreach ($srv in $Resolvers) {
    try {
      if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
  # Primary query
        $ans = Resolve-DnsName -Name $Name -Type TXT -Server $srv -ErrorAction Stop
        $txtRecs = $ans | Where-Object { $_.Type -eq 'TXT' -and $_.PSObject.Properties['Strings'] }

        $strings = foreach ($rec in $txtRecs) { ($rec.Strings -join '') }
        if ($strings -and $strings.Count -gt 0) { return ($strings -join ' ') }

  # Follow any CNAME to the target and query TXT there
        $cname = ($ans | Where-Object { $_.Type -eq 'CNAME' } | Select-Object -First 1 -ExpandProperty NameHost -ErrorAction SilentlyContinue)
        if ($cname) {
          $ans2 = Resolve-DnsName -Name $cname -Type TXT -Server $srv -ErrorAction Stop
          $txtRecs2 = $ans2 | Where-Object { $_.Type -eq 'TXT' -and $_.PSObject.Properties['Strings'] }
          $strings2 = foreach ($rec in $txtRecs2) { ($rec.Strings -join '') }
          if ($strings2 -and $strings2.Count -gt 0) { return ($strings2 -join ' ') }
        }
      }
      else {
  # Fallback: nslookup
        $out = nslookup -type=txt $Name $srv 2>$null
        $txt = ($out | Select-String -Pattern '"([^"]*)"' -AllMatches).Matches.Value -replace '"',''
        $joined = ($txt -join '')
        if ($joined) { return $joined }
      }
    } catch { }
  }
  return $null
}

function Resolve-MX {
  param([string]$Domain)

  foreach ($srv in $Resolvers) {
    try {
      if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        $ans = Resolve-DnsName -Name $Domain -Type MX -Server $srv -ErrorAction Stop

        $mxRecs = $ans |
          Where-Object {
            # Section may be missing in some versions; accept the line anyway
            ($_.PSObject.Properties.Match('Section').Count -eq 0 -or $_.Section -eq 'Answer') -and
            (
              $_.PSObject.Properties.Match('NameExchange').Count -gt 0 -or
              ($_.PSObject.Properties.Match('Type').Count -gt 0 -and $_.Type -eq 'MX') -or
              ($_.PSObject.Properties.Match('QueryType').Count -gt 0 -and $_.QueryType -eq 'MX')
            )
          } |
          Select-Object @{n='Preference';e={ if ($_.PSObject.Properties.Match('Preference')) { $_.Preference } else { 0 } }},
                        @{n='NameExchange';e={ $_.NameExchange }}

        if (@($mxRecs).Count -gt 0) { return $mxRecs }
      }
      else {
  # Fallback: nslookup
        $out = nslookup -type=mx $Domain $srv 2>$null
        $lines = $out | Where-Object { $_ -match 'mail exchanger =|preference =' }
        $result = @()
        foreach ($line in $lines) {
          if ($line -match 'preference\s*=\s*(\d+),\s*mail exchanger\s*=\s*(\S+)') {
            $result += [pscustomobject]@{ Preference = [int]$Matches[1]; NameExchange = $Matches[2] }
          } elseif ($line -match 'mail exchanger\s*=\s*(\S+)') {
            $result += [pscustomobject]@{ Preference = 0; NameExchange = $Matches[1] }
          }
        }
        if (@($result).Count -gt 0) { return $result }
      }
    } catch { }
  }
  return @()
}

function Resolve-SPF {
  param([string]$Domain)

  foreach ($srv in $Resolvers) {
    try {
      if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        $ans = Resolve-DnsName -Name $Domain -Type TXT -Server $srv -ErrorAction Stop
        $txts = foreach($rec in $ans) {
          if ($rec.PSObject.Properties['Strings']) { ($rec.Strings -join '') }
        }
        $spf = @($txts | Where-Object { $_ -match '(?i)\bv=spf1\b' })
        if ($spf.Count -gt 0) { return $spf }
      } else {
  # Fallback: nslookup (find block near "v=spf1" and join quoted strings)
        $out = nslookup -type=txt $Domain $srv 2>$null
        $hit = $out | Select-String -Pattern 'v=spf1' -Context 0,3 | Select-Object -First 1
        if ($hit) {
          $lines = @($hit.Line) + $hit.Context.PostContext
          $txt = ($lines | Select-String -Pattern '"([^"]*)"' -AllMatches).Matches.Value -replace '"','' -join ''
          if ($txt) { return @($txt) }
        }
      }
    } catch { }
  }
  return @()
}

function Get-DmarcInfo($txt){
  $map = @{}
  if (-not $txt) { return $map }
  $pairs = $txt -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  foreach($p in $pairs){
    $kv = $p -split '=',2
    if($kv.Count -eq 2){
      $map[$kv[0].Trim()] = $kv[1].Trim()
    }
  }
  return $map
}

function Get-HttpText($url){
  try {
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers @{ "User-Agent"="MailStackCheck/1.1" } -TimeoutSec 10
    return [string]$resp.Content
  } catch {
    return $null
  }
}

function Write-HtmlReport {
  param(
    [string]$Path,
    [string]$Domain,
    [pscustomobject]$Summary,
    $mxResult,
    $spfResult,
    $dkimResult,
    $mtaStsResult,
    $dmarcResult,
    $tlsResult
  )

  # Old Render-Section function removed - now using ConvertTo-HtmlSection

  $css = @'
  body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; color:#222 }
  h1 { color:#0078D7 }
  h2 { border-bottom:1px solid #ddd; padding-bottom:4px }
  table { border-collapse: collapse; width: 480px; margin-bottom: 12px; table-layout: fixed; }
  table th, table td { word-wrap: break-word; overflow-wrap: break-word; padding: 6px 8px; }
  /* Borderless table variant for DKIM (columns still align) */
  table.no-borders { border: none }
  table.no-borders th, table.no-borders td { border: none; padding:6px 8px; text-align:left; vertical-align:top; }
  /* Use a monospace font for pre-wrapped cells to keep columns aligned */
  table.no-borders td pre { margin:0; font-family: Consolas, 'Courier New', monospace; white-space: pre-wrap }
  th, td { border:1px solid #ddd; padding:6px 8px; text-align:left }
  .ok { color: green }
  .warn { color: #b58900 }
  .fail { color: red }
  .info { color: #0078D7 }
  p.ok, p.fail, p.warn, p.info { font-size: 14px; margin: 4px 0; font-weight: 600 }
  p.ok { color: green }
  p.fail { color: red }
  p.warn { color: #b58900 }
  p.info { color: #0078D7 }
  /* Icon support - icons are manually added in HTML content */
  .status-ok { color: green; }
  .status-fail { color: red; }
  .status-warn { color: #b58900; }
  .status-info { color: #0078D7; }
  /* Info blocks styling */
  .info-block { margin: 8px 0 4px 0; }
  .info-block p { margin: 2px 0; }
'@

  $now = (Get-Date).ToString('u')

  $html = @"
<html>
  <head>
    <meta charset='utf-8' />
    <title>Mail check report for $Domain</title>
    <style>$css</style>
  </head>
  <body>
  <h1>Mail check report &mdash; $([System.Web.HttpUtility]::HtmlEncode($Domain))</h1>
    <p>Generated: $now</p>
"@

  # Friendly names mapping for Summary table
  $friendlyNames = @{
    'Domain' = 'Domain'
    'MX_Records_Present' = 'MX records found'
    'SPF_Present' = 'SPF record present'
    'SPF_Healthy' = 'SPF configuration valid'
    'DKIM_ValidSelector' = 'DKIM selector valid'
    'MTA_STS_DNS_Present' = 'MTA-STS DNS record present'
    'MTA_STS_Enforced' = 'MTA-STS policy enforced'
    'DMARC_Present' = 'DMARC record present'
    'DMARC_Enforced' = 'DMARC policy enforced (reject/quarantine)'
    'TLS_RPT_Present' = 'TLS-RPT reporting enabled'
  }

  $html += "<h2>Summary</h2>"
  $html += "<p>Tested domain: <strong>$([System.Web.HttpUtility]::HtmlEncode($Summary.Domain))</strong></p>"
  $html += "<table style='width: 480px; table-layout: fixed;'><tr><th style='width: 360px;'>Test</th><th style='width: 120px;'>Result</th></tr>"
  foreach ($k in $Summary.PSObject.Properties.Name) {
    # Skip Domain since it's now shown above the table
    if ($k -eq 'Domain') { continue }
    $v = $Summary.$k
    if ($v -is [string] -and $v -eq "N/A") { 
      $cls = 'status-info'
      $valStr = '&#x2139;&#xFE0F; N/A'  # ℹ️ N/A
    } elseif ($k -eq 'MX_Records_Present' -and $v -eq $false) {
      # MX records not present is informational, not an error (domain may only send email)
      $cls = 'status-info'
      $valStr = '&#x2139;&#xFE0F; False'  # ℹ️ False
    } elseif ($v -is [bool]) { 
      $cls = if ($v) { 'status-ok' } else { 'status-fail' }
      $valStr = if ($v) { '&#x2705; True' } else { '&#x274C; False' }  # ✅ True / ❌ False
    } else { 
      $cls = ''
      $valStr = [System.Web.HttpUtility]::HtmlEncode($v)
    }
    $displayName = if ($friendlyNames.ContainsKey($k)) { $friendlyNames[$k] } else { $k }
    $html += "<tr><td>$( [System.Web.HttpUtility]::HtmlEncode($displayName) )</td><td class='$cls'>$valStr</td></tr>"
  }
  $html += "</table>"

  # Old helper functions removed - now using ConvertTo-HtmlSection

  # (Block status table removed - verbose per-block console text is included in each section below)

  # Use unified result objects for all sections
  $html += ConvertTo-HtmlSection $mxResult
  $html += ConvertTo-HtmlSection $spfResult
  $html += ConvertTo-HtmlSection $dkimResult
  $html += ConvertTo-HtmlSection $mtaStsResult
  $html += ConvertTo-HtmlSection $dmarcResult
  $html += ConvertTo-HtmlSection $tlsResult

  $html += "</body></html>"

  try {
    $html | Out-File -FilePath $Path -Encoding utf8 -Force
    Write-Host "Wrote HTML report to: $Path" -ForegroundColor Green
  } catch {
    Write-Host ("Failed to write HTML report to {0}: {1}" -f $Path, $_) -ForegroundColor Red
  }
}

function Write-SummaryHtmlReport {
  param(
    [string]$Path,
    [array]$AllResults
  )

  $css = @'
  body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; color:#222 }
  h1 { color:#0078D7 }
  h2 { border-bottom:1px solid #ddd; padding-bottom:4px; margin-top: 30px }
  table { border-collapse: collapse; width: 100%; margin-bottom: 12px; }
  th, td { border:1px solid #ddd; padding:8px 12px; text-align:left }
  th { background-color: #f5f5f5; font-weight: 600; position: sticky; top: 0; }
  td.domain { font-weight: 600; font-family: 'Courier New', monospace; }
  .status-ok { color: green; }
  .status-fail { color: red; }
  .status-warn { color: #b58900; }
  .status-info { color: #0078D7; }
  tr:hover { background-color: #f9f9f9; }
  .summary-stats { background-color: #f0f8ff; padding: 15px; border-radius: 5px; margin-bottom: 20px; }
  .summary-stats p { margin: 5px 0; }
'@

  $now = (Get-Date).ToString('u')
  $totalDomains = $AllResults.Count
  
  # Calculate statistics
  $allOK = 0
  $someIssues = 0
  $majorIssues = 0
  
  foreach ($result in $AllResults) {
    $summary = $result.Summary
    $failCount = 0
    
    # Count failures (excluding N/A and MX_Records_Present which is informational)
    # Note: MX_Records_Present = False is not a failure (domain may only send email)
    if ($summary.SPF_Present -eq $false) { $failCount++ }
    if ($summary.SPF_Healthy -eq $false) { $failCount++ }
    if ($summary.DKIM_ValidSelector -is [bool] -and $summary.DKIM_ValidSelector -eq $false) { $failCount++ }
    if ($summary.MTA_STS_DNS_Present -is [bool] -and $summary.MTA_STS_DNS_Present -eq $false) { $failCount++ }
    if ($summary.MTA_STS_Enforced -is [bool] -and $summary.MTA_STS_Enforced -eq $false) { $failCount++ }
    if ($summary.DMARC_Present -eq $false) { $failCount++ }
    if ($summary.DMARC_Enforced -eq $false) { $failCount++ }
    if ($summary.TLS_RPT_Present -is [bool] -and $summary.TLS_RPT_Present -eq $false) { $failCount++ }
    
    if ($failCount -eq 0) {
      $allOK++
    } elseif ($failCount -le 2) {
      $someIssues++
    } else {
      $majorIssues++
    }
  }

  $html = @"
<html>
  <head>
    <meta charset='utf-8' />
    <title>Bulk Mail Check Summary Report</title>
    <style>$css</style>
  </head>
  <body>
  <h1>Bulk Mail Check Summary Report</h1>
  <p>Generated: $now</p>
  
  <div class='summary-stats'>
    <h2>Overview Statistics</h2>
    <p><strong>Total Domains Checked:</strong> $totalDomains</p>
    <p><strong>&#x2705; All Checks Passed:</strong> $allOK domains</p>
    <p><strong>&#x26A0;&#xFE0F; Minor Issues (1-2 failures):</strong> $someIssues domains</p>
    <p><strong>&#x274C; Major Issues (3+ failures):</strong> $majorIssues domains</p>
  </div>
  
  <h2>Detailed Results</h2>
  <table>
    <tr>
      <th>Domain</th>
      <th>MX Records</th>
      <th>SPF Present</th>
      <th>SPF Healthy</th>
      <th>DKIM Valid</th>
      <th>MTA-STS DNS</th>
      <th>MTA-STS Enforced</th>
      <th>DMARC Present</th>
      <th>DMARC Enforced</th>
      <th>TLS-RPT</th>
    </tr>
"@

  foreach ($result in $AllResults) {
    $summary = $result.Summary
    $domain = [System.Web.HttpUtility]::HtmlEncode($summary.Domain)
    
    $html += "    <tr>`n"
    $html += "      <td class='domain'>$domain</td>`n"
    
    # Helper function to render cell
    $renderCell = {
      param($value, $fieldName)
      if ($value -is [string] -and $value -eq "N/A") {
        return "<td class='status-info'>&#x2139;&#xFE0F; N/A</td>"
      } elseif ($fieldName -eq 'MX_Records_Present' -and $value -eq $false) {
        # MX records not present is informational, not an error (domain may only send email)
        return "<td class='status-info'>&#x2139;&#xFE0F; No</td>"
      } elseif ($value -eq $true) {
        return "<td class='status-ok'>&#x2705; Yes</td>"
      } else {
        return "<td class='status-fail'>&#x274C; No</td>"
      }
    }
    
    $html += (& $renderCell $summary.MX_Records_Present 'MX_Records_Present') + "`n"
    $html += (& $renderCell $summary.SPF_Present) + "`n"
    $html += (& $renderCell $summary.SPF_Healthy) + "`n"
    $html += (& $renderCell $summary.DKIM_ValidSelector) + "`n"
    $html += (& $renderCell $summary.MTA_STS_DNS_Present) + "`n"
    $html += (& $renderCell $summary.MTA_STS_Enforced) + "`n"
    $html += (& $renderCell $summary.DMARC_Present) + "`n"
    $html += (& $renderCell $summary.DMARC_Enforced) + "`n"
    $html += (& $renderCell $summary.TLS_RPT_Present) + "`n"
    
    $html += "    </tr>`n"
  }

  $html += @"
  </table>
  
  <p style='margin-top: 30px; color: #666; font-size: 12px;'>
    <strong>Legend:</strong> 
    <span style='color: green;'>&#x2705; Yes</span> = Passed | 
    <span style='color: red;'>&#x274C; No</span> = Failed | 
    <span style='color: #0078D7;'>&#x2139;&#xFE0F; N/A / No MX</span> = Informational (not a failure)
  </p>
  </body>
</html>
"@

  try {
    $html | Out-File -FilePath $Path -Encoding utf8 -Force
    Write-Host "Wrote summary HTML report to: $Path" -ForegroundColor Green
  } catch {
    Write-Host ("Failed to write summary HTML report to {0}: {1}" -f $Path, $_) -ForegroundColor Red
  }
}

function Invoke-DomainCheck {
    param(
        [string]$Domain,
        [string]$Selectors = "default,s1,s2,selector1,selector2,google,mail,k1",
        [bool]$QuietMode = $false
    )
    
$Domain = $Domain.Trim().ToLower()

    if (-not $QuietMode) {
Write-Host "Checking domain: $Domain (Resolvers: $($Resolvers -join ', '))" -ForegroundColor Yellow
    }

# 1) MX Records
$mxResult = Test-MXRecords -Domain $Domain
$mx = $mxResult.Data.MXRecords
$mxOk = @($mx).Count -gt 0
    if (-not $QuietMode) { Write-CheckResult $mxResult }

# 2) SPF
$spfResult = Test-SPFRecords -Domain $Domain
$spfRecs = $spfResult.Data.SPFRecords
$spfHealthy = $spfResult.Data.Healthy
    if (-not $QuietMode) { Write-CheckResult $spfResult }

# 3) DKIM (by selectors)
# Check if SPF has any mechanisms other than just v=spf1 and -all
$hasSpfWithMechanisms = $false
if (@($spfRecs).Count -gt 0) {
  foreach ($spf in $spfRecs) {
    $cleanSpf = $spf -replace '(?i)\bv=spf1\s*', '' -replace '(?i)\s*[~+\-?]?all\s*$', '' -replace '^\s+|\s+$', ''
    $hasMechanisms = $cleanSpf.Length -gt 0 -and $cleanSpf -match '(?i)(include:|a:|mx:|ptr:|exists:|redirect=)'
    if ($hasMechanisms) {
      $hasSpfWithMechanisms = $true
      break
    }
  }
}

$selectorList = ($Selectors -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$dkimResult = Test-DKIMRecords -Domain $Domain -Selectors $selectorList -HasMX $mxOk -HasSpfWithMechanisms $hasSpfWithMechanisms
$dkimResults = $dkimResult.Data.DKIMResults
$DKIM_AnySelector_Valid = $dkimResult.Data.AnyValid
    if (-not $QuietMode) { Write-CheckResult $dkimResult }

# 4) MTA-STS
$mtaStsResult = Test-MTASts -Domain $Domain -HasMX $mxOk
$mtaStsTxt = $mtaStsResult.Data.MtaStsTxt
$MtaStsEnforced = $mtaStsResult.Data.MtaStsEnforced
$MtaStsModeTesting = $mtaStsResult.Data.MtaStsModeTesting
    if (-not $QuietMode) { Write-CheckResult $mtaStsResult }

# 5) DMARC
$dmarcResult = Test-DMARC -Domain $Domain
$dmarc = $dmarcResult.Data.DmarcMap
$dmarcTxt = $dmarcResult.Data.DmarcTxt
$dmarcEnforced = [bool]$dmarcResult.Data.Enforced
    if (-not $QuietMode) { Write-CheckResult $dmarcResult }

# 6) TLS-RPT
$tlsResult = Test-TLSReport -Domain $Domain -HasMX $mxOk
$tlsRptTxt = $tlsResult.Data.TlsRptTxt
    if (-not $QuietMode) { Write-CheckResult $tlsResult }

# Summary
$hasMXRecords = [bool]$mxOk
$summary = [pscustomobject]@{
  Domain                 = $Domain
  MX_Records_Present     = $hasMXRecords
  SPF_Present            = [bool](@($spfRecs).Count -gt 0)
  SPF_Healthy            = [bool]$spfHealthy
  DKIM_ValidSelector     = if ($hasMXRecords -or $hasSpfWithMechanisms) { [bool]$DKIM_AnySelector_Valid } else { "N/A" }
  MTA_STS_DNS_Present    = if ($hasMXRecords) { [bool]$mtaStsTxt } else { "N/A" }
  MTA_STS_Enforced       = if ($hasMXRecords) { [bool]$MtaStsEnforced } else { "N/A" }
  DMARC_Present          = [bool]$dmarcTxt
  DMARC_Enforced         = [bool]$dmarcEnforced
  TLS_RPT_Present        = if ($hasMXRecords) { [bool]$tlsRptTxt } else { "N/A" }
}

    if (-not $QuietMode) {
        Write-Section "Summary"
        Write-Host "Tested domain: $Domain" -ForegroundColor White

# Färgkodad radvis status
Write-Host "`nStatus:"
Write-BoolLine "MX_Records_Present"     $summary.MX_Records_Present
Write-BoolLine "SPF_Present"            $summary.SPF_Present
Write-BoolLine "SPF_Healthy"            $summary.SPF_Healthy
Write-BoolLine "DKIM_ValidSelector"     $summary.DKIM_ValidSelector
Write-BoolLine "MTA_STS_DNS_Present"    $summary.MTA_STS_DNS_Present
Write-BoolLine "MTA_STS_Enforced"       $summary.MTA_STS_Enforced
Write-BoolLine "DMARC_Present"          $summary.DMARC_Present
Write-BoolLine "DMARC_Enforced"         $summary.DMARC_Enforced
Write-BoolLine "TLS_RPT_Present"        $summary.TLS_RPT_Present

Write-Host "`nTip: For DKIM, inspect a real message header to learn the active selector (s=) and re-run with -Selectors 'thatSelector'." -ForegroundColor DarkCyan
    }
    
    # Return all results as hashtable
    return @{
        Domain = $Domain
        MXResult = $mxResult
        SPFResult = $spfResult
        DKIMResult = $dkimResult
        MTAStsResult = $mtaStsResult
        DMARCResult = $dmarcResult
        TLSResult = $tlsResult
        Summary = $summary
    }
}

# --- Main ---

if ($BulkFile) {
    # Bulk mode: process multiple domains
    $domains = @(Get-Content $BulkFile | 
               Where-Object { $_ -and $_.Trim() -and -not $_.Trim().StartsWith('#') } |
               ForEach-Object { $_.Trim().ToLower() })
    
    if ($domains.Count -eq 0) {
        throw "No valid domains found in $BulkFile"
    }
    
    Write-Host "Checking $($domains.Count) domains (Resolvers: $($Resolvers -join ', '))" -ForegroundColor Yellow
    Write-Host ""
    
    $allResults = @()
    $total = $domains.Count
    
    for ($i = 0; $i -lt $total; $i++) {
        Write-Host "Processing domain $($i + 1) of ${total}: $($domains[$i])" -ForegroundColor Yellow
        $result = Invoke-DomainCheck -Domain $domains[$i] -Selectors $Selectors -QuietMode $true
        $allResults += $result
    }
    
    Write-Host "`nAll domains processed." -ForegroundColor Green
    
    # Export CSV if requested
    if ($Csv) {
        $csvData = $allResults | ForEach-Object { $_.Summary }
  $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $csvPath = "bulk-results-$ts.csv"
        $csvData | Export-Csv -Path $csvPath -NoTypeInformation
        Write-Host "CSV exported to: $csvPath" -ForegroundColor Green
    }
    
    # Generate summary HTML report if requested
    if ($SummaryHtml) {
        $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $summaryHtmlPath = "bulk-summary-$ts.html"
        Write-SummaryHtmlReport -Path $summaryHtmlPath -AllResults $allResults
    }
    
    # Generate HTML reports if requested
    if ($Html) {
        $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $htmlCount = 0
        foreach ($result in $allResults) {
            $safeDomain = $result.Domain -replace '[^a-z0-9.-]','-'
            $htmlPath = "$safeDomain-$ts.html"
            Write-HtmlReport -Path $htmlPath -Domain $result.Domain -Summary $result.Summary `
                           -mxResult $result.MXResult -spfResult $result.SPFResult `
                           -dkimResult $result.DKIMResult -mtaStsResult $result.MTAStsResult `
                           -dmarcResult $result.DMARCResult -tlsResult $result.TLSResult
            $htmlCount++
        }
        Write-Host "Generated $htmlCount HTML reports." -ForegroundColor Green
    }
    
} else {
    # Single domain mode: existing behavior with full console output
    $result = Invoke-DomainCheck -Domain $Domain -Selectors $Selectors -QuietMode $false
    
    # Generate HTML report if requested
    if ($Html) {
        $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $safeDomain = $Domain -replace '[^a-z0-9.-]','-'
        $outPath = "$safeDomain-$ts.html"
        Write-HtmlReport -Path $outPath -Domain $Domain -Summary $result.Summary `
                       -mxResult $result.MXResult -spfResult $result.SPFResult `
                       -dkimResult $result.DKIMResult -mtaStsResult $result.MTAStsResult `
                       -dmarcResult $result.DMARCResult -tlsResult $result.TLSResult
    }
}

