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

    # Helper function to check if an IP/CIDR is a private/internal address (RFC 1918)
    function Test-IsPrivateIp {
        param([string]$IpOrCidr)
        
        if ([string]::IsNullOrWhiteSpace($IpOrCidr)) { return $false }
        
        # Aggressive cleaning: remove invisible chars, quotes, extra spaces
        # Keep only: Alphanumeric, dot, slash, asterisk, dash
        $clean = $IpOrCidr -replace '[^0-9a-zA-Z\.\/\*\-]', ''
        
        # 1. Check for explicit internet indicators
        if ($clean -eq "*" -or $clean -eq "0.0.0.0/0" -or $clean -eq "Internet" -or $clean -eq "Any") {
            return $false
        }
        
        # 2. Azure Service Tags
        if ($clean -like "VirtualNetwork*" -or $clean -like "AzureLoadBalancer*") { return $true }
        
        # 3. RFC 1918 Private Ranges
        if ($clean -like "10.*") { return $true }
        if ($clean -like "192.168.*") { return $true }
        
        # 172.16.x.x - 172.31.x.x
        if ($clean -like "172.*") {
            if ($clean -match "^172\.(\d+)") {
                $secondOctet = [int]$Matches[1]
                if ($secondOctet -ge 16 -and $secondOctet -le 31) {
                    return $true
                }
            }
        }
        
        # 4. Special Ranges
        if ($clean -like "127.*") { return $true }      # Loopback
        if ($clean -like "169.254.*") { return $true }  # Link-Local
        
        return $false
    }
    
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
                if ($trimmedAddr -eq $dangerous -or $trimmedAddr -like $dangerous) {
                    $isInternetSource = $true
                    break
                }
            }
            
            # If not an explicit internet indicator, check if it's a private range
            if (-not $isInternetSource) {
                $isPrivate = Test-IsPrivateIp -IpOrCidr $trimmedAddr
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

