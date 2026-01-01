# Claude Skills Implementation Guide

This document provides detailed instructions for implementing a Claude API-based multi-agent analysis system alongside the existing OpenAI implementation.

## Overview

### Current State
- `Invoke-OpenAIAnalysis.ps1` - Calls OpenAI API with combined governance payload
- `Invoke-AzureArchitectAgent.ps1` - Orchestrates the AI analysis
- Single monolithic AI call handling all 8 domains

### Target State
- `Invoke-ClaudeAnalysis.ps1` - Claude API integration (parallel to OpenAI)
- 5 domain expert agents running in parallel
- 1 orchestrator agent synthesizing expert outputs
- Provider-agnostic architecture (`-Provider OpenAI|Claude`)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    AzureArchitect                           │
│                   (Opus 4.5 - Synthesis)                    │
└──────────────────────────┬──────────────────────────────────┘
                           │
   ┌───────────┬───────────┼───────────┬───────────┐
   ▼           ▼           ▼           ▼           ▼
┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌─────────┐
│Security│ │  Cost  │ │  RBAC  │ │  Ops   │ │ Network │
│ Expert │ │ Expert │ │ Expert │ │ Expert │ │ Expert  │
└────────┘ └────────┘ └────────┘ └────────┘ └─────────┘
```

### Data Routing
Cross-cutting data sources (Advisor, Change Tracking) are filtered and routed to relevant experts:

| Expert | Primary Data | Advisor Categories | Change Types |
|--------|--------------|-------------------|--------------|
| Security | CIS Findings | Security | IAM, NSG, firewall, encryption |
| Cost | Cost Tracking | Cost | Resource create/delete |
| RBAC | RBAC Governance | (none) | Role assignments, group membership |
| Operations | VM Backup, EOL | Reliability, OpEx, Performance | Config, scaling |
| Network | Network Inventory | Performance | NSG rules, peering, routing |

---

## File Structure

Create these new files:

```
Private/
├── Helpers/
│   ├── Invoke-ClaudeAnalysis.ps1      # Claude API wrapper
│   ├── Split-AdvisorByCategory.ps1    # Route Advisor data
│   ├── Split-ChangesByDomain.ps1      # Route Change data
│   └── Invoke-DomainExpert.ps1        # Generic expert invoker
│
Config/
├── Prompts/
│   ├── Experts/
│   │   ├── SecurityExpert.txt
│   │   ├── CostExpert.txt
│   │   ├── RBACExpert.txt
│   │   ├── OperationsExpert.txt
│   │   └── NetworkExpert.txt
│   └── OrchestratorPrompt.txt         # Synthesis-focused (replaces monolithic)
```

---

## Implementation Steps

### Step 1: Create Invoke-ClaudeAnalysis.ps1

Location: `Private/Helpers/Invoke-ClaudeAnalysis.ps1`

This mirrors `Invoke-OpenAIAnalysis.ps1` but for Claude API.

#### Key Differences from OpenAI:

| Aspect | OpenAI | Claude |
|--------|--------|--------|
| Endpoint | `api.openai.com/v1/responses` | `api.anthropic.com/v1/messages` |
| Auth Header | `Authorization: Bearer $key` | `x-api-key: $key` + `anthropic-version: 2023-06-01` |
| Request Body | `input` array with roles | `messages` array with roles |
| System Prompt | In `input` array | Separate `system` field |
| Response Path | `output[].content[].text` | `content[].text` |
| Token Usage | `usage.input_tokens` | `usage.input_tokens` |

#### Function Signature:

```powershell
function Invoke-ClaudeAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SystemPrompt,

        [Parameter(Mandatory = $true)]
        [string]$UserPrompt,

        [Parameter(Mandatory = $false)]
        [string]$ApiKey = $env:ANTHROPIC_API_KEY,

        [Parameter(Mandatory = $false)]
        [ValidateSet('claude-opus-4-5-20250514', 'claude-sonnet-4-20250514', 'claude-haiku-3-5-20241022')]
        [string]$Model = 'claude-sonnet-4-20250514',

        [Parameter(Mandatory = $false)]
        [int]$MaxTokens = 8192,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 120,

        [Parameter(Mandatory = $false)]
        [double]$MaxCostPerRun = 0.50
    )
```

#### Environment Variables:

```
ANTHROPIC_API_KEY          # Required - Claude API key
ANTHROPIC_MODEL            # Optional - Override default model
ANTHROPIC_MAX_TOKENS       # Optional - Max output tokens (default: 8192)
ANTHROPIC_TIMEOUT_SECONDS  # Optional - Request timeout (default: 120)
ANTHROPIC_MAX_COST_USD     # Optional - Cost cap per run (default: 0.50)
```

#### Claude API Pricing (per 1M tokens):

| Model | Input | Output |
|-------|-------|--------|
| claude-opus-4-5-20250514 | $15.00 | $75.00 |
| claude-sonnet-4-20250514 | $3.00 | $15.00 |
| claude-haiku-3-5-20241022 | $0.80 | $4.00 |

#### Request Body Structure:

```json
{
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 8192,
    "system": "You are a security expert...",
    "messages": [
        {
            "role": "user",
            "content": "Analyze this data: {...}"
        }
    ]
}
```

#### Response Structure:

```json
{
    "id": "msg_...",
    "type": "message",
    "role": "assistant",
    "content": [
        {
            "type": "text",
            "text": "Analysis results..."
        }
    ],
    "stop_reason": "end_turn",
    "usage": {
        "input_tokens": 1234,
        "output_tokens": 567
    }
}
```

#### Return Object (match OpenAI pattern):

```powershell
[PSCustomObject]@{
    Success        = $true
    Raw            = $responseJson
    Text           = $extractedText
    InputTokens    = $usage.input_tokens
    OutputTokens   = $usage.output_tokens
    InputCost      = $calculatedInputCost
    OutputCost     = $calculatedOutputCost
    EstimatedCost  = $totalCost
    Model          = $modelUsed
    Truncated      = ($stopReason -eq 'max_tokens')
}
```

---

### Step 2: Create Data Router Functions

#### Split-AdvisorByCategory.ps1

```powershell
function Split-AdvisorByCategory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$AdvisorRecommendations
    )

    @{
        Security    = $AdvisorRecommendations | Where-Object { $_.Category -eq 'Security' }
        Cost        = $AdvisorRecommendations | Where-Object { $_.Category -eq 'Cost' }
        Reliability = $AdvisorRecommendations | Where-Object { $_.Category -eq 'Reliability' }
        OpEx        = $AdvisorRecommendations | Where-Object { $_.Category -eq 'OperationalExcellence' }
        Performance = $AdvisorRecommendations | Where-Object { $_.Category -eq 'Performance' }
    }
}
```

#### Split-ChangesByDomain.ps1

```powershell
function Split-ChangesByDomain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$ChangeTracking
    )

    # Define resource type patterns for each domain
    $securityPatterns = 'Microsoft\.Network/networkSecurityGroups|Microsoft\.KeyVault|Microsoft\.Authorization|firewall|identity'
    $costPatterns = 'Create|Delete'  # Operations, not resource types
    $rbacPatterns = 'Microsoft\.Authorization/roleAssignments|Microsoft\.AAD'
    $opsPatterns = 'Microsoft\.Compute|Microsoft\.RecoveryServices|config'
    $networkPatterns = 'Microsoft\.Network'

    @{
        Security   = $ChangeTracking | Where-Object {
            $_.ResourceType -match $securityPatterns -or
            $_.OperationName -match 'security|firewall|nsg|vault'
        }
        Cost       = $ChangeTracking | Where-Object {
            $_.OperationName -match $costPatterns
        }
        RBAC       = $ChangeTracking | Where-Object {
            $_.ResourceType -match $rbacPatterns
        }
        Operations = $ChangeTracking | Where-Object {
            $_.ResourceType -match $opsPatterns
        }
        Network    = $ChangeTracking | Where-Object {
            $_.ResourceType -match $networkPatterns
        }
    }
}
```

---

### Step 3: Create Expert Prompt Files

Location: `Config/Prompts/Experts/`

#### SecurityExpert.txt

```
You are an Azure Security Expert specializing in CIS Azure Foundations Benchmark compliance and cloud security posture assessment.

## Your Expertise
- CIS control prioritization by exploitability, not just severity labels
- Attack chain analysis (which failures enable lateral movement)
- Compliance vs actual risk distinction
- Remediation sequencing (quick wins vs architectural changes)

## Your Data Sources
You will receive:
1. CIS Findings - Security control violations with severity ratings
2. Advisor Security Recommendations - Azure's security suggestions
3. Security-Relevant Changes - Recent IAM, NSG, firewall, encryption changes

## Your Task
Analyze the security posture and provide:
1. **Critical Exposures** - What can be exploited NOW (not theoretical risks)
2. **Attack Surface Assessment** - Public exposure, lateral movement paths
3. **Prioritized Remediation** - Ordered by (Exploitability × Impact), not severity label
4. **Quick Wins** - High-impact, low-effort fixes

## Rules
- Focus ONLY on security. Do not discuss cost optimization or operational issues.
- Distinguish between "compliance checkbox" issues and "real attack vectors"
- Be specific: name resources, subscriptions, and exact misconfigurations
- Provide remediation commands where applicable (Azure CLI/PowerShell)
```

#### CostExpert.txt

```
You are an Azure FinOps Expert specializing in cloud cost optimization and financial governance.

## Critical Knowledge
- Reserved Instances and Savings Plans are MUTUALLY EXCLUSIVE - never recommend both for the same workload
- Always deduplicate overlapping recommendations
- Consider commitment risk (1yr vs 3yr, utilization uncertainty)
- Distinguish "stop bleeding" (immediate waste) vs "optimization" (efficiency improvements)

## Your Data Sources
You will receive:
1. Cost Tracking Data - Current spend patterns
2. Advisor Cost Recommendations - Azure's cost suggestions with savings estimates
3. Resource Changes - Recent creates/deletes affecting cost

## Your Task
Analyze cost optimization opportunities and provide:
1. **Immediate Savings** - Waste that can be stopped today (orphaned resources, oversized VMs)
2. **Commitment Opportunities** - RI/Savings Plan recommendations with ROI analysis
3. **Right-Sizing** - Specific resize recommendations with projected savings
4. **Cost Anomalies** - Unusual spend patterns or unexpected growth

## Rules
- Focus ONLY on cost. Do not discuss security or compliance.
- Always show: Current Cost → Recommended Action → Projected Savings
- Consider implementation complexity (1=easy, 5=complex)
- Flag recommendations that require workload analysis before commitment
- Deduplicate: If RI and Savings Plan both appear for same workload, recommend ONE with reasoning
```

#### RBACExpert.txt

```
You are an Azure Identity & Access Management Expert specializing in RBAC governance and zero-trust principles.

## Your Expertise
- Privilege creep identification
- Blast radius assessment (what damage could compromised identity cause?)
- Role redundancy and overlap analysis
- Stale access detection

## Your Data Sources
You will receive:
1. RBAC Governance Data - Role assignments, risk levels, scope analysis
2. RBAC-Related Changes - Recent role assignments, group membership changes

## Your Task
Analyze identity governance and provide:
1. **Over-Privileged Accounts** - Identities with excessive permissions
2. **Blast Radius Assessment** - High-risk accounts ranked by potential damage
3. **Stale Access** - Permissions that should be revoked
4. **Role Consolidation** - Redundant or overlapping assignments

## Rules
- Focus ONLY on identity and access. Do not discuss other domains.
- Flag any Owner/Contributor at subscription or management group scope
- Identify service principals with excessive permissions
- Check for direct user assignments vs group-based (prefer groups)
- Highlight external identities with privileged access
```

#### OperationsExpert.txt

```
You are an Azure Operations Expert specializing in infrastructure reliability, backup, and lifecycle management.

## Your Expertise
- Backup coverage and RPO/RTO analysis
- End-of-life planning and upgrade sequencing
- Configuration drift detection
- Operational resilience assessment

## Your Data Sources
You will receive:
1. VM Backup Data - Backup coverage, health, policies
2. EOL Data - Resources approaching end-of-life with urgency tiers
3. Advisor Recommendations - Reliability, Operational Excellence, Performance
4. Configuration Changes - Recent config modifications, scaling events

## Your Task
Analyze operational health and provide:
1. **Backup Gaps** - Production workloads without adequate backup
2. **EOL Urgency** - Resources requiring immediate attention (<30 days), planning (<90 days)
3. **Reliability Risks** - Single points of failure, missing redundancy
4. **Configuration Drift** - Unexpected changes requiring review

## Rules
- Focus ONLY on operations. Do not discuss security or cost.
- Prioritize production workloads over dev/test
- For EOL: Provide specific upgrade paths, not just "upgrade needed"
- Flag backup policy gaps (e.g., daily backup but 30-day retention for critical data)
```

#### NetworkExpert.txt

```
You are an Azure Network Expert specializing in network architecture, security, and connectivity.

## Your Expertise
- Network topology analysis (hub-spoke, mesh, hybrid)
- NSG rule effectiveness and gaps
- Connectivity health (peering, ExpressRoute, VPN)
- Network exposure assessment

## Your Data Sources
You will receive:
1. Network Inventory - VNets, subnets, NSGs, peerings, gateways
2. Advisor Performance Recommendations - Latency, throughput issues
3. Network Changes - NSG rule modifications, peering changes, routing updates

## Your Task
Analyze network architecture and provide:
1. **Exposure Assessment** - Public endpoints, missing private endpoints
2. **NSG Analysis** - Overly permissive rules, missing deny rules
3. **Connectivity Gaps** - Missing peerings, routing issues, DNS problems
4. **Architecture Recommendations** - Topology improvements

## Rules
- Focus ONLY on networking. Security aspects of NSGs go to Security Expert.
- Identify resources that should use Private Endpoints but don't
- Flag any 0.0.0.0/0 or * rules in NSGs
- Check for orphaned network resources (unused NICs, IPs, NSGs)
- Assess ExpressRoute/VPN health if present
```

---

### Step 4: Create Orchestrator Prompt

Location: `Config/Prompts/OrchestratorPrompt.txt`

```
You are the Azure Architect, a senior cloud governance expert who synthesizes analysis from domain specialists into actionable executive guidance.

## Your Role
You do NOT perform raw analysis. You receive pre-analyzed insights from 5 domain experts:
1. Security Expert - CIS compliance, attack surface, vulnerabilities
2. Cost Expert - Optimization opportunities, waste identification
3. RBAC Expert - Identity governance, privilege analysis
4. Operations Expert - Backup, EOL, reliability
5. Network Expert - Topology, connectivity, NSG analysis

## Your Task
Synthesize expert analyses into a unified governance report:

### 1. Executive Summary (5 bullets max)
- One critical item from each domain that leadership must know
- Use business language, not technical jargon

### 2. Cross-Domain Insights
Identify compounding risks that span domains:
- Security + RBAC: Over-privileged accounts on exposed resources
- Cost + Operations: EOL resources still incurring significant spend
- Network + Security: Public exposure combined with NSG gaps
- Operations + Cost: Unbackup resources that would be expensive to recreate

### 3. Prioritized Action Plan (7 items max)
Rank by: (Risk × Business Impact) / (Effort + Complexity)

For each action:
- Domain tag: [SECURITY], [COST], [RBAC], [OPS], [NETWORK]
- Specific action with resource names
- Business justification
- Effort estimate: Quick Win / Moderate / Significant

### 4. Deferred Items
What was intentionally NOT prioritized and why (transparency)

## Rules
- Do NOT repeat expert analysis verbatim - synthesize and prioritize
- Focus on cross-domain patterns experts couldn't see individually
- Challenge expert recommendations if they conflict
- Be opinionated: "You SHOULD do X" not "You COULD consider X"
- Include specific resource names, subscription context
```

---

### Step 5: Create Invoke-DomainExpert.ps1

Location: `Private/Helpers/Invoke-DomainExpert.ps1`

```powershell
function Invoke-DomainExpert {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Security', 'Cost', 'RBAC', 'Operations', 'Network')]
        [string]$ExpertType,

        [Parameter(Mandatory = $true)]
        [hashtable]$DomainData,

        [Parameter(Mandatory = $false)]
        [ValidateSet('OpenAI', 'Claude')]
        [string]$Provider = 'Claude',

        [Parameter(Mandatory = $false)]
        [string]$ApiKey,

        [Parameter(Mandatory = $false)]
        [string]$Model  # If not specified, uses default for provider
    )

    # Load expert prompt
    $promptPath = Join-Path $PSScriptRoot "..\..\Config\Prompts\Experts\$($ExpertType)Expert.txt"
    if (-not (Test-Path $promptPath)) {
        throw "Expert prompt not found: $promptPath"
    }
    $systemPrompt = Get-Content $promptPath -Raw

    # Build user prompt with domain data
    $userPrompt = @"
Analyze the following $ExpertType data for Azure governance assessment:

```json
$($DomainData | ConvertTo-Json -Depth 10)
```

Provide your expert analysis following the guidelines in your system prompt.
"@

    # Call appropriate provider
    if ($Provider -eq 'Claude') {
        $params = @{
            SystemPrompt = $systemPrompt
            UserPrompt   = $userPrompt
            Model        = if ($Model) { $Model } else { 'claude-sonnet-4-20250514' }
        }
        if ($ApiKey) { $params.ApiKey = $ApiKey }

        Invoke-ClaudeAnalysis @params
    }
    else {
        $params = @{
            SystemPrompt = $systemPrompt
            UserPrompt   = $userPrompt
            OutputFormat = 'markdown'
            Model        = if ($Model) { $Model } else { 'gpt-4o-mini' }
        }
        if ($ApiKey) { $params.ApiKey = $ApiKey }

        Invoke-OpenAIAnalysis @params
    }
}
```

---

### Step 6: Update Invoke-AzureArchitectAgent.ps1

Add provider selection and multi-expert orchestration:

```powershell
# Add parameter
[Parameter(Mandatory = $false)]
[ValidateSet('OpenAI', 'Claude', 'Claude-MultiExpert')]
[string]$Provider = 'OpenAI'

# In the function body, add logic for Claude-MultiExpert mode:
if ($Provider -eq 'Claude-MultiExpert') {
    # 1. Split cross-cutting data
    $advisorByCategory = Split-AdvisorByCategory -AdvisorRecommendations $advisorData
    $changesByDomain = Split-ChangesByDomain -ChangeTracking $changeData

    # 2. Build domain-specific payloads
    $securityPayload = @{
        CISFindings = $securityInsights
        AdvisorSecurity = $advisorByCategory.Security
        SecurityChanges = $changesByDomain.Security
    }
    # ... similar for other domains

    # 3. Run experts in parallel (PowerShell 7+ with ForEach-Object -Parallel, or sequential fallback)
    $expertResults = @{}
    $experts = @('Security', 'Cost', 'RBAC', 'Operations', 'Network')

    foreach ($expert in $experts) {
        Write-Host "Running $expert Expert..." -ForegroundColor Cyan
        $payload = Get-Variable -Name "$($expert.ToLower())Payload" -ValueOnly
        $expertResults[$expert] = Invoke-DomainExpert -ExpertType $expert -DomainData $payload -Provider 'Claude'
    }

    # 4. Run orchestrator with expert outputs
    $orchestratorPrompt = Get-Content (Join-Path $PSScriptRoot "..\Config\Prompts\OrchestratorPrompt.txt") -Raw
    $synthesisPayload = @{
        SecurityAnalysis = $expertResults.Security.Text
        CostAnalysis = $expertResults.Cost.Text
        RBACAnalysis = $expertResults.RBAC.Text
        OperationsAnalysis = $expertResults.Operations.Text
        NetworkAnalysis = $expertResults.Network.Text
        Metadata = $reportMetadata
    }

    $finalResult = Invoke-ClaudeAnalysis `
        -SystemPrompt $orchestratorPrompt `
        -UserPrompt ($synthesisPayload | ConvertTo-Json -Depth 10) `
        -Model 'claude-opus-4-5-20250514'  # Opus for synthesis

    return $finalResult
}
```

---

## Testing

### Test 1: Claude API Integration

```powershell
# Set environment
$env:ANTHROPIC_API_KEY = "sk-ant-..."

# Test basic call
$result = Invoke-ClaudeAnalysis `
    -SystemPrompt "You are a helpful assistant." `
    -UserPrompt "Say hello in JSON format: {greeting: string}" `
    -Model 'claude-haiku-3-5-20241022'  # Use Haiku for cheap testing

$result | Format-List
```

### Test 2: Single Expert

```powershell
# Load some test data
$testSecurityData = @{
    findings = @(
        @{ controlId = "CIS-1.1"; severity = "High"; status = "FAIL" }
    )
}

$result = Invoke-DomainExpert -ExpertType Security -DomainData $testSecurityData -Provider Claude
$result.Text
```

### Test 3: Full Multi-Expert Flow

```powershell
# Run audit with new provider
Invoke-AzureSecurityAudit -AI -Provider 'Claude-MultiExpert'
```

---

## Cost Estimation

### Per-Run Costs (Estimated)

| Component | Model | Input Tokens | Output Tokens | Cost |
|-----------|-------|--------------|---------------|------|
| Security Expert | Sonnet | ~5K | ~2K | ~$0.045 |
| Cost Expert | Sonnet | ~3K | ~1.5K | ~$0.03 |
| RBAC Expert | Sonnet | ~2K | ~1K | ~$0.02 |
| Operations Expert | Sonnet | ~4K | ~1.5K | ~$0.035 |
| Network Expert | Sonnet | ~3K | ~1.5K | ~$0.03 |
| **Orchestrator** | **Opus** | ~10K | ~3K | ~$0.375 |
| **Total** | | | | **~$0.54** |

Compare to current: Single GPT-4o-nano call ~$0.02-0.05

Trade-off: ~10x cost for significantly deeper, domain-specific analysis with Opus-quality synthesis.

---

## Migration Path

1. **Phase 1**: Implement `Invoke-ClaudeAnalysis.ps1` (drop-in alternative to OpenAI)
2. **Phase 2**: Add data router functions
3. **Phase 3**: Create expert prompts
4. **Phase 4**: Implement multi-expert orchestration
5. **Phase 5**: Add `-Provider` parameter to main cmdlet
6. **Phase 6**: (Optional) Add Claude Code Skills for interactive analysis

---

## Notes for Implementation

### PowerShell HTTP Client Pattern

Use the same `System.Net.Http.HttpClient` pattern as `Invoke-OpenAIAnalysis.ps1`:

```powershell
Add-Type -AssemblyName System.Net.Http
$handler = New-Object System.Net.Http.HttpClientHandler
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

# Claude-specific headers
$client.DefaultRequestHeaders.Add('x-api-key', $ApiKey)
$client.DefaultRequestHeaders.Add('anthropic-version', '2023-06-01')
$client.DefaultRequestHeaders.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new('application/json'))
```

### Error Handling

Claude API errors return:

```json
{
    "type": "error",
    "error": {
        "type": "invalid_request_error",
        "message": "..."
    }
}
```

Check `$response.type -eq 'error'` and extract `$response.error.message`.

### Rate Limits

Claude API returns rate limit headers:
- `anthropic-ratelimit-requests-limit`
- `anthropic-ratelimit-requests-remaining`
- `anthropic-ratelimit-tokens-limit`
- `anthropic-ratelimit-tokens-remaining`

Consider logging these for monitoring.
