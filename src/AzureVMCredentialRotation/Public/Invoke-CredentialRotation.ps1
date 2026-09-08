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

        For each machine it works out what is due (missing, expiring or half-rotated),
        rotates it, and writes a record of what happened.

        Rotation after use is not handled here either. Register-CredentialAccess pulls the
        expiry date of a credential somebody read forward; this function then sees it as
        ordinary ageing. One signal, one code path - and the orchestrator decides how often
        to look.

    .PARAMETER VMName
        Rotate this machine. The expiry threshold does not apply: you named it, so it is
        rotated. This is the form to reach for from a workstation.

    .PARAMETER ResourceGroupName
        Narrows -VMName when the same name exists more than once in the subscription.
        Without it, an ambiguous name is an error rather than a guess.

    .PARAMETER VM
        Machines to process, as objects from Get-AzVM. The expiry threshold applies, so
        only the ones that are actually due are touched. This is what an orchestrator
        passes after it has selected them.

    .PARAMETER ThresholdDays
        Rotate a credential whose expiry is this close. Ignored with -VMName.

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
        Invoke-CredentialRotation -VaultName kv-creds -VM $vms

        What an orchestrator does: select the machines however you like, then hand them
        over. The tag here is the caller's policy, not the module's.

    .OUTPUTS
        PSCustomObject summarising the run, with the individual records attached.
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

        # Only meaningful for a set of machines. A named machine is rotated regardless.
        [Parameter(ParameterSetName = 'Machines')][ValidateRange(0, 3650)][int]$ThresholdDays = 14,

        [ValidateRange(1, 3650)][int]$ValidityDays = 90,

        [switch]$SkipSshKeys,
        [switch]$RemovePriorSshKeys,
        [switch]$ResetSshConfiguration,

        # Structured audit records. Without these, the job output is the only trail.
        [string]$DataCollectionEndpoint,
        [string]$DataCollectionRuleId,
        [string]$StreamName = 'Custom-CredentialRotation_CL',

        [string]$TriggeredBy
    )

    $startTime = Get-Date
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
        Write-RotationLog -Message "Vault: $VaultName | machine: $VMName | validity: $ValidityDays d | named, so the expiry threshold does not apply" -Level Info
        @(Resolve-TargetVM -Name $VMName -ResourceGroupName $ResourceGroupName)
    }
    else {
        Write-RotationLog -Message "Vault: $VaultName | machines: $(@($VM).Count) | threshold: $ThresholdDays d | validity: $ValidityDays d" -Level Info
        @($VM)
    }

    # --- what is due ---------------------------------------------------------
    try {
        $candidates = Get-RotationCandidate -VaultName $VaultName -VM $machines `
            -ThresholdDays $ThresholdDays -IgnoreExpiry:$named -SkipSshKeys:$SkipSshKeys
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

    # --- 4. audit records ----------------------------------------------------
    if ($DataCollectionEndpoint -and $DataCollectionRuleId -and $records.Count -gt 0) {
        foreach ($record in $records) {
            Write-RotationRecord -Record $record `
                -DataCollectionEndpoint $DataCollectionEndpoint `
                -DataCollectionRuleId $DataCollectionRuleId `
                -StreamName $StreamName -Confirm:$false
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
