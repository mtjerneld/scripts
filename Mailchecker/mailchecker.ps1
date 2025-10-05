<# 
.SYNOPSIS
  Quick external mail hygiene checker: MX, DKIM, MTA-STS, DMARC, TLS-RPT, SPF.

.PARAMETER Domain
  Domain to check (e.g. example.com). If omitted, you’ll be prompted.

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
  [string]$Selectors = "default,s1,s2,selector1,selector2,google,mail,k1",

  [Parameter(Mandatory=$false)]
  [string[]]$DnsServer
  ,
  [Parameter(Mandatory=$false)]
  [string]$HtmlOutput
  ,
  [Parameter(Mandatory=$false)]
  [switch]$Html
)

function Write-Section($title) {
  Write-Host ""
  Write-Host "=== $title ===" -ForegroundColor White
}

function Write-BoolLine {
  param([string]$Label, $Value)
  if ($Value -is [string] -and $Value -eq "N/A") {
    $color = 'Yellow'
    $text = 'N/A'
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
    $MX,
    $SPF,
    $DKIM,
    $MtaStsTxt,
    $MtaStsBody,
    $DmarcMap,
    $TlsRptTxt,
  [string]$MtaStsUrl,
  [bool]$MtaStsModeTesting,
  [bool]$MtaStsEnforced,
  [string]$DmarcWarning,
  [string]$DmarcTxt,
  [bool]$DmarcEnforced,
  [array]$SpfWarnings,
  [array]$DkimWarnings,
  [string]$DkimStatusLine,
    [string]$MXSection,
    [string]$SPFSection,
    [string]$DKIMSection,
    [string]$MtaStsSection,
    [string]$DmarcSection,
    [string]$TlsRptSection
  )

  # Simple function to render any section with console output
  function Render-Section($title, $sectionText, $warnings = @(), $infoMessages = @()) {
    # Add informational text at the top of each section
    $infoText = ""
    switch ($title) {
      "MX Records" { 
        $infoText = "Mail Exchange (MX) records define which servers are authorized to receive email for your domain. Missing or incorrect MX records mean your domain cannot receive mail reliably." 
      }
      "SPF" { 
        $infoText = "SPF (Sender Policy Framework) helps prevent email spoofing by specifying which mail servers are allowed to send messages on behalf of your domain. Weak or missing SPF records make it easier for attackers to impersonate your domain." 
      }
      "DKIM" { 
        $infoText = "DKIM (DomainKeys Identified Mail) adds a digital signature to outgoing messages, proving they were not altered in transit and originate from an authorized sender. Without valid DKIM keys, recipients cannot verify the authenticity of your emails." 
      }
      "MTA-STS" { 
        $infoText = "MTA-STS (Mail Transfer Agent - Strict Transport Security) enforces encrypted mail delivery (TLS) between servers, protecting messages from interception. Without MTA-STS, emails may still be sent unencrypted even if your server supports TLS." 
      }
      "DMARC" { 
        $infoText = "DMARC (Domain-based Message Authentication, Reporting and Conformance) ties SPF and DKIM together and instructs receiving servers how to handle messages that fail authentication. A missing or unenforced DMARC policy allows spoofed emails to appear legitimate." 
      }
      "TLS-RPT" { 
        $infoText = "TLS-RPT (SMTP TLS Reporting) provides feedback about encryption issues in mail delivery, helping administrators identify failed or downgraded TLS connections. It is optional but highly recommended for visibility and security monitoring." 
      }
    }
    
    # Update titles with more verbose definitions
    $verboseTitle = $title
    switch ($title) {
      "MX Records" { $verboseTitle = "MX Records" }
      "SPF" { $verboseTitle = "SPF (Sender Policy Framework)" }
      "DKIM" { $verboseTitle = "DKIM (DomainKeys Identified Mail)" }
      "MTA-STS" { $verboseTitle = "MTA-STS (Mail Transfer Agent - Strict Transport Security)" }
      "DMARC" { $verboseTitle = "DMARC (Domain-based Message Authentication, Reporting and Conformance)" }
      "TLS-RPT" { $verboseTitle = "TLS-RPT (SMTP TLS Reporting)" }
    }
    
    $result = "  <h2>$verboseTitle</h2>`n"
    if ($infoText) {
      $result += "  <p>$([System.Web.HttpUtility]::HtmlEncode($infoText))</p>`n"
    }
    if ($sectionText) {
      $parts = Split-SectionAndStatus $sectionText
      $before = $parts[0]; $statusLine = $parts[1]; $extractedWarnings = $parts[2]
      
      # Console output
      if ($before) { 
        $formatted = Format-SectionHtml $before
        $result += "  $formatted`n"
      }
      
      # Combine all messages into one block
      $allMessages = @()
      
      # Add passed info messages first
      if ($infoMessages -and $infoMessages.Count -gt 0) { $allMessages += $infoMessages }
      
      # Add passed warnings
      if ($warnings -and $warnings.Count -gt 0) { $allMessages += $warnings }
      
      # Add extracted warnings
      if ($extractedWarnings -and $extractedWarnings.Count -gt 0) { $allMessages += $extractedWarnings }
      
      # Render combined block - only if we have messages
      if ($allMessages.Count -gt 0) {
        $result += "`n  <div class='info-block'>`n"
        foreach ($msg in $allMessages) {
          $cls = 'info'
          if ($msg -match '^(?i)\s*Warning:') { $cls = 'warn' }
          $result += "    <p class='$cls'>$( [System.Web.HttpUtility]::HtmlEncode($msg) )</p>`n"
        }
        $result += "  </div>`n"
      }
      
      # Status line
      if ($statusLine) { 
        $statusHtml = Render-FinalStatusParagraph $statusLine
        $result += "  $statusHtml`n"
      }
    } else {
      $result += "  <p class='fail'>No $title data available.</p>`n"
    }
    return $result
  }

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
      $cls = 'warn'
      $valStr = 'N/A'
    } elseif ($v -is [bool]) { 
      $cls = if ($v) { 'ok' } else { 'fail' }
      $valStr = [string]$v
    } else { 
      $cls = ''
      $valStr = [System.Web.HttpUtility]::HtmlEncode($v)
    }
    $displayName = if ($friendlyNames.ContainsKey($k)) { $friendlyNames[$k] } else { $k }
    $html += "<tr><td>$( [System.Web.HttpUtility]::HtmlEncode($displayName) )</td><td class='$cls'>$valStr</td></tr>"
  }
  $html += "</table>"

  function Format-SectionHtml($text) {
    if (-not $text) { return '' }
    $lines = $text -split "`n"
    $outLines = @()
    foreach ($ln in $lines) {
      $line = $ln.TrimEnd("`r")
      # Keep lines verbatim inside pre blocks. Status lines will be rendered
      # consistently as paragraphs by Render-FinalStatusParagraph, so do not
      # inject inline spans here.
      # Default: just HTML-encode the line
      $outLines += [System.Web.HttpUtility]::HtmlEncode($line)
    }
    return "  <pre>" + ($outLines -join "`n") + "</pre>"
  }

  function Render-FinalStatusParagraph([string]$line) {
    if (-not $line) { return '' }
    $enc = [System.Web.HttpUtility]::HtmlEncode($line.Trim())
    if ($line -match '(?i)status:\s*(OK)') { return "  <p class='ok'>$enc</p>" }
    if ($line -match '(?i)status:\s*(FAIL)') { return "  <p class='fail'>$enc</p>" }
    if ($line -match '(?i)status:\s*(WARNING|WARN)') { return "  <p class='warn'>$enc</p>" }
    # Generic fallback: if line begins with Warning/Info, render with matching class
    if ($line -match '(?i)^\s*warning') { return "  <p class='warn'>$enc</p>" }
    if ($line -match '(?i)^\s*info') { return "  <p class='info'>$enc</p>" }
    return "  <p>$enc</p>"
  }

  function Render-Insights($arr) {
    if (-not $arr) { return '' }
    $s = ''
    foreach ($w in $arr) {
      $cls = 'warn'
      if ($w -match '(?i)^\s*info') { $cls = 'info' }
      elseif ($w -match '(?i)^\s*warning') { $cls = 'warn' }
      $s += "<p class='$cls'>$( [System.Web.HttpUtility]::HtmlEncode($w) )</p>"
    }
    return $s
  }

  function Split-SectionAndStatus([string]$sectionText) {
    # Returns array: [0]=contentBeforeStatus, [1]=statusLine or $null, [2]=warnings array
    if (-not $sectionText) { return @('',$null,@()) }
    $sec = $sectionText
    
    # Extract warnings first (lines containing "Warning:")
    $warnings = @()
    $lines = $sec -split "`n"
    $contentLines = @()
    foreach ($line in $lines) {
      if ($line -match '(?i)\s*Warning:') {
        $warnings += $line.Trim()
      } else {
        $contentLines += $line
      }
    }
    $sec = $contentLines -join "`n"
    
    # Find all lines that contain 'status:' (case-insensitive) and pick the last
    $matches = [regex]::Matches($sec, '(?im)^.*status:.*$')
    if ($matches.Count -gt 0) {
      $last = $matches[$matches.Count - 1]
      $statusLine = $last.Value.Trim()
      $before = $sec.Substring(0, $last.Index).TrimEnd("`r","`n")
      return @($before, $statusLine, $warnings)
    }
    return @($sec, $null, $warnings)
  }

  # (Block status table removed - verbose per-block console text is included in each section below)

  # Use simple approach for all sections
  $html += Render-Section "MX Records" $MXSection
  $html += Render-Section "SPF" $SPFSection $SpfWarnings
  
  # DKIM needs special handling for validation message - add it to existing warnings
  if ($DKIM_AnySelector_Valid) { 
    $DkimWarnings += "Info: DKIM validation successful - at least one valid selector found with proper public key." 
  } else { 
    $DkimWarnings += "Warning: DKIM validation failed - no valid selectors found with proper public keys." 
  }
  $html += Render-Section "DKIM" $DKIMSection $DkimWarnings
  $html += Render-Section "MTA-STS" $MtaStsSection
  
  # DMARC - handle warnings and info separately since they come as strings, not arrays
  $dmarcWarnings = @()
  $dmarcInfoMessages = @()
  if ($DmarcWarning) { $dmarcWarnings = @($DmarcWarning) }
  if ($dmarcInfo) { $dmarcInfoMessages = @($dmarcInfo) }
  $html += Render-Section "DMARC" $DmarcSection $dmarcWarnings $dmarcInfoMessages
  $html += Render-Section "TLS-RPT" $TlsRptSection

  $html += "</body></html>"

  try {
    $html | Out-File -FilePath $Path -Encoding utf8 -Force
    Write-Host "Wrote HTML report to: $Path" -ForegroundColor Green
  } catch {
    Write-Host ("Failed to write HTML report to {0}: {1}" -f $Path, $_) -ForegroundColor Red
  }
}

# --- Main ---

if (-not $Domain -or $Domain.Trim() -eq '') {
  $Domain = Read-Host "Enter domain (e.g. example.com)"
}
$Domain = $Domain.Trim().ToLower()

Write-Host "Checking domain: $Domain (Resolvers: $($Resolvers -join ', '))" -ForegroundColor Yellow

# 1) MX
Write-Section "MX Records"
$mx = Resolve-MX $Domain
$mxOk = $false
if (@($mx).Count -gt 0) {
  $mx | Sort-Object Preference,NameExchange | Format-Table -AutoSize
  $mxOk = $true
  Write-Host "MX status: OK" -ForegroundColor Green
} else {
  Write-Host "No MX records found via any configured resolver." -ForegroundColor Red
  Write-Host "MX status: FAIL" -ForegroundColor Red
}

# 2) SPF
Write-Section "SPF"
$spfRecs = Resolve-SPF $Domain
$spfWarnings = @()
$spfConsoleLines = @()
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
if (@($spfRecs).Count -gt 0) {
  $i = 1
  foreach ($rec in $spfRecs) {
    $spfConsoleLines += ("SPF #{0}: {1}" -f $i, $rec)
    # Remove the all mechanism analysis - not needed in output
    $lookupCount = Get-SpfLookups $rec @()
  $spfConsoleLines += ("Info: DNS lookups (SPF): {0}" -f $lookupCount)
    $spfHealthy = $true
    $spfSoftFail = $false
    if (-not $rec) {
      $spfHealthy = $false
    } elseif ($lookupCount -gt 10) {
      $msg = "Warning: SPF exceeds 10 DNS lookups!"
  $spfConsoleLines += $msg
      $spfWarnings += $msg
      $spfHealthy = $false
    }
    $allMatch = [regex]::Match($rec, '(?i)(^|\s)([~+\-?])?all(\s|$)')
    if ($allMatch.Success -and $allMatch.Groups[2].Value -eq '~') {
      $msg = "Warning: SPF uses soft fail (~all), which is not recommended for production."
      $spfWarnings += $msg
      $spfHealthy = $false
      $spfSoftFail = $true
    }
    $i++
  }
  # Print buffered SPF console lines (DNS/SPF record details)
  foreach ($ln in $spfConsoleLines) { 
    if ($ln -match '^Info:') {
      Write-Host $ln -ForegroundColor Cyan
    } else {
      Write-Host $ln
    }
  }
  # Print collected SPF warnings/insights
  foreach ($w in $spfWarnings) { Write-Host $w -ForegroundColor Yellow }
  # Final SPF status
  if ($spfHealthy) {
    Write-Host "SPF status: OK" -ForegroundColor Green
  } else {
    Write-Host "SPF status: FAIL" -ForegroundColor Red
  }
} else {
  Write-Host "No SPF (v=spf1) record found at $Domain" -ForegroundColor Yellow
  Write-Host "SPF status: FAIL" -ForegroundColor Red
}

# 3) DKIM (by selectors)
Write-Section "DKIM"
# Skip DKIM test only if domain has no MX AND (no SPF record OR SPF only has -all)
$hasSpfWithMechanisms = $false
if (@($spfRecs).Count -gt 0) {
  foreach ($spf in $spfRecs) {
    # Check if SPF has any mechanisms other than just v=spf1 and -all
    # Remove v=spf1 and -all, then check if anything meaningful remains
    $cleanSpf = $spf -replace '(?i)\bv=spf1\s*', '' -replace '(?i)\s*[~+\-?]?all\s*$', '' -replace '^\s+|\s+$', ''
    $hasMechanisms = $cleanSpf.Length -gt 0 -and $cleanSpf -match '(?i)(include:|a:|mx:|ptr:|exists:|redirect=)'
    if ($hasMechanisms) {
      $hasSpfWithMechanisms = $true
      break
    }
  }
}

if (-not $mxOk -and -not $hasSpfWithMechanisms) {
  Write-Host "Info: Not applicable - domain has no mail flow (no MX and no SPF mechanisms)" -ForegroundColor Cyan
  Write-Host "DKIM status: N/A" -ForegroundColor Yellow
} else {
  $selectorList = ($Selectors -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  $dkimResults = @()
  $dkimWarnings = @()

  foreach($sel in $selectorList){
  $dkimHost = "$sel._domainkey.$Domain"
  $txt = Resolve-Txt $dkimHost
  if ($txt -is [System.Collections.IEnumerable]) { $txt = ($txt -join "") }

  $hasV = $false; $hasP = $false
  if ($txt) {
    $hasV = [bool]($txt -match "(?i)\bv\s*=\s*DKIM1\b")
  # Allow p= to be the last field without a semicolon
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

# Valid if TXT exists, p= exists, and if v= exists it must be DKIM1
$validSelectors = $dkimResults | Where-Object {
  $_.Found -and $_.Has_PublicKey_p -and (
    -not $_.Has_V_DKIM1 -or $_.Has_V_DKIM1
  )
}

# FIX: always count as an array
$DKIM_AnySelector_Valid = (@($validSelectors).Count -gt 0)

# Extra flaggor
foreach ($dkim in @($validSelectors)) {
  if ($dkim.FullTXT -match '(?i)\bt=y\b') {
    $msg = "Warning: DKIM selector '$($dkim.Selector)' is in test mode (t=y)."
    Write-Host $msg -ForegroundColor Yellow
    $dkimWarnings += $msg
  }
  if ($dkim.FullTXT -match '(?i)\bt=s\b') {
    $msg = "Info: DKIM selector '$($dkim.Selector)' uses strict mode (t=s) - good security practice that prevents email spoofing from other domains."
    $dkimWarnings += $msg
  }
  if ($dkim.FullTXT -match '(?i)\bp=\s*;') {
    $msg = "Warning: DKIM selector '$($dkim.Selector)' has empty key (p=), which means revocation."
    Write-Host $msg -ForegroundColor Red
    $dkimWarnings += $msg
  }
}

# Print DKIM results table first (DNS responses)
$dkimResults | Format-Table -AutoSize

# Then print collected warnings/insights
foreach ($w in $dkimWarnings) { 
  if ($w -match '^Info:') {
    Write-Host $w -ForegroundColor Cyan
  } else {
    Write-Host $w -ForegroundColor Yellow
  }
}

# Finally print summarized DKIM status
if (-not $mxOk) {
  Write-Host "Info: Not applicable - domain cannot receive email" -ForegroundColor Cyan
  Write-Host "DKIM status: N/A" -ForegroundColor Yellow
} elseif ($DKIM_AnySelector_Valid) {
  Write-Host "Info: DKIM validation successful - at least one valid selector found with proper public key." -ForegroundColor Cyan
  Write-Host "DKIM status: OK" -ForegroundColor Green
} else {
  Write-Host "Warning: DKIM validation failed - no valid selectors found with proper public keys." -ForegroundColor Yellow
  Write-Host "DKIM status: FAIL" -ForegroundColor Red
}
}


# 4) MTA-STS
Write-Section "MTA-STS"
if (-not $mxOk) {
  Write-Host "Info: Not applicable - domain cannot receive email" -ForegroundColor Cyan
  Write-Host "MTA-STS status: N/A" -ForegroundColor Yellow
} else {

# --- MTA-STS: säkra defaults (alltid bools) ---
$MtaStsModeTesting = $false
$MtaStsEnforced    = $false
[string]$mtaStsUrlVal = $null
[string]$mtaStsBody   = $null

$mtaStsTxtHost = "_mta-sts.$Domain"
$mtaStsTxt = Resolve-Txt $mtaStsTxtHost
  if ($mtaStsTxt) {
  Write-Host ("TXT at $($mtaStsTxtHost):`n$($mtaStsTxt)")
  $hasV = $mtaStsTxt -match "(?i)\bv=STSv1\b"
  $idMatch = [regex]::Match($mtaStsTxt, "(?i)\bid=([^;]+)")
  $idVal = $null
  if ($idMatch.Success) { $idVal = $idMatch.Groups[1].Value.Trim() }
  Write-Host ("- v=STSv1 present: {0}" -f $hasV)
  if ($idVal) { Write-Host ("- id: {0}" -f $idVal) } else { Write-Host "- id: (none)" }
  # Status line moved to end of MTA-STS block
} else {
  Write-Host "No _mta-sts TXT record found." -ForegroundColor Yellow
}

# Bygg URL och spara strängvärde att visa i rapporten
$mtaStsUrl = "https://mta-sts.$Domain/.well-known/mta-sts.txt"
$mtaStsUrlVal = $mtaStsUrl

# Hämta HTTPS-policy (din egen helper, t.ex. Invoke-WebRequest wrapper)
$mtaStsBody = Get-HttpText $mtaStsUrl

if ($mtaStsBody) {
    # Enkla nyckel=värde-rader, ex:
    # version: STSv1
    # mode: enforce|testing|none
    # mx: example.com
    # max_age: 86400

    $mode = $null
    foreach ($line in $mtaStsBody -split "`n") {
        $trim = $line.Trim()
        if ($trim -match '^(?i)mode\s*:\s*(.+)$') {
            $mode = $Matches[1].Trim()
            break
        }
    }

    # Säkra booleans baserat på mode
    # enforce  -> Enforced=$true, ModeTesting=$false
    # testing  -> ModeTesting=$true, Enforced=$false
    # none/okänt -> båda $false
    switch -Regex ($mode) {
        '^(?i)enforce$' { $MtaStsEnforced = $true;  $MtaStsModeTesting = $false; break }
        '^(?i)testing$' { $MtaStsEnforced = $false; $MtaStsModeTesting = $true;  break }
        default         { $MtaStsEnforced = $false; $MtaStsModeTesting = $false; break }
    }
} else {
    # Ingen policy hittad -> båda false (redan default), och $mtaStsBody förblir $null
    $MtaStsEnforced    = $false
    $MtaStsModeTesting = $false
}
  if ($mtaStsBody) {
  Write-Host "Fetched policy from $mtaStsUrl"
  $dict = @{}
  foreach($line in ($mtaStsBody -split "`n")){
    $t = $line.Trim()
    if ($t -like "#*" -or $t -eq "") { continue }
    $kv = $t -split ":",2
    if ($kv.Count -eq 2) { $dict[$kv[0].Trim()] = $kv[1].Trim() }
  }
  $mode = $dict['mode']
  $version = $dict['version']
  $maxage = $dict['max_age']

  if ($version) { Write-Host ("- version: {0}" -f $version) } else { Write-Host "- version: (missing)" }
  if ($mode)    { Write-Host ("- mode: {0}" -f $mode) }       else { Write-Host "- mode: (missing)" }
  if ($maxage)  { Write-Host ("- max_age: {0}" -f $maxage) } else { Write-Host "- max_age: (missing)" }

  $mxLines = @()
  foreach($ln in ($mtaStsBody -split "`n")){
    if ($ln -match "^\s*mx\s*:") { $mxLines += $ln.Trim() }
  }
  if ($mxLines.Count -gt 0) {
    Write-Host "- mx patterns:"
    foreach($l in $mxLines){ Write-Host ("  {0}" -f $l) }
  }
  # If the policy is in testing mode, print the warning after the policy details
  if ($MtaStsModeTesting) {
    Write-Host ""
    Write-Host "Warning: MTA-STS is in testing mode (mode=testing) and not enforced (HTTPS policy)." -ForegroundColor Yellow
  }

  # Status line for MTA-STS HTTPS policy will only be shown in the summary block
  } else {
  Write-Host "Could not fetch HTTPS policy at $mtaStsUrl" -ForegroundColor Yellow
}

# Final MTA-STS status based on our robust parsing
if (-not $mxOk) {
  Write-Host "Info: Not applicable - domain cannot receive email" -ForegroundColor Cyan
  Write-Host "MTA-STS status: N/A" -ForegroundColor Yellow
} elseif ($MtaStsEnforced) {
  Write-Host "MTA-STS status: OK" -ForegroundColor Green
} else {
  Write-Host "MTA-STS status: FAIL" -ForegroundColor Red
}
}

# 5) DMARC
Write-Section "DMARC"
$dmarcHost = "_dmarc.$Domain"
$dmarcTxt = Resolve-Txt $dmarcHost

# --- Harden DMARC enforcement flag ---
try {
    $dmarcEnforced = $false
    if ($dmarcTxt) {
        # Normalize for matching
        $dmarcNorm = [string]$dmarcTxt
        if ($dmarcNorm -match '(?i)\bp\s*=\s*(reject|quarantine)\b') {
            $dmarcEnforced = $true
        } else {
            $dmarcEnforced = $false
        }
    } else {
        $dmarcEnforced = $false
    }
} catch { $dmarcEnforced = $false }
# --- End harden ---
  if ($dmarcTxt) {
  Write-Host ("TXT at $($dmarcHost):`n$($dmarcTxt)")
  $dmarc = Get-DmarcInfo $dmarcTxt
  $tags = "v","p","sp","rua","ruf","fo","aspf","adkim","pct"
  # Evaluate p early so we can place the warning immediately after the p line
  $pVal = if ($dmarc.ContainsKey('p')) { $dmarc['p'] } else { $null }
  $dmarcWarning = $null
  foreach($t in $tags){
    if ($dmarc.ContainsKey($t)) {
      Write-Host ("- {0} = {1}" -f $t, $dmarc[$t])
      if ($t -eq 'p' -and $pVal -and $pVal -match '(?i)^none$') {
        # collect the warning and print after the tag lines
        $dmarcWarning = "Warning: DMARC is in testing mode only (p=none) and not enforced."
      }
    }
  }
  if ($dmarcWarning) { Write-Host $dmarcWarning -ForegroundColor Yellow; Write-Host "" }
  $hasV = ($dmarc.ContainsKey('v') -and $dmarc['v'] -match '(?i)^DMARC1$')
  $hasP = $dmarc.ContainsKey('p')
    if ($hasV -and $hasP) {
    # Use the parsed tag map to check p and sp separately (avoid false matches where 'sp' contains 'p')
    $spVal = if ($dmarc.ContainsKey('sp')) { $dmarc['sp'] } else { $null }

    $dmarcEnforced = $false
    if ($pVal -and $pVal -match '(?i)^(quarantine|reject)$') {
      $dmarcEnforced = $true
    }

    Write-Host "DMARC looks present with required tags (v & p)." -ForegroundColor Green
    if ($dmarcEnforced) {
      Write-Host "DMARC status: OK" -ForegroundColor Green
    } else {
      Write-Host "DMARC status: FAIL" -ForegroundColor Red
    }
    
  } else {
    Write-Host "DMARC present but missing required tags (v and/or p)." -ForegroundColor Yellow
    Write-Host "DMARC status: FAIL" -ForegroundColor Red
  }
} else {
  Write-Host "No DMARC record found at $dmarcHost" -ForegroundColor Red
  Write-Host "DMARC status: FAIL" -ForegroundColor Red
}

# 6) TLS-RPT
Write-Section "SMTP TLS Reporting (TLS-RPT)"
if (-not $mxOk) {
  Write-Host "Info: Not applicable - domain cannot receive email" -ForegroundColor Cyan
  Write-Host "TLS-RPT status: N/A" -ForegroundColor Yellow
} else {
  $tlsRptHost = "_smtp._tls.$Domain"
  $tlsRptTxt = Resolve-Txt $tlsRptHost
if ($tlsRptTxt) {
  Write-Host ("TXT at $($tlsRptHost):`n$($tlsRptTxt)")
  $hasV = $tlsRptTxt -match "(?i)\bv=TLSRPTv1\b"
  $ruaMatch = [regex]::Match($tlsRptTxt, "(?i)\bru[a]\s*=\s*mailto:([^,;]+)")
  Write-Host ("- v=TLSRPTv1 present: {0}" -f $hasV)
  if ($ruaMatch.Success) { Write-Host ("- rua: {0}" -f $ruaMatch.Groups[1].Value) } else { Write-Host "- rua: (missing)" }
  Write-Host "TLS-RPT status: OK" -ForegroundColor Green
} else {
  if (-not $mxOk) {
    Write-Host "Info: Not applicable - domain cannot receive email" -ForegroundColor Cyan
    Write-Host "TLS-RPT status: N/A" -ForegroundColor Yellow
  } else {
    Write-Host "No TLS-RPT record found (optional but recommended)." -ForegroundColor Yellow
    Write-Host "TLS-RPT status: FAIL" -ForegroundColor Red
  }
}
}

# Summary
Write-Section "Summary"
Write-Host "Tested domain: $Domain" -ForegroundColor White

# If no MX records, only validate outbound features (SPF, DMARC)
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


# Färgkodad radvis status
Write-Host "`nStatus:"
Write-BoolLine "MX_Records_Present"     $summary.MX_Records_Present
Write-BoolLine "SPF_Present"            $summary.SPF_Present
Write-BoolLine "SPF_Healthy"            $summary.SPF_Healthy
Write-BoolLine "DKIM_ValidSelector"     $summary.DKIM_ValidSelector
Write-BoolLine "MTA_STS_DNS_Present"    $summary.MTA_STS_DNS_Present
Write-BoolLine "MTA_STS_Enforced"       $summary.MTA_STS_Enforced
## MTA_STS_Reason line removed to restore summary to only show booleans
Write-BoolLine "DMARC_Present"          $summary.DMARC_Present
Write-BoolLine "DMARC_Enforced"         $summary.DMARC_Enforced
Write-BoolLine "TLS_RPT_Present"        $summary.TLS_RPT_Present

Write-Host "`nTip: For DKIM, inspect a real message header to learn the active selector (s=) and re-run with -Selectors 'thatSelector'." -ForegroundColor DarkCyan

# If requested, write an HTML report
if ($HtmlOutput -and $HtmlOutput.Trim() -ne '') {
  $outPath = $HtmlOutput
} elseif ($Html) {
  $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $safeDomain = $Domain -replace '[^a-z0-9.-]','-'
  $outPath = "$safeDomain-$ts.html"
} else {
  $outPath = $null
}

if ($outPath) {
  # Ensure we have the pieces to include; variables like $mtaStsBody or $dmarc may be null
  $mxRecords = $mx
  $spfRecords = $spfRecs
  $dkimResults = $dkimResults
  $mtaStsTxtVal = $mtaStsTxt
  $mtaStsBodyVal = $mtaStsBody
  $dmarcMap = $dmarc
  $tlsRptTxtVal = $tlsRptTxt
  $mtaStsUrlVal = $mtaStsUrl
  # Build console-style section strings for inclusion in the HTML report
  $mxSection = $null
  if (@($mxRecords).Count -gt 0) {
    $mxSection = ($mxRecords | Sort-Object Preference,NameExchange | ForEach-Object { "{0} {1}" -f $_.Preference, $_.NameExchange }) -join "`n"
    $mxSection += "`n`nMX status: OK"
  } else {
    $mxSection = "No MX records found via any configured resolver.`nMX status: FAIL"
  }

  $spfSection = $null
  if (@($spfRecords).Count -gt 0) {
  $i=1; $lines=@()
  foreach ($r in $spfRecords) { $lines += ("SPF #{0}: {1}" -f $i, $r); $i++ }
  $lines += ("- DNS lookups (SPF): {0}" -f $lookupCount)  # best-effort: uses last computed lookupCount
  if ($spfHealthy) { $lines += "`nSPF status: OK" } else { $lines += "`nSPF status: FAIL" }
    $spfSection = $lines -join "`n"
  } else { $spfSection = "No SPF (v=spf1) record found at $Domain`nSPF status: FAIL" }

  $dkimSection = $null
  if (-not $mxOk -and -not $hasSpfWithMechanisms) {
    # N/A case - domain has no mail flow
    $dkimSection = "Info: Not applicable - domain has no mail flow (no MX and no SPF mechanisms)`nDKIM status: N/A"
  } elseif ($dkimResults -and @($dkimResults).Count -gt 0) {
    $lines = @()
    foreach ($d in $dkimResults) { $lines += "Selector $($d.Selector): Found=$($d.Found) V=$($d.Has_V_DKIM1) p=$($d.Has_PublicKey_p)" }
  if ($DKIM_AnySelector_Valid) { $dkimStatusLine = "DKIM status: OK" } else { $dkimStatusLine = "DKIM status: FAIL" }
    # Add status line to the section
    $lines += $dkimStatusLine
    # Build console-style section for HTML rendering
    $dkimSection = $lines -join "`n"
  } else { $dkimSection = "DKIM: No selectors checked.`nDKIM status: FAIL" }

  # Build MTA-STS section with all console output including warnings
  $mtaStsSection = $null
  if (-not $mxOk) {
    # N/A case - domain cannot receive email
    $mtaStsSection = "Info: Not applicable - domain cannot receive email`nMTA-STS status: N/A"
  } elseif ($mtaStsTxtVal) {
    $mtaStsSection = "TXT at _mta-sts.$($Domain):`n$($mtaStsTxtVal)"
    if ($mtaStsBodyVal) { 
      $mtaStsSection += "`nFetched policy from $($mtaStsUrlVal)`n" + $mtaStsBodyVal 
      # Add testing mode warning if applicable (same as console output)
      if ($MtaStsModeTesting) { 
        $mtaStsSection += "`n`nWarning: MTA-STS is in testing mode (mode=testing) and not enforced (HTTPS policy)." 
      }
    }
    # Add status (same as console output)
    if ($MtaStsEnforced) { $mtaStsSection += "`nMTA-STS status: OK" } else { $mtaStsSection += "`nMTA-STS status: FAIL" }
  } else { 
    $mtaStsSection = "No _mta-sts TXT record found.`nMTA-STS status: FAIL" 
  }

  $dmarcSection = $null
  $dmarcWarning = $null
  $dmarcInfo = $null
  if ($dmarcMap -and $dmarcMap.Keys.Count -gt 0) {
    $lines = @()
  $lines += "TXT at _dmarc.$($Domain):`n$($dmarcTxt)"
    $tags = "v","p","sp","rua","ruf","fo","aspf","adkim","pct"
    foreach ($t in $tags) {
      if ($dmarcMap.ContainsKey($t)) {
        $lines += "- $t = $($dmarcMap[$t])"
        if ($t -eq 'p' -and $pVal -and $pVal -match '(?i)^none$') {
          # Do not insert warning into the pre block; capture it separately so the HTML writer
          # can place a <p class='warn'> immediately after the '- p = ...' line.
          $dmarcWarning = "Warning: DMARC is in testing mode only (p=none) and not enforced."
        }
      }
    }
    # Add info message about DMARC presence
    $dmarcInfo = "Info: DMARC looks present with required tags (v & p)."
  if ($dmarcEnforced) { $dmarcStatus = "`nDMARC status: OK" } else { $dmarcStatus = "`nDMARC status: FAIL" }
  $lines += $dmarcStatus
    $dmarcSection = $lines -join "`n"
  } else { $dmarcSection = "No DMARC record found at _dmarc.$Domain`nDMARC status: FAIL" }
  # Keep DMARC section for HTML rendering (warnings will be handled by Split-SectionAndStatus)

  $tlsRptSection = $null
  if (-not $mxOk) {
    # N/A case - domain cannot receive email
    $tlsRptSection = "Info: Not applicable - domain cannot receive email`nTLS-RPT status: N/A"
  } elseif ($tlsRptTxtVal) {
    $tlsRptSection = "TXT at _smtp._tls.$($Domain):`n$($tlsRptTxtVal)`n`nTLS-RPT status: OK"
  } else { $tlsRptSection = "No TLS-RPT record found (optional but recommended).`n`nTLS-RPT status: FAIL" }

# --- Tvinga booleans så att aldrig "" råkar skickas in ---
$MtaStsModeTesting = [bool]$MtaStsModeTesting
$MtaStsEnforced    = [bool]$MtaStsEnforced

# --- Coerce DMARC boolean ---
$dmarcEnforced = [bool]$dmarcEnforced

  Write-HtmlReport -Path $outPath -Domain $Domain -Summary $summary -MX $mxRecords -SPF $spfRecords -DKIM $dkimResults -MtaStsTxt $mtaStsTxtVal -MtaStsBody $mtaStsBodyVal -DmarcMap $dmarcMap -TlsRptTxt $tlsRptTxtVal -MtaStsUrl $mtaStsUrlVal -MtaStsModeTesting $mtaStsModeTesting -MtaStsEnforced $MtaStsEnforced -DmarcWarning $dmarcWarning -DmarcTxt $dmarcTxt -DmarcEnforced $dmarcEnforced -SpfWarnings $spfWarnings -DkimWarnings $dkimWarnings -DkimStatusLine $dkimStatusLine -MXSection $mxSection -SPFSection $spfSection -DKIMSection $dkimSection -MtaStsSection $mtaStsSection -DmarcSection $dmarcSection -TlsRptSection $tlsRptSection
}
