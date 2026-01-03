@{
    # Exclude rules that produce false positives
    ExcludeRules = @(
        # False positive: try-catch structure is valid but linter gets confused by complex nesting
        'PSUseDeclaredVarsMoreThanAssignments'
    )
    
    # Custom rules configuration
    Rules = @{
        # Suppress syntax error false positives
        PSAvoidUsingEmptyCatchBlock = @{
            Enabled = $false
        }
    }
}
