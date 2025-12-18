# Update-AllControlDefinitions.ps1
# Script to add description and improve references for all controls

$controlDefPath = Join-Path $PSScriptRoot "Config\ControlDefinitions.json"

if (-not (Test-Path $controlDefPath)) {
    Write-Error "ControlDefinitions.json not found at: $controlDefPath"
    exit 1
}

Write-Host "Reading ControlDefinitions.json..." -ForegroundColor Cyan
$jsonContent = Get-Content $controlDefPath -Raw
$json = $jsonContent | ConvertFrom-Json

$controls = $json.controls
$updatedCount = 0

Write-Host "Processing $($controls.Count) controls..." -ForegroundColor Cyan

foreach ($control in $controls) {
    $needsUpdate = $false
    
    # Add description if missing (expand businessImpact)
    if (-not $control.PSObject.Properties.Name -contains 'description' -or [string]::IsNullOrWhiteSpace($control.description)) {
        # Use businessImpact as base for description
        $description = $control.businessImpact
        if ([string]::IsNullOrWhiteSpace($description)) {
            $description = "Security control: $($control.controlName)"
        }
        
        # Add more context based on control type
        if ($control.controlId -ne "N/A") {
            $description = "$description This control is part of the CIS Microsoft Azure Foundations Benchmark."
        }
        
        $control | Add-Member -MemberType NoteProperty -Name "description" -Value $description -Force
        $needsUpdate = $true
    }
    
    # Ensure references array exists
    if (-not $control.PSObject.Properties.Name -contains 'references') {
        $control | Add-Member -MemberType NoteProperty -Name "references" -Value @() -Force
        $needsUpdate = $true
    }
    
    # Convert references to ArrayList for easier manipulation
    $refList = [System.Collections.ArrayList]@()
    if ($control.references) {
        foreach ($ref in $control.references) {
            $refList.Add($ref) | Out-Null
        }
    }
    
    # Check for existing links
    $hasCisWorkbench = $false
    $hasTenable = $false
    foreach ($ref in $refList) {
        if ($ref -match 'workbench\.cisecurity\.org') {
            $hasCisWorkbench = $true
        }
        if ($ref -match 'tenable\.com') {
            $hasTenable = $true
        }
    }
    
    # Add CIS Workbench link if missing (for controls with valid CIS IDs)
    if (-not $hasCisWorkbench -and $control.controlId -ne "N/A") {
        $refList.Add("https://workbench.cisecurity.org/files/3459") | Out-Null
        $needsUpdate = $true
    }
    
    # Add Tenable placeholder if missing (for controls with valid CIS IDs)
    # NOTE: These need to be updated with actual Tenable hash values
    if (-not $hasTenable -and $control.controlId -ne "N/A") {
        # Placeholder - user needs to update with actual Tenable hash
        $tenablePlaceholder = "https://www.tenable.com/audits/items/CIS_Microsoft_Azure_Foundations_L1_v1.3.1.audit:[UPDATE_WITH_TENABLE_HASH_FOR_$($control.controlId)]"
        $refList.Add($tenablePlaceholder) | Out-Null
        $needsUpdate = $true
        Write-Host "  Added Tenable placeholder for control $($control.controlId)" -ForegroundColor Yellow
    }
    
    if ($needsUpdate) {
        $control.references = $refList.ToArray()
        $updatedCount++
    }
}

if ($updatedCount -gt 0) {
    Write-Host "`nSaving updated ControlDefinitions.json..." -ForegroundColor Cyan
    # Convert back to JSON with proper formatting
    $json | ConvertTo-Json -Depth 20 | Set-Content $controlDefPath -Encoding UTF8
    Write-Host "Updated $updatedCount control(s)" -ForegroundColor Green
    Write-Host "`nIMPORTANT: Update Tenable links with [UPDATE_WITH_TENABLE_HASH] placeholders" -ForegroundColor Yellow
    Write-Host "  Find actual Tenable hashes at: https://www.tenable.com/audits" -ForegroundColor Cyan
} else {
    Write-Host "No updates needed - all controls already have description and references." -ForegroundColor Green
}






