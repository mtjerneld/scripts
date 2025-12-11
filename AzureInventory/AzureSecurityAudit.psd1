#
# Module manifest for module 'AzureSecurityAudit'
#

@{
    RootModule = 'AzureSecurityAudit.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author = 'Azure Security Team'
    CompanyName = 'Unknown'
    Copyright = '(c) 2025. All rights reserved.'
    Description = 'Azure Security Audit Tool - CIS Benchmark Compliance Scanner for multi-subscription security assessments'
    
    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '5.1'
    
    # Functions to export from this module
    FunctionsToExport = @(
        'Invoke-AzureSecurityAudit',
        'Export-SecurityReport',
        'Export-VMBackupReport',
        'Export-AdvisorReport',
        'Export-ChangeTrackingReport',
        'Export-DashboardReport',
        'Export-NetworkInventoryReport',
        'Connect-AuditEnvironment'
    )
    
    # Cmdlets to export from this module
    CmdletsToExport = @()
    
    # Variables to export from this module
    VariablesToExport = @()
    
    # Aliases to export from this module
    AliasesToExport = @()
    
    # Note: Required modules are checked at runtime by Connect-AuditEnvironment
    # Install with: Install-Module Az -Force
    # Required modules: Az.Accounts, Az.Resources, Az.Storage, Az.Websites, 
    #                   Az.Compute, Az.Sql, Az.Network, Az.Monitor, Az.ConnectedMachine
    
    # Private data to pass to the module
    PrivateData = @{
        PSData = @{
            Tags = @('Azure', 'Security', 'CIS', 'Compliance', 'Audit')
            LicenseUri = ''
            ProjectUri = ''
            IconUri = ''
            ReleaseNotes = 'Initial release - P0 and P1 CIS controls for Azure security auditing'
        }
    }
}

