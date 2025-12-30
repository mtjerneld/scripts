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
        [string]$Model,
        
        [Parameter(Mandatory = $false)]
        [int]$MaxOutputTokens = 8000,
        
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 60,
        
        [Parameter(Mandatory = $false)]
        [double]$MaxCostPerRun = 0.10,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('json', 'markdown')]
        [string]$OutputFormat = 'json'
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
    
    # Build request
    $baseUrl = 'https://api.openai.com/v1'
    $url = "$baseUrl/responses"
    $modelToUse = if ($Model) { $Model } elseif ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { 'gpt-4o-mini' }
    
    # Check if model is a reasoning model (gpt-5 series)
    $isReasoningModel = $modelToUse -match '^gpt-5'
    
    # Get max output tokens from environment variable if set, otherwise use parameter default
    $maxOutputTokensToUse = if ($env:OPENAI_MAX_OUTPUT_TOKENS) {
        [int]$env:OPENAI_MAX_OUTPUT_TOKENS
    } else {
        $MaxOutputTokens
    }
    
    # Estimate input tokens
    $inputTokens = Get-EstimatedTokens -Text ($SystemPrompt + $UserPrompt)
    
    # Get pricing from environment or use defaults (per 1M tokens, matching OpenAI's pricing format)
    $priceIn = if ($env:OPENAI_PRICE_INPUT_PER_1M_USD) { [double]$env:OPENAI_PRICE_INPUT_PER_1M_USD } else { 5.0 }
    $priceOut = if ($env:OPENAI_PRICE_OUTPUT_PER_1M_USD) { [double]$env:OPENAI_PRICE_OUTPUT_PER_1M_USD } else { 15.0 }
    $maxCost = if ($env:OPENAI_MAX_COST_USD_PER_RUN) { [double]$env:OPENAI_MAX_COST_USD_PER_RUN } else { $MaxCostPerRun }
    
    # Calculate costs (convert tokens to millions for pricing)
    $inputCost = [Math]::Round((($inputTokens/1000000.0)*$priceIn), 4)
    $allowedOutputCost = $maxCost - $inputCost
    $allowedOutputTokens = if ($allowedOutputCost -gt 0) { 
        [int][Math]::Floor(($allowedOutputCost / $priceOut) * 1000000) 
    } else { 
        0 
    }
    
    # If OPENAI_MAX_OUTPUT_TOKENS is explicitly set, use it (but warn if cost constraint would limit it)
    # Otherwise, apply cost constraint
    if ($env:OPENAI_MAX_OUTPUT_TOKENS) {
        $effectiveMaxOutput = [int]$maxOutputTokensToUse
        if ($allowedOutputTokens -lt $maxOutputTokensToUse) {
            Write-Warning "OPENAI_MAX_OUTPUT_TOKENS=$maxOutputTokensToUse is set, but cost constraint (OPENAI_MAX_COST_USD_PER_RUN=$maxCost) would limit it to $allowedOutputTokens tokens. Consider increasing OPENAI_MAX_COST_USD_PER_RUN if you need more tokens."
        }
    } else {
        $effectiveMaxOutput = [int][Math]::Max(0, [int][Math]::Min($maxOutputTokensToUse, $allowedOutputTokens))
    }
    
    $costEstimate = [Math]::Round($inputCost + (($effectiveMaxOutput/1000000.0)*$priceOut), 4)
    
    Write-Verbose "Cost cap: $maxCost | Input est: $inputCost | Allowed out tokens: $allowedOutputTokens | Requested: $maxOutputTokensToUse | Using: $effectiveMaxOutput | Est total: $costEstimate"
    if ($env:OPENAI_MAX_OUTPUT_TOKENS) {
        Write-Host "Using OPENAI_MAX_OUTPUT_TOKENS=$maxOutputTokensToUse (cost estimate: `$$costEstimate)" -ForegroundColor Gray
    }
    
    if ($effectiveMaxOutput -le 0) { 
        throw ("Estimated cost $inputCost exceeds cap $maxCost. Increase OPENAI_MAX_COST_USD_PER_RUN or reduce input size.") 
    }
    
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
    
    $verbosityLevel = if ($isReasoningModel) { 'low' } else { 'medium' }
    
    # Build request body
    $bodyObj = [ordered]@{
        model = $modelToUse
        max_output_tokens = $effectiveMaxOutput
        input = $inputBlocks
    }
    
    # Add format constraint only for JSON output
    if ($OutputFormat -eq 'json') {
        $bodyObj['text'] = [ordered]@{
            format = [ordered]@{
                type = 'json_schema'
                name = 'governance_analysis'
                strict = $false  # Allow flexibility for governance analysis
                schema = $flexibleSchema
            }
            verbosity = $verbosityLevel
        }
    } else {
        # For markdown, use plain text format (no format constraint)
        $bodyObj['text'] = [ordered]@{
            verbosity = $verbosityLevel
        }
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
    
    # Extract actual token usage from response (do this once, before format checks)
    $actualInputTokens = $inputTokens  # Keep estimated as fallback
    $actualOutputTokens = $null
    $actualReasoningTokens = $null
    
    if ($json.usage) {
        if ($json.usage.input_tokens) {
            $actualInputTokens = [int]$json.usage.input_tokens
        }
        if ($json.usage.output_tokens) {
            $actualOutputTokens = [int]$json.usage.output_tokens
        }
        # For reasoning models, check for reasoning tokens
        if ($json.usage.output_tokens_details -and $json.usage.output_tokens_details.reasoning_tokens) {
            $actualReasoningTokens = [int]$json.usage.output_tokens_details.reasoning_tokens
        }
    }
    
    # Recalculate actual cost with real token counts if available
    $actualCost = $costEstimate
    $actualInputCost = [Math]::Round((($actualInputTokens/1000000.0)*$priceIn), 4)
    $actualOutputCost = if ($actualOutputTokens) {
        [Math]::Round((($actualOutputTokens/1000000.0)*$priceOut), 4)
    } else {
        # Estimate output cost based on max output tokens if actual not available
        [Math]::Round((($effectiveMaxOutput/1000000.0)*$priceOut), 4)
    }
    $actualCost = [Math]::Round($actualInputCost + $actualOutputCost, 4)
    
    # Check for truncation indicators in output messages
    $truncated = $false
    $truncationReason = $null
    if ($json.output) {
        foreach ($outputItem in $json.output) {
            if ($outputItem.type -eq 'message' -and $outputItem.finish_reason) {
                # finish_reason can be: "completed", "length", "stop", "content_filter", etc.
                # "length" means it was truncated due to max_output_tokens
                if ($outputItem.finish_reason -eq 'length') {
                    $truncated = $true
                    $truncationReason = "Response truncated due to max_output_tokens limit"
                    break
                }
            }
        }
    }
    
    # Warn if output tokens are close to the limit (within 5%)
    if ($actualOutputTokens -and $effectiveMaxOutput -gt 0) {
        $usagePercent = ($actualOutputTokens / $effectiveMaxOutput) * 100
        if ($usagePercent -ge 95) {
            Write-Warning "Output token usage is very high ($usagePercent% of max). Response may be truncated. Consider increasing OPENAI_MAX_OUTPUT_TOKENS."
        }
    }
    
    # Check for incomplete response and handle appropriately
    if ($json.status -eq 'incomplete' -or $truncated) {
        $incompleteReason = if ($truncated) { 
            $truncationReason 
        } elseif ($json.incomplete_details) { 
            $json.incomplete_details.reason 
        } else { 
            'unknown' 
        }
        $actualMaxTokens = if ($json.max_output_tokens) { $json.max_output_tokens } else { 'unknown' }
        Write-Warning "Response is incomplete (reason: $incompleteReason, max_output_tokens sent: $actualMaxTokens, requested: $effectiveMaxOutput, actual output: $actualOutputTokens)"
        
        # For markdown format with incomplete response, try to extract any available text
        if ($OutputFormat -eq 'markdown') {
            $textPayload = Get-FirstResponsesOutputText -Json $json -FallbackContent $resp
            # If we only got the raw JSON, indicate it's incomplete
            if ($textPayload -eq $resp -or $textPayload -match '^\s*\{') {
                $errorMsg = "Response incomplete due to $incompleteReason. max_output_tokens sent: $actualMaxTokens. "
                if ($env:OPENAI_MAX_OUTPUT_TOKENS) {
                    $errorMsg += "You have OPENAI_MAX_OUTPUT_TOKENS=$maxOutputTokensToUse set. "
                }
                $errorMsg += "Consider increasing OPENAI_MAX_OUTPUT_TOKENS further or reducing input size."
                throw $errorMsg
            }
            return [PSCustomObject]@{
                Success = $true
                Raw = $json
                Text = $textPayload
                InputTokens = $actualInputTokens
                OutputTokens = $actualOutputTokens
                ReasoningTokens = $actualReasoningTokens
                InputCost = $actualInputCost
                OutputCost = $actualOutputCost
                EstimatedCost = $actualCost
                Model = $modelToUse
                Incomplete = $true
                IncompleteReason = $incompleteReason
                Truncated = $truncated
            }
        } else {
            throw "Response incomplete (reason: $incompleteReason, max_output_tokens sent: $actualMaxTokens). Consider increasing OPENAI_MAX_OUTPUT_TOKENS."
        }
    }
    
    # For markdown format, always extract text directly (no JSON parsing)
    if ($OutputFormat -eq 'markdown') {
        $textPayload = Get-FirstResponsesOutputText -Json $json -FallbackContent $resp
        return [PSCustomObject]@{
            Success = $true
            Raw = $json
            Text = $textPayload
            InputTokens = $actualInputTokens
            OutputTokens = $actualOutputTokens
            ReasoningTokens = $actualReasoningTokens
            InputCost = $actualInputCost
            OutputCost = $actualOutputCost
            EstimatedCost = $actualCost
            Model = $modelToUse
            Truncated = $truncated
        }
    }
    
    # For JSON format, try to parse structured response
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
            InputTokens = $actualInputTokens
            OutputTokens = $actualOutputTokens
            ReasoningTokens = $actualReasoningTokens
            InputCost = $actualInputCost
            OutputCost = $actualOutputCost
            EstimatedCost = $actualCost
            Model = $modelToUse
            Truncated = $truncated
        }
    } else {
        # Fallback to text extraction
        $textPayload = Get-FirstResponsesOutputText -Json $json -FallbackContent $resp
        return [PSCustomObject]@{
            Success = $true
            Raw = $json
            Text = $textPayload
            InputTokens = $actualInputTokens
            OutputTokens = $actualOutputTokens
            ReasoningTokens = $actualReasoningTokens
            InputCost = $actualInputCost
            OutputCost = $actualOutputCost
            EstimatedCost = $actualCost
            Model = $modelToUse
            Truncated = $truncated
        }
    }
}

