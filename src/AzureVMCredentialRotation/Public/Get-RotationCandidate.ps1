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
          Manual        - -IgnoreExpiry was set, so a healthy credential is replaced
                          anyway

    .PARAMETER VM
        The machines to examine. Objects from Get-AzVM, fetched by the caller.

    .PARAMETER IgnoreExpiry
        Treat a healthy, unexpired credential as due anyway, reported as Manual. This is
        what somebody naming a single machine means: they asked for that machine, and a
        threshold quietly deciding to do nothing would be the wrong answer. A scheduled
        pass leaves it off and lets the expiry date decide.

        The last point is the design in one sentence: the expiry date is the only
        signal. Everything else writes to it.

    .OUTPUTS
        PSCustomObject with VM, CredentialType, Reason, SecretName, ExpiresOn.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VaultName,

        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object[]]$VM,

        [ValidateRange(0, 3650)][int]$ThresholdDays = 14,

        [switch]$IgnoreExpiry,

        # Linux VMs get an SSH key rotated unless this is set.
        [switch]$SkipSshKeys
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
                elseif ($null -eq $secret.Secret.Expires) {
                    $reason = 'Missing'
                    Write-RotationLog -Message "Secret '$secretName' has no expiry date" -Level Warning -Scope $vm.Name
                }
                elseif ($IgnoreExpiry) {
                    # Asked for explicitly: rotate it whatever the expiry says. Anything else
                    # would silently do nothing for a machine somebody named.
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
