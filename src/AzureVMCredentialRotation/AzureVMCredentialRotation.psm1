# AzureVMCredentialRotation module loader.
#
# Functions live in Public/ and Private/ as one file each. Azure Automation runs one
# script per job, so the runbook either imports this module from the Gallery (the Bicep
# path) or runs the flattened build from build/Build-Runbook.ps1 (the Terraform path).

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
