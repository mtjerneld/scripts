## az-storage-gpv2-tls-audit.sh — README

## Beskrivning

Skriptet inventerar Azure Storage-konton i alla subscriptions du har åtkomst till för att identifiera:

- Kontotyper som bör uppgraderas inför Microsofts pensionering:
  - `BlobStorage` (legacy "blob-only")
  - `Storage` (GPv1)
- Storage-konton som inte tvingar TLS 1.2 (`minimumTlsVersion` != `TLS1_2` eller saknas)

Skriptet är read-only: det gör inga ändringar i din Azure-miljö. Det skriver ut en tabell per subscription i terminalen och exporterar en tidsstämplad CSV-fil.

## Förutsättningar

- Azure Cloud Shell (Bash) eller annan Bash-miljö med Azure CLI (`az`) installerad.
- Inloggad med `az login` mot en användare som har läsbehörighet (t.ex. Reader) på de subscriptions som ska inventeras.
- Vanliga Bash-verktyg: `awk`, `column`, `mktemp` (finns i Cloud Shell).

> Obs: Skriptet är skrivet för Bash. På Windows kör du det enklast i Cloud Shell, WSL eller Git Bash.

## Snabbstart

1. Kopiera skriptet till Cloud Shell eller din lokala miljö:

   ```bash
   nano az-storage-gpv2-tls-audit.sh
   # klistra in skriptet, spara: Ctrl+O Enter, stäng: Ctrl+X
   chmod +x az-storage-gpv2-tls-audit.sh
   ```

2. Kör skriptet:

   ```bash
   ./az-storage-gpv2-tls-audit.sh
   ```

3. (Valfritt) Ladda ner CSV-filen som skapas i din hemkatalog. Filnamnet har formatet `storage_inventory_YYYYMMDD_HHMMSS.csv`.

   I Cloud Shell kan du använda nedladdningsikonen eller kommandot:

   ```bash
   download storage_inventory_YYYYMMDD_HHMMSS.csv
   ```

## Vad skriptet gör

- Loopar igenom alla subscriptions du har åtkomst till.
- Hämtar Storage accounts som uppfyller minst ett av följande villkor:
  - `kind` är `BlobStorage` eller `Storage` (påverkade av 2026-pensioneringen)
  - `minimumTlsVersion` är inte `TLS1_2` eller saknas
- Visar en tabell per subscription i terminalen.
- Skapar en CSV i hemkatalogen med tidsstämplat filnamn, t.ex. `storage_inventory_20251004_093210.csv`.

### CSV-kolumner

CSV-filen innehåller (exempelkolumner):

- `SubscriptionId`
- `SubscriptionName`
- `ResourceGroup`
- `AccountName`
- `Kind`
- `MinimumTlsVersion`
- `Status` (se beskrivning nedan)

> Notera: Exakta kolumnnamn kan variera något beroende på skriptets implementation. Filen är avsedd för vidare analys och arkivering.

## Notera

Premiumkonton som `BlockBlobStorage` och `FileStorage` påverkas inte av denna pensionering och flaggas därför inte för "Version"-problemet.

## Vad skriptet inte gör

- Gör inga uppgraderingar, patcher eller andra ändringar (inga `update/create/delete`).
- Ändrar inte `supportsHttpsTrafficOnly`.
- Byter endast lokal CLI-kontent med `az account set` för att läsa resurser i respektive subscription.

---

## Nya inventeringsskript (TLS/legacy-relaterade)

Alla skript är read-only och kör mot alla subscriptions du har åtkomst till (samma mönster som `az-storage-gpv2-tls-audit.sh`). Varje skript skapar en tidsstämplad CSV i aktuell katalog och skriver även en tabell till terminalen.

### 1) az-sql-tls-audit.sh
- Inventerar Azure SQL Servers och läser `minimalTlsVersion` och `publicNetworkAccess`.
- CSV-kolumner: `SubscriptionName,SubscriptionId,ResourceGroup,ServerName,MinimumTlsVersion,PublicNetworkAccess,IsCompliant`.
- Compliance: `MinimumTlsVersion` ska vara 1.2.

Körning:
```bash
./az-sql-tls-audit.sh
```

### 2) az-appservice-tls-audit.sh
- Inventerar Web Apps/Function Apps och läser `minTlsVersion`, `ftpsState` och `httpsOnly`.
- CSV-kolumner: `SubscriptionName,SubscriptionId,ResourceGroup,SiteName,Kind,MinimumTlsVersion,FtpsState,HttpsOnly,IsCompliant`.
- Compliance: `minTlsVersion` = 1.2 och `httpsOnly` = true.

Körning:
```bash
./az-appservice-tls-audit.sh
```

### 3) az-adds-ldaps-audit.sh
- Inventerar Azure AD Domain Services och läser secure LDAP-inställningar samt certifikatets utgångsdatum.
- CSV-kolumner: `SubscriptionName,SubscriptionId,ResourceGroup,DomainServiceName,SecureLdapEnabled,SecureLdapExternalAccess,CertificateExpiry,IsCompliant`.
- Compliance: secure LDAP aktiverad och certifikatet giltigt.

Körning:
```bash
./az-adds-ldaps-audit.sh
```

### 4) az-monitor-agents-audit.sh
- Inventerar VM/VMSS-tillägg och identifierar legacy-agenter (OMS/MMA) samt nya Azure Monitor-agenter.
- CSV-kolumner: `SubscriptionName,SubscriptionId,ResourceGroup,VmType,Name,ExtensionPublisher,ExtensionType,ExtensionVersion,IsLegacyAgent,IsCompliant`.
- Heuristik:
  - Legacy: `OmsAgentForLinux`, `MicrosoftMonitoringAgent`, `MMAExtension`, `Microsoft.EnterpriseCloud.Monitoring`
  - Compliant: `AzureMonitorLinuxAgent`, `AzureMonitorWindowsAgent`

Körning:
```bash
./az-monitor-agents-audit.sh
```

### 5) az-automation-agents-audit.sh
- Inventerar Automation Accounts, Hybrid Worker Groups och Workers, samt länkad Log Analytics workspace.
- CSV-kolumner: `SubscriptionName,SubscriptionId,ResourceGroup,AutomationAccount,HybridWorkerGroup,WorkerName,LinkedWorkspaceResourceId,Notes,IsCompliant`.
- Not: `IsCompliant` sätts till `unknown` här; korskoppla med monitor-agent CSV för att se om workers kör legacy agent.

Körning:
```bash
./az-automation-agents-audit.sh
```

### 6) az-entra-legacy-apps-inventory.sh
- Inventerar Entra ID-appar via Microsoft Graph (kräver `jq` och Graph-behörigheter) och flaggar legacy-mönster: public client, implicit grant, OOB-redirects.
- CSV-kolumner: `AppId,DisplayName,SignInAudience,PublicClient,IsFallbackPublicClient,ImplicitGrantEnabled,HasOOBRedirect,IsCompliant`.
- Not: Detta är heuristik för legacy-konfigurationer — det är inte en TLS-kontroll.

Körning:
```bash
./az-entra-legacy-apps-inventory.sh
```

## Förutsättningar för nya skript
- Azure CLI (`az`) och inloggning med `az login`.
- Behörighet: minst Reader på de subscriptions som ska inventeras.
- För `az-entra-legacy-apps-inventory.sh`: `jq` samt Microsoft Graph-åtkomst (t.ex. `Application.Read.All` eller `Directory.Read.All`) med delegerat samtycke.

## Statusfält (i CSV och tabell)

Följande statusvärden används i utdata för att beskriva vad som behöver åtgärdas:

| Status  | Betydelse |
| ------- | --------- |
| Version | Kontotypen är `BlobStorage` eller `Storage` — bör uppgraderas till GPv2 |
| TLS     | `minimumTlsVersion` är inte `TLS1_2` (eller saknas) |
| Both    | Både kontotyp och TLS behöver åtgärdas |

## Utdata och filhämtning

- Terminal: en tabell per subscription med status för varje storage account.
- CSV: en fil med namn `storage_inventory_YYYYMMDD_HHMMSS.csv` sparas i din hemkatalog.
- Hämta filen via Cloud Shells nedladdningsknapp eller med:

  ```bash
  download storage_inventory_YYYYMMDD_HHMMSS.csv
  ```

## Kontakt / licens

Detta skript levereras utan garanti. Använd vid eget ansvar.

---

README uppdaterad: språkliga förbättringar, tydligare rubriker och information om CSV-kolumner.
