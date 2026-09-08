function Get-RotationCandidate {
    <#
    .SYNOPSIS
        Works out which credentials on the given machines need rotating.

    .DESCRIPTION
        The caller states the machines. This function never searches for them, never
        reads a tag and has no opinion about which machines belong in scope - that is
        the orchestrator's job, and keeping it there is what lets the same module run
        from a workstation against one machine and from a runbook against a fleet.

        What it does decide is whether a machine the caller already chose actually has
        something to rotate. Rotation is triggered by one of five conditions:

          ResumePending - a previous run was interrupted after staging a value
          Missing       - no secret yet, or a secret with no expiry date
          Expiry        - the expiry date is within the threshold
          Access        - not detected here; access pulls the expiry date forward,
                          and this function then sees it as Expiry
          Manual        - nothing else applied, so the credential is replaced because
                          the caller asked for this machine

        Access is the one worth reading twice, because it is the design in one sentence:
        the expiry date is the only signal, and everything else writes to it.

    .PARAMETER VaultName
        The Key Vault holding the credentials. Only read here: this function decides what
        is due, it never writes.

    .PARAMETER VM
        The machines to examine. Objects from Get-AzVM, fetched by the caller.

    .PARAMETER OnlyIfDue
        Consult the expiry date instead of rotating regardless. Without it every machine
        handed in is a candidate, which is what asking for a machine means. A scheduled
        pass sets it, so it touches only what is missing, half-rotated or near expiry.

    .PARAMETER ThresholdDays
        How close to expiry counts as due. Only consulted with -OnlyIfDue.

    .PARAMETER SkipSshKeys
        Leaves SSH keys out of the answer. Without it a Linux machine yields a key
        candidate as well as a password one.

    .PARAMETER SecretNameTemplate
        How secret names are built from {vm}, {user}, {rg} and {kind}. Must match what was
        used when the secrets were written, or nothing will be found.

    .EXAMPLE
        Get-RotationCandidate -VaultName kv-creds -VM (Get-AzVM -ResourceGroupName rg-dmz)

        Every credential on every machine in that resource group, because asking for a
        machine is itself the reason to rotate it. Reason comes back as Manual.

    .EXAMPLE
        Get-RotationCandidate -VaultName kv-creds -VM $vms -OnlyIfDue -ThresholdDays 14

        What a scheduled pass asks: only what is missing, half-rotated or within
        fourteen days of expiry. Reason distinguishes Missing, Expiry and ResumePending.

    .EXAMPLE
        Get-RotationCandidate -VaultName kv-creds -VM $vms -OnlyIfDue |
            Format-Table VM, CredentialType, Reason, ExpiresOn

        Dry inspection before a first run over an estate. Nothing is changed by asking,
        so this is the cheapest way to see how much work the next rotation would be.

    .OUTPUTS
        PSCustomObject with VM, CredentialType, Reason, SecretName, ExpiresOn.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VaultName,

        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object[]]$VM,

        [switch]$OnlyIfDue,

        # Only consulted with -OnlyIfDue.
        [ValidateRange(0, 3650)][int]$ThresholdDays = 14,

        # Linux VMs get an SSH key rotated unless this is set.
        [switch]$SkipSshKeys,

        [ValidateNotNullOrEmpty()][string]$SecretNameTemplate = '{vm}-{user}-{kind}'
    )

    $candidates = [System.Collections.Generic.List[object]]::new()
    $now = (Get-Date).ToUniversalTime()

    $vms = @($VM)
    Write-RotationLog -Message "$($vms.Count) machine(s) handed in by the caller" -Level Info -Scope 'discovery'

    foreach ($vm in $vms) {
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
            $secretName = Resolve-SecretName -VMName $vm.Name -AdminUsername $adminUsername -Kind $kind -ResourceGroupName $vm.ResourceGroupName -Template $SecretNameTemplate
            $pendingName = Resolve-SecretName -VMName $vm.Name -AdminUsername $adminUsername -Kind $kind -ResourceGroupName $vm.ResourceGroupName -Pending -Template $SecretNameTemplate

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
                elseif ($null -eq $secret.Secret.Expires) {
                    $reason = 'Missing'
                    Write-RotationLog -Message "Secret '$secretName' has no expiry date" -Level Warning -Scope $vm.Name
                }
                elseif (-not $OnlyIfDue) {
                    # The caller handed this machine over. Doing nothing because the date is
                    # comfortable would be the wrong answer to a direct request.
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
