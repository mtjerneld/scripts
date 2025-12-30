# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AzureSecurityAudit is a PowerShell module for automated Azure security posture assessments against CIS Azure Foundations Benchmark v2.0+ controls. It supports multi-subscription scanning, optional AI-powered analysis via OpenAI, and generates HTML/JSON reports.

## Commands

```powershell
# Import module
Import-Module .\AzureSecurityAudit.psd1 -Force

# Connect to Azure (interactive or via .env file)
Connect-AuditEnvironment
Connect-AuditEnvironment -EnvFile ".env"

# Run security audit
Invoke-AzureSecurityAudit                                    # Full audit, all subscriptions
Invoke-AzureSecurityAudit -Categories Storage, SQL, Network  # Specific categories
Invoke-AzureSecurityAudit -IncludeLevel2                     # Include L2 CIS controls
Invoke-AzureSecurityAudit -AI                                # Enable AI analysis
Invoke-AzureSecurityAudit -ExportJson -PassThru              # Export JSON, return result object

# Run Pester tests
Invoke-Pester -Path .\Tests\
Invoke-Pester -Path .\Tests\ConvertTo-SecurityAIInsights.Tests.ps1
```

## Architecture

### Module Structure
- **AzureSecurityAudit.psm1**: Root module that dot-sources all functions from Public/, Private/Helpers/, Private/Scanners/, Private/Config/, Private/Collectors/
- **AzureSecurityAudit.psd1**: Module manifest defining exported functions

### Key Directories
- **Public/**: Exported cmdlets (Invoke-AzureSecurityAudit, Connect-AuditEnvironment, Export-*Report, Invoke-AzureArchitectAgent)
- **Private/Scanners/**: Per-service scanner functions (Get-Azure*Findings.ps1) - each returns security findings for a resource type
- **Private/Collectors/**: Data collection functions (Advisor, RBAC, Cost, Network, ChangeTracking)
- **Private/Helpers/**: Shared utilities, AI insight converters (ConvertTo-*AIInsights.ps1), report generation
- **Config/**: ControlDefinitions.json (CIS control metadata), ResourceTypeMapping.json

### Data Flow
1. `Invoke-AzureSecurityAudit` orchestrates the scan
2. Calls scanner functions per category (Storage, AppService, VM, ARC, Monitor, Network, SQL, KeyVault)
3. Each scanner uses `New-SecurityFinding` helper to create standardized finding objects
4. Collectors gather supplementary data (Advisor recommendations, RBAC, costs, network topology)
5. `Generate-AuditReports` creates HTML reports
6. If `-AI` flag: ConvertTo-*AIInsights functions transform data, Invoke-AzureArchitectAgent calls OpenAI

### Control Definitions
- CIS controls defined in `Config/ControlDefinitions.json`
- Each control has: controlId, severity (Critical/High/Medium/Low), level (L1/L2), category, checkLogic
- L1 controls scanned by default; L2 requires `-IncludeLevel2` flag

### Finding Object Structure
Standard security finding created via `New-SecurityFinding`:
- SubscriptionId, SubscriptionName, ResourceId, ResourceName, ResourceType
- ControlId, ControlName, Category, Severity, CisLevel
- Status (PASS/FAIL/ERROR/SKIPPED), CurrentValue, ExpectedValue
- RemediationSteps

## Key Patterns

### Scanner Pattern
Each scanner in Private/Scanners/ follows:
```powershell
function Get-Azure{Service}Findings {
    param($SubscriptionId, $SubscriptionName, [switch]$IncludeLevel2)
    # Query Azure resources
    # For each resource, check controls
    # Return array of findings via New-SecurityFinding
}
```

### AI Integration
- AI insights use ConvertTo-*AIInsights helpers to prepare JSON payloads
- Invoke-AzureArchitectAgent sends combined payload to OpenAI
- API key via `OPENAI_API_KEY` env var or `-OpenAIKey` parameter

### Authentication
Service principal credentials can be stored in `.env` file:
```
AZURE_TENANT_ID=...
AZURE_CLIENT_ID=...
AZURE_CLIENT_SECRET=...
```

### Key rules
We never write or change anything in the Azure- or EntraID tenants. We only ever read. It is fundamentally important that this tool never make any changes in the audit environment. 

## Testing
Tests use Pester framework. Test files in `Tests/` directory follow `*.Tests.ps1` naming. Tests import functions directly via dot-sourcing rather than importing the full module.
