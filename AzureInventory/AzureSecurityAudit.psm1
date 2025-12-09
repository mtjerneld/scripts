#
# AzureSecurityAudit.psm1
# Root module that dot-sources all functions
#

$ModuleRoot = $PSScriptRoot

# Dot-source all private helper functions
Get-ChildItem -Path "$ModuleRoot\Private\Helpers\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
    . $_.FullName
}

# Dot-source all scanner functions
Get-ChildItem -Path "$ModuleRoot\Private\Scanners\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
    . $_.FullName
}

# Dot-source all collector functions
$collectorFiles = Get-ChildItem -Path "$ModuleRoot\Private\Collectors\*.ps1" -ErrorAction SilentlyContinue
if ($collectorFiles) {
    Write-Verbose "Loading $($collectorFiles.Count) collector function(s)..."
    $collectorFiles | ForEach-Object {
        Write-Verbose "  Loading: $($_.Name)"
        . $_.FullName
    }
} else {
    Write-Verbose "No collector functions found in $ModuleRoot\Private\Collectors\"
}

# Dot-source all config functions
Get-ChildItem -Path "$ModuleRoot\Private\Config\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
    . $_.FullName
}

# Dot-source all public functions
Get-ChildItem -Path "$ModuleRoot\Public\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
    . $_.FullName
}

# Export module members
Export-ModuleMember -Function (Get-ChildItem -Path "$ModuleRoot\Public\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) })


