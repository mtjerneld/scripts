<#
.SYNOPSIS
    Encodes text for safe use in HTML by escaping special characters.

.DESCRIPTION
    Escapes HTML special characters (&, <, >, ", ') to prevent XSS attacks and ensure
    proper HTML rendering. Uses System.Web.HttpUtility if available, otherwise falls back
    to manual encoding.

.PARAMETER Text
    Text to encode for HTML.

.EXAMPLE
    $safeHtml = Encode-Html -Text "User <script>alert('xss')</script>"
    # Returns: "User &lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"
#>
function Encode-Html {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
        [string]$Text
    )
    
    if ([string]::IsNullOrEmpty($Text)) {
        return ""
    }
    
    # Try to use System.Web.HttpUtility if available (more robust)
    try {
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
        return [System.Web.HttpUtility]::HtmlEncode($Text)
    }
    catch {
        # Manual HTML encoding fallback
        return $Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace "'", '&#39;'
    }
}



