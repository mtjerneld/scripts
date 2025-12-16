<#
.SYNOPSIS
    Tests if a resource matches any deprecation rules and calculates EOL severity.

.DESCRIPTION
    Matches a resource against deprecation rules based on resourceType and matchProperties.
    Calculates severity based on time until deadline:
    - Critical: Passed or < 3 months
    - High: 3-6 months
    - Medium: 6-12 months
    - Low: 12-24 months

.PARAMETER Resource
    The Azure resource object to test (from Get-Az* cmdlets).

.PARAMETER ResourceType
    The Azure resource type (e.g., "Microsoft.Storage/storageAccounts").

.PARAMETER DeprecationRules
    Array of deprecation rules from Get-DeprecationRules.

.PARAMETER ResourceTypeMapping
    Optional resource type mapping for property paths.

.OUTPUTS
    PSCustomObject with:
    - Matched: boolean
    - Rule: matched deprecation rule (if any)
    - Severity: Critical/High/Medium/Low (if matched)
    - DaysUntilDeadline: number of days until deadline (if matched)
    - Deadline: deadline date string (if matched)
#>
function Test-ResourceEOLStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$Resource,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceType,
        
        [Parameter(Mandatory = $true)]
        [array]$DeprecationRules,
        
        [hashtable]$ResourceTypeMapping = @{}
    )
    
    if (-not $DeprecationRules -or $DeprecationRules.Count -eq 0) {
        return [PSCustomObject]@{
            Matched = $false
            Rule = $null
            Severity = $null
            DaysUntilDeadline = $null
            Deadline = $null
        }
    }
    
    # Filter rules by resourceType
    $relevantRules = @($DeprecationRules | Where-Object { 
        $_.resourceType -eq $ResourceType 
    })
    
    if ($relevantRules.Count -eq 0) {
        return [PSCustomObject]@{
            Matched = $false
            Rule = $null
            Severity = $null
            DaysUntilDeadline = $null
            Deadline = $null
        }
    }
    
    # Helper to get nested property value
    function Get-ResourcePropertyValue {
        param(
            [PSObject]$Obj,
            [string]$Path
        )
        
        if ([string]::IsNullOrWhiteSpace($Path)) {
            return $null
        }
        
        $current = $Obj
        $segments = $Path -split '\.'
        foreach ($seg in $segments) {
            if ($null -eq $current) { return $null }
            
            if ($current -is [System.Collections.IDictionary]) {
                if (-not $current.Contains($seg)) { return $null }
                $current = $current[$seg]
            }
            elseif ($current.PSObject) {
                # PowerShell objects are case-insensitive for property access, but we need to find the exact property name
                $propNames = $current.PSObject.Properties.Name
                $matchedProp = $propNames | Where-Object { $_ -eq $seg }
                
                if ($matchedProp) {
                    # Exact match found
                    $current = $current.$matchedProp
                }
                else {
                    # Try case-insensitive match
                    $matchedProp = $propNames | Where-Object { $_ -ieq $seg }
                    if ($matchedProp) {
                        $current = $current.$matchedProp
                    }
                    else {
                        Write-Verbose "Property '$seg' not found in object. Available properties: $($propNames -join ', ')"
                        return $null
                    }
                }
            }
            else {
                return $null
            }
        }
        
        return $current
    }
    
    # Test each relevant rule
    foreach ($rule in $relevantRules) {
        $matches = $true
        
        # If no matchProperties, all resources of this type match
        if ($rule.matchProperties) {
            $matchProps = $rule.matchProperties
            if ($matchProps.PSObject.Properties.Count -gt 0) {
                foreach ($propName in $matchProps.PSObject.Properties.Name) {
                    $expectedValue = $matchProps.$propName
                    
                    # Get property path from mapping or use direct property name
                    $propertyPath = $null
                    if ($ResourceTypeMapping -and $ResourceTypeMapping.ContainsKey($ResourceType)) {
                        $mapping = $ResourceTypeMapping[$ResourceType]
                        # Handle both hashtable and PSCustomObject
                        if ($mapping -is [hashtable] -and $mapping.ContainsKey("properties")) {
                            $mappingProps = $mapping["properties"]
                            if ($mappingProps -is [hashtable] -and $mappingProps.ContainsKey($propName)) {
                                $propertyPath = $mappingProps[$propName]
                            }
                            elseif ($mappingProps.PSObject -and $mappingProps.PSObject.Properties.Name -contains $propName) {
                                $propertyPath = $mappingProps.$propName
                            }
                        }
                        elseif ($mapping.PSObject -and $mapping.PSObject.Properties.Name -contains "properties") {
                            $mappingProps = $mapping.properties
                            if ($mappingProps.PSObject -and $mappingProps.PSObject.Properties.Name -contains $propName) {
                                $propertyPath = $mappingProps.$propName
                            }
                        }
                    }
                    
                    # Fallback to direct property name if no mapping
                    if ([string]::IsNullOrWhiteSpace($propertyPath)) {
                        $propertyPath = $propName
                    }
                    
                    # Get actual value from resource
                    $actualValue = Get-ResourcePropertyValue -Obj $Resource -Path $propertyPath
                    $actualStr = if ($actualValue -ne $null) { "$actualValue" } else { "" }
                    
                    Write-Verbose "EOL Match Check: propName=$propName, propertyPath=$propertyPath, expectedValue=$expectedValue, actualValue=$actualStr"
                    
                    # Compare (case-insensitive string comparison)
                    if ($actualStr -ne "$expectedValue") {
                        Write-Verbose "EOL Match Failed: '$actualStr' != '$expectedValue'"
                        $matches = $false
                        break
                    } else {
                        Write-Verbose "EOL Match Succeeded: '$actualStr' == '$expectedValue'"
                    }
                }
            }
        }
        
        if ($matches) {
            # Calculate severity based on time until deadline
            $deadlineStr = $rule.deadline
            if ([string]::IsNullOrWhiteSpace($deadlineStr)) {
                continue
            }
            
            try {
                $deadline = [DateTime]::Parse($deadlineStr)
                $today = Get-Date
                $daysUntil = ($deadline - $today).Days
                
                # Calculate severity
                $severity = "Low"
                if ($daysUntil -lt 0) {
                    # Past due
                    $severity = "Critical"
                }
                elseif ($daysUntil -lt 90) {
                    # < 3 months
                    $severity = "Critical"
                }
                elseif ($daysUntil -lt 180) {
                    # 3-6 months
                    $severity = "High"
                }
                elseif ($daysUntil -lt 365) {
                    # 6-12 months
                    $severity = "Medium"
                }
                elseif ($daysUntil -lt 730) {
                    # 12-24 months
                    $severity = "Low"
                }
                else {
                    # > 24 months - don't match (too far in future)
                    continue
                }
                
                return [PSCustomObject]@{
                    Matched = $true
                    Rule = $rule
                    Severity = $severity
                    DaysUntilDeadline = $daysUntil
                    Deadline = $deadlineStr
                }
            }
            catch {
                Write-Verbose "Failed to parse deadline date '$deadlineStr' for rule '$($rule.component)': $_"
                continue
            }
        }
    }
    
    # No match found
    return [PSCustomObject]@{
        Matched = $false
        Rule = $null
        Severity = $null
        DaysUntilDeadline = $null
        Deadline = $null
    }
}

