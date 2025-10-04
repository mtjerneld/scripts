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
)

function Write-Section($title) {
  Write-Host ""
  Write-Host "=== $title ===" -ForegroundColor White
}

function Write-BoolLine {
  param([string]$Label, [bool]$Value)
  $color = if ($Value) { 'Green' } else { 'Red' }
  $text  = if ($Value) { 'True' }  else { 'False' }
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
    Write-Host ("SPF #{0}: {1}" -f $i, $rec)
    $all = [regex]::Match($rec, '(?i)(^|\s)([~+\-?])?all(\s|$)')
    if ($all.Success) {
      $sign = $all.Groups[2].Value
      $desc = switch ($sign) {
        '-' { 'Hard fail (-all)' }
        '~' { 'Soft fail (~all)' }
        '+' { 'Pass (+all)' }
        '?' { 'Neutral (?all)' }
        default { 'Pass (+all)' }
      }
      Write-Host ("- all mechanism: {0}" -f $desc)
    } else {
      Write-Host "- all mechanism: (missing)"
    }
    $lookupCount = Get-SpfLookups $rec @()
    Write-Host ("- DNS lookups (SPF): {0}" -f $lookupCount)
    $spfHealthy = $true
    $spfSoftFail = $false
    if (-not $rec) {
      $spfHealthy = $false
    } elseif ($lookupCount -gt 10) {
      Write-Host "Warning: SPF exceeds 10 DNS lookups!" -ForegroundColor Yellow
      $spfHealthy = $false
    }
    $allMatch = [regex]::Match($rec, '(?i)(^|\s)([~+\-?])?all(\s|$)')
    if ($allMatch.Success -and $allMatch.Groups[2].Value -eq '~') {
      Write-Host "Warning: SPF uses soft fail (~all), which is not recommended for production." -ForegroundColor Yellow
      $spfHealthy = $false
      $spfSoftFail = $true
    }
    $i++
  }
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
$selectorList = ($Selectors -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$dkimResults = @()

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
  $_.Found -and (
    $_.FullTXT -match '(?i)\bp\s*=\s*[^;]+' -or $_.FullTXT -match '(?i)\bp\s*=\s*\S+$'
  ) -and (
    -not ($_.FullTXT -match '(?i)\bv\s*=') -or ($_.FullTXT -match '(?i)\bv\s*=\s*DKIM1\b')
  )
}

# FIX: always count as an array
$DKIM_AnySelector_Valid = (@($validSelectors).Count -gt 0)

# Extra flaggor
foreach ($dkim in @($validSelectors)) {
  if ($dkim.FullTXT -match '(?i)\bt=y\b') {
  Write-Host "Warning: DKIM selector '$($dkim.Selector)' is in test mode (t=y)." -ForegroundColor Yellow
  }
  if ($dkim.FullTXT -match '(?i)\bt=s\b') {
  Write-Host "Info: DKIM selector '$($dkim.Selector)' has strict flag (t=s)." -ForegroundColor Cyan
  }
  if ($dkim.FullTXT -match '(?i)\bp=\s*;') {
  Write-Host "Warning: DKIM selector '$($dkim.Selector)' has empty key (p=), which means revocation." -ForegroundColor Red
  }
}

# Sammanfattad status
if ($DKIM_AnySelector_Valid) {
  Write-Host "DKIM: At least one valid selector found." -ForegroundColor Green
  Write-Host "DKIM status: OK" -ForegroundColor Green
} else {
  Write-Host "DKIM: No valid selector found." -ForegroundColor Red
  Write-Host "DKIM status: FAIL" -ForegroundColor Red
}

$dkimResults | Format-Table -AutoSize


# 4) MTA-STS
Write-Section "MTA-STS"
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
  $mtaStsEnforced = $true
  $modeMatch = [regex]::Match($mtaStsTxt, '(?i)mode\s*=\s*testing')
  if ($modeMatch.Success) {
    Write-Host "Warning: MTA-STS is in testing mode and not enforced." -ForegroundColor Yellow
    $mtaStsEnforced = $false
  }
  # Status line moved to end of MTA-STS block
} else {
  Write-Host "No _mta-sts TXT record found." -ForegroundColor Yellow
  $mtaStsEnforced = $false
  Write-Host "MTA-STS status: FAIL" -ForegroundColor Red
}

if (-not $mtaStsBody) {
  $mtaStsEnforced = $false
}

$mtaStsUrl = "https://mta-sts.$Domain/.well-known/mta-sts.txt"
## Fetch HTTPS policy and set enforcement correctly
$mtaStsBody = Get-HttpText $mtaStsUrl
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

  if ($mode -and $mode -match '(?i)testing') {
    Write-Host "Warning: MTA-STS is in testing mode (mode=testing) and not enforced (HTTPS policy)." -ForegroundColor Yellow
    $mtaStsEnforced = $false
  } elseif ($mode -and $mode -match '(?i)enforce') {
    $mtaStsEnforced = $true
  } else {
    $mtaStsEnforced = $false
  }

  $mxLines = @()
  foreach($ln in ($mtaStsBody -split "`n")){
    if ($ln -match "^\s*mx\s*:") { $mxLines += $ln.Trim() }
  }
  if ($mxLines.Count -gt 0) {
    Write-Host "- mx patterns:"
    foreach($l in $mxLines){ Write-Host ("  {0}" -f $l) }
  }

  # Status line for MTA-STS HTTPS policy will only be shown in the summary block
  } else {
  Write-Host "Could not fetch HTTPS policy at $mtaStsUrl" -ForegroundColor Yellow

  $mtaStsEnforced = $false
}

# Print MTA-STS status only once at the end of the MTA-STS section
if ($mtaStsEnforced) {
  Write-Host "MTA-STS status: OK" -ForegroundColor Green
} else {
  Write-Host "MTA-STS status: FAIL" -ForegroundColor Red
}

# 5) DMARC
Write-Section "DMARC"
$dmarcHost = "_dmarc.$Domain"
$dmarcTxt = Resolve-Txt $dmarcHost
  if ($dmarcTxt) {
  Write-Host ("TXT at $($dmarcHost):`n$($dmarcTxt)")
  $dmarc = Get-DmarcInfo $dmarcTxt
  $tags = "v","p","sp","rua","ruf","fo","aspf","adkim","pct"
  foreach($t in $tags){
    if ($dmarc.ContainsKey($t)) { Write-Host ("- {0} = {1}" -f $t, $dmarc[$t]) }
  }
  $hasV = ($dmarc.ContainsKey('v') -and $dmarc['v'] -match '(?i)^DMARC1$')
  $hasP = $dmarc.ContainsKey('p')
    if ($hasV -and $hasP) {
    $dmarcEnforced = $false
    if ($dmarcTxt) {
      $pMatch = [regex]::Match($dmarcTxt, '(?i)p\s*=\s*(quarantine|reject)')
      if ($pMatch.Success) {
        $dmarcEnforced = $true
      }
    }
    Write-Host "DMARC looks present with required tags (v & p)." -ForegroundColor Green
    if ($dmarcEnforced) {
      Write-Host "DMARC status: OK" -ForegroundColor Green
    } else {
      Write-Host "DMARC status: FAIL" -ForegroundColor Red
    }
    $pNoneMatch = [regex]::Match($dmarcTxt, '(?i)p\s*=\s*none')
    if ($pNoneMatch.Success) {
      Write-Host "Warning: DMARC is in testing mode only (p=none) and not enforced." -ForegroundColor Yellow
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
  Write-Host "No TLS-RPT record found (optional but recommended)." -ForegroundColor Yellow
  Write-Host "TLS-RPT status: FAIL" -ForegroundColor Red
}

# Summary
Write-Section "Summary"
Write-Host "Tested domain: $Domain" -ForegroundColor White
$mtaStsReason = $null
if (-not $mtaStsBody) {
  $mtaStsReason = "No HTTPS policy found"
} elseif ($mode -and $mode -match '(?i)testing') {
  $mtaStsReason = "mode=testing"
}
$summary = [pscustomobject]@{
  Domain                 = $Domain
  MX_Records_Present     = [bool]$mxOk
  SPF_Present            = [bool](@($spfRecs).Count -gt 0)
  SPF_Healthy            = [bool]$spfHealthy
  SPF_SoftFail           = [bool]$spfSoftFail
  DKIM_ValidSelector     = [bool]$DKIM_AnySelector_Valid
  MTA_STS_DNS_Present    = [bool]$mtaStsTxt
  MTA_STS_Enforced       = [bool]$mtaStsEnforced
  MTA_STS_Reason         = $mtaStsReason
  DMARC_Present          = [bool]$dmarcTxt
  DMARC_Enforced         = [bool]$dmarcEnforced
  TLS_RPT_Present        = [bool]$tlsRptTxt
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
