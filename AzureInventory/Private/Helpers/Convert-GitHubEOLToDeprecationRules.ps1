<#
.SYNOPSIS
    Converts Azure EOL service_list.json from GitHub to DeprecationRules format.

.DESCRIPTION
    Helper script used manually to bootstrap / refresh Config\DeprecationRules.json
    from the official Azure EOL repository (https://github.com/Azure/EOL).

    NOTE: This script is intentionally NOT called automatically from the main
    audit flow. You run it manually when you want to update EOL rules.

.PARAMETER InputPath
    Path to a local copy of service_list.json downloaded from GitHub.

.PARAMETER OutputPath
    Path where the converted DeprecationRules JSON should be written.

.PARAMETER ExistingRulesPath
    Optional path to existing DeprecationRules.json that should be merged
    with the generated rules.

.PARAMETER ResourceTypeMappingPath
    Optional path to ResourceTypeMapping.json used to enrich rules with
    resourceType / matchProperties metadata.

.EXAMPLE
    Convert-GitHubEOLToDeprecationRules `
        -InputPath .\service_list.json `
        -OutputPath .\Config\DeprecationRules.json `
        -ExistingRulesPath .\Config\DeprecationRules.json `
        -ResourceTypeMappingPath .\Config\ResourceTypeMapping.json
#>
function Convert-GitHubEOLToDeprecationRules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [string]$ExistingRulesPath,

        [string]$ResourceTypeMappingPath
    )

    if (-not (Test-Path $InputPath)) {
        throw "Input file not found: $InputPath"
    }

    Write-Verbose "Loading GitHub EOL data from $InputPath"
    $raw = Get-Content -Path $InputPath -Raw | ConvertFrom-Json

    if (-not $raw) {
        throw "No data loaded from $InputPath"
    }

    # Optional: load existing rules to preserve hand-crafted items
    $existingRules = @()
    if ($ExistingRulesPath -and (Test-Path $ExistingRulesPath)) {
        try {
            $existingJson = Get-Content -Path $ExistingRulesPath -Raw | ConvertFrom-Json
            if ($existingJson -and $existingJson.deprecations) {
                $existingRules = @($existingJson.deprecations)
                Write-Verbose "Loaded $($existingRules.Count) existing deprecation rule(s) from $ExistingRulesPath"
            }
        }
        catch {
            Write-Warning "Failed to load existing DeprecationRules from $ExistingRulesPath : $_"
        }
    }

    # Optional: load resource type mapping
    $resourceTypeMappings = @()
    if ($ResourceTypeMappingPath -and (Test-Path $ResourceTypeMappingPath)) {
        try {
            $mappingJson = Get-Content -Path $ResourceTypeMappingPath -Raw | ConvertFrom-Json
            if ($mappingJson -and $mappingJson.mappings) {
                $resourceTypeMappings = @($mappingJson.mappings)
                Write-Verbose "Loaded $($resourceTypeMappings.Count) resource type mapping(s) from $ResourceTypeMappingPath"
            }
        }
        catch {
            Write-Warning "Failed to load ResourceTypeMapping from $ResourceTypeMappingPath : $_"
        }
    }

    $today = Get-Date
    $generatedRules = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($item in $raw) {
        if (-not $item.ServiceName -or -not $item.RetiringFeature -or -not $item.RetirementDate) {
            continue
        }

        $component = "$($item.ServiceName) - $($item.RetiringFeature)"

        # Normalize date to yyyy-MM-dd
        $deadline = $null
        try {
            $deadline = ([DateTime]$item.RetirementDate).ToString('yyyy-MM-dd')
        }
        catch {
            Write-Warning "Skipping EOL item with invalid RetirementDate: $component ($($item.RetirementDate))"
            continue
        }

        $retirementDate = [DateTime]$item.RetirementDate
        $daysUntil = ($retirementDate - $today).TotalDays

        # Status
        $status = if ($retirementDate -lt $today) {
            "RETIRED"
        } elseif ($daysUntil -lt 90) {
            "DEPRECATED"
        } else {
            "ANNOUNCED"
        }

        # Severity
        $severity = if ($daysUntil -lt 30) {
            "Critical"
        } elseif ($daysUntil -lt 90) {
            "High"
        } elseif ($daysUntil -lt 180) {
            "Medium"
        } else {
            "Low"
        }

        # Try to enrich with resourceType / matchProperties via mapping (best effort)
        $resourceType = $null
        $matchProperties = @{}

        if ($resourceTypeMappings.Count -gt 0) {
            # Simple heuristic: match on ServiceName
            $matchingMappings = $resourceTypeMappings | Where-Object { $_.ServiceName -eq $item.ServiceName }
            if ($matchingMappings.Count -gt 0) {
                # For now, take the first mapping per service
                $map = $matchingMappings[0]
                $resourceType = $map.resourceType

                if ($map.properties) {
                    # We don't know exact expected values for each property from GitHub data,
                    # so we only include logical property names here. Expected values can
                    # be added manually later in DeprecationRules.json.
                    foreach ($propName in $map.properties.PSObject.Properties.Name) {
                        $matchProperties[$propName] = $null
                    }
                }
            }
        }

        $rule = [PSCustomObject]@{
            component       = $component
            serviceName     = $item.ServiceName
            retiringFeature = $item.RetiringFeature
            resourceType    = $resourceType
            matchProperties = if ($matchProperties.Count -gt 0) { $matchProperties } else { $null }
            status          = $status
            deadline        = $deadline
            detectionMethod = "ServiceName: $($item.ServiceName); Feature: $($item.RetiringFeature)"
            actionRequired  = "Review retirement notice and plan migration before $deadline"
            migrationGuide  = $item.Link
            severity        = $severity
        }

        $generatedRules.Add($rule)
    }

    Write-Verbose "Generated $($generatedRules.Count) deprecation rule(s) from GitHub EOL data"

    # Merge existing + generated rules
    $allRules = @()
    if ($existingRules.Count -gt 0) {
        $allRules += $existingRules
    }
    $allRules += $generatedRules

    $outputObject = [PSCustomObject]@{
        deprecations = $allRules
    }

    $json = $outputObject | ConvertTo-Json -Depth 6
    $outputDir = Split-Path -Parent $OutputPath
    if ($outputDir -and -not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    Set-Content -Path $OutputPath -Value $json -Encoding UTF8
    Write-Host "EOL DeprecationRules written to $OutputPath" -ForegroundColor Green
}


