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
        timer, no queue, no orchestrator, no second code path to test.

        Changing an expiry date is an attribute update. It does not create a new
        secret version and it does not read the value, so it neither disturbs
        consumers nor pollutes the audit trail this function depends on.

    .PARAMETER GracePeriodHours
        How long the reader keeps working credentials. Eight hours covers a working
        day. Note that a password change does not end an established RDP session, but
        it does break reconnects, UAC elevation and anything that re-authenticates.

    .OUTPUTS
        PSCustomObject per secret whose expiry was moved.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$WorkspaceId,

        [ValidateRange(0, 168)][int]$GracePeriodHours = 8,
        [ValidateRange(1, 720)][int]$LookbackHours = 24,
        [string[]]$ExcludeObjectId = @(),
        [string]$HoldTagName = 'CredentialRotationHold'
    )

    $accessed = Get-AccessedSecret -WorkspaceId $WorkspaceId -VaultName $VaultName `
        -LookbackHours $LookbackHours -ExcludeObjectId $ExcludeObjectId

    if ($accessed.Count -eq 0) {
        Write-RotationLog -Message 'No human secret reads in the lookback window' -Level Info -Scope 'access'
        return @()
    }

    $now = (Get-Date).ToUniversalTime()
    $deadline = $now.AddHours($GracePeriodHours)
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in $accessed) {
        # Staging secrets are read by this tool itself during recovery; never treat
        # them as user access.
        if ($entry.SecretName -like '*-pending') { continue }

        $meta = Get-RotationSecret -VaultName $VaultName -Name $entry.SecretName
        if (-not $meta.Exists) { continue }

        if ($meta.Secret.Tags -and $meta.Secret.Tags[$HoldTagName] -eq 'true') {
            Write-RotationLog -Message "'$($entry.SecretName)' was read by $($entry.AccessedBy) but is on hold, leaving expiry untouched" -Level Warning -Scope 'access'
            continue
        }

        $currentExpiry = if ($meta.Secret.Expires) { $meta.Secret.Expires.ToUniversalTime() } else { $null }

        # Never push an expiry date further out than it already is.
        if ($currentExpiry -and $currentExpiry -le $deadline) {
            Write-RotationLog -Message "'$($entry.SecretName)' already expires at $($currentExpiry.ToString('u')), no change" -Level Info -Scope 'access'
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($entry.SecretName, "Bring expiry forward to $($deadline.ToString('u'))")) {
            $results.Add([pscustomobject]@{
                SecretName = $entry.SecretName
                AccessedBy = $entry.AccessedBy
                NewExpiry  = $deadline
                Applied    = $false
            })
            continue
        }

        $tags = @{}
        if ($meta.Secret.Tags) { $meta.Secret.Tags.GetEnumerator() | ForEach-Object { $tags[$_.Key] = $_.Value } }
        $tags['LastAccessedBy'] = $entry.AccessedBy
        $tags['LastAccessedAt'] = $entry.LastAccessedAt.ToString('o')
        $tags['RotationReason'] = 'Access'

        $null = Update-AzKeyVaultSecret -VaultName $VaultName -Name $entry.SecretName `
            -Expires $deadline -Tag $tags -ErrorAction Stop

        Write-RotationLog -Message "'$($entry.SecretName)' was read by $($entry.AccessedBy), expiry moved to $($deadline.ToString('u'))" -Level Success -Scope 'access'

        $results.Add([pscustomobject]@{
            SecretName = $entry.SecretName
            AccessedBy = $entry.AccessedBy
            NewExpiry  = $deadline
            Applied    = $true
        })
    }

    return $results.ToArray()
}
