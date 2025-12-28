# Azure Security Audit Tool v1.0

PowerShell module for automated Azure security posture assessments across multiple subscriptions. Scans Azure resources against CIS Azure Foundations Benchmark v2.0 controls with focus on TLS enforcement, encryption, network security, and deprecated component detection.

## Features

- **Multi-Subscription Scanning**: Automatically scans all enabled subscriptions or specific subscriptions
- **CIS Level 1 (L1) Controls**: Essential security controls applicable to all environments
- **CIS Level 2 (L2) Controls**: Optional controls for critical data or high-security environments
- **Deprecated Component Detection**: Identifies 12 deprecated/EOL components with migration deadlines
- **HTML Report Generation**: Professional HTML reports with executive summary, charts, and detailed findings
- **JSON Export**: Optional JSON export for integration with other tools
- **Remediation Guidance**: Includes CLI/PowerShell commands for fixing issues

## Supported Service Categories

1. **Storage Accounts** - 7 Level 1 controls + 3 Level 2 controls (TLS, HTTPS, public access, encryption, CMK, etc.)
2. **App Services** - 9 controls (TLS, HTTPS, FTP, authentication, managed identity)
3. **Virtual Machines** - 8 controls (managed disks, Defender, AMA agent, encryption)
4. **Azure ARC** - 5 controls (agent version, connection status, AMA extension)
5. **Azure Monitor** - 4 controls (MMA detection, diagnostic settings, DCR associations)
6. **Networking** - 8 controls (NSG rules, Network Watcher, DDoS, Azure Firewall)
7. **SQL Databases** - 10 controls (TLS, firewall rules, auditing, TDE, Defender)

## Installation

### Prerequisites

- PowerShell 5.1 or later
- Azure PowerShell modules (Az.*)

### Install Required Modules

```powershell
# Install Azure PowerShell modules
Install-Module Az -Force -AllowClobber

# Or install individual Az modules
Install-Module Az.Accounts, Az.Resources, Az.Storage, Az.Websites, Az.Compute, Az.Sql, Az.Network, Az.Monitor, Az.ConnectedMachine -Force
```

### Install Module

```powershell
# Clone or download the module
# Navigate to the module directory
cd D:\Dev\scripts\AzureInventory

# Import the module
Import-Module .\AzureSecurityAudit.psd1 -Force
```

## Authentication

The tool supports multiple authentication methods:

### 1. Interactive Authentication (Default)

```powershell
# Simple interactive login
Connect-AuditEnvironment
```

### 2. Service Principal with .env File (Recommended for Automation)

Create a `.env` file in the module directory:

```env
# Entra ID (formerly Azure AD) Tenant ID - find it in Azure Portal > Entra ID > Overview
AZURE_TENANT_ID=your-entra-id-tenant-id-here

# Service Principal Application (Client) ID
AZURE_CLIENT_ID=your-client-id-here

# Service Principal Client Secret
AZURE_CLIENT_SECRET=your-client-secret-here
```

Then connect:

```powershell
Connect-AuditEnvironment -EnvFile ".env"
```

**Create Service Principal:**

```powershell
# Create Service Principal with Reader role
# This will output: appId (Client ID), password (Client Secret), tenant (Tenant ID)
az ad sp create-for-rbac --name "AzureSecurityAudit" --role "Reader" --scopes /subscriptions/{subscriptionId}

# The output will show:
# {
#   "appId": "xxxx-xxxx-xxxx",        # This is AZURE_CLIENT_ID
#   "password": "xxxx-xxxx-xxxx",     # This is AZURE_CLIENT_SECRET
#   "tenant": "xxxx-xxxx-xxxx"        # This is AZURE_TENANT_ID (Entra ID Tenant ID)
# }

# Or assign at Management Group level for tenant-wide access
az ad sp create-for-rbac --name "AzureSecurityAudit" --role "Reader"
New-AzRoleAssignment -ObjectId <sp-object-id> -RoleDefinitionName "Reader" -Scope "/providers/Microsoft.Management/managementGroups/{rootMgId}"
New-AzRoleAssignment -ObjectId <sp-object-id> -RoleDefinitionName "Security Reader" -Scope "/providers/Microsoft.Management/managementGroups/{rootMgId}"
```

### 3. Service Principal with Parameters

```powershell
Connect-AuditEnvironment -TenantId "tenant-id" -ApplicationId "app-id" -ClientSecret "secret"
```

### 4. Managed Identity (for Azure VMs/ARC)

```powershell
Connect-AuditEnvironment -UseManagedIdentity
```

## Usage

### Basic Usage

```powershell
# Connect to Azure (interactive or via .env)
Connect-AuditEnvironment

# Run full audit across all enabled subscriptions
Invoke-AzureSecurityAudit

# Run audit for specific categories
Invoke-AzureSecurityAudit -Categories Storage, SQL, Network

# Run audit for specific subscriptions
Invoke-AzureSecurityAudit -SubscriptionIds "sub-123", "sub-456"

# Export JSON in addition to HTML
Invoke-AzureSecurityAudit -ExportJson

# Get result object for further processing
$result = Invoke-AzureSecurityAudit -PassThru
```

### Advanced Usage

```powershell
# Custom output path
Invoke-AzureSecurityAudit -OutputPath ".\Reports\SecurityAudit_2025.html"

# Scan specific categories with JSON export
Invoke-AzureSecurityAudit -Categories Storage, SQL -ExportJson -OutputPath ".\audit.html"

## AI-Powered Analysis

The module includes optional AI-powered analysis using OpenAI to provide strategic recommendations and prioritization across your customer portfolio.

### Prerequisites

- OpenAI API key (set via `OPENAI_API_KEY` environment variable or `-OpenAIKey` parameter)
- OpenAI API access (gpt-4o-mini or gpt-5-mini recommended for cost efficiency)

### Basic AI Analysis

```powershell
# Run audit with AI analysis enabled
Invoke-AzureSecurityAudit -AI

# With custom OpenAI model
Invoke-AzureSecurityAudit -AI -OpenAIModel "gpt-4o-mini"

# With custom API key
Invoke-AzureSecurityAudit -AI -OpenAIKey "sk-..."
```

### AI Analysis Parameters

```powershell
Invoke-AzureSecurityAudit `
    -AI `
    -OpenAIKey $env:OPENAI_API_KEY `
    -OpenAIModel "gpt-4o-mini" `
    -AICostTopN 15 `          # Top N cost opportunities to analyze
    -AISecurityTopN 20         # Top N security findings to analyze
```

### AI Output Files

When `-AI` is enabled, the following files are generated in the output folder:

- `AI_Analysis_YYYY-MM-DD_HHmmss.txt` - Full AI analysis report with recommendations
- `AI_Metadata_YYYY-MM-DD_HHmmss.json` - Token usage, cost, and metadata
- `AI_Insights_Payload_YYYY-MM-DD_HHmmss.json` - Combined governance data sent to AI

### AI Analysis Content

The AI analysis includes:

1. **Executive Summary** - Top critical issues and portfolio health
2. **Strategic Priorities** - Top 5 ranked actions with business impact
3. **Cost Optimization Roadmap** - Quick wins, medium-term, and strategic projects
4. **Security & Compliance Actions** - Immediate escalations and remediation priorities
5. **Infrastructure Modernization** - EOL remediation and technical debt
6. **Cross-Cutting Insights** - Portfolio patterns and proactive recommendations

### Cost Considerations

- Typical analysis: ~$0.10-0.50 per run (depends on portfolio size)
- Token usage: ~20-40K input tokens, ~3-8K output tokens
- Cost scales with number of subscriptions and findings

### Standalone AI Agent

You can also call the AI agent directly with pre-generated insights:

```powershell
# Generate insights separately
$costInsights = ConvertTo-CostAIInsights -AdvisorRecommendations $recs
$secInsights = ConvertTo-SecurityAIInsights -Findings $findings

# Combine and analyze
$payload = ConvertTo-CombinedPayload -CostInsights $costInsights -SecurityInsights $secInsights -SubscriptionCount 30
$json = $payload | ConvertTo-Json -Depth 10

$analysis = Invoke-AzureArchitectAgent -GovernanceDataJson $json -ApiKey $env:OPENAI_API_KEY
```

# Include Level 2 controls (for critical data or high-security environments)
Invoke-AzureSecurityAudit -Categories Storage -IncludeLevel2

# Level 2 with specific critical storage accounts (for CMK control 3.12)
Invoke-AzureSecurityAudit -Categories Storage -IncludeLevel2 -CriticalStorageAccounts "critical-storage-1", "critical-storage-2"
```

## CIS Level 1 vs Level 2 Controls

### Level 1 (L1) Controls
**Level 1 controls are essential security controls that should be applied to all systems without significant functional impact.**

These controls provide a baseline level of security and are applicable to all environments:
- Minimum TLS Version 1.2
- Secure Transfer Required (HTTPS only)
- Public Blob Access Disabled
- Default Network Action Deny
- And more...

**By default, the tool scans only Level 1 controls.**

### Level 2 (L2) Controls
**Level 2 controls are recommended for environments that handle critical data or require enhanced security.**

These controls may have some functional impact or require additional administrative overhead:
- **Infrastructure Encryption (3.2)**: Double encryption at storage service level
- **Customer-Managed Keys (3.12)**: Enhanced key control using Azure Key Vault (for critical data only)
- **Azure Services Bypass (3.9)**: Network rule bypass for trusted Azure services

**Level 2 controls are only scanned when using the `-IncludeLevel2` parameter.**

> **Important**: According to CIS documentation, Level 2 controls like CMK (3.12) are **not applicable to all storage accounts** - they should only be applied to accounts storing critical data. Use the `-CriticalStorageAccounts` parameter to specify which accounts require Level 2 controls.

## Required RBAC Permissions

The service principal or user account needs the following roles at subscription or management group level:

- **Reader** - Read access to all resources
- **Security Reader** - Read security settings
- **Storage Account Key Operator Service Role** - For storage encryption checks (optional)
- **SQL Security Manager** - For SQL security features (optional)

### Recommended Setup

```powershell
# Assign Reader role at Management Group level for tenant-wide access
New-AzRoleAssignment -ObjectId <servicePrincipalId> -RoleDefinitionName "Reader" -Scope "/providers/Microsoft.Management/managementGroups/{rootMgId}"
New-AzRoleAssignment -ObjectId <servicePrincipalId> -RoleDefinitionName "Security Reader" -Scope "/providers/Microsoft.Management/managementGroups/{rootMgId}"
```

## Report Structure

The HTML report includes:

1. **Executive Summary**
   - KPI cards for Critical/High/Medium/Low findings
   - Pie chart: Findings by Category
   - Bar chart: Findings by Severity

2. **Deprecated Components Alert**
   - Highlighted section for EOL components
   - Past-due dates shown in red
   - Action required guidance

3. **Detailed Findings Table**
   - Sortable/filterable table with all findings
   - Color-coded by severity
   - Export buttons (Excel, CSV, PDF)

4. **Subscription Details**
   - Accordion sections per subscription
   - Findings grouped by subscription

5. **Remediation Guidance**
   - Grouped by control
   - CLI/PowerShell commands for each finding

## Critical Deprecations Detected

The tool flags the following deprecated components:

| Component | Status | Deadline | Severity |
|-----------|--------|----------|----------|
| Log Analytics Agent (MMA) | RETIRED | Aug 31, 2024 | Critical |
| TLS 1.0/1.1 (General) | Deprecated | Aug 31, 2025 | Critical |
| Azure Storage TLS 1.0/1.1 | Deprecated | Feb 3, 2026 | Critical |
| GPv1/BlobStorage Accounts | Deprecated | Oct 13, 2026 | Medium |
| Azure Disk Encryption | Retiring | Sep 15, 2028 | Medium |
| Dependency Agent | Retiring | Jun 30, 2028 | Medium |

## Example Output

```
Starting Azure Security Audit across 3 subscription(s)...

[1/3] Scanning: Production (sub-123)
  - Storage... 45 checks (12 failures)
  - SQL... 28 checks (5 failures)
  - Network... 32 checks (8 failures)
  - VM... 15 checks (3 failures)

[2/3] Scanning: Development (sub-456)
  - Storage... 12 checks (2 failures)
  - SQL... 8 checks (1 failures)

=== Scan Summary ===
Total Findings: 150
  Critical: 8
  High:     15
  Medium:   22
  Low:      5

HTML Report: .\AzureSecurityAudit_20250106_143022.html
```

## Troubleshooting

### Module Import Errors

```powershell
# Check if module is in PSModulePath
$env:PSModulePath

# Import with full path
Import-Module "D:\Dev\scripts\AzureInventory\AzureSecurityAudit.psd1" -Force
```

### Missing Permissions

```powershell
# Verify current context
Get-AzContext

# Check role assignments
Get-AzRoleAssignment -SignInName <your-email>
```

### API Rate Limiting

The module includes automatic retry logic with exponential backoff for rate limiting (HTTP 429) and transient errors (HTTP 503).


## Module Structure

```
AzureInventory/
├── AzureSecurityAudit.psd1          # Module manifest
├── AzureSecurityAudit.psm1          # Root module
├── Public/                           # Exported cmdlets
│   ├── Invoke-AzureSecurityAudit.ps1
│   ├── Export-SecurityReport.ps1
│   └── Connect-AuditEnvironment.ps1
├── Private/                          # Internal functions
│   ├── Scanners/                    # Scanner functions
│   ├── Helpers/                     # Helper functions
│   └── Config/                      # Config loaders
├── Config/                           # Configuration files
│   ├── ControlDefinitions.json
│   └── EOLFallback/                 # Fallback EOL data from Microsoft
└── Templates/                        # HTML templates (optional)
    └── assets/
```

## Contributing

This is an internal tool. For issues or enhancements, contact the development team.

## License

Internal use only.

## Version History

- **v1.0.0** (2025-01-06)
  - Initial release
  - P0 and P1 CIS controls
  - Multi-subscription scanning
  - HTML report generation
  - Deprecated component detection

## References

- [CIS Azure Foundations Benchmark v2.0](https://www.cisecurity.org/benchmark/azure)
- [Azure Security Best Practices](https://docs.microsoft.com/azure/security/)
- [Azure Deprecation Announcements](https://azure.microsoft.com/updates/)

