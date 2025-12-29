<#
.SYNOPSIS
    Sends governance insights to Azure Architect AI agent for analysis.

.DESCRIPTION
    Takes combined JSON payload of governance insights and sends to OpenAI
    for expert analysis and recommendations. Returns structured recommendations
    with priorities and action plans.

.PARAMETER GovernanceDataJson
    Combined JSON payload of governance insights.

.PARAMETER ApiKey
    OpenAI API key.

.PARAMETER Model
    OpenAI model to use (default: gpt-4o-mini).

.PARAMETER OutputPath
    Path to save AI analysis output.

.EXAMPLE
    $analysis = Invoke-AzureArchitectAgent -GovernanceDataJson $json -ApiKey $key
#>
function Invoke-AzureArchitectAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GovernanceDataJson,
        
        [Parameter(Mandatory = $false)]
        [string]$ApiKey = $env:OPENAI_API_KEY,
        
        [Parameter(Mandatory = $false)]
        [string]$Model,
        
        [Parameter(Mandatory = $false)]
        [string]$OutputPath
    )
    
    Write-Host "Invoking Azure Architect AI Agent..." -ForegroundColor Cyan
    
    # Determine model to use (parameter > env var > default)
    $modelToUse = if ($Model) { $Model } elseif ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { "gpt-4o-mini" }
    
    # Get module root to find prompt files
    # Try to find module root by looking for AzureSecurityAudit.psm1 (more robust)
    $moduleRoot = $null
    $currentPath = $PSScriptRoot
    while ($currentPath -and -not $moduleRoot) {
        if (Test-Path (Join-Path $currentPath "AzureSecurityAudit.psm1")) {
            $moduleRoot = $currentPath
            break
        }
        $parentPath = Split-Path -Parent $currentPath
        if ($parentPath -eq $currentPath) { break }
        $currentPath = $parentPath
    }
    
    # Fallback: assume we're in Public (go up one level)
    if (-not $moduleRoot) {
        $moduleRoot = Split-Path -Parent $PSScriptRoot
    }
    
    # Load system prompt
    $systemPromptPath = Join-Path $moduleRoot "Config\Prompts\SystemPrompt.txt"
    if (-not (Test-Path $systemPromptPath)) {
        throw "System prompt file not found: $systemPromptPath"
    }
    $systemPrompt = Get-Content $systemPromptPath -Raw
    
    # Load and populate user prompt template
    $userPromptPath = Join-Path $moduleRoot "Config\Prompts\UserPromptTemplate.txt"
    if (-not (Test-Path $userPromptPath)) {
        throw "User prompt template file not found: $userPromptPath"
    }
    $userPromptTemplate = Get-Content $userPromptPath -Raw
    $userPrompt = $userPromptTemplate -replace '{{GOVERNANCE_DATA_JSON}}', $GovernanceDataJson
    
    # Estimate token count (rough approximation: 1 token ≈ 4 characters)
    $estimatedInputTokens = [math]::Ceiling(($systemPrompt.Length + $userPrompt.Length) / 4)
    Write-Verbose "Estimated input tokens: $estimatedInputTokens"
    
    if ($estimatedInputTokens -gt 50000) {
        Write-Warning "Input token count is high ($estimatedInputTokens). Consider reducing data payload."
    }
    
    # Ensure Invoke-OpenAIAnalysis is available
    if (-not (Get-Command -Name Invoke-OpenAIAnalysis -ErrorAction SilentlyContinue)) {
        $helperPath = Join-Path $moduleRoot "Private\Helpers\Invoke-OpenAIAnalysis.ps1"
        if (Test-Path $helperPath) {
            . $helperPath
        }
    }
    
    if (-not (Get-Command -Name Invoke-OpenAIAnalysis -ErrorAction SilentlyContinue)) {
        throw "Invoke-OpenAIAnalysis function not available. Cannot proceed with AI analysis."
    }
    
    # Call OpenAI API
    Write-Verbose "Calling OpenAI API with model: $modelToUse"
    $startTime = Get-Date
    
    try {
        # Determine timeout from environment variable or use default
        $timeoutSeconds = if ($env:OPENAI_TIMEOUT_SECONDS) { 
            [int]$env:OPENAI_TIMEOUT_SECONDS 
        } else { 
            120  # Default timeout
        }
        
        $response = Invoke-OpenAIAnalysis `
            -SystemPrompt $systemPrompt `
            -UserPrompt $userPrompt `
            -ApiKey $ApiKey `
            -Model $modelToUse `
            -MaxOutputTokens 8000 `
            -TimeoutSeconds $timeoutSeconds `
            -OutputFormat 'markdown'
        
        $duration = (Get-Date) - $startTime
        
        if (-not $response.Success) {
            throw "OpenAI API request failed"
        }
        
        # Extract analysis text (for markdown format, use Text directly)
        $analysis = if ($response.Text) {
            $response.Text
        } elseif ($response.Parsed) {
            # Fallback: if we got parsed JSON, convert to markdown-like format
            # This shouldn't happen with markdown format, but handle gracefully
            $response.Parsed | ConvertTo-Json -Depth 10
        } else {
            "Analysis completed but no text content available."
        }
        
        # Log token usage and cost
        $inputTokens = $response.InputTokens
        $outputTokens = $response.OutputTokens
        $reasoningTokens = $response.ReasoningTokens
        $inputCost = $response.InputCost
        $outputCost = $response.OutputCost
        $actualCost = $response.EstimatedCost
        
        Write-Host "  AI Analysis Complete" -ForegroundColor Green
        Write-Host "    Duration: $($duration.TotalSeconds.ToString('F1')) seconds" -ForegroundColor Gray
        if ($outputTokens) {
            Write-Host "    Tokens: $inputTokens input, $outputTokens output" -ForegroundColor Gray
            if ($reasoningTokens) {
                Write-Host "      (including $reasoningTokens reasoning tokens)" -ForegroundColor Gray
            }
        } else {
            Write-Host "    Tokens: ~$inputTokens (estimated)" -ForegroundColor Gray
        }
        Write-Host "    Cost: `$$($actualCost.ToString('F4')) total" -ForegroundColor Gray
        Write-Host "      Input: `$$($inputCost.ToString('F4')) ($inputTokens tokens)" -ForegroundColor Gray
        if ($outputTokens) {
            Write-Host "      Output: `$$($outputCost.ToString('F4')) ($outputTokens tokens)" -ForegroundColor Gray
        } else {
            Write-Host "      Output: `$$($outputCost.ToString('F4')) (estimated)" -ForegroundColor Gray
        }
        
        # Check for truncation
        if ($response.Truncated) {
            Write-Warning "  ⚠️  Response was TRUNCATED due to max_output_tokens limit!"
            Write-Warning "     Consider increasing OPENAI_MAX_OUTPUT_TOKENS to get the full analysis."
        } elseif ($response.Incomplete) {
            Write-Warning "  ⚠️  Response is INCOMPLETE: $($response.IncompleteReason)"
            Write-Warning "     Consider increasing OPENAI_MAX_OUTPUT_TOKENS or reducing input size."
        }
        
        # Save output if path provided
        if ($OutputPath) {
            $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
            $outputFile = Join-Path $OutputPath "AI_Analysis_$timestamp.md"
            $analysis | Out-File $outputFile -Encoding UTF8
            Write-Host "  Analysis saved: $outputFile" -ForegroundColor Green
            
            # Also save metadata
            $metadataFile = Join-Path $OutputPath "AI_Metadata_$timestamp.json"
            $tokenUsage = @{
                input = $inputTokens
            }
            if ($outputTokens) {
                $tokenUsage.output = $outputTokens
                $tokenUsage.estimated = $false
            } else {
                $tokenUsage.estimated = $true
            }
            if ($reasoningTokens) {
                $tokenUsage.reasoning = $reasoningTokens
            }
            
            $costBreakdown = @{
                total = $actualCost
                input = $inputCost
                output = $outputCost
            }
            
            $metadataObj = @{
                timestamp = $timestamp
                model = $Model
                duration_seconds = $duration.TotalSeconds
                token_usage = $tokenUsage
                cost = $costBreakdown
                finish_reason = if ($response.Raw -and $response.Raw.status) { $response.Raw.status } else { "completed" }
            }
            
            # Add truncation/incomplete flags if present
            if ($response.Truncated) {
                $metadataObj.truncated = $true
                $metadataObj.truncation_reason = "Response truncated due to max_output_tokens limit"
            }
            if ($response.Incomplete) {
                $metadataObj.incomplete = $true
                $metadataObj.incomplete_reason = $response.IncompleteReason
            }
            
            $metadataObj | ConvertTo-Json | Out-File $metadataFile -Encoding UTF8
        }
        
        return @{
            Success = $true
            Analysis = $analysis
            Metadata = @{
                Model = $Model
                Duration = $duration
                TokenUsage = @{
                    Input = $inputTokens
                    Output = $outputTokens
                    Reasoning = $reasoningTokens
                    Estimated = if ($outputTokens) { $false } else { $true }
                }
                Cost = @{
                    Total = $actualCost
                    Input = $inputCost
                    Output = $outputCost
                }
                EstimatedCost = $actualCost  # Keep for backward compatibility
                Truncated = if ($response.Truncated) { $true } else { $false }
                Incomplete = if ($response.Incomplete) { $true } else { $false }
                IncompleteReason = if ($response.IncompleteReason) { $response.IncompleteReason } else { $null }
                Timestamp = Get-Date
            }
            RawResponse = $response
        }
    }
    catch {
        Write-Error "AI analysis failed: $_"
        return @{
            Success = $false
            Error = $_.Exception.Message
            ErrorDetails = $_
        }
    }
}

