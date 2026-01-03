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
- **AzureSecurityAudit.psm1**: Root module that dot-sources all functions from Public/, Private/Helpers/, Private/Scanners/, Private/Collectors/
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

## Development Workflow

**Claude Code** - Arkitekt och senior utvecklare:
- Designar nya lösningar och arkitektur
- Code review och kvalitetssäkring
- Problemlösning vid komplexa buggar
- Kommunicerar via MD-filer (FIXPLAN-*.md, DESIGN-*.md, etc.)

**Cursor** - Team av juniorutvecklare:
- Skriver majoriteten av koden
- Implementerar enligt specifikationer i MD-filer
- Kör tester och rapporterar resultat

**Arbetsflöde:**
1. Claude analyserar problem/feature → skriver spec i MD-fil
2. Cursor implementerar enligt spec
3. Claude gör review, identifierar issues → uppdaterar MD-fil
4. Iteration tills klart

## Writing FIXPLAN Files

When creating FIXPLAN-*.md files or feature specs for Cursor, **always include the standard Cursor Instructions header** at the top of the file.

### Standard Cursor Instructions Header

Every FIXPLAN or feature spec MUST start with:

```markdown
## Instructions for Cursor

### Status Management
- Du får ENDAST sätta status till `[IN PROGRESS]` eller `[READY FOR REVIEW]`
- Du får ALDRIG markera issues som `[FIXED]` - endast Claude får göra detta efter review
- Du får ALDRIG skapa nya issues - rapportera problem till Claude istället

### When Done with an Issue
Ändra rubriken och lägg till status:
\`\`\`
## Issue N: Title [READY FOR REVIEW]
**Status:** Ready for review - implemented in commit abc123
\`\`\`

### Status Flow
\`\`\`
[NEW] → [IN PROGRESS] → [READY FOR REVIEW] → [FIXED]
                                              ↓
                                    Status: Verified by Claude
\`\`\`

---
```

### Issue Format

Be concise and descriptive rather than writing full code:

**Include:**
- **What** - Problem symptoms and root cause
- **Where** - File path and approximate line numbers
- **Why** - Explain the flawed logic
- **How** - Describe the fix approach (not full implementation)
- **Test** - How to verify the fix works

**Avoid:**
- Full code blocks (if you have the complete code, just edit directly)
- Redundant explanations

**Example:**
```
## Issue N: Brief Title

**Problem:** Filter uses INTERSECTION instead of UNION
**Where:** `filterRawDailyDataBySelections`, lines ~2044-2046
**Current logic:** Early return skips unselected subscriptions entirely
**Fix:** Remove early return, use UNION condition at category level
**Test:** Ctrl+click Sub-1 + Storage → should show Sub-1 fully + Storage from all subs
```
