<#
.SYNOPSIS
    Scans Azure resources for End-of-Life (EOL) / deprecated services based on DeprecationRules.

.DESCRIPTION
    Uses Azure Resource Graph to enumerate resources across subscriptions and matches them
    against rules defined in Config\DeprecationRules.json (optionellt kompletterat med
    Config\ResourceTypeMapping.json).

    Resultatet används för EOL-sektionen i Security-rapporten.

.PARAMETER SubscriptionIds
    List of subscription IDs to scan.

.PARAMETER DeprecationRulesPath
    Optional explicit path to DeprecationRules.json. Defaults to module Config folder.

.PARAMETER ResourceTypeMappingPath
    Optional explicit path to ResourceTypeMapping.json. Defaults to module Config folder.

.OUTPUTS
    Array of PSCustomObject:
        Component, Status, Deadline, DaysUntilDeadline, Severity,
        AffectedResourceCount, AffectedResources (array),
        ActionRequired, MigrationGuide
#>
function Get-EOLStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$SubscriptionIds,

        [string]$DeprecationRulesPath,

        [string]$ResourceTypeMappingPath
    )

    # Resolve module root
    $moduleRoot = $PSScriptRoot -replace '\\Private\\Scanners$', ''

    if (-not $DeprecationRulesPath) {
        $DeprecationRulesPath = Join-Path $moduleRoot "Config\DeprecationRules.json"
    }
    if (-not $ResourceTypeMappingPath) {
        $ResourceTypeMappingPath = Join-Path $moduleRoot "Config\ResourceTypeMapping.json"
    }

    # Load DeprecationRules
    if (-not (Test-Path $DeprecationRulesPath)) {
        Write-Verbose "DeprecationRules file not found at $DeprecationRulesPath - skipping EOL scan"
        return @()
    }

    $rulesJson = Get-Content -Path $DeprecationRulesPath -Raw | ConvertFrom-Json
    $allRules = if ($rulesJson.deprecations) { @($rulesJson.deprecations) } else { @() }

    if ($allRules.Count -eq 0) {
        Write-Verbose "No deprecation rules found in $DeprecationRulesPath"
        return @()
    }

    # Load ResourceType mappings (optional but recommended)
    $resourceTypeMappings = @()
    if (Test-Path $ResourceTypeMappingPath) {
        try {
            $mappingJson = Get-Content -Path $ResourceTypeMappingPath -Raw | ConvertFrom-Json
            if ($mappingJson -and $mappingJson.mappings) {
                $resourceTypeMappings = @($mappingJson.mappings)
            }
        }
        catch {
            Write-Warning "Failed to load ResourceTypeMapping from $ResourceTypeMappingPath : $_"
        }
    }

    if (-not (Get-Module -ListAvailable -Name Az.ResourceGraph)) {
        Write-Warning "Az.ResourceGraph module is not available. EOL tracking will be skipped."
        return @()
    }

    Import-Module Az.ResourceGraph -ErrorAction SilentlyContinue | Out-Null

    # Helper: get nested property from Resource Graph row using path like 'properties.extra.runtime'
    function Get-NestedProperty {
        param(
            [Parameter(Mandatory = $true)]
            [object]$Object,

            [Parameter(Mandatory = $true)]
            [string]$Path
        )

        if (-not $Object -or [string]::IsNullOrWhiteSpace($Path)) {
            return $null
        }

        $current = $Object
        $segments = $Path -split '\.'
        foreach ($seg in $segments) {
            if (-not $current) { return $null }

            if ($current -is [System.Collections.IDictionary]) {
                if (-not $current.Contains($seg)) { return $null }
                $current = $current[$seg]
            }
            elseif ($current.PSObject -and $current.PSObject.Properties.Name -contains $seg) {
                $current = $current.$seg
            }
            else {
                return $null
            }
        }

        return $current
    }

    # Helper: check if a resource matches a deprecation rule
    function Test-ResourceMatchesDeprecation {
        param(
            [Parameter(Mandatory = $true)]
            [pscustomobject]$Resource,

            [Parameter(Mandatory = $true)]
            [pscustomobject]$Rule,

            [Parameter(Mandatory = $true)]
            [pscustomobject]$Mapping
        )

        # If no matchProperties defined, treat all resources of this type as affected
        if (-not $Rule.matchProperties) {
            return $true
        }

        $ruleProps = $Rule.matchProperties.PSObject.Properties
        if ($ruleProps.Count -eq 0) {
            return $true
        }

        $mappingProps = if ($Mapping -and $Mapping.properties) { $Mapping.properties } else { $null }

        foreach ($prop in $ruleProps) {
            $logicalName = $prop.Name
            $expected = $prop.Value

            # If we don't have a mapping for this logical property, skip strict matching
            if (-not $mappingProps -or -not ($mappingProps.PSObject.Properties.Name -contains $logicalName)) {
                continue
            }

            $propertyPath = $mappingProps.$logicalName
            if ([string]::IsNullOrWhiteSpace($propertyPath)) {
                continue
            }

            $actual = Get-NestedProperty -Object $Resource -Path $propertyPath

            # If expected value is null/empty, only require that the property exists
            if ([string]::IsNullOrWhiteSpace([string]$expected)) {
                if ($null -eq $actual) {
                    return $false
                }
                continue
            }

            # String comparison, case-insensitive
            $actualStr = if ($actual -ne $null) { "$actual" } else { "" }
            if ($actualStr -ne $expected) {
                return $false
            }
        }

        return $true
    }

    # Group rules by resourceType
    $rulesByType = @{}
    foreach ($rule in $allRules) {
        if (-not $rule.resourceType) {
            continue
        }
        $rt = $rule.resourceType
        if (-not $rulesByType.ContainsKey($rt)) {
            $rulesByType[$rt] = [System.Collections.Generic.List[pscustomobject]]::new()
        }
        $rulesByType[$rt].Add($rule)
    }

    if ($rulesByType.Keys.Count -eq 0) {
        Write-Verbose "No deprecation rules with resourceType defined. EOL scanning has nothing to do."
        return @()
    }

    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($resourceType in $rulesByType.Keys) {
        $rulesForType = $rulesByType[$resourceType]
        Write-Verbose "Running EOL scan for resource type '$resourceType' with $($rulesForType.Count) rule(s)"

        $subSetJson = ($SubscriptionIds | Sort-Object -Unique) | ConvertTo-Json -Compress
        $kql = @"
Resources
| where subscriptionId in (dynamic($subSetJson))
| where type == '$resourceType'
| project id, name, type, resourceGroup, location, subscriptionId, properties, sku
"@

        try {
            $queryResult = Search-AzGraph -Query $kql -ErrorAction Stop
        }
        catch {
            Write-Warning "Resource Graph query failed for type '$resourceType' : $_"
            continue
        }

        if (-not $queryResult -or $queryResult.Count -eq 0) {
            Write-Verbose "No resources of type '$resourceType' found in selected subscriptions"
            continue
        }

        # Find mapping (if any) for this resourceType
        $mapping = $null
        if ($resourceTypeMappings.Count -gt 0) {
            $mapping = $resourceTypeMappings | Where-Object { $_.resourceType -eq $resourceType } | Select-Object -First 1
        }

        foreach ($rule in $rulesForType) {
            $affected = [System.Collections.Generic.List[pscustomobject]]::new()

            foreach ($res in $queryResult) {
                $matches = $false
                if ($mapping) {
                    $matches = Test-ResourceMatchesDeprecation -Resource $res -Rule $rule -Mapping $mapping
                } else {
                    # Without mapping we can only match on resourceType
                    $matches = $true
                }

                if (-not $matches) { continue }

                $affected.Add([pscustomobject]@{
                    ResourceId    = $res.id
                    ResourceGroup = $res.resourceGroup
                    Location      = $res.location
                    SubscriptionId= $res.subscriptionId
                    Name          = $res.name
                    Properties    = $res.properties
                    Sku           = $res.sku
                })
            }

            if ($affected.Count -eq 0) {
                continue
            }

            # Calculate status / severity based on deadline
            $deadlineDate = $null
            $daysUntil = $null
            $status = $rule.status
            $severity = $rule.severity

            if ($rule.deadline) {
                try {
                    $deadlineDate = [DateTime]$rule.deadline
                    $daysUntil = ($deadlineDate - (Get-Date)).TotalDays

                    if (-not $status) {
                        if ($deadlineDate -lt (Get-Date)) {
                            $status = "RETIRED"
                        } elseif ($daysUntil -lt 90) {
                            $status = "DEPRECATED"
                        } else {
                            $status = "ANNOUNCED"
                        }
                    }

                    if (-not $severity) {
                        if ($daysUntil -lt 30) {
                            $severity = "Critical"
                        } elseif ($daysUntil -lt 90) {
                            $severity = "High"
                        } elseif ($daysUntil -lt 180) {
                            $severity = "Medium"
                        } else {
                            $severity = "Low"
                        }
                    }
                }
                catch {
                    Write-Verbose "Failed to parse deadline '$($rule.deadline)' for component '$($rule.component)'"
                }
            }

            $result = [pscustomobject]@{
                Component            = $rule.component
                Status               = if ($status) { $status } else { "UNKNOWN" }
                Deadline             = $rule.deadline
                DaysUntilDeadline    = if ($daysUntil -ne $null) { [math]::Round($daysUntil, 0) } else { $null }
                Severity             = if ($severity) { $severity } else { "Medium" }
                AffectedResourceCount= $affected.Count
                AffectedResources    = $affected
                ActionRequired       = $rule.actionRequired
                MigrationGuide       = $rule.migrationGuide
            }

            $results.Add($result)
        }
    }

    return $results
}


