#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][switch]$Help,
    [Parameter(Mandatory = $false)][string]$FirstFile,
    [Parameter(Mandatory = $false)][string]$LastFile
)

function Show-Usage {
    Write-Host "Usage: .\statusupdate.ps1 -FirstFile <path> -LastFile <path>" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Compares two Mailchecker bulk-results CSVs and prints per-domain diffs." -ForegroundColor Gray
    Write-Host ""
    Write-Host "Parameters:" -ForegroundColor Gray
    Write-Host "  -FirstFile    Path to older CSV (e.g., .\\Statusupdate\\bulk-results-20251021-185735.csv)" -ForegroundColor Gray
    Write-Host "  -LastFile     Path to newer CSV (e.g., .\\Statusupdate\\bulk-results-20251029-101246.csv)" -ForegroundColor Gray
    Write-Host "  -Help         Show this help and exit" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Output:" -ForegroundColor Gray
    Write-Host "  Table with columns: Domain, Category, Change, Trend, StatusChange, Details" -ForegroundColor Gray
    Write-Host "  StatusChange colors: FAIL (red), WARN (yellow), PASS (green), N/A (dark gray)" -ForegroundColor Gray
    Write-Host "" 
    Write-Host "Example:" -ForegroundColor Gray
    Write-Host "  .\\statusupdate.ps1 -FirstFile .\\Statusupdate\\bulk-results-20251021-185735.csv -LastFile .\\Statusupdate\\bulk-results-20251029-101246.csv" -ForegroundColor Gray
}

if ($Help) { Show-Usage; exit 0 }

if (-not $FirstFile -or -not $LastFile) {
    Show-Usage
    exit 1
}

function Write-ErrorAndExit([string]$message, [int]$code = 1) {
    Write-Error $message
    exit $code
}

if (-not (Test-Path -LiteralPath $FirstFile)) {
    Write-ErrorAndExit "First file not found: $FirstFile"
}
if (-not (Test-Path -LiteralPath $LastFile)) {
    Write-ErrorAndExit "Last file not found: $LastFile"
}

function Import-BulkCsv([string]$path) {
    try {
        $rows = Import-Csv -LiteralPath $path -Delimiter ','
    } catch {
        Write-ErrorAndExit "Failed to read CSV: $path. $_"
    }
    if ($rows -and ($rows[0].PSObject.Properties.Name -contains 'Domain')) {
        return $rows
    }
    # Fallback: normalize doubled quotes and strip wrapping quotes per line
    try {
        $lines = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-ErrorAndExit "Failed to read file content: $path. $_"
    }
    if (-not $lines) { return $rows }
    $normalized = New-Object System.Text.StringBuilder
    foreach ($line in ($lines -split "`r?`n")) {
        if ($null -eq $line) { continue }
        $l = $line.Replace('""','"')
        if ($l.Length -ge 2 -and $l.StartsWith('"') -and $l.EndsWith('"')) {
            $l = $l.Substring(1, $l.Length - 2)
        }
        [void]$normalized.AppendLine($l)
    }
    $fixedText = $normalized.ToString()
    try {
        $rows2 = $fixedText | ConvertFrom-Csv -Delimiter ','
    } catch {
        # If even fallback fails, return original attempt
        return $rows
    }
    return $rows2
}

$firstRows = Import-BulkCsv -path $FirstFile
$lastRows  = Import-BulkCsv -path $LastFile

if (-not $firstRows -and -not $lastRows) {
    Write-Output "Both CSV files are empty. Nothing to compare."
    exit 0
}

function Get-NormalizedText([object]$value) {
    if ($null -eq $value) { return '' }
    $text = [string]$value
    $text = $text.Trim()
    return $text
}

function Get-Severity([string]$status) {
    $s = (Get-NormalizedText $status).ToUpperInvariant()
    switch ($s) {
        'FAIL' { return 0 }
        'WARN' { return 1 }
        'PASS' { return 2 }
        default { return -1 }
    }
}

function Is-BooleanEquivalent([string]$a, [string]$b) {
    $na = (Get-NormalizedText $a).ToLowerInvariant()
    $nb = (Get-NormalizedText $b).ToLowerInvariant()
    $map = @{ 'true' = 'true'; 'false' = 'false' }
    if ($map.ContainsKey($na)) { $na = $map[$na] }
    if ($map.ContainsKey($nb)) { $nb = $map[$nb] }
    return $na -eq $nb
}

# Build domain -> row maps
$firstByDomain = @{}
foreach ($row in $firstRows) {
    $key = (Get-NormalizedText $row.Domain).ToLowerInvariant()
    if ($key) { $firstByDomain[$key] = $row }
}
$lastByDomain = @{}
foreach ($row in $lastRows) {
    $key = (Get-NormalizedText $row.Domain).ToLowerInvariant()
    if ($key) { $lastByDomain[$key] = $row }
}

$allDomains = New-Object System.Collections.Generic.HashSet[string]
foreach ($k in $firstByDomain.Keys) { [void]$allDomains.Add($k) }
foreach ($k in $lastByDomain.Keys) { [void]$allDomains.Add($k) }
$sortedDomains = $allDomains | Sort-Object

# Fields to compare
$statusFields = @('Status','SPF_Status','DKIM_Status','DMARC_Status','MTA_STS_Status','TLS_RPT_Status')
$reasonFields = @('SPF_Reason','DKIM_Reason','DMARC_Reason','MTA_STS_Reason','TLS_RPT_Reason')
$primaryFields = @('MX_Records') + $statusFields
$flagFields = @('SPF_Present','SPF_Healthy','DKIM_ValidSelector','MTA_STS_DNS_Present','MTA_STS_Enforced','DMARC_Present','DMARC_Enforced','TLS_RPT_Present')
$reasonByStatus = @{
    'SPF_Status'    = 'SPF_Reason'
    'DKIM_Status'   = 'DKIM_Reason'
    'DMARC_Status'  = 'DMARC_Reason'
    'MTA_STS_Status'= 'MTA_STS_Reason'
    'TLS_RPT_Status'= 'TLS_RPT_Reason'
}

# Counters
$countNew = 0
$countRemoved = 0
$countImproved = 0
$countRegressed = 0
$countChanged = 0

# Collect rows for pretty output
$rowsOut = New-Object System.Collections.Generic.List[object]

Write-Output ("Comparing:`n  First: {0}`n  Last:  {1}`n" -f $FirstFile, $LastFile)

foreach ($domainKey in $sortedDomains) {
    $first = $firstByDomain[$domainKey]
    $last  = $lastByDomain[$domainKey]

    if ($null -eq $first -and $null -ne $last) {
        $countNew++
        $disp = $last.Domain
        $status = Get-NormalizedText $last.Status
        $mx = Get-NormalizedText $last.MX_Records
        $rowsOut.Add([pscustomobject]@{ Domain = $disp; Category = 'DOMAIN'; Change = 'NEW'; Trend = 'Neutral'; Details = 'Domain added' })
        continue
    }
    if ($null -ne $first -and $null -eq $last) {
        $countRemoved++
        $disp = $first.Domain
        $rowsOut.Add([pscustomobject]@{ Domain = $disp; Category = 'DOMAIN'; Change = 'REMOVED'; Trend = 'Neutral'; Details = 'Domain removed' })
        continue
    }
    if ($null -eq $first -and $null -eq $last) { continue }

    $dispDomain = $last.Domain
    # Collect changes per category
    $changesByCategory = @{}
    $catStatusChange = @{}      # category -> "OLD->NEW"
    $catStatusNew = @{}         # category -> NEW status string
    $improveDelta = 0
    $regressDelta = 0

    foreach ($field in $primaryFields + $flagFields + $reasonFields) {
        $a = Get-NormalizedText $first.$field
        $b = Get-NormalizedText $last.$field

        $different = $false
        if ($flagFields -contains $field) {
            $different = -not (Is-BooleanEquivalent $a $b)
        } else {
            $different = ($a -ne $b)
        }

        if ($different) {
            # Determine category
            $category = 'General'
            if ($field -like 'SPF_*') { $category = 'SPF' }
            elseif ($field -like 'DKIM_*') { $category = 'DKIM' }
            elseif ($field -like 'DMARC_*') { $category = 'DMARC' }
            elseif ($field -like 'MTA_STS_*') { $category = 'MTA-STS' }
            elseif ($field -like 'TLS_RPT_*') { $category = 'TLS-RPT' }
            elseif ($field -eq 'MX_Records') { $category = 'MX' }
            elseif ($field -eq 'Status') { $category = 'Overall' }

            if ($statusFields -contains $field) {
                $sa = Get-Severity $a
                $sb = Get-Severity $b
                if ($sa -ge 0 -and $sb -ge 0) {
                    if ($sb -gt $sa) { $improveDelta++ }
                    elseif ($sb -lt $sa) { $regressDelta++ }
                }
                # Record status change for category
                $catStatusChange[$category] = ("{0}->{1}" -f $a, $b)
                $catStatusNew[$category] = $b
                if ($reasonByStatus.ContainsKey($field)) {
                    $reasonField = $reasonByStatus[$field]
                    $ra = Get-NormalizedText $first.$reasonField
                    $rb = Get-NormalizedText $last.$reasonField
                    if ($ra -or $rb) {
                        $msg = ("{0} '{1}'->'{2}'" -f $reasonField, $ra, $rb)
                        if (-not $changesByCategory.ContainsKey($category)) { $changesByCategory[$category] = @() }
                        $changesByCategory[$category] += $msg
                        continue
                    }
                }
            }
            if ($reasonFields -contains $field) {
                # Avoid duplicate reason lines if status already changed for the same category
                if ($catStatusChange.ContainsKey($category)) { continue }
            }
            $msg2 = if ($reasonFields -contains $field) { ("{0} '{1}'->'{2}'" -f $field, $a, $b) } else { ("{0} {1}->{2}" -f $field, $a, $b) }
            if (-not $changesByCategory.ContainsKey($category)) { $changesByCategory[$category] = @() }
            $changesByCategory[$category] += $msg2
        }
    }

    if ($changesByCategory.Keys.Count -gt 0) {
        $countChanged++
        $domainTrend = 'Neutral'
        if ($improveDelta -gt 0 -and $regressDelta -eq 0) { $domainTrend = 'Improved'; $countImproved++ }
        elseif ($regressDelta -gt 0 -and $improveDelta -eq 0) { $domainTrend = 'Regressed'; $countRegressed++ }
        elseif ($regressDelta -gt 0 -and $improveDelta -gt 0) { $domainTrend = 'Mixed' }
        foreach ($cat in ($changesByCategory.Keys | Sort-Object)) {
            $details = [string]::Join('; ', $changesByCategory[$cat])
            $statusChange = ($catStatusChange[$cat] | ForEach-Object { $_ })
            $newStatus = ($catStatusNew[$cat] | ForEach-Object { $_ })
            $statusText = if ($null -ne $statusChange -and $statusChange -ne '') { $statusChange } else { '' }
            $rowsOut.Add([pscustomobject]@{ Domain = $dispDomain; Category = $cat; Change = 'CHANGED'; Trend = $domainTrend; StatusChange = $statusText; Details = $details; NewStatus = $newStatus })
        }
    }
}

# Pretty print table with colors
Write-Output ""
if ($rowsOut.Count -eq 0) {
    Write-Host "No differences found." -ForegroundColor Green
} else {
    $domainWidth = 28
    $categoryWidth = 10
    $changeWidth = 9
    $trendWidth = 9
    $statusWidth = 13
    $detailsWidth = 60
    $header = ("{0,-$domainWidth} {1,-$categoryWidth} {2,-$changeWidth} {3,-$trendWidth} {4,-$statusWidth} {5}" -f 'Domain','Category','Change','Trend','StatusChange','Details')
    Write-Host $header -ForegroundColor Cyan
    Write-Host ('-' * [Math]::Min(120, $header.Length + 20)) -ForegroundColor DarkCyan

    function Get-RowColor([string]$change, [string]$trend) {
        $c = (Get-NormalizedText $change).ToUpperInvariant()
        $t = (Get-NormalizedText $trend).ToUpperInvariant()
        switch ($c) {
            'NEW' { return 'Blue' }
            'REMOVED' { return 'Magenta' }
            default {
                switch ($t) {
                    'IMPROVED' { return 'Green' }
                    'REGRESSED' { return 'Red' }
                    'MIXED' { return 'Yellow' }
                    default { return 'Gray' }
                }
            }
        }
    }

    function Get-StatusColor([string]$status) {
        $s = (Get-NormalizedText $status).ToUpperInvariant()
        switch ($s) {
            'FAIL' { return 'Red' }
            'WARN' { return 'Yellow' }
            'PASS' { return 'Green' }
            'N/A' { return 'DarkGray' }
            default { return $null }
        }
    }

    function Write-StatusChangeCell([string]$statusChange, [int]$width) {
        $txt = Get-NormalizedText $statusChange
        if (-not $txt) {
            Write-Host ("{0,-$width}" -f '') -NoNewline
            return
        }
        $parts = $txt -split '->', 2
        $old = Get-NormalizedText ($parts[0])
        $new = if ($parts.Count -gt 1) { Get-NormalizedText ($parts[1]) } else { '' }
        $oldColor = Get-StatusColor -status $old
        $newColor = Get-StatusColor -status $new
        if ($oldColor) { Write-Host $old -ForegroundColor $oldColor -NoNewline } else { Write-Host $old -NoNewline }
        Write-Host '->' -ForegroundColor White -NoNewline
        if ($newColor) { Write-Host $new -ForegroundColor $newColor -NoNewline } else { Write-Host $new -NoNewline }
        $len = ($old + '->' + $new).Length
        $pad = [Math]::Max(0, $width - $len)
        if ($pad -gt 0) { Write-Host (' ' * $pad) -NoNewline }
    }

    function Wrap-Text([string]$text, [int]$width) {
        $t = Get-NormalizedText $text
        if (-not $t) { return @('') }
        if ($width -le 0) { return @($t) }
        $lines = @()
        while ($t.Length -gt $width) {
            $slice = $t.Substring(0, $width)
            $breakAt = $slice.LastIndexOf(' ')
            if ($breakAt -le 0) { $breakAt = $width }
            $lines += $t.Substring(0, $breakAt).TrimEnd()
            $t = $t.Substring($breakAt).TrimStart()
        }
        $lines += $t
        return $lines
    }

    function Wrap-Details([string]$text, [int]$width) {
        $t = Get-NormalizedText $text
        if (-not $t) { return @('') }
        $wrapped = @(Wrap-Text -text $t -width $width)
        if ($wrapped.Count -eq 0) { return @('') }
        return ,$wrapped
    }

    function Coerce-Details([object]$details) {
        if ($null -eq $details) { return '' }
        if ($details -is [string]) { return $details }
        if ($details -is [char[]]) { return -join $details }
        if ($details -is [System.Collections.IEnumerable]) {
            $sb = New-Object System.Text.StringBuilder
            foreach ($x in $details) {
                if ($null -eq $x) { continue }
                if ($sb.Length -gt 0) { [void]$sb.Append('; ') }
                [void]$sb.Append([string]$x)
            }
            return $sb.ToString()
        }
        return [string]$details
    }

    foreach ($r in $rowsOut | Sort-Object Domain, Category) {
        # No row-wide coloring; only color StatusChange tokens
        $catVal = if ($null -ne $r.Category -and $r.Category -ne '') { $r.Category } else { '' }
        $statusChange = if ($r.PSObject.Properties.Name -contains 'StatusChange') { $r.StatusChange } else { '' }
        $detailsText = if ($r.PSObject.Properties.Name -contains 'Details') { $r.Details } else { '' }
        $detailsText = Coerce-Details -details $detailsText
        $detailLines = Wrap-Details -text $detailsText -width $detailsWidth

        $leftFmt = "{0,-$domainWidth} {1,-$categoryWidth} {2,-$changeWidth} {3,-$trendWidth} "
        $statusFmt = "{0,-$statusWidth} "
        $tailFmt = "{0}"
        $contLeft = ("{0,-$domainWidth} {1,-$categoryWidth} {2,-$changeWidth} {3,-$trendWidth} {4,-$statusWidth} " -f '','','','','')

        for ($i = 0; $i -lt $detailLines.Count; $i++) {
            if ($i -eq 0) {
                $leftText = ($leftFmt -f $r.Domain, $catVal, $r.Change, $r.Trend)
                Write-Host $leftText -NoNewline
                Write-StatusChangeCell -statusChange $statusChange -width $statusWidth
            } else {
                Write-Host $contLeft -NoNewline
            }
            Write-Host ($tailFmt -f $detailLines[$i])
        }
    }
}

# Summary
Write-Output ""
$summary = ("Summary: New={0}, Removed={1}, Changed={2}, Improved={3}, Regressed={4}" -f $countNew, $countRemoved, $countChanged, $countImproved, $countRegressed)
Write-Host $summary -ForegroundColor Cyan


