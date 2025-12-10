# CIS Microsoft Azure Foundations Benchmark v4.0.0 Comparison

## Sammanfattning

CIS v4.0.0 har omstrukturerat kontrollerna betydligt. Många kontroller har ändrat nummer och nya kontroller har lagts till.

## Mappning: Våra kontroller → CIS v4.0.0

| Vår Kontroll | Vårt Namn | CIS v4.0.0 | Status |
|-------------|-----------|------------|--------|
| 3.1 | Secure Transfer Required | **10.3.4** | ✅ Matchar |
| 3.6 | Soft Delete for Blobs | **10.3.6** | ✅ Matchar |
| 3.15 | Minimum TLS Version 1.2 | **10.3.7** | ✅ Matchar |
| 6.1 | No RDP from Internet | **8.1** | ✅ Matchar |
| 6.2 | No SSH from Internet | **8.2** | ✅ Matchar |
| 8.1 | Key Vault Firewall | **9.3.x** (delvis) | ⚠️ Delvis matchar |
| 8.3 | Key Vault RBAC | **9.3.x** (delvis) | ⚠️ Delvis matchar |
| 8.4 | Key Vault Soft Delete | **9.3.5** | ✅ Matchar |
| 8.5 | Key Vault Purge Protection | **9.3.5** | ✅ Matchar (del av samma kontroll) |
| 9.1 | App Service - Authentication Enabled | **9.1.x** (delvis) | ⚠️ Delvis matchar |
| 9.2 | App Service - HTTPS Only | **9.1.x** (delvis) | ⚠️ Delvis matchar |
| 9.3 | App Service - Minimum TLS 1.2 | **9.1.x** (delvis) | ⚠️ Delvis matchar |

## Kontroller som saknas i vår konfiguration (CIS v4.0.0)

### Storage (10.x)
- **10.1.1** - Soft delete for Azure File Shares
- **10.1.2** - SMB protocol version 3.1.1 or higher
- **10.1.3** - SMB channel encryption AES-256-GCM
- **10.2.1** - Soft delete for blobs (vi har 3.6 som motsvarar detta)
- **10.3.8** - Cross Tenant Replication disabled
- **10.3.9** - Allow Blob Anonymous Access disabled
- **10.3.10** - Azure Resource Manager Delete locks

### Databricks (3.1.x) - NYTT I v4.0.0
- **3.1.1** - Databricks in customer-managed VNet
- **3.1.2** - NSGs configured for Databricks subnets
- **3.1.4** - Users synced from Entra ID
- **3.1.5** - Unity Catalog configured
- **3.1.6** - Personal access tokens restricted
- **3.1.7** - Diagnostic log delivery configured

### Microsoft Entra ID / Identity (6.x) - NYTT I v4.0.0
- **6.1.1** - Security defaults enabled
- **6.1.2** - Multifactor authentication enabled for all users
- **6.1.3** - Remember MFA on trusted devices disabled
- **6.3.1** - Azure admin accounts not used for daily operations
- **6.3.2** - Guest users reviewed regularly
- **6.3.3** - User Access Administrator role restricted
- **6.3.4** - Privileged role assignments reviewed
- **6.4** - Restrict non-admin users from creating tenants
- **6.5** - Number of methods required to reset = 2
- **6.6** - Account lockout threshold ≤ 10
- **6.7** - Account lockout duration ≥ 60 seconds
- **6.8** - Custom banned password list set to Enforce
- **6.9** - Re-confirm authentication information not set to 0
- **6.10** - Notify users on password resets = Yes
- **6.11** - Notify all admins when other admins reset password = Yes
- **6.12** - User consent for applications = Do not allow
- **6.14** - Users can register applications = No
- **6.15** - Guest users access restrictions
- **6.17** - Restrict access to Microsoft Entra admin center = Yes
- **6.22** - Require MFA to register/join devices = Yes
- **6.23** - No custom subscription administrator roles

### Monitoring (7.x)
- **7.1.4** - Azure Monitor Resource Logging Enabled for All Services

### Network (8.x)
- **8.3** - UDP access from Internet evaluated and restricted
- **8.4** - HTTP(S) access from Internet evaluated and restricted
- **8.7** - Public IP addresses evaluated periodically

### Microsoft Defender for Cloud (9.1.x) - NYTT I v4.0.0
- **9.1.10** - Defender for Cloud checks VM OS for updates
- **9.1.11** - Cloud Security Benchmark policies not set to Disabled
- **9.1.12** - All users with Owner role configured
- **9.1.13** - Additional email addresses configured
- **9.1.14** - Notify about alerts with severity enabled
- **9.1.15** - Notify about attack paths with risk level enabled

### Key Vault (9.3.x)
- **9.3.1** - Expiration Date set for all Keys in RBAC Key Vaults
- **9.3.2** - Expiration Date set for all Keys in Non-RBAC Key Vaults
- **9.3.3** - Expiration Date set for all Secrets in RBAC Key Vaults
- **9.3.4** - Expiration Date set for all Secrets in Non-RBAC Key Vaults
- **9.3.5** - Key Vault is Recoverable (Soft Delete + Purge Protection)

## Kontroller som finns i vår konfiguration men INTE i CIS v4.0.0 L1

Dessa kontroller kan vara:
- Level 2 kontroller (inte i L1)
- Deprecated kontroller
- Kontroller från andra frameworks (ASB, Well-Architected)

| Kontroll | Namn | Kategori | Möjlig orsak |
|----------|------|----------|--------------|
| 2.1.1 | Microsoft Defender for Servers | VM | Kan vara L2 eller ASB |
| 3.2 | Infrastructure Encryption | Storage | Kan vara L2 |
| 3.7 | Public Blob Access | Storage | Kan vara L2 |
| 3.8 | Default Network Access | Storage | Kan vara L2 |
| 3.9 | Azure Services Bypass | Storage | Kan vara L2 |
| 3.12 | Customer-Managed Keys (CMK) | Storage | Kan vara L2 |
| 4.1.1 | SQL Auditing Enabled | SQL | Kan vara L2 |
| 4.1.2 | SQL Firewall - No Allow All | SQL | Kan vara L2 |
| 4.1.4 | Azure AD Admin Configured | SQL | Kan vara L2 |
| 4.1.5 | Transparent Data Encryption (TDE) | SQL | Kan vara L2 |
| 4.2.1 | Microsoft Defender for SQL | SQL | Kan vara L2 |
| 5.4 | Diagnostic Settings Enabled | Monitor | Kan vara L2 |
| 6.6 | Network Watcher Enabled | Network | Kan vara L2 |
| 7.2 | Managed Disks | VM | Kan vara L2 |
| 9.10 | App Service - FTP Disabled | AppService | Kan vara L2 |

## Rekommendationer

1. **Uppdatera kontroll-ID:n** för att matcha CIS v4.0.0:
   - 3.1 → 10.3.4
   - 3.6 → 10.3.6
   - 3.15 → 10.3.7
   - 6.1 → 8.1
   - 6.2 → 8.2
   - 8.4 → 9.3.5 (Soft Delete)
   - 8.5 → 9.3.5 (Purge Protection)

2. **Lägg till nya kontroller** från CIS v4.0.0:
   - Storage File Shares kontroller (10.1.x)
   - Databricks kontroller (3.1.x) - om relevant
   - Microsoft Entra ID kontroller (6.x) - om relevant
   - Microsoft Defender for Cloud kontroller (9.1.x)
   - Key Vault expiration kontroller (9.3.1-9.3.4)

3. **Verifiera deprecated kontroller**:
   - Kontrollera om kontroller som inte finns i v4.0.0 är deprecated eller Level 2

4. **Uppdatera metadata**:
   - Ändra `cisVersion` till "CIS Azure Foundations Benchmark v4.0.0"



