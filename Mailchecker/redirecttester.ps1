<#
redirecttester.ps1

PowerShell 5.1 prototype to analyze domain-brand relations by:
- generating domain variants (.se, .com, .no, .fi, .dk)
- resolving A, AAAA, CNAME records
- performing HTTP HEAD requests to detect redirects
- scoring matches: RedirectBack, SameDNS, Unrelated
- exporting results to CSV

Usage:
.
  .\redirecttester.ps1 -InputFile domains.txt -OutputCsv results.csv -TimeoutSeconds 5 -UseParallel:$true

Notes:
- Designed for PowerShell 5.1. Uses Start-Job for simple concurrency.
- DNS lookups use Resolve-DnsName if available; falls back to [System.Net.Dns] for A records.
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$InputFile,

    [Parameter(Mandatory=$false)]
    [string]$OutputCsv = "results.csv",

    [int]$TimeoutSeconds = 5,

    [switch]$UseParallel,

    # Child-mode parameters (used when launching parallel child processes)
    [switch]$Child,
    [string]$ChildBaseDomain,
    [string]$ChildOut
)

# Domain suffixes to test
$Suffixes = @('.se', '.com', '.no', '.fi', '.dk')

function Get-DnsRecords {
    param(
        [Parameter(Mandatory=$true)] [string]$Domain
    )

    # In-memory cache (process lifetime)
    if (-not $script:DnsCache) { $script:DnsCache = @{} }
    if ($script:DnsCache.ContainsKey($Domain)) { return $script:DnsCache[$Domain] }

    $result = [PSCustomObject]@{
        Domain = $Domain
        A = @()
        AAAA = @()
        CNAME = @()
        NS = @()
    }

    try {
        if (Get-Command -Name Resolve-DnsName -ErrorAction SilentlyContinue) {
            # A
            try { $a = Resolve-DnsName -Name $Domain -Type A -ErrorAction Stop } catch { $a = $null }
            if ($a) { $result.A = ($a | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress) }

            # AAAA
            try { $aaaa = Resolve-DnsName -Name $Domain -Type AAAA -ErrorAction Stop } catch { $aaaa = $null }
            if ($aaaa) { $result.AAAA = ($aaaa | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress) }

            # CNAME
            try { $c = Resolve-DnsName -Name $Domain -Type CNAME -ErrorAction Stop } catch { $c = $null }
            if ($c) {
                # Resolve-DnsName can return different property names depending on platform/version.
                $names = @()
                foreach ($item in $c) {
                    if ($item.PSObject.Properties.Name -contains 'NameHost') { $names += $item.NameHost }
                    elseif ($item.PSObject.Properties.Name -contains 'NameTarget') { $names += $item.NameTarget }
                    elseif ($item.PSObject.Properties.Name -contains 'Target') { $names += $item.Target }
                }
                $result.CNAME = $names | Where-Object { $_ } | Select-Object -Unique
            }

            # NS
            try { $ns = Resolve-DnsName -Name $Domain -Type NS -ErrorAction Stop } catch { $ns = $null }
            if ($ns) {
                $nsnames = @()
                foreach ($item in $ns) {
                    if ($item.PSObject.Properties.Name -contains 'NameHost') { $nsnames += $item.NameHost }
                    elseif ($item.PSObject.Properties.Name -contains 'NameServer') { $nsnames += $item.NameServer }
                    elseif ($item.PSObject.Properties.Name -contains 'Name') { $nsnames += $item.Name }
                }
                $result.NS = $nsnames | Where-Object { $_ } | Select-Object -Unique
            }
        }
        else {
            # Fallback: limited A record via System.Net.Dns
            try { $ips = [System.Net.Dns]::GetHostAddresses($Domain) } catch { $ips = @() }
            if ($ips) {
                $result.A = $ips | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.ToString() }
                $result.AAAA = $ips | Where-Object { $_.AddressFamily -eq 'InterNetworkV6' } | ForEach-Object { $_.ToString() }
            }
        }
    }
    catch {
        # swallow; keep empty arrays
    }

    $script:DnsCache[$Domain] = $result
    return $result
}

function Invoke-HeadRequest {
    param(
        [Parameter(Mandatory=$true)] [string]$Url,
        [int]$Timeout = 5
    )

    # Use System.Net.HttpWebRequest for PS5 compatibility
    try {
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Method = 'HEAD'
        $request.Timeout = $Timeout * 1000
        $request.AllowAutoRedirect = $false

        $response = $request.GetResponse()
        $status = [int]$response.StatusCode
        $loc = $null
        try { $loc = $response.Headers['Location'] } catch { }
        $response.Close()
        return [PSCustomObject]@{ Status = $status; Location = $loc }
    }
    catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if ($resp) {
            $status = 0
            try { $status = [int]$resp.StatusCode } catch { }
            $loc = $null
            try { $loc = $resp.Headers['Location'] } catch { }
            if ($resp -ne $null) { $resp.Close() }
            return [PSCustomObject]@{ Status = $status; Location = $loc }
        }
        return [PSCustomObject]@{ Status = $null; Location = $null }
    }
    catch {
        return [PSCustomObject]@{ Status = $null; Location = $null }
    }
}

function Analyze-BaseDomain {
    param(
        [Parameter(Mandatory=$true)] [string]$BaseDomain
    )

    $baseName = $BaseDomain -replace '^www\.', ''
    $baseRecords = Get-DnsRecords -Domain $baseName

    $rows = @()

    foreach ($suf in $Suffixes) {
        # build variant; if base already has suffix, replace
        $nameOnly = $baseName -replace '\.[^.]+$',''
        $variant = "$nameOnly$suf"

        $dns = Get-DnsRecords -Domain $variant

        # HTTP test
        $urlsToTry = @("http://$variant/", "https://$variant/")
        $redirectTarget = $null
        $status = $null

        foreach ($u in $urlsToTry) {
            $r = Invoke-HeadRequest -Url $u -Timeout $TimeoutSeconds
            if ($r -and $r.Status) {
                $status = $r.Status
                if ($r.Location) { $redirectTarget = $r.Location; break }
            }
        }

        # Compare DNS: any overlapping A/AAAA or same CNAME host
        $dnsMatch = $false
        if (($dns.A | Where-Object { $baseRecords.A -contains $_ }) -or ($dns.AAAA | Where-Object { $baseRecords.AAAA -contains $_ })) { $dnsMatch = $true }
        if (-not $dnsMatch) {
            foreach ($c in $dns.CNAME) { if ($baseRecords.CNAME -contains $c) { $dnsMatch = $true; break } }
        }

        # Determine MatchType
        if ($redirectTarget -and ($redirectTarget -like "*${baseName}*")) {
            $match = 'RedirectBack'
        }
        elseif ($dnsMatch) { $match = 'SameDNS' }
        else { $match = 'Unrelated' }

        $rows += [PSCustomObject]@{
            BaseDomain = $baseName
            Variant = $variant
            RedirectTarget = $redirectTarget
            HttpStatus = $status
            # Use colon as internal separator to avoid Excel interpreting semicolons as column delimiters
            DNS_A = ($dns.A -join ':')
            DNS_AAAA = ($dns.AAAA -join ':')
            DNS_CNAME = ($dns.CNAME -join ':')
            DNS_NS = ($dns.NS -join ':')
            DNSMatch = $dnsMatch
            MatchType = $match
        }
    }

    return $rows
}

# Read input
if ($Child) {
    if (-not $ChildBaseDomain) { throw "ChildBaseDomain must be provided in Child mode" }
    $res = Analyze-BaseDomain -BaseDomain $ChildBaseDomain
    if (-not $ChildOut) { Write-Host (ConvertTo-Json $res); exit 0 }
    $res | ConvertTo-Json -Depth 5 | Set-Content -Path $ChildOut -Encoding UTF8
    exit 0
}

if (-not $InputFile) { throw "InputFile parameter is required when not running in Child mode." }
if (-not (Test-Path $InputFile)) { throw "Input file not found: $InputFile" }

$domains = Get-Content $InputFile | Where-Object { $_ -and ($_ -notmatch '^#') } | ForEach-Object { $_.Trim() }

$allResults = @()

if ($UseParallel) {
    # Use Start-Job to spawn child PowerShell processes that run this script in -Child mode.
    # Each child writes its JSON result to a temp file which the parent collects.
    $jobs = @()
    $tempFiles = @()

    foreach ($d in $domains) {
        $tmp = [System.IO.Path]::GetTempFileName() + '.json'
        $tempFiles += $tmp

        $scriptPath = (Get-Item -LiteralPath $PSCommandPath).FullName

        $arg = "-NoProfile -File `"$scriptPath`" -Child -ChildBaseDomain `"$d`" -ChildOut `"$tmp`" -TimeoutSeconds $TimeoutSeconds"

        $jobs += Start-Job -ScriptBlock { param($a) & powershell.exe $a } -ArgumentList $arg
    }

    Wait-Job -Job $jobs | Out-Null

    foreach ($tmp in $tempFiles) {
        if (Test-Path $tmp) {
            try {
                $json = Get-Content $tmp -Raw
                $items = ConvertFrom-Json $json
                $allResults += $items
            } catch {
                Write-Warning ("Failed reading JSON from {0}: {1}" -f $tmp, $_)
            } finally {
                Remove-Item $tmp -ErrorAction SilentlyContinue
            }
        }
    }

    # Clean up jobs
    $jobs | Remove-Job -Force
}
else {
    foreach ($d in $domains) {
        $res = Analyze-BaseDomain -BaseDomain $d
        $allResults += $res
    }
}

# Export CSV
$allResults | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8

Write-Host "Done. Results written to $OutputCsv. Rows: $($allResults.Count)"
