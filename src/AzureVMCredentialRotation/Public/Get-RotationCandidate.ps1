function Get-RotationCandidate {
    <#
    .SYNOPSIS
        Finds the credentials that need rotating.

    .DESCRIPTION
        Opt-in, not opt-out. A VM is only considered when it carries the enable tag.

        This is the difference between a tool and an incident. A discovery loop that
        treats "no secret exists for this VM" as "rotate it" will, on its first run
        in an established tenant, change the local administrator password of every
        machine it can see - including the ones whose credentials live in a CMDB or a
        password manager that nobody told it about.

        Rotation is triggered by one of five conditions:

          ResumePending - a previous run was interrupted after staging a value
          Missing       - no secret yet, or a secret with no expiry date
          Expiry        - the expiry date is within the threshold
          Access        - not detected here; access pulls the expiry date forward,
                          and this function then sees it as Expiry
          Manual        - a VM was named explicitly through -VM, so it is rotated
                          whatever its expiry date says

    .PARAMETER VM
        Rotate these VMs instead of discovering tagged ones. Naming a machine is a
        stronger statement of intent than a tag, so the enable tag is not required and
        the expiry threshold does not apply - the reason becomes Manual. The hold tag
        still applies, because it means somebody is working on that machine.

    .PARAMETER IgnoreHold
        Rotate even a VM carrying the hold tag. Only meaningful with -VM: a scheduled
        run must never talk itself out of a hold.

        The last point is the design in one sentence: the expiry date is the only
        signal. Everything else writes to it.

    .OUTPUTS
        PSCustomObject with VM, CredentialType, Reason, SecretName, ExpiresOn.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VaultName,

        # Explicit machines instead of tag discovery. See the note on -VM in the help.
        [ValidateNotNullOrEmpty()][object[]]$VM,

        [switch]$IgnoreHold,

        [ValidateRange(0, 3650)][int]$ThresholdDays = 14,

        [string]$EnableTagName = 'CredentialRotation',
        [string]$EnableTagValue = 'enabled',
        [string]$HoldTagName = 'CredentialRotationHold',

        # Linux VMs get an SSH key rotated unless this is set.
        [switch]$SkipSshKeys
    )

    $candidates = [System.Collections.Generic.List[object]]::new()
    $now = (Get-Date).ToUniversalTime()

    # Named machines skip discovery entirely. The tag exists to stop a scheduled run
    # reaching further than intended; it has nothing to protect when a person types the name.
    $explicit = $PSBoundParameters.ContainsKey('VM')

    $vms = if ($explicit) {
        @($VM)
    }
    else {
        @(Get-AzVM -ErrorAction Stop | Where-Object {
            $_.Tags -and
            $_.Tags.ContainsKey($EnableTagName) -and
            $_.Tags[$EnableTagName] -eq $EnableTagValue
        })
    }

    if ($explicit) {
        Write-RotationLog -Message "$($vms.Count) VM(s) named explicitly, tag discovery skipped" -Level Info -Scope 'discovery'
    }
    else {
        Write-RotationLog -Message "$($vms.Count) VM(s) tagged $EnableTagName=$EnableTagValue in this subscription" -Level Info -Scope 'discovery'
    }

    foreach ($vm in $vms) {
        if ($vm.Tags -and $vm.Tags.ContainsKey($HoldTagName) -and $vm.Tags[$HoldTagName] -eq 'true') {
            if (-not $IgnoreHold) {
                Write-RotationLog -Message "On hold via $HoldTagName, skipping" -Level Warning -Scope $vm.Name
                continue
            }
            Write-RotationLog -Message "On hold via $HoldTagName, overridden by -IgnoreHold" -Level Warning -Scope $vm.Name
        }

        $adminUsername = $vm.OSProfile.AdminUsername
        if ([string]::IsNullOrWhiteSpace($adminUsername)) {
            Write-RotationLog -Message 'No admin username in the OS profile (specialised image?), skipping' -Level Warning -Scope $vm.Name
            continue
        }

        $osType = [string]$vm.StorageProfile.OsDisk.OsType
        $types = [System.Collections.Generic.List[string]]::new()

        if ($osType -eq 'Windows') {
            $types.Add('Password')
        }
        elseif ($osType -eq 'Linux') {
            $passwordAuthEnabled = -not $vm.OSProfile.LinuxConfiguration.DisablePasswordAuthentication
            if ($passwordAuthEnabled) { $types.Add('Password') }
            if (-not $SkipSshKeys) { $types.Add('SSHKey') }
        }
        else {
            Write-RotationLog -Message "Unknown OS type '$osType', skipping" -Level Warning -Scope $vm.Name
            continue
        }

        foreach ($type in $types) {
            $kind = if ($type -eq 'Password') { 'pw' } else { 'ssh-priv' }
            $secretName = Resolve-SecretName -VMName $vm.Name -AdminUsername $adminUsername -Kind $kind
            $pendingName = Resolve-SecretName -VMName $vm.Name -AdminUsername $adminUsername -Kind $kind -Pending

            $reason = $null
            $expiresOn = $null

            $pending = Get-RotationSecret -VaultName $VaultName -Name $pendingName
            $isPendingOpen = $pending.Exists -and
                             $pending.Secret.Tags.State -eq 'pending' -and
                             $pending.Secret.Enabled -ne $false

            if ($isPendingOpen) {
                $reason = 'ResumePending'
            }
            else {
                $secret = Get-RotationSecret -VaultName $VaultName -Name $secretName

                if (-not $secret.Exists) {
                    $reason = 'Missing'
                }
                elseif ($secret.Secret.Tags -and $secret.Secret.Tags[$HoldTagName] -eq 'true' -and -not $IgnoreHold) {
                    Write-RotationLog -Message "Secret '$secretName' is on hold, skipping" -Level Warning -Scope $vm.Name
                    continue
                }
                elseif ($null -eq $secret.Secret.Expires) {
                    $reason = 'Missing'
                    Write-RotationLog -Message "Secret '$secretName' has no expiry date" -Level Warning -Scope $vm.Name
                }
                elseif ($explicit) {
                    # Named on the command line: rotate it, whatever the expiry says. Anything
                    # else would silently do nothing for a machine somebody asked about.
                    $expiresOn = $secret.Secret.Expires.ToUniversalTime()
                    $reason = 'Manual'
                }
                else {
                    $expiresOn = $secret.Secret.Expires.ToUniversalTime()
                    if (($expiresOn - $now).TotalDays -le $ThresholdDays) {
                        # Access-driven rotation works by pulling the expiry date
                        # forward, so by the time it gets here it is indistinguishable
                        # from ordinary ageing. Register-CredentialAccess leaves a tag
                        # behind precisely so the audit record can still say which of
                        # the two it was - without it, the workbook cannot answer
                        # "was this replaced because someone read it, or because it
                        # got old", which is most of the point of keeping records.
                        $reason = if ($secret.Secret.Tags -and $secret.Secret.Tags['RotationReason'] -eq 'Access') {
                            'Access'
                        }
                        else { 'Expiry' }
                    }
                }
            }

            if (-not $reason) { continue }

            $candidates.Add([pscustomobject]@{
                VM             = $vm
                CredentialType = $type
                Reason         = $reason
                SecretName     = $secretName
                ExpiresOn      = $expiresOn
            })
        }
    }

    return $candidates.ToArray()
}
