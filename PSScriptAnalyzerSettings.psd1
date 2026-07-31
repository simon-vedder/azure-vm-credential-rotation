<#
    PSScriptAnalyzer configuration.

    Rules are excluded only with a reason. If you add one, add the reason with it.
#>
@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # The generated and staged credentials are created in memory and never read
        # from disk, so there is no encrypted standard string to convert from. The
        # rule assumes a plaintext secret was already sitting somewhere; here the
        # SecureString is the first form the value ever takes.
        'PSAvoidUsingConvertToSecureStringWithPlainText'

        # Fires on any parameter whose name contains "Credential". Ours is
        # $CredentialType, a discriminator with values Password and SSHKey - not a
        # secret. Renaming it to satisfy a substring match would make the code worse.
        'PSAvoidUsingPlainTextForPassword'

        # Fires on the New-* verb. New-RotationPassword, New-RotationSshKeyPair and
        # New-RotationRecord build in-memory objects and change nothing outside the
        # process. The functions that do change state - Update-VMCredential,
        # Register-CredentialAccess, Invoke-CredentialRotation - all implement
        # ShouldProcess.
        'PSUseShouldProcessForStateChangingFunctions'

        # The usual advice is Write-Output, and it is wrong here in both places this
        # appears.
        #
        # In the runbook, Write-Output writes to the success stream, so every log line
        # emitted inside a function becomes part of that function's return value. Our
        # own tests caught this: Get-AccessedSecret returned one log line plus its
        # results, and the caller counted them as data. Write-Host goes to the
        # information stream, which Azure Automation still surfaces in the job output,
        # without touching the pipeline.
        #
        # In build/Build-Runbook.ps1 it is deliberate console feedback from a
        # command-line tool, which is exactly what Write-Host is for.
        'PSAvoidUsingWriteHost'
    )
}
