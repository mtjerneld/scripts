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
    $status = 'FAIL'
    
    if (@($mx).Count -gt 0) {
        $details = $mx | Sort-Object Preference,NameExchange | 
                   ForEach-Object { "$($_.Preference) $($_.NameExchange)" }
        $status = 'OK'
    } else {
        $details = @("No MX records found via any configured resolver.")
    }
    
    return New-CheckResult -Section 'MX Records' -Status $status -Details $details -Data @{ MXRecords = $mx }
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
        $hasV = [bool]($tlsRptTxt -match "(?i)\\bv=TLSRPTv1\\b")
        $ruaMatch = [regex]::Match($tlsRptTxt, "(?i)\\bru[a]\\s*=\\s*(mailto:[^,;]+|https?://[^,;]+)")
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
    
    $html = @"
  <h2>$verboseTitle</h2>
"@
    
    # Add informational text
    if ($infoText) {
        $html += @"
  <p>$([System.Web.HttpUtility]::HtmlEncode($infoText))</p>
"@
    }
    
    # Console output (details)
    if ($Result.Details -and $Result.Details.Count -gt 0) {
        $html += "  <pre>"
        foreach ($line in $Result.Details) {
            $html += [System.Web.HttpUtility]::HtmlEncode($line) + "`n"
        }
        $html += "</pre>"
    }
    
    # Info/Warning block
    $allMessages = @()
    if ($Result.InfoMessages -and $Result.InfoMessages.Count -gt 0) { 
        $allMessages += $Result.InfoMessages 
    }
    if ($Result.Warnings -and $Result.Warnings.Count -gt 0) { 
        $allMessages += $Result.Warnings 
    }
    
    if ($allMessages.Count -gt 0) {
        $html += @"

  <div class='info-block'>"@
        foreach ($msg in $allMessages) {
            $cls = 'info'
            if ($msg -match '^(?i)\s*Warning:') { $cls = 'warn' }
            $html += @"
    <p class='$cls'>$([System.Web.HttpUtility]::HtmlEncode($msg))</p>
"@
        }
        $html += @"
  </div>"@
    }
    
    # Status line
    $statusText = "$($Result.Section) status: $($Result.Status)"
    $cls = switch ($Result.Status) {
        'OK'   { 'ok' }
        'FAIL' { 'fail' }
        'WARN' { 'warn' }
        'N/A'  { 'warn' }
    }
    $html += @"
  <p class='$cls'>$([System.Web.HttpUtility]::HtmlEncode($statusText))</p>
"@
    
    return $html
}

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

# --- Main ---

if (-not $Domain -or $Domain.Trim() -eq '') {
  $Domain = Read-Host "Enter domain (e.g. example.com)"
}
$Domain = $Domain.Trim().ToLower()

Write-Host "Checking domain: $Domain (Resolvers: $($Resolvers -join ', '))" -ForegroundColor Yellow

# 1) MX
# 1) MX Records
$mxResult = Test-MXRecords -Domain $Domain
$mx = $mxResult.Data.MXRecords
$mxOk = @($mx).Count -gt 0
Write-CheckResult $mxResult

# 2) SPF
$spfResult = Test-SPFRecords -Domain $Domain
$spfRecs = $spfResult.Data.SPFRecords
$spfHealthy = $spfResult.Data.Healthy
Write-CheckResult $spfResult

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
Write-CheckResult $dkimResult


# 4) MTA-STS
$mtaStsResult = Test-MTASts -Domain $Domain -HasMX $mxOk
$mtaStsTxt = $mtaStsResult.Data.MtaStsTxt
$MtaStsEnforced = $mtaStsResult.Data.MtaStsEnforced
$MtaStsModeTesting = $mtaStsResult.Data.MtaStsModeTesting
Write-CheckResult $mtaStsResult

# 5) DMARC
# Replace legacy DMARC console block with unified result object
$dmarcResult = Test-DMARC -Domain $Domain
$dmarc = $dmarcResult.Data.DmarcMap
$dmarcTxt = $dmarcResult.Data.DmarcTxt
$dmarcEnforced = [bool]$dmarcResult.Data.Enforced
Write-CheckResult $dmarcResult

# 6) TLS-RPT
# Replace legacy TLS-RPT console block with unified result object
$tlsResult = Test-TLSReport -Domain $Domain -HasMX $mxOk
$tlsRptTxt = $tlsResult.Data.TlsRptTxt
Write-CheckResult $tlsResult

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
  # Old section building code removed - now using unified result objects

# --- Tvinga booleans så att aldrig "" råkar skickas in ---
$MtaStsModeTesting = [bool]$MtaStsModeTesting
$MtaStsEnforced    = [bool]$MtaStsEnforced

# --- Coerce DMARC boolean ---
$dmarcEnforced = [bool]$dmarcEnforced

  Write-HtmlReport -Path $outPath -Domain $Domain -Summary $summary -mxResult $mxResult -spfResult $spfResult -dkimResult $dkimResult -mtaStsResult $mtaStsResult -dmarcResult $dmarcResult -tlsResult $tlsResult
}
