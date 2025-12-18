<#
.SYNOPSIS
    Safely extracts a value from a dictionary, hashtable, or object.

.DESCRIPTION
    Attempts to retrieve a value from various data structures (hashtables, dictionaries, PSObjects)
    using multiple access methods. Returns null if the key/property is not found.

.PARAMETER Dict
    Dictionary, hashtable, or object to search.

.PARAMETER Key
    Key or property name to retrieve.

.EXAMPLE
    $value = Get-DictionaryValue -Dict $extendedProps -Key "currentSku"

.EXAMPLE
    $savings = Get-DictionaryValue -Dict $metadata -Key "annualSavingsAmount"
#>
function Get-DictionaryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Dict,
        
        [Parameter(Mandatory = $true)]
        [string]$Key
    )
    
    if ($null -eq $Dict) { 
        return $null 
    }
    
    # Try hashtable/dictionary access
    if ($Dict -is [System.Collections.IDictionary]) {
        if ($Dict.ContainsKey($Key)) {
            return $Dict[$Key]
        }
        return $null
    }
    
    # Try as PSObject with properties
    if ($Dict.PSObject.Properties[$Key]) {
        return $Dict.PSObject.Properties[$Key].Value
    }
    
    # Try direct property access
    try {
        $value = $Dict.$Key
        if ($null -ne $value) {
            return $value
        }
    }
    catch { }
    
    return $null
}





