function Invoke-CredentialRotation {
    <#
    .SYNOPSIS
        Rotates the credentials that are due on the machines you give it.

    .DESCRIPTION
        The caller states the machines. This function does not search for them, does not
        read a tag, and has no opinion about which machines belong in scope. That belongs
        to whatever is orchestrating - a runbook, a pipeline, or you at a prompt - and
        keeping it out of here is what lets the same code run against one machine from a
        workstation and against a fleet on a schedule.

        Every machine handed in is rotated. Add -OnlyIfDue and the expiry date gets a vote
        instead, which is what a scheduled pass wants. Whether you passed one name or two
        hundred objects has nothing to do with it.

        Rotation after use is not handled here either. Register-CredentialAccess pulls the
        expiry date of a credential somebody read forward; this function then sees it as
        ordinary ageing. One signal, one code path - and the orchestrator decides how often
        to look.

    .PARAMETER VaultName
        The Key Vault the credentials live in. The one thing this function must be told
        that it cannot work out from the machines themselves.

    .PARAMETER VMName
        Rotate this machine. A convenience over -VM for the common case of one name; it
        behaves identically otherwise.

    .PARAMETER ResourceGroupName
        Narrows -VMName when the same name exists more than once in the subscription.
        Without it, an ambiguous name is an error rather than a guess.

    .PARAMETER VM
        Machines to process, as objects from Get-AzVM. What an orchestrator passes after
        it has selected them.

    .PARAMETER OnlyIfDue
        Rotate only what is missing, half-rotated or near expiry, instead of rotating
        everything handed in. How you name the machines says nothing about this - a
        scheduled pass sets it, a person at a prompt usually does not.

    .PARAMETER ThresholdDays
        How close to expiry counts as due. Only consulted with -OnlyIfDue.

    .PARAMETER ValidityDays
        How far ahead each new secret's expiry date is set. Since the expiry date is the
        only signal, this is the rotation interval: ninety days here means a credential
        comes back around in ninety days.

    .PARAMETER SkipSshKeys
        Rotates passwords only, leaving Linux SSH keys alone. Useful while onboarding an
        estate where the keys are managed by something else.

    .PARAMETER RemovePriorSshKeys
        Passed through to Update-VMCredential, and off by default for the reason given
        there: VMAccess can wipe every entry in authorized_keys, colleagues and agents
        included.

    .PARAMETER ResetSshConfiguration
        Passed through to Update-VMCredential, and off by default: VMAccess can restore
        sshd configuration to its default and undo hardening on a baselined host.

    .PARAMETER TriggeredBy
        Who or what asked for this run - a runbook job id, a person, a change ticket.
        Recorded on every record the run produces, and never interpreted.

    .PARAMETER SecretNameTemplate
        How secret names are built from {vm}, {user}, {rg} and {kind}. Change it to fit a
        vault that already has a naming convention; keep it the same for the life of a
        secret. Use {rg} where two machines could share a name - a VM name is not unique in
        a subscription, and the default template would put both on one secret.

    .EXAMPLE
        Invoke-CredentialRotation -VaultName kv-creds -VMName jump-01 -WhatIf

        Shows what would happen to one machine, from your own workstation, without
        deploying anything. Always the first thing to run.

    .EXAMPLE
        Invoke-CredentialRotation -VaultName kv-creds -VMName jump-01

        Rotates that machine now. The secret is created in the vault if it does not
        exist yet, so this is also how a machine is onboarded by hand.

    .EXAMPLE
        $vms = Get-AzVM | Where-Object { $_.Tags.CredentialRotation -eq 'enabled' }
        Invoke-CredentialRotation -VaultName kv-creds -VM $vms -OnlyIfDue

        What an orchestrator does: select the machines however you like, hand them over,
        and ask for only the ones that are due. The tag here is the caller's policy, not
        the module's.

    .EXAMPLE
        Invoke-CredentialRotation -VaultName kv-creds -VM $vms

        The same machines, all rotated, due or not. Naming machines and deciding whether
        the expiry date gets a vote are two separate questions, so they are two separate
        parameters.

    .OUTPUTS
        PSCustomObject summarising the run. Records holds one entry per credential touched,
        in the shape CredentialRotation_CL expects, for whoever wants to ship them.
    #>
    # -WhatIf is supported and propagated, but the decision is made where the change is:
    # Update-VMCredential calls ShouldProcess per credential. Confirming once up here
    # instead would collapse a dry run into a single line and throw away the per-credential
    # WhatIf records, which are the reason anybody runs one.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '')]
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Named')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VaultName,

        [Parameter(Mandatory, ParameterSetName = 'Named')]
        [ValidateNotNullOrEmpty()][string]$VMName,

        [Parameter(ParameterSetName = 'Named')][string]$ResourceGroupName,

        [Parameter(Mandatory, ParameterSetName = 'Machines')]
        [ValidateNotNullOrEmpty()][object[]]$VM,

        [switch]$OnlyIfDue,

        # Only consulted with -OnlyIfDue.
        [ValidateRange(0, 3650)][int]$ThresholdDays = 14,

        [ValidateRange(1, 3650)][int]$ValidityDays = 90,

        [switch]$SkipSshKeys,
        [switch]$RemovePriorSshKeys,
        [switch]$ResetSshConfiguration,

        [ValidateNotNullOrEmpty()][string]$SecretNameTemplate = '{vm}-{user}-{kind}',

        [string]$TriggeredBy
    )

    $startTime = Get-Date
    # Only ever decides where the machines come from, never what happens to them.
    $named = $PSCmdlet.ParameterSetName -eq 'Named'
    $records = [System.Collections.Generic.List[object]]::new()

    $stats = [ordered]@{
        Candidates = 0
        Rotated    = 0
        Skipped    = 0
        Failed     = 0
    }

    Write-RotationLog -Message '=== Credential rotation started ===' -Level Info

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        throw 'No Azure context. Connect with Connect-AzAccount (or -Identity in Automation) first.'
    }

    # --- the machines --------------------------------------------------------
    # Named or handed in, but always stated by the caller. Nothing here searches.
    $machines = if ($named) {
        @(Resolve-TargetVM -Name $VMName -ResourceGroupName $ResourceGroupName)
    }
    else {
        @($VM)
    }

    $scope = if ($OnlyIfDue) { "only what is due within $ThresholdDays d" } else { 'everything handed in' }
    Write-RotationLog -Message "Vault: $VaultName | machines: $($machines.Count) | $scope | validity: $ValidityDays d" -Level Info

    # A threshold with nothing to apply to is the kind of parameter that looks like it
    # worked. Say so rather than ignoring it quietly.
    if ($PSBoundParameters.ContainsKey('ThresholdDays') -and -not $OnlyIfDue) {
        Write-RotationLog -Message '-ThresholdDays was given without -OnlyIfDue, so it has no effect: every machine handed in is being rotated.' -Level Warning
    }

    # --- what to rotate ------------------------------------------------------
    try {
        $candidates = Get-RotationCandidate -VaultName $VaultName -VM $machines `
            -OnlyIfDue:$OnlyIfDue -ThresholdDays $ThresholdDays -SkipSshKeys:$SkipSshKeys `
            -SecretNameTemplate $SecretNameTemplate
    }
    catch {
        Write-RotationLog -Message "Could not work out what is due: $($_.Exception.Message)" -Level Error
        throw
    }

    $stats.Candidates = @($candidates).Count
    Write-RotationLog -Message "$(@($candidates).Count) credential(s) to process" -Level Info

    # --- rotate --------------------------------------------------------------
    foreach ($candidate in $candidates) {
        try {
            $record = Update-VMCredential -VaultName $VaultName -VM $candidate.VM `
                -CredentialType $candidate.CredentialType -ValidityDays $ValidityDays `
                -TriggerReason $candidate.Reason -TriggeredBy $TriggeredBy `
                -RemovePriorSshKeys:$RemovePriorSshKeys `
                -ResetSshConfiguration:$ResetSshConfiguration `
                -SecretNameTemplate $SecretNameTemplate `
                -WhatIf:$WhatIfPreference -Confirm:$false

            $records.Add($record)

            switch ($record.Result) {
                'Rotated' { $stats.Rotated++ }
                'Skipped' { $stats.Skipped++ }
                'Failed' { $stats.Failed++ }
                'WhatIf' { $stats.Skipped++ }
            }
        }
        catch {
            Write-RotationLog -Message "Unhandled error on $($candidate.VM.Name) ($($candidate.CredentialType)): $($_.Exception.Message)" -Level Error -Scope $candidate.VM.Name
            $stats.Failed++
        }
    }

    $duration = (Get-Date) - $startTime

    Write-RotationLog -Message '=== Summary ===' -Level Info
    Write-RotationLog -Message "Duration: $($duration.ToString('hh\:mm\:ss'))" -Level Info
    Write-RotationLog -Message "Candidates: $($stats.Candidates) | rotated: $($stats.Rotated) | skipped: $($stats.Skipped) | failed: $($stats.Failed)" `
        -Level $(if ($stats.Failed -gt 0) { 'Warning' } else { 'Success' })

    return [pscustomobject]@{
        StartedAt  = $startTime.ToUniversalTime()
        Duration   = $duration
        Candidates = $stats.Candidates
        Rotated    = $stats.Rotated
        Skipped    = $stats.Skipped
        Failed     = $stats.Failed
        Records    = $records.ToArray()
    }
}
