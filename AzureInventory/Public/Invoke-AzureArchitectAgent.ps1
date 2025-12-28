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
        [string]$Model = "gpt-4o-mini",
        
        [Parameter(Mandatory = $false)]
        [string]$OutputPath
    )
    
    Write-Host "Invoking Azure Architect AI Agent..." -ForegroundColor Cyan
    
    # Get module root to find prompt files
    $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    
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
    Write-Verbose "Calling OpenAI API with model: $Model"
    $startTime = Get-Date
    
    try {
        $response = Invoke-OpenAIAnalysis `
            -SystemPrompt $systemPrompt `
            -UserPrompt $userPrompt `
            -ApiKey $ApiKey `
            -Model $Model `
            -MaxOutputTokens 8000 `
            -TimeoutSeconds 120
        
        $duration = (Get-Date) - $startTime
        
        if (-not $response.Success) {
            throw "OpenAI API request failed"
        }
        
        # Extract analysis text
        $analysis = if ($response.Text) {
            $response.Text
        } elseif ($response.Parsed) {
            # Try to extract from parsed object
            if ($response.Parsed.executive_summary) {
                # Structured response
                $response.Parsed | ConvertTo-Json -Depth 10
            } else {
                $response.Parsed | ConvertTo-Json -Depth 10
            }
        } else {
            "Analysis completed but no text content available."
        }
        
        # Log token usage and cost
        $inputTokens = $response.InputTokens
        $estimatedCost = $response.EstimatedCost
        
        Write-Host "  AI Analysis Complete" -ForegroundColor Green
        Write-Host "    Duration: $($duration.TotalSeconds.ToString('F1')) seconds" -ForegroundColor Gray
        Write-Host "    Tokens: ~$inputTokens (estimated)" -ForegroundColor Gray
        Write-Host "    Estimated Cost: `$$($estimatedCost.ToString('F4'))" -ForegroundColor Gray
        
        # Save output if path provided
        if ($OutputPath) {
            $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
            $outputFile = Join-Path $OutputPath "AI_Analysis_$timestamp.txt"
            $analysis | Out-File $outputFile -Encoding UTF8
            Write-Host "  Analysis saved: $outputFile" -ForegroundColor Green
            
            # Also save metadata
            $metadataFile = Join-Path $OutputPath "AI_Metadata_$timestamp.json"
            @{
                timestamp = $timestamp
                model = $Model
                duration_seconds = $duration.TotalSeconds
                token_usage = @{
                    input = $inputTokens
                    estimated = $true
                }
                estimated_cost = $estimatedCost
                finish_reason = if ($response.Raw) { "completed" } else { "unknown" }
            } | ConvertTo-Json | Out-File $metadataFile -Encoding UTF8
        }
        
        return @{
            Success = $true
            Analysis = $analysis
            Metadata = @{
                Model = $Model
                Duration = $duration
                TokenUsage = @{
                    Input = $inputTokens
                    Estimated = $true
                }
                EstimatedCost = $estimatedCost
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

