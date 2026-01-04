function Test-RetryAIAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$JsonFilePath,
        
        [Parameter(Mandatory = $false)]
        [string]$Model
    )
    
    Write-Host "`n=== Retry AI Analysis with Existing JSON ===" -ForegroundColor Cyan
    
    # Check if Invoke-AzureArchitectAgent is available
    if (-not (Get-Command -Name Invoke-AzureArchitectAgent -ErrorAction SilentlyContinue)) {
        Write-Error "Invoke-AzureArchitectAgent function not found. Make sure Init-Local.ps1 has loaded all functions."
        return
    }
    
    # If no JSON file path provided, find the latest one in output folder
    if ([string]::IsNullOrWhiteSpace($JsonFilePath)) {
        Write-Host "No JSON file specified, searching for latest AI_Insights_Payload JSON file..." -ForegroundColor Gray
        $outputFolder = Join-Path (Get-Location) "output"
        if (Test-Path $outputFolder) {
            $jsonFiles = Get-ChildItem -Path $outputFolder -Recurse -Filter "AI_Insights_Payload_*.json" -ErrorAction SilentlyContinue | 
                Sort-Object LastWriteTime -Descending
            if ($jsonFiles.Count -gt 0) {
                $JsonFilePath = $jsonFiles[0].FullName
                Write-Host "Found latest JSON file: $JsonFilePath" -ForegroundColor Green
            }
        }
        
        if ([string]::IsNullOrWhiteSpace($JsonFilePath)) {
            Write-Error "No AI_Insights_Payload JSON file found in output folder. Please specify -JsonFilePath parameter or run an audit first."
            return
        }
    }
    
    # Resolve the JSON file path
    if (-not [System.IO.Path]::IsPathRooted($JsonFilePath)) {
        $JsonFilePath = Join-Path (Get-Location) $JsonFilePath
    }
    
    if (-not (Test-Path $JsonFilePath)) {
        Write-Error "JSON file not found: $JsonFilePath"
        return
    }
    
    Write-Host "Loading JSON from: $JsonFilePath" -ForegroundColor Gray
    
    # Read the JSON file
    try {
        $json = Get-Content $JsonFilePath -Raw -Encoding UTF8
    }
    catch {
        Write-Error "Failed to read JSON file: $_"
        return
    }
    
    # Get the output folder (same folder as the JSON file)
    $outputFolder = Split-Path -Parent $JsonFilePath
    
    Write-Host "Output folder: $outputFolder" -ForegroundColor Gray
    
    # Determine model to use (parameter > env var > default)
    $modelToUse = if ($Model) { $Model } elseif ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { "gpt-4o-mini" }
    Write-Host "Model: $modelToUse" -ForegroundColor Gray
    
    # Call the AI agent
    Write-Host "`nInvoking AI analysis..." -ForegroundColor Cyan
    try {
        $result = Invoke-AzureArchitectAgent `
            -GovernanceDataJson $json `
            -Model $modelToUse `
            -OutputPath $outputFolder
        
        if ($result.Success) {
            Write-Host "`n[SUCCESS] AI Analysis completed successfully!" -ForegroundColor Green
            Write-Host "  Analysis saved to: $outputFolder" -ForegroundColor Gray
            if ($result.Metadata) {
                Write-Host "  Estimated cost: `$$($result.Metadata.EstimatedCost.ToString('F4'))" -ForegroundColor Gray
                Write-Host "  Duration: $([math]::Round($result.Metadata.Duration.TotalSeconds, 1)) seconds" -ForegroundColor Gray
            }
        }
        else {
            Write-Error "AI Analysis failed: $($result.Error)"
        }
    }
    catch {
        Write-Error "Failed to invoke AI analysis: $_"
        Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) {
            Write-Host "Inner exception: $($_.Exception.InnerException.Message)" -ForegroundColor Red
        }
    }
}
