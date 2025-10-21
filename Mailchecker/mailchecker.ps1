<# 
.SYNOPSIS
  Quick external mail hygiene checker: MX, DKIM, MTA-STS, DMARC, TLS-RPT, SPF.

.PARAMETER Domain
  Domain to check (e.g. example.com). If omitted, you'll be prompted.

.PARAMETER Selectors
  Comma-separated DKIM selectors to test. 
  Defaults include common ones (default,s1,s2,selector1,selector2,google,mail,k1).

.PARAMETER DnsServer
  DNS server(s) to query first (IP or name). Falls back to 8.8.8.8 and 1.1.1.1 automatically.

.EXAMPLE
  .\mailcheck.ps1 -Domain contoso.com -Selectors "mx,default,s1,google" -DnsServer 8.8.8.8
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$false)]
  [string]$Domain,

  [Parameter(Mandatory=$false)]
  [string]$BulkFile,

  [Parameter(Mandatory=$false)]
  [string]$Selectors = "default,s1,s2,selector1,selector2,google,mail,k1",

  [Parameter(Mandatory=$false)]
  [string[]]$DnsServer,
  
  [Parameter(Mandatory=$false)]
  [switch]$Html,
  
  [Parameter(Mandatory=$false)]
  [string]$OutputPath,
  
  [Parameter(Mandatory=$false)]
  [switch]$FullHtmlExport,
  
  [Parameter(Mandatory=$false)]
  [switch]$OpenReport,
  
  [Parameter(Mandatory=$false)]
  [switch]$Json,
  
  [Parameter(Mandatory=$false)]
  [switch]$UploadToAzure,
  
  [Parameter(Mandatory=$false)]
  [string]$AzureRunId,
  
  [Parameter(Mandatory=$false)]
  [string]$EnvFile = ".env",
  
  [Parameter(Mandatory=$false)]
  [switch]$ChatGPT,
  
  [Parameter(Mandatory=$false)]
  [switch]$Help,
  
  [Parameter(Mandatory=$false)]
  [switch]$ChatGPTHello,

  [Parameter(Mandatory=$false)]
  [switch]$ActivityPlan
)

# Ensure modern TLS and avoid 100-Continue delays for outbound HTTPS calls
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
try { [System.Net.ServicePointManager]::Expect100Continue = $false } catch {}

# Show help if requested
if ($Help) {
    $helpText = @"
MAILCHECKER - Email Security Configuration Checker
===================================================

SYNOPSIS
    .\mailchecker.ps1 -Domain <domain> [-Selectors <list>] [-Html | -FullHtmlExport] [-ChatGPT] [-OpenReport]
    .\mailchecker.ps1 -BulkFile <file> [-FullHtmlExport] [-Json] [-ChatGPT] [-OpenReport]

DESCRIPTION
    Checks email security: MX, SPF, DKIM, MTA-STS, DMARC, TLS-RPT
    See README.md for detailed documentation and security standards.

KEY PARAMETERS
    -Domain <domain>         Single domain to check
    -BulkFile <file>         File with domains (one per line)
    -Selectors <list>        DKIM selectors (default: default,s1,s2,selector1,selector2,google,mail,k1)
    -DnsServer <servers>     DNS servers to use (default: 8.8.8.8, 1.1.1.1)
    
OUTPUT OPTIONS
    -Html                    Generate simple HTML report (single file, embedded assets, single domain only)
    -FullHtmlExport         [RECOMMENDED] Complete export with assets directory (single domain or bulk)
    -Json                    Add JSON export (bulk mode only, with -FullHtmlExport)
    -OutputPath <path>       Output directory (default: output/)
    -OpenReport              Auto-open report in browser (requires -FullHtmlExport)
    -ChatGPT                 Generate AI analysis with remediation plan (requires -FullHtmlExport and OPENAI_API_KEY in .env)
    
AZURE CLOUD UPLOAD
    -UploadToAzure          Upload report to Azure Blob Storage (requires -FullHtmlExport, works for single domain or bulk)
    -AzureRunId <id>        Custom Run ID for upload (auto-generated if not specified)
    -EnvFile <path>         Path to .env file (default: .env)

QUICK EXAMPLES

  Single Domain:
    .\mailchecker.ps1 -Domain example.com
    .\mailchecker.ps1 -Domain example.com -Html

  Bulk Checking:
    .\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport
    .\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -OpenReport
    .\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -Json
  
  With AI Analysis:
    .\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -ChatGPT
    .\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -ChatGPT -OpenReport
  
  Azure Upload:
    .\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -UploadToAzure
    .\mailchecker.ps1 -BulkFile domains.txt -FullHtmlExport -UploadToAzure -AzureRunId "2025-audit"

DEFAULT OUTPUT STRUCTURE (output/domains-20251008-142315/)
    index.html              Main summary with links
    bulk-results-*.csv      CSV export
    results.json            JSON export (if -Json)
    analysis/
      index.html            AI-generated analysis (if -ChatGPT)
    assets/
      style.css             Modern responsive styles
      app.js                Interactive features
      analysis.css          AI analysis styles
      analysis.js           AI analysis scripts
    domains/
      example.com.html      Individual reports
      ...

INPUT FILE FORMAT (domains.txt)
    example.com
    test.org
    # Comments start with #
    another-domain.com

SEVERITY LEVELS
    [PASS] - Meets strict security standards
    [WARN] - Needs improvement (not fully enforced)
    [FAIL] - Critical issue or missing
    [N/A]  - Not applicable

COMMON ISSUES
    - DKIM no valid selectors -> Check email headers for s= parameter
    - SPF >10 lookups -> Simplify or use redirect
    - MTA-STS testing mode -> Change to mode: enforce
    - DMARC p=none -> Upgrade to p=reject

AI ANALYSIS (OPTIONAL)
    Add OPENAI_API_KEY to .env to enable AI-powered analysis:
    - Strategic remediation plan with priorities
    - Per-domain recommendations
    - Cost estimation and timeline
    - Actionable next steps

MORE INFORMATION
    See README.md for:
    - Detailed security check descriptions
    - Complete parameter reference
    - Troubleshooting guide
    - RFC references and best practices

Version: mailchecker.ps1 v2.0
"@
    Write-Host $helpText
    exit 0
}

# ============================================================================
# Azure Upload Helper Functions
# ============================================================================

function Import-EnvFile {
    param([string]$EnvFilePath)
    
    if (-not (Test-Path $EnvFilePath)) {
        throw "Environment file not found: $EnvFilePath`nCreate a .env file with AZURE_STORAGE_ACCOUNT and AZURE_STORAGE_KEY"
    }
    
    Write-Host "Loading environment from: $EnvFilePath" -ForegroundColor Cyan
    
    Get-Content $EnvFilePath | ForEach-Object {
        $line = $_.Trim()
        
        # Skip empty lines and comments
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            return
        }
        
        # Parse KEY=VALUE
        if ($line -match '^([^=]+)=(.*)$') {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            
            # Remove quotes if present (double or single)
            $value = $value -replace '^"', '' -replace "^'", '' -replace '"$', '' -replace "'$", ''
            
            # Set environment variable
            Set-Item -Path "env:$key" -Value $value
            Write-Verbose "Set env:$key"
        }
    }
    
    # Validate required variables
    if ([string]::IsNullOrWhiteSpace($env:AZURE_STORAGE_ACCOUNT)) {
        throw "AZURE_STORAGE_ACCOUNT not found in $EnvFilePath"
    }
    
    Write-Host "  [OK] AZURE_STORAGE_ACCOUNT: $env:AZURE_STORAGE_ACCOUNT" -ForegroundColor Green
    
    # Optional auth inputs:
    # - AZURE_STORAGE_SAS: preferred for non-interactive uploads
    # - AZURE_STORAGE_KEY: supported via env auth
    # - Otherwise, user will authenticate with 'azcopy login' (Microsoft Entra ID)
    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_STORAGE_SAS)) {
        $sasTail = if ($env:AZURE_STORAGE_SAS.Length -gt 6) { $env:AZURE_STORAGE_SAS.Substring($env:AZURE_STORAGE_SAS.Length - 6) } else { $env:AZURE_STORAGE_SAS }
        Write-Host "  [OK] AZURE_STORAGE_SAS: ****$sasTail" -ForegroundColor Green
    } elseif (-not [string]::IsNullOrWhiteSpace($env:AZURE_STORAGE_KEY)) {
    $keyLen = $env:AZURE_STORAGE_KEY.Length
    $lastFour = if ($keyLen -gt 4) { $env:AZURE_STORAGE_KEY.Substring($keyLen - 4) } else { $env:AZURE_STORAGE_KEY }
    Write-Host "  [OK] AZURE_STORAGE_KEY: ****$lastFour" -ForegroundColor Green
    } else {
        Write-Host "  [INFO] No SAS or key found. Will use 'azcopy login' (Microsoft Entra ID)." -ForegroundColor Yellow
    }
}

function Import-OpenAIEnv {
    param([string]$EnvFilePath)
    if (-not (Test-Path $EnvFilePath)) { return }
    Get-Content $EnvFilePath | ForEach-Object {
        $line = $_.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { return }
        if ($line -match '^([^=]+)=(.*)$') {
            $key = $Matches[1].Trim()
            if ($key -notlike 'OPENAI_*') { return }
            $value = $Matches[2].Trim()
            $value = $value -replace '^"', '' -replace "^'", '' -replace '"$', '' -replace "'$", ''
            Set-Item -Path "env:$key" -Value $value
        }
    }
}

function Test-AzCopyAvailable {
    # Check if azcopy is available
    $azcopy = Get-Command azcopy -ErrorAction SilentlyContinue
    if ($azcopy) {
        Write-Host "  [OK] AzCopy found: $($azcopy.Source)" -ForegroundColor Green
        return $true
    }
    Write-Host "AzCopy not found." -ForegroundColor Yellow
    return $false
}

function New-AzureRunId {
    param([string]$CustomRunId)
    
    if (-not [string]::IsNullOrWhiteSpace($CustomRunId)) {
        Write-Host "Using custom Run ID: $CustomRunId" -ForegroundColor Cyan
        return $CustomRunId
    }
    
    # Generate timestamp
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    
    # Generate random token (6 chars, alphanumeric)
    $buffer = New-Object byte[] 6
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
    $token = [Convert]::ToBase64String($buffer) -replace '[^a-zA-Z0-9]', ''
    $token = $token.Substring(0, [Math]::Min(6, $token.Length))
    
    # Combine and lowercase
    $runId = ("{0}-{1}" -f $timestamp, $token).ToLower()
    
    Write-Host "Generated Run ID: $runId" -ForegroundColor Cyan
    return $runId
}

function Invoke-AzureUpload {
    param(
        [string]$SourcePath,
        [string]$RunId
    )
    
    # Validate source
    $indexPath = Join-Path $SourcePath "index.html"
    if (-not (Test-Path $indexPath)) {
        throw "index.html not found in $SourcePath - cannot upload incomplete report"
    }
    
    Write-Host "`nPreparing Azure upload..." -ForegroundColor Yellow
    Write-Host "  Source: $SourcePath" -ForegroundColor Gray
    Write-Host "  Run ID: $RunId" -ForegroundColor Gray
    
    # Build source path with wildcard for recursive copy
    $src = Join-Path $SourcePath "*"
    
    # If a SAS is present in environment, validate it; if invalid/expired, clear it so we can regenerate
    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_STORAGE_SAS)) {
        try {
            $sasRaw = $env:AZURE_STORAGE_SAS
            if ($sasRaw.StartsWith('?')) { $sasRaw = $sasRaw.Substring(1) }
            $pairs = $sasRaw -split '&' | Where-Object { $_ -match '=' }
            $qs = @{}
            foreach ($p in $pairs) {
                $kv = $p -split '=',2
                if ($kv.Count -eq 2) { $qs[$kv[0]] = [System.Web.HttpUtility]::UrlDecode($kv[1]) }
            }
            $nowUtc = [DateTime]::UtcNow
            $isValid = $true
            if ($qs.ContainsKey('se')) {
                $se = [DateTime]::Parse($qs['se'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
                $minutesUntilExpiry = ($se - $nowUtc).TotalMinutes
                Write-Verbose "SAS expires in $([Math]::Round($minutesUntilExpiry, 1)) minutes"
                # Invalidate if expired or expires within 5 minutes
                if ($minutesUntilExpiry -le 5) { 
                    $isValid = $false 
                    Write-Host "  [WARN] Existing SAS expires in $([Math]::Round($minutesUntilExpiry, 1)) minutes" -ForegroundColor Yellow
                }
            }
            if ($qs.ContainsKey('st') -and $isValid) {
                $st = [DateTime]::Parse($qs['st'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
                # Allow small clock skew tolerance
                if ($st -gt $nowUtc.AddMinutes(5)) { $isValid = $false }
            }
            if (-not $isValid) {
                Write-Host "  [INFO] Will generate a new SAS token" -ForegroundColor Yellow
                $env:AZURE_STORAGE_SAS = $null
            }
        } catch {
            # If parsing fails, assume invalid and clear to regenerate
            Write-Host "  [WARN] Failed to validate existing SAS token: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  [INFO] Will generate a new SAS token" -ForegroundColor Yellow
            $env:AZURE_STORAGE_SAS = $null
        }
    }

    # If no SAS is provided but an account key exists and Azure CLI is available,
    # generate a short-lived SAS for $web to avoid AAD/RBAC pitfalls
    if ([string]::IsNullOrWhiteSpace($env:AZURE_STORAGE_SAS) -and -not [string]::IsNullOrWhiteSpace($env:AZURE_STORAGE_KEY)) {
        $azCli = Get-Command az -ErrorAction SilentlyContinue
        if ($azCli) {
            try {
                Write-Host "  Generating temporary SAS for $web via Azure CLI..." -ForegroundColor Yellow
                $nowUtc = (Get-Date).ToUniversalTime()
                $startUtc = $nowUtc.AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:ssZ')
                $expiryUtc = $nowUtc.AddHours(8).ToString('yyyy-MM-ddTHH:mm:ssZ')
                $azArgs = @(
                    'storage','container','generate-sas',
                    '--account-name', $env:AZURE_STORAGE_ACCOUNT,
                    '--account-key', ($env:AZURE_STORAGE_KEY).Trim(),
                    '--name', '$web',
                    '--permissions', 'racwdl',
                    '--start', $startUtc,
                    '--expiry', $expiryUtc,
                    '--https-only',
                    '--output', 'tsv'
                )
                $generatedSas = (& az @azArgs 2>&1).ToString().Trim()
                if (-not [string]::IsNullOrWhiteSpace($generatedSas)) {
                    $env:AZURE_STORAGE_SAS = $generatedSas
                    $tail = if ($generatedSas.Length -gt 6) { $generatedSas.Substring($generatedSas.Length - 6) } else { $generatedSas }
                    Write-Host "  [OK] SAS generated (****$tail)" -ForegroundColor Green
                } else {
                    Write-Host "  [WARN] Failed to generate SAS via Azure CLI; proceeding without SAS" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "  [WARN] SAS generation failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    # Build destination URL. Prefer SAS if provided, else Entra ID login/session.
    $baseDest = 'https://{0}.blob.core.windows.net/$web/reports/{1}/' -f $env:AZURE_STORAGE_ACCOUNT, $RunId
    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_STORAGE_SAS)) {
        # Ensure leading '?' on SAS
        $sas = $env:AZURE_STORAGE_SAS
        if ($sas -and -not $sas.StartsWith('?')) { $sas = '?' + $sas }
        $dest = $baseDest + $sas
    } else {
        $dest = $baseDest
    }
    
    Write-Host "`nUploading to Azure Blob Storage..." -ForegroundColor Yellow
    
    # Auth selection:
    # 1) SAS present -> use SAS (no login)
    # 2) Account Key present -> set AZCOPY_ACCOUNT_* env (force key auth)
    # 3) Else -> Entra ID via AZCLI if available
    $prevAutoLoginType = $env:AZCOPY_AUTO_LOGIN_TYPE
    $prevAccountName = $env:AZCOPY_ACCOUNT_NAME
    $prevAccountKey  = $env:AZCOPY_ACCOUNT_KEY
    $didSetAutoLogin = $false
    $didSetAccountCreds = $false

    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_STORAGE_SAS)) {
        # SAS auth; nothing to set
    } elseif (-not [string]::IsNullOrWhiteSpace($env:AZURE_STORAGE_KEY)) {
        # Force account key auth so AzCopy doesn't try AAD
        $env:AZCOPY_ACCOUNT_NAME = $env:AZURE_STORAGE_ACCOUNT
        $env:AZCOPY_ACCOUNT_KEY  = ($env:AZURE_STORAGE_KEY).Trim()
        # Disable auto-login by unsetting the variable if present
        if ($env:AZCOPY_AUTO_LOGIN_TYPE) { Remove-Item Env:AZCOPY_AUTO_LOGIN_TYPE -ErrorAction SilentlyContinue }
        $didSetAccountCreds = $true
        $didSetAutoLogin = $true
    } else {
        # Try Entra ID via Azure CLI tokens
        if (-not [string]::IsNullOrWhiteSpace((Get-Command az -ErrorAction SilentlyContinue))) {
            $env:AZCOPY_AUTO_LOGIN_TYPE = 'AZCLI'
            $didSetAutoLogin = $true
        }
    }

    try {
        # Run AzCopy (recursive upload, overwrite true)
        $azcopyArgs = @(
            'copy',
            $src,
            $dest,
            '--recursive',
            '--overwrite=true'
        )
        
        # Execute AzCopy (capture output for error handling)
        $output = & azcopy @azcopyArgs 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            # Filter out the key from error messages
            $safeOutput = $output
            if (-not [string]::IsNullOrWhiteSpace($env:AZURE_STORAGE_KEY)) {
                $safeOutput = $safeOutput -replace [regex]::Escape($env:AZURE_STORAGE_KEY), '****'
            }
            throw "AzCopy failed with exit code $LASTEXITCODE`n$safeOutput"
        }
        
        Write-Host "  [OK] Upload completed successfully" -ForegroundColor Green
        
        # Determine web zone
        $zone = $env:AZURE_WEB_ZONE
        if ([string]::IsNullOrWhiteSpace($zone)) {
            $zone = 'z1'  # Default to z1, but may differ per region
            Write-Host "  Note: Using zone 'z1' (default). Set AZURE_WEB_ZONE in .env if different." -ForegroundColor Gray
        }
        
        # Build public URLs
        $publicFolder = "https://{0}.{1}.web.core.windows.net/reports/{2}/" -f $env:AZURE_STORAGE_ACCOUNT, $zone, $RunId
        $publicIndex = $publicFolder + "index.html"
        
        # Verify upload by checking if index.html is accessible
        Write-Host "`nVerifying upload..." -ForegroundColor Yellow
        try {
            $headResponse = Invoke-WebRequest -Method Head -Uri $publicIndex -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            if ($headResponse.StatusCode -eq 200) {
                Write-Host "  [OK] Upload verified (HTTP 200)" -ForegroundColor Green
            }
        } catch {
            Write-Host "  [WARN] Could not verify upload automatically (this may be expected if DNS hasn't propagated yet)" -ForegroundColor Yellow
        }
        
        # Print public URLs
        Write-Host "`n" -NoNewline
        Write-Host "===================================================================" -ForegroundColor Cyan
        Write-Host "  Report uploaded successfully!" -ForegroundColor Green
        Write-Host "===================================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Public URL (index):  " -NoNewline -ForegroundColor White
        Write-Host $publicIndex -ForegroundColor Cyan
        Write-Host ""
        Write-Host "===================================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Tip: Share the index URL to provide direct access to the report" -ForegroundColor Gray
        Write-Host ""
        
    } catch {
        Write-Host ""
        Write-Host "[ERROR] Upload failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Suggestion: Authenticate with 'azcopy login' or use a SAS token in .env as AZURE_STORAGE_SAS." -ForegroundColor Yellow
        throw
    } finally {
        # Restore AZCOPY envs if changed
        if ($didSetAutoLogin) {
            if ($null -ne $prevAutoLoginType) { $env:AZCOPY_AUTO_LOGIN_TYPE = $prevAutoLoginType } else { Remove-Item Env:AZCOPY_AUTO_LOGIN_TYPE -ErrorAction SilentlyContinue }
        }
        if ($didSetAccountCreds) {
            if ($null -ne $prevAccountName) { $env:AZCOPY_ACCOUNT_NAME = $prevAccountName } else { Remove-Item Env:AZCOPY_ACCOUNT_NAME -ErrorAction SilentlyContinue }
            if ($null -ne $prevAccountKey)  { $env:AZCOPY_ACCOUNT_KEY  = $prevAccountKey  } else { Remove-Item Env:AZCOPY_ACCOUNT_KEY  -ErrorAction SilentlyContinue }
        }
    }
}

# ============================================================================
# End Azure Upload Functions
# ============================================================================

# Validate input parameters
if ($Domain -and $BulkFile) {
    throw "Cannot specify both -Domain and -BulkFile"
}
if (-not $Domain -and -not $BulkFile) {
    $Domain = Read-Host "Enter domain (e.g. example.com)"
}

# Validate Azure upload requirements
if ($UploadToAzure) {
    if (-not $FullHtmlExport) {
        throw "-UploadToAzure requires -FullHtmlExport to generate the report structure"
    }
    # Early AzCopy availability check before any scanning/export work
    Write-Host "\nAzure upload requested: verifying AzCopy tool before scanning..." -ForegroundColor Yellow
    if (-not (Test-AzCopyAvailable)) {
        Write-Host "" -ForegroundColor Yellow
        Write-Host "AzCopy is required to upload to Azure. Please install and verify:" -ForegroundColor Yellow
        Write-Host "  winget install azcopy --source winget" -ForegroundColor Cyan
        Write-Host "  Close and reopen your terminal (refresh PATH), then run again." -ForegroundColor Gray
        exit 1
    }
}

function New-CheckResult {
    param(
        [string]$Section,
        [string]$Status,  # OK, FAIL, WARN, N/A
        [string[]]$Details = @(),
        [string[]]$Warnings = @(),
        [string[]]$InfoMessages = @(),
        [hashtable]$Data = @{}
    )
    
    return [pscustomobject]@{
        Section = $Section
        Status = $Status
        Details = $Details
        Warnings = $Warnings
        InfoMessages = $InfoMessages
        Data = $Data
    }
}

function New-OutputStructure {
    param(
        [string]$InputFile,
        [string]$OutputPath
    )
    
    # Determine final output path
    $resolvedPath = $null
    
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        # Auto-generate path based on input file
        if ([string]::IsNullOrWhiteSpace($InputFile)) {
            # Single domain mode - use generic name
            $baseName = "mailcheck-report"
        } else {
            # Bulk mode - use input filename without extension
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
        }
        
        $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $outputDir = Join-Path (Get-Location) "output"
        $resolvedPath = Join-Path $outputDir "$baseName-$timestamp"
    } else {
        # Use provided path
        $resolvedPath = $OutputPath
    }
    
    # Create main directory
    if (-not (Test-Path $resolvedPath)) {
        try {
            New-Item -ItemType Directory -Path $resolvedPath -Force | Out-Null
            Write-Host "Created output directory: $resolvedPath" -ForegroundColor Cyan
        } catch {
            Write-Host "Error: Could not create output directory: $resolvedPath" -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Red
            throw
        }
    }
    
    # Create subdirectories for FullHtmlExport
    $domainsPath = Join-Path $resolvedPath "domains"
    $assetsPath = Join-Path $resolvedPath "assets"
    
    if (-not (Test-Path $domainsPath)) {
        New-Item -ItemType Directory -Path $domainsPath -Force | Out-Null
    }
    
    if (-not (Test-Path $assetsPath)) {
        New-Item -ItemType Directory -Path $assetsPath -Force | Out-Null
    }
    
    return @{
        RootPath = $resolvedPath
        DomainsPath = $domainsPath
        AssetsPath = $assetsPath
    }
}

function Write-AssetsFiles {
    param([string]$AssetsPath)
    
    # Copy CSS and JS from source templates folder to flat output structure
    $sourceTemplatesPath = Join-Path $PSScriptRoot 'templates'
    
    # Copy main stylesheet
    $styleSrc = Join-Path $sourceTemplatesPath "css/style.css"
    $styleDst = Join-Path $AssetsPath "style.css"
    Copy-Item -Path $styleSrc -Destination $styleDst -Force
    
    # Copy main JS
    $jsSrc = Join-Path $sourceTemplatesPath "js/app.js"
    $jsDst = Join-Path $AssetsPath "app.js"
    Copy-Item -Path $jsSrc -Destination $jsDst -Force
    
    # Copy analysis-specific CSS and JS (used by analysis.html template)
    $analysisCssSrc = Join-Path $sourceTemplatesPath "css/analysis.css"
    $analysisCssDst = Join-Path $AssetsPath "analysis.css"
    Copy-Item -Path $analysisCssSrc -Destination $analysisCssDst -Force
    
    $analysisJsSrc = Join-Path $sourceTemplatesPath "js/analysis.js"
    $analysisJsDst = Join-Path $AssetsPath "analysis.js"
    Copy-Item -Path $analysisJsSrc -Destination $analysisJsDst -Force
}

function Test-MXRecords {
    param([string]$Domain)
    
    $mx = Resolve-MX $Domain
    $details = @()
    $infoMessages = @()
    $warnings = @()
    $status = 'FAIL'
    $reason = ""
    $domainExists = $true
    $nsRecords = @()
    
    if (@($mx).Count -gt 0) {
        $details = $mx | Sort-Object Preference,NameExchange | 
                   ForEach-Object { "$($_.Preference) $($_.NameExchange)" }
        $status = 'PASS'
        $mxList = ($mx | Sort-Object Preference,NameExchange | ForEach-Object { "$($_.Preference) $($_.NameExchange)" }) -join ', '
        $reason = "MX: $mxList"
    } else {
        # No MX records - check if domain exists by looking for NS records
        $nsResult = Resolve-NS $Domain
        $nsRecords = $nsResult.NSRecords
        $nsStatus = $nsResult.Status
        
        if ($nsStatus -eq 'NXDOMAIN') {
            # Domain does not exist (NXDOMAIN response)
            $details = @("Domain does not exist - DNS returned NXDOMAIN (Non-Existent Domain).")
            $warnings = @("Warning: Domain '$Domain' does not exist in DNS.")
            $status = 'FAIL'
            $reason = "Domain: does not exist (NXDOMAIN)"
            $domainExists = $false
        } elseif ($nsStatus -eq 'SERVFAIL') {
            # DNS server failed - domain might exist but DNS is misconfigured
            # Still run email security checks as domain may have SPF/DMARC records
            $details = @("DNS resolution failed - DNS query error (SERVFAIL/No response/Timeout).")
            $details += "This typically indicates:"
            $details += "  - Domain exists but nameservers are misconfigured"
            $details += "  - Nameservers are not responding"
            $details += "  - Network connectivity issues or timeouts"
            $details += "  - Lame delegation (nameservers don't accept queries for this domain)"
            $details += ""
            $details += "Email security checks will still be performed as records may exist."
            $warnings = @("Warning: Domain '$Domain' has DNS issues but security checks will be attempted.")
            $status = 'WARN'  # WARN instead of FAIL since we'll still check email security
            $reason = "MX: N/A (DNS misconfigured)"
            $domainExists = $true  # Treat as existing so email checks are performed
        } elseif (@($nsRecords).Count -gt 0) {
            # Domain exists but has no MX records (send-only domain)
            $details = @("No MX records found via any configured resolver.")
            $details += "NS records present: " + (($nsRecords | Select-Object -First 3) -join ', ')
            if (@($nsRecords).Count -gt 3) {
                $details += "  ... and $(@($nsRecords).Count - 3) more"
            }
            $infoMessages = @("Info: No MX records is not necessarily an error - domain may only send email (not receive).")
            $status = 'N/A'
            $reason = "MX: N/A (send-only domain)"
        } else {
            # Unknown error
            $details = @("Could not determine domain status - DNS query failed without specific error.")
            $warnings = @("Warning: Unable to verify if domain '$Domain' exists.")
            $status = 'FAIL'
            $reason = "Domain: DNS query failed"
            $domainExists = $false
        }
    }
    
    return New-CheckResult -Section 'MX Records' -Status $status -Details $details -Warnings $warnings -InfoMessages $infoMessages -Data @{ 
        MXRecords = $mx
        NSRecords = $nsRecords
        DomainExists = $domainExists
        Reason = $reason
    }
}

function Get-SpfLookups($spf, $checked) {
  if ($checked -contains $spf) { return 0 }
  $checked += $spf
  $count = 0
  $count += ([regex]::Matches($spf, '(?i)include:')).Count
  $count += ([regex]::Matches($spf, '(?i)a(?=\s|:|$)')).Count
  $count += ([regex]::Matches($spf, '(?i)mx(?=\s|:|$)')).Count
  $count += ([regex]::Matches($spf, '(?i)ptr(?=\s|:|$)')).Count
  $count += ([regex]::Matches($spf, '(?i)exists:')).Count
  $count += ([regex]::Matches($spf, '(?i)redirect=')).Count
  # Recursive check for include and redirect
  foreach ($inc in ([regex]::Matches($spf, '(?i)include:([^\s]+)'))) {
    $incDom = $inc.Groups[1].Value
    $incSpf = Resolve-SPF $incDom
    if ($incSpf) { $count += Get-SpfLookups $incSpf $checked }
  }
  foreach ($red in ([regex]::Matches($spf, '(?i)redirect=([^\s]+)'))) {
    $redDom = $red.Groups[1].Value
    $redSpf = Resolve-SPF $redDom
    if ($redSpf) { $count += Get-SpfLookups $redSpf $checked }
  }
  return $count
}

# Enhanced version that returns detailed lookup breakdown per include
function Get-SpfLookupsDetailed($spf, $checked, $depth = 0) {
  if ($checked -contains $spf) { 
    return @{ Total = 0; Details = @() }
  }
  $checked += $spf
  
  # Count direct lookups (mechanisms that trigger DNS lookups)
  $directCount = 0
  $includeCount = ([regex]::Matches($spf, '(?i)\binclude:')).Count
  $aCount = ([regex]::Matches($spf, '(?i)(?<=\s)a(?=\s|:|$)')).Count     # Require whitespace before 'a' to avoid matching IPv6
  $mxCountLocal = ([regex]::Matches($spf, '(?i)(?<=\s)mx(?=\s|:|$)')).Count
  $ptrCount = ([regex]::Matches($spf, '(?i)(?<=\s)ptr(?=\s|:|$)')).Count
  $existsCount = ([regex]::Matches($spf, '(?i)\bexists:')).Count
  $redirectCount = ([regex]::Matches($spf, '(?i)\bredirect=')).Count
  
  $directCount = $includeCount + $aCount + $mxCountLocal + $ptrCount + $existsCount + $redirectCount
  
  # Debug logging for IP-only SPF records that shouldn't have lookups
  if ($directCount -gt 0 -and $spf -match 'improve\.nordlo|zetup\.se') {
    Write-Verbose "DEBUG: SPF record analysis for nested include:"
    Write-Verbose "  Record: $($spf.Substring(0, [Math]::Min(150, $spf.Length)))..."
    Write-Verbose "  Counts: include=$includeCount, a=$aCount, mx=$mxCountLocal, ptr=$ptrCount, exists=$existsCount, redirect=$redirectCount"
    Write-Verbose "  Direct total: $directCount"
  }
  
  $totalCount = $directCount
  $details = @()
  
  # Recursive check for includes
  foreach ($inc in ([regex]::Matches($spf, '(?i)include:([^\s]+)'))) {
    $incDom = $inc.Groups[1].Value
    $incSpf = Resolve-SPF $incDom
    if ($incSpf) {
      $incResult = Get-SpfLookupsDetailed $incSpf $checked ($depth + 1)
      $incTotal = 1 + $incResult.Total  # 1 for the include itself + recursive lookups
      $totalCount += $incResult.Total
      
      # Debug logging for specific domains
      if ($incDom -match 'improve\.nordlo|zetup\.se') {
        Write-Verbose "DEBUG Include: $incDom"
        Write-Verbose "  Retrieved SPF (full): $incSpf"
        Write-Verbose "  Counts in this record: include=$($incResult.Details.Count), direct_lookups=$directCount"
        Write-Verbose "  Recursive Total: $($incResult.Total)"
        Write-Verbose "  Display Total (1+recursive): $incTotal"
      }
      
      $details += [PSCustomObject]@{
        Include = $incDom
        Lookups = $incTotal
        Depth = $depth
      }
      
      # Add nested details
      $details += $incResult.Details
    }
  }
  
  # Recursive check for redirects
  foreach ($red in ([regex]::Matches($spf, '(?i)redirect=([^\s]+)'))) {
    $redDom = $red.Groups[1].Value
    $redSpf = Resolve-SPF $redDom
    if ($redSpf) {
      $redResult = Get-SpfLookupsDetailed $redSpf $checked ($depth + 1)
      $redTotal = 1 + $redResult.Total
      $totalCount += $redResult.Total
      
      $details += [PSCustomObject]@{
        Include = "redirect=$redDom"
        Lookups = $redTotal
        Depth = $depth
      }
      
      $details += $redResult.Details
    }
  }
  
  return @{
    Total = $totalCount
    Details = $details
  }
}

function Test-SPFRecords {
    param(
        [string]$Domain,
        [bool]$DomainExists = $true
    )
    
    # If domain doesn't exist, mark as N/A
    if (-not $DomainExists) {
        return New-CheckResult -Section 'SPF' -Status 'N/A' -Details @("Domain does not exist - no NS records found.") -InfoMessages @("Not applicable - domain does not exist") -Data @{
            SPFRecords = @()
            Healthy = $false
            Reason = "SPF: N/A (domain does not exist)"
        }
    }
    
    $spfRecs = Resolve-SPF $Domain
    $details = @()
    $warnings = @()
    $infoMessages = @()
    $status = 'FAIL'
    $spfHealthy = $true
    $reason = ""
    
    if (@($spfRecs).Count -gt 0) {
        # Check for multi-SPF (strict profile: FAIL)
        if (@($spfRecs).Count -gt 1) {
            $warnings += "Warning: Multiple SPF records found - this violates RFC and causes unpredictable behavior."
            $spfHealthy = $false
            $status = 'FAIL'
            $reason = "SPF: multiple records (RFC violation)"
        }
        
        $i = 1
        $hasPtr = $false
        $hasSoftFail = $false
        $maxLookups = 0
        
        foreach ($rec in $spfRecs) {
            $details += "SPF #$i`: $rec"
            
            # Check for ptr (strict profile: WARN)
            if ($rec -match '(?i)\bptr\b') {
                $hasPtr = $true
            }
            
            # Check for soft fail (strict profile: WARN)
            if ($rec -match '(?i)~all\b') {
                $hasSoftFail = $true
            }
            
            # Count DNS lookups with detailed breakdown
            $lookupResult = Get-SpfLookupsDetailed $rec @()
            $lookupCount = $lookupResult.Total
            
            # Determine status based on lookup count (strict RFC 7208 interpretation)
            if ($lookupCount -gt 10) {
                $warnings += "Warning: DNS lookups (SPF): $lookupCount (exceeds RFC limit of 10)"
                $spfHealthy = $false
                $status = 'FAIL'
            } elseif ($lookupCount -eq 10) {
                $warnings += "Warning: DNS lookups (SPF): $lookupCount (at RFC limit - any change will break SPF)"
                if ($status -ne 'FAIL') { $status = 'WARN' }
            } elseif ($lookupCount -eq 9) {
                $warnings += "Warning: DNS lookups (SPF): $lookupCount (near RFC limit - only 1 lookup remaining)"
                if ($status -ne 'FAIL') { $status = 'WARN' }
            } else {
                $infoMessages += "Info: DNS lookups (SPF): $lookupCount (RFC limit: 10, remaining: $(10 - $lookupCount))"
            }
            
            # Show breakdown including direct lookups and includes
            $details += ""
            $details += "SPF Lookup Breakdown (RFC 7208):"
            $details += "  Note: RFC counts include, a, mx, ptr, exists, redirect as lookups"
            
            # Count direct lookups (mechanisms in the main SPF record) - use same regex as detailed function
            $directLookups = 0
            $aCount = ([regex]::Matches($rec, '(?i)(?<=\s)a(?=\s|:|$)')).Count
            $mxCount = ([regex]::Matches($rec, '(?i)(?<=\s)mx(?=\s|:|$)')).Count
            $ptrCount = ([regex]::Matches($rec, '(?i)(?<=\s)ptr(?=\s|:|$)')).Count
            $existsCount = ([regex]::Matches($rec, '(?i)\bexists:')).Count
            $directLookups = $aCount + $mxCount + $ptrCount + $existsCount
            
            if ($directLookups -gt 0) {
                $details += "  - Direct mechanisms: $directLookups lookup(s)"
                if ($aCount -gt 0) { $details += "    * a: $aCount" }
                if ($mxCount -gt 0) { $details += "    * mx: $mxCount" }
                if ($ptrCount -gt 0) { $details += "    * ptr: $ptrCount" }
                if ($existsCount -gt 0) { $details += "    * exists: $existsCount" }
            }
            
            # Show include/redirect breakdown
            $topLevelIncludes = @($lookupResult.Details | Where-Object { $_.Depth -eq 0 })
            foreach ($inc in $topLevelIncludes) {
                $details += "  - $($inc.Include): $($inc.Lookups) lookup(s)"
                if ($inc.Lookups -gt 5) {
                    $infoMessages += "Info: SPF include '$($inc.Include)' uses $($inc.Lookups) DNS lookups (consider optimizing)"
                }
            }
            
            if ($directLookups + $topLevelIncludes.Count -gt 0) {
                $details += "  TOTAL: $lookupCount lookup(s)"
            }
            
            if ($lookupCount -gt $maxLookups) { $maxLookups = $lookupCount }
            
            $i++
        }
        
        # Add warnings for ptr and soft fail (always show these if present)
        if ($hasPtr) {
            $warnings += "Warning: SPF uses ptr mechanism, which is deprecated and inefficient."
        }
        if ($hasSoftFail) {
            $warnings += "Warning: SPF uses soft fail (~all). Consider using -all (hard fail) for production."
        }
        
        # Determine status and reason based on findings (only if not already set to FAIL from multi-SPF)
        if (-not $reason) {
            if ($maxLookups -gt 10) {
                $status = 'FAIL'
                $spfHealthy = $false
                # Build reason with additional issues
                $reasonParts = @(">10 lookups ($maxLookups)")
                if ($hasSoftFail) { $reasonParts += "~all" }
                if ($hasPtr) { $reasonParts += "ptr" }
                $reason = "SPF: " + ($reasonParts -join ", ")
            } elseif ($maxLookups -ge 9 -or $hasPtr -or $hasSoftFail) {
                # 9-10 lookups OR ptr OR ~all → WARN
                $status = 'WARN'
                $spfHealthy = $false
                $reasonParts = @()
                if ($maxLookups -eq 10) {
                    $reasonParts += "at limit (10 lookups)"
                } elseif ($maxLookups -eq 9) {
                    $reasonParts += "near limit (9 lookups)"
                }
                if ($hasSoftFail) { $reasonParts += "~all (soft fail)" }
                if ($hasPtr) { $reasonParts += "ptr (deprecated)" }
                
                if ($reasonParts.Count -gt 0) {
                    $reason = "SPF: " + ($reasonParts -join ", ")
                } else {
                    $reason = "SPF: valid ($maxLookups lookups)"
                }
            } else {
                $status = 'PASS'
                $reason = "SPF: valid ($maxLookups lookups)"
                $spfHealthy = $true
            }
        }
    } else {
        $details = @("No SPF (v=spf1) record found at $Domain")
        $spfHealthy = $false
        $status = 'FAIL'
        $reason = "SPF: missing"
    }
    
    return New-CheckResult -Section 'SPF' -Status $status -Details $details -Warnings $warnings -InfoMessages $infoMessages -Data @{ 
        SPFRecords = $spfRecs
        Healthy = $spfHealthy
        Reason = $reason
    }
}

function Test-DKIMRecords {
    param(
        [string]$Domain,
        [string[]]$Selectors,
        [bool]$HasMX,
        [bool]$HasSpfWithMechanisms,
        [bool]$DomainExists = $true
    )
    
    $details = @()
    $warnings = @()
    $infoMessages = @()
    $status = 'FAIL'
    $dkimResults = @()
    
    # If domain doesn't exist, mark as N/A
    if (-not $DomainExists) {
        return New-CheckResult -Section 'DKIM' -Status 'N/A' -Details @("Domain does not exist - no NS records found.") -InfoMessages @("Not applicable - domain does not exist") -Data @{
            DKIMResults = @()
            AnyValid = $false
            Reason = "DKIM: N/A (domain does not exist)"
        }
    }
    
    # Skip DKIM test only if domain has no MX AND (no SPF record OR SPF only has -all)
    if (-not $HasMX -and -not $HasSpfWithMechanisms) {
        $infoMessages += "Not applicable - domain has no mail flow (no MX and no SPF mechanisms)"
        return New-CheckResult -Section 'DKIM' -Status 'N/A' -InfoMessages $infoMessages -Data @{ Reason = "DKIM: N/A (no mail flow)" }
    }
    
    # Check DKIM selectors
    foreach($sel in $Selectors){
        $dkimHost = "$sel._domainkey.$Domain"
        $txt = Resolve-Txt $dkimHost
        if ($txt -is [System.Collections.IEnumerable]) { $txt = ($txt -join "") }

        $hasV = $false; $hasP = $false
        if ($txt) {
            $hasV = [bool]($txt -match "(?i)\bv\s*=\s*DKIM1\b")
            $hasP = [bool](($txt -match "(?i)\bp\s*=\s*[^;]+") -or ($txt -match "(?i)\bp\s*=\s*\S+$"))
        }

        $raw = $null
        if ($txt) {
            if ($txt.Length -gt 120) {
                $raw = $txt.Substring(0,120) + "..."
            } else {
                $raw = $txt
            }
        }

        $dkimResults += [pscustomobject]@{
            Selector        = $sel
            Hostname        = $dkimHost
            Found           = ([string]::IsNullOrWhiteSpace($txt) -eq $false)
            Has_V_DKIM1     = $hasV
            Has_PublicKey_p = $hasP
            RawTXT          = $raw
            FullTXT         = $txt
        }
    }

    # Add table to details
    if ($dkimResults.Count -gt 0) {
        $tableLines = $dkimResults | Format-Table -AutoSize | Out-String -Stream
        $details += $tableLines
    }

    # Valid if TXT exists, p= exists, and if v= exists it must be DKIM1
    $validSelectors = $dkimResults | Where-Object {
        $_.Found -and $_.Has_PublicKey_p -and (
            -not $_.Has_V_DKIM1 -or $_.Has_V_DKIM1
        )
    }

    $anyValid = @($validSelectors).Count -gt 0

    # Check for warnings and info messages
    foreach ($dkim in @($validSelectors)) {
        if ($dkim.FullTXT -match '(?i)\bt=y\b') {
            $warnings += "Warning: DKIM selector '$($dkim.Selector)' is in test mode (t=y)."
        }
        if ($dkim.FullTXT -match '(?i)\bt=s\b') {
            $infoMessages += "Info: DKIM selector '$($dkim.Selector)' uses strict mode (t=s) - good security practice that prevents email spoofing from other domains."
        }
        if ($dkim.FullTXT -match '(?i)\bp=\s*;') {
            $warnings += "Warning: DKIM selector '$($dkim.Selector)' has empty key (p=), which means revocation."
        }
    }

    $reason = ""
    if ($anyValid) {
        $infoMessages += "DKIM validation successful - at least one valid selector found with proper public key."
        $status = 'PASS'
        $validSelectorNames = ($validSelectors | ForEach-Object { $_.Selector }) -join ', '
        $reason = "DKIM: valid selectors ($validSelectorNames)"
    } else {
        $warnings += "DKIM validation failed - no valid selectors found with proper public keys."
        $status = 'FAIL'
        $reason = "DKIM: no valid selectors"
    }
    
    return New-CheckResult -Section 'DKIM' -Status $status -Details $details -Warnings $warnings -InfoMessages $infoMessages -Data @{ 
        DKIMResults = $dkimResults
        AnyValid = $anyValid
        Reason = $reason
    }
}

function Test-MTASts {
    param(
        [string]$Domain,
        [bool]$HasMX,
        [bool]$DomainExists = $true
    )
    
    $details = @()
    $warnings = @()
    $infoMessages = @()
    $status = 'FAIL'
    $reason = ""
    
    # If domain doesn't exist, mark as N/A
    if (-not $DomainExists) {
        return New-CheckResult -Section 'MTA-STS' -Status 'N/A' -Details @("Domain does not exist - no NS records found.") -InfoMessages @("Not applicable - domain does not exist") -Data @{
            MtaStsTxt = $null
            MtaStsBody = $null
            MtaStsUrl = $null
            MtaStsModeTesting = $false
            MtaStsEnforced = $false
            Reason = "MTA-STS: N/A (domain does not exist)"
        }
    }
    
    if (-not $HasMX) {
        $infoMessages += "Not applicable - domain cannot receive email"
        return New-CheckResult -Section 'MTA-STS' -Status 'N/A' -InfoMessages $infoMessages -Data @{ Reason = "N/A: no MX records" }
    }
    
    # MTA-STS logic
    $MtaStsModeTesting = $false
    $MtaStsEnforced = $false
    [string]$mtaStsUrlVal = $null
    [string]$mtaStsBody = $null
    
    $mtaStsTxt = Resolve-Txt "_mta-sts.$Domain"
    if ($mtaStsTxt) {
        $details += "TXT at _mta-sts.$Domain`:"
        $details += $mtaStsTxt
        
        # Parse MTA-STS TXT record - check for v=STSv1 to distinguish from wildcard TXT records
        if ($mtaStsTxt -match '(?i)\bv=STSv1\b') {
            $details += "- v=STSv1 present: True"
            if ($mtaStsTxt -match '(?i)\bid=([^;]+)') {
                $details += "- id: $($Matches[1])"
            }
        } else {
            # TXT record exists but doesn't contain v=STSv1 - likely a wildcard DNS record (e.g., *.domain.com)
            # Treat as missing rather than broken
            $details += "- v=STSv1 present: False (likely wildcard TXT record, not actual MTA-STS)"
            $details += "No valid MTA-STS record found (TXT exists but missing v=STSv1)."
            $status = 'FAIL'
            $reason = "MTA-STS: missing (required for domains with MX)"
            $warnings += "Warning: Wildcard TXT record detected - not a valid MTA-STS configuration."
            return New-CheckResult -Section 'MTA-STS' -Status $status -Details $details -Warnings $warnings -InfoMessages $infoMessages -Data @{ 
                MtaStsTxt = $mtaStsTxt  # Keep the wildcard record for detection in HTML rendering
                MtaStsBody = $null
                MtaStsUrl = $null
                MtaStsModeTesting = $false
                MtaStsEnforced = $false
                Reason = $reason
            }
        }
        
        # Fetch HTTPS policy
        $mtaStsUrl = "https://mta-sts.$Domain/.well-known/mta-sts.txt"
        $mtaStsUrlVal = $mtaStsUrl
        $mtaStsBody = Get-HttpText $mtaStsUrl
        
        if ($mtaStsBody) {
            $details += "Fetched policy from $mtaStsUrl"
            $details += $mtaStsBody
            
            # Parse mode from HTTPS policy
            $mode = $null
            foreach ($line in ($mtaStsBody -split "`n")) {
                $trim = $line.Trim()
                if ($trim -match '^(?i)mode\s*:\s*(.+)$') {
                    $mode = $Matches[1].Trim()
                    break
                }
            }
            
            # Set booleans based on mode
            switch -Regex ($mode) {
                '^(?i)enforce$' { 
                    $MtaStsEnforced = $true
                    $MtaStsModeTesting = $false
                    $status = 'PASS'
                    $reason = "MTA-STS: mode=enforce"
                    $infoMessages += "MTA-STS is properly enforced (mode=enforce)."
                    break 
                }
                '^(?i)testing$' { 
                    $MtaStsEnforced = $false
                    $MtaStsModeTesting = $true
                    $status = 'WARN'
                    $reason = "MTA-STS: mode=testing"
                    $warnings += "Warning: MTA-STS is in testing mode (mode=testing). Switch to mode=enforce for full protection."
                    break 
                }
                default { 
                    $MtaStsEnforced = $false
                    $MtaStsModeTesting = $false
                    $status = 'FAIL'
                    $reason = "MTA-STS: invalid or missing mode"
                    break 
                }
            }
        } else {
            $details += "Could not fetch HTTPS policy at $mtaStsUrl"
            $status = 'FAIL'
            $reason = "MTA-STS: DNS record exists but policy unreachable"
        }
    } else {
        $details += "No _mta-sts TXT record found."
        $status = 'FAIL'
        $reason = "MTA-STS: missing (required for domains with MX)"
    }
    
    return New-CheckResult -Section 'MTA-STS' -Status $status -Details $details -Warnings $warnings -InfoMessages $infoMessages -Data @{ 
        MtaStsTxt = $mtaStsTxt
        MtaStsBody = $mtaStsBody
        MtaStsUrl = $mtaStsUrlVal
        MtaStsModeTesting = $MtaStsModeTesting
        MtaStsEnforced = $MtaStsEnforced
        Reason = $reason
    }
}

function Test-DMARC {
    param(
        [string]$Domain,
        [bool]$DomainExists = $true
    )

    $details = @()
    $warnings = @()
    $infoMessages = @()
    $status = 'FAIL'
    $reason = ""
    
    # If domain doesn't exist, mark as N/A
    if (-not $DomainExists) {
        return New-CheckResult -Section 'DMARC' -Status 'N/A' -Details @("Domain does not exist - no NS records found.") -InfoMessages @("Not applicable - domain does not exist") -Data @{
            DmarcMap = @{}
            DmarcTxt = $null
            Enforced = $false
            Reason = "DMARC: N/A (domain does not exist)"
        }
    }

    $dmarcHost = "_dmarc.$Domain"
    
    # Check if _dmarc uses CNAME (not best practice)
    $hasCname = $false
    $cnameTarget = $null
    try {
        if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
            $dnsCheck = Resolve-DnsName -Name $dmarcHost -ErrorAction SilentlyContinue
            $cnameRec = $dnsCheck | Where-Object { $_.Type -eq 'CNAME' } | Select-Object -First 1
            if ($cnameRec) {
                $hasCname = $true
                $cnameTarget = $cnameRec.NameHost
            }
        }
    } catch { }
    
    if ($hasCname) {
        $infoMessages += "Info: _dmarc.$Domain uses CNAME to $cnameTarget (not recommended - direct TXT records are preferred)."
    }
    
    # Get all TXT records separately to check for multiple DMARC records
    $allDmarcRecords = @(Resolve-TxtAll $dmarcHost | Where-Object { $_ -match '(?i)v=DMARC1' })
    
    # Check for multiple DMARC records (RFC violation)
    if ($allDmarcRecords.Count -gt 1) {
        $warnings += "Warning: Multiple DMARC records detected (RFC violation) - behavior is undefined!"
        $status = 'FAIL'
        $reason = "DMARC: multiple records (RFC violation)"
        $details += "Multiple DMARC records found ($($allDmarcRecords.Count)):"
        foreach ($rec in $allDmarcRecords) {
            $details += "  - $rec"
        }
    }
    
    # Use the joined version for parsing (first DMARC record if multiple)
    $dmarcTxt = if ($allDmarcRecords.Count -gt 0) { $allDmarcRecords[0] } else { Resolve-Txt $dmarcHost }
    $dmarcMap = @{}
    $pVal = $null

    if ($dmarcTxt) {
        $details += "TXT at _dmarc.${Domain}:"
        $details += $dmarcTxt
        $tags = "v","p","sp","rua","ruf","fo","aspf","adkim","pct"
        foreach ($t in $tags) {
            $m = [regex]::Match($dmarcTxt, "(?im)(^|;)\s*$t\s*=\s*([^;]+)")
            if ($m.Success) {
                $val = $m.Groups[2].Value.Trim()
                $dmarcMap[$t] = $val
                $details += "- $t = $val"
                if ($t -eq 'p') { $pVal = $val }
            }
        }
        
        # Parse rua/ruf addresses (can be comma-separated)
        if ($dmarcMap.ContainsKey('rua')) {
            $ruaAddresses = $dmarcMap['rua'] -split ',' | ForEach-Object { $_.Trim() }
            $details += "- rua addresses: $($ruaAddresses.Count)"
            foreach ($addr in $ruaAddresses) {
                if ($addr -match '^mailto:') {
                    $details += "  * $addr"
                } else {
                    $details += "  * $addr (⚠️ not mailto:)"
                    $warnings += "Warning: DMARC rua address '$addr' does not use mailto: URI"
                }
            }
        }
        if ($dmarcMap.ContainsKey('ruf')) {
            $rufAddresses = $dmarcMap['ruf'] -split ',' | ForEach-Object { $_.Trim() }
            $details += "- ruf addresses: $($rufAddresses.Count)"
            foreach ($addr in $rufAddresses) {
                if ($addr -match '^mailto:') {
                    $details += "  * $addr"
                } else {
                    $details += "  * $addr (⚠️ not mailto:)"
                    $warnings += "Warning: DMARC ruf address '$addr' does not use mailto: URI"
                }
            }
        }
        
        # Build reason string
        $reasonParts = @()
        if ($pVal) { $reasonParts += "p=$pVal" }
        if ($dmarcMap.ContainsKey('pct')) { $reasonParts += "pct=$($dmarcMap['pct'])" }
        if ($dmarcMap.ContainsKey('sp')) { $reasonParts += "sp=$($dmarcMap['sp'])" } else { $reasonParts += "sp=missing" }
        if ($dmarcMap.ContainsKey('adkim')) { $reasonParts += "adkim=$($dmarcMap['adkim'])" } else { $reasonParts += "adkim=r" }
        if ($dmarcMap.ContainsKey('aspf')) { $reasonParts += "aspf=$($dmarcMap['aspf'])" } else { $reasonParts += "aspf=r" }
        if ($dmarcMap.ContainsKey('rua')) { $reasonParts += "rua=ok" } else { $reasonParts += "rua=missing" }
        $reason = "DMARC: " + ($reasonParts -join "; ")
        
        # Check for additional warnings (shown in reason but don't change severity if p=reject)
        if ($dmarcMap.ContainsKey('pct') -and [int]$dmarcMap['pct'] -lt 100) {
            $warnings += "Warning: DMARC pct<100 - not all messages are subject to policy."
        }
        if (-not $dmarcMap.ContainsKey('sp')) {
            $infoMessages += "Info: DMARC sp (subdomain policy) not set - subdomains will inherit main policy."
        }
        if (-not $dmarcMap.ContainsKey('rua') -and -not $dmarcMap.ContainsKey('ruf')) {
            $warnings += "Warning: DMARC has no reporting addresses (rua/ruf)."
        }
        if (-not $dmarcMap.ContainsKey('adkim') -or $dmarcMap['adkim'] -match '(?i)^r') {
            $infoMessages += "Info: DMARC adkim=relaxed (default) - consider strict mode for better security."
        }
        if (-not $dmarcMap.ContainsKey('aspf') -or $dmarcMap['aspf'] -match '(?i)^r') {
            $infoMessages += "Info: DMARC aspf=relaxed (default) - consider strict mode for better security."
        }
        
        # Strict profile: p=reject → PASS, p=quarantine → WARN, p=none → WARN, missing/other → FAIL
        if ($pVal -and $pVal -match '(?i)^reject$') {
            $status = 'PASS'
            $infoMessages += "DMARC policy is enforced (p=reject)."
        } elseif ($pVal -and $pVal -match '(?i)^quarantine$') {
            $status = 'WARN'
            $warnings += "Warning: DMARC p=quarantine is not fully enforced. Upgrade to p=reject for strict protection."
        } elseif ($pVal -and $pVal -match '(?i)^none$') {
            $status = 'WARN'
            $warnings += "Warning: DMARC is in monitoring mode only (p=none). Upgrade to p=reject for enforcement."
        } else {
            $status = 'FAIL'
        }
    } else {
        $details += "No DMARC record found at _dmarc.$Domain"
        $reason = "DMARC: missing"
        $status = 'FAIL'
    }

    return New-CheckResult -Section 'DMARC' -Status $status -Details $details -Warnings $warnings -InfoMessages $infoMessages -Data @{ 
        DmarcMap = $dmarcMap
        DmarcTxt = $dmarcTxt
        Enforced = ($pVal -match '(?i)^reject$')
        Reason = $reason
    }
}

function Test-TLSReport {
    param(
        [string]$Domain,
        [bool]$HasMX,
        [bool]$DomainExists = $true
    )

    $details = @()
    $warnings = @()
    $infoMessages = @()
    $status = 'FAIL'
    $reason = ""
    
    # If domain doesn't exist, mark as N/A
    if (-not $DomainExists) {
        return New-CheckResult -Section 'SMTP TLS Reporting (TLS-RPT)' -Status 'N/A' -Details @("Domain does not exist - no NS records found.") -InfoMessages @("Not applicable - domain does not exist") -Data @{
            TlsRptTxt = $null
            Reason = "TLS-RPT: N/A (domain does not exist)"
        }
    }

    if (-not $HasMX) {
        $infoMessages += "Not applicable - domain cannot receive email"
        return New-CheckResult -Section 'SMTP TLS Reporting (TLS-RPT)' -Status 'N/A' -InfoMessages $infoMessages -Data @{ Reason = "N/A: no MX records" }
    }

    $tlsRptHost = "_smtp._tls.$Domain"
    $tlsRptTxt = Resolve-Txt $tlsRptHost

    if ($tlsRptTxt) {
        $details += "TXT at $($tlsRptHost):"
        $details += $tlsRptTxt
        $hasV = [bool]($tlsRptTxt -match "(?i)\bv=TLSRPTv1\b")
        $ruaMatch = [regex]::Match($tlsRptTxt, "(?i)\bru[a]\s*=\s*(mailto:[^,;]+|https?://[^,;]+)")
        
        # Check for v=TLSRPTv1 to distinguish from wildcard TXT records
        if ($hasV) { 
            $details += "- v=TLSRPTv1 present: True" 
            if ($ruaMatch.Success) { $details += ("- rua: {0}" -f $ruaMatch.Groups[1].Value) }
            $status = 'PASS'
            $reason = "TLS-RPT: configured"
            $infoMessages += "TLS-RPT is configured for encryption monitoring."
        } else {
            # TXT record exists but doesn't contain v=TLSRPTv1 - likely a wildcard DNS record
            $details += "- v=TLSRPTv1 present: False (likely wildcard TXT record, not actual TLS-RPT)"
            $details += "No TLS-RPT record found (recommended for encryption monitoring)."
            $status = 'WARN'
            $reason = "TLS-RPT: missing"
            $warnings += "Warning: Wildcard TXT record detected - not a valid TLS-RPT configuration."
            $warnings += "Warning: TLS-RPT not configured. Recommended for monitoring TLS encryption issues."
        }
    } else {
        $details += "No TLS-RPT record found (recommended for encryption monitoring)."
        $status = 'WARN'
        $reason = "TLS-RPT: missing"
        $warnings += "Warning: TLS-RPT not configured. Recommended for monitoring TLS encryption issues."
    }

    return New-CheckResult -Section 'SMTP TLS Reporting (TLS-RPT)' -Status $status -Details $details -Warnings $warnings -InfoMessages $infoMessages -Data @{ 
        TlsRptTxt = $tlsRptTxt
        Reason = $reason
    }
}

function Write-CheckResult {
    param(
        [Parameter(ValueFromPipeline)]
        $Result
    )
    
    Write-Section $Result.Section
    
    # Details
    foreach ($line in $Result.Details) {
        Write-Host $line
    }
    
    # Info messages
    foreach ($info in $Result.InfoMessages) {
        Write-Host $info -ForegroundColor Cyan
    }
    
    # Warnings
    foreach ($warn in $Result.Warnings) {
        Write-Host $warn -ForegroundColor Yellow
    }
    
    # Status
    $color = switch ($Result.Status) {
        'PASS' { 'Green' }
        'OK'   { 'Green' }  # Legacy support
        'FAIL' { 'Red' }
        'WARN' { 'Yellow' }
        'N/A'  { 'Yellow' }
    }
    Write-Host "$($Result.Section) status: $($Result.Status)" -ForegroundColor $color
}

function ConvertTo-HtmlSection {
    param(
        [Parameter(ValueFromPipeline)]
        $Result
    )
    
    # Get verbose title and info text
    $verboseTitle = $Result.Section
    $infoText = ""
    
    switch ($Result.Section) {
        "MX Records" { 
            $verboseTitle = "MX Records"
            $infoText = "Mail Exchange (MX) records define which servers are authorized to receive email for your domain. Missing or incorrect MX records mean your domain cannot receive mail reliably." 
        }
        "SPF" { 
            $verboseTitle = "SPF (Sender Policy Framework)"
            $infoText = "SPF (Sender Policy Framework) helps prevent email spoofing by specifying which mail servers are allowed to send messages on behalf of your domain. Weak or missing SPF records make it easier for attackers to impersonate your domain." 
        }
        "DKIM" { 
            $verboseTitle = "DKIM (DomainKeys Identified Mail)"
            $infoText = "DKIM (DomainKeys Identified Mail) adds a digital signature to outgoing messages, proving they were not altered in transit and originate from an authorized sender. Without valid DKIM keys, recipients cannot verify the authenticity of your emails." 
        }
        "MTA-STS" { 
            $verboseTitle = "MTA-STS (Mail Transfer Agent - Strict Transport Security)"
            $infoText = "MTA-STS (Mail Transfer Agent - Strict Transport Security) enforces encrypted mail delivery (TLS) between servers, protecting messages from interception. Without MTA-STS, emails may still be sent unencrypted even if your server supports TLS."
            
            # Check for wildcard TXT record case (TXT exists but no v=STSv1)
            if ($Result.Data -and $Result.Data.MtaStsTxt -and $Result.Data.MtaStsTxt -notmatch '(?i)\bv=STSv1\b' -and $Result.Status -eq 'FAIL') {
                $infoText += "`n`n<strong>Note - Wildcard DNS Detected:</strong> A TXT record was found at _mta-sts but it does not contain 'v=STSv1'. This is likely caused by a wildcard DNS configuration (*.domain) that returns SPF or other records for all subdomains. This is treated as 'missing' rather than misconfigured."
            }
        }
        "DMARC" { 
            $verboseTitle = "DMARC (Domain-based Message Authentication, Reporting and Conformance)"
            $infoText = "DMARC (Domain-based Message Authentication, Reporting and Conformance) ties SPF and DKIM together and instructs receiving servers how to handle messages that fail authentication. A missing or unenforced DMARC policy allows spoofed emails to appear legitimate." 
        }
        "SMTP TLS Reporting (TLS-RPT)" { 
            $verboseTitle = "TLS-RPT (SMTP TLS Reporting)"
            $infoText = "TLS-RPT (SMTP TLS Reporting) provides feedback about encryption issues in mail delivery, helping administrators identify failed or downgraded TLS connections. It is optional but highly recommended for visibility and security monitoring."
            
            # Check for wildcard TXT record case (TXT exists but no v=TLSRPTv1)
            if ($Result.Data -and $Result.Data.TlsRptTxt -and $Result.Data.TlsRptTxt -notmatch '(?i)\bv=TLSRPTv1\b' -and $Result.Status -eq 'WARN') {
                $infoText += "`n`n<strong>Note - Wildcard DNS Detected:</strong> A TXT record was found at _smtp._tls but it does not contain 'v=TLSRPTv1'. This is likely caused by a wildcard DNS configuration (*.domain) that returns SPF or other records for all subdomains. This is treated as 'missing' rather than misconfigured."
            }
        }
    }
    
    $html = "  <h2>$verboseTitle</h2>`n"
    
    if ($infoText) {
        $html += "  <p>$([System.Web.HttpUtility]::HtmlEncode($infoText))</p>`n"
    }
    
    if ($Result.Details -and $Result.Details.Count -gt 0) {
        $html += "  <pre>"
        foreach ($line in $Result.Details) {
            $html += ([System.Web.HttpUtility]::HtmlEncode($line) + "`n")
        }
        $html += "</pre>`n"
    }
    
    $allMessages = @()
    if ($Result.InfoMessages -and $Result.InfoMessages.Count -gt 0) { $allMessages += $Result.InfoMessages }
    if ($Result.Warnings -and $Result.Warnings.Count -gt 0) { $allMessages += $Result.Warnings }
    if ($allMessages.Count -gt 0) {
        $html += "`n  <div class='info-block'>`n"
        foreach ($msg in $allMessages) {
            $cls = 'status-info'
            if ($msg -match '^(?i)\s*Warning:') { 
                $cls = 'status-warn'
            }
            $encodedMsg = [System.Web.HttpUtility]::HtmlEncode($msg)
            $html += ("    <p class='" + $cls + "'>" + $encodedMsg + "</p>`n")
        }
        $html += "  </div>`n"
    }
    
    $statusText = "$($Result.Section) status: $($Result.Status)"
    $clsFinal = switch ($Result.Status) {
        'PASS' { 'status-ok' }
        'OK'   { 'status-ok' }
        'FAIL' { 'status-fail' }
        'WARN' { 'status-warn' }
        'N/A'  { 'status-info' }
    }
    $encodedStatus = [System.Web.HttpUtility]::HtmlEncode($statusText)
    $html += "  <p class='" + $clsFinal + "'>" + $encodedStatus + "</p>`n"
    
    return $html
}

function Write-Section($title) {
  Write-Host ""
  Write-Host "=== $title ===" -ForegroundColor White
}

function Write-StatusLine {
  param([string]$Label, $Status, $Details = "")
  
  # Map status to color
  $color = switch ($Status) {
    'PASS' { 'Green' }
    'OK'   { 'Green' }  # Legacy support
    'WARN' { 'Yellow' }
    'FAIL' { 'Red' }
    'N/A'  { 'Cyan' }
    default { 'White' }
  }
  
  # Map status to display text (OK is legacy, normalize to PASS)
  $statusText = switch ($Status) {
    'OK'   { 'PASS' }
    'PASS' { 'PASS' }
    default { $Status }
  }
  
  Write-Host ("- {0}: " -f $Label) -NoNewline
  Write-Host $statusText -ForegroundColor $color
  
  # Show details if provided (e.g., MX records)
  if ($Details) {
    Write-Host ("  {0}" -f $Details) -ForegroundColor Gray
  }
}

# Build resolver list
$Resolvers = @()
if ($DnsServer) { $Resolvers += $DnsServer }
$Resolvers += @('8.8.8.8','1.1.1.1')
$Resolvers = $Resolvers | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique

function Resolve-TxtAll {
  param([string]$Name)

  foreach ($srv in $Resolvers) {
    try {
      if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        $ans = Resolve-DnsName -Name $Name -Type TXT -Server $srv -ErrorAction Stop
        $txtRecs = $ans | Where-Object { $_.Type -eq 'TXT' -and $_.PSObject.Properties['Strings'] }

        $strings = @(foreach ($rec in $txtRecs) { ($rec.Strings -join '') })
        if ($strings.Count -gt 0) { return $strings }

        # Follow any CNAME to the target and query TXT there
        $cname = ($ans | Where-Object { $_.Type -eq 'CNAME' } | Select-Object -First 1 -ExpandProperty NameHost -ErrorAction SilentlyContinue)
        if ($cname) {
          $ans2 = Resolve-DnsName -Name $cname -Type TXT -Server $srv -ErrorAction Stop
          $txtRecs2 = $ans2 | Where-Object { $_.Type -eq 'TXT' -and $_.PSObject.Properties['Strings'] }
          $strings2 = @(foreach ($rec in $txtRecs2) { ($rec.Strings -join '') })
          if ($strings2.Count -gt 0) { return $strings2 }
        }
      }
      else {
        # Fallback: nslookup - harder to separate multiple records, return as single-item array
        $out = nslookup -type=txt $Name $srv 2>$null
        $txt = ($out | Select-String -Pattern '"([^"]*)"' -AllMatches).Matches.Value -replace '"',''
        $joined = ($txt -join '')
        if ($joined) { return @($joined) }
      }
    } catch { }
  }
  return @()
}

function Resolve-Txt {
  param([string]$Name)

  foreach ($srv in $Resolvers) {
    try {
      if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
  # Primary query
        $ans = Resolve-DnsName -Name $Name -Type TXT -Server $srv -ErrorAction Stop
        $txtRecs = $ans | Where-Object { $_.Type -eq 'TXT' -and $_.PSObject.Properties['Strings'] }

        $strings = foreach ($rec in $txtRecs) { ($rec.Strings -join '') }
        if ($strings -and $strings.Count -gt 0) { return ($strings -join ' ') }

  # Follow any CNAME to the target and query TXT there
        $cname = ($ans | Where-Object { $_.Type -eq 'CNAME' } | Select-Object -First 1 -ExpandProperty NameHost -ErrorAction SilentlyContinue)
        if ($cname) {
          $ans2 = Resolve-DnsName -Name $cname -Type TXT -Server $srv -ErrorAction Stop
          $txtRecs2 = $ans2 | Where-Object { $_.Type -eq 'TXT' -and $_.PSObject.Properties['Strings'] }
          $strings2 = foreach ($rec in $txtRecs2) { ($rec.Strings -join '') }
          if ($strings2 -and $strings2.Count -gt 0) { return ($strings2 -join ' ') }
        }
      }
      else {
  # Fallback: nslookup
        $out = nslookup -type=txt $Name $srv 2>$null
        $txt = ($out | Select-String -Pattern '"([^"]*)"' -AllMatches).Matches.Value -replace '"',''
        $joined = ($txt -join '')
        if ($joined) { return $joined }
      }
    } catch { }
  }
  return $null
}

function Resolve-NS {
  param([string]$Domain)

  $result = @{
    NSRecords = @()
    Status = 'Unknown'  # 'Success', 'NXDOMAIN', 'SERVFAIL', 'Unknown'
  }

  foreach ($srv in $Resolvers) {
    try {
      if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        try {
          $ans = Resolve-DnsName -Name $Domain -Type NS -Server $srv -ErrorAction Stop
          $nsRecs = $ans | Where-Object { $_.Type -eq 'NS' } | Select-Object -ExpandProperty NameHost
          if (@($nsRecs).Count -gt 0) { 
            $result.NSRecords = $nsRecs
            $result.Status = 'Success'
            return $result
          }
        } catch {
          # Check error message to determine type of failure
          $errMsg = $_.Exception.Message
          if ($errMsg -match 'NXDOMAIN|does not exist|Non-existent domain') {
            $result.Status = 'NXDOMAIN'
          } else {
            # Any other DNS error (SERVFAIL, timeout, no response, etc.) = DNS misconfigured
            $result.Status = 'SERVFAIL'
          }
        }
      }
      else {
        # Fallback: nslookup
        $out = nslookup -type=ns $Domain $srv 2>&1 | Out-String
        
        # Check for specific error messages
        if ($out -match 'Non-existent domain') {
          $result.Status = 'NXDOMAIN'
        } elseif ($out -match 'nameserver\s*=\s*(\S+)') {
          # Found NS records
          $lines = $out -split "`n" | Where-Object { $_ -match 'nameserver\s*=\s*(\S+)' }
          $nsResult = @()
          foreach ($line in $lines) {
            if ($line -match 'nameserver\s*=\s*(\S+)') {
              $nsResult += $Matches[1]
            }
          }
          if (@($nsResult).Count -gt 0) {
            $result.NSRecords = $nsResult
            $result.Status = 'Success'
            return $result
          }
        } else {
          # Any error that's not NXDOMAIN (Server failed, No response, timeout, etc.)
          if ($out -match 'Server failed|No response|timeout|Request timed out|connection timed out') {
            $result.Status = 'SERVFAIL'
          }
        }
      }
    } catch {
      # Catch-all for any exception
      $errMsg = $_.Exception.Message
      if ($errMsg -match 'NXDOMAIN|does not exist|Non-existent domain') {
        $result.Status = 'NXDOMAIN'
      } else {
        # Any other error = DNS misconfigured
        $result.Status = 'SERVFAIL'
      }
    }
  }
  
  # If we got here without Success and no specific status was set, 
  # treat as SERVFAIL (DNS misconfigured) rather than Unknown
  if ($result.Status -eq 'Unknown') {
    $result.Status = 'SERVFAIL'
  }
  
  return $result
}

function Resolve-MX {
  param([string]$Domain)

  foreach ($srv in $Resolvers) {
    try {
      if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        $ans = Resolve-DnsName -Name $Domain -Type MX -Server $srv -ErrorAction Stop

        $mxRecs = $ans |
          Where-Object {
            # Section may be missing in some versions; accept the line anyway
            ($_.PSObject.Properties.Match('Section').Count -eq 0 -or $_.Section -eq 'Answer') -and
            (
              $_.PSObject.Properties.Match('NameExchange').Count -gt 0 -or
              ($_.PSObject.Properties.Match('Type').Count -gt 0 -and $_.Type -eq 'MX') -or
              ($_.PSObject.Properties.Match('QueryType').Count -gt 0 -and $_.QueryType -eq 'MX')
            )
          } |
          Select-Object @{n='Preference';e={ if ($_.PSObject.Properties.Match('Preference')) { $_.Preference } else { 0 } }},
                        @{n='NameExchange';e={ $_.NameExchange }}

        if (@($mxRecs).Count -gt 0) { return $mxRecs }
      }
      else {
  # Fallback: nslookup
        $out = nslookup -type=mx $Domain $srv 2>$null
        $lines = $out | Where-Object { $_ -match 'mail exchanger =|preference =' }
        $result = @()
        foreach ($line in $lines) {
          if ($line -match 'preference\s*=\s*(\d+),\s*mail exchanger\s*=\s*(\S+)') {
            $result += [pscustomobject]@{ Preference = [int]$Matches[1]; NameExchange = $Matches[2] }
          } elseif ($line -match 'mail exchanger\s*=\s*(\S+)') {
            $result += [pscustomobject]@{ Preference = 0; NameExchange = $Matches[1] }
          }
        }
        if (@($result).Count -gt 0) { return $result }
      }
    } catch { }
  }
  return @()
}

function Resolve-SPF {
  param([string]$Domain)

  foreach ($srv in $Resolvers) {
    try {
      if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        $ans = Resolve-DnsName -Name $Domain -Type TXT -Server $srv -ErrorAction Stop
        $txts = foreach($rec in $ans) {
          if ($rec.PSObject.Properties['Strings']) { ($rec.Strings -join '') }
        }
        $spf = @($txts | Where-Object { $_ -match '(?i)\bv=spf1\b' })
        if ($spf.Count -gt 0) { return $spf }
      } else {
  # Fallback: nslookup (find block near "v=spf1" and join quoted strings)
        $out = nslookup -type=txt $Domain $srv 2>$null
        $hit = $out | Select-String -Pattern 'v=spf1' -Context 0,3 | Select-Object -First 1
        if ($hit) {
          $lines = @($hit.Line) + $hit.Context.PostContext
          $txt = ($lines | Select-String -Pattern '"([^"]*)"' -AllMatches).Matches.Value -replace '"','' -join ''
          if ($txt) { return @($txt) }
        }
      }
    } catch { }
  }
  return @()
}

function Get-HttpText($url){
  try {
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers @{ "User-Agent"="MailStackCheck/1.1" } -TimeoutSec 10
    return [string]$resp.Content
  } catch {
    return $null
  }
}

function Convert-MarkdownToHtml {
  param([string]$Markdown)
  if ([string]::IsNullOrWhiteSpace($Markdown)) { return "" }
  
  # First, extract and convert tables before HTML encoding
  # More flexible pattern that handles optional blank lines
  $tablePattern = '(?ms)^\|(.+?)\|[\r\n]+\|[-:\s|]+\|[\r\n]+((?:[\r\n]*\|.+?\|[\r\n]*)+)'
  $tables = @{}
  $tableIndex = 0
  $Markdown = [regex]::Replace($Markdown, $tablePattern, {
    param($match)
    $tableIndex++
    $placeholder = "___TABLE_PLACEHOLDER_$tableIndex___"
    
    # Parse table - get all lines with pipes
    $lines = $match.Value -split '[\r\n]+' | Where-Object { $_ -match '\|' -and $_.Trim() }
    if ($lines.Count -lt 2) { return $match.Value }
    
    $headerLine = $lines[0].Trim()
    $headers = ($headerLine -split '\|' | Where-Object { $_.Trim() }) | ForEach-Object { $_.Trim() }
    
    # Find separator line and skip to data rows
    $separatorIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match '^\|[\s\-:|]+\|$') {
        $separatorIdx = $i
        break
      }
    }
    
    if ($separatorIdx -eq -1) { return $match.Value }
    
    $dataLines = $lines[($separatorIdx + 1)..($lines.Count - 1)]
    
    $tableHtml = "<table>`n<thead><tr>"
    foreach ($h in $headers) {
      $tableHtml += "<th>$h</th>"
    }
    $tableHtml += "</tr></thead>`n<tbody>`n"
    
    foreach ($line in $dataLines) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $cells = ($line -split '\|' | Where-Object { $_.Trim() }) | ForEach-Object { $_.Trim() }
      if ($cells.Count -eq 0) { continue }
      $tableHtml += "<tr>"
      foreach ($cell in $cells) {
        $tableHtml += "<td>$cell</td>"
      }
      $tableHtml += "</tr>`n"
    }
    $tableHtml += "</tbody></table>"
    
    $tables[$placeholder] = $tableHtml
    return "`n$placeholder`n"
  })
  
  # Now process the rest of the markdown
  $html = [System.Web.HttpUtility]::HtmlEncode($Markdown)
  
  # Headings
  $html = $html -replace '(?m)^# {1}\s*(.+)$', '<h1>$1</h1>'
  $html = $html -replace '(?m)^## {1}\s*(.+)$', '<h2>$1</h2>'
  $html = $html -replace '(?m)^### {1}\s*(.+)$', '<h3>$1</h3>'
  $html = $html -replace '(?m)^#### {1}\s*(.+)$', '<h4>$1</h4>'
  $html = $html -replace '(?m)^##### {1}\s*(.+)$', '<h5>$1</h5>'
  $html = $html -replace '(?m)^###### {1}\s*(.+)$', '<h6>$1</h6>'
  # Bold and italic
  $html = $html -replace '\*\*(.+?)\*\*', '<strong>$1</strong>'
  $html = $html -replace '(?<!\*)\*(.+?)\*', '<em>$1</em>'
  # Code fences
  $html = $html -replace '(?s)```(.*?)```', '<pre><code>$1</code></pre>'
  # Inline code
  $html = $html -replace '`([^`]+)`', '<code>$1</code>'
  # Blockquotes
  $html = $html -replace '(?m)^&gt;\s*(.+)$', '<blockquote>$1</blockquote>'
  # Links [text](url)
  $html = $html -replace '\[([^\]]+)\]\(([^\)]+)\)', '<a href="$2">$1</a>'
  
  # Lists (improved handling) - process line by line to properly group
  $lines = $html -split '[\r\n]+'
  $result = New-Object System.Collections.Generic.List[string]
  $inList = $false
  
  foreach ($line in $lines) {
    if ($line -match '^(?:- |\* )(.*)$') {
      # This is a list item
      if (-not $inList) {
        $result.Add('<ul>')
        $inList = $true
      }
      $content = $Matches[1]
      $result.Add("<li>$content</li>")
    } else {
      # Not a list item
      if ($inList) {
        $result.Add('</ul>')
        $inList = $false
      }
      if (-not [string]::IsNullOrWhiteSpace($line)) {
        $result.Add($line)
      }
    }
  }
  
  # Close any open list
  if ($inList) {
    $result.Add('</ul>')
  }
  
  $html = $result -join "`n"
  
  # Restore tables (they're already HTML, no encoding needed)
  foreach ($key in $tables.Keys) {
    $html = $html.Replace([System.Web.HttpUtility]::HtmlEncode($key), $tables[$key])
  }
  
  # Paragraphs (but not for lines that are part of lists, headings, or tables)
  $html = $html -replace '(?m)^(?!<h\d|<ul>|<li>|<pre>|<p>|</|<code>|<strong>|<em>|<table>|<blockquote>)(.+)$', '<p>$1</p>'
  
  # Clean up empty paragraphs
  $html = $html -replace '<p>\s*</p>', ''
  
  return $html
}

function Compress-ResultsForAI {
  param([array]$AllResults)
  function Truncate([string]$s, [int]$max=250) { if ([string]::IsNullOrWhiteSpace($s)) { return '' } if ($s.Length -le $max) { return $s } return $s.Substring(0,$max) }
  $domains = @()
  $notableDeviations = @()
  
  foreach ($r in $AllResults) {
    try {
      $mxProviders = @()
      if ($r.MXResult -and $r.MXResult.Data -and $r.MXResult.Data.MXRecords) {
        $mxProviders = @($r.MXResult.Data.MXRecords | ForEach-Object { [string]$_.NameExchange })
      }
      $issues = @()
      function Add-Issue([string]$t) { if (-not [string]::IsNullOrWhiteSpace($t)) { if ($issues -notcontains $t) { $issues += $t } } }
      if ($r.SPFResult -and $r.SPFResult.Status -ne 'PASS' -and $r.SPFResult.Status -ne 'OK') { Add-Issue ("SPF: " + (Truncate([string]$r.SPFResult.Data.Reason,160))) }
      if ($r.DKIMResult -and $r.DKIMResult.Status -ne 'PASS') { Add-Issue ("DKIM: " + (Truncate([string]$r.DKIMResult.Data.Reason,160))) }
      if ($r.DMARCResult -and $r.DMARCResult.Status -ne 'PASS') { Add-Issue ("DMARC: " + (Truncate([string]$r.DMARCResult.Data.Reason,160))) }
      if ($r.MTAStsResult -and $r.MTAStsResult.Status -ne 'PASS') { Add-Issue ("MTA-STS: " + (Truncate([string]$r.MTAStsResult.Data.Reason,160))) }
      if ($r.TLSResult -and $r.TLSResult.Status -ne 'PASS') { Add-Issue ("TLS-RPT: " + (Truncate([string]$r.TLSResult.Data.Reason,160))) }

      # Collect notable warnings from all checks (for AI context)
      $domainName = [string]$r.Domain
      foreach ($check in @($r.SPFResult, $r.DKIMResult, $r.DMARCResult, $r.MTAStsResult, $r.TLSResult, $r.MXResult)) {
        if ($check -and $check.Warnings) {
          foreach ($warn in $check.Warnings) {
            if (-not [string]::IsNullOrWhiteSpace($warn)) {
              # Extract just the warning message (remove "Warning: " prefix if present)
              $warnMsg = $warn -replace '^Warning:\s*', ''
              # Use PSCustomObject instead of hashtable for proper Group-Object support
              $notableDeviations += [PSCustomObject]@{
                domain = $domainName
                message = $warnMsg
              }
            }
          }
        }
      }

      $domains += @{
        domain  = [string]$r.Domain
        overall = [string]$r.Summary.Status
        checks  = @{
          spf     = @{ status = [string]$r.SPFResult.Status;   reason = (Truncate([string]$r.SPFResult.Data.Reason)) }
          dkim    = @{ status = [string]$r.DKIMResult.Status;  reason = (Truncate([string]$r.DKIMResult.Data.Reason)) }
          dmarc   = @{ status = [string]$r.DMARCResult.Status; reason = (Truncate([string]$r.DMARCResult.Data.Reason)) }
          mta_sts = @{ status = [string]$r.MTAStsResult.Status; reason = (Truncate([string]$r.MTAStsResult.Data.Reason)) }
          tls_rpt = @{ status = [string]$r.TLSResult.Status;   reason = (Truncate([string]$r.TLSResult.Data.Reason)) }
        }
        mx      = @{ 
          providers = $mxProviders
          status = [string]$r.MXResult.Status
          reason = (Truncate([string]$r.MXResult.Data.Reason))
        }
        issues  = $issues
      }
    } catch {
      # Skip malformed entry
    }
  }
  
  # Calculate summary statistics for deterministic reporting
  $stats = @{
    domain_total = $domains.Count
    mx = @{
      has_mx = 0       # Domains with MX records
      no_mx = 0        # Domains without MX (send-only)
      servfail = 0     # Domains with DNS SERVFAIL errors
    }
    dmarc = @{
      missing = 0
      p_none = 0
      p_quarantine = 0
      p_reject = 0
      pct_partial = 0
      no_reporting = 0
      fail = 0
      warn = 0
      pass = 0
    }
    spf = @{
      missing = 0
      fail = 0
      warn = 0
      pass = 0
    }
    dkim = @{
      missing = 0
      fail = 0
      warn = 0
      pass = 0
      na = 0
    }
    mta_sts = @{
      missing = 0
      fail = 0
      warn = 0
      pass = 0
      na = 0
    }
    tls_rpt = @{
      missing = 0
      fail = 0
      warn = 0
      pass = 0
      na = 0
    }
  }
  
  foreach ($d in $domains) {
    # MX - categorize domain MX status
    $mxReason = [string]$d.mx.reason
    if ($mxReason -match 'DNS misconfigured|SERVFAIL') {
      $stats.mx.servfail++
    } elseif ($mxReason -match 'send-only|No MX') {
      $stats.mx.no_mx++
    } elseif ($d.mx.providers -and @($d.mx.providers).Count -gt 0) {
      $stats.mx.has_mx++
    } else {
      # Fallback: no providers = no MX
      $stats.mx.no_mx++
    }
    
    # DMARC - count based on status, track reason for context
    $dmarcStatus = $d.checks.dmarc.status
    $dmarcReason = [string]$d.checks.dmarc.reason
    if ($dmarcStatus -eq 'PASS' -or $dmarcStatus -eq 'OK') { 
      $stats.dmarc.pass++
      if ($dmarcReason -match 'p=reject') { $stats.dmarc.p_reject++ }
    }
    elseif ($dmarcStatus -eq 'WARN') { 
      $stats.dmarc.warn++
      if ($dmarcReason -match 'p=none') { $stats.dmarc.p_none++ }
      if ($dmarcReason -match 'p=quarantine') { $stats.dmarc.p_quarantine++ }
    }
    elseif ($dmarcStatus -eq 'FAIL') { 
      if ($dmarcReason -match 'not found|missing') { 
        $stats.dmarc.missing++
      } else {
        $stats.dmarc.fail++
      }
    }
    # Track pct<100 across all DMARC configs (critical issue regardless of policy)
    if ($dmarcReason -match 'pct=(\d+)' -and [int]$Matches[1] -lt 100) { 
      $stats.dmarc.pct_partial++ 
    }
    # Track missing reporting addresses (rua/ruf)
    if ($dmarcReason -match 'rua=missing|ruf=missing' -or ($dmarcStatus -ne 'FAIL' -and $dmarcReason -notmatch 'rua=' -and $dmarcReason -notmatch 'ruf=')) {
      $stats.dmarc.no_reporting++
    }
    
    # SPF - count based on status
    $spfStatus = $d.checks.spf.status
    $spfReason = [string]$d.checks.spf.reason
    if ($spfStatus -eq 'PASS' -or $spfStatus -eq 'OK') { $stats.spf.pass++ }
    elseif ($spfStatus -eq 'WARN') { $stats.spf.warn++ }
    elseif ($spfStatus -eq 'FAIL') { 
      if ($spfReason -match 'not found|missing') { 
        $stats.spf.missing++
      } else {
        $stats.spf.fail++
      }
    }
    
    # Check if domain has MX records (for DKIM/MTA-STS/TLS-RPT applicability)
    $hasMX = $false
    if ($d.mx -and $d.mx.providers -and @($d.mx.providers).Count -gt 0) {
      $hasMX = $true
    }
    
    # DKIM - only applicable if domain has MX
    if (-not $hasMX) {
      $stats.dkim.na++
    } else {
      $dkimStatus = $d.checks.dkim.status
      $dkimReason = [string]$d.checks.dkim.reason
      if ($dkimStatus -eq 'PASS' -or $dkimStatus -eq 'OK') { $stats.dkim.pass++ }
      elseif ($dkimStatus -eq 'WARN') { $stats.dkim.warn++ }
      elseif ($dkimStatus -eq 'FAIL') { 
        if ($dkimReason -match 'not found|no valid|missing') { 
          $stats.dkim.missing++
        } else {
          $stats.dkim.fail++
        }
      }
    }
    
    # MTA-STS - only applicable if domain has MX
    if (-not $hasMX) {
      $stats.mta_sts.na++
    } else {
      $mtaStsStatus = $d.checks.mta_sts.status
      $mtaStsReason = [string]$d.checks.mta_sts.reason
      if ($mtaStsStatus -eq 'PASS' -or $mtaStsStatus -eq 'OK') { $stats.mta_sts.pass++ }
      elseif ($mtaStsStatus -eq 'WARN') { $stats.mta_sts.warn++ }
      elseif ($mtaStsStatus -eq 'FAIL') { 
        if ($mtaStsReason -match 'missing|not found') { 
          $stats.mta_sts.missing++
        } else {
          $stats.mta_sts.fail++
        }
      }
    }
    
    # TLS-RPT - only applicable if domain has MX
    if (-not $hasMX) {
      $stats.tls_rpt.na++
    } else {
      $tlsRptStatus = $d.checks.tls_rpt.status
      $tlsRptReason = [string]$d.checks.tls_rpt.reason
      if ($tlsRptStatus -eq 'PASS' -or $tlsRptStatus -eq 'OK') { $stats.tls_rpt.pass++ }
      elseif ($tlsRptStatus -eq 'WARN') { 
        if ($tlsRptReason -match 'missing|not found') { 
          $stats.tls_rpt.missing++
        } else {
          $stats.tls_rpt.warn++
        }
      }
      elseif ($tlsRptStatus -eq 'FAIL') { $stats.tls_rpt.fail++ }
    }
  }
  
  # Aggregate notable_deviations by message to reduce payload size
  $aggregatedDeviations = @()
  if ($notableDeviations.Count -gt 0) {
    $grouped = $notableDeviations | Group-Object -Property message
    foreach ($group in $grouped) {
      $aggregatedDeviations += [PSCustomObject]@{
        message = [string]$group.Name
        count = [int]$group.Count
      }
    }
    # Sort by count descending (most common issues first)
    $aggregatedDeviations = $aggregatedDeviations | Sort-Object -Property count -Descending
  }
  
  return @{ 
    generated = (Get-Date).ToString('u')
    total_domains = $domains.Count
    calculated = $stats
    notable_deviations = $aggregatedDeviations
    # TEMP TEST: Exclude domains array to reduce tokens and force AI to use calculated stats
    # domains = $domains
  }
}

function New-ActivityPlanFromResults {
  param(
    [pscustomobject[]]$AllResults,
    [string]$RulesPath,
    [string]$OutputPath
  )
  
  Write-Host "`nGenerating activity plan from remediation recommendations..." -ForegroundColor Cyan
  
  if (-not (Test-Path $RulesPath)) {
    Write-Host "  [ERROR] Rules file not found: $RulesPath" -ForegroundColor Red
    return $null
  }
  
  # Load rules
  try {
    $rulesJson = Get-Content -Path $RulesPath -Raw -ErrorAction Stop | ConvertFrom-Json
  } catch {
    Write-Host "  [ERROR] Failed to load rules: $_" -ForegroundColor Red
    return $null
  }
  
  $activities = @()
  $today = Get-Date
  $activityCounter = @{}
  
  foreach ($result in $AllResults) {
    $domain = $result.Domain
    
    # Evaluate each rule against domain data
    foreach ($rule in $rulesJson.rules) {
      $shouldApply = Test-RuleCondition -Rule $rule -Result $result
      
      if ($shouldApply) {
        # Generate unique activity counter per domain/control/phase
        $counterKey = "$domain-$($rule.phase)-$($rule.control)"
        if (-not $activityCounter.ContainsKey($counterKey)) {
          $activityCounter[$counterKey] = 1
        } else {
          $activityCounter[$counterKey]++
        }
        $counter = $activityCounter[$counterKey]
        
        # Generate activity ID
        $activityId = "ACT-{0}-{1}-{2}-{3:D3}" -f $domain, $rule.phase, $rule.control, $counter
        $description = $rule.activity_template -replace '\{domain\}', $domain
        
        # Calculate dependency
        $dependsOn = ''
        if ($rule.depends_on_activity) {
          $depTemplate = $rule.depends_on_activity
          $depTemplate = $depTemplate -replace '\{domain\}', $domain
          # Find the actual activity ID that matches this pattern
          $matchingActivity = $activities | Where-Object { 
            $_.Domain -eq $domain -and 
            $_.ActivityID -match "$domain-$($depTemplate.Split('-')[1])-$($depTemplate.Split('-')[2])"
          } | Select-Object -First 1
          if ($matchingActivity) {
            $dependsOn = $matchingActivity.ActivityID
          }
        }
        
        $activity = [PSCustomObject]@{
          ActivityID = $activityId
          Phase = $rule.phase
          Category = $rule.category
          Domain = $domain
          ActivityDescription = $description
          BusinessImpact = $rule.business_impact
          EstimatedDays = $rule.estimated_days
          StartDate = $today.ToString('yyyy-MM-dd')
          EndDate = $today.AddDays($rule.estimated_days).ToString('yyyy-MM-dd')
          DependsOn = $dependsOn
          Status = 'Not Started'
          Owner = ''
        }
        
        $activities += $activity
        
        # Process follow-up activities if defined
        if ($rule.follow_up_activities) {
          foreach ($followUp in $rule.follow_up_activities) {
            # Generate counter for follow-up
            $followUpCounterKey = "$domain-$($followUp.phase)-$($rule.control)"
            if (-not $activityCounter.ContainsKey($followUpCounterKey)) {
              $activityCounter[$followUpCounterKey] = 1
            } else {
              $activityCounter[$followUpCounterKey]++
            }
            $followUpCounter = $activityCounter[$followUpCounterKey]
            
            $followUpId = "ACT-{0}-{1}-{2}-{3:D3}" -f $domain, $followUp.phase, $rule.control, $followUpCounter
            $followUpDescription = $followUp.activity_template -replace '\{domain\}', $domain
            
            # Calculate follow-up dependency
            $followUpDependsOn = ''
            if ($followUp.depends_on_activity) {
              $followUpDepTemplate = $followUp.depends_on_activity -replace '\{domain\}', $domain
              # Find matching activity
              $matchingFollowUpActivity = $activities | Where-Object { 
                $_.Domain -eq $domain -and 
                $_.ActivityID -match "$domain-$($followUpDepTemplate.Split('-')[1])-$($followUpDepTemplate.Split('-')[2])"
              } | Select-Object -First 1
              if ($matchingFollowUpActivity) {
                $followUpDependsOn = $matchingFollowUpActivity.ActivityID
              }
            }
            
            $followUpActivity = [PSCustomObject]@{
              ActivityID = $followUpId
              Phase = $followUp.phase
              Category = $rule.category
              Domain = $domain
              ActivityDescription = $followUpDescription
              BusinessImpact = $followUp.business_impact
              EstimatedDays = $followUp.estimated_days
              StartDate = $today.ToString('yyyy-MM-dd')
              EndDate = $today.AddDays($followUp.estimated_days).ToString('yyyy-MM-dd')
              DependsOn = $followUpDependsOn
              Status = 'Not Started'
              Owner = ''
            }
            
            $activities += $followUpActivity
          }
        }
      }
    }
  }
  
  if ($activities.Count -eq 0) {
    Write-Host "  [WARN] No activities generated from rules" -ForegroundColor Yellow
    return $null
  }
  
  # Dependency-based date calculation for all activities
  # Create activity lookup by ID for fast dependency resolution
  $activityLookup = @{}
  foreach ($act in $activities) {
    $activityLookup[$act.ActivityID] = $act
  }
  
  # Recalculate dates based on dependencies (both P0 and P1)
  $today = Get-Date
  
  foreach ($activity in $activities) {
    # If activity has a dependency, start the day after dependency ends
    if (-not [string]::IsNullOrWhiteSpace($activity.DependsOn)) {
      $depActivityId = $activity.DependsOn
      if ($activityLookup.ContainsKey($depActivityId)) {
        $depActivity = $activityLookup[$depActivityId]
        $depEndDate = [DateTime]::Parse($depActivity.EndDate)
        $newStartDate = $depEndDate.AddDays(1)
        
        # Update dates
        $activity.StartDate = $newStartDate.ToString('yyyy-MM-dd')
        $activity.EndDate = $newStartDate.AddDays([int]$activity.EstimatedDays).ToString('yyyy-MM-dd')
      }
    }
  }
  
  # Phase separation: All P1 must start after all P0 complete
  $p0Activities = $activities | Where-Object { $_.Phase -eq 'P0' }
  $p1Activities = $activities | Where-Object { $_.Phase -eq 'P1' }
  
  if ($p0Activities -and $p1Activities) {
    # Find latest P0 end date (after dependency adjustments)
    $latestP0EndDate = ($p0Activities | ForEach-Object { [DateTime]::Parse($_.EndDate) } | Measure-Object -Maximum).Maximum
    $p1GlobalStartDate = $latestP0EndDate.AddDays(1)
    
    Write-Host "  Latest P0 completion: $($latestP0EndDate.ToString('yyyy-MM-dd'))" -ForegroundColor Cyan
    Write-Host "  P1 phase starts: $($p1GlobalStartDate.ToString('yyyy-MM-dd'))" -ForegroundColor Cyan
    
    # Ensure all P1 activities start no earlier than global P1 start date
    foreach ($p1Activity in $p1Activities) {
      $currentStartDate = [DateTime]::Parse($p1Activity.StartDate)
      
      if ($currentStartDate -lt $p1GlobalStartDate) {
        # Activity would start too early, push it to P1 global start
        $p1Activity.StartDate = $p1GlobalStartDate.ToString('yyyy-MM-dd')
        $p1Activity.EndDate = $p1GlobalStartDate.AddDays([int]$p1Activity.EstimatedDays).ToString('yyyy-MM-dd')
      }
    }
  }
  
  # Sort activities by Phase (P0, P1), then by Domain, then by Category
  $activities = $activities | Sort-Object -Property @{Expression={$_.Phase}; Ascending=$true}, @{Expression={$_.Domain}; Ascending=$true}, @{Expression={$_.Category}; Ascending=$true}
  
  # Export CSV
  $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $csvPath = Join-Path $OutputPath "activity-plan-$timestamp.csv"
  
  try {
    $activities | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
  } catch {
    Write-Host "  [ERROR] Failed to export CSV: $_" -ForegroundColor Red
    return $null
  }
  
  # Summary output
  $p0Count = @($activities | Where-Object { $_.Phase -eq 'P0' }).Count
  $p1Count = @($activities | Where-Object { $_.Phase -eq 'P1' }).Count
  
  Write-Host "  [OK] Activity plan saved: $csvPath" -ForegroundColor Green
  Write-Host "      Total activities: $($activities.Count)" -ForegroundColor Gray
  Write-Host "      P0 (Immediate):   $p0Count activities" -ForegroundColor Red
  Write-Host "      P1 (High):        $p1Count activities" -ForegroundColor Yellow
  
  return $csvPath
}

function Test-RuleCondition {
  param(
    [pscustomobject]$Rule,
    [pscustomobject]$Result
  )
  
  $condition = $Rule.condition
  
  # Access Summary properties (Result objects from mailchecker have nested Summary object)
  $summary = $Result.Summary
  if (-not $summary) {
    return $false
  }
  
  # Helper to check if domain has MX records
  $mxReason = if ($Result.MXResult) { $Result.MXResult.Data.Reason } else { '' }
  $hasMX = $mxReason -notmatch 'No MX|send-only|N/A' -and 
           $Result.MXResult.Status -ne 'N/A'
  
  # Parse and evaluate conditions based on result object structure
  # Domain existence check
  if ($condition -match 'domain_exists == false') {
    return $summary.Domain_Exists -eq $false
  }
  
  # SPF conditions
  if ($condition -match "spf\.status == 'FAIL' && spf\.present == false") {
    return $Result.SPFResult.Status -eq 'FAIL' -and $summary.SPF_Present -eq $false
  }
  if ($condition -match "spf\.status == 'FAIL' && spf\.reason =~ 'lookup'") {
    return $Result.SPFResult.Status -eq 'FAIL' -and $Result.SPFResult.Data.Reason -match 'lookup'
  }
  if ($condition -match "spf\.status == 'WARN' && spf\.healthy == false && spf\.reason =~ 'lookup'") {
    return $Result.SPFResult.Status -eq 'WARN' -and $summary.SPF_Healthy -eq $false -and $Result.SPFResult.Data.Reason -match 'lookup'
  }
  if ($condition -match "spf\.status == 'WARN' && spf\.present == true && spf\.healthy == true") {
    return $Result.SPFResult.Status -eq 'WARN' -and $summary.SPF_Present -eq $true -and $summary.SPF_Healthy -eq $true
  }
  
  # DMARC conditions
  if ($condition -match "dmarc\.status == 'FAIL' && dmarc\.present == false") {
    return $Result.DMARCResult.Status -eq 'FAIL' -and $summary.DMARC_Present -eq $false
  }
  if ($condition -match "dmarc\.status == 'WARN' && dmarc\.reason =~ 'p=none'") {
    return $Result.DMARCResult.Status -eq 'WARN' -and $Result.DMARCResult.Data.Reason -match 'p=none'
  }
  if ($condition -match "dmarc\.status == 'WARN' && dmarc\.reason =~ 'p=quarantine'") {
    return $Result.DMARCResult.Status -eq 'WARN' -and $Result.DMARCResult.Data.Reason -match 'p=quarantine'
  }
  if ($condition -match "dmarc\.status == 'WARN' && dmarc\.reason =~ 'rua=missing'") {
    return $Result.DMARCResult.Status -eq 'WARN' -and $Result.DMARCResult.Data.Reason -match 'rua=missing'
  }
  
  # DKIM conditions
  if ($condition -match "dkim\.status == 'FAIL' && dkim\.valid_selector == false") {
    return $Result.DKIMResult.Status -eq 'FAIL' -and $summary.DKIM_ValidSelector -eq $false
  }
  
  # TLS-RPT conditions
  if ($condition -match "tls_rpt\.status == 'WARN' && tls_rpt\.present == false && has_mx == true") {
    return $Result.TLSResult.Status -eq 'WARN' -and $summary.TLS_RPT_Present -eq $false -and $hasMX
  }
  
  # MTA-STS conditions
  # Rule 1: FAIL status with MX - deploy MTA-STS mode=testing (depends on TLS-RPT)
  if ($condition -match "mta_sts\.status == 'FAIL' && has_mx == true") {
    return $Result.MTAStsResult.Status -eq 'FAIL' -and $hasMX
  }
  # Rule 2: WARN status OR not enforced, with MX - transition to enforce
  if ($condition -match "mta_sts\.status == 'WARN' && mta_sts\.enforced == false && has_mx == true") {
    return $Result.MTAStsResult.Status -eq 'WARN' -and $summary.MTA_STS_Enforced -eq $false -and $hasMX
  }
  
  return $false
}

function ConvertTo-PlainObject {
  param($obj)
  if ($null -eq $obj) { return $null }
  if ($obj -is [string] -or $obj -is [bool] -or $obj -is [int] -or $obj -is [double] -or $obj -is [decimal]) { return $obj }
  if ($obj -is [System.Collections.IDictionary]) {
    $ht = @{}
    foreach ($k in $obj.Keys) { $ht[[string]$k] = ConvertTo-PlainObject $obj[$k] }
    return $ht
  }
  if ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [string])) {
    $arr = @()
    foreach ($it in $obj) { $arr += ,(ConvertTo-PlainObject $it) }
    return $arr
  }
  if ($obj -is [psobject]) {
    $ht = @{}
    foreach ($p in $obj.PSObject.Properties) { $ht[[string]$p.Name] = ConvertTo-PlainObject $p.Value }
    return $ht
  }
  return ("" + $obj)
}

function Get-EstimatedTokens {
  param([string]$Text)
  if ($null -eq $Text) { return 0 }
  return [int][Math]::Ceiling(($Text.Length) / 4)
}

function Invoke-OpenAIAnalysis {
  param(
    [pscustomobject]$Compressed,
    [string]$AgentPath,
    [string]$SchemaPath,
    [string]$Model,
    [int]$MaxOutputTokens = 8000,
    [int]$TimeoutSeconds = 60
  )
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $agent = [System.IO.File]::ReadAllText($AgentPath, $utf8NoBom)
  $schemaJson = Get-Content -Path $SchemaPath -Raw -ErrorAction Stop | ConvertFrom-Json
  # Normalize schema for Responses API
  try { Set-OpenAIAdditionalPropertiesFalse -Node $schemaJson } catch {}
  try { Set-OpenAIRequiredForAllProperties -Node $schemaJson } catch {}

  $userMeta = @{ date = (Get-Date).ToString('u'); domain_count = $Compressed.total_domains } | ConvertTo-Json -Depth 5 -Compress
  $compressedJson = $Compressed | ConvertTo-Json -Depth 6 -Compress

  $inputTokens = (Get-EstimatedTokens -Text ($agent + $userMeta + $compressedJson))
  $maxIn = [int]([int]($env:OPENAI_MAX_INPUT_TOKENS) | ForEach-Object { if ($_ -gt 0) { $_ } else { 50000 } })
  if ($inputTokens -gt $maxIn) { throw "Input exceeds token cap ($inputTokens > $maxIn)." }

  $priceIn = [double]([double]$env:OPENAI_PRICE_INPUT_PER_1K_USD | ForEach-Object { if ($_ -gt 0) { $_ } else { 0.005 } })
  $priceOut = [double]([double]$env:OPENAI_PRICE_OUTPUT_PER_1K_USD | ForEach-Object { if ($_ -gt 0) { $_ } else { 0.015 } })
  $maxCost = [double]([double]$env:OPENAI_MAX_COST_USD_PER_RUN | ForEach-Object { if ($_ -gt 0) { $_ } else { 0.10 } })
  $inputCost = [Math]::Round((($inputTokens/1000.0)*$priceIn), 4)
  $allowedOutputCost = $maxCost - $inputCost
  $allowedOutputTokens = if ($allowedOutputCost -gt 0) { [int][Math]::Floor(($allowedOutputCost / $priceOut) * 1000) } else { 0 }
  $effectiveMaxOutput = [int][Math]::Max(0, [int][Math]::Min($MaxOutputTokens, $allowedOutputTokens))
  $costEstimate = [Math]::Round($inputCost + (($effectiveMaxOutput/1000.0)*$priceOut), 4)
  Write-Host ("  Cost cap: {0:N2} | Input est: {1:N4} | Allowed out tokens: {2} | Using out tokens: {3} | Est total: {4:N4}" -f $maxCost, $inputCost, $allowedOutputTokens, $effectiveMaxOutput, $costEstimate) -ForegroundColor Gray
  if ($effectiveMaxOutput -le 0) { throw ("Estimated cost {0:N4} exceeds cap {1:N2}." -f $inputCost, $maxCost) }

  # Always target OpenAI's official Responses API endpoint (ignore OPENAI_BASE_URL)
  $baseUrl = 'https://api.openai.com/v1'
  $url = "$baseUrl/responses"
  $apiKey = $env:OPENAI_API_KEY
  if ([string]::IsNullOrWhiteSpace($apiKey)) { throw 'OPENAI_API_KEY missing' }
  $modelToUse = if ($Model) { $Model } elseif ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { 'gpt-5-mini' }

  Write-Host "  Building JSON payload..." -ForegroundColor Gray
  $swBuild = [Diagnostics.Stopwatch]::StartNew()
  # Build object payload using typed content blocks and strict schema
  $userCombined = "All output must be in English. Return a single JSON strictly validating the provided schema under response_format.\nRun:\n" + $userMeta + "\nData:\n" + $compressedJson
  # Use a minimal strict schema first to force raw JSON (expand later)
  $minimalSchema = [ordered]@{
    type = 'object'
    properties = [ordered]@{
      summary         = @{ type = 'string'; maxLength = 900 }
      overall_status  = @{ type = 'string'; enum = @('PASS','WARN','FAIL') }
      key_findings    = @{ type = 'array'; items = @{ type = 'string'; maxLength = 220 }; minItems = 3; maxItems = 6 }
      report_markdown = @{ type = 'string'; maxLength = 6000 }
    }
    required = @('summary','overall_status','key_findings','report_markdown')
    additionalProperties = $false
  }
  $inputBlocks = @(
    @{ role = 'system'; content = @(@{ type = 'input_text'; text = $agent }) },
    @{ role = 'user'  ; content = @(@{ type = 'input_text'; text = $userCombined }) }
  )
  # Sanitize content part types defensively
  foreach ($blk in $inputBlocks) {
    if ($blk.content) {
      for ($i=0; $i -lt $blk.content.Count; $i++) {
        if ($blk.content[$i].type -ne 'input_text') { $blk.content[$i].type = 'input_text' }
      }
    }
  }
  # Check if model is a reasoning model (gpt-5 series)
  $isReasoningModel = $modelToUse -match '^gpt-5'
  
  # Set verbosity based on model type
  $verbosityLevel = if ($isReasoningModel) { 'low' } else { 'medium' }
  
  $bodyObj = [ordered]@{
    model             = $modelToUse
    max_output_tokens = $effectiveMaxOutput
    text              = [ordered]@{ format = [ordered]@{ type='json_schema'; name='analysis'; strict=$true; schema=$minimalSchema }; verbosity = $verbosityLevel }
    input             = $inputBlocks
  }
  
  # Only add reasoning parameter for reasoning models
  if ($isReasoningModel) {
    # Options: 'low' (fast), 'medium' (balanced), 'high' (thorough)
    # Higher effort = better quality checks but slower and more expensive
    $reasoningEffort = if ($env:OPENAI_REASONING_EFFORT) { $env:OPENAI_REASONING_EFFORT } else { 'low' }
    $bodyObj['reasoning'] = [ordered]@{ effort = $reasoningEffort }
  }
  # Normalize content-part types to input_text for Responses API
  try {
    $null = ConvertTo-NormalizedResponsesContentTypes -BodyObj $bodyObj
  } catch {}
  $bodyJson = $bodyObj | ConvertTo-Json -Depth 100 -Compress
  $swBuild.Stop()
  Write-Host ("  Payload built in {0} ms" -f $swBuild.ElapsedMilliseconds) -ForegroundColor Gray
  # Dump payload for debugging (compact and pretty variants, no BOM)
  # DISABLED: Not needed unless debugging
  # try {
  #   $dumpPath = Join-Path (Get-Location) 'openai-payload.json'
  #   $prettyPath = Join-Path (Get-Location) 'openai-payload.pretty.json'
  #   [System.IO.File]::WriteAllText($dumpPath, $bodyJson, (New-Object System.Text.UTF8Encoding($false)))
  #   try {
  #     $pretty = $bodyObj | ConvertTo-Json -Depth 100
  #     [System.IO.File]::WriteAllText($prettyPath, $pretty, (New-Object System.Text.UTF8Encoding($false)))
  #   } catch {}
  #   Write-Host ("  Payload dumped to {0} (pretty: {1})" -f $dumpPath, $prettyPath) -ForegroundColor Gray
  # } catch {}

  # Get timeout configuration
  $timeout = if ($env:OPENAI_TIMEOUT_SECONDS) { [int]$env:OPENAI_TIMEOUT_SECONDS } else { $TimeoutSeconds }
  $bodyBytes = [System.Text.Encoding]::UTF8.GetByteCount($bodyJson)
  # Safety check to ensure we only ever post to the official endpoint
  if ($url -notmatch '^https://api\.openai\.com/v1/responses$') { throw ("Safety check failed: URL ({0}) is not OpenAI's official endpoint." -f $url) }
  Write-Host ("  Endpoint: {0}" -f $url) -ForegroundColor Gray
  Write-Host ("  Submitting request to OpenAI (input~{0} tokens, max_output={1}, timeout={2}s, body={3} bytes)..." -f $inputTokens, $effectiveMaxOutput, $timeout, $bodyBytes) -ForegroundColor Gray
  try {
    # Use HttpClient (PS5-stable) for the main call as well
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    try { [System.Net.ServicePointManager]::Expect100Continue = $false } catch {}
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($timeout)
    $client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $apiKey)
    $client.DefaultRequestHeaders.Accept.Clear()
    $client.DefaultRequestHeaders.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new('application/json'))
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('Mailchecker-PS5/1.0')
    $content = New-Object System.Net.Http.StringContent($bodyJson, [System.Text.Encoding]::UTF8, 'application/json')
    $swSend = [Diagnostics.Stopwatch]::StartNew()
    $httpResp = $client.PostAsync($url, $content).GetAwaiter().GetResult()
    $rawResp = $httpResp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $swSend.Stop()
    if (-not $httpResp.IsSuccessStatusCode) {
      try { [System.IO.File]::WriteAllText((Join-Path (Get-Location) 'openai-error.json'), $rawResp, (New-Object System.Text.UTF8Encoding($false))) } catch {}
      throw ("OpenAI request failed (HTTP {0} {1}): {2}" -f [int]$httpResp.StatusCode, $httpResp.StatusCode, $rawResp)
    }
    Write-Host ("  OpenAI HTTP OK in {0} ms" -f $swSend.ElapsedMilliseconds) -ForegroundColor Gray
    $resp = $rawResp
  } catch {
    $we = $_.Exception
    throw ("OpenAI request failed: {0}" -f $we.Message)
  }

  # Invoke-RestMethod returns a parsed object already; fall back if it's a string
  $json = $null
  if ($resp -is [string]) {
    if ($PSVersionTable.PSVersion.Major -ge 7) { $json = $resp | ConvertFrom-Json -Depth 100 -ErrorAction SilentlyContinue }
    else { $json = $resp | ConvertFrom-Json -ErrorAction SilentlyContinue }
  } else {
    $json = $resp
  }
  # Best-effort logging of size
  try { $rawStr = ($resp | ConvertTo-Json -Depth 20); Write-Host ("  Response body chars: {0}" -f ($rawStr.Length)) -ForegroundColor Gray } catch {}
  if ($null -eq $json) { throw 'Failed to parse OpenAI response JSON' }
  # Prefer robust parsing into object, fallback to text
  $parsedObj = $null
  try { $parsedObj = ConvertFrom-OpenAIResponseJson -respObj $json } catch {}
  if ($parsedObj) {
    return [PSCustomObject]@{ raw = $json; obj = $parsedObj; text = ($parsedObj | ConvertTo-Json -Depth 50); input_tokens = $inputTokens; est_cost = $costEstimate }
  } else {
    $payload = Get-FirstResponsesOutputText -Json $json -FallbackContent $resp.Content
    return [PSCustomObject]@{ raw = $json; text = $payload; input_tokens = $inputTokens; est_cost = $costEstimate }
  }
}

function ConvertTo-NormalizedResponsesContentTypes {
  param([Parameter(Mandatory=$true)][hashtable]$BodyObj)
  if (-not $BodyObj.input) { return $BodyObj }
  foreach ($blk in $BodyObj.input) {
    if (-not $blk.content) { continue }
    for ($i=0; $i -lt $blk.content.Count; $i++) {
      if ($blk.content[$i].type -ne 'input_text') { $blk.content[$i].type = 'input_text' }
    }
  }
  return $BodyObj
}

function Get-FirstResponsesOutputText {
  param(
    [Parameter(Mandatory=$true)]$Json,
    [Parameter(Mandatory=$false)]$FallbackContent
  )
  try {
    if ($Json.output) {
      foreach ($item in $Json.output) {
        if ($item.type -eq 'message' -and $item.content) {
          foreach ($c in $item.content) {
            if ($c.type -eq 'output_text' -and $c.text) { return $c.text }
          }
        }
      }
      # Legacy shape
      if ($Json.output[0].content[0].text) { return $Json.output[0].content[0].text }
    }
    if ($Json.output_text) { return $Json.output_text }
    if ($Json.choices -and $Json.choices[0].message.content) { return $Json.choices[0].message.content }
  } catch {}
  return $FallbackContent
}

function ConvertFrom-OpenAIResponseJson {
  param(
    [Parameter(Mandatory=$true)] $respObj
  )
  # Try to find a completed message first, even if overall status is incomplete
  $jsonText = ($respObj.output |
    Where-Object { $_.type -eq 'message' -and $_.status -eq 'completed' } |
    Select-Object -First 1 -ExpandProperty content |
    Where-Object { $_.type -eq 'output_text' } |
    Select-Object -First 1 -ExpandProperty text)
  
  # If no completed message found and overall status is incomplete, throw error
  if (-not $jsonText -and $respObj.status -eq 'incomplete') {
    $reason = $respObj.incomplete_details.reason
    throw ("Model status=incomplete (reason={0}) - no completed message found." -f $reason)
  }

  if (-not $jsonText) { throw 'No output_text found in response.' }

  if ($jsonText -match '^\s*```') {
    $jsonText = $jsonText -replace '^\s*```(?:json)?\s*',''
    $jsonText = $jsonText -replace '\s*```$',''
  }

  $first = $null
  try { $first = $jsonText | ConvertFrom-Json } catch { $first = ($jsonText.Trim() | ConvertFrom-Json) }
  if ($first -is [string] -and $first.TrimStart().StartsWith('{')) {
    return ($first | ConvertFrom-Json)
  }
  return $first
}

function Set-OpenAIAdditionalPropertiesFalse {
  param([Parameter(Mandatory=$true)]$Node)
  if ($null -eq $Node) { return }
  $typeName = $Node.GetType().Name
  if ($typeName -eq 'Hashtable' -or $typeName -eq 'PSCustomObject') {
    # If object-type schema, ensure additionalProperties:false
    if ($Node.type -eq 'object') {
      $hasProp = $false
      try { $hasProp = $Node.PSObject.Properties.Name -contains 'additionalProperties' } catch {}
      if (-not $hasProp) {
        try { Add-Member -InputObject $Node -NotePropertyName 'additionalProperties' -NotePropertyValue $false -Force } catch {}
      } elseif ($Node.additionalProperties -ne $false) {
        $Node.additionalProperties = $false
      }
      # Recurse into properties
      if ($Node.properties) {
        if ($Node.properties -is [hashtable]) {
          foreach ($k in $Node.properties.Keys) { Set-OpenAIAdditionalPropertiesFalse -Node $Node.properties[$k] }
        } else {
          foreach ($kv in $Node.properties.PSObject.Properties) { Set-OpenAIAdditionalPropertiesFalse -Node $kv.Value }
        }
      }
    }
    # If array-type schema, recurse into items
    if ($Node.type -eq 'array' -and $Node.items) {
      Set-OpenAIAdditionalPropertiesFalse -Node $Node.items
    }
  }
}

function Set-OpenAIRequiredForAllProperties {
  param([Parameter(Mandatory=$true)]$Node)
  if ($null -eq $Node) { return }
  $typeName = $Node.GetType().Name
  if ($typeName -eq 'Hashtable' -or $typeName -eq 'PSCustomObject') {
    if ($Node.type -eq 'object' -and $Node.properties) {
      # Build required array to include all property keys if missing/invalid
      $propNames = @()
      if ($Node.properties -is [hashtable]) {
        foreach ($k in $Node.properties.Keys) { $propNames += $k }
      } else {
        foreach ($p in $Node.properties.PSObject.Properties) { $propNames += $p.Name }
      }
      $needSet = $true
      try {
        if ($Node.required -and ($Node.required -is [System.Collections.IEnumerable])) {
          # If required exists, ensure it includes all keys
          $diff = $propNames | Where-Object { $Node.required -notcontains $_ }
          if ($diff.Count -eq 0) { $needSet = $false }
        }
      } catch {}
      if ($needSet) { $Node.required = $propNames }
      # Recurse
      if ($Node.properties -is [hashtable]) {
        foreach ($k in $Node.properties.Keys) { Set-OpenAIRequiredForAllProperties -Node $Node.properties[$k] }
      } else {
        foreach ($kv in $Node.properties.PSObject.Properties) { Set-OpenAIRequiredForAllProperties -Node $kv.Value }
      }
    }
    if ($Node.type -eq 'array' -and $Node.items) { Set-OpenAIRequiredForAllProperties -Node $Node.items }
  }
}

function Invoke-OpenAIHelloHttpClient {
  param(
    [string]$Model = 'gpt-5-mini',
    [int]$TimeoutSeconds = 60
  )
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
  try { [System.Net.ServicePointManager]::Expect100Continue = $false } catch {}

  $apiKey = $env:OPENAI_API_KEY
  if ([string]::IsNullOrWhiteSpace($apiKey)) { throw 'OPENAI_API_KEY missing' }

  $payloadObj = [ordered]@{
    model = $Model
    input = @(
      @{ role = 'user'; content = @(@{ type = 'input_text'; text = 'Say hello' }) }
    )
  }
  $payloadJson = $payloadObj | ConvertTo-Json -Depth 20 -Compress
  # DISABLED: Payload dump not needed unless debugging
  # try { [System.IO.File]::WriteAllText((Join-Path (Get-Location) 'openai-hello.json'), $payloadJson, (New-Object System.Text.UTF8Encoding($false))) } catch {}

  Add-Type -AssemblyName System.Net.Http
  $handler = New-Object System.Net.Http.HttpClientHandler
  $handler.UseProxy = $false
  $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate

  $client = New-Object System.Net.Http.HttpClient($handler)
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
  $client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $apiKey)
  $client.DefaultRequestHeaders.Accept.Clear()
  $client.DefaultRequestHeaders.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new('application/json'))
  $client.DefaultRequestHeaders.UserAgent.ParseAdd('Mailchecker-PS5/1.0')

  $uri = 'https://api.openai.com/v1/responses'
  $content = New-Object System.Net.Http.StringContent($payloadJson, [System.Text.Encoding]::UTF8, 'application/json')
  $response = $client.PostAsync($uri, $content).GetAwaiter().GetResult()
  $raw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

  if (-not $response.IsSuccessStatusCode) {
    try { [System.IO.File]::WriteAllText((Join-Path (Get-Location) 'openai-error.json'), $raw, (New-Object System.Text.UTF8Encoding($false))) } catch {}
    throw ("HTTP {0} {1}: {2}" -f [int]$response.StatusCode, $response.StatusCode, $raw)
  }
  if ($PSVersionTable.PSVersion.Major -ge 7) { return ($raw | ConvertFrom-Json -Depth 50) }
  else { return ($raw | ConvertFrom-Json) }
}

function Write-AnalysisReport {
  param(
    [string]$AnalysisDir,
    [string]$TemplatePath,
    [pscustomobject]$AnalysisObj
  )
  $tmpl = Get-Content -Path $TemplatePath -Raw -ErrorAction Stop
  function Get-StatusChipHtmlLocal {
    param([string]$status)
    $cls = switch ($status) {
      'PASS' { 'status-chip ok' }
      'OK'   { 'status-chip ok' }
      'WARN' { 'status-chip warn' }
      'FAIL' { 'status-chip fail' }
      default { 'status-chip info' }
    }
    $label = if ($status -eq 'OK') { 'PASS' } else { $status }
    $encoded = [System.Web.HttpUtility]::HtmlEncode($label)
    return ('<span class="' + $cls + '">' + $encoded + '</span>')
  }
  $statusChip = Get-StatusChipHtmlLocal $AnalysisObj.overall_status
  
  # Build conditional sections - only show if we have data
  $keyFindingsSection = ''
  if ($AnalysisObj.key_findings -and @($AnalysisObj.key_findings).Count -gt 0) {
    $keyFindingsHtml = '<ul>' + (($AnalysisObj.key_findings | ForEach-Object { '<li>' + [System.Web.HttpUtility]::HtmlEncode($_) + '</li>' }) -join '') + '</ul>'
    $keyFindingsSection = @"
    <section id="key-findings">
      <h2>Key Findings</h2>
      $keyFindingsHtml
    </section>

"@
  }
  
  $fullReportSection = ''
  if ($AnalysisObj.report_markdown -and $AnalysisObj.report_markdown.Trim().Length -gt 0) {
    # Encode markdown for safe embedding in HTML data attribute
    $markdownEncoded = [System.Web.HttpUtility]::HtmlEncode($AnalysisObj.report_markdown)
    $fullReportSection = @"
    <section id="full-report">
      <h2>Full Report</h2>
      <div class="md" data-markdown="$markdownEncoded"></div>
    </section>

"@
  }
  
  function Get-MetaHtmlLocal {
    param($meta, $usage)
    $lines = @()
    if ($meta) {
      foreach ($p in $meta.PSObject.Properties) { $lines += ($p.Name + ': ' + [System.Web.HttpUtility]::HtmlEncode(($p.Value -as [string]))) }
    }
    if ($usage) {
      foreach ($p in $usage.PSObject.Properties) { $lines += ('usage.' + $p.Name + ': ' + [System.Web.HttpUtility]::HtmlEncode(($p.Value -as [string]))) }
    }
    if ($lines.Count -eq 0) { return '' }
    return @"
    <footer class="meta">
      <h3>Analysis Metadata</h3>
      <pre class="meta">$([System.Web.HttpUtility]::HtmlEncode(($lines -join "`n")))</pre>
    </footer>

"@
  }
  $metaHtml = Get-MetaHtmlLocal -meta $AnalysisObj.meta -usage $AnalysisObj.usage
  $reportDate = (Get-Date).ToString('yyyy-MM-dd')
  $out = $tmpl.Replace('{{REPORT_DATE}}', $reportDate)
  $out = $out.Replace('{{OVERALL_STATUS}}', $statusChip)
  $out = $out.Replace('{{SUMMARY}}', [System.Web.HttpUtility]::HtmlEncode($AnalysisObj.summary))
  $out = $out.Replace('{{KEY_FINDINGS_SECTION}}', $keyFindingsSection)
  $out = $out.Replace('{{FULL_REPORT_SECTION}}', $fullReportSection)
  $out = $out.Replace('{{META}}', $metaHtml)
  $indexPath = Join-Path $AnalysisDir 'index.html'
  $out | Out-File -FilePath $indexPath -Encoding utf8 -Force
}

function Get-DomainReportHtml {
  param(
    [string]$RelAssetsPath,
    [switch]$IncludeBackLink,
    [string]$Domain,
    [pscustomobject]$Summary,
    $mxResult,
    $spfResult,
    $dkimResult,
    $mtaStsResult,
    $dmarcResult,
    $tlsResult
  )
  
  $now = (Get-Date).ToString('u')

  # Load template
  $templatePath = Join-Path $PSScriptRoot 'templates/html/domain-report.html'
  $html = Get-Content -Path $templatePath -Raw -Encoding UTF8
  
  # Build back links
  $backLinkTop = if ($IncludeBackLink) { '    <a href="../index.html" class="nav-link">Back to Summary</a>' } else { '' }
  $backLinkBottom = if ($IncludeBackLink) { '        <p><a href="../index.html" class="back-link">Back to Summary</a></p>' } else { '' }
  
  # Build issues box
  $issues = @()
  $hasFail = $false
  foreach ($result in @($mxResult, $spfResult, $dkimResult, $mtaStsResult, $dmarcResult, $tlsResult)) {
    if ($result.Status -eq 'FAIL') {
      $hasFail = $true
      # Remove duplicate section prefix from reason (e.g., "MTA-STS: missing" becomes "missing")
      # For TLS-RPT, section is "SMTP TLS Reporting (TLS-RPT)" but reason starts with "TLS-RPT:"
      $cleanReason = $result.Data.Reason -replace '^(SPF|DKIM|DMARC|MTA-STS|TLS-RPT):\s*', ''
      $issues += "$($result.Section): $cleanReason"
    } elseif ($result.Status -eq 'WARN') {
      # Remove duplicate section prefix from reason
      $cleanReason = $result.Data.Reason -replace '^(SPF|DKIM|DMARC|MTA-STS|TLS-RPT):\s*', ''
      $issues += "$($result.Section): $cleanReason"
      }
    }
  if ($issues.Count -gt 0) {
    $boxClass = if ($hasFail) { "issues-box-fail" } else { "issues-box" }
    $issuesBox = @"
    <div class="$boxClass">
        <h3>Issues Found</h3>
        <ul>
$(($issues | ForEach-Object { "            <li>$([System.Web.HttpUtility]::HtmlEncode($_))</li>" }) -join "`n")
        </ul>
    </div>
"@
  } else {
    $issuesBox = @"
    <div class="success-box">
        <h3>All Checks Passed</h3>
        <p>No issues detected in the email security configuration.</p>
    </div>
"@
  }

  # Build summary table
  $summaryTable = "<h2>Summary</h2>`n"
  $summaryTable += "<table class='summary-table'><tr><th class='col-check'>Check</th><th class='col-status'>Status</th><th>Details</th></tr>"
  
  $renderStatusCell = {
    param($status)
    $cls = switch ($status) {
      'PASS' { 'status-ok' }
      'OK' { 'status-ok' }
      'WARN' { 'status-warn' }
      'FAIL' { 'status-fail' }
      'N/A' { 'status-info' }
      default { '' }
    }
    $text = switch ($status) { 'OK' { 'PASS' } default { $status } }
    return "<td class='$cls'>$text</td>"
  }
  
  if ($mxResult.Status -eq 'PASS' -or $mxResult.Status -eq 'OK') {
    $mxRecords = ($mxResult.Data.MXRecords | Sort-Object Preference,NameExchange | ForEach-Object { [System.Web.HttpUtility]::HtmlEncode("$($_.Preference) $($_.NameExchange)") }) -join '<br>'
    $summaryTable += "<tr><td>MX Records</td><td class='status-ok' colspan='2'>$mxRecords</td></tr>"
  } elseif ($mxResult.Status -eq 'WARN') {
    $summaryTable += "<tr><td>MX Records</td>" + (& $renderStatusCell $mxResult.Status) + "<td class='td-detail-warn'>$([System.Web.HttpUtility]::HtmlEncode($mxResult.Data.Reason))</td></tr>"
  } elseif ($mxResult.Data.DomainExists -eq $false) {
    $summaryTable += "<tr><td>MX Records</td>" + (& $renderStatusCell $mxResult.Status) + "<td class='td-detail-error'>$([System.Web.HttpUtility]::HtmlEncode($mxResult.Data.Reason))</td></tr>"
  } else {
    $summaryTable += "<tr><td>MX Records</td>" + (& $renderStatusCell $mxResult.Status) + "<td class='td-small'>$([System.Web.HttpUtility]::HtmlEncode($mxResult.Data.Reason))</td></tr>"
  }
  $summaryTable += "<tr><td>SPF</td>" + (& $renderStatusCell $spfResult.Status) + "<td class='td-small'>$([System.Web.HttpUtility]::HtmlEncode($spfResult.Data.Reason))</td></tr>"
  $summaryTable += "<tr><td>DKIM</td>" + (& $renderStatusCell $dkimResult.Status) + "<td class='td-small'>$([System.Web.HttpUtility]::HtmlEncode($dkimResult.Data.Reason))</td></tr>"
  $summaryTable += "<tr><td>DMARC</td>" + (& $renderStatusCell $dmarcResult.Status) + "<td class='td-small'>$([System.Web.HttpUtility]::HtmlEncode($dmarcResult.Data.Reason))</td></tr>"
  $summaryTable += "<tr><td>MTA-STS</td>" + (& $renderStatusCell $mtaStsResult.Status) + "<td class='td-small'>$([System.Web.HttpUtility]::HtmlEncode($mtaStsResult.Data.Reason))</td></tr>"
  $summaryTable += "<tr><td>TLS-RPT</td>" + (& $renderStatusCell $tlsResult.Status) + "<td class='td-small'>$([System.Web.HttpUtility]::HtmlEncode($tlsResult.Data.Reason))</td></tr>"
  $summaryTable += "</table>"

  # Build sections
  $sections = ""
  $sections += ConvertTo-HtmlSection $mxResult
  $sections += ConvertTo-HtmlSection $spfResult
  $sections += ConvertTo-HtmlSection $dkimResult
  $sections += ConvertTo-HtmlSection $dmarcResult
  $sections += ConvertTo-HtmlSection $mtaStsResult
  $sections += ConvertTo-HtmlSection $tlsResult

  # Replace placeholders
  $encodedDomain = [System.Web.HttpUtility]::HtmlEncode($Domain)
  $html = $html -replace '\{\{DOMAIN\}\}', $encodedDomain
  $html = $html -replace '\{\{TIMESTAMP\}\}', $now
  $html = $html -replace '\{\{REL_ASSETS_PATH\}\}', $RelAssetsPath
  $html = $html -replace '\{\{BACK_LINK_TOP\}\}', $backLinkTop
  $html = $html -replace '\{\{BACK_LINK_BOTTOM\}\}', $backLinkBottom
  $html = $html -replace '\{\{ISSUES_BOX\}\}', $issuesBox
  $html = $html -replace '\{\{SUMMARY_TABLE\}\}', $summaryTable
  $html = $html -replace '\{\{SECTIONS\}\}', $sections
  
  # Explicitly return string
  return [string]$html
}

function Write-DomainReportPage {
  param(
    [string]$OutputPath,
    [string]$Domain,
    [pscustomobject]$Summary,
    $mxResult,
    $spfResult,
    $dkimResult,
    $mtaStsResult,
    $dmarcResult,
    $tlsResult
  )
  
  # Sanitize domain name for filename
  $safeDomain = $Domain -replace '[^a-z0-9.-]', '_'
  $domainPath = Join-Path $OutputPath "$safeDomain.html"
  
  $html = Get-DomainReportHtml -RelAssetsPath "../assets" -IncludeBackLink:$true -Domain $Domain -Summary $Summary -mxResult $mxResult -spfResult $spfResult -dkimResult $dkimResult -mtaStsResult $mtaStsResult -dmarcResult $dmarcResult -tlsResult $tlsResult

  # html already complete from helper

  try {
    $html | Out-File -FilePath $domainPath -Encoding utf8 -Force
  } catch {
    Write-Host ("Failed to write domain report for {0}: {1}" -f $Domain, $_) -ForegroundColor Red
  }
}

function Write-HtmlReport {
  param(
    [string]$Path,
    [string]$Domain,
    [pscustomobject]$Summary,
    $mxResult,
    $spfResult,
    $dkimResult,
    $mtaStsResult,
    $dmarcResult,
    $tlsResult
  )

  # Old Render-Section function removed - now using ConvertTo-HtmlSection

  # Ensure assets (CSS/JS) exist alongside the single-page report
  try {
    $outDir = Split-Path -Parent $Path
    $assetsDir = Join-Path $outDir "assets"
    if (-not (Test-Path $assetsDir)) {
      New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null
    }
    Write-AssetsFiles -AssetsPath $assetsDir
  } catch {
    Write-Host ("[WARN] Could not create/write assets for single HTML: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
  }

  $html = Get-DomainReportHtml -RelAssetsPath "assets" -IncludeBackLink:$false -Domain $Domain -Summary $Summary -mxResult $mxResult -spfResult $spfResult -dkimResult $dkimResult -mtaStsResult $mtaStsResult -dmarcResult $dmarcResult -tlsResult $tlsResult

  try {
    $html | Out-File -FilePath $Path -Encoding utf8 -Force
    # Make path clickable in modern terminals (Windows Terminal, VS Code)
    $fullPath = (Resolve-Path $Path).Path
    $fileUrl = "file:///$($fullPath -replace '\\','/')"
    $esc = [char]27
    $clickableLink = "$esc]8;;$fileUrl$esc\$Path$esc]8;;$esc\"
    Write-Host "Wrote HTML report to: $clickableLink" -ForegroundColor Green
  } catch {
    Write-Host ("Failed to write HTML report to {0}: {1}" -f $Path, $_) -ForegroundColor Red
  }
}

function Write-IndexPage {
  param(
    [string]$RootPath,
    [array]$AllResults,
    [string]$CsvFileName = $null,
    [string]$JsonFileName = $null,
    [string]$ActivityPlanFileName = $null
  )
  
  $indexPath = Join-Path $RootPath "index.html"
  $now = (Get-Date).ToString('u')
  $totalDomains = $AllResults.Count
  
  # Load template
  $templatePath = Join-Path $PSScriptRoot 'templates/html/index.html'
  $html = Get-Content -Path $templatePath -Raw -Encoding UTF8
  
  # Calculate statistics - domain level (based on overall status)
  $passResults = @($AllResults | Where-Object { $_.Summary.Status -eq 'PASS' })
  $warnResults = @($AllResults | Where-Object { $_.Summary.Status -eq 'WARN' })
  $failResults = @($AllResults | Where-Object { $_.Summary.Status -eq 'FAIL' })
  
  $passCount = $passResults.Count
  $warnCount = $warnResults.Count
  $failCount = $failResults.Count
  
  # Count status per check type (excluding N/A from totals for applicable checks)
  $mxPass = @($AllResults | Where-Object { $_.MXResult.Status -eq 'PASS' -or $_.MXResult.Status -eq 'OK' }).Count
  $spfPass = @($AllResults | Where-Object { $_.SPFResult.Status -eq 'PASS' }).Count
  
  # For DKIM, MTA-STS, TLS-RPT: only count applicable domains (exclude N/A)
  $dkimApplicable = @($AllResults | Where-Object { $_.DKIMResult.Status -ne 'N/A' }).Count
  $dkimPass = @($AllResults | Where-Object { $_.DKIMResult.Status -eq 'PASS' }).Count
  
  $mtaStsApplicable = @($AllResults | Where-Object { $_.MTAStsResult.Status -ne 'N/A' }).Count
  $mtaStsPass = @($AllResults | Where-Object { $_.MTAStsResult.Status -eq 'PASS' }).Count
  
  $dmarcPass = @($AllResults | Where-Object { $_.DMARCResult.Status -eq 'PASS' }).Count
  
  $tlsApplicable = @($AllResults | Where-Object { $_.TLSResult.Status -ne 'N/A' }).Count
  $tlsPass = @($AllResults | Where-Object { $_.TLSResult.Status -eq 'PASS' }).Count
  
  # Determine icon class for each check type based on worst status
  function Get-CheckIconClass {
    param($CheckResults)
    $hasFail = @($CheckResults | Where-Object { $_ -eq 'FAIL' }).Count -gt 0
    $hasWarn = @($CheckResults | Where-Object { $_ -eq 'WARN' }).Count -gt 0
    
    if ($hasFail) { return 'status-fail' }
    elseif ($hasWarn) { return 'status-warn' }
    else { return 'status-ok' }
  }
  
  $mxIconClass = Get-CheckIconClass ($AllResults | ForEach-Object { $_.MXResult.Status })
  $spfIconClass = Get-CheckIconClass ($AllResults | ForEach-Object { $_.SPFResult.Status })
  $dkimIconClass = Get-CheckIconClass ($AllResults | ForEach-Object { $_.DKIMResult.Status })
  $dmarcIconClass = Get-CheckIconClass ($AllResults | ForEach-Object { $_.DMARCResult.Status })
  $mtaStsIconClass = Get-CheckIconClass ($AllResults | ForEach-Object { $_.MTAStsResult.Status })
  $tlsIconClass = Get-CheckIconClass ($AllResults | ForEach-Object { $_.TLSResult.Status })

  # Build check summary (show applicable counts for N/A-eligible checks)
  $checkSummary = "        <p><span class='$mxIconClass'></span> MX Records: $mxPass/$totalDomains | <span class='$spfIconClass'></span> SPF: $spfPass/$totalDomains | <span class='$dkimIconClass'></span> DKIM: $dkimPass/$dkimApplicable</p>`n"
  $checkSummary += "        <p><span class='$dmarcIconClass'></span> DMARC: $dmarcPass/$totalDomains | <span class='$mtaStsIconClass'></span> MTA-STS: $mtaStsPass/$mtaStsApplicable | <span class='$tlsIconClass'></span> TLS-RPT: $tlsPass/$tlsApplicable</p>"

  # Build action buttons (download links + analysis link)
  $downloadLinks = "    <div class='action-buttons'>`n"
    if ($CsvFileName) {
      $encodedCsvName = [System.Web.HttpUtility]::HtmlEncode($CsvFileName)
    $downloadLinks += "        <a class='btn btn-download' href='" + $encodedCsvName + "'>Download CSV</a>`n"
    }
    if ($JsonFileName) {
      $encodedJsonName = [System.Web.HttpUtility]::HtmlEncode($JsonFileName)
    $downloadLinks += "        <a class='btn btn-download' href='" + $encodedJsonName + "'>Download JSON</a>`n"
    }
    if ($ActivityPlanFileName) {
      $encodedActivityPlanName = [System.Web.HttpUtility]::HtmlEncode($ActivityPlanFileName)
    $downloadLinks += "        <a class='btn btn-download btn-activity-plan' href='" + $encodedActivityPlanName + "'>Download Activity Plan</a>`n"
    }
  $downloadLinks += "        <a class='btn btn-primary' href='analysis/index.html'>View Analysis &amp; Remediation</a>`n"
    $downloadLinks += "    </div>`n"

  # Helper to render status badge - build strings without nested expansion
  function Get-StatusBadgeHtml {
    param([string]$status)
    
    $cls = 'status-info'
    $text = $status
    
    if ($status -eq 'PASS' -or $status -eq 'OK') {
      $cls = 'status-ok'
      $text = 'PASS'
    } elseif ($status -eq 'WARN') {
      $cls = 'status-warn'
      $text = 'WARN'
    } elseif ($status -eq 'FAIL') {
      $cls = 'status-fail'
      $text = 'FAIL'
    } elseif ($status -eq 'N/A') {
      $cls = 'status-info'
      $text = 'N/A'
    }
    
    return "<span class='" + $cls + "' title='" + $text + "'></span>"
  }

  # Build domain rows
  $domainRows = ""
  foreach ($result in $AllResults) {
    $domain = $result.Domain
    $safeDomain = $domain -replace '[^a-z0-9.-]', '_'
    $domainLink = "domains/$safeDomain.html"
    $encodedDomain = [System.Web.HttpUtility]::HtmlEncode($domain)
    
    $overallStatus = $result.Summary.Status
    $statusClass = switch ($overallStatus) {
        'PASS' { 'status-ok' }
        'WARN' { 'status-warn' }
        'FAIL' { 'status-fail' }
        default { '' }
      }
    
    # Collect condensed issues with line breaks
    $issues = @()
    if ($result.SPFResult.Status -eq 'FAIL' -or $result.SPFResult.Status -eq 'WARN') {
      $issues += "SPF: " + ($result.SPFResult.Data.Reason -replace '^SPF: ', '')
    }
    if ($result.DKIMResult.Status -eq 'FAIL') {
      $issues += "DKIM: " + ($result.DKIMResult.Data.Reason -replace '^DKIM: ', '')
    }
    if ($result.MTAStsResult.Status -eq 'FAIL' -or $result.MTAStsResult.Status -eq 'WARN') {
      $issues += "MTA-STS: " + ($result.MTAStsResult.Data.Reason -replace '^MTA-STS: ', '')
    }
    if ($result.DMARCResult.Status -eq 'FAIL' -or $result.DMARCResult.Status -eq 'WARN') {
      # Simplify DMARC - only show actual issues, not informational fields
      $dmarcReason = $result.DMARCResult.Data.Reason -replace '^DMARC: ', ''
      # Extract only the problematic parts
      $dmarcIssues = @()
      
      # If DMARC is completely missing, just show "missing" - don't check for rua/sp/pct
      if ($dmarcReason -eq 'missing') { 
        $dmarcIssues += 'missing' 
      }
      else {
        # DMARC exists but has issues - check specific problems
        if ($dmarcReason -match 'p=none') { $dmarcIssues += 'p=none (monitoring only)' }
        elseif ($dmarcReason -match 'p=quarantine') { $dmarcIssues += 'p=quarantine (not fully enforced)' }
        
        if ($dmarcReason -match 'pct=(\d+)' -and [int]$Matches[1] -lt 100) { $dmarcIssues += "pct=$($Matches[1])" }
        if ($dmarcReason -match 'sp=missing') { $dmarcIssues += 'sp=missing' }
        if ($dmarcReason -match 'rua=missing') { $dmarcIssues += 'rua=missing' }
      }
      
      if ($dmarcIssues.Count -gt 0) {
        $issues += "DMARC: " + ($dmarcIssues -join ', ')
      }
    }
    if ($result.TLSResult.Status -eq 'WARN') {
      $issues += "TLS-RPT: " + ($result.TLSResult.Data.Reason -replace '^TLS-RPT: ', '')
    }
    
    $issuesText = if ($issues.Count -gt 0) { 
      ($issues | ForEach-Object { [System.Web.HttpUtility]::HtmlEncode($_) }) -join '<br>'
    } else {
      '<span class="text-success">No issues</span>' 
    }
    
    # Get MX records for display
    $mxRecordsText = if ($result.MXResult.Status -eq 'PASS' -or $result.MXResult.Status -eq 'OK') {
      ($result.MXResult.Data.MXRecords | Sort-Object Preference,NameExchange | ForEach-Object { 
        [System.Web.HttpUtility]::HtmlEncode("$($_.Preference) $($_.NameExchange)") 
      }) -join '<br>'
    } elseif ($result.MXResult.Status -eq 'N/A') {
      '<span class="text-muted-light">N/A (send-only)</span>'
    } elseif ($result.MXResult.Status -eq 'WARN') {
      # SERVFAIL case - shown as warning with note about DNS issues
      '<span class="text-warning">DNS misconfigured (SERVFAIL)</span>'
    } elseif ($result.MXResult.Data.DomainExists -eq $false) {
      # NXDOMAIN - domain truly doesn't exist
      '<span class="text-error">Domain does not exist</span>'
    } else {
      '<span class="text-error">No MX records</span>'
    }
    
    $encodedDomainLink = [System.Web.HttpUtility]::HtmlAttributeEncode($domainLink)
    
    # Get badge HTML for each status
    $spfBadge = Get-StatusBadgeHtml $result.SPFResult.Status
    $dkimBadge = Get-StatusBadgeHtml $result.DKIMResult.Status
    $mtastsBadge = Get-StatusBadgeHtml $result.MTAStsResult.Status
    $dmarcBadge = Get-StatusBadgeHtml $result.DMARCResult.Status
    $tlsBadge = Get-StatusBadgeHtml $result.TLSResult.Status
    
    $domainRows += "            <tr>`n"
    $domainRows += "                <td class='domain'><a href='" + $encodedDomainLink + "'>" + $encodedDomain + "</a></td>`n"
    $domainRows += "                <td class='td-small'>" + $mxRecordsText + "</td>`n"
    $domainRows += "                <td class='" + $statusClass + " td-center' title='" + $overallStatus + "'></td>`n"
    $domainRows += "                <td class='td-center'>" + $spfBadge + "</td>`n"
    $domainRows += "                <td class='td-center'>" + $dkimBadge + "</td>`n"
    $domainRows += "                <td class='td-center'>" + $dmarcBadge + "</td>`n"
    $domainRows += "                <td class='td-center'>" + $mtastsBadge + "</td>`n"
    $domainRows += "                <td class='td-center'>" + $tlsBadge + "</td>`n"
    $domainRows += "                <td class='td-small'>" + $issuesText + "</td>`n"
    $domainRows += "            </tr>`n"
  }

  # Replace placeholders
  $html = $html -replace '\{\{TIMESTAMP\}\}', $now
  $html = $html -replace '\{\{TOTAL_DOMAINS\}\}', $totalDomains
  $html = $html -replace '\{\{PASS_COUNT\}\}', $passCount
  $html = $html -replace '\{\{WARN_COUNT\}\}', $warnCount
  $html = $html -replace '\{\{FAIL_COUNT\}\}', $failCount
  $html = $html -replace '\{\{CHECK_SUMMARY\}\}', $checkSummary
  $html = $html -replace '\{\{DOWNLOAD_LINKS\}\}', $downloadLinks
  $html = $html -replace '\{\{DOMAIN_ROWS\}\}', $domainRows

  try {
    $html | Out-File -FilePath $indexPath -Encoding utf8 -Force
    # Make path clickable in modern terminals
    $fullPath = (Resolve-Path $indexPath).Path
    $fileUrl = "file:///$($fullPath -replace '\\','/')"
    $esc = [char]27
    $clickableLink = "$esc]8;;$fileUrl$esc\$indexPath$esc]8;;$esc\"
    Write-Host "Wrote index report to: $clickableLink" -ForegroundColor Green
  } catch {
    Write-Host ("Failed to write index report: {0}" -f $_) -ForegroundColor Red
  }
}

function Invoke-DomainCheck {
    param(
        [string]$Domain,
        [string]$Selectors = "default,s1,s2,selector1,selector2,google,mail,k1",
        [bool]$QuietMode = $false
    )
    
$Domain = $Domain.Trim().ToLower()

    if (-not $QuietMode) {
Write-Host "Checking domain: $Domain (Resolvers: $($Resolvers -join ', '))" -ForegroundColor Yellow
    }

# 1) MX Records
$mxResult = Test-MXRecords -Domain $Domain
$mx = $mxResult.Data.MXRecords
$mxOk = @($mx).Count -gt 0
$domainExists = $mxResult.Data.DomainExists
    if (-not $QuietMode) { Write-CheckResult $mxResult }

# 2) SPF
$spfResult = Test-SPFRecords -Domain $Domain -DomainExists $domainExists
$spfRecs = $spfResult.Data.SPFRecords
$spfHealthy = $spfResult.Data.Healthy
    if (-not $QuietMode) { Write-CheckResult $spfResult }

# 3) DKIM (by selectors)
# Check if SPF has any mechanisms other than just v=spf1 and -all
$hasSpfWithMechanisms = $false
if (@($spfRecs).Count -gt 0) {
  foreach ($spf in $spfRecs) {
    $cleanSpf = $spf -replace '(?i)\bv=spf1\s*', '' -replace '(?i)\s*[~+\-?]?all\s*$', '' -replace '^\s+|\s+$', ''
    $hasMechanisms = $cleanSpf.Length -gt 0 -and $cleanSpf -match '(?i)(include:|a:|mx:|ptr:|exists:|redirect=)'
    if ($hasMechanisms) {
      $hasSpfWithMechanisms = $true
      break
    }
  }
}

$selectorList = ($Selectors -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$dkimResult = Test-DKIMRecords -Domain $Domain -Selectors $selectorList -HasMX $mxOk -HasSpfWithMechanisms $hasSpfWithMechanisms -DomainExists $domainExists
$DKIM_AnySelector_Valid = $dkimResult.Data.AnyValid
    if (-not $QuietMode) { Write-CheckResult $dkimResult }

# 4) MTA-STS
$mtaStsResult = Test-MTASts -Domain $Domain -HasMX $mxOk -DomainExists $domainExists
$mtaStsTxt = $mtaStsResult.Data.MtaStsTxt
$MtaStsEnforced = $mtaStsResult.Data.MtaStsEnforced
    if (-not $QuietMode) { Write-CheckResult $mtaStsResult }

# 5) DMARC
$dmarcResult = Test-DMARC -Domain $Domain -DomainExists $domainExists
$dmarcTxt = $dmarcResult.Data.DmarcTxt
$dmarcEnforced = [bool]$dmarcResult.Data.Enforced
    if (-not $QuietMode) { Write-CheckResult $dmarcResult }

# 6) TLS-RPT
$tlsResult = Test-TLSReport -Domain $Domain -HasMX $mxOk -DomainExists $domainExists
$tlsRptTxt = $tlsResult.Data.TlsRptTxt
    if (-not $QuietMode) { Write-CheckResult $tlsResult }

# Summary
$hasMXRecords = [bool]$mxOk
$mxRecordsDisplay = if ($hasMXRecords) { 
    ($mx | Sort-Object Preference,NameExchange | ForEach-Object { "$($_.Preference) $($_.NameExchange)" }) -join ', '
} else { 
    "N/A" 
}

# Collect all reasons for detailed explanation
$allReasons = @()
if ($mxResult.Data.Reason) { $allReasons += $mxResult.Data.Reason }
if ($spfResult.Data.Reason) { $allReasons += $spfResult.Data.Reason }
if ($dkimResult.Data.Reason) { $allReasons += $dkimResult.Data.Reason }
if ($mtaStsResult.Data.Reason) { $allReasons += $mtaStsResult.Data.Reason }
if ($dmarcResult.Data.Reason) { $allReasons += $dmarcResult.Data.Reason }
if ($tlsResult.Data.Reason) { $allReasons += $tlsResult.Data.Reason }
$reasonText = $allReasons -join ' | '

# Determine overall status
$overallStatus = "PASS"
if ($mxResult.Status -eq 'FAIL' -or $spfResult.Status -eq 'FAIL' -or $dkimResult.Status -eq 'FAIL' -or 
    $mtaStsResult.Status -eq 'FAIL' -or $dmarcResult.Status -eq 'FAIL' -or $tlsResult.Status -eq 'FAIL') {
    $overallStatus = "FAIL"
} elseif ($mxResult.Status -eq 'WARN' -or $spfResult.Status -eq 'WARN' -or $dkimResult.Status -eq 'WARN' -or 
          $mtaStsResult.Status -eq 'WARN' -or $dmarcResult.Status -eq 'WARN' -or $tlsResult.Status -eq 'WARN') {
    $overallStatus = "WARN"
}

$summary = [pscustomobject]@{
  Domain                 = $Domain
  Status                 = $overallStatus
  Reason                 = $reasonText
  MX_Records_Present     = $mxRecordsDisplay
  SPF_Present            = [bool](@($spfRecs).Count -gt 0)
  SPF_Healthy            = [bool]$spfHealthy
  DKIM_ValidSelector     = if ($hasMXRecords -or $hasSpfWithMechanisms) { [bool]$DKIM_AnySelector_Valid } else { "N/A" }
  MTA_STS_DNS_Present    = if ($hasMXRecords) { [bool]$mtaStsTxt } else { "N/A" }
  MTA_STS_Enforced       = if ($hasMXRecords) { [bool]$MtaStsEnforced } else { "N/A" }
  DMARC_Present          = [bool]$dmarcTxt
  DMARC_Enforced         = [bool]$dmarcEnforced
  TLS_RPT_Present        = if ($hasMXRecords) { [bool]$tlsRptTxt } else { "N/A" }
}

    if (-not $QuietMode) {
        Write-Section "Summary"
        Write-Host "Tested domain: $Domain" -ForegroundColor White

# Overall status
Write-Host "`nOverall Status: " -NoNewline
$statusColor = switch ($summary.Status) {
    'PASS' { 'Green' }
    'WARN' { 'Yellow' }
    'FAIL' { 'Red' }
    default { 'White' }
}
Write-Host $summary.Status -ForegroundColor $statusColor

# Status per check
Write-Host "`nDetailed Status:"
Write-StatusLine "MX Records"   $mxResult.Status    $(if ($mxResult.Status -eq 'PASS' -or $mxResult.Status -eq 'OK') { $mxRecordsDisplay })
Write-StatusLine "SPF"          $spfResult.Status
Write-StatusLine "DKIM"         $dkimResult.Status
Write-StatusLine "MTA-STS"      $mtaStsResult.Status
Write-StatusLine "DMARC"        $dmarcResult.Status
Write-StatusLine "TLS-RPT"      $tlsResult.Status

Write-Host "`nTip: For DKIM, inspect a real message header to learn the active selector (s=) and re-run with -Selectors 'thatSelector'." -ForegroundColor DarkCyan
    }
    
    # Return all results as hashtable
    return @{
        Domain = $Domain
        MXResult = $mxResult
        SPFResult = $spfResult
        DKIMResult = $dkimResult
        MTAStsResult = $mtaStsResult
        DMARCResult = $dmarcResult
        TLSResult = $tlsResult
        Summary = $summary
    }
}

# --- Main ---

# Step 1: Build domain queue (from bulk file or command line)
$domains = @()
$isBulkMode = $false

if ($BulkFile) {
    # Load domains from bulk file
    $isBulkMode = $true
    if (-not (Test-Path $BulkFile)) {
        Write-Host "Error: File not found: $BulkFile" -ForegroundColor Red
        Write-Host "Please check the file path and try again." -ForegroundColor Yellow
        exit 1
    }
    
    $rawDomains = @(Get-Content $BulkFile | 
               Where-Object { $_ -and $_.Trim() -and -not $_.Trim().StartsWith('#') } |
               ForEach-Object { $_.Trim().ToLower() })
    
    # Remove duplicates and sort alphabetically
    $domains = @($rawDomains | Select-Object -Unique | Sort-Object)
    
    $duplicateCount = $rawDomains.Count - $domains.Count
    if ($duplicateCount -gt 0) {
        Write-Host "Removed $duplicateCount duplicate domain(s)" -ForegroundColor Yellow
    }
    
    if ($domains.Count -eq 0) {
        Write-Host "Error: No valid domains found in $BulkFile" -ForegroundColor Red
        Write-Host "" -ForegroundColor Yellow
        Write-Host "The file appears to be empty or contains only comments/whitespace." -ForegroundColor Yellow
        Write-Host "" -ForegroundColor Yellow
        Write-Host "Expected format (one domain per line):" -ForegroundColor Cyan
        Write-Host "  example.com" -ForegroundColor Gray
        Write-Host "  test.org" -ForegroundColor Gray
        Write-Host "  # This is a comment" -ForegroundColor Gray
        Write-Host "  another-domain.com" -ForegroundColor Gray
        exit 1
    }
} else {
    # Single domain from command line
    $domains = @($Domain)
    }
    
# Step 2: Process all domains in queue (same workflow for all)
Write-Host "Checking $($domains.Count) domain$(if ($domains.Count -gt 1) { 's' }) (Resolvers: $($Resolvers -join ', '))" -ForegroundColor Yellow
    Write-Host ""
    
    $allResults = @()
    $total = $domains.Count
    
    for ($i = 0; $i -lt $total; $i++) {
    if ($total -gt 1) {
        # Quiet mode for bulk
        Write-Host "Processing domain $($i + 1) of ${total}: $($domains[$i])" -ForegroundColor Yellow -NoNewline
        $result = Invoke-DomainCheck -Domain $domains[$i] -Selectors $Selectors -QuietMode $true
        
        # Show overall status on same line
        $statusColor = switch ($result.Summary.Status) {
            'PASS' { 'Green' }
            'WARN' { 'Yellow' }
            'FAIL' { 'Red' }
            default { 'White' }
        }
        Write-Host " (Overall status: " -NoNewline
        Write-Host $result.Summary.Status -ForegroundColor $statusColor -NoNewline
        Write-Host ")"
    } else {
        # Verbose mode for single domain
        $result = Invoke-DomainCheck -Domain $domains[$i] -Selectors $Selectors
    }
        
        $allResults += $result
    }
    
    Write-Host "`nAll domains processed." -ForegroundColor Green

# Step 3: Unified output generation (same for bulk and single domain)
if ($Html -or $FullHtmlExport) {
    # Determine output path
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = "output"
    } else {
        $resolvedOutputPath = $OutputPath
    }
    
    # Track filenames for index page
    $csvFileName = $null
    $jsonFileName = $null
        $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $outputStructure = $null
    
    if ($FullHtmlExport) {
        # Create full structure with assets and domains folders
        if ($BulkFile) {
            $outputStructure = New-OutputStructure -InputFile $BulkFile -OutputPath $OutputPath
        } else {
            $safeDomain = $domains[0] -replace '[^a-z0-9.-]','-'
            $reportDir = Join-Path $resolvedOutputPath "$safeDomain-$ts"
            $outputStructure = New-OutputStructure -RootPath $reportDir
        }
        $resolvedOutputPath = $outputStructure.RootPath
        
        # Write assets (CSS and JS)
        Write-AssetsFiles -AssetsPath $outputStructure.AssetsPath
        if ($BulkFile) {
            Write-Host "Created assets (CSS, JS) in: $($outputStructure.AssetsPath)" -ForegroundColor Cyan
        }
        
        # Export CSV (always with FullHtmlExport)
        # Create enhanced CSV with individual reason columns
        # Sanitize function to remove tabs, newlines, and other problematic characters
        function ConvertTo-CsvSafe($value) {
            if ($null -eq $value) { return "" }
            # Replace tabs with spaces, remove newlines, replace semicolons with commas, and trim
            return $value.ToString() -replace "`t", " " -replace "`r`n", " " -replace "`n", " " -replace "`r", " " -replace ";", ","
        }
        
        $csvData = $allResults | ForEach-Object {
            [PSCustomObject]@{
                Domain = ConvertTo-CsvSafe $_.Domain
                Domain_Exists = ConvertTo-CsvSafe $_.MXResult.Data.DomainExists
                Status = ConvertTo-CsvSafe $_.Summary.Status
                MX_Records = ConvertTo-CsvSafe $_.Summary.MX_Records_Present
                SPF_Status = ConvertTo-CsvSafe $_.SPFResult.Status
                SPF_Reason = ConvertTo-CsvSafe $_.SPFResult.Data.Reason
                DKIM_Status = ConvertTo-CsvSafe $_.DKIMResult.Status
                DKIM_Reason = ConvertTo-CsvSafe $_.DKIMResult.Data.Reason
                DMARC_Status = ConvertTo-CsvSafe $_.DMARCResult.Status
                DMARC_Reason = ConvertTo-CsvSafe $_.DMARCResult.Data.Reason
                MTA_STS_Status = ConvertTo-CsvSafe $_.MTAStsResult.Status
                MTA_STS_Reason = ConvertTo-CsvSafe $_.MTAStsResult.Data.Reason
                TLS_RPT_Status = ConvertTo-CsvSafe $_.TLSResult.Status
                TLS_RPT_Reason = ConvertTo-CsvSafe $_.TLSResult.Data.Reason
                SPF_Present = ConvertTo-CsvSafe $_.Summary.SPF_Present
                SPF_Healthy = ConvertTo-CsvSafe $_.Summary.SPF_Healthy
                DKIM_ValidSelector = ConvertTo-CsvSafe $_.Summary.DKIM_ValidSelector
                MTA_STS_DNS_Present = ConvertTo-CsvSafe $_.Summary.MTA_STS_DNS_Present
                MTA_STS_Enforced = ConvertTo-CsvSafe $_.Summary.MTA_STS_Enforced
                DMARC_Present = ConvertTo-CsvSafe $_.Summary.DMARC_Present
                DMARC_Enforced = ConvertTo-CsvSafe $_.Summary.DMARC_Enforced
                TLS_RPT_Present = ConvertTo-CsvSafe $_.Summary.TLS_RPT_Present
            }
        }
        $csvFileName = "bulk-results-$ts.csv"
        $csvPath = Join-Path $resolvedOutputPath $csvFileName
        $csvData | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ','
        # Make path clickable
        $fullPath = (Resolve-Path $csvPath).Path
        $fileUrl = "file:///$($fullPath -replace '\\','/')"
        $esc = [char]27
        $clickableLink = "$esc]8;;$fileUrl$esc\$csvPath$esc]8;;$esc\"
        Write-Host "CSV exported to: $clickableLink" -ForegroundColor Green
    }
    
    # Export JSON if requested
    if ($Json) {
        $jsonFileName = "results.json"
        $jsonPath = Join-Path $resolvedOutputPath $jsonFileName
        
        # Convert all results to JSON-friendly format
        $jsonData = @{
            GeneratedDate = (Get-Date).ToString('u')
            TotalDomains = $allResults.Count
            ScriptVersion = "mailchecker.ps1 v2.0"
            Results = @($allResults | ForEach-Object {
                @{
                    Domain = $_.Domain
                    OverallStatus = $_.Summary.Status
                    Checks = @{
                        MX = @{
                            Status = $_.MXResult.Status
                            Reason = $_.MXResult.Data.Reason
                            Records = @($_.MXResult.Data.MXRecords | ForEach-Object { 
                                @{ Preference = $_.Preference; NameExchange = $_.NameExchange } 
                            })
                        }
                        SPF = @{
                            Status = $_.SPFResult.Status
                            Reason = $_.SPFResult.Data.Reason
                            Records = $_.SPFResult.Data.SPFRecords
                            Healthy = $_.SPFResult.Data.Healthy
                        }
                        DKIM = @{
                            Status = $_.DKIMResult.Status
                            Reason = $_.DKIMResult.Data.Reason
                            AnyValid = $_.DKIMResult.Data.AnyValid
                        }
                        MTASTS = @{
                            Status = $_.MTAStsResult.Status
                            Reason = $_.MTAStsResult.Data.Reason
                            Enforced = $_.MTAStsResult.Data.MtaStsEnforced
                        }
                        DMARC = @{
                            Status = $_.DMARCResult.Status
                            Reason = $_.DMARCResult.Data.Reason
                            Enforced = $_.DMARCResult.Data.Enforced
                            Record = $_.DMARCResult.Data.DmarcTxt
                        }
                        TLSRPT = @{
                            Status = $_.TLSResult.Status
                            Reason = $_.TLSResult.Data.Reason
                            Record = $_.TLSResult.Data.TlsRptTxt
                        }
                    }
                }
            })
        }
        
        $jsonData | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding utf8 -Force
        # Make path clickable
        $fullPath = (Resolve-Path $jsonPath).Path
        $fileUrl = "file:///$($fullPath -replace '\\','/')"
        $esc = [char]27
        $clickableLink = "$esc]8;;$fileUrl$esc\$jsonPath$esc]8;;$esc\"
        Write-Host "JSON exported to: $clickableLink" -ForegroundColor Green
    }

    # ChatGPT analysis removed here; handled once later with banner
    
    # FullHtmlExport mode: create index + individual domain pages
    if ($FullHtmlExport) {
        # Generate individual domain pages
        Write-Host "`nGenerating individual domain reports..." -ForegroundColor Yellow
        $domainCount = 0
        foreach ($result in $allResults) {
            Write-DomainReportPage -OutputPath $outputStructure.DomainsPath `
                                 -Domain $result.Domain -Summary $result.Summary `
                           -mxResult $result.MXResult -spfResult $result.SPFResult `
                           -dkimResult $result.DKIMResult -mtaStsResult $result.MTAStsResult `
                           -dmarcResult $result.DMARCResult -tlsResult $result.TLSResult
            $domainCount++
        }
        Write-Host "Generated $domainCount domain reports in: $($outputStructure.DomainsPath)" -ForegroundColor Green
        
        # Generate activity plan if requested (before index page so we can include the button)
        $activityPlanFileName = $null
        if ($ActivityPlan -and $allResults.Count -gt 0) {
            Write-Host "`n============================================================" -ForegroundColor Cyan
            Write-Host "  Generating Activity Plan" -ForegroundColor Yellow
            Write-Host "============================================================" -ForegroundColor Cyan
            
            try {
                $rulesPath = Join-Path $PSScriptRoot 'schema/remediation-rules.json'
                $planPath = New-ActivityPlanFromResults -AllResults $allResults -RulesPath $rulesPath -OutputPath $outputStructure.RootPath
                
                # Use just the timestamped filename for the button
                if ($planPath -and (Test-Path $planPath)) {
                    $activityPlanFileName = Split-Path $planPath -Leaf
                }
            } catch {
                Write-Host "  [ERROR] Failed to generate activity plan: $_" -ForegroundColor Red
                Write-Host "         $($_.ScriptStackTrace)" -ForegroundColor Gray
            }
        }
        
        # Generate index page
        Write-IndexPage -RootPath $outputStructure.RootPath -AllResults $allResults `
                        -CsvFileName $csvFileName -JsonFileName $jsonFileName `
                        -ActivityPlanFileName $activityPlanFileName

        # ChatGPT Analysis (if requested) - run exactly once here
        if ($ChatGPT -and -not $script:__ChatGptRunCompleted) {
            Write-Host "" -NoNewline; Write-Host "============================================================" -ForegroundColor Cyan
            Write-Host "  Starting ChatGPT Analysis" -ForegroundColor Yellow
            Write-Host "============================================================" -ForegroundColor Cyan
            try {
                # Only load OpenAI-related keys here to avoid re-printing Azure creds
                Import-OpenAIEnv -EnvFilePath $EnvFile
                # Show OpenAI env (masked)
                $modelShown = if ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { '(default)' }
                Write-Host ("  [OK] OPENAI_MODEL: {0}" -f $modelShown) -ForegroundColor Green
                if ($env:OPENAI_API_KEY) {
                    $k=$env:OPENAI_API_KEY; $tail= if($k.Length -gt 6){$k.Substring($k.Length-6)}else{$k}
                    Write-Host ("  [OK] OPENAI_API_KEY: ****{0}" -f $tail) -ForegroundColor Green
                }
                # Build and call
                $analysisDir = Join-Path $outputStructure.RootPath 'analysis'
                if (-not (Test-Path $analysisDir)) { New-Item -ItemType Directory -Path $analysisDir -Force | Out-Null }
                if ([string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
                    $templatePath = Join-Path $PSScriptRoot 'templates/html/analysis-unavailable.html'
                    $failHtml = Get-Content -Path $templatePath -Raw -Encoding UTF8
                    $failHtml | Out-File -FilePath (Join-Path $analysisDir 'index.html') -Encoding utf8 -Force
                } else {
                    $modelToUse = if ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { 'gpt-4o-mini' }
                    Write-Host ("  Using model: {0}" -f $modelToUse) -ForegroundColor Gray
                    if ($ChatGPTHello) {
                        Write-Host "  Sending hello test..." -ForegroundColor Gray
                        $helloResp = Invoke-OpenAIHelloHttpClient -Model $modelToUse -TimeoutSeconds 60
                        Write-Host "  [OK] Hello response received." -ForegroundColor Green
                        $outText = $null
                        if ($helloResp -and $helloResp.output -and $helloResp.output.Count -gt 0 -and $helloResp.output[0].content -and $helloResp.output[0].content.Count -gt 0 -and $helloResp.output[0].content[0].text) {
                            $outText = $helloResp.output[0].content[0].text
                        } elseif ($helloResp -and $helloResp.output_text) {
                            $outText = $helloResp.output_text
                        } else {
                            try { $outText = ($helloResp | ConvertTo-Json -Depth 20) } catch { $outText = "(no text in response)" }
                        }
                        Write-Host ("  Model says: {0}" -f $outText) -ForegroundColor Cyan
                        $script:__ChatGptRunCompleted = $true
                        return
                    }
                    $compressed = Compress-ResultsForAI -AllResults $allResults
                    Write-Host "  Calculated Statistics:" -ForegroundColor Cyan
                    $c = $compressed.calculated
                    Write-Host ("    Domains: {0,3} total" -f $c.domain_total) -ForegroundColor Gray
                    Write-Host ("    MX:      {0,3} with MX, {1,3} send-only, {2,3} SERVFAIL" -f $c.mx.has_mx, $c.mx.no_mx, $c.mx.servfail) -ForegroundColor Gray
                    Write-Host ("    DMARC:   {0,3} missing, {1,3} fail, {2,3} warn, {3,3} pass; {4,3} pct<100, {5,3} no rua/ruf" -f $c.dmarc.missing, $c.dmarc.fail, $c.dmarc.warn, $c.dmarc.pass, $c.dmarc.pct_partial, $c.dmarc.no_reporting) -ForegroundColor Gray
                    Write-Host ("    SPF:     {0,3} missing, {1,3} fail, {2,3} warn, {3,3} pass" -f $c.spf.missing, $c.spf.fail, $c.spf.warn, $c.spf.pass) -ForegroundColor Gray
                    Write-Host ("    DKIM:    {0,3} missing, {1,3} fail, {2,3} warn, {3,3} pass, {4,3} N/A (no MX)" -f $c.dkim.missing, $c.dkim.fail, $c.dkim.warn, $c.dkim.pass, $c.dkim.na) -ForegroundColor Gray
                    Write-Host ("    MTA-STS: {0,3} missing, {1,3} fail, {2,3} warn, {3,3} pass, {4,3} N/A (no MX)" -f $c.mta_sts.missing, $c.mta_sts.fail, $c.mta_sts.warn, $c.mta_sts.pass, $c.mta_sts.na) -ForegroundColor Gray
                    Write-Host ("    TLS-RPT: {0,3} missing, {1,3} fail, {2,3} warn, {3,3} pass, {4,3} N/A (no MX)" -f $c.tls_rpt.missing, $c.tls_rpt.fail, $c.tls_rpt.warn, $c.tls_rpt.pass, $c.tls_rpt.na) -ForegroundColor Gray
                    if ($compressed.notable_deviations -and $compressed.notable_deviations.Count -gt 0) {
                      $totalWarningInstances = ($compressed.notable_deviations | ForEach-Object { $_.count } | Measure-Object -Sum).Sum
                      Write-Host ("    Notable deviations: {0} unique warning types, {1} total instances" -f $compressed.notable_deviations.Count, $totalWarningInstances) -ForegroundColor Yellow
                    }
                    # Dump input payload for transparency and debugging
                    try {
                        $payloadMdPath = Join-Path $analysisDir 'input-payload.md'
                        $payloadMd = @"
# Input Payload to AI

**Generated:** $($compressed.generated)
**Total Domains:** $($compressed.total_domains)

## Calculated Statistics

### MX Records
- **With MX:** $($c.mx.has_mx) domains
- **Send-only (no MX):** $($c.mx.no_mx) domains
- **SERVFAIL:** $($c.mx.servfail) domains

### DMARC
- **Missing:** $($c.dmarc.missing) domains
- **Fail (configuration errors):** $($c.dmarc.fail) domains
- **Warn (weak policies):** $($c.dmarc.warn) domains
- **Pass (p=reject):** $($c.dmarc.pass) domains
- **Partial coverage (pct<100):** $($c.dmarc.pct_partial) domains
- **No reporting (rua/ruf missing):** $($c.dmarc.no_reporting) domains
- **Policy distribution:**
  - p=none: $($c.dmarc.p_none) domains
  - p=quarantine: $($c.dmarc.p_quarantine) domains
  - p=reject: $($c.dmarc.p_reject) domains

### SPF
- **Missing:** $($c.spf.missing) domains
- **Fail (configuration errors):** $($c.spf.fail) domains
- **Warn (weak configuration):** $($c.spf.warn) domains
- **Pass:** $($c.spf.pass) domains

### DKIM
- **Missing:** $($c.dkim.missing) domains
- **Fail (configuration errors):** $($c.dkim.fail) domains
- **Warn:** $($c.dkim.warn) domains
- **Pass:** $($c.dkim.pass) domains
- **N/A (no MX):** $($c.dkim.na) domains

### MTA-STS
- **Missing:** $($c.mta_sts.missing) domains
- **Fail (configuration errors):** $($c.mta_sts.fail) domains
- **Warn:** $($c.mta_sts.warn) domains
- **Pass:** $($c.mta_sts.pass) domains
- **N/A (no MX):** $($c.mta_sts.na) domains

### TLS-RPT
- **Missing:** $($c.tls_rpt.missing) domains
- **Fail (configuration errors):** $($c.tls_rpt.fail) domains
- **Warn:** $($c.tls_rpt.warn) domains
- **Pass:** $($c.tls_rpt.pass) domains
- **N/A (no MX):** $($c.tls_rpt.na) domains

## Notable Deviations

"@
                        if ($compressed.notable_deviations -and $compressed.notable_deviations.Count -gt 0) {
                            $totalInstances = ($compressed.notable_deviations | ForEach-Object { $_.count } | Measure-Object -Sum).Sum
                            $payloadMd += "`n*$($compressed.notable_deviations.Count) unique warning types, $totalInstances total instances across $($compressed.total_domains) domains*`n"
                            foreach ($deviation in $compressed.notable_deviations) {
                                $msg = if ($deviation.message) { $deviation.message } else { "(empty message)" }
                                $cnt = if ($deviation.count) { $deviation.count } else { 0 }
                                $payloadMd += "`n- **$msg** ($cnt occurrences)"
                            }
                        } else {
                            $payloadMd += "`n*No notable deviations detected*"
                        }
                        $payloadMd | Out-File -FilePath $payloadMdPath -Encoding utf8 -Force
                        
                        # Also dump raw JSON payload for debugging
                        $payloadJsonPath = Join-Path $analysisDir 'input-payload.json'
                        ($compressed | ConvertTo-Json -Depth 10) | Out-File -FilePath $payloadJsonPath -Encoding utf8 -Force
                    } catch {}
                    
                    $agentPath = Join-Path $PSScriptRoot 'prompts/agent.md'
                    $schemaPath = Join-Path $PSScriptRoot 'schema/analysis.schema.json'
                    $analysisResp = Invoke-OpenAIAnalysis -Compressed $compressed -AgentPath $agentPath -SchemaPath $schemaPath -Model $modelToUse -MaxOutputTokens ([int]([int]$env:OPENAI_MAX_OUTPUT_TOKENS | ForEach-Object { if ($_ -gt 0) { $_ } else { 8000 } })) -TimeoutSeconds ([int]([int]$env:OPENAI_TIMEOUT_SECONDS | ForEach-Object { if ($_ -gt 0) { $_ } else { 60 } }))
                    # Dump full response JSON for debugging and audits
                    try {
                        $respJsonPath = Join-Path $analysisDir 'response.json'
                        ($analysisResp.raw | ConvertTo-Json -Depth 100) | Out-File -FilePath $respJsonPath -Encoding utf8 -Force
                    } catch {}
                    # Display usage statistics
                    try {
                        if ($analysisResp.raw.usage) {
                            $usage = $analysisResp.raw.usage
                            Write-Host "  Usage Summary:" -ForegroundColor Cyan
                            Write-Host ("    Input tokens:        {0,6}" -f $usage.input_tokens) -ForegroundColor Gray
                            if ($usage.input_tokens_details -and $usage.input_tokens_details.cached_tokens -gt 0) {
                                Write-Host ("    Cached tokens:       {0,6}" -f $usage.input_tokens_details.cached_tokens) -ForegroundColor Gray
                            }
                            Write-Host ("    Output tokens:       {0,6}" -f $usage.output_tokens) -ForegroundColor Gray
                            if ($usage.output_tokens_details -and $usage.output_tokens_details.reasoning_tokens -gt 0) {
                                Write-Host ("    Reasoning tokens:    {0,6}" -f $usage.output_tokens_details.reasoning_tokens) -ForegroundColor Gray
                            }
                            Write-Host ("    Total tokens:        {0,6}" -f $usage.total_tokens) -ForegroundColor Cyan
                        }
                    } catch {}
                    # Prefer parsed object if available (robust parsing handles quoted JSON)
                    $analysisText = $analysisResp.text
                    $analysisObj = $analysisResp.obj
                    if (-not $analysisObj) { 
                        try {
                            if ($PSVersionTable.PSVersion.Major -ge 7) {
                                $analysisObj = $analysisText | ConvertFrom-Json -Depth 100
                            } else {
                                $analysisObj = $analysisText | ConvertFrom-Json
                            }
                        } catch { 
                            Write-Host ("  [WARN] Failed to parse analysis JSON: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                        }
                    }
                    if ($null -eq $analysisObj) {
                        Write-Host "  [ERROR] Analysis object is null - response may be invalid or truncated" -ForegroundColor Red
                        Write-Host ("  Response text length: {0} chars" -f $analysisText.Length) -ForegroundColor Gray
                        $templatePath = Join-Path $PSScriptRoot 'templates/html/analysis-invalid.html'
                        $failHtml = Get-Content -Path $templatePath -Raw -Encoding UTF8
                        $failHtml | Out-File -FilePath (Join-Path $analysisDir 'index.html') -Encoding utf8 -Force
                        try { $textPath = Join-Path $analysisDir 'response_text.txt'; $analysisText | Out-File -FilePath $textPath -Encoding utf8 -Force } catch {}
                    } else {
                        Write-Host "  [OK] Analysis parsed successfully" -ForegroundColor Green
                        # Validate field lengths against schema
                        if ($analysisObj.report_markdown -and $analysisObj.report_markdown.Length -gt 6000) {
                            Write-Host ("  [WARN] report_markdown exceeds limit ({0} > 6000 chars)" -f $analysisObj.report_markdown.Length) -ForegroundColor Yellow
                        }
                        if ($analysisObj.summary -and $analysisObj.summary.Length -gt 900) {
                            Write-Host ("  [WARN] summary exceeds limit ({0} > 900 chars)" -f $analysisObj.summary.Length) -ForegroundColor Yellow
                        }
                        Write-Host ("  Content: summary={0} chars, findings={1}, markdown={2} chars" -f $analysisObj.summary.Length, $analysisObj.key_findings.Count, $analysisObj.report_markdown.Length) -ForegroundColor Gray
                        ($analysisText) | Out-File -FilePath (Join-Path $analysisDir 'analysis.json') -Encoding utf8 -Force
                        $templatePath = Join-Path $PSScriptRoot 'templates/html/analysis.html'
                        Write-AnalysisReport -AnalysisDir $analysisDir -TemplatePath $templatePath -AnalysisObj $analysisObj
                        # Make path clickable
                        $analysisIndexPath = Join-Path $analysisDir 'index.html'
                        $fullPath = (Resolve-Path $analysisIndexPath).Path
                        $fileUrl = "file:///$($fullPath -replace '\\','/')"
                        $esc = [char]27
                        $clickableLink = "$esc]8;;$fileUrl$esc\analysis/index.html$esc]8;;$esc\"
                        Write-Host "  [OK] ChatGPT analysis written to $clickableLink" -ForegroundColor Green
                        $script:__ChatGptRunCompleted = $true
                    }
                }
            } catch {
                Write-Host ("  [WARN] ChatGPT analysis failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                $script:__ChatGptRunCompleted = $true
            }
        }

        # If ChatGPT analysis exists, add a note
        $analysisIndex = Join-Path $outputStructure.RootPath 'analysis/index.html'
        if (Test-Path $analysisIndex) { Write-Host "AI analysis available: $analysisIndex" -ForegroundColor Cyan }
        
        # Create clickable file link for modern terminals
        $indexPath = Join-Path $outputStructure.RootPath "index.html"
        $indexPathFull = (Resolve-Path $indexPath).Path
        
        # Open report if requested
        if ($OpenReport) {
            try {
                if ($IsWindows -or $PSVersionTable.PSVersion.Major -le 5) {
                    Start-Process $indexPath
                    Write-Host "Opened report in default browser." -ForegroundColor Green
                } elseif ($IsMacOS) {
                    & open $indexPath
                    Write-Host "Opened report in default browser." -ForegroundColor Green
                } elseif ($IsLinux) {
                    & xdg-open $indexPath
                    Write-Host "Opened report in default browser." -ForegroundColor Green
                }
            } catch {
                Write-Host "Could not automatically open report: $_" -ForegroundColor Yellow
                Write-Host "Please open manually: $indexPath" -ForegroundColor Cyan
            }
        }
        
        Write-Host "`n[OK] Full HTML export complete! Click link to open:" -ForegroundColor Green
        
        # Use PSStyle.FormatHyperlink in PS 7.2+ or fallback to file:// URI
        if ($PSVersionTable.PSVersion.Major -ge 7 -and $PSVersionTable.PSVersion.Minor -ge 2) {
            # PowerShell 7.2+ has built-in hyperlink support
            $clickableLink = $PSStyle.FormatHyperlink($indexPathFull, $indexPathFull)
            Write-Host "   $clickableLink" -ForegroundColor Cyan
        } else {
            # Fallback: use file:// URI (clickable in most modern terminals)
            $fileUri = "file:///$($indexPathFull -replace '\\', '/')"
            Write-Host "   $fileUri" -ForegroundColor Cyan
        }
        
        # Azure Upload (if requested)
        if ($UploadToAzure) {
            try {
                Write-Host "`n" -NoNewline
                Write-Host "============================================================" -ForegroundColor Cyan
                Write-Host "  Starting Azure Upload Process" -ForegroundColor Yellow
                Write-Host "============================================================" -ForegroundColor Cyan
                Write-Host ""
                
                # Step 1: Load environment variables
                Import-EnvFile -EnvFilePath $EnvFile
                
                # Step 2: AzCopy availability was checked earlier; proceed directly to upload
                
                # Step 3: Generate or use provided Run ID
                Write-Host "`nGenerating Run ID..." -ForegroundColor Yellow
                $runId = New-AzureRunId -CustomRunId $AzureRunId
                
                # Step 4: Upload to Azure
                Invoke-AzureUpload -SourcePath $outputStructure.RootPath -RunId $runId
                
            } catch {
                Write-Host "`n❌ Azure upload failed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "Local report is still available at: $indexPath" -ForegroundColor Yellow
                # Don't throw - we still have a local report
            }
        }
    } else {
        # Simple HTML mode (backward compatible): single file with embedded assets
        # Ensure output directory exists
        if (-not (Test-Path $resolvedOutputPath)) {
            try {
                New-Item -ItemType Directory -Path $resolvedOutputPath -Force | Out-Null
            } catch {
                Write-Host "Error: Could not create output directory: $resolvedOutputPath" -ForegroundColor Red
                Write-Host $_.Exception.Message -ForegroundColor Red
                exit 1
            }
        }
        
        $safeDomain = $domains[0] -replace '[^a-z0-9.-]','-'
        $outPath = Join-Path $resolvedOutputPath "$safeDomain-$ts.html"
        Write-HtmlReport -Path $outPath -Domain $domains[0] -Summary $allResults[0].Summary `
                       -mxResult $allResults[0].MXResult -spfResult $allResults[0].SPFResult `
                       -dkimResult $allResults[0].DKIMResult -mtaStsResult $allResults[0].MTAStsResult `
                       -dmarcResult $allResults[0].DMARCResult -tlsResult $allResults[0].TLSResult
    }
} else {
    # No HTML output requested - just console output
    Write-Host "`nProcessing complete. Use -Html or -FullHtmlExport for HTML reports." -ForegroundColor Cyan
}

