# Update-ControlDefinitions.ps1
# Script to add description and Tenable references to all controls in ControlDefinitions.json

$controlDefPath = Join-Path $PSScriptRoot "Config\ControlDefinitions.json"

if (-not (Test-Path $controlDefPath)) {
    Write-Error "ControlDefinitions.json not found at: $controlDefPath"
    exit 1
}

Write-Host "Reading ControlDefinitions.json..." -ForegroundColor Cyan
$json = Get-Content $controlDefPath -Raw | ConvertFrom-Json

$updatedCount = 0
$controls = $json.controls

foreach ($control in $controls) {
    $needsUpdate = $false
    
    # Add description if missing (use businessImpact as base and expand)
    if (-not $control.description) {
        $control | Add-Member -MemberType NoteProperty -Name "description" -Value $null -Force
        $control.description = $control.businessImpact
        $needsUpdate = $true
    }
    
    # Ensure references array exists
    if (-not $control.references) {
        $control | Add-Member -MemberType NoteProperty -Name "references" -Value @() -Force
        $needsUpdate = $true
    }
    
    # Add CIS Workbench link if not present
    $hasCisWorkbench = $false
    if ($control.references) {
        foreach ($ref in $control.references) {
            if ($ref -match 'workbench\.cisecurity\.org') {
                $hasCisWorkbench = $true
                break
            }
        }
    }
    
    # Add Tenable link placeholder if control has a valid CIS control ID
    $hasTenable = $false
    if ($control.references) {
        foreach ($ref in $control.references) {
            if ($ref -match 'tenable\.com') {
                $hasTenable = $true
                break
            }
        }
    }
    
    # Build references array
    $references = @()
    if ($control.references) {
        $references = [System.Collections.ArrayList]@($control.references)
    }
    
    # Add CIS Workbench link if missing (generic link - can be updated with specific control)
    if (-not $hasCisWorkbench -and $control.controlId -ne "N/A") {
        $cisLink = "https://workbench.cisecurity.org/files/3459"
        $references.Add($cisLink) | Out-Null
        $needsUpdate = $true
    }
    
    # Add Tenable placeholder if missing and control has valid ID
    if (-not $hasTenable -and $control.controlId -ne "N/A") {
        # Placeholder - needs to be updated with actual Tenable hash
        $tenablePlaceholder = "https://www.tenable.com/audits/items/CIS_Microsoft_Azure_Foundations_L1_v1.3.1.audit:[TENABLE_HASH_FOR_$($control.controlId)]"
        Write-Host "  Control $($control.controlId) needs Tenable hash - placeholder added" -ForegroundColor Yellow
        $references.Add($tenablePlaceholder) | Out-Null
        $needsUpdate = $true
    }
    
    if ($needsUpdate) {
        $control.references = $references.ToArray()
        $updatedCount++
        Write-Host "  Updated: $($control.controlId) - $($control.controlName)" -ForegroundColor Green
    }
}

if ($updatedCount -gt 0) {
    Write-Host "`nSaving updated ControlDefinitions.json..." -ForegroundColor Cyan
    $json | ConvertTo-Json -Depth 20 | Set-Content $controlDefPath -Encoding UTF8
    Write-Host "Updated $updatedCount control(s)" -ForegroundColor Green
    Write-Host "`nNOTE: Tenable links with [TENABLE_HASH] placeholders need to be updated with actual hash values from Tenable." -ForegroundColor Yellow
} else {
    Write-Host "No updates needed." -ForegroundColor Green
}





