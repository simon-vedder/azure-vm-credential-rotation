@{
    RootModule        = 'AzureVMCredentialRotation.psm1'
    ModuleVersion     = '0.3.0'
    GUID              = 'b3f1c2d4-5e6a-4b7c-8d9e-0a1b2c3d4e5f'
    Author            = 'Simon Vedder'
    Description       = 'Credential lifecycle for Azure VMs that cannot use Windows LAPS or Entra login. Rotates local admin passwords and SSH keys, driven by Key Vault expiry dates.'
    PowerShellVersion = '7.2'
    CompatiblePSEditions = @('Core')

    RequiredModules   = @(
        'Az.Accounts'
        'Az.Compute'
        'Az.KeyVault'
        'Az.Resources'
    )

    FunctionsToExport = @(
        'Invoke-CredentialRotation'
        'Get-RotationCandidate'
        'Update-VMCredential'
        'Register-CredentialAccess'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags       = @('Azure', 'KeyVault', 'Security', 'Rotation', 'Automation')
            LicenseUri = 'https://github.com/simon-vedder/azure-vm-credential-rotation/blob/main/LICENSE'
            ProjectUri = 'https://github.com/simon-vedder/azure-vm-credential-rotation'
        }
    }
}
