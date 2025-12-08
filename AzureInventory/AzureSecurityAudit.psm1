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


