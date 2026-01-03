# Creating Test Reports with Test Data

This guide explains how to generate HTML reports using dummy test data, perfect for rapid HTML/CSS development and testing without needing to run full Azure scans.

## Overview

The test data generation system allows you to:
- Generate realistic dummy data for all report types
- Create HTML reports instantly without Azure connections
- Iterate quickly on CSS/HTML changes
- Test all report types with consistent test data

All test reports are saved to the `test-output/` directory.

## Quick Start

### Generate a Single Report

To generate a single report (e.g., Security report) with test data:

```powershell
# Load the test data generator
. .\Tools\New-TestData.ps1

# Generate and open a Security report
Test-SingleReport -ReportType Security
```

The report will be saved to `test-output/security.html` and automatically opened in your default browser.

### Generate All Reports

To generate all reports at once:

```powershell
# Run the test reports script
. .\Tools\Test-ReportsWithDummyData.ps1
```

This will generate all 8 report types:
- Security (`security.html`)
- VM Backup (`vm-backup.html`)
- Change Tracking (`change-tracking.html`)
- Cost Tracking (`cost-tracking.html`)
- EOL (`eol.html`)
- Network Inventory (`network-inventory.html`)
- RBAC (`rbac.html`)
- Advisor (`advisor.html`)

## Available Report Types

When using `Test-SingleReport`, you can specify any of these report types:

- `Security` - Security compliance and findings report
- `VMBackup` - Virtual Machine backup status report
- `ChangeTracking` - Resource change tracking report
- `CostTracking` - Cost analysis report
- `EOL` - End-of-life tracking report
- `NetworkInventory` - Network resource inventory
- `RBAC` - Role-Based Access Control inventory
- `Advisor` - Azure Advisor recommendations
- `Dashboard` - Main dashboard summarizing all reports

## Examples

### Example 1: Generate Security Report

```powershell
. .\Tools\New-TestData.ps1
Test-SingleReport -ReportType Security
```

### Example 2: Generate VM Backup Report with Custom Output Path

```powershell
. .\Tools\New-TestData.ps1
Test-SingleReport -ReportType VMBackup -OutputPath "test-output/my-vm-test.html"
```

### Example 3: Generate Network Inventory Report

```powershell
. .\Tools\New-TestData.ps1
Test-SingleReport -ReportType NetworkInventory
```

### Example 4: Generate Dashboard Report

```powershell
. .\Tools\New-TestData.ps1
Test-SingleReport -ReportType Dashboard
```

### Example 5: Generate All Reports

```powershell
. .\Tools\Test-ReportsWithDummyData.ps1
```

Or with a custom output folder:

```powershell
. .\Tools\Test-ReportsWithDummyData.ps1 -OutputFolder "my-test-reports"
```

## Test Data Details

### Security Report Test Data

The Security report test data includes:
- **50 findings** by default (configurable)
- **6 categories**: Storage, AppService, VM, Network, SQL, KeyVault
- **4 severity levels**: Critical, High, Medium, Low
- **3 subscriptions**: Sub-Prod-001, Sub-Dev-002, Sub-Test-003
- **Frameworks**: Mix of CIS only, ASB only, and CIS+ASB
- **CIS Levels**: L1 only (L2 is skipped for now)

Each category is guaranteed to have at least one failed finding to ensure all categories appear in the report.

### Network Inventory Test Data

The Network Inventory report test data includes:
- **10 VNets** by default (configurable with `-VNetCount`)
- **Subnets** with NSG risks, connected devices, and service endpoints
- **Gateways** (VPN and ExpressRoute) with connections
- **Peerings** between VNets
- **Virtual WAN Hubs** with VPN and ExpressRoute connections
- **Azure Firewalls** with deployment configurations
- **NSG Security Risks** with Critical, High, and Medium severity levels
- **Connected Devices** (NICs, Load Balancers, Application Gateways, Bastion)
- **3 subscriptions**: Sub-Prod-001, Sub-Dev-002, Sub-Test-003

The test data includes realistic network topologies with security risks to test the full report functionality.

### VM Backup Test Data

The VM Backup report test data includes:
- **30 VMs** by default (configurable with `-VMCount`)
- **3 subscriptions**: Sub-Prod-001, Sub-Dev-002, Sub-Test-003
- **Mixed OS types**: Windows and Linux
- **Power states**: Running, Stopped, Deallocated
- **Backup status**: 2/3 protected, 1/3 unprotected
- **Backup vaults**: Multiple vault names (vault-prod-001, vault-prod-002, vault-dev-001)
- **Backup policies**: Various policy names (DefaultPolicy, DailyBackupPolicy, WeeklyBackupPolicy, ProductionBackupPolicy)
- **Health statuses**: Healthy, Warning, or null
- **Protection statuses**: Protected, ProtectionStopped, ProtectionError
- **Last backup times**: Various dates (0-7 days ago)
- **VM sizes**: Standard_B2s, Standard_D2s_v3, Standard_D4s_v3, Standard_B4ms, Standard_DS2_v2
- **Resource groups**: RG-Prod-VM, RG-Dev-VM, RG-Test-VM, RG-Shared-VM
- **Locations**: eastus, westus, westeurope, northeurope

**Important:** The test data structure matches exactly the real data structure from `Get-AzureVirtualMachineFindings.ps1`:
- Uses `VMName` (not `Name`)
- Uses `OsType` (not `OSType`)
- Uses `VaultName` (not `BackupVaultName`)
- Uses `PolicyName` (not `BackupPolicyName`)
- Includes all fields: `HealthStatus`, `ProtectionStatus`, `LastBackupStatus`, `VMSize`, `ProvisioningState`, etc.

### Customizing Test Data

To customize test data, edit the functions in `Tools/New-TestData.ps1`:

- `New-TestSecurityData -FindingCount 100` - Generate more findings
- `New-TestNetworkInventoryData -VNetCount 20` - Generate more VNets
- `New-TestVMBackupData -VMCount 50` - Generate more VMs
- Modify framework distribution in the function
- Adjust subscription names or IDs
- Change category/severity distributions

## Workflow for CSS/HTML Development

1. **Make CSS changes** in `Config/Styles/` files
2. **Generate test report**:
   ```powershell
   . .\Tools\New-TestData.ps1
   Test-SingleReport -ReportType Security
   ```
3. **Review changes** in the browser
4. **Repeat** steps 1-3 until satisfied
5. **Test all reports** when ready:
   ```powershell
   . .\Tools\Test-ReportsWithDummyData.ps1
   ```

## Output Location

All test reports are saved to:
- **Default**: `test-output/` directory (relative to project root)
- **Custom**: Specify with `-OutputPath` or `-OutputFolder` parameters

The `test-output/` directory is created automatically if it doesn't exist.

## Tips

1. **Fast Iteration**: Use `Test-SingleReport` for quick CSS testing on one report at a time
2. **Full Testing**: Use `Test-ReportsWithDummyData.ps1` to verify all reports work together
3. **Browser Refresh**: Use Ctrl+F5 (hard refresh) to ensure CSS changes are loaded
4. **Module Reload**: The `Test-SingleReport` function automatically reloads the module to ensure you're using the latest code
5. **No Azure Required**: Test data generation works completely offline - no Azure connection needed!

## Troubleshooting

### Module Functions Not Found

If you get errors about missing functions:

```powershell
# Reload the module
. .\Init-Local.ps1

# Then load test data generator
. .\Tools\New-TestData.ps1
```

### Reports Not Updating

If changes don't appear in the browser:
1. Hard refresh the browser (Ctrl+F5)
2. Regenerate the report
3. Check that you're editing the correct CSS files in `Config/Styles/`

### Test Data Issues

If test data doesn't match expected format:
- Check `Tools/New-TestData.ps1` for the data structure
- Ensure all required properties are present (SubscriptionId, SubscriptionName, Category, Severity, Frameworks, etc.)

## Testing with Real Azure Data

For testing with real Azure data (requires Azure connection):

```powershell
# Load the module
. .\Init-Local.ps1

# Test Network Inventory with real Azure data
Test-NetworkInventory -SubscriptionIds @("sub-id-1", "sub-id-2")

# Or test with all subscriptions in current tenant
Test-NetworkInventory
```

The `Test-NetworkInventory` function:
- Collects real network inventory from Azure subscriptions
- Generates HTML report with actual data
- Opens the report automatically in your browser
- Saves to `network-inventory-test.html` by default

## Unit Tests

Pester test cases are available for Network Inventory:

```powershell
# Run Network Inventory tests
Invoke-Pester Tests/NetworkInventory.Tests.ps1

# Run all tests
Invoke-Pester Tests/
```

The test suite validates:
- Test data generation
- Report generation with various data scenarios
- HTML structure and CSS class usage
- Edge cases (empty data, missing properties, etc.)

## File Structure

```
AzureInventory/
├── Tools/
│   ├── New-TestData.ps1              # Test data generator functions
│   └── Test-ReportsWithDummyData.ps1  # Script to generate all reports
├── Tests/
│   ├── NetworkInventory.Tests.ps1     # Pester tests for Network Inventory
│   ├── ConvertTo-SecurityAIInsights.Tests.ps1
│   └── ... (other test files)
├── test-output/                       # Output directory for test reports
│   ├── security.html
│   ├── vm-backup.html
│   ├── network-inventory.html
│   └── ... (other reports)
└── Config/
    └── Styles/                        # CSS files to modify
        ├── _variables.css
        ├── _base.css
        └── _components/
            └── ... (component CSS files)
```

## Next Steps

- Modify CSS files in `Config/Styles/` to customize report appearance
- Adjust test data in `Tools/New-TestData.ps1` to test different scenarios
- Generate reports and review in browser
- Iterate until satisfied with the design

Happy testing! 🎨

