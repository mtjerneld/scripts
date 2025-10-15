<#
.SYNOPSIS
    Analyzes domain relationships by testing variants and following redirects.

.DESCRIPTION
    This script discovers related domains by:
    - Testing domain variants (.se, .com, .no, .fi, .dk, .nu)
    - Resolving DNS records (A, AAAA, CNAME, NS)
    - Performing HTTP HEAD requests to detect redirects
    - Performing second-degree discovery (testing variants of discovered domains)
    - Matching domains based on: DNS records (IP, CNAME, NS), redirect patterns
    - Optionally adding discovered domains back to the input file

.PARAMETER InputFile
    Path to a newline-separated domain list. Lines starting with # are ignored.

.PARAMETER OutputCsv
    Optional CSV output path for full analysis results.

.PARAMETER TimeoutSeconds
    HTTP timeout in seconds (default: 5).

.PARAMETER UseParallel
    Run per-domain checks in parallel using Start-Job (child processes).

.PARAMETER AddMatches
    Automatically append newly found matches to the input file.

.PARAMETER PromptAddMatches
    Prompt before appending matches to the input file.

.PARAMETER DryRun
    Show what would be added without actually modifying the input file.

.EXAMPLE
    .\redirecttester.ps1 -InputFile domains.txt -AddMatches
    Tests domains and adds discovered matches to the input file.

.EXAMPLE
    .\redirecttester.ps1 -InputFile domains.txt -OutputCsv results.csv
    Tests domains and exports full analysis to CSV.

.EXAMPLE
    .\redirecttester.ps1 -InputFile domains.txt -AddMatches -OutputCsv results.csv -TimeoutSeconds 3
    Tests domains with 3-second timeout, adds matches, and exports CSV.

.NOTES
    - Designed for PowerShell 5.1. Uses Start-Job for parallel execution.
    - DNS lookups use Resolve-DnsName if available; falls back to [System.Net.Dns].
    - Match types: Original domain, DNS match, RedirectBack, Discovered redirect, Variant match
    - Second-degree discovery automatically tests variants of discovered domains.
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$InputFile,

    [Parameter(Mandatory=$false)]
    [string]$OutputCsv,

    [int]$TimeoutSeconds = 5,

    [switch]$UseParallel,

    # Optionally add detected likely matches back into the input file
    [switch]$PromptAddMatches,
    [switch]$AddMatches,
    [switch]$DryRun,
    [switch]$Help,

    # Child-mode parameters (used when launching parallel child processes)
    [switch]$Child,
    [string]$ChildBaseDomain,
    [string]$ChildOut
)

# Domain suffixes to test
$Suffixes = @('.se', '.com', '.no', '.fi', '.dk', '.nu')

if ($Help) {
    Write-Host "redirecttester.ps1 - Domain relationship analyzer"
    Write-Host ""
    Write-Host "DESCRIPTION:"
    Write-Host "  Discovers related domains by testing variants (.se, .com, .no, .fi, .dk, .nu),"
    Write-Host "  analyzing DNS records (A, AAAA, CNAME, NS), following redirects, and performing"
    Write-Host "  second-degree discovery on found domains."
    Write-Host ""
    Write-Host "USAGE:"
    Write-Host "  .\redirecttester.ps1 -InputFile <path> [-OutputCsv <path>] [-AddMatches] [options]"
    Write-Host ""
    Write-Host "PARAMETERS:"
    Write-Host "  -InputFile <path>      Path to newline-separated domain list (# for comments)"
    Write-Host "  -OutputCsv <path>      Optional: Export full analysis to CSV"
    Write-Host "  -AddMatches            Automatically append discovered domains to input file"
    Write-Host "  -PromptAddMatches      Prompt before appending matches"
    Write-Host "  -DryRun                Show what would be added without modifying file"
    Write-Host "  -TimeoutSeconds <n>    HTTP timeout in seconds (default: 5)"
    Write-Host "  -UseParallel           Run checks in parallel using background jobs"
    Write-Host "  -Help                  Show this help"
    Write-Host ""
    Write-Host "EXAMPLES:"
    Write-Host "  .\redirecttester.ps1 -InputFile domains.txt -AddMatches"
    Write-Host "  .\redirecttester.ps1 -InputFile domains.txt -OutputCsv results.csv"
    Write-Host "  .\redirecttester.ps1 -InputFile domains.txt -AddMatches -TimeoutSeconds 3"
    Write-Host ""
    Write-Host "MATCH TYPES:"
    Write-Host "  Original domain     - Redirect from input domain to this target"
    Write-Host "  DNS match           - Variant shares DNS records (IP, CNAME, or NS)"
    Write-Host "  RedirectBack        - Variant redirects back to base domain"
    Write-Host "  Discovered redirect - Second-degree match from discovered domain"
    Write-Host "  Variant match       - Variant has DNS match or redirects back"
    Write-Host ""
    Write-Host "FEATURES:"
    Write-Host "  • Second-degree discovery: Automatically tests variants of discovered domains"
    Write-Host "  • DNS matching: Compares A, AAAA, CNAME, and NS records (requires 2+ NS matches)"
    Write-Host "  • Smart filtering: Excludes self-redirects and unrelated external redirects"
    Write-Host "  • Progress tracking: Shows real-time progress for both discovery rounds"
    Write-Host ""
    exit 0
}

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
            if ($null -ne $resp) { $resp.Close() }
            return [PSCustomObject]@{ Status = $status; Location = $loc }
        }
        return [PSCustomObject]@{ Status = $null; Location = $null }
    }
    catch {
        return [PSCustomObject]@{ Status = $null; Location = $null }
    }
}

function Get-BaseDomainAnalysis {
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

        # Compare DNS: any overlapping A/AAAA, same CNAME host, or matching NS records
        $dnsMatch = $false
        if (($dns.A | Where-Object { $baseRecords.A -contains $_ }) -or ($dns.AAAA | Where-Object { $baseRecords.AAAA -contains $_ })) { $dnsMatch = $true }
        if (-not $dnsMatch) {
            foreach ($c in $dns.CNAME) { if ($baseRecords.CNAME -contains $c) { $dnsMatch = $true; break } }
        }
        if (-not $dnsMatch) {
            # Check if NS records match (need at least 2 matching nameservers to consider it a match)
            $matchingNS = $dns.NS | Where-Object { $baseRecords.NS -contains $_ }
            if ($matchingNS -and $matchingNS.Count -ge 2) { $dnsMatch = $true }
        }

        # Determine MatchType
        # Check if redirect target hostname matches the base domain (not just contains the name)
        $redirectsToBase = $false
        if ($redirectTarget) {
            try {
                $targetUri = [Uri]$redirectTarget
                $targetHost = ($targetUri.Host -replace '^www\.', '').Trim().ToLower()
                $baseHost = ($baseName -replace '^www\.', '').Trim().ToLower()
                if ($targetHost -eq $baseHost) {
                    $redirectsToBase = $true
                }
            } catch { }
        }
        
        if ($redirectsToBase) {
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
    $res = Get-BaseDomainAnalysis -BaseDomain $ChildBaseDomain
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
    # Sequential mode with progress reporting
    for ($i = 0; $i -lt $domains.Count; $i++) {
        $d = $domains[$i]
        $percent = [int](($i / $domains.Count) * 100)
        Write-Progress -Activity "Analyzing domains" -Status ("{0}/{1} - {2}" -f ($i+1), $domains.Count, $d) -PercentComplete $percent

        $res = Get-BaseDomainAnalysis -BaseDomain $d
        $allResults += $res
    }

    # Clear progress
    Write-Progress -Activity "Analyzing domains" -Completed -Status "Done"
}

### Second-degree discovery: test variants of redirect targets and DNS-matched variants
Write-Host "Performing second-degree discovery (testing variants of discovered domains)..."

# Get all tested domains so far
$testedDomains = $allResults | Select-Object -ExpandProperty BaseDomain -Unique | ForEach-Object { ($_ -replace '^www\.', '').Trim().ToLower() }

# Find discovered domains from the first round (both redirect targets AND DNS/RedirectBack matches)
$firstRoundDiscoveries = @()

# 1. Find redirect targets (excluding self-redirects and unrelated redirects)
foreach ($row in $allResults) {
    if ($row.RedirectTarget -and $row.MatchType -ne 'Unrelated') {
        try {
            $u = [Uri]$row.RedirectTarget
            if ($u.Host) {
                $normalizedHost = ($u.Host -replace '^www\.', '').Trim().ToLower()
                $normalizedVariant = ($row.Variant -replace '^www\.', '').Trim().ToLower()
                $normalizedBase = ($row.BaseDomain -replace '^www\.', '').Trim().ToLower()
                
                # Only include redirect targets from:
                # - Original domains (base domain is in original input AND variant equals base)
                # - Variants with DNS match or RedirectBack
                $isOriginalDomainVariant = ($originalDomains -contains $normalizedBase) -and ($normalizedVariant -eq $normalizedBase)
                
                # Skip self-redirects and only include if it's from original domain or has relationship
                if ($normalizedHost -ne $normalizedVariant -and $testedDomains -notcontains $normalizedHost -and $isOriginalDomainVariant) {
                    $firstRoundDiscoveries += $normalizedHost
                }
            }
        } catch { }
    }
}

# 2. Find variants with DNS matches or RedirectBack
$variantMatches = $allResults | 
    Where-Object { $_.MatchType -in @('RedirectBack','SameDNS') } | 
    Select-Object -ExpandProperty Variant | 
    ForEach-Object { ($_ -replace '^www\.', '').Trim().ToLower() } |
    Where-Object { $testedDomains -notcontains $_ }

$firstRoundDiscoveries = @($firstRoundDiscoveries + $variantMatches) | Select-Object -Unique

if ($firstRoundDiscoveries -and $firstRoundDiscoveries.Count -gt 0) {
    Write-Host "Testing variants of $($firstRoundDiscoveries.Count) discovered domain(s)..."
    
    for ($i = 0; $i -lt $firstRoundDiscoveries.Count; $i++) {
        $discoveredDomain = $firstRoundDiscoveries[$i]
        $percent = [int](($i / $firstRoundDiscoveries.Count) * 100)
        Write-Progress -Activity "Second-degree discovery" -Status ("{0}/{1} - {2}" -f ($i+1), $firstRoundDiscoveries.Count, $discoveredDomain) -PercentComplete $percent
        
        $res = Get-BaseDomainAnalysis -BaseDomain $discoveredDomain
        $allResults += $res
    }
    
    Write-Progress -Activity "Second-degree discovery" -Completed -Status "Done"
    Write-Host "Second-degree discovery complete. Found additional variants."
}

# For the redirect detail collection later, we need to track what was discovered
$firstRoundRedirects = $firstRoundDiscoveries

# Export CSV (only if specified)
if ($OutputCsv) {
    $allResults | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    Write-Host "Results exported to $OutputCsv"
}

### Optional: collect likely matches and optionally append to input file
# First, get the list of domains that were in the original input file (non-commented lines)
$originalDomains = Get-Content $InputFile | 
    Where-Object { $_ -and ($_ -notmatch '^#') -and ($_ -notmatch '^\s*$') } | 
    ForEach-Object { ($_.Trim() -replace '^www\.', '').ToLower() } | 
    Select-Object -Unique

# Include Variants with desirable MatchTypes
$normVariantMatches = $allResults | 
    Where-Object { $_.MatchType -in @('RedirectBack','SameDNS') } | 
    Select-Object -ExpandProperty Variant | 
    ForEach-Object { ($_ -replace '^www\.', '').Trim().ToLower() } |
    Select-Object -Unique

# Extract redirect target hostnames with proper filtering:
# - If the variant IS the original domain that was in input file → include its redirects
# - If the variant IS a discovered redirect target (second-degree) → include its redirects if DNS match
# - If the variant has a DNS match with the base → include its redirects
# - If the variant redirects back to the base → include its redirects
$redirectDetails = @()
foreach ($row in $allResults) {
    if ($row.RedirectTarget) {
        $normalizedBase = ($row.BaseDomain -replace '^www\.', '').Trim().ToLower()
        $normalizedVariant = ($row.Variant -replace '^www\.', '').Trim().ToLower()
        
        # Check if this variant IS the base domain (meaning it was in original input OR discovered redirect target)
        $isOriginalDomain = ($originalDomains -contains $normalizedBase) -and ($normalizedVariant -eq $normalizedBase)
        $isDiscoveredRedirect = ($firstRoundRedirects -contains $normalizedBase) -and ($normalizedVariant -eq $normalizedBase)
        
        # Determine match reason
        # Only include redirects that indicate a real relationship, not random external redirects
        $reason = $null
        if ($isOriginalDomain -and ($row.MatchType -ne 'Unrelated')) { 
            # Original domain redirect, but only if there's some indication of relationship
            # (DNS match, or it's the base domain testing itself which might redirect to canonical URL)
            $reason = "Original domain" 
        }
        elseif ($isDiscoveredRedirect -and ($row.DNSMatch -eq $true -or $row.MatchType -eq 'RedirectBack')) { 
            $reason = "Discovered redirect" 
        }
        elseif ($row.MatchType -eq 'RedirectBack') { $reason = "RedirectBack" }
        elseif ($row.DNSMatch -eq $true) { $reason = "DNS match" }
        
        # Include redirect if we have a valid reason
        if ($reason) {
            try {
                $u = [Uri]$row.RedirectTarget
                if ($u.Host) {
                    # normalize by stripping leading www.
                    $normalizedHost = ($u.Host -replace '^www\.', '').Trim().ToLower()
                    
                    # Skip self-redirects (e.g., missionpoint.com → https://missionpoint.com/)
                    if ($normalizedHost -ne $normalizedVariant) {
                        $redirectDetails += [PSCustomObject]@{
                            Host = $normalizedHost
                            Reason = $reason
                            Variant = $row.Variant
                        }
                    }
                }
            } catch {
                # ignore unparsable URLs
            }
        }
    }
}

# Get unique hosts for the actual list
$normRedirectHosts = $redirectDetails | Select-Object -ExpandProperty Host -Unique

# Merge variants and redirects into likelyMatches for later filtering
$likelyMatches = @($normVariantMatches + $normRedirectHosts) | Select-Object -Unique

    if ($likelyMatches -and $likelyMatches.Count -gt 0) {
        # Extract existing domains from input file, considering both commented and non-commented lines
        try {
            $existing = Get-Content $InputFile |
                Where-Object { $_ -and ($_ -notmatch '^\s*$') } |
                ForEach-Object { ($_ -replace '^\s*#\s*','').Trim() -replace '^www\.', '' } |
                ForEach-Object { $_.ToLower() } |
                Where-Object { $_ } |
                Select-Object -Unique
        } catch {
            $existing = @()
        }

        # First build $newMatches from variant matches that aren't already in input file
        $newMatches = $normVariantMatches | Where-Object { $existing -notcontains $_ }

        # When AddMatches is true, ALWAYS include redirect hosts that aren't in input file yet
        if ($AddMatches -and $normRedirectHosts) {
            $redirectsToAdd = $normRedirectHosts | Where-Object { $existing -notcontains $_ }
            if ($redirectsToAdd) {
                $newMatches = @($newMatches + $redirectsToAdd) | Select-Object -Unique
            }
        }
        
        # Build table of all new matches with reasons
        $matchesTable = @()
        foreach ($match in $newMatches) {
            # Check if it's a redirect target
            $detail = $redirectDetails | Where-Object { $_.Host -eq $match } | Select-Object -First 1
            if ($detail) {
                # Get primary reason and trace back to the original input domain (BaseDomain)
                $primaryReason = ($redirectDetails | Where-Object { $_.Host -eq $match } | Select-Object -First 1).Reason
                $variant = ($redirectDetails | Where-Object { $_.Host -eq $match } | Select-Object -First 1).Variant
                # Find the BaseDomain for this variant from $allResults
                $baseDomain = ($allResults | Where-Object { $_.Variant -eq $variant } | Select-Object -First 1).BaseDomain
                $matchesTable += [PSCustomObject]@{
                    Domain = $match
                    Reason = $primaryReason
                    From = $baseDomain
                }
            } else {
                # It's a variant match - find which base domain it's a variant of
                $variantRow = $allResults | Where-Object { 
                    $normalizedVariant = ($_.Variant -replace '^www\.', '').Trim().ToLower()
                    $normalizedVariant -eq $match 
                } | Select-Object -First 1
                $baseDomain = if ($variantRow) { $variantRow.BaseDomain } else { "-" }
                $matchesTable += [PSCustomObject]@{
                    Domain = $match
                    Reason = "Variant match"
                    From = $baseDomain
                }
            }
        }
        
    if ($newMatches -and $newMatches.Count -gt 0) {
        Write-Host "`nAdding $($newMatches.Count) new domain(s):"
        $matchesTable | Format-Table -Property Domain, Reason, From -AutoSize | Out-String | Write-Host
        
        Write-Host "Legend:"
        Write-Host "  Original domain     - Domain redirects to this target (discovered from original input domain)"
        Write-Host "  Discovered redirect - Variant of a redirect target with DNS match (second-degree discovery)"
        Write-Host "  DNS match           - Variant has matching DNS records with the base domain"
        Write-Host "  RedirectBack        - Variant redirects back to the base domain"
        Write-Host "  Variant match       - Variant has matching DNS or redirects back to base"
        Write-Host ""

        # Decide whether to add (or just show what would be added)
        $doAdd = $false
        if ($DryRun) {
            Write-Host "`nDry run mode - would append these matches to ${InputFile}:"
            Write-Host "# Added matches (example timestamp)"
            foreach ($m in $newMatches) { Write-Host $m }
            Write-Host "`nRun without -DryRun to actually append these matches."
        }
        else {
            if ($AddMatches) { $doAdd = $true }
            elseif ($PromptAddMatches) {
                $ans = Read-Host ("Add these to ${InputFile}? (Y/N)")
                $doAdd = ($ans -match '^[Yy]')
            }

            if ($doAdd) {
                Add-Content -Path $InputFile -Value ""
                # Only comment the heading/separator line, add matches as plain domain lines
                Add-Content -Path $InputFile -Value ("# Added matches {0}" -f (Get-Date -Format o))
                foreach ($m in $newMatches) { Add-Content -Path $InputFile -Value ($m) }
                Write-Host ("Appended $($newMatches.Count) matches to ${InputFile} (heading commented).")
            }
            else {
                if ($PromptAddMatches) { Write-Host "No matches added." }
            }
        }
    }
}

Write-Host "Done. Analyzed $($allResults.Count) variant(s)."
