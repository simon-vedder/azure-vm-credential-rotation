function Update-VMCredential {
    <#
    .SYNOPSIS
        Rotates one credential on one VM and stores it in Key Vault.

    .DESCRIPTION
        Write order is the point of this function.

        The naive order is: change the VM, then store the new value. If the Key Vault
        write then fails - throttling, a role assignment that expired, a firewall
        rule - the machine has a password nobody knows. That is unrecoverable without
        a serial console or a disk swap.

        This function stages the value first, in a separate secret named
        "<name>-pending":

            1. write the new value to <name>-pending, tagged State=pending
            2. apply it to the VM through the VMAccess extension
            3. write it to <name> with the real expiry
            4. overwrite <name>-pending with a placeholder, tagged State=consumed

        Any crash leaves the value recoverable. If the run dies between 2 and 3, the
        next run finds an open pending secret, reapplies the same value to the VM
        (idempotent) and promotes it. Callers see <name> only ever holding a value
        the VM has actually accepted.

        The staging secret is overwritten rather than deleted or disabled - see
        Close-PendingCredential for why both of those fail against a real vault.

    .PARAMETER VaultName
        The Key Vault the new value is written to. Written before the machine is touched,
        which is the whole point of the order above.

    .PARAMETER VM
        The machine to change, as an object from Get-AzVM. One machine, not a list: the
        fan-out belongs to Invoke-CredentialRotation.

    .PARAMETER CredentialType
        Password for the local administrator account, or SSHKey for a new key pair on a
        Linux machine. One credential per call, so a machine with both is two calls.

    .PARAMETER ValidityDays
        How far ahead the new secret's expiry date is set. That date is the only thing
        that brings the credential back for rotation, so it is the rotation interval in
        everything but name. Note that a STIG-hardened Linux image enforces a shorter
        maximum password age than the ninety-day default.

    .PARAMETER TriggerReason
        Why this rotation is happening, recorded on the run. Get-RotationCandidate works
        it out; pass it through rather than inventing one, or the audit trail stops
        matching what actually drove the change.

    .PARAMETER TriggeredBy
        Who or what asked for it - a runbook job id, a person, a change ticket. Free text,
        recorded verbatim, never interpreted.

    .PARAMETER SecretNameTemplate
        How the secret name is built from {vm}, {user}, {rg} and {kind}. Must match what
        was used when the secret was written, or this call stages a new secret beside the
        real one instead of replacing it.

    .PARAMETER RemovePriorSshKeys
        Defaults to false, deliberately. The VMAccess extension can wipe every entry
        in authorized_keys, which takes out colleagues, configuration management and
        backup agents along with the key you meant to replace. Turn it on only if you
        are certain this tool owns every key on the machine.

    .PARAMETER ResetSshConfiguration
        Defaults to false, deliberately. VMAccess can restore sshd configuration to
        its default, which silently undoes hardening on a CIS-baselined host.

    .EXAMPLE
        $vm = Get-AzVM -ResourceGroupName rg-dmz -Name jump-01
        Update-VMCredential -VaultName kv-creds -VM $vm -CredentialType Password -WhatIf

        What one rotation would do, without doing it. ShouldProcess is asked per
        credential, so a dry run over a fleet still reports every machine separately.

    .EXAMPLE
        $vm = Get-AzVM -ResourceGroupName rg-dmz -Name jump-01
        Update-VMCredential -VaultName kv-creds -VM $vm -CredentialType Password -Confirm:$false

        Replaces the local administrator password now and stores it with the default
        ninety-day expiry. ConfirmImpact is High, so without -Confirm:$false this prompts.

    .EXAMPLE
        Update-VMCredential -VaultName kv-creds -VM $linuxVm -CredentialType SSHKey -TriggerReason Access -TriggeredBy 'runbook:8f2c' -Confirm:$false

        A key replaced because somebody read the old one. The reason and the caller are
        recorded on the run; they change nothing about how the rotation is performed.

    .NOTES
        RequiredPermissions: Key Vault Secrets Officer on the vault, and Virtual Machine Contributor
        on the machine. The VM permission is needed because the new credential is applied through the
        VMAccess extension, which means extension installation rights on that machine.

    .OUTPUTS
        PSCustomObject describing the outcome.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][ValidateNotNull()]$VM,
        [Parameter(Mandatory)][ValidateSet('Password', 'SSHKey')][string]$CredentialType,

        [ValidateRange(1, 3650)][int]$ValidityDays = 90,
        [ValidateSet('Expiry', 'Access', 'Missing', 'Manual', 'ResumePending')][string]$TriggerReason = 'Expiry',
        [string]$TriggeredBy,

        [switch]$RemovePriorSshKeys,
        [switch]$ResetSshConfiguration,

        [ValidateNotNullOrEmpty()][string]$SecretNameTemplate = '{vm}-{user}-{kind}'
    )

    $startedAt = (Get-Date).ToUniversalTime()
    $adminUsername = $VM.OSProfile.AdminUsername
    $osType = [string]$VM.StorageProfile.OsDisk.OsType
    $subscriptionId = ($VM.Id -split '/')[2]

    if ([string]::IsNullOrWhiteSpace($adminUsername)) {
        throw "VM '$($VM.Name)' has no admin username in its OS profile. This happens with specialised images; such VMs must be excluded from rotation."
    }

    $kind = if ($CredentialType -eq 'Password') { 'pw' } else { 'ssh-priv' }
    $secretName = Resolve-SecretName -VMName $VM.Name -AdminUsername $adminUsername -Kind $kind -ResourceGroupName $VM.ResourceGroupName -Template $SecretNameTemplate
    $pendingName = Resolve-SecretName -VMName $VM.Name -AdminUsername $adminUsername -Kind $kind -ResourceGroupName $VM.ResourceGroupName -Pending -Template $SecretNameTemplate

    $record = @{
        SecretName        = $secretName
        VMName            = $VM.Name
        ResourceGroupName = $VM.ResourceGroupName
        SubscriptionId    = $subscriptionId
        OSType            = $osType
        CredentialType    = $CredentialType
        TriggerReason     = $TriggerReason
        TriggeredBy       = $TriggeredBy
        StartedAt         = $startedAt
    }

    $current = Get-RotationSecret -VaultName $VaultName -Name $secretName
    $previousVersion = if ($current.Exists) { $current.Secret.Version } else { $null }

    if (-not $PSCmdlet.ShouldProcess("$($VM.Name) ($CredentialType)", 'Rotate credential')) {
        Write-RotationLog -Message "Would rotate $CredentialType for $($VM.Name) [$TriggerReason]" -Level Info -Scope $VM.Name
        return New-RotationRecord @record -Result 'WhatIf' -PreviousSecretVersion $previousVersion -Detail 'WhatIf mode, no changes made'
    }

    if (-not (Test-VMRunning -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name)) {
        Write-RotationLog -Message "VM is not running, skipping. The next run will retry." -Level Warning -Scope $VM.Name
        return New-RotationRecord @record -Result 'Skipped' -PreviousSecretVersion $previousVersion -Detail 'VM not running'
    }

    # ---- 1. stage the value -------------------------------------------------
    $pending = Get-PendingCredential -VaultName $VaultName -PendingName $pendingName

    if ($pending.IsOpen) {
        Write-RotationLog -Message "Resuming an interrupted rotation from $($pending.CreatedAt)" -Level Warning -Scope $VM.Name
        $secretValue = $pending.Value
        $publicKey = if ($CredentialType -eq 'SSHKey') {
            ConvertFrom-PemToSshPublicKey -PrivateKeyPem $secretValue
        }
        else { $null }
    }
    else {
        if ($CredentialType -eq 'Password') {
            $secretValue = New-RotationPassword
            $publicKey = $null
        }
        else {
            $keyPair = New-RotationSshKeyPair
            $secretValue = $keyPair.PrivateKey
            $publicKey = $keyPair.PublicKey
        }

        # No public key here: Key Vault caps a tag value at 256 characters and an
        # ssh-rsa key is several times that. On resume it is derived from the staged
        # private key instead.
        $pendingTags = @{
            State     = 'pending'
            VMName    = $VM.Name
            AdminName = $adminUsername
            CreatedAt = $startedAt.ToString('o')
        }

        $null = Set-AzKeyVaultSecret -VaultName $VaultName -Name $pendingName `
            -SecretValue $secretValue `
            -Expires $startedAt.AddDays(1) `
            -Tag $pendingTags `
            -ErrorAction Stop

        Write-RotationLog -Message "Staged new $CredentialType in '$pendingName'" -Level Info -Scope $VM.Name
    }

    # ---- 2. apply it to the machine ----------------------------------------
    try {
        Set-VMAccessCredential -VM $VM -AdminUsername $adminUsername -OSType $osType `
            -CredentialType $CredentialType -SecretValue $secretValue -PublicKey $publicKey `
            -RemovePriorSshKeys:$RemovePriorSshKeys -ResetSshConfiguration:$ResetSshConfiguration

        Write-RotationLog -Message "VM accepted the new $CredentialType" -Level Success -Scope $VM.Name
    }
    catch {
        Write-RotationLog -Message "VM did not accept the new ${CredentialType}: $($_.Exception.Message)" -Level Error -Scope $VM.Name
        return New-RotationRecord @record -Result 'Failed' -PreviousSecretVersion $previousVersion `
            -Detail "VMAccess extension failed: $($_.Exception.Message). Staged value remains in '$pendingName'."
    }

    # ---- 3. promote ---------------------------------------------------------
    # Tags are replaced wholesale, which also clears RotationReason from a previous
    # access-driven cycle. Leaving it in place would make every later rotation of this
    # secret claim to have been triggered by a read.
    $tags = @{
        VMName         = $VM.Name
        AdminName      = $adminUsername
        OSType         = $osType
        CredentialType = $CredentialType
        LastRotated    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
        LastTrigger    = $TriggerReason
        RotatedBy      = 'azure-vm-credential-rotation'
    }

    $new = Set-AzKeyVaultSecret -VaultName $VaultName -Name $secretName `
        -SecretValue $secretValue `
        -Expires (Get-Date).ToUniversalTime().AddDays($ValidityDays) `
        -Tag $tags `
        -ErrorAction Stop

    # The public key is not secret, but keeping it beside the private key saves
    # anyone from having to derive it later.
    if ($CredentialType -eq 'SSHKey' -and $publicKey) {
        $publicName = Resolve-SecretName -VMName $VM.Name -AdminUsername $adminUsername -Kind 'ssh-pub' -ResourceGroupName $VM.ResourceGroupName -Template $SecretNameTemplate
        $null = Set-AzKeyVaultSecret -VaultName $VaultName -Name $publicName `
            -SecretValue (ConvertTo-SecureString -String $publicKey -AsPlainText -Force) `
            -Expires (Get-Date).ToUniversalTime().AddDays($ValidityDays) `
            -Tag $tags -ErrorAction Stop
    }

    # ---- 4. close the staging secret ---------------------------------------
    Close-PendingCredential -VaultName $VaultName -PendingName $pendingName

    Write-RotationLog -Message "Rotated $CredentialType, new version $($new.Version), expires in $ValidityDays days" -Level Success -Scope $VM.Name

    return New-RotationRecord @record -Result 'Rotated' `
        -PreviousSecretVersion $previousVersion -NewSecretVersion $new.Version
}

function Get-PendingCredential {
    <#
    .SYNOPSIS
        Returns the staged credential for a secret, if a rotation was interrupted.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$PendingName
    )

    $result = [pscustomobject]@{
        IsOpen    = $false
        Value     = $null
        Version   = $null
        CreatedAt = $null
    }

    $meta = Get-RotationSecret -VaultName $VaultName -Name $PendingName
    if (-not $meta.Exists) { return $result }
    if ($meta.Disabled) { return $result }
    if ($meta.Secret.Tags.State -ne 'pending') { return $result }

    # Reading the staged value is a SecretGet by the managed identity. It carries no
    # upn claim, so it never registers as human access.
    $full = Get-AzKeyVaultSecret -VaultName $VaultName -Name $PendingName -ErrorAction Stop

    $result.IsOpen = $true
    $result.Value = $full.SecretValue
    $result.Version = $meta.Secret.Version
    $result.CreatedAt = $meta.Secret.Tags.CreatedAt

    return $result
}

function Close-PendingCredential {
    <#
    .SYNOPSIS
        Marks a staged credential as consumed and removes its value.

    .DESCRIPTION
        Overwrites the staging secret with a placeholder rather than deleting or
        disabling it. All three options were tried against a real vault; only this one
        works:

          delete   Key Vault soft-delete reserves the name until it is purged, so the
                   next rotation fails writing to it. Purging needs another permission
                   and is irreversible.

          disable  reads then fail with "Operation get is not allowed on a disabled
                   secret" - a 403, indistinguishable at a glance from a missing role
                   assignment. Since the engine deliberately refuses to treat an
                   unreadable secret as absent, one disabled staging secret took down
                   discovery for the entire subscription.

          overwrite  the value is gone, the metadata stays readable, the name stays
                     usable. This one.

        The previous version still holds the credential, reachable only by explicit
        version id - but that is the same value now stored in the live secret, so it
        adds no exposure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$PendingName
    )

    try {
        $placeholder = ConvertTo-SecureString -String 'consumed' -AsPlainText -Force

        $null = Set-AzKeyVaultSecret -VaultName $VaultName -Name $PendingName `
            -SecretValue $placeholder `
            -Expires (Get-Date).ToUniversalTime().AddDays(1) `
            -Tag @{ State = 'consumed'; ConsumedAt = (Get-Date).ToUniversalTime().ToString('o') } `
            -ErrorAction Stop
    }
    catch {
        # The credential is safely in place at this point; a stale staging marker is
        # cosmetic and gets overwritten by the next rotation.
        Write-RotationLog -Message "Could not close staging secret '$PendingName': $($_.Exception.Message)" -Level Warning
    }
}

function Set-VMAccessCredential {
    <#
    .SYNOPSIS
        Applies a credential to a VM through the VMAccess extension.

    .DESCRIPTION
        Note what this does beyond changing a password: if the account named in the
        OS profile no longer exists on the machine, VMAccess recreates it as a local
        administrator. Someone may have removed or renamed that account on purpose.
        See docs/threat-model.md.

        Two hard-won details, both found on a live tenant and neither obvious:

        1. Settings are passed as JSON strings, not hashtables. Handing a hashtable to
           -ProtectedSettings works fine with a current Az module and fails inside an
           Azure Automation sandbox running an older one, where the extension receives
           a nested object and reports:

               Enable failed: crypt() argument 1 must be str, not dict

           The same call, same password, succeeded locally on Az.Accounts 5.5 and
           failed on the sandbox's 2.15. Serialising explicitly removes the module
           version from the equation entirely.

        2. On Linux the optional keys are omitted rather than sent as false, because
           the extension branches on whether a key is *present*, not on its value.

        The Linux extension is also picky about an absent settings object, so an empty
        one is always sent - matching what "az vm user update" does.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][string]$AdminUsername,
        [Parameter(Mandatory)][string]$OSType,
        [Parameter(Mandatory)][string]$CredentialType,
        [Parameter(Mandatory)][securestring]$SecretValue,
        [string]$PublicKey,
        [switch]$RemovePriorSshKeys,
        [switch]$ResetSshConfiguration
    )

    $common = @{
        ResourceGroupName = $VM.ResourceGroupName
        VMName            = $VM.Name
        Location          = $VM.Location
        ForceRerun        = (New-Guid).Guid
        ErrorAction       = 'Stop'
    }

    if ($OSType -eq 'Windows') {
        $plain = ConvertFrom-SecureString -SecureString $SecretValue -AsPlainText
        try {
            $null = Set-AzVMExtension @common `
                -Name 'VMAccessAgent' `
                -Publisher 'Microsoft.Compute' `
                -ExtensionType 'VMAccessAgent' `
                -TypeHandlerVersion '2.4' `
                -SettingString (ConvertTo-Json -InputObject @{ UserName = $AdminUsername } -Compress) `
                -ProtectedSettingString (ConvertTo-Json -InputObject @{ Password = $plain } -Compress)
        }
        finally {
            $plain = $null
            [System.GC]::Collect()
        }
        return
    }

    $protected = @{ username = $AdminUsername }

    if ($CredentialType -eq 'Password') {
        $plain = ConvertFrom-SecureString -SecureString $SecretValue -AsPlainText
        $protected['password'] = $plain
        # No reset_ssh here at all - see the note above.
    }
    else {
        if ([string]::IsNullOrWhiteSpace($PublicKey)) {
            throw 'SSH rotation requires a public key.'
        }
        $protected['ssh_key'] = $PublicKey

        # Present only when actually wanted, for the same reason.
        if ($ResetSshConfiguration) { $protected['reset_ssh'] = $true }
        if ($RemovePriorSshKeys) { $protected['remove_prior_keys'] = $true }
    }

    try {
        $null = Set-AzVMExtension @common `
            -Name 'VMAccessForLinux' `
            -Publisher 'Microsoft.OSTCExtensions' `
            -ExtensionType 'VMAccessForLinux' `
            -TypeHandlerVersion '1.5' `
            -SettingString '{}' `
            -ProtectedSettingString (ConvertTo-Json -InputObject $protected -Compress)
    }
    finally {
        $protected['password'] = $null
        $protected = $null
        $plain = $null
        [System.GC]::Collect()
    }
}
