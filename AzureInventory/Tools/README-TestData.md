# Test Data Generator for HTML/CSS Testing

This tool allows you to quickly test HTML/CSS changes without running full Azure scans.

## Quick Start

1. **Load the test data generator:**
   ```powershell
   . .\Tools\New-TestData.ps1
   ```

2. **Generate a single report (recommended for focused testing):**
   ```powershell
   Test-SingleReport -ReportType Security
   Test-SingleReport -ReportType VMBackup
   Test-SingleReport -ReportType ChangeTracking
   # etc...
   ```
   
   **Note:** All test reports are saved to the `test-output` directory by default.

3. **Or generate all reports at once:**
   ```powershell
   . .\Tools\Test-ReportsWithDummyData.ps1
   ```

## Available Report Types

- `Security` - Security audit findings
- `VMBackup` - VM backup status
- `ChangeTracking` - Azure change tracking
- `CostTracking` - Cost analysis
- `EOL` - End of Life components
- `NetworkInventory` - Network inventory
- `RBAC` - Role-based access control
- `Advisor` - Azure Advisor recommendations

## Usage Examples

### Test a single report with custom output path:
```powershell
. .\Tools\New-TestData.ps1
Test-SingleReport -ReportType Security -OutputPath "test-output\custom-security.html"
```

### Generate test data manually:
```powershell
. .\Tools\New-TestData.ps1

# Generate test data
$securityData = New-TestSecurityData
$vmData = New-TestVMBackupData

# Use with export functions
Export-SecurityReport -AuditResult $securityData -OutputPath "security.html"
Export-VMBackupReport -VMInventory $vmData -OutputPath "vm-backup.html" -TenantId "test-tenant"
```

### Generate all test data at once:
```powershell
. .\Tools\New-TestData.ps1
$allData = New-TestAllData

# Access individual datasets
$allData.Security
$allData.VMBackup
$allData.ChangeTracking
# etc...
```

## Workflow for Fixing CSS

1. **Pick one report to fix:**
   ```powershell
   Test-SingleReport -ReportType Security
   ```

2. **Open the generated HTML file in your browser**

3. **Make CSS changes** in `Config/Styles/` files

4. **Regenerate the report** to see changes:
   ```powershell
   Test-SingleReport -ReportType Security
   ```

5. **Repeat** until the design looks good

6. **Move to the next report** and repeat

## Notes

- All test data is generated locally - no Azure connection required
- Test data includes realistic structures matching real Azure data
- You can adjust the amount of test data by modifying the functions (e.g., `New-TestSecurityData -FindingCount 100`)
- The generated reports use the same HTML structure as real reports, so CSS fixes will apply to both

