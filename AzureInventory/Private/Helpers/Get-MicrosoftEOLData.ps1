<#
.SYNOPSIS
    Retrieves Microsoft's official EOL data files from GitHub with local fallback.

.DESCRIPTION
    Downloads service_list.json and resource_list.kql from Azure/EOL GitHub repository.
    Caches files locally and falls back to bundled copies if download fails.

.PARAMETER ForceRefresh
    Force refresh of cached files even if they're recent.

.OUTPUTS
    PSCustomObject with:
    - ServiceList: Array of service EOL entries
    - ResourceListKQL: KQL query string for finding EOL resources
    - Source: "GitHub", "Cache", or "Fallback"
#>
function Get-MicrosoftEOLData {
    [CmdletBinding()]
    param(
        [switch]$ForceRefresh
    )
    
    $moduleRoot = $PSScriptRoot -replace '\\Private\\Helpers$', ''
    $cacheDir = Join-Path $moduleRoot "Config\EOLCache"
    $fallbackDir = Join-Path $moduleRoot "Config\EOLFallback"
    
    # Ensure directories exist
    if (-not (Test-Path $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }
    if (-not (Test-Path $fallbackDir)) {
        New-Item -ItemType Directory -Path $fallbackDir -Force | Out-Null
    }
    
    $serviceListPath = Join-Path $cacheDir "service_list.json"
    $kqlPath = Join-Path $cacheDir "resource_list.kql"
    $fallbackServiceListPath = Join-Path $fallbackDir "service_list.json"
    $fallbackKqlPath = Join-Path $fallbackDir "resource_list.kql"
    $lastUpdatePath = Join-Path $cacheDir "lastUpdate.txt"
    
    # GitHub URLs
    $serviceListUrl = "https://raw.githubusercontent.com/Azure/EOL/main/service_list.json"
    $kqlUrl = "https://raw.githubusercontent.com/Azure/EOL/main/resource_list.kql"
    
    $source = "Unknown"
    $shouldDownload = $false
    
    # Check if we should download (cache older than 7 days or forced)
    if ($ForceRefresh) {
        $shouldDownload = $true
        Write-Verbose "Force refresh requested, downloading from GitHub"
    }
    elseif (-not (Test-Path $serviceListPath) -or -not (Test-Path $kqlPath)) {
        $shouldDownload = $true
        Write-Verbose "Cache files not found, downloading from GitHub"
    }
    else {
        # Check cache age
        $lastUpdate = $null
        if (Test-Path $lastUpdatePath) {
            try {
                $lastUpdate = [DateTime]::Parse((Get-Content $lastUpdatePath -Raw).Trim())
            }
            catch {
                Write-Verbose "Could not parse lastUpdate timestamp, will refresh"
            }
        }
        
        if ($null -eq $lastUpdate -or ((Get-Date) - $lastUpdate).TotalDays -gt 7) {
            $shouldDownload = $true
            Write-Verbose "Cache is older than 7 days, downloading from GitHub"
        }
        else {
            Write-Verbose "Using cached EOL data (last updated: $lastUpdate)"
            $source = "Cache"
        }
    }
    
    # Try to download from GitHub
    if ($shouldDownload) {
        try {
            Write-Verbose "Downloading service_list.json from GitHub..."
            $serviceListResponse = Invoke-WebRequest -Uri $serviceListUrl -ErrorAction Stop -TimeoutSec 30 -UseBasicParsing
            $serviceListResponse.Content | Out-File -FilePath $serviceListPath -Encoding UTF8 -Force
            
            Write-Verbose "Downloading resource_list.kql from GitHub..."
            $kqlResponse = Invoke-WebRequest -Uri $kqlUrl -ErrorAction Stop -TimeoutSec 30 -UseBasicParsing
            $kqlResponse.Content | Out-File -FilePath $kqlPath -Encoding UTF8 -Force
            
            # Update timestamp
            (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") | Out-File -FilePath $lastUpdatePath -Encoding UTF8 -Force
            
            Write-Verbose "Successfully downloaded EOL data from GitHub"
            $source = "GitHub"
        }
        catch {
            Write-Warning "Failed to download EOL data from GitHub: $_"
            Write-Verbose "Attempting to use cache or fallback..."
            
            # Try to use cache if available
            if (Test-Path $serviceListPath) {
                Write-Verbose "Using cached service_list.json"
                $source = "Cache"
            }
            elseif (Test-Path $fallbackServiceListPath) {
                Write-Verbose "Using fallback service_list.json"
                $serviceListPath = $fallbackServiceListPath
                $source = "Fallback"
            }
            else {
                Write-Error "No EOL data available (GitHub download failed, no cache, no fallback)"
                return $null
            }
            
            # Try to use cached KQL or fallback
            if (Test-Path $kqlPath) {
                Write-Verbose "Using cached resource_list.kql"
            }
            elseif (Test-Path $fallbackKqlPath) {
                Write-Verbose "Using fallback resource_list.kql"
                $kqlPath = $fallbackKqlPath
            }
            else {
                Write-Error "No KQL query available (GitHub download failed, no cache, no fallback)"
                return $null
            }
        }
    }
    
    # Load service list
    try {
        $serviceListContent = Get-Content -Path $serviceListPath -Raw -ErrorAction Stop
        $serviceList = $serviceListContent | ConvertFrom-Json
    }
    catch {
        Write-Error "Failed to load service_list.json: $_"
        return $null
    }
    
    # Load KQL query
    try {
        $kqlQuery = Get-Content -Path $kqlPath -Raw -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to load resource_list.kql: $_"
        return $null
    }
    
    return [PSCustomObject]@{
        ServiceList = $serviceList
        ResourceListKQL = $kqlQuery
        Source = $source
    }
}





