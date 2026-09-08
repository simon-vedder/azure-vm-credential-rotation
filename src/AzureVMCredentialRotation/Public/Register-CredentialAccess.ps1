function Register-CredentialAccess {
    <#
    .SYNOPSIS
        Brings the expiry date forward for secrets a human has read.

    .DESCRIPTION
        Rotation after use, without a second execution path.

        A credential that someone has read is spent. It has been in a clipboard, a
        terminal scrollback, an RDP client, possibly a screen share or a ticket. The
        useful response is to replace it soon - but not instantly, because the person
        who read it is usually still using it.

        Rather than schedule a delayed job, this writes the deadline where the system
        already looks: the secret's expiry date. Set it to now plus the grace period,
        and the next scheduled run treats it as any other near-expiry secret. No
        timer, no queue, no second code path to test.

        Who read what is the caller's finding, not this function's. It takes a secret
        name and a reader and acts; the orchestrator gets those from the Key Vault
        audit log in Log Analytics (queries/accessed-secrets.kql) and pipes them in.
        That keeps the module free of any workspace dependency, and lets a different
        orchestrator learn about reads however it likes.

        Changing an expiry date is an attribute update. It does not create a new
        secret version and it does not read the value, so it neither disturbs
        consumers nor pollutes the audit trail this function depends on.

    .PARAMETER SecretName
        The secret that was read. Accepts pipeline input by property name, so the
        result of the audit-log query pipes straight in.

    .PARAMETER AccessedBy
        Who read it. Recorded on the secret so the audit trail can say.

    .PARAMETER AccessedAt
        When. Defaults to now; the query supplies LastAccessedAt, which is accepted.

    .PARAMETER GracePeriodHours
        How long the reader keeps working credentials. Eight hours covers a working
        day. Note that a password change does not end an established RDP session, but
        it does break reconnects, UAC elevation and anything that re-authenticates.

    .EXAMPLE
        Register-CredentialAccess -VaultName kv -SecretName vm01-azureuser-pw -AccessedBy alice@contoso.com

    .EXAMPLE
        $reads | Register-CredentialAccess -VaultName kv -GracePeriodHours 8 -WhatIf

        Whatever produced $reads - the KQL in queries/, a SIEM export, a ticket - as
        long as each object carries SecretName and AccessedBy.

    .OUTPUTS
        PSCustomObject per secret, saying whether its expiry was moved.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VaultName,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][string]$SecretName,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()][string]$AccessedBy,

        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('LastAccessedAt')]
        [datetime]$AccessedAt = (Get-Date).ToUniversalTime(),

        [ValidateRange(0, 168)][int]$GracePeriodHours = 8
    )

    begin {
        $deadline = (Get-Date).ToUniversalTime().AddHours($GracePeriodHours)
    }

    process {
        $outcome = [pscustomobject]@{
            SecretName = $SecretName
            AccessedBy = $AccessedBy
            NewExpiry  = $deadline
            Applied    = $false
        }

        # Staging secrets are read by this tool itself during recovery; never treat
        # them as user access.
        if ($SecretName -like '*-pending') { return }

        $meta = Get-RotationSecret -VaultName $VaultName -Name $SecretName
        if (-not $meta.Exists) {
            Write-RotationLog -Message "'$SecretName' was read but does not exist in the vault, nothing to move" -Level Info -Scope 'access'
            return
        }

        $currentExpiry = if ($meta.Secret.Expires) { $meta.Secret.Expires.ToUniversalTime() } else { $null }

        # Never push an expiry date further out than it already is.
        if ($currentExpiry -and $currentExpiry -le $deadline) {
            Write-RotationLog -Message "'$SecretName' already expires at $($currentExpiry.ToString('u')), no change" -Level Info -Scope 'access'
            return $outcome
        }

        if (-not $PSCmdlet.ShouldProcess($SecretName, "Bring expiry forward to $($deadline.ToString('u'))")) {
            return $outcome
        }

        $tags = @{}
        if ($meta.Secret.Tags) { $meta.Secret.Tags.GetEnumerator() | ForEach-Object { $tags[$_.Key] = $_.Value } }
        $tags['LastAccessedBy'] = $AccessedBy
        $tags['LastAccessedAt'] = $AccessedAt.ToUniversalTime().ToString('o')
        $tags['RotationReason'] = 'Access'

        $null = Update-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName `
            -Expires $deadline -Tag $tags -ErrorAction Stop

        Write-RotationLog -Message "'$SecretName' was read by $AccessedBy, expiry moved to $($deadline.ToString('u'))" -Level Success -Scope 'access'

        $outcome.Applied = $true
        return $outcome
    }
}
