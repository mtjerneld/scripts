<#
.SYNOPSIS
    Analyzes NSG rules for security risks.

.DESCRIPTION
    Examines Network Security Group rules and identifies potentially dangerous
    configurations such as open management ports, any/any rules, and exposed
    database ports.

.PARAMETER NsgRules
    Collection of NSG security rules to analyze.

.PARAMETER NsgName
    Name of the NSG being analyzed (for reporting).

.OUTPUTS
    List of PSCustomObjects containing risk findings with severity levels.
#>
function Get-NsgRiskAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $NsgRules,
        
        [Parameter(Mandatory = $false)]
        [string]$NsgName = "Unknown"
    )
    
    $risks = [System.Collections.Generic.List[PSObject]]::new()
    
    if (-not $NsgRules) {
        return $risks
    }
    
    # Define risky port configurations
    $criticalPorts = @{
        22   = "SSH"
        3389 = "RDP"
    }
    
    $highRiskPorts = @{
        23   = "Telnet"
        445  = "SMB"
        5985 = "WinRM HTTP"
        5986 = "WinRM HTTPS"
        135  = "RPC"
        139  = "NetBIOS"
    }
    
    $mediumRiskPorts = @{
        1433  = "SQL Server"
        3306  = "MySQL"
        5432  = "PostgreSQL"
        27017 = "MongoDB"
        6379  = "Redis"
        9200  = "Elasticsearch"
        5601  = "Kibana"
        8080  = "HTTP Alt"
        21    = "FTP"
        25    = "SMTP"
    }
    
    # Sources that indicate "open to internet" (exclude private ranges)
    $dangerousSources = @(
        "*",
        "0.0.0.0/0",
        "Internet",
        "Any"
    )

    
    foreach ($rule in $NsgRules) {
        # Only analyze Allow rules for inbound traffic
        if ($rule.Access -ne "Allow") { continue }
        if ($rule.Direction -ne "Inbound") { continue }
        
        # Check if source is dangerous (open to internet, NOT private ranges)
        $sourceIsOpen = $false
        $sourceAddresses = @()
        
        # Collect all source addresses
        if ($rule.SourceAddressPrefix) {
            # Handle space and comma-separated values in SourceAddressPrefix
            # Split on comma first, then trim each part
            $prefixParts = $rule.SourceAddressPrefix -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
            foreach ($part in $prefixParts) {
                # Also split on spaces in case there are space-separated values
                $subParts = $part -split '\s+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
                foreach ($subPart in $subParts) {
                    if ($subPart) { $sourceAddresses += $subPart }
                }
            }
        }
        if ($rule.SourceAddressPrefixes) {
            foreach ($prefix in $rule.SourceAddressPrefixes) {
                if ($prefix) {
                    # Also handle comma-separated values in array elements
                    $prefixParts = $prefix -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
                    foreach ($part in $prefixParts) {
                        $subParts = $part -split '\s+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
                        foreach ($subPart in $subParts) {
                            if ($subPart) { $sourceAddresses += $subPart }
                        }
                    }
                }
            }
        }
        
        # Check if ANY source is actually from internet (not private)
        # Only flag if at least one source is truly from internet
        $hasInternetSource = $false
        $validSourceCount = 0
        
        # If no source addresses, skip (shouldn't happen for Allow rules, but be safe)
        if ($sourceAddresses.Count -eq 0) { continue }
        
        foreach ($sourceAddr in $sourceAddresses) {
            if ([string]::IsNullOrWhiteSpace($sourceAddr)) { continue }
            
            $trimmedAddr = $sourceAddr.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmedAddr)) { continue }
            
            $validSourceCount++
            
            # Check for explicit internet indicators first
            $isInternetSource = $false
            foreach ($dangerous in $dangerousSources) {
                if ($trimmedAddr -eq $dangerous) {
                    $isInternetSource = $true
                    break
                }
            }
            
            # If not an explicit internet indicator, check if it's a private range
            # FULLY INLINED - no function call to eliminate any scope issues
            if (-not $isInternetSource) {
                $cleanAddr = $trimmedAddr -replace '[^0-9a-zA-Z\.\/\*\-]', ''
                $isPrivate = $false
                
                # RFC 1918: 10.0.0.0/8
                if ($cleanAddr -like "10.*") { 
                    $isPrivate = $true 
                }
                # RFC 1918: 192.168.0.0/16
                elseif ($cleanAddr -like "192.168.*") { 
                    $isPrivate = $true 
                }
                # RFC 1918: 172.16.0.0/12 (172.16.x.x - 172.31.x.x)
                elseif ($cleanAddr -like "172.*") {
                    if ($cleanAddr -match "^172\.(\d+)") {
                        $octet2 = [int]$Matches[1]
                        if ($octet2 -ge 16 -and $octet2 -le 31) {
                            $isPrivate = $true
                        }
                    }
                }
                # Loopback
                elseif ($cleanAddr -like "127.*") { 
                    $isPrivate = $true 
                }
                # Link-Local
                elseif ($cleanAddr -like "169.254.*") { 
                    $isPrivate = $true 
                }
                # Azure Service Tags
                elseif ($cleanAddr -like "VirtualNetwork*" -or $cleanAddr -like "AzureLoadBalancer*") { 
                    $isPrivate = $true 
                }
                
                if ($isPrivate) {
                    # This is a private range - not an internet source, continue checking other sources
                    continue
                } else {
                    # Not private and not explicitly internet - could be public IP range, treat as internet
                    $isInternetSource = $true
                }
            }
            
            if ($isInternetSource) {
                $hasInternetSource = $true
                break
            }
        }
        
        # Only flag rules that have at least one internet source
        # If all sources are private, this is internal-to-internal traffic, not a security risk
        if (-not $hasInternetSource) { 
            # All sources are private - this is not a security risk from internet
            # Explicitly skip rules where all valid sources are private ranges
            continue 
        }
        
        # Double-check: if we have valid sources and none are internet, skip
        if ($validSourceCount -gt 0 -and -not $hasInternetSource) {
            continue
        }
        
        # Get destination addresses
        $destinationAddresses = @()
        if ($rule.DestinationAddressPrefix) {
            # Handle space-separated values in DestinationAddressPrefix
            $destPrefixParts = $rule.DestinationAddressPrefix -split '\s+'
            $destinationAddresses += $destPrefixParts
        }
        if ($rule.DestinationAddressPrefixes) {
            $destinationAddresses += $rule.DestinationAddressPrefixes
        }
        $destinationString = if ($destinationAddresses.Count -gt 0) {
            $destinationAddresses -join ", "
        } else {
            "Any"
        }
        
        # Build source string
        $sourceString = if ($sourceAddresses.Count -gt 0) {
            $sourceAddresses -join ", "
        } else {
            "Any"
        }
        
        # Get destination ports
        $ports = @()
        if ($rule.DestinationPortRange) {
            $ports += $rule.DestinationPortRange
        }
        if ($rule.DestinationPortRanges) {
            $ports += $rule.DestinationPortRanges
        }
        
        foreach ($portSpec in $ports) {
            $severity = $null
            $portName = $null
            $riskDescription = $null
            
            # Check for any/any (wildcard port)
            if ($portSpec -eq "*") {
                $severity = "Critical"
                $portName = "All Ports"
                $riskDescription = "All ports open to internet - extremely dangerous"
                
                $risks.Add([PSCustomObject]@{
                    Severity        = $severity
                    RuleName        = $rule.Name
                    Direction       = $rule.Direction
                    Port            = $portSpec
                    PortName        = $portName
                    Source          = $sourceString
                    Destination     = $destinationString
                    Protocol        = $rule.Protocol
                    Priority        = $rule.Priority
                    Description     = $riskDescription
                    NsgName         = $NsgName
                })
                continue
            }
            
            # Parse port range or single port
            $portNumbers = @()
            if ($portSpec -match "^(\d+)-(\d+)$") {
                $startPort = [int]$Matches[1]
                $endPort = [int]$Matches[2]
                # For ranges, check if any risky ports are included
                $portNumbers = $startPort..$endPort
            }
            elseif ($portSpec -match "^\d+$") {
                $portNumbers = @([int]$portSpec)
            }
            
            foreach ($port in $portNumbers) {
                # Check critical ports
                if ($criticalPorts.ContainsKey($port)) {
                    $severity = "Critical"
                    $portName = $criticalPorts[$port]
                    $riskDescription = "$portName ($port) open to internet - high risk of unauthorized access"
                }
                # Check high risk ports
                elseif ($highRiskPorts.ContainsKey($port)) {
                    $severity = "High"
                    $portName = $highRiskPorts[$port]
                    $riskDescription = "$portName ($port) open to internet - management port exposed"
                }
                # Check medium risk ports
                elseif ($mediumRiskPorts.ContainsKey($port)) {
                    $severity = "Medium"
                    $portName = $mediumRiskPorts[$port]
                    $riskDescription = "$portName ($port) open to internet - service port exposed"
                }
                
                if ($severity) {
                    # Avoid duplicate entries for the same rule/port combination
                    $existing = $risks | Where-Object { 
                        $_.RuleName -eq $rule.Name -and $_.Port -eq $port.ToString() 
                    }
                    
                    if (-not $existing) {
                        $risks.Add([PSCustomObject]@{
                            Severity        = $severity
                            RuleName        = $rule.Name
                            Direction       = $rule.Direction
                            Port            = $port.ToString()
                            PortName        = $portName
                            Source          = $sourceString
                            Destination     = $destinationString
                            Protocol        = $rule.Protocol
                            Priority        = $rule.Priority
                            Description     = $riskDescription
                            NsgName         = $NsgName
                        })
                    }
                    
                    # Reset for next iteration
                    $severity = $null
                }
            }
        }
    }
    
    # Sort by severity (Critical first, then High, then Medium)
    $severityOrder = @{ "Critical" = 1; "High" = 2; "Medium" = 3 }
    $sortedRisks = $risks | Sort-Object { $severityOrder[$_.Severity] }, Priority
    
    return $sortedRisks
}

