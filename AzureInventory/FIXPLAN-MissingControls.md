# FIXPLAN: Missing Control Implementations

## Instructions for Cursor

### Status Management
- Du får ENDAST sätta status till `[IN PROGRESS]` eller `[READY FOR REVIEW]`
- Du får ALDRIG markera issues som `[FIXED]` - endast Claude får göra detta efter review
- Du får ALDRIG skapa nya issues - rapportera problem till Claude istället

### When Done with an Issue
Ändra rubriken och lägg till status:
```
## Issue N: Title [READY FOR REVIEW]
**Status:** Ready for review - implemented in commit abc123
```

### Status Flow
```
[NEW] → [IN PROGRESS] → [READY FOR REVIEW] → [FIXED]
                                              ↓
                                    Status: Verified by Claude
```

---

## Background

We have 53 controls defined in `Config/ControlDefinitions.json`, but only ~26 are actually implemented in the scanner code. This creates a significant gap where many security controls are never evaluated.

### Current State Summary

| Category | Controls Defined | Controls Implemented | Gap |
|----------|-----------------|---------------------|-----|
| Storage | 12 | 6 | 6 missing |
| SQL | 6 | 5 | 1 missing |
| Network | 9 | 5 | 4 missing (2 manual) |
| VM | 6 | 5 | 1 missing |
| AppService | 4 | 4 | 0 |
| ARC | 4 | 4 | 0 |
| Monitor | 5 | 3 | 2 missing (1 manual) |
| KeyVault | 8 | 4 | 4 missing |

**Manual controls** (marked `automated: false`) require human review and cannot be auto-checked:
- Azure Resource Manager Delete Locks (Storage)
- Network Security Groups Configured (Network)
- Network Security Groups Rules Reviewed (Network)
- No MMA/OMS Agents (Monitor) - Note: This IS implemented in scanner despite being marked manual

---

## Issue 1: Storage - Missing File Share Controls [NEW]

**Problem:** Three Azure File Share controls are defined but not implemented
**Where:** `Private/Scanners/Get-AzureStorageFindings.ps1`
**Controls to implement:**

1. **Soft Delete for Azure File Shares (10.1.1)**
   - API: `Get-AzStorageFileServiceProperty -ResourceGroupName $rg -StorageAccountName $name`
   - Check: `$props.ShareDeleteRetentionPolicy.Enabled -eq $true`

2. **SMB Protocol Version 3.1.1 or Higher (10.1.2)**
   - API: Same as above, check `$props.ProtocolSettings.Smb.Versions`
   - Check: Versions should contain "SMB3.1.1"

3. **SMB Channel Encryption AES-256-GCM (10.1.3)**
   - API: Same as above, check `$props.ProtocolSettings.Smb.AuthenticationMethods`
   - Check: Should have encryption enabled

**Implementation pattern:** Follow existing blob soft delete pattern in the scanner

**Test:** Run `Start-AzureGovernanceAudit -Mode Test -ReportType Security` and verify file share controls appear

---

## Issue 2: Storage - Cross Tenant Replication Control [NEW]

**Problem:** Cross Tenant Replication control (10.3.8) is defined but not implemented
**Where:** `Private/Scanners/Get-AzureStorageFindings.ps1`

**Implementation:**
```powershell
$crossTenantControl = $controlLookup["Cross Tenant Replication Disabled"]
if ($crossTenantControl) {
    $controlsEvaluated++
    $allowCrossTenant = if ($null -ne $sa.AllowCrossTenantReplication) {
        $sa.AllowCrossTenantReplication
    } else {
        $true  # Default is allowed if not set
    }
    $status = if (-not $allowCrossTenant) { "PASS" } else { "FAIL" }
    # Create finding...
}
```

**Property:** `$sa.AllowCrossTenantReplication` - already available on storage account object

**Test:** Verify control appears in security report

---

## Issue 3: Storage - Private Endpoints Control [NEW]

**Problem:** Storage Private Endpoints control (NS-2) is defined but not implemented
**Where:** `Private/Scanners/Get-AzureStorageFindings.ps1`

**Implementation:**
- Check: `$sa.PrivateEndpointConnections` property
- Pass if at least one approved private endpoint exists
- Note: This is an ASB control, not CIS

**Consideration:** Many storage accounts legitimately don't need private endpoints, so consider making this informational or adjustable severity

---

## Issue 4: SQL - Enable Threat Detection Control [NEW]

**Problem:** Enable Threat Detection control (LT-1) is defined but not implemented
**Where:** `Private/Scanners/Get-AzureSqlDatabaseFindings.ps1`

**Implementation:**
- API: `Get-AzSqlServerAdvancedThreatProtectionSetting -ResourceGroupName $rg -ServerName $server`
- Check: `$setting.ThreatDetectionState -eq 'Enabled'`
- Note: This is a commercial feature (Defender for SQL)

---

## Issue 5: Network - Flow Logs Control [NEW]

**Problem:** NSG Flow Logs control (8.7) is defined but not implemented
**Where:** `Private/Scanners/Get-AzureNetworkFindings.ps1`

**Implementation:**
- Requires Network Watcher API
- API: `Get-AzNetworkWatcherFlowLog` for each NSG
- Check: Flow log exists and is enabled
- Note: Requires Network Watcher to be enabled first

---

## Issue 6: VM - Disk Encryption Control [NEW]

**Problem:** VM Disk Encryption control (DP-4) is defined but not implemented
**Where:** `Private/Scanners/Get-AzureVirtualMachineFindings.ps1`

**Implementation:**
- Check: `$vm.StorageProfile.OsDisk.EncryptionSettings` or Azure Disk Encryption status
- Alternative: Check if disk has Server-Side Encryption
- API: `Get-AzDisk -ResourceGroupName $rg -DiskName $diskName` then check `EncryptionSettings`

---

## Issue 7: KeyVault - Key/Secret Expiration Controls [NEW]

**Problem:** Four key/secret expiration controls are defined but not implemented
**Where:** `Private/Scanners/Get-AzureKeyVaultFindings.ps1`
**Controls:**

1. **Expiration Date Set for All Keys in RBAC Key Vaults (9.3.1)**
2. **Expiration Date Set for All Keys in Non-RBAC Key Vaults (9.3.2)**
3. **Expiration Date Set for All Secrets in RBAC Key Vaults (9.3.3)**
4. **Expiration Date Set for All Secrets in Non-RBAC Key Vaults (9.3.4)**

**Challenge:** Requires data plane access to Key Vault, not just management plane
- Need: `Get-AzKeyVaultKey -VaultName $vaultName` and `Get-AzKeyVaultSecret -VaultName $vaultName`
- These require appropriate Key Vault access policies or RBAC roles

**Consideration:** May need to make these optional or handle access denied gracefully

---

## Issue 8: Monitor - Log Analytics Retention Control [NEW]

**Problem:** Log Analytics Workspace Retention Period control (7.1.4) is defined but not implemented
**Where:** `Private/Scanners/Get-AzureMonitorFindings.ps1`

**Implementation:**
- API: `Get-AzOperationalInsightsWorkspace`
- Check: `$workspace.RetentionInDays -ge 90`

---

## Issue 9: Update Test Data Generator [NEW]

**Problem:** `New-TestSecurityData` needs to generate findings for newly implemented controls
**Where:** `Tools/New-TestData.ps1`

**After implementing new controls**, update the test data generator to include:
- File Share controls (soft delete, SMB settings)
- Cross Tenant Replication findings
- Private Endpoints findings
- Threat Detection findings
- Flow Logs findings
- Disk Encryption findings
- Key/Secret expiration findings
- Log Analytics retention findings

---

## Priority Order

**High Priority (Core Security):**
1. Issue 2: Cross Tenant Replication (simple, property already available)
2. Issue 6: VM Disk Encryption (important security control)
3. Issue 4: SQL Threat Detection (if Defender is enabled)

**Medium Priority (Compliance):**
4. Issue 1: File Share Controls (multiple controls, similar pattern)
5. Issue 8: Log Analytics Retention (simple check)
6. Issue 5: Network Flow Logs (requires Network Watcher)

**Lower Priority (Complex/Optional):**
7. Issue 3: Private Endpoints (may not apply to all environments)
8. Issue 7: Key/Secret Expiration (requires data plane access)

**Last:**
9. Issue 9: Update Test Data (after other issues)

---

## Testing

After implementing controls:
1. Run `Start-AzureGovernanceAudit -Mode Test -ReportType Security`
2. Verify new controls appear in console output with correct check counts
3. Verify findings appear in HTML report
4. Verify compliance scores update correctly
