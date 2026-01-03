# Azure Change Tracking Noise Filter

## Problem

Azure Activity Logs and Change Analysis capture routine maintenance operations that obscure meaningful infrastructure changes. Common noise sources include:

- **VM Extension self-updates** - Extensions like SqlIaasExtension, Azure Monitor Agent, and Guest Configuration periodically reinstall themselves
- **Backup operations** - VMSnapshot extensions create/delete cycles
- **Policy evaluations** - Guest Configuration compliance checks

These appear as create/delete pairs within short time windows, triggered by Application service principals rather than users.

## Solution

Implement a toggleable noise filter in HTML reports that:
1. Marks noise rows during PowerShell report generation
2. Hides them by default with a visible count
3. Allows users to toggle visibility for full transparency

---

## PowerShell: Noise Detection Function

```powershell
function Test-IsExtensionNoise {
    param(
        [Parameter(Mandatory)]
        $Change,
        [array]$AllChanges  # Optional: for paired create/delete detection
    )
    
    # Only applies to VM extensions
    if ($Change.ResourceType -notlike '*virtualMachines/extensions*') {
        return $false
    }
    
    # Extensions known to perform automated self-maintenance
    $noisyExtensions = @(
        'SqlIaasExtension'           # SQL IaaS Agent updates
        'AzureMonitorWindowsAgent'   # AMA updates
        'AzureMonitorLinuxAgent'
        'MicrosoftMonitoringAgent'   # Legacy OMS/MMA
        'OmsAgentForLinux'
        'DependencyAgentWindows'     # VM Insights
        'DependencyAgentLinux'
        'AzurePolicyforWindows'      # Guest Configuration
        'AzurePolicyforLinux'
        'ConfigurationforWindows'
        'ConfigurationforLinux'
        'IaaSAntimalware'            # Defender
        'MDE.Windows'
        'MDE.Linux'
        'BGInfo'                     # Background info
        'VMSnapshot'                 # Backup snapshots
        'VMSnapshotLinux'
    )
    
    # Check 1: Known noisy extension + automated caller
    $isKnownNoisyExtension = $noisyExtensions -contains $Change.ResourceName
    $isAutomatedCaller = $Change.CallerType -eq 'Application'
    
    if ($isKnownNoisyExtension -and $isAutomatedCaller) {
        return $true
    }
    
    # Check 2: Any extension create/delete pair within 10 minutes (automated churn)
    if ($AllChanges -and $isAutomatedCaller) {
        $resourceId = $Change.ResourceId
        $timestamp = $Change.Timestamp
        $operation = $Change.OperationType  # 'Create' or 'Delete'
        
        $pairedOperation = if ($operation -eq 'Create') { 'Delete' } else { 'Create' }
        
        $hasPair = $AllChanges | Where-Object {
            $_.ResourceId -eq $resourceId -and
            $_.OperationType -eq $pairedOperation -and
            [Math]::Abs(($_.Timestamp - $timestamp).TotalMinutes) -le 10
        }
        
        if ($hasPair) {
            return $true
        }
    }
    
    return $false
}
```

## PowerShell: Mark Rows During HTML Generation

```powershell
# When building table rows
$noiseClass = if (Test-IsExtensionNoise -Change $change -AllChanges $allChanges) { 
    ' class="noise-row"' 
} else { 
    '' 
}

$html += "<tr$noiseClass>"
```

---

## HTML: Filter Toggle Control

Place in report header area:

```html
<div class="filter-controls">
    <label class="toggle-switch">
        <input type="checkbox" id="noiseFilter" checked onchange="toggleNoiseFilter()">
        <span class="toggle-slider"></span>
    </label>
    <span class="filter-label">
        Hide routine maintenance 
        <span id="noiseCount" class="noise-count">(0 hidden)</span>
    </span>
</div>
```

---

## CSS: Toggle Switch Styling (Dark Theme)

```css
.filter-controls {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 12px 16px;
    background: #2a2a2a;
    border-radius: 6px;
    margin-bottom: 16px;
}

.toggle-switch {
    position: relative;
    width: 44px;
    height: 24px;
}

.toggle-switch input {
    opacity: 0;
    width: 0;
    height: 0;
}

.toggle-slider {
    position: absolute;
    cursor: pointer;
    inset: 0;
    background-color: #555;
    border-radius: 24px;
    transition: 0.2s;
}

.toggle-slider:before {
    position: absolute;
    content: "";
    height: 18px;
    width: 18px;
    left: 3px;
    bottom: 3px;
    background-color: #fff;
    border-radius: 50%;
    transition: 0.2s;
}

.toggle-switch input:checked + .toggle-slider {
    background-color: #4a9eff;
}

.toggle-switch input:checked + .toggle-slider:before {
    transform: translateX(20px);
}

.filter-label {
    color: #ccc;
    font-size: 14px;
}

.noise-count {
    color: #888;
    font-size: 12px;
}

/* Noise row styling */
tr.noise-row {
    opacity: 0.5;
}

tr.noise-row.filtered {
    display: none;
}

/* Optional: subtle indicator when showing noise */
tr.noise-row td:first-child::before {
    content: "⚙ ";
    color: #666;
}
```

---

## JavaScript: Toggle Logic

```javascript
function toggleNoiseFilter() {
    const checkbox = document.getElementById('noiseFilter');
    const noiseRows = document.querySelectorAll('tr.noise-row');
    
    noiseRows.forEach(row => {
        row.classList.toggle('filtered', checkbox.checked);
    });
    
    updateNoiseCount();
}

function updateNoiseCount() {
    const noiseRows = document.querySelectorAll('tr.noise-row');
    const countSpan = document.getElementById('noiseCount');
    const count = noiseRows.length;
    
    if (count === 0) {
        countSpan.textContent = '';
    } else {
        countSpan.textContent = `(${count} hidden)`;
    }
}

// Initialize on page load
document.addEventListener('DOMContentLoaded', updateNoiseCount);
```

---

## Design Principles

1. **User-initiated changes always visible** - Only filter when `CallerType -eq 'Application'`
2. **Transparency** - Show count of hidden items; allow toggle to reveal all
3. **Paired detection catches unknown extensions** - Create/delete within 10 minutes from Application principal
4. **Extensible** - Easy to add new noisy extensions to the list

## Future Enhancements

- Separate toggles for different noise categories (extensions, backups, policy)
- "First seen" exception: show new extension installations even if automated
- Persist toggle state in localStorage
