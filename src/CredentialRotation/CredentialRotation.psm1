# CredentialRotation module loader.
#
# Functions live in Public/ and Private/ as one file each. The build script in
# build/Build-Runbook.ps1 flattens them into a single runbook file, because
# Azure Automation runs one script per job and cannot import a module that is
# not published to a gallery or uploaded as a module asset.

$public = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -ErrorAction SilentlyContinue)
$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in @($private + $public)) {
    try {
        . $file.FullName
    }
    catch {
        throw "Failed to import $($file.FullName): $_"
    }
}

Export-ModuleMember -Function $public.BaseName
