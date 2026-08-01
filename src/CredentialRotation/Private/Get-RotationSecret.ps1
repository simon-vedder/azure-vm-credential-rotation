function Get-RotationSecret {
    <#
    .SYNOPSIS
        Reads secret metadata, distinguishing "does not exist" from "cannot read".

    .DESCRIPTION
        This distinction is the single most important piece of error handling in the
        project. Get-AzKeyVaultSecret returns $null when a secret is absent and
        throws when the call itself fails - a denied role assignment, throttling, a
        firewall, a transient network fault.

        Treating both as "no secret, therefore rotate" is how you end up changing a
        VM password and then failing to store it. This function returns Exists=$false
        only for a genuine absence and rethrows everything else, so a permissions
        problem surfaces as a failure instead of a rotation.

        Note that -IncludeVersions is not used: metadata is enough to decide, and not
        reading the value keeps this call out of the SecretGet audit trail that the
        access-triggered rotation depends on.

        A disabled secret is a third case, and it is not obvious: Key Vault answers a
        read with 403 "Operation get is not allowed on a disabled secret". That looks
        exactly like a permissions failure, so without special handling a single
        disabled secret anywhere in the vault aborts discovery for the whole
        subscription - which is precisely what happened on a live run.

    .OUTPUTS
        PSCustomObject with Exists, Disabled and Secret (the Key Vault secret, or $null).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$Name
    )

    try {
        $secret = Get-AzKeyVaultSecret -VaultName $VaultName -Name $Name -ErrorAction Stop

        return [pscustomobject]@{
            Exists   = $null -ne $secret
            Disabled = $false
            Secret   = $secret
        }
    }
    catch {
        # Az surfaces a missing secret as $null, but be explicit in case a future
        # version starts throwing: only a genuine 404 counts as absent.
        $isNotFound = $_.Exception.Message -match 'SecretNotFound' -or
                      $_.Exception.Response.StatusCode -eq 404

        if ($isNotFound) {
            return [pscustomobject]@{ Exists = $false; Disabled = $false; Secret = $null }
        }

        # Disabled: the secret exists but cannot be read. Not a permissions problem,
        # and not a reason to stop.
        if ($_.Exception.Message -match 'disabled secret') {
            return [pscustomobject]@{ Exists = $true; Disabled = $true; Secret = $null }
        }

        throw "Cannot read secret metadata '$Name' from vault '$VaultName'. Refusing to treat this as a missing secret. $($_.Exception.Message)"
    }
}
