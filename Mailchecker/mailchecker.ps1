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
  [string]$OutputPath,
  
  [Parameter(Mandatory=$false)]
  [switch]$FullHtmlExport,
  
  [Parameter(Mandatory=$false)]
  [switch]$OpenReport,
  
  [Parameter(Mandatory=$false)]
  [switch]$Json,
  
  [Parameter(Mandatory=$false)]
  [switch]$Help
)

# Show help if requested
if ($Help) {
    $helpText = @"
MAILCHECKER - Email Security Configuration Checker
===================================================

SYNOPSIS
    .\mailchecker.ps1 -Domain <domain> [-Selectors <list>] [-Html]
    .\mailchecker.ps1 -BulkFile <file> [-FullHtmlExport] [-OpenReport] [-Json]

DESCRIPTION
    Checks email security: MX, SPF, DKIM, MTA-STS, DMARC, TLS-RPT
    See README.md for detailed documentation and security standards.

KEY PARAMETERS
    -Domain <domain>         Single domain to check
    -BulkFile <file>         File with domains (one per line)
    -Selectors <list>        DKIM selectors (default: default,s1,s2,selector1,selector2,google,mail,k1)
    -DnsServer <servers>     DNS servers to use (default: 8.8.8.8, 1.1.1.1)
    
OUTPUT OPTIONS
    -Html                    Generate HTML report for single domain
    -FullHtmlExport         [RECOMMENDED] Complete export: index, domain reports, CSV, assets
    -Json                    Add JSON export (with -FullHtmlExport)
    -OutputPath <path>       Output directory (auto-generated if not specified)
    -OpenReport              Auto-open report in browser (with -FullHtmlExport)

QUICK EXAMPLES

  Single Domain:
    .\mailchecker.ps1 -Domain example.com
    .\mailchecker.ps1 -Domain example.com -Html

  Bulk Checking:
    .\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport
    .\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -OpenReport
    .\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -Json -OutputPath ./reports

FULL HTML EXPORT STRUCTURE
    domains-20251008-142315/
      index.html              Main summary with links
      bulk-results-*.csv      CSV export
      results.json            JSON export (if -Json)
      assets/
        style.css             Modern responsive styles
        app.js                Interactive features
      domains/
        example.com.html      Individual reports
        ...

INPUT FILE FORMAT (domains.txt)
    example.com
    test.org
    # Comments start with #
    another-domain.com

SEVERITY LEVELS
    [PASS] - Meets strict security standards
    [WARN] - Needs improvement (not fully enforced)
    [FAIL] - Critical issue or missing
    [N/A]  - Not applicable

COMMON ISSUES
    - DKIM no valid selectors -> Check email headers for s= parameter
    - SPF >10 lookups -> Simplify or use redirect
    - MTA-STS testing mode -> Change to mode: enforce
    - DMARC p=none -> Upgrade to p=reject

MORE INFORMATION
    See README.md for:
    - Detailed security check descriptions
    - Complete parameter reference
    - Troubleshooting guide
    - RFC references and best practices

Version: mailchecker.ps1 v2.0
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

function New-OutputStructure {
    param(
        [string]$InputFile,
        [string]$OutputPath
    )
    
    # Determine final output path
    $resolvedPath = $null
    
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        # Auto-generate path based on input file
        if ([string]::IsNullOrWhiteSpace($InputFile)) {
            # Single domain mode - use generic name
            $baseName = "mailcheck-report"
        } else {
            # Bulk mode - use input filename without extension
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
        }
        
        $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $resolvedPath = Join-Path (Get-Location) "$baseName-$timestamp"
    } else {
        # Use provided path
        $resolvedPath = $OutputPath
    }
    
    # Create main directory
    if (-not (Test-Path $resolvedPath)) {
        try {
            New-Item -ItemType Directory -Path $resolvedPath -Force | Out-Null
            Write-Host "Created output directory: $resolvedPath" -ForegroundColor Cyan
        } catch {
            Write-Host "Error: Could not create output directory: $resolvedPath" -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Red
            throw
        }
    }
    
    # Create subdirectories for FullHtmlExport
    $domainsPath = Join-Path $resolvedPath "domains"
    $assetsPath = Join-Path $resolvedPath "assets"
    
    if (-not (Test-Path $domainsPath)) {
        New-Item -ItemType Directory -Path $domainsPath -Force | Out-Null
    }
    
    if (-not (Test-Path $assetsPath)) {
        New-Item -ItemType Directory -Path $assetsPath -Force | Out-Null
    }
    
    return @{
        RootPath = $resolvedPath
        DomainsPath = $domainsPath
        AssetsPath = $assetsPath
    }
}

function Write-AssetsFiles {
    param([string]$AssetsPath)
    
    # Create style.css
    $css = @'
/* Global styles */
body { 
    font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; 
    margin: 0;
    padding: 20px;
    background-color: #f5f5f5;
    color: #222;
    line-height: 1.6;
}

.container {
    max-width: 1400px;
    margin: 0 auto;
    background-color: white;
    padding: 30px;
    border-radius: 8px;
    box-shadow: 0 2px 10px rgba(0,0,0,0.1);
}

h1 { 
    color: #0078D7;
    border-bottom: 3px solid #0078D7;
    padding-bottom: 10px;
    margin-bottom: 20px;
}

h2 { 
    border-bottom: 1px solid #ddd;
    padding-bottom: 8px;
    margin-top: 30px;
    color: #333;
}

/* Navigation */
.nav-link {
    display: inline-block;
    margin: 10px 0;
    padding: 8px 16px;
    background-color: #0078D7;
    color: white;
    text-decoration: none;
    border-radius: 4px;
    transition: background-color 0.3s;
}

.nav-link:hover {
    background-color: #005a9e;
}

/* Summary statistics */
.summary-stats {
    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
    color: white;
    padding: 20px;
    border-radius: 8px;
    margin-bottom: 30px;
}

.summary-stats h2 {
    color: white;
    border-bottom: 2px solid rgba(255,255,255,0.3);
    margin-top: 0;
}

.summary-stats p {
    margin: 8px 0;
    font-size: 16px;
}

.stats-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 15px;
    margin-top: 15px;
}

.stat-card {
    background-color: rgba(255,255,255,0.15);
    padding: 15px;
    border-radius: 6px;
    text-align: center;
}

.stat-number {
    font-size: 32px;
    font-weight: bold;
    margin: 10px 0;
}

/* Table styles */
table {
    border-collapse: collapse;
    width: 100%;
    margin-bottom: 20px;
    background-color: white;
    box-shadow: 0 1px 3px rgba(0,0,0,0.1);
}

th, td {
    border: 1px solid #ddd;
    padding: 12px;
    text-align: left;
}

th {
    background-color: #f8f9fa;
    font-weight: 600;
    position: sticky;
    top: 0;
    z-index: 10;
}

tr:hover {
    background-color: #f9f9f9;
}

td.domain {
    font-weight: 600;
    font-family: 'Courier New', monospace;
}

/* Status badges */
.status-badge {
    display: inline-block;
    padding: 4px 10px;
    border-radius: 12px;
    font-size: 13px;
    font-weight: 600;
    text-transform: uppercase;
}

.status-ok {
    color: #28a745;
}

.status-fail {
    color: #dc3545;
}

.status-warn {
    color: #ffc107;
}

.status-info {
    color: #0078D7;
}

/* Info blocks */
.info-block {
    margin: 12px 0;
    padding: 10px;
    border-left: 4px solid #0078D7;
    background-color: #f0f8ff;
}

.info-block p {
    margin: 6px 0;
}

/* Issue box */
.issues-box {
    background-color: #fff3cd;
    border-left: 4px solid #ffc107;
    padding: 15px;
    margin: 20px 0;
    border-radius: 4px;
}

.issues-box h3 {
    margin-top: 0;
    color: #856404;
}

/* Section styles */
.section {
    margin: 30px 0;
    padding: 20px;
    background-color: #fafafa;
    border-radius: 6px;
}

pre {
    background-color: #f4f4f4;
    padding: 12px;
    border-radius: 4px;
    overflow-x: auto;
    font-family: 'Courier New', monospace;
    font-size: 13px;
}

/* Footer */
.footer {
    margin-top: 40px;
    padding-top: 20px;
    border-top: 1px solid #ddd;
    text-align: center;
    color: #666;
    font-size: 13px;
}

/* Links */
a {
    color: #0078D7;
    text-decoration: none;
}

a:hover {
    text-decoration: underline;
}

/* Download links */
.download-links {
    margin: 20px 0;
    padding: 15px;
    background-color: #e7f3ff;
    border-radius: 6px;
}

.download-links a {
    display: inline-block;
    margin: 5px 10px 5px 0;
    padding: 8px 16px;
    background-color: #0078D7;
    color: white;
    border-radius: 4px;
    text-decoration: none;
}

.download-links a:hover {
    background-color: #005a9e;
    text-decoration: none;
}

/* Metadata */
.metadata {
    color: #666;
    font-size: 14px;
    margin: 10px 0;
}
'@

    $cssPath = Join-Path $AssetsPath "style.css"
    $css | Out-File -FilePath $cssPath -Encoding utf8 -Force
    
    # Create app.js with sorting and filtering functionality
    $js = @'
// Simple table sorting and filtering
document.addEventListener('DOMContentLoaded', function() {
    // Add sorting to index table if it exists
    const table = document.querySelector('table');
    if (!table) return;
    
    const headers = table.querySelectorAll('th');
    headers.forEach((header, index) => {
        header.style.cursor = 'pointer';
        header.addEventListener('click', () => sortTable(index));
    });
});

function sortTable(columnIndex) {
    const table = document.querySelector('table');
    const tbody = table.querySelector('tbody') || table;
    const rows = Array.from(tbody.querySelectorAll('tr')).slice(1); // Skip header
    
    const sorted = rows.sort((a, b) => {
        const aText = a.cells[columnIndex]?.textContent.trim() || '';
        const bText = b.cells[columnIndex]?.textContent.trim() || '';
        return aText.localeCompare(bText);
    });
    
    sorted.forEach(row => tbody.appendChild(row));
}

function filterTable(status) {
    const table = document.querySelector('table');
    const rows = table.querySelectorAll('tr');
    
    rows.forEach((row, index) => {
        if (index === 0) return; // Skip header
        
        if (status === 'all') {
            row.style.display = '';
        } else {
            const statusCell = row.cells[1]?.textContent.trim();
            row.style.display = statusCell.includes(status.toUpperCase()) ? '' : 'none';
        }
    });
}
'@

    $jsPath = Join-Path $AssetsPath "app.js"
    $js | Out-File -FilePath $jsPath -Encoding utf8 -Force
}

function Test-MXRecords {
    param([string]$Domain)
    
    $mx = Resolve-MX $Domain
    $details = @()
    $infoMessages = @()
    $status = 'FAIL'
    $reason = ""
    
    if (@($mx).Count -gt 0) {
        $details = $mx | Sort-Object Preference,NameExchange | 
                   ForEach-Object { "$($_.Preference) $($_.NameExchange)" }
        $status = 'PASS'
        $mxList = ($mx | Sort-Object Preference,NameExchange | ForEach-Object { "$($_.Preference) $($_.NameExchange)" }) -join ', '
        $reason = "MX: $mxList"
    } else {
        $details = @("No MX records found via any configured resolver.")
        $infoMessages = @("Info: No MX records is not necessarily an error - domain may only send email (not receive).")
        $status = 'N/A'
        $reason = "MX: N/A (send-only domain)"
    }
    
    return New-CheckResult -Section 'MX Records' -Status $status -Details $details -InfoMessages $infoMessages -Data @{ 
        MXRecords = $mx
        Reason = $reason
    }
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

# Enhanced version that returns detailed lookup breakdown per include
function Get-SpfLookupsDetailed($spf, $checked, $depth = 0) {
  if ($checked -contains $spf) { 
    return @{ Total = 0; Details = @() }
  }
  $checked += $spf
  
  # Count direct lookups (mechanisms that trigger DNS lookups)
  $directCount = 0
  $directCount += ([regex]::Matches($spf, '(?i)include:')).Count
  $directCount += ([regex]::Matches($spf, '(?i)a(?=\s|:|$)')).Count
  $directCount += ([regex]::Matches($spf, '(?i)mx(?=\s|:|$)')).Count
  $directCount += ([regex]::Matches($spf, '(?i)ptr(?=\s|:|$)')).Count
  $directCount += ([regex]::Matches($spf, '(?i)exists:')).Count
  $directCount += ([regex]::Matches($spf, '(?i)redirect=')).Count
  
  $totalCount = $directCount
  $details = @()
  
  # Recursive check for includes
  foreach ($inc in ([regex]::Matches($spf, '(?i)include:([^\s]+)'))) {
    $incDom = $inc.Groups[1].Value
    $incSpf = Resolve-SPF $incDom
    if ($incSpf) {
      $incResult = Get-SpfLookupsDetailed $incSpf $checked ($depth + 1)
      $incTotal = 1 + $incResult.Total  # 1 for the include itself + recursive lookups
      $totalCount += $incResult.Total
      
      $details += [PSCustomObject]@{
        Include = $incDom
        Lookups = $incTotal
        Depth = $depth
      }
      
      # Add nested details
      $details += $incResult.Details
    }
  }
  
  # Recursive check for redirects
  foreach ($red in ([regex]::Matches($spf, '(?i)redirect=([^\s]+)'))) {
    $redDom = $red.Groups[1].Value
    $redSpf = Resolve-SPF $redDom
    if ($redSpf) {
      $redResult = Get-SpfLookupsDetailed $redSpf $checked ($depth + 1)
      $redTotal = 1 + $redResult.Total
      $totalCount += $redResult.Total
      
      $details += [PSCustomObject]@{
        Include = "redirect=$redDom"
        Lookups = $redTotal
        Depth = $depth
      }
      
      $details += $redResult.Details
    }
  }
  
  return @{
    Total = $totalCount
    Details = $details
  }
}

function Test-SPFRecords {
    param([string]$Domain)
    
    $spfRecs = Resolve-SPF $Domain
    $details = @()
    $warnings = @()
    $infoMessages = @()
    $status = 'FAIL'
    $spfHealthy = $true
    $reason = ""
    
    if (@($spfRecs).Count -gt 0) {
        # Check for multi-SPF (strict profile: FAIL)
        if (@($spfRecs).Count -gt 1) {
            $warnings += "Warning: Multiple SPF records found - this violates RFC and causes unpredictable behavior."
            $spfHealthy = $false
            $status = 'FAIL'
            $reason = "SPF: multiple records (RFC violation)"
        }
        
        $i = 1
        $hasPtr = $false
        $hasSoftFail = $false
        $maxLookups = 0
        
        foreach ($rec in $spfRecs) {
            $details += "SPF #$i`: $rec"
            
            # Check for ptr (strict profile: WARN)
            if ($rec -match '(?i)\bptr\b') {
                $hasPtr = $true
            }
            
            # Check for soft fail (strict profile: WARN)
            if ($rec -match '(?i)~all\b') {
                $hasSoftFail = $true
            }
            
            # Count DNS lookups with detailed breakdown
            $lookupResult = Get-SpfLookupsDetailed $rec @()
            $lookupCount = $lookupResult.Total
            
            # Determine status based on lookup count
            if ($lookupCount -gt 10) {
                $warnings += "Warning: DNS lookups (SPF): $lookupCount (exceeds RFC limit of 10)"
                $spfHealthy = $false
                $status = 'FAIL'
            } elseif ($lookupCount -eq 10) {
                $warnings += "Warning: DNS lookups (SPF): $lookupCount (at RFC limit - any change will break SPF)"
                if ($status -ne 'FAIL') { $status = 'WARN' }
            } elseif ($lookupCount -eq 9) {
                $warnings += "Warning: DNS lookups (SPF): $lookupCount (near RFC limit - only 1 lookup remaining)"
                if ($status -ne 'FAIL') { $status = 'WARN' }
            } else {
                $infoMessages += "Info: DNS lookups (SPF): $lookupCount (RFC limit: 10, remaining: $(10 - $lookupCount))"
            }
            
            # Show breakdown including direct lookups and includes
            $details += ""
            $details += "SPF Lookup Breakdown (recursive):"
            
            # Count direct lookups (mechanisms in the main SPF record)
            $directLookups = 0
            $directLookups += ([regex]::Matches($rec, '(?i)\ba(?=\s|:|$)')).Count
            $directLookups += ([regex]::Matches($rec, '(?i)\bmx(?=\s|:|$)')).Count
            $directLookups += ([regex]::Matches($rec, '(?i)\bptr(?=\s|:|$)')).Count
            $directLookups += ([regex]::Matches($rec, '(?i)\bexists:')).Count
            
            if ($directLookups -gt 0) {
                $details += "  - Direct mechanisms (mx, a, ptr, exists): $directLookups lookup(s)"
            }
            
            # Show include/redirect breakdown
            $topLevelIncludes = @($lookupResult.Details | Where-Object { $_.Depth -eq 0 })
            foreach ($inc in $topLevelIncludes) {
                $details += "  - $($inc.Include): $($inc.Lookups) lookup(s)"
                if ($inc.Lookups -gt 5) {
                    $infoMessages += "Info: SPF include '$($inc.Include)' uses $($inc.Lookups) DNS lookups (consider optimizing)"
                }
            }
            
            if ($directLookups + $topLevelIncludes.Count -gt 0) {
                $details += "  TOTAL: $lookupCount lookup(s)"
            }
            
            if ($lookupCount -gt $maxLookups) { $maxLookups = $lookupCount }
            
            $i++
        }
        
        # Add warnings for ptr and soft fail (always show these if present)
        if ($hasPtr) {
            $warnings += "Warning: SPF uses ptr mechanism, which is deprecated and inefficient."
        }
        if ($hasSoftFail) {
            $warnings += "Warning: SPF uses soft fail (~all). Consider using -all (hard fail) for production."
        }
        
        # Determine status and reason based on findings (only if not already set to FAIL from multi-SPF)
        if (-not $reason) {
            if ($maxLookups -gt 10) {
                $status = 'FAIL'
                $spfHealthy = $false
                # Build reason with additional issues
                $reasonParts = @(">10 lookups ($maxLookups)")
                if ($hasSoftFail) { $reasonParts += "~all" }
                if ($hasPtr) { $reasonParts += "ptr" }
                $reason = "SPF: " + ($reasonParts -join ", ")
            } elseif ($maxLookups -ge 9 -or $hasPtr -or $hasSoftFail) {
                # 9-10 lookups OR ptr OR ~all → WARN
                $status = 'WARN'
                $spfHealthy = $false
                $reasonParts = @()
                if ($maxLookups -eq 10) {
                    $reasonParts += "at limit (10 lookups)"
                } elseif ($maxLookups -eq 9) {
                    $reasonParts += "near limit (9 lookups)"
                }
                if ($hasSoftFail) { $reasonParts += "~all (soft fail)" }
                if ($hasPtr) { $reasonParts += "ptr (deprecated)" }
                
                if ($reasonParts.Count -gt 0) {
                    $reason = "SPF: " + ($reasonParts -join ", ")
                } else {
                    $reason = "SPF: valid ($maxLookups lookups)"
                }
            } else {
                $status = 'PASS'
                $reason = "SPF: valid ($maxLookups lookups)"
                $spfHealthy = $true
            }
        }
    } else {
        $details = @("No SPF (v=spf1) record found at $Domain")
        $spfHealthy = $false
        $status = 'FAIL'
        $reason = "SPF: missing"
    }
    
    return New-CheckResult -Section 'SPF' -Status $status -Details $details -Warnings $warnings -InfoMessages $infoMessages -Data @{ 
        SPFRecords = $spfRecs
        Healthy = $spfHealthy
        Reason = $reason
    }
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
        return New-CheckResult -Section 'DKIM' -Status 'N/A' -InfoMessages $infoMessages -Data @{ Reason = "DKIM: N/A (no mail flow)" }
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

    $reason = ""
    if ($anyValid) {
        $infoMessages += "DKIM validation successful - at least one valid selector found with proper public key."
        $status = 'PASS'
        $validSelectorNames = ($validSelectors | ForEach-Object { $_.Selector }) -join ', '
        $reason = "DKIM: valid selectors ($validSelectorNames)"
    } else {
        $warnings += "DKIM validation failed - no valid selectors found with proper public keys."
        $status = 'FAIL'
        $reason = "DKIM: no valid selectors"
    }
    
    return New-CheckResult -Section 'DKIM' -Status $status -Details $details -Warnings $warnings -InfoMessages $infoMessages -Data @{ 
        DKIMResults = $dkimResults
        AnyValid = $anyValid
        Reason = $reason
    }
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
    $reason = ""
    
    if (-not $HasMX) {
        $infoMessages += "Not applicable - domain cannot receive email"
        return New-CheckResult -Section 'MTA-STS' -Status 'N/A' -InfoMessages $infoMessages -Data @{ Reason = "N/A: no MX records" }
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
                '^(?i)enforce$' { 
                    $MtaStsEnforced = $true
                    $MtaStsModeTesting = $false
                    $status = 'PASS'
                    $reason = "MTA-STS: mode=enforce"
                    $infoMessages += "MTA-STS is properly enforced (mode=enforce)."
                    break 
                }
                '^(?i)testing$' { 
                    $MtaStsEnforced = $false
                    $MtaStsModeTesting = $true
                    $status = 'WARN'
                    $reason = "MTA-STS: mode=testing"
                    $warnings += "Warning: MTA-STS is in testing mode (mode=testing). Switch to mode=enforce for full protection."
                    break 
                }
                default { 
                    $MtaStsEnforced = $false
                    $MtaStsModeTesting = $false
                    $status = 'FAIL'
                    $reason = "MTA-STS: invalid or missing mode"
                    break 
                }
            }
        } else {
            $details += "Could not fetch HTTPS policy at $mtaStsUrl"
            $status = 'FAIL'
            $reason = "MTA-STS: DNS record exists but policy unreachable"
        }
    } else {
        $details += "No _mta-sts TXT record found."
        $status = 'FAIL'
        $reason = "MTA-STS: missing (required for domains with MX)"
    }
    
    return New-CheckResult -Section 'MTA-STS' -Status $status -Details $details -Warnings $warnings -InfoMessages $infoMessages -Data @{ 
        MtaStsTxt = $mtaStsTxt
        MtaStsBody = $mtaStsBody
        MtaStsUrl = $mtaStsUrlVal
        MtaStsModeTesting = $MtaStsModeTesting
        MtaStsEnforced = $MtaStsEnforced
        Reason = $reason
    }
}

function Test-DMARC {
    param([string]$Domain)

    $details = @()
    $warnings = @()
    $infoMessages = @()
    $status = 'FAIL'
    $reason = ""

    $dmarcHost = "_dmarc.$Domain"
    
    # Check if _dmarc uses CNAME (not best practice)
    $hasCname = $false
    $cnameTarget = $null
    try {
        if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
            $dnsCheck = Resolve-DnsName -Name $dmarcHost -ErrorAction SilentlyContinue
            $cnameRec = $dnsCheck | Where-Object { $_.Type -eq 'CNAME' } | Select-Object -First 1
            if ($cnameRec) {
                $hasCname = $true
                $cnameTarget = $cnameRec.NameHost
            }
        }
    } catch { }
    
    if ($hasCname) {
        $infoMessages += "Info: _dmarc.$Domain uses CNAME to $cnameTarget (not recommended - direct TXT records are preferred)."
    }
    
    # Get all TXT records separately to check for multiple DMARC records
    $allDmarcRecords = @(Resolve-TxtAll $dmarcHost | Where-Object { $_ -match '(?i)v=DMARC1' })
    
    # Check for multiple DMARC records (RFC violation)
    if ($allDmarcRecords.Count -gt 1) {
        $warnings += "Warning: Multiple DMARC records detected (RFC violation) - behavior is undefined!"
        $status = 'FAIL'
        $reason = "DMARC: multiple records (RFC violation)"
        $details += "Multiple DMARC records found ($($allDmarcRecords.Count)):"
        foreach ($rec in $allDmarcRecords) {
            $details += "  - $rec"
        }
    }
    
    # Use the joined version for parsing (first DMARC record if multiple)
    $dmarcTxt = if ($allDmarcRecords.Count -gt 0) { $allDmarcRecords[0] } else { Resolve-Txt $dmarcHost }
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
        
        # Parse rua/ruf addresses (can be comma-separated)
        if ($dmarcMap.ContainsKey('rua')) {
            $ruaAddresses = $dmarcMap['rua'] -split ',' | ForEach-Object { $_.Trim() }
            $details += "- rua addresses: $($ruaAddresses.Count)"
            foreach ($addr in $ruaAddresses) {
                if ($addr -match '^mailto:') {
                    $details += "  * $addr"
                } else {
                    $details += "  * $addr (⚠️ not mailto:)"
                    $warnings += "Warning: DMARC rua address '$addr' does not use mailto: URI"
                }
            }
        }
        if ($dmarcMap.ContainsKey('ruf')) {
            $rufAddresses = $dmarcMap['ruf'] -split ',' | ForEach-Object { $_.Trim() }
            $details += "- ruf addresses: $($rufAddresses.Count)"
            foreach ($addr in $rufAddresses) {
                if ($addr -match '^mailto:') {
                    $details += "  * $addr"
                } else {
                    $details += "  * $addr (⚠️ not mailto:)"
                    $warnings += "Warning: DMARC ruf address '$addr' does not use mailto: URI"
                }
            }
        }
        
        # Build reason string
        $reasonParts = @()
        if ($pVal) { $reasonParts += "p=$pVal" }
        if ($dmarcMap.ContainsKey('pct')) { $reasonParts += "pct=$($dmarcMap['pct'])" }
        if ($dmarcMap.ContainsKey('sp')) { $reasonParts += "sp=$($dmarcMap['sp'])" } else { $reasonParts += "sp=missing" }
        if ($dmarcMap.ContainsKey('adkim')) { $reasonParts += "adkim=$($dmarcMap['adkim'])" } else { $reasonParts += "adkim=r" }
        if ($dmarcMap.ContainsKey('aspf')) { $reasonParts += "aspf=$($dmarcMap['aspf'])" } else { $reasonParts += "aspf=r" }
        if ($dmarcMap.ContainsKey('rua')) { $reasonParts += "rua=ok" } else { $reasonParts += "rua=missing" }
        $reason = "DMARC: " + ($reasonParts -join "; ")
        
        # Check for additional warnings (shown in reason but don't change severity if p=reject)
        if ($dmarcMap.ContainsKey('pct') -and [int]$dmarcMap['pct'] -lt 100) {
            $warnings += "Warning: DMARC pct<100 - not all messages are subject to policy."
        }
        if (-not $dmarcMap.ContainsKey('sp')) {
            $infoMessages += "Info: DMARC sp (subdomain policy) not set - subdomains will inherit main policy."
        }
        if (-not $dmarcMap.ContainsKey('rua') -and -not $dmarcMap.ContainsKey('ruf')) {
            $warnings += "Warning: DMARC has no reporting addresses (rua/ruf)."
        }
        if (-not $dmarcMap.ContainsKey('adkim') -or $dmarcMap['adkim'] -match '(?i)^r') {
            $infoMessages += "Info: DMARC adkim=relaxed (default) - consider strict mode for better security."
        }
        if (-not $dmarcMap.ContainsKey('aspf') -or $dmarcMap['aspf'] -match '(?i)^r') {
            $infoMessages += "Info: DMARC aspf=relaxed (default) - consider strict mode for better security."
        }
        
        # Strict profile: p=reject → PASS, p=quarantine → WARN, p=none → WARN, missing/other → FAIL
        if ($pVal -and $pVal -match '(?i)^reject$') {
            $status = 'PASS'
            $infoMessages += "DMARC policy is enforced (p=reject)."
        } elseif ($pVal -and $pVal -match '(?i)^quarantine$') {
            $status = 'WARN'
            $warnings += "Warning: DMARC p=quarantine is not fully enforced. Upgrade to p=reject for strict protection."
        } elseif ($pVal -and $pVal -match '(?i)^none$') {
            $status = 'WARN'
            $warnings += "Warning: DMARC is in monitoring mode only (p=none). Upgrade to p=reject for enforcement."
        } else {
            $status = 'FAIL'
        }
    } else {
        $details += "No DMARC record found at _dmarc.$Domain"
        $reason = "DMARC: missing"
        $status = 'FAIL'
    }

    return New-CheckResult -Section 'DMARC' -Status $status -Details $details -Warnings $warnings -InfoMessages $infoMessages -Data @{ 
        DmarcMap = $dmarcMap
        DmarcTxt = $dmarcTxt
        Enforced = ($pVal -match '(?i)^reject$')
        Reason = $reason
    }
}

function Test-TLSReport {
    param([string]$Domain, [bool]$HasMX)

    $details = @()
    $warnings = @()
    $infoMessages = @()
    $status = 'FAIL'
    $reason = ""

    if (-not $HasMX) {
        $infoMessages += "Not applicable - domain cannot receive email"
        return New-CheckResult -Section 'SMTP TLS Reporting (TLS-RPT)' -Status 'N/A' -InfoMessages $infoMessages -Data @{ Reason = "N/A: no MX records" }
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
        $status = 'PASS'
        $reason = "TLS-RPT: configured"
        $infoMessages += "TLS-RPT is configured for encryption monitoring."
    } else {
        $details += "No TLS-RPT record found (recommended for encryption monitoring)."
        $status = 'WARN'
        $reason = "TLS-RPT: missing"
        $warnings += "Warning: TLS-RPT not configured. Recommended for monitoring TLS encryption issues."
    }

    return New-CheckResult -Section 'SMTP TLS Reporting (TLS-RPT)' -Status $status -Details $details -Warnings $warnings -InfoMessages $infoMessages -Data @{ 
        TlsRptTxt = $tlsRptTxt
        Reason = $reason
    }
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
        'PASS' { 'Green' }
        'OK'   { 'Green' }  # Legacy support
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
        'PASS' { 'status-ok'; $icon = '&#x2705; ' }    # ✅
        'OK'   { 'status-ok'; $icon = '&#x2705; ' }    # ✅ (Legacy)
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

function Write-StatusLine {
  param([string]$Label, $Status, $Details = "")
  
  # Map status to color
  $color = switch ($Status) {
    'PASS' { 'Green' }
    'OK'   { 'Green' }  # Legacy support
    'WARN' { 'Yellow' }
    'FAIL' { 'Red' }
    'N/A'  { 'Cyan' }
    default { 'White' }
  }
  
  # Map status to display text (OK is legacy, normalize to PASS)
  $statusText = switch ($Status) {
    'OK'   { 'PASS' }
    'PASS' { 'PASS' }
    default { $Status }
  }
  
  Write-Host ("- {0}: " -f $Label) -NoNewline
  Write-Host $statusText -ForegroundColor $color
  
  # Show details if provided (e.g., MX records)
  if ($Details) {
    Write-Host ("  {0}" -f $Details) -ForegroundColor Gray
  }
}

# Build resolver list
$Resolvers = @()
if ($DnsServer) { $Resolvers += $DnsServer }
$Resolvers += @('8.8.8.8','1.1.1.1')
$Resolvers = $Resolvers | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique

function Resolve-TxtAll {
  param([string]$Name)

  foreach ($srv in $Resolvers) {
    try {
      if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        $ans = Resolve-DnsName -Name $Name -Type TXT -Server $srv -ErrorAction Stop
        $txtRecs = $ans | Where-Object { $_.Type -eq 'TXT' -and $_.PSObject.Properties['Strings'] }

        $strings = @(foreach ($rec in $txtRecs) { ($rec.Strings -join '') })
        if ($strings.Count -gt 0) { return $strings }

        # Follow any CNAME to the target and query TXT there
        $cname = ($ans | Where-Object { $_.Type -eq 'CNAME' } | Select-Object -First 1 -ExpandProperty NameHost -ErrorAction SilentlyContinue)
        if ($cname) {
          $ans2 = Resolve-DnsName -Name $cname -Type TXT -Server $srv -ErrorAction Stop
          $txtRecs2 = $ans2 | Where-Object { $_.Type -eq 'TXT' -and $_.PSObject.Properties['Strings'] }
          $strings2 = @(foreach ($rec in $txtRecs2) { ($rec.Strings -join '') })
          if ($strings2.Count -gt 0) { return $strings2 }
        }
      }
      else {
        # Fallback: nslookup - harder to separate multiple records, return as single-item array
        $out = nslookup -type=txt $Name $srv 2>$null
        $txt = ($out | Select-String -Pattern '"([^"]*)"' -AllMatches).Matches.Value -replace '"',''
        $joined = ($txt -join '')
        if ($joined) { return @($joined) }
      }
    } catch { }
  }
  return @()
}

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

function Write-DomainReportPage {
  param(
    [string]$OutputPath,
    [string]$Domain,
    [pscustomobject]$Summary,
    $mxResult,
    $spfResult,
    $dkimResult,
    $mtaStsResult,
    $dmarcResult,
    $tlsResult
  )
  
  # Sanitize domain name for filename
  $safeDomain = $Domain -replace '[^a-z0-9.-]', '_'
  $domainPath = Join-Path $OutputPath "$safeDomain.html"
  
  $now = (Get-Date).ToString('u')
  
  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Mail Security Report - $([System.Web.HttpUtility]::HtmlEncode($Domain))</title>
    <link rel="stylesheet" href="../assets/style.css">
</head>
<body>
<div class="container">
    <a href="../index.html" class="nav-link">&#8592; Back to Summary</a>
    
    <h1>Mail Security Report</h1>
    <p class="metadata"><strong>Domain:</strong> $([System.Web.HttpUtility]::HtmlEncode($Domain))</p>
    <p class="metadata"><strong>Generated:</strong> $now</p>
"@

  # Issues box - collect all warnings and failures
  $issues = @()
  foreach ($result in @($mxResult, $spfResult, $dkimResult, $mtaStsResult, $dmarcResult, $tlsResult)) {
    if ($result.Status -eq 'FAIL' -or $result.Status -eq 'WARN') {
      $issues += "$($result.Section): $($result.Data.Reason)"
    }
  }
  
  if ($issues.Count -gt 0) {
    $html += @"
    <div class="issues-box">
        <h3>&#9888;&#65039; Issues Found</h3>
        <ul>
$(($issues | ForEach-Object { "            <li>$([System.Web.HttpUtility]::HtmlEncode($_))</li>" }) -join "`n")
        </ul>
    </div>
"@
  } else {
    $html += @"
    <div style="background-color: #d4edda; border-left: 4px solid #28a745; padding: 15px; margin: 20px 0; border-radius: 4px;">
        <h3 style="color: #155724; margin-top: 0;">&#9989; All Checks Passed</h3>
        <p style="color: #155724; margin-bottom: 0;">No issues detected in the email security configuration.</p>
    </div>
"@
  }

  # Summary table
  $html += "<h2>Summary</h2>"
  $html += "<table><tr><th style='width: 200px;'>Check</th><th style='width: 120px;'>Status</th><th>Details</th></tr>"
  
  # Helper to render status cell
  $renderStatusCell = {
    param($status)
    $cls = switch ($status) {
      'PASS' { 'status-ok' }
      'OK' { 'status-ok' }
      'WARN' { 'status-warn' }
      'FAIL' { 'status-fail' }
      'N/A' { 'status-info' }
      default { '' }
    }
    $icon = switch ($status) {
      'PASS' { '&#x2705; ' }
      'OK' { '&#x2705; ' }
      'WARN' { '&#x26A0;&#xFE0F; ' }
      'FAIL' { '&#x274C; ' }
      'N/A' { '&#x2139;&#xFE0F; ' }
      default { '' }
    }
    $text = switch ($status) {
      'OK' { 'PASS' }
      default { $status }
    }
    return "<td class='$cls'>$icon$text</td>"
  }
  
  # MX Records
  if ($mxResult.Status -eq 'PASS' -or $mxResult.Status -eq 'OK') {
    $mxRecords = ($mxResult.Data.MXRecords | Sort-Object Preference,NameExchange | ForEach-Object { [System.Web.HttpUtility]::HtmlEncode("$($_.Preference) $($_.NameExchange)") }) -join '<br>'
    $html += "<tr><td>MX Records</td><td class='status-ok' colspan='2'>$mxRecords</td></tr>"
  } else {
    $html += "<tr><td>MX Records</td>" + (& $renderStatusCell $mxResult.Status) + "<td style='font-size: 12px;'>$([System.Web.HttpUtility]::HtmlEncode($mxResult.Data.Reason))</td></tr>"
  }
  
  $html += "<tr><td>SPF</td>" + (& $renderStatusCell $spfResult.Status) + "<td style='font-size: 12px;'>$([System.Web.HttpUtility]::HtmlEncode($spfResult.Data.Reason))</td></tr>"
  $html += "<tr><td>DKIM</td>" + (& $renderStatusCell $dkimResult.Status) + "<td style='font-size: 12px;'>$([System.Web.HttpUtility]::HtmlEncode($dkimResult.Data.Reason))</td></tr>"
  $html += "<tr><td>DMARC</td>" + (& $renderStatusCell $dmarcResult.Status) + "<td style='font-size: 12px;'>$([System.Web.HttpUtility]::HtmlEncode($dmarcResult.Data.Reason))</td></tr>"
  $html += "<tr><td>MTA-STS</td>" + (& $renderStatusCell $mtaStsResult.Status) + "<td style='font-size: 12px;'>$([System.Web.HttpUtility]::HtmlEncode($mtaStsResult.Data.Reason))</td></tr>"
  $html += "<tr><td>TLS-RPT</td>" + (& $renderStatusCell $tlsResult.Status) + "<td style='font-size: 12px;'>$([System.Web.HttpUtility]::HtmlEncode($tlsResult.Data.Reason))</td></tr>"
  
  $html += "</table>"

  # Detailed sections (reuse existing ConvertTo-HtmlSection)
  $html += ConvertTo-HtmlSection $mxResult
  $html += ConvertTo-HtmlSection $spfResult
  $html += ConvertTo-HtmlSection $dkimResult
  $html += ConvertTo-HtmlSection $dmarcResult
  $html += ConvertTo-HtmlSection $mtaStsResult
  $html += ConvertTo-HtmlSection $tlsResult

  # Footer
  $html += @"
    <div class="footer">
        <p>Generated by <strong>mailchecker.ps1</strong> on $now</p>
        <p><a href="../index.html">&#8592; Back to Summary</a></p>
    </div>
</div>
<script src="../assets/app.js"></script>
</body>
</html>
"@

  try {
    $html | Out-File -FilePath $domainPath -Encoding utf8 -Force
  } catch {
    Write-Host ("Failed to write domain report for {0}: {1}" -f $Domain, $_) -ForegroundColor Red
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

  $html += "<h2>Summary</h2>"
  $html += "<p>Tested domain: <strong>$([System.Web.HttpUtility]::HtmlEncode($Summary.Domain))</strong></p>"
  
  # Overall status
  $statusClass = switch ($Summary.Status) {
    'PASS' { 'status-ok' }
    'WARN' { 'status-warn' }
    'FAIL' { 'status-fail' }
    default { '' }
  }
  $statusIcon = switch ($Summary.Status) {
    'PASS' { '&#x2705; ' }
    'WARN' { '&#x26A0;&#xFE0F; ' }
    'FAIL' { '&#x274C; ' }
    default { '' }
  }
  $html += "<p style='font-weight: 600; font-size: 16px;' class='$statusClass'>Overall Status: $statusIcon$([System.Web.HttpUtility]::HtmlEncode($Summary.Status))</p>"
  
  # Individual check statuses
  $html += "<table style='width: 480px; table-layout: fixed;'><tr><th style='width: 180px;'>Check</th><th style='width: 100px;'>Status</th><th style='width: 200px;'>Notes</th></tr>"
  
  # Helper to render status
  $renderStatus = {
    param($status)
    $cls = switch ($status) {
      'PASS' { 'status-ok' }
      'OK' { 'status-ok' }  # Legacy support
      'WARN' { 'status-warn' }
      'FAIL' { 'status-fail' }
      'N/A' { 'status-info' }
      default { '' }
    }
    $icon = switch ($status) {
      'PASS' { '&#x2705; ' }
      'OK' { '&#x2705; ' }  # Legacy support
      'WARN' { '&#x26A0;&#xFE0F; ' }
      'FAIL' { '&#x274C; ' }
      'N/A' { '&#x2139;&#xFE0F; ' }
      default { '' }
    }
    $text = switch ($status) {
      'OK' { 'PASS' }  # Normalize OK to PASS
      default { $status }
    }
    return "<td class='$cls'>$icon$text</td>"
  }
  
  # Add rows for each check
  # MX Records - show actual records instead of just status
  if ($mxResult.Status -eq 'PASS' -or $mxResult.Status -eq 'OK') {
    $mxRecords = ($mxResult.Data.MXRecords | Sort-Object Preference,NameExchange | ForEach-Object { [System.Web.HttpUtility]::HtmlEncode("$($_.Preference) $($_.NameExchange)") }) -join '<br>'
    $html += "<tr><td>MX Records</td><td class='status-ok' colspan='2'>$mxRecords</td></tr>"
  } else {
    $html += "<tr><td>MX Records</td>" + (& $renderStatus $mxResult.Status) + "<td style='font-size: 11px;'>$([System.Web.HttpUtility]::HtmlEncode($mxResult.Data.Reason))</td></tr>"
  }
  
  $html += "<tr><td>SPF</td>" + (& $renderStatus $spfResult.Status) + "<td style='font-size: 11px;'>$([System.Web.HttpUtility]::HtmlEncode($spfResult.Data.Reason))</td></tr>"
  $html += "<tr><td>DKIM</td>" + (& $renderStatus $dkimResult.Status) + "<td style='font-size: 11px;'>$([System.Web.HttpUtility]::HtmlEncode($dkimResult.Data.Reason))</td></tr>"
  $html += "<tr><td>MTA-STS</td>" + (& $renderStatus $mtaStsResult.Status) + "<td style='font-size: 11px;'>$([System.Web.HttpUtility]::HtmlEncode($mtaStsResult.Data.Reason))</td></tr>"
  $html += "<tr><td>DMARC</td>" + (& $renderStatus $dmarcResult.Status) + "<td style='font-size: 11px;'>$([System.Web.HttpUtility]::HtmlEncode($dmarcResult.Data.Reason))</td></tr>"
  $html += "<tr><td>TLS-RPT</td>" + (& $renderStatus $tlsResult.Status) + "<td style='font-size: 11px;'>$([System.Web.HttpUtility]::HtmlEncode($tlsResult.Data.Reason))</td></tr>"
  
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

function Write-IndexPage {
  param(
    [string]$RootPath,
    [array]$AllResults,
    [string]$CsvFileName = $null,
    [string]$JsonFileName = $null
  )
  
  $indexPath = Join-Path $RootPath "index.html"
  $now = (Get-Date).ToString('u')
  $totalDomains = $AllResults.Count
  
  # Calculate statistics - domain level (based on overall status)
  $passResults = @($AllResults | Where-Object { $_.Summary.Status -eq 'PASS' })
  $warnResults = @($AllResults | Where-Object { $_.Summary.Status -eq 'WARN' })
  $failResults = @($AllResults | Where-Object { $_.Summary.Status -eq 'FAIL' })
  
  $passCount = $passResults.Count
  $warnCount = $warnResults.Count
  $failCount = $failResults.Count
  
  # Count status per check type
  $mxPass = @($AllResults | Where-Object { $_.MXResult.Status -eq 'PASS' -or $_.MXResult.Status -eq 'OK' }).Count
  $spfPass = @($AllResults | Where-Object { $_.SPFResult.Status -eq 'PASS' }).Count
  $dkimPass = @($AllResults | Where-Object { $_.DKIMResult.Status -eq 'PASS' }).Count
  $mtaStsPass = @($AllResults | Where-Object { $_.MTAStsResult.Status -eq 'PASS' }).Count
  $dmarcPass = @($AllResults | Where-Object { $_.DMARCResult.Status -eq 'PASS' }).Count
  $tlsPass = @($AllResults | Where-Object { $_.TLSResult.Status -eq 'PASS' }).Count

  $html = @"
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Mail Security Check - Summary Report</title>
    <link rel="stylesheet" href="assets/style.css">
  </head>
  <body>
<div class="container">
    <h1>&#128231; Mail Security Check - Summary Report</h1>
    <p class="metadata"><strong>Generated:</strong> $now</p>
    <p class="metadata"><strong>Total Domains Checked:</strong> $totalDomains</p>
    
    <div class="summary-stats">
        <h2>Domain Overview</h2>
        <div class="stats-grid">
            <div class="stat-card">
                <div>Total Domains</div>
                <div class="stat-number">$totalDomains</div>
  </div>
            <div class="stat-card">
                <div>&#9989; Fully Compliant</div>
                <div class="stat-number">$passCount</div>
                <div style="font-size: 12px; margin-top: 5px;">All checks passed</div>
            </div>
            <div class="stat-card">
                <div>&#9888;&#65039; Needs Improvement</div>
                <div class="stat-number">$warnCount</div>
                <div style="font-size: 12px; margin-top: 5px;">Has warnings</div>
            </div>
            <div class="stat-card">
                <div>&#10060; Critical Issues</div>
                <div class="stat-number">$failCount</div>
                <div style="font-size: 12px; margin-top: 5px;">Has failures</div>
            </div>
        </div>
        <h3 style="margin-top: 20px;">Individual Check Summary</h3>
        <p style="font-size: 14px;">&#9989; MX Records: $mxPass/$totalDomains | SPF: $spfPass/$totalDomains | DKIM: $dkimPass/$totalDomains</p>
        <p style="font-size: 14px;">&#9989; DMARC: $dmarcPass/$totalDomains | MTA-STS: $mtaStsPass/$totalDomains | TLS-RPT: $tlsPass/$totalDomains</p>
    </div>
"@

  # Download links if CSV or JSON available
  if ($CsvFileName -or $JsonFileName) {
    $html += "    <div class='download-links'>`n"
    $html += "        <strong>Download:</strong>`n"
    if ($CsvFileName) {
      $encodedCsvName = [System.Web.HttpUtility]::HtmlEncode($CsvFileName)
      $html += "        <a href='" + $encodedCsvName + "'>&#128202; CSV Report</a>`n"
    }
    if ($JsonFileName) {
      $encodedJsonName = [System.Web.HttpUtility]::HtmlEncode($JsonFileName)
      $html += "        <a href='" + $encodedJsonName + "'>&#128196; JSON Export</a>`n"
    }
    $html += "    </div>`n"
  }

  $html += @"
  <h2>Detailed Results</h2>
  <table>
        <thead>
            <tr>
                <th style="width: 200px;">Domain</th>
                <th style="width: 200px;">MX Records</th>
                <th style="width: 90px;">Status</th>
                <th style="width: 70px;">SPF</th>
                <th style="width: 70px;">DKIM</th>
                <th style="width: 90px;">DMARC</th>
                <th style="width: 90px;">MTA-STS</th>
                <th style="width: 90px;">TLS-RPT</th>
                <th>Issues</th>
    </tr>
        </thead>
        <tbody>
"@

  # Helper to render status badge - build strings without nested expansion
  function Get-StatusBadgeHtml {
    param([string]$status)
    
    $cls = 'status-info'
    $icon = '&#x2139;&#xFE0F;'
    $text = $status
    
    if ($status -eq 'PASS' -or $status -eq 'OK') {
      $cls = 'status-ok'
      $icon = '&#9989;'
      $text = 'PASS'
    } elseif ($status -eq 'WARN') {
      $cls = 'status-warn'
      $icon = '&#9888;&#65039;'
      $text = 'WARN'
    } elseif ($status -eq 'FAIL') {
      $cls = 'status-fail'
      $icon = '&#10060;'
      $text = 'FAIL'
    } elseif ($status -eq 'N/A') {
      $cls = 'status-info'
      $icon = '&#8505;&#65039;'
      $text = 'N/A'
    }
    
    return "<span class='" + $cls + "' title='" + $text + "'>" + $icon + "</span>"
  }

  foreach ($result in $AllResults) {
    $domain = $result.Domain
    $safeDomain = $domain -replace '[^a-z0-9.-]', '_'
    $domainLink = "domains/$safeDomain.html"
    $encodedDomain = [System.Web.HttpUtility]::HtmlEncode($domain)
    
    $overallStatus = $result.Summary.Status
    $statusClass = switch ($overallStatus) {
        'PASS' { 'status-ok' }
        'WARN' { 'status-warn' }
        'FAIL' { 'status-fail' }
        default { '' }
      }
    $statusIcon = switch ($overallStatus) {
      'PASS' { '&#9989; ' }
      'WARN' { '&#9888;&#65039; ' }
      'FAIL' { '&#10060; ' }
        default { '' }
      }
    
    # Collect condensed issues with line breaks
    $issues = @()
    if ($result.SPFResult.Status -eq 'FAIL' -or $result.SPFResult.Status -eq 'WARN') {
      $issues += "SPF: " + ($result.SPFResult.Data.Reason -replace '^SPF: ', '')
    }
    if ($result.DKIMResult.Status -eq 'FAIL') {
      $issues += "DKIM: " + ($result.DKIMResult.Data.Reason -replace '^DKIM: ', '')
    }
    if ($result.MTAStsResult.Status -eq 'FAIL' -or $result.MTAStsResult.Status -eq 'WARN') {
      $issues += "MTA-STS: " + ($result.MTAStsResult.Data.Reason -replace '^MTA-STS: ', '')
    }
    if ($result.DMARCResult.Status -eq 'FAIL' -or $result.DMARCResult.Status -eq 'WARN') {
      # Simplify DMARC - only show actual issues, not informational fields
      $dmarcReason = $result.DMARCResult.Data.Reason -replace '^DMARC: ', ''
      # Extract only the problematic parts
      $dmarcIssues = @()
      if ($dmarcReason -match 'p=none') { $dmarcIssues += 'p=none (monitoring only)' }
      elseif ($dmarcReason -match 'p=quarantine') { $dmarcIssues += 'p=quarantine (not fully enforced)' }
      if ($dmarcReason -match 'pct=(\d+)' -and [int]$Matches[1] -lt 100) { $dmarcIssues += "pct=$($Matches[1])" }
      if ($dmarcReason -match 'sp=missing') { $dmarcIssues += 'sp=missing' }
      if ($dmarcReason -match 'rua=missing') { $dmarcIssues += 'rua=missing' }
      
      if ($dmarcIssues.Count -gt 0) {
        $issues += "DMARC: " + ($dmarcIssues -join ', ')
      }
    }
    if ($result.TLSResult.Status -eq 'WARN') {
      $issues += "TLS-RPT: " + ($result.TLSResult.Data.Reason -replace '^TLS-RPT: ', '')
    }
    
    $issuesText = if ($issues.Count -gt 0) { 
      ($issues | ForEach-Object { [System.Web.HttpUtility]::HtmlEncode($_) }) -join '<br>'
    } else {
      '<span style="color: #28a745;">No issues</span>' 
    }
    
    # Get MX records for display
    $mxRecordsText = if ($result.MXResult.Status -eq 'PASS' -or $result.MXResult.Status -eq 'OK') {
      ($result.MXResult.Data.MXRecords | Sort-Object Preference,NameExchange | ForEach-Object { 
        [System.Web.HttpUtility]::HtmlEncode("$($_.Preference) $($_.NameExchange)") 
      }) -join '<br>'
    } elseif ($result.MXResult.Status -eq 'N/A') {
      '<span style="color: #666;">N/A</span>'
    } else {
      '<span style="color: #dc3545;">No MX records</span>'
    }
    
    $encodedDomainLink = [System.Web.HttpUtility]::HtmlAttributeEncode($domainLink)
    
    # Get badge HTML for each status
    $spfBadge = Get-StatusBadgeHtml $result.SPFResult.Status
    $dkimBadge = Get-StatusBadgeHtml $result.DKIMResult.Status
    $mtastsBadge = Get-StatusBadgeHtml $result.MTAStsResult.Status
    $dmarcBadge = Get-StatusBadgeHtml $result.DMARCResult.Status
    $tlsBadge = Get-StatusBadgeHtml $result.TLSResult.Status
    
    $html += "            <tr>`n"
    $html += "                <td class='domain'><a href='" + $encodedDomainLink + "'>" + $encodedDomain + "</a></td>`n"
    $html += "                <td style='font-size: 12px;'>" + $mxRecordsText + "</td>`n"
    $html += "                <td class='" + $statusClass + "'>" + $statusIcon + $overallStatus + "</td>`n"
    $html += "                <td style='text-align: center;'>" + $spfBadge + "</td>`n"
    $html += "                <td style='text-align: center;'>" + $dkimBadge + "</td>`n"
    $html += "                <td style='text-align: center;'>" + $dmarcBadge + "</td>`n"
    $html += "                <td style='text-align: center;'>" + $mtastsBadge + "</td>`n"
    $html += "                <td style='text-align: center;'>" + $tlsBadge + "</td>`n"
    $html += "                <td style='font-size: 12px;'>" + $issuesText + "</td>`n"
    $html += "            </tr>`n"
  }

  $html += @"
        </tbody>
  </table>
  
    <div class="footer">
        <p><strong>Legend:</strong> 
        <span style='color: #28a745;'>&#9989; PASS</span> = Meets security standards | 
        <span style='color: #ffc107;'>&#9888;&#65039; WARN</span> = Needs improvement | 
        <span style='color: #dc3545;'>&#10060; FAIL</span> = Critical issue | 
        <span style='color: #0078D7;'>&#8505;&#65039; N/A</span> = Not applicable
        </p>
        <p>Generated by <strong>mailchecker.ps1</strong> on $now</p>
    </div>
</div>
<script src="assets/app.js"></script>
  </body>
</html>
"@

  try {
    $html | Out-File -FilePath $indexPath -Encoding utf8 -Force
    Write-Host "Wrote index report to: $indexPath" -ForegroundColor Green
  } catch {
    Write-Host ("Failed to write index report: {0}" -f $_) -ForegroundColor Red
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
$DKIM_AnySelector_Valid = $dkimResult.Data.AnyValid
    if (-not $QuietMode) { Write-CheckResult $dkimResult }

# 4) MTA-STS
$mtaStsResult = Test-MTASts -Domain $Domain -HasMX $mxOk
$mtaStsTxt = $mtaStsResult.Data.MtaStsTxt
$MtaStsEnforced = $mtaStsResult.Data.MtaStsEnforced
    if (-not $QuietMode) { Write-CheckResult $mtaStsResult }

# 5) DMARC
$dmarcResult = Test-DMARC -Domain $Domain
$dmarcTxt = $dmarcResult.Data.DmarcTxt
$dmarcEnforced = [bool]$dmarcResult.Data.Enforced
    if (-not $QuietMode) { Write-CheckResult $dmarcResult }

# 6) TLS-RPT
$tlsResult = Test-TLSReport -Domain $Domain -HasMX $mxOk
$tlsRptTxt = $tlsResult.Data.TlsRptTxt
    if (-not $QuietMode) { Write-CheckResult $tlsResult }

# Summary
$hasMXRecords = [bool]$mxOk
$mxRecordsDisplay = if ($hasMXRecords) { 
    ($mx | Sort-Object Preference,NameExchange | ForEach-Object { "$($_.Preference) $($_.NameExchange)" }) -join ', '
} else { 
    "N/A" 
}

# Collect all reasons for detailed explanation
$allReasons = @()
if ($mxResult.Data.Reason) { $allReasons += $mxResult.Data.Reason }
if ($spfResult.Data.Reason) { $allReasons += $spfResult.Data.Reason }
if ($dkimResult.Data.Reason) { $allReasons += $dkimResult.Data.Reason }
if ($mtaStsResult.Data.Reason) { $allReasons += $mtaStsResult.Data.Reason }
if ($dmarcResult.Data.Reason) { $allReasons += $dmarcResult.Data.Reason }
if ($tlsResult.Data.Reason) { $allReasons += $tlsResult.Data.Reason }
$reasonText = $allReasons -join ' | '

# Determine overall status
$overallStatus = "PASS"
if ($mxResult.Status -eq 'FAIL' -or $spfResult.Status -eq 'FAIL' -or $dkimResult.Status -eq 'FAIL' -or 
    $mtaStsResult.Status -eq 'FAIL' -or $dmarcResult.Status -eq 'FAIL' -or $tlsResult.Status -eq 'FAIL') {
    $overallStatus = "FAIL"
} elseif ($mxResult.Status -eq 'WARN' -or $spfResult.Status -eq 'WARN' -or $dkimResult.Status -eq 'WARN' -or 
          $mtaStsResult.Status -eq 'WARN' -or $dmarcResult.Status -eq 'WARN' -or $tlsResult.Status -eq 'WARN') {
    $overallStatus = "WARN"
}

$summary = [pscustomobject]@{
  Domain                 = $Domain
  Status                 = $overallStatus
  Reason                 = $reasonText
  MX_Records_Present     = $mxRecordsDisplay
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

# Overall status
Write-Host "`nOverall Status: " -NoNewline
$statusColor = switch ($summary.Status) {
    'PASS' { 'Green' }
    'WARN' { 'Yellow' }
    'FAIL' { 'Red' }
    default { 'White' }
}
Write-Host $summary.Status -ForegroundColor $statusColor

# Status per check
Write-Host "`nDetailed Status:"
Write-StatusLine "MX Records"   $mxResult.Status    $(if ($mxResult.Status -eq 'PASS' -or $mxResult.Status -eq 'OK') { $mxRecordsDisplay })
Write-StatusLine "SPF"          $spfResult.Status
Write-StatusLine "DKIM"         $dkimResult.Status
Write-StatusLine "MTA-STS"      $mtaStsResult.Status
Write-StatusLine "DMARC"        $dmarcResult.Status
Write-StatusLine "TLS-RPT"      $tlsResult.Status

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
    if (-not (Test-Path $BulkFile)) {
        Write-Host "Error: File not found: $BulkFile" -ForegroundColor Red
        Write-Host "Please check the file path and try again." -ForegroundColor Yellow
        exit 1
    }
    
    # Determine output structure
    $outputStructure = $null
    if ($FullHtmlExport) {
        # Create full structure with assets and domains folders
        $outputStructure = New-OutputStructure -InputFile $BulkFile -OutputPath $OutputPath
        $resolvedOutputPath = $outputStructure.RootPath
        
        # Write assets (CSS and JS)
        Write-AssetsFiles -AssetsPath $outputStructure.AssetsPath
        Write-Host "Created assets (CSS, JS) in: $($outputStructure.AssetsPath)" -ForegroundColor Cyan
    } else {
        # Legacy mode - simple output path
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            $resolvedOutputPath = "."
        } else {
            $resolvedOutputPath = $OutputPath
    }
    
    # Ensure output directory exists
        if (-not (Test-Path $resolvedOutputPath)) {
        try {
                New-Item -ItemType Directory -Path $resolvedOutputPath -Force | Out-Null
                Write-Host "Created output directory: $resolvedOutputPath" -ForegroundColor Cyan
        } catch {
                Write-Host "Error: Could not create output directory: $resolvedOutputPath" -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Red
            exit 1
            }
        }
    }
    
    $rawDomains = @(Get-Content $BulkFile | 
               Where-Object { $_ -and $_.Trim() -and -not $_.Trim().StartsWith('#') } |
               ForEach-Object { $_.Trim().ToLower() })
    
    # Remove duplicates and sort alphabetically
    $domains = @($rawDomains | Select-Object -Unique | Sort-Object)
    
    $duplicateCount = $rawDomains.Count - $domains.Count
    if ($duplicateCount -gt 0) {
        Write-Host "Removed $duplicateCount duplicate domain(s)" -ForegroundColor Yellow
    }
    
    if ($domains.Count -eq 0) {
        Write-Host "Error: No valid domains found in $BulkFile" -ForegroundColor Red
        Write-Host "" -ForegroundColor Yellow
        Write-Host "The file appears to be empty or contains only comments/whitespace." -ForegroundColor Yellow
        Write-Host "" -ForegroundColor Yellow
        Write-Host "Expected format (one domain per line):" -ForegroundColor Cyan
        Write-Host "  example.com" -ForegroundColor Gray
        Write-Host "  test.org" -ForegroundColor Gray
        Write-Host "  # This is a comment" -ForegroundColor Gray
        Write-Host "  another-domain.com" -ForegroundColor Gray
        exit 1
    }
    
    Write-Host "Checking $($domains.Count) domains (Resolvers: $($Resolvers -join ', '))" -ForegroundColor Yellow
    Write-Host ""
    
    $allResults = @()
    $total = $domains.Count
    
    for ($i = 0; $i -lt $total; $i++) {
        Write-Host "Processing domain $($i + 1) of ${total}: $($domains[$i])" -ForegroundColor Yellow -NoNewline
        $result = Invoke-DomainCheck -Domain $domains[$i] -Selectors $Selectors -QuietMode $true
        
        # Show overall status on same line
        $statusColor = switch ($result.Summary.Status) {
            'PASS' { 'Green' }
            'WARN' { 'Yellow' }
            'FAIL' { 'Red' }
            default { 'White' }
        }
        Write-Host " (Overall status: " -NoNewline
        Write-Host $result.Summary.Status -ForegroundColor $statusColor -NoNewline
        Write-Host ")"
        
        $allResults += $result
    }
    
    Write-Host "`nAll domains processed." -ForegroundColor Green
    
    # Track filenames for index page
    $csvFileName = $null
    $jsonFileName = $null
        $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
    
    # Export CSV (always with FullHtmlExport)
    if ($FullHtmlExport) {
        # Create enhanced CSV with individual reason columns
        # Sanitize function to remove tabs, newlines, and other problematic characters
        function Sanitize-CsvField($value) {
            if ($null -eq $value) { return "" }
            # Replace tabs with spaces, remove newlines, replace semicolons with commas, and trim
            return $value.ToString() -replace "`t", " " -replace "`r`n", " " -replace "`n", " " -replace "`r", " " -replace ";", ","
        }
        
        $csvData = $allResults | ForEach-Object {
            [PSCustomObject]@{
                Domain = Sanitize-CsvField $_.Domain
                Status = Sanitize-CsvField $_.Summary.Status
                MX_Records = Sanitize-CsvField $_.Summary.MX_Records_Present
                SPF_Status = Sanitize-CsvField $_.SPFResult.Status
                SPF_Reason = Sanitize-CsvField $_.SPFResult.Data.Reason
                DKIM_Status = Sanitize-CsvField $_.DKIMResult.Status
                DKIM_Reason = Sanitize-CsvField $_.DKIMResult.Data.Reason
                DMARC_Status = Sanitize-CsvField $_.DMARCResult.Status
                DMARC_Reason = Sanitize-CsvField $_.DMARCResult.Data.Reason
                MTA_STS_Status = Sanitize-CsvField $_.MTAStsResult.Status
                MTA_STS_Reason = Sanitize-CsvField $_.MTAStsResult.Data.Reason
                TLS_RPT_Status = Sanitize-CsvField $_.TLSResult.Status
                TLS_RPT_Reason = Sanitize-CsvField $_.TLSResult.Data.Reason
                SPF_Present = Sanitize-CsvField $_.Summary.SPF_Present
                SPF_Healthy = Sanitize-CsvField $_.Summary.SPF_Healthy
                DKIM_ValidSelector = Sanitize-CsvField $_.Summary.DKIM_ValidSelector
                MTA_STS_DNS_Present = Sanitize-CsvField $_.Summary.MTA_STS_DNS_Present
                MTA_STS_Enforced = Sanitize-CsvField $_.Summary.MTA_STS_Enforced
                DMARC_Present = Sanitize-CsvField $_.Summary.DMARC_Present
                DMARC_Enforced = Sanitize-CsvField $_.Summary.DMARC_Enforced
                TLS_RPT_Present = Sanitize-CsvField $_.Summary.TLS_RPT_Present
            }
        }
        $csvFileName = "bulk-results-$ts.csv"
        $csvPath = Join-Path $resolvedOutputPath $csvFileName
        $csvData | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ','
        Write-Host "CSV exported to: $csvPath" -ForegroundColor Green
    }
    
    # Export JSON if requested
    if ($Json) {
        $jsonFileName = "results.json"
        $jsonPath = Join-Path $resolvedOutputPath $jsonFileName
        
        # Convert all results to JSON-friendly format
        $jsonData = @{
            GeneratedDate = (Get-Date).ToString('u')
            TotalDomains = $allResults.Count
            ScriptVersion = "mailchecker.ps1 v2.0"
            Results = @($allResults | ForEach-Object {
                @{
                    Domain = $_.Domain
                    OverallStatus = $_.Summary.Status
                    Checks = @{
                        MX = @{
                            Status = $_.MXResult.Status
                            Reason = $_.MXResult.Data.Reason
                            Records = @($_.MXResult.Data.MXRecords | ForEach-Object { 
                                @{ Preference = $_.Preference; NameExchange = $_.NameExchange } 
                            })
                        }
                        SPF = @{
                            Status = $_.SPFResult.Status
                            Reason = $_.SPFResult.Data.Reason
                            Records = $_.SPFResult.Data.SPFRecords
                            Healthy = $_.SPFResult.Data.Healthy
                        }
                        DKIM = @{
                            Status = $_.DKIMResult.Status
                            Reason = $_.DKIMResult.Data.Reason
                            AnyValid = $_.DKIMResult.Data.AnyValid
                        }
                        MTASTS = @{
                            Status = $_.MTAStsResult.Status
                            Reason = $_.MTAStsResult.Data.Reason
                            Enforced = $_.MTAStsResult.Data.MtaStsEnforced
                        }
                        DMARC = @{
                            Status = $_.DMARCResult.Status
                            Reason = $_.DMARCResult.Data.Reason
                            Enforced = $_.DMARCResult.Data.Enforced
                            Record = $_.DMARCResult.Data.DmarcTxt
                        }
                        TLSRPT = @{
                            Status = $_.TLSResult.Status
                            Reason = $_.TLSResult.Data.Reason
                            Record = $_.TLSResult.Data.TlsRptTxt
                        }
                    }
                }
            })
        }
        
        $jsonData | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding utf8 -Force
        Write-Host "JSON exported to: $jsonPath" -ForegroundColor Green
    }
    
    # FullHtmlExport mode: create index + individual domain pages
    if ($FullHtmlExport) {
        # Generate individual domain pages
        Write-Host "`nGenerating individual domain reports..." -ForegroundColor Yellow
        $domainCount = 0
        foreach ($result in $allResults) {
            Write-DomainReportPage -OutputPath $outputStructure.DomainsPath `
                                 -Domain $result.Domain -Summary $result.Summary `
                           -mxResult $result.MXResult -spfResult $result.SPFResult `
                           -dkimResult $result.DKIMResult -mtaStsResult $result.MTAStsResult `
                           -dmarcResult $result.DMARCResult -tlsResult $result.TLSResult
            $domainCount++
        }
        Write-Host "Generated $domainCount domain reports in: $($outputStructure.DomainsPath)" -ForegroundColor Green
        
        # Generate index page
        Write-IndexPage -RootPath $outputStructure.RootPath -AllResults $allResults `
                        -CsvFileName $csvFileName -JsonFileName $jsonFileName
        
        # Create clickable file link for modern terminals
        $indexPath = Join-Path $outputStructure.RootPath "index.html"
        $indexPathFull = (Resolve-Path $indexPath).Path
        
        # Open report if requested
        if ($OpenReport) {
            try {
                if ($IsWindows -or $PSVersionTable.PSVersion.Major -le 5) {
                    Start-Process $indexPath
                    Write-Host "Opened report in default browser." -ForegroundColor Green
                } elseif ($IsMacOS) {
                    & open $indexPath
                    Write-Host "Opened report in default browser." -ForegroundColor Green
                } elseif ($IsLinux) {
                    & xdg-open $indexPath
                    Write-Host "Opened report in default browser." -ForegroundColor Green
                }
            } catch {
                Write-Host "Could not automatically open report: $_" -ForegroundColor Yellow
                Write-Host "Please open manually: $indexPath" -ForegroundColor Cyan
            }
        }
        
        Write-Host "`n[OK] Full HTML export complete! Click link to open:" -ForegroundColor Green
        
        # Use PSStyle.FormatHyperlink in PS 7.2+ or fallback to file:// URI
        if ($PSVersionTable.PSVersion.Major -ge 7 -and $PSVersionTable.PSVersion.Minor -ge 2) {
            # PowerShell 7.2+ has built-in hyperlink support
            $clickableLink = $PSStyle.FormatHyperlink($indexPathFull, $indexPathFull)
            Write-Host "   $clickableLink" -ForegroundColor Cyan
        } else {
            # Fallback: use file:// URI (clickable in most modern terminals)
            $fileUri = "file:///$($indexPathFull -replace '\\', '/')"
            Write-Host "   $fileUri" -ForegroundColor Cyan
        }
    } else {
        # No FullHtmlExport - just console output
        Write-Host "`nProcessing complete. Use -FullHtmlExport for HTML reports." -ForegroundColor Cyan
    }
    
} else {
    # Single domain mode: existing behavior with full console output
    $result = Invoke-DomainCheck -Domain $Domain -Selectors $Selectors -QuietMode $false
    
    # Generate HTML report if requested
    if ($Html) {
        # Determine output path
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            $resolvedOutputPath = "."
        } else {
            $resolvedOutputPath = $OutputPath
        }
        
        # Ensure output directory exists
        if (-not (Test-Path $resolvedOutputPath)) {
            try {
                New-Item -ItemType Directory -Path $resolvedOutputPath -Force | Out-Null
            } catch {
                Write-Host "Error: Could not create output directory: $resolvedOutputPath" -ForegroundColor Red
                Write-Host $_.Exception.Message -ForegroundColor Red
                exit 1
            }
        }
        
        $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $safeDomain = $Domain -replace '[^a-z0-9.-]','-'
        $outPath = Join-Path $resolvedOutputPath "$safeDomain-$ts.html"
        Write-HtmlReport -Path $outPath -Domain $Domain -Summary $result.Summary `
                       -mxResult $result.MXResult -spfResult $result.SPFResult `
                       -dkimResult $result.DKIMResult -mtaStsResult $result.MTAStsResult `
                       -dmarcResult $result.DMARCResult -tlsResult $result.TLSResult
    }
}

