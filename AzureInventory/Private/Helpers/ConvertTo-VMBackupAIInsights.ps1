<#
.SYNOPSIS
    Converts VM backup inventory data into AI-ready JSON insights.

.DESCRIPTION
    Extracts and structures the most important VM backup insights
    for AI analysis, focusing on unprotected VMs, backup gaps,
    and health issues.

.PARAMETER VMInventory
    Array of VM inventory objects from Get-AzureVirtualMachineFindings.

.PARAMETER TopN
    Number of top findings to include (default: 20).

.PARAMETER BackupAgeThreshold
    Number of days since last backup to consider as gap (default: 30).

.EXAMPLE
    $insights = ConvertTo-VMBackupAIInsights -VMInventory $vmInventory -TopN 25 -BackupAgeThreshold 30
#>
function ConvertTo-VMBackupAIInsights {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$VMInventory,
        
        [Parameter(Mandatory = $false)]
        [int]$TopN = 20,
        
        [Parameter(Mandatory = $false)]
        [int]$BackupAgeThreshold = 30
    )
    
    Write-Verbose "Converting VM backup data to AI insights (TopN: $TopN, BackupAgeThreshold: $BackupAgeThreshold)"
    
    # Handle empty/null data
    if (-not $VMInventory -or $VMInventory.Count -eq 0) {
        Write-Verbose "No VM inventory found"
        return @{
            domain = "vm_backup"
            generated_at = (Get-Date).ToString("o")
            summary = @{
                total_vms = 0
                protected_vms = 0
                unprotected_vms = 0
                running_unprotected = 0
                backup_gaps = 0
                health_issues = 0
                protection_rate = 0
            }
            unprotected_vms = @()
            backup_gaps = @()
            by_subscription = @()
            health_issues = @()
        }
    }
    
    # Calculate summary statistics
    $totalVMs = $VMInventory.Count
    $protectedVMs = @($VMInventory | Where-Object { $_.BackupEnabled }).Count
    $unprotectedVMs = $totalVMs - $protectedVMs
    $runningVMs = @($VMInventory | Where-Object { $_.PowerState -eq 'running' }).Count
    $runningUnprotected = @($VMInventory | Where-Object { 
        $_.PowerState -eq 'running' -and -not $_.BackupEnabled 
    }).Count
    
    $protectionRate = if ($totalVMs -gt 0) {
        [math]::Round(($protectedVMs / $totalVMs) * 100, 1)
    } else {
        0
    }
    
    # Find VMs without recent backups
    $today = Get-Date
    $backupGaps = [System.Collections.Generic.List[PSObject]]::new()
    $healthIssues = [System.Collections.Generic.List[PSObject]]::new()
    
    foreach ($vm in $VMInventory) {
        if ($vm.BackupEnabled) {
            # Check for backup age gap
            if ($vm.LastBackupTime) {
                $lastBackupDate = if ($vm.LastBackupTime -is [DateTime]) {
                    $vm.LastBackupTime
                } else {
                    try {
                        [DateTime]::Parse($vm.LastBackupTime)
                    } catch {
                        $null
                    }
                }
                
                if ($lastBackupDate) {
                    $daysSinceBackup = ($today - $lastBackupDate).Days
                    if ($daysSinceBackup -gt $BackupAgeThreshold) {
                        $backupGaps.Add([PSCustomObject]@{
                            VMName = $vm.VMName
                            ResourceGroup = $vm.ResourceGroup
                            SubscriptionName = $vm.SubscriptionName
                            LastBackupTime = $lastBackupDate
                            DaysSinceBackup = $daysSinceBackup
                            VaultName = $vm.VaultName
                            PolicyName = $vm.PolicyName
                            PowerState = $vm.PowerState
                        })
                    }
                }
            }
            
            # Check for health issues
            if ($vm.HealthStatus -and $vm.HealthStatus -ne 'Healthy') {
                $healthIssues.Add([PSCustomObject]@{
                    VMName = $vm.VMName
                    ResourceGroup = $vm.ResourceGroup
                    SubscriptionName = $vm.SubscriptionName
                    HealthStatus = $vm.HealthStatus
                    LastBackupStatus = $vm.LastBackupStatus
                    VaultName = $vm.VaultName
                    PolicyName = $vm.PolicyName
                    PowerState = $vm.PowerState
                })
            }
            
            # Check for failed backup status
            if ($vm.LastBackupStatus -and $vm.LastBackupStatus -ne 'Completed' -and $vm.LastBackupStatus -ne 'CompletedWithWarnings') {
                $healthIssues.Add([PSCustomObject]@{
                    VMName = $vm.VMName
                    ResourceGroup = $vm.ResourceGroup
                    SubscriptionName = $vm.SubscriptionName
                    HealthStatus = $vm.HealthStatus
                    LastBackupStatus = $vm.LastBackupStatus
                    VaultName = $vm.VaultName
                    PolicyName = $vm.PolicyName
                    PowerState = $vm.PowerState
                })
            }
        }
    }
    
    # Get unprotected VMs (prioritize running ones)
    $unprotectedVMList = @($VMInventory | 
        Where-Object { -not $_.BackupEnabled } | 
        Sort-Object @{
            Expression = { if ($_.PowerState -eq 'running') { 0 } else { 1 } }
        }, VMName | 
        Select-Object -First $TopN | 
        ForEach-Object {
            @{
                vm_name = $_.VMName
                resource_group = $_.ResourceGroup
                subscription = $_.SubscriptionName
                power_state = $_.PowerState
                os_type = $_.OsType
                vm_size = $_.VMSize
                location = $_.Location
            }
        })
    
    # Build backup gaps list
    $backupGapsList = @($backupGaps | 
        Sort-Object DaysSinceBackup -Descending | 
        Select-Object -First $TopN | 
        ForEach-Object {
            @{
                vm_name = $_.VMName
                resource_group = $_.ResourceGroup
                subscription = $_.SubscriptionName
                last_backup_time = if ($_.LastBackupTime -is [DateTime]) {
                    $_.LastBackupTime.ToString("o")
                } else {
                    $_.LastBackupTime.ToString()
                }
                days_since_backup = $_.DaysSinceBackup
                vault_name = $_.VaultName
                policy_name = $_.PolicyName
                power_state = $_.PowerState
            }
        })
    
    # Build health issues list
    $healthIssuesList = @($healthIssues | 
        Sort-Object @{
            Expression = {
                switch ($_.HealthStatus) {
                    "Unhealthy" { 0 }
                    "Warning" { 1 }
                    default { 2 }
                }
            }
        }, VMName | 
        Select-Object -First $TopN | 
        ForEach-Object {
            @{
                vm_name = $_.VMName
                resource_group = $_.ResourceGroup
                subscription = $_.SubscriptionName
                health_status = $_.HealthStatus
                last_backup_status = $_.LastBackupStatus
                vault_name = $_.VaultName
                policy_name = $_.PolicyName
                power_state = $_.PowerState
            }
        })
    
    # Group by subscription
    $bySubscription = @($VMInventory | 
        Group-Object SubscriptionName | 
        ForEach-Object {
            $subVMs = $_.Group
            $subTotal = $subVMs.Count
            $subProtected = @($subVMs | Where-Object { $_.BackupEnabled }).Count
            $subUnprotected = $subTotal - $subProtected
            $subRunning = @($subVMs | Where-Object { $_.PowerState -eq 'running' }).Count
            $subRunningUnprotected = @($subVMs | Where-Object { 
                $_.PowerState -eq 'running' -and -not $_.BackupEnabled 
            }).Count
            $subProtectionRate = if ($subTotal -gt 0) {
                [math]::Round(($subProtected / $subTotal) * 100, 1)
            } else {
                0
            }
            
            @{
                subscription = $_.Name
                total_vms = $subTotal
                protected_vms = $subProtected
                unprotected_vms = $subUnprotected
                running_vms = $subRunning
                running_unprotected = $subRunningUnprotected
                protection_rate = $subProtectionRate
            }
        } | Sort-Object unprotected_vms -Descending)
    
    $insights = @{
        domain = "vm_backup"
        generated_at = (Get-Date).ToString("o")
        
        summary = @{
            total_vms = $totalVMs
            protected_vms = $protectedVMs
            unprotected_vms = $unprotectedVMs
            running_vms = $runningVMs
            running_unprotected = $runningUnprotected
            backup_gaps = $backupGaps.Count
            health_issues = $healthIssues.Count
            protection_rate = $protectionRate
        }
        
        unprotected_vms = $unprotectedVMList
        
        backup_gaps = $backupGapsList
        
        by_subscription = $bySubscription
        
        health_issues = $healthIssuesList
    }
    
    Write-Verbose "VM backup insights generated: $totalVMs VMs, $unprotectedVMs unprotected, $($backupGaps.Count) backup gaps, $($healthIssues.Count) health issues"
    
    return $insights
}

