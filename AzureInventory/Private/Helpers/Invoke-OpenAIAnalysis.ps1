<#
.SYNOPSIS
    Invokes OpenAI Responses API for governance data analysis.

.DESCRIPTION
    Adapted from mailchecker.ps1 to work with Azure governance data.
    Uses Responses API endpoint with structured JSON output.
    Includes token counting, cost estimation, and retry logic.

.PARAMETER SystemPrompt
    System prompt text for the AI agent.

.PARAMETER UserPrompt
    User prompt text (should include governance data JSON).

.PARAMETER ApiKey
    OpenAI API key (can also use OPENAI_API_KEY environment variable).

.PARAMETER Model
    OpenAI model to use (default: gpt-4o-mini).

.PARAMETER MaxOutputTokens
    Maximum output tokens (default: 8000).

.PARAMETER TimeoutSeconds
    Request timeout in seconds (default: 60).

.PARAMETER MaxCostPerRun
    Maximum cost in USD per run (default: 0.10).

.EXAMPLE
    $result = Invoke-OpenAIAnalysis -SystemPrompt $sysPrompt -UserPrompt $userPrompt -ApiKey $key
#>
function Invoke-OpenAIAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SystemPrompt,
        
        [Parameter(Mandatory = $true)]
        [string]$UserPrompt,
        
        [Parameter(Mandatory = $false)]
        [string]$ApiKey = $env:OPENAI_API_KEY,
        
        [Parameter(Mandatory = $false)]
        [string]$Model = "gpt-4o-mini",
        
        [Parameter(Mandatory = $false)]
        [int]$MaxOutputTokens = 8000,
        
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 60,
        
        [Parameter(Mandatory = $false)]
        [double]$MaxCostPerRun = 0.10
    )
    
    # Validate API key
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw "OpenAI API key not provided. Set via -ApiKey parameter or OPENAI_API_KEY environment variable."
    }
    
    # Token estimation helper (simple approximation: 1 token ≈ 4 characters)
    function Get-EstimatedTokens {
        param([string]$Text)
        if ($null -eq $Text) { return 0 }
        return [int][Math]::Ceiling(($Text.Length) / 4)
    }
    
    # Normalize content types for Responses API
    function ConvertTo-NormalizedResponsesContentTypes {
        param([Parameter(Mandatory=$true)][hashtable]$BodyObj)
        if (-not $BodyObj.input) { return $BodyObj }
        foreach ($blk in $BodyObj.input) {
            if (-not $blk.content) { continue }
            for ($i=0; $i -lt $blk.content.Count; $i++) {
                if ($blk.content[$i].type -ne 'input_text') { 
                    $blk.content[$i].type = 'input_text' 
                }
            }
        }
        return $BodyObj
    }
    
    # Estimate input tokens
    $inputTokens = Get-EstimatedTokens -Text ($SystemPrompt + $UserPrompt)
    
    # Get pricing from environment or use defaults
    $priceIn = [double]([double]$env:OPENAI_PRICE_INPUT_PER_1K_USD | ForEach-Object { if ($_ -gt 0) { $_ } else { 0.005 } })
    $priceOut = [double]([double]$env:OPENAI_PRICE_OUTPUT_PER_1K_USD | ForEach-Object { if ($_ -gt 0) { $_ } else { 0.015 } })
    $maxCost = [double]([double]$env:OPENAI_MAX_COST_USD_PER_RUN | ForEach-Object { if ($_ -gt 0) { $_ } else { $MaxCostPerRun } })
    
    # Calculate costs
    $inputCost = [Math]::Round((($inputTokens/1000.0)*$priceIn), 4)
    $allowedOutputCost = $maxCost - $inputCost
    $allowedOutputTokens = if ($allowedOutputCost -gt 0) { 
        [int][Math]::Floor(($allowedOutputCost / $priceOut) * 1000) 
    } else { 
        0 
    }
    $effectiveMaxOutput = [int][Math]::Max(0, [int][Math]::Min($MaxOutputTokens, $allowedOutputTokens))
    $costEstimate = [Math]::Round($inputCost + (($effectiveMaxOutput/1000.0)*$priceOut), 4)
    
    Write-Verbose "Cost cap: $maxCost | Input est: $inputCost | Allowed out tokens: $allowedOutputTokens | Using out tokens: $effectiveMaxOutput | Est total: $costEstimate"
    
    if ($effectiveMaxOutput -le 0) { 
        throw ("Estimated cost $inputCost exceeds cap $maxCost.") 
    }
    
    # Build request
    $baseUrl = 'https://api.openai.com/v1'
    $url = "$baseUrl/responses"
    $modelToUse = if ($Model) { $Model } elseif ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { 'gpt-4o-mini' }
    
    Write-Verbose "Building JSON payload..."
    $swBuild = [Diagnostics.Stopwatch]::StartNew()
    
    # Use flexible JSON schema for governance analysis (not mailchecker-specific)
    $flexibleSchema = [ordered]@{
        type = 'object'
        properties = [ordered]@{
            executive_summary = @{ type = 'string' }
            strategic_priorities = @{ 
                type = 'array'
                items = @{ type = 'object' }
            }
            cost_optimization_roadmap = @{ type = 'object' }
            security_compliance_actions = @{ type = 'object' }
            infrastructure_modernization = @{ type = 'object' }
            cross_cutting_insights = @{ type = 'object' }
        }
        required = @('executive_summary')
        additionalProperties = $true  # Allow flexibility
    }
    
    # Build input blocks
    $inputBlocks = @(
        @{ role = 'system'; content = @(@{ type = 'input_text'; text = $SystemPrompt }) },
        @{ role = 'user'; content = @(@{ type = 'input_text'; text = $UserPrompt }) }
    )
    
    # Sanitize content part types
    foreach ($blk in $inputBlocks) {
        if ($blk.content) {
            for ($i=0; $i -lt $blk.content.Count; $i++) {
                if ($blk.content[$i].type -ne 'input_text') { 
                    $blk.content[$i].type = 'input_text' 
                }
            }
        }
    }
    
    # Check if model is a reasoning model (gpt-5 series)
    $isReasoningModel = $modelToUse -match '^gpt-5'
    $verbosityLevel = if ($isReasoningModel) { 'low' } else { 'medium' }
    
    # Build request body
    $bodyObj = [ordered]@{
        model = $modelToUse
        max_output_tokens = $effectiveMaxOutput
        text = [ordered]@{
            format = [ordered]@{
                type = 'json_schema'
                name = 'governance_analysis'
                strict = $false  # Allow flexibility for governance analysis
                schema = $flexibleSchema
            }
            verbosity = $verbosityLevel
        }
        input = $inputBlocks
    }
    
    # Add reasoning parameter for reasoning models
    if ($isReasoningModel) {
        $reasoningEffort = if ($env:OPENAI_REASONING_EFFORT) { $env:OPENAI_REASONING_EFFORT } else { 'low' }
        $bodyObj['reasoning'] = [ordered]@{
            effort = $reasoningEffort
        }
    }
    
    # Normalize content types
    try {
        $null = ConvertTo-NormalizedResponsesContentTypes -BodyObj $bodyObj
    } catch {
        Write-Verbose "Content type normalization warning: $_"
    }
    
    $bodyJson = $bodyObj | ConvertTo-Json -Depth 100 -Compress
    $swBuild.Stop()
    Write-Verbose "Payload built in $($swBuild.ElapsedMilliseconds) ms"
    
    # Get timeout
    $timeout = if ($env:OPENAI_TIMEOUT_SECONDS) { [int]$env:OPENAI_TIMEOUT_SECONDS } else { $TimeoutSeconds }
    $bodyBytes = [System.Text.Encoding]::UTF8.GetByteCount($bodyJson)
    
    # Safety check
    if ($url -notmatch '^https://api\.openai\.com/v1/responses$') { 
        throw ("Safety check failed: URL ($url) is not OpenAI's official endpoint.") 
    }
    
    Write-Verbose "Endpoint: $url"
    Write-Verbose "Submitting request to OpenAI (input~$inputTokens tokens, max_output=$effectiveMaxOutput, timeout=$timeout s, body=$bodyBytes bytes)..."
    
    try {
        # Use HttpClient for the API call
        try { 
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 
        } catch {}
        try { 
            [System.Net.ServicePointManager]::Expect100Continue = $false 
        } catch {}
        
        Add-Type -AssemblyName System.Net.Http
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.UseProxy = $false
        $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds($timeout)
        $client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $ApiKey)
        $client.DefaultRequestHeaders.Accept.Clear()
        $client.DefaultRequestHeaders.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new('application/json'))
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('AzureSecurityAudit/1.0')
        
        $content = New-Object System.Net.Http.StringContent($bodyJson, [System.Text.Encoding]::UTF8, 'application/json')
        $swSend = [Diagnostics.Stopwatch]::StartNew()
        $httpResp = $client.PostAsync($url, $content).GetAwaiter().GetResult()
        $rawResp = $httpResp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $swSend.Stop()
        
        if (-not $httpResp.IsSuccessStatusCode) {
            try { 
                $errorPath = Join-Path (Get-Location) 'openai-error.json'
                [System.IO.File]::WriteAllText($errorPath, $rawResp, (New-Object System.Text.UTF8Encoding($false))) 
            } catch {}
            throw ("OpenAI request failed (HTTP $([int]$httpResp.StatusCode) $($httpResp.StatusCode)): $rawResp")
        }
        
        Write-Verbose "OpenAI HTTP OK in $($swSend.ElapsedMilliseconds) ms"
        $resp = $rawResp
    }
    catch {
        $we = $_.Exception
        throw ("OpenAI request failed: $($we.Message)")
    }
    
    # Parse response
    $json = $null
    if ($resp -is [string]) {
        if ($PSVersionTable.PSVersion.Major -ge 7) { 
            $json = $resp | ConvertFrom-Json -Depth 100 -ErrorAction SilentlyContinue 
        }
        else { 
            $json = $resp | ConvertFrom-Json -ErrorAction SilentlyContinue 
        }
    } else {
        $json = $resp
    }
    
    if ($null -eq $json) { 
        throw 'Failed to parse OpenAI response JSON' 
    }
    
    # Try to parse structured response
    $parsedObj = $null
    try { 
        $parsedObj = ConvertFrom-OpenAIResponseJson -RespObj $json 
    } catch {
        Write-Verbose "Could not parse structured JSON, using text fallback: $_"
    }
    
    if ($parsedObj) {
        return [PSCustomObject]@{
            Success = $true
            Raw = $json
            Parsed = $parsedObj
            Text = ($parsedObj | ConvertTo-Json -Depth 50)
            InputTokens = $inputTokens
            EstimatedCost = $costEstimate
            Model = $modelToUse
        }
    } else {
        # Fallback to text extraction
        $textPayload = Get-FirstResponsesOutputText -Json $json -FallbackContent $resp
        return [PSCustomObject]@{
            Success = $true
            Raw = $json
            Text = $textPayload
            InputTokens = $inputTokens
            EstimatedCost = $costEstimate
            Model = $modelToUse
        }
    }
}

