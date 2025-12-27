<#
.SYNOPSIS
    Converts EOL component results from Get-AzureEOLStatus into EOLFinding objects.

.DESCRIPTION
    Takes the output from Get-AzureEOLStatus (EOL components with affected resources)
    and converts each affected resource into a New-EOLFinding object. Handles resource
    name extraction, subscription name lookup, and proper status mapping.

.PARAMETER EOLResults
    Array of EOL component results from Get-AzureEOLStatus.

.PARAMETER EOLFindings
    List to add the converted EOL findings to.

.EXAMPLE
    $allEOLFindings = [System.Collections.Generic.List[PSObject]]::new()
    Convert-EOLResultsToFindings -EOLResults $eolResults -EOLFindings $allEOLFindings
#>
function Convert-EOLResultsToFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSObject[]]$EOLResults,
        
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[PSObject]]$EOLFindings
    )
    
    if (-not $EOLResults -or $EOLResults.Count -eq 0) {
        Write-Verbose "Convert-EOLResultsToFindings: No EOL results to convert"
        return
    }
    
    foreach ($eolComponent in $EOLResults) {
        Write-Verbose "Convert-EOLResultsToFindings: Processing component '$($eolComponent.Component)'"
        Write-Verbose "  - AffectedResourceCount property: $($eolComponent.AffectedResourceCount)"
        Write-Verbose "  - AffectedResources type: $($eolComponent.AffectedResources.GetType().FullName)"
        Write-Verbose "  - AffectedResources Count: $($eolComponent.AffectedResources.Count)"
        
        # Convert each affected resource to an EOLFinding and add to allEOLFindings
        if ($eolComponent.AffectedResources -and $eolComponent.AffectedResources.Count -gt 0) {
            Write-Verbose "Convert-EOLResultsToFindings: Component '$($eolComponent.Component)' has $($eolComponent.AffectedResources.Count) affected resources - processing..."
            # Map status: DEPRECATED -> Deprecated, ANNOUNCED -> Retiring, RETIRED -> RETIRED
            $mappedStatus = switch ($eolComponent.Status) {
                "DEPRECATED" { "Deprecated" }
                "ANNOUNCED" { "Retiring" }
                "RETIRED" { "RETIRED" }
                "UNKNOWN" { "Deprecated" }
                default { $eolComponent.Status }
            }
            
            # Ensure DaysUntilDeadline is an integer (handle null)
            # For TBD deadlines, keep as null so report shows "TBD" instead of "0 d"
            $daysUntil = if ($null -ne $eolComponent.DaysUntilDeadline) { 
                [int]$eolComponent.DaysUntilDeadline 
            } else { 
                # Only set to 0 if deadline is not TBD (for backwards compatibility)
                if ($eolComponent.Deadline -eq "TBD") {
                    $null
                } else {
                    0
                }
            }
            
            foreach ($affectedResource in $eolComponent.AffectedResources) {
                # Get subscription name (suppress warnings for cross-tenant subscriptions)
                $subName = Get-SubscriptionDisplayName -SubscriptionId $affectedResource.SubscriptionId -ErrorAction SilentlyContinue -WarningAction SilentlyContinue 2>$null
                
                # Ensure ResourceName is not empty (extract from ResourceId if needed)
                $resourceName = $affectedResource.Name
                if ([string]::IsNullOrWhiteSpace($resourceName) -and $affectedResource.ResourceId) {
                    $resourceName = $affectedResource.ResourceId.Split('/')[-1]
                }
                if ([string]::IsNullOrWhiteSpace($resourceName)) {
                    $resourceName = "Unknown"
                }
                
                # Ensure ResourceGroup is not empty
                $resourceGroup = $affectedResource.ResourceGroup
                if ([string]::IsNullOrWhiteSpace($resourceGroup)) {
                    # Try to extract from ResourceId
                    $resourceIdParts = $affectedResource.ResourceId.Split('/')
                    $rgIndex = [array]::IndexOf($resourceIdParts, 'resourceGroups')
                    if ($rgIndex -ge 0 -and $rgIndex -lt ($resourceIdParts.Length - 1)) {
                        $resourceGroup = $resourceIdParts[$rgIndex + 1]
                    } else {
                        $resourceGroup = "Unknown"
                    }
                }
                
                # Create EOLFinding for this resource
                $eolFinding = New-EOLFinding `
                    -SubscriptionId $affectedResource.SubscriptionId `
                    -SubscriptionName $subName `
                    -ResourceGroup $resourceGroup `
                    -ResourceType $eolComponent.ResourceType `
                    -ResourceName $resourceName `
                    -ResourceId $affectedResource.ResourceId `
                    -Component $eolComponent.Component `
                    -Status $mappedStatus `
                    -Deadline $eolComponent.Deadline `
                    -Severity $eolComponent.Severity `
                    -DaysUntilDeadline $daysUntil `
                    -ActionRequired $eolComponent.ActionRequired `
                    -MigrationGuide $eolComponent.MigrationGuide `
                    -References @()
                
                $EOLFindings.Add($eolFinding)
            }
            
            Write-Verbose "Convert-EOLResultsToFindings: Converted $($eolComponent.AffectedResources.Count) resource(s) for component '$($eolComponent.Component)' to EOL findings"
        } else {
            Write-Verbose "Convert-EOLResultsToFindings: Component '$($eolComponent.Component)' has no AffectedResources (Count: $($eolComponent.AffectedResources.Count), AffectedResourceCount: $($eolComponent.AffectedResourceCount))"
        }
    }
    
    Write-Verbose "Convert-EOLResultsToFindings: Total findings created: $($EOLFindings.Count)"
}


