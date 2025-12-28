<#
.SYNOPSIS
    Parses OpenAI Responses API JSON structure to extract text content.

.DESCRIPTION
    Extracts the output text from OpenAI Responses API JSON structure.
    Handles incomplete responses and error cases gracefully.

.PARAMETER RespObj
    The parsed JSON response object from OpenAI API.

.EXAMPLE
    $parsed = ConvertFrom-OpenAIResponseJson -RespObj $jsonResponse
#>
function ConvertFrom-OpenAIResponseJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $RespObj
    )
    
    # Try to find a completed message first, even if overall status is incomplete
    $jsonText = ($RespObj.output |
        Where-Object { $_.type -eq 'message' -and $_.status -eq 'completed' } |
        Select-Object -First 1 -ExpandProperty content |
        Where-Object { $_.type -eq 'output_text' } |
        Select-Object -First 1 -ExpandProperty text)
    
    # If no completed message found and overall status is incomplete, throw error
    if (-not $jsonText -and $RespObj.status -eq 'incomplete') {
        $reason = $RespObj.incomplete_details.reason
        throw ("Model status=incomplete (reason={0}) - no completed message found." -f $reason)
    }

    if (-not $jsonText) { 
        throw 'No output_text found in response.' 
    }

    # Remove markdown code fences if present
    if ($jsonText -match '^\s*```') {
        $jsonText = $jsonText -replace '^\s*```(?:json)?\s*',''
        $jsonText = $jsonText -replace '\s*```$',''
    }

    # Parse JSON
    $first = $null
    try { 
        $first = $jsonText | ConvertFrom-Json 
    } catch { 
        $first = ($jsonText.Trim() | ConvertFrom-Json) 
    }
    
    # Handle nested JSON strings
    if ($first -is [string] -and $first.TrimStart().StartsWith('{')) {
        return ($first | ConvertFrom-Json)
    }
    
    return $first
}

<#
.SYNOPSIS
    Extracts the first output text from Responses API JSON.

.DESCRIPTION
    Helper function to extract text content from various response formats.

.PARAMETER Json
    The JSON response object.

.PARAMETER FallbackContent
    Fallback content if extraction fails.
#>
function Get-FirstResponsesOutputText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Json,
        
        [Parameter(Mandatory = $false)]
        $FallbackContent
    )
    
    try {
        if ($Json.output) {
            foreach ($item in $Json.output) {
                if ($item.type -eq 'message' -and $item.content) {
                    foreach ($c in $item.content) {
                        if ($c.type -eq 'output_text' -and $c.text) { 
                            return $c.text 
                        }
                    }
                }
            }
            # Legacy shape
            if ($Json.output[0].content[0].text) { 
                return $Json.output[0].content[0].text 
            }
        }
        if ($Json.output_text) { 
            return $Json.output_text 
        }
        if ($Json.choices -and $Json.choices[0].message.content) { 
            return $Json.choices[0].message.content 
        }
    } catch {
        Write-Verbose "Error extracting output text: $_"
    }
    
    return $FallbackContent
}

