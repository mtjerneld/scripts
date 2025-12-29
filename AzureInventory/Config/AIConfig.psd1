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
        AdvisorInsights = 15000       # Max tokens for Advisor recommendations (all categories)
        CostInsights = 12000           # Max tokens for cost data (deprecated - use AdvisorInsights)
        SecurityInsights = 15000      # Max tokens for security data
        RBACInsights = 10000          # Max tokens for RBAC data
        NetworkInsights = 12000       # Max tokens for network data
        EOLInsights = 8000            # Max tokens for EOL data
        ChangeTrackingInsights = 10000 # Max tokens for change tracking data
        VMBackupInsights = 8000       # Max tokens for VM backup data
        CostTrackingInsights = 12000  # Max tokens for cost tracking data
        TotalInput = 50000            # Max total input tokens
        MaxOutput = 8000              # Max output tokens
    }
    
    # Data Filtering Thresholds
    Filtering = @{
        AdvisorTopN = 15              # Top N Advisor recommendations per category
        CostTopN = 15                 # Top N cost opportunities (deprecated)
        SecurityCriticalOnly = $true  # Only critical/high severity
        SecurityTopN = 20             # Top N security issues
        RBACTopN = 20                  # Top N RBAC risks
        NetworkTopN = 20               # Top N network risks
        EOLTopN = 20                   # Top N EOL findings
        EOLDaysThreshold = 90          # Only EOL within N days
        ChangeTrackingTopN = 20        # Top N change tracking findings
        VMBackupTopN = 20              # Top N VM backup findings
        CostTrackingTopN = 20          # Top N cost tracking items
        MinimumSavingsThreshold = 100   # Minimum annual savings to include
        BackupAgeThreshold = 30        # Days since last backup to consider as gap
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

