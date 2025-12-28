@{
    # OpenAI Configuration
    OpenAI = @{
        APIEndpoint = "https://api.openai.com/v1/responses"
        Model = "gpt-4o-mini"  # Default model (can be overridden)
        Temperature = 0.7
        MaxOutputTokens = 8000
        TopP = 1.0
    }
    
    # Token Budget Limits (safety controls)
    TokenBudget = @{
        CostInsights = 12000        # Max tokens for cost data
        SecurityInsights = 15000     # Max tokens for security data
        TotalInput = 50000          # Max total input tokens
        MaxOutput = 8000             # Max output tokens
    }
    
    # Data Filtering Thresholds
    Filtering = @{
        CostTopN = 15                # Top N cost opportunities
        SecurityCriticalOnly = $true  # Only critical/high severity
        SecurityTopN = 20             # Top N security issues
        MinimumSavingsThreshold = 100 # Minimum annual savings to include
        EOLDaysThreshold = 90         # Only EOL within N days
    }
    
    # Output Options
    Output = @{
        SavePayloadJSON = $true      # Save combined JSON payload
        SaveAIResponse = $true       # Save raw AI response
        GenerateCombinedHTML = $true # Generate HTML with AI section
        VerboseLogging = $true       # Detailed logging
    }
    
    # Rate Limiting
    RateLimit = @{
        MaxRequestsPerMinute = 10
        RetryAttempts = 3
        RetryDelaySeconds = 2
    }
    
    # Cost Control (from mailchecker pattern)
    CostControl = @{
        MaxCostPerRun = 0.10         # Maximum cost in USD per analysis run
        PriceInputPer1K = 0.005      # Input token price per 1K tokens
        PriceOutputPer1K = 0.015     # Output token price per 1K tokens
    }
}

