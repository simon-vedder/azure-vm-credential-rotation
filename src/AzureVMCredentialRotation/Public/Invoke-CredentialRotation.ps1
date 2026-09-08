function Invoke-CredentialRotation {
    <#
    .SYNOPSIS
        Reconciles VM credentials against their Key Vault expiry dates.

    .DESCRIPTION
        Two ways to call it.

        Name a machine with -VMName and it rotates that one, now, whatever its expiry
        date says and whether or not it carries the enable tag. Naming a machine is a
        stronger statement of intent than a tag, and this is the form to reach for from
        a workstation.

        Call it without -VMName and it makes one pass over the estate:

          1. ask Log Analytics which secrets a human read, and pull those expiry
             dates forward (optional, requires the observability module)
          2. find every credential that is missing, expiring or half-rotated
          3. rotate it
          4. write a record of what happened

        There is no event subscription and no queue. The run is the retry: anything
        that fails or is skipped - a stopped VM, a throttled call, an unhealthy guest
        agent - is simply picked up next time. That is what makes the whole thing
        small enough to reason about.

        Latency is the trade. A credential read at 09:00 with a six-hourly schedule
        and an eight-hour grace period is replaced some time before 23:00, not within
        minutes. For credentials that would otherwise sit unchanged for months, that
        is not a meaningful difference. If it is for you, see
        docs/decisions/0002-reconciliation-loop-over-events.md, which describes what
        an event-driven version would need.

    .PARAMETER SubscriptionId
        Subscriptions to process. Defaults to the current context only - deliberately
        narrow, so an unscoped run cannot reach further than intended. With -VMName only
        the first entry is used, because one machine lives in one subscription.

    .PARAMETER VMName
        Rotate this machine and nothing else. The enable tag is not required and the
        expiry threshold does not apply. The hold tag still does.

    .PARAMETER ResourceGroupName
        Narrows -VMName when the same name exists more than once in the subscription.
        Without it, an ambiguous name is an error rather than a guess.

    .PARAMETER IgnoreHold
        Rotate even a machine carrying the hold tag. Only available with -VMName: a
        scheduled run must never talk itself out of a hold.

    .EXAMPLE
        Invoke-CredentialRotation -VaultName kv-creds -VMName jump-01 -WhatIf

        Shows what would happen to one machine, from your own workstation, without
        deploying anything. Always the first thing to run.

    .EXAMPLE
        Invoke-CredentialRotation -VaultName kv-creds -VMName jump-01

        Rotates that machine now. The secret is created in the vault if it does not
        exist yet, so this is also how a machine is onboarded by hand.

    .EXAMPLE
        Invoke-CredentialRotation -VaultName kv-creds -WhatIf

        The estate pass: every VM carrying the enable tag whose credential is missing,
        expiring or half-rotated. This is what the scheduled runbook calls.

    .OUTPUTS
        PSCustomObject summarising the run, with the individual records attached.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Estate')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VaultName,

        [Parameter(Mandatory, ParameterSetName = 'SingleVM')]
        [ValidateNotNullOrEmpty()][string]$VMName,

        [Parameter(ParameterSetName = 'SingleVM')][string]$ResourceGroupName,
        [Parameter(ParameterSetName = 'SingleVM')][switch]$IgnoreHold,

        [string[]]$SubscriptionId,

        # Estate only: a named machine is rotated whatever its expiry says, and was not
        # found by tag in the first place. Offering these there would be offering a
        # parameter that does nothing.
        [Parameter(ParameterSetName = 'Estate')][ValidateRange(0, 3650)][int]$ThresholdDays = 14,
        [Parameter(ParameterSetName = 'Estate')][string]$EnableTagName = 'CredentialRotation',
        [Parameter(ParameterSetName = 'Estate')][string]$EnableTagValue = 'enabled',

        [ValidateRange(1, 3650)][int]$ValidityDays = 90,
        [string]$HoldTagName = 'CredentialRotationHold',
        [switch]$SkipSshKeys,
        [switch]$RemovePriorSshKeys,
        [switch]$ResetSshConfiguration,

        # Access-triggered rotation. Without a workspace, only expiry drives rotation.
        # Estate only: the scan is an estate-wide query whose only effect is to move
        # expiry dates, and a named machine is rotated regardless of its expiry date.
        [Parameter(ParameterSetName = 'Estate')][string]$WorkspaceId,
        [Parameter(ParameterSetName = 'Estate')][ValidateRange(0, 168)][int]$GracePeriodHours = 8,
        [Parameter(ParameterSetName = 'Estate')][ValidateRange(1, 720)][int]$AccessLookbackHours = 24,
        [Parameter(ParameterSetName = 'Estate')][string[]]$ExcludeObjectId = @(),

        # Structured audit records. Without these, the job output is the only trail.
        [string]$DataCollectionEndpoint,
        [string]$DataCollectionRuleId,
        [string]$StreamName = 'Custom-CredentialRotation_CL',

        [string]$TriggeredBy
    )

    $startTime = Get-Date
    $single = $PSCmdlet.ParameterSetName -eq 'SingleVM'
    $records = [System.Collections.Generic.List[object]]::new()

    $stats = [ordered]@{
        Candidates   = 0
        Rotated      = 0
        Skipped      = 0
        Failed       = 0
        AccessMarked = 0
    }

    Write-RotationLog -Message '=== Credential rotation started ===' -Level Info
    if ($single) {
        Write-RotationLog -Message "Vault: $VaultName | machine: $VMName | validity: $ValidityDays d | named explicitly, tag and threshold do not apply" -Level Info
    }
    else {
        Write-RotationLog -Message "Vault: $VaultName | threshold: $ThresholdDays d | validity: $ValidityDays d | access-driven: $([bool]$WorkspaceId)" -Level Info
    }

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        throw 'No Azure context. Connect with Connect-AzAccount -Identity before calling this function.'
    }

    # --- 1. access-driven expiry updates ------------------------------------
    # -WorkspaceId belongs to the estate parameter set, so this cannot run for a named
    # machine: the scan only moves expiry dates, which a named machine ignores anyway.
    if ($WorkspaceId) {
        try {
            $marked = Register-CredentialAccess -VaultName $VaultName -WorkspaceId $WorkspaceId `
                -GracePeriodHours $GracePeriodHours -LookbackHours $AccessLookbackHours `
                -ExcludeObjectId $ExcludeObjectId -HoldTagName $HoldTagName
            $stats.AccessMarked = @($marked).Count
        }
        catch {
            # A workspace problem must not stop expiry-driven rotation.
            Write-RotationLog -Message "Access scan failed, continuing with expiry-driven rotation only: $($_.Exception.Message)" -Level Error -Scope 'access'
            $stats.Failed++
        }
    }

    # --- 2 & 3. find and rotate ---------------------------------------------
    # One machine lives in one subscription, so a list would only be a way to get it wrong.
    $subscriptions = if ($SubscriptionId) {
        if ($single) { @($SubscriptionId[0]) } else { $SubscriptionId }
    }
    else { @((Get-AzContext).Subscription.Id) }

    foreach ($sub in $subscriptions) {
        Write-RotationLog -Message "--- Subscription $sub ---" -Level Info

        try {
            $null = Set-AzContext -SubscriptionId $sub -ErrorAction Stop
        }
        catch {
            Write-RotationLog -Message "Cannot switch to subscription ${sub}: $($_.Exception.Message)" -Level Error
            $stats.Failed++
            continue
        }

        try {
            $candidates = if ($single) {
                Get-RotationCandidate -VaultName $VaultName -VM (Resolve-TargetVM -Name $VMName -ResourceGroupName $ResourceGroupName) `
                    -IgnoreHold:$IgnoreHold -HoldTagName $HoldTagName -SkipSshKeys:$SkipSshKeys
            }
            else {
                Get-RotationCandidate -VaultName $VaultName -ThresholdDays $ThresholdDays `
                    -EnableTagName $EnableTagName -EnableTagValue $EnableTagValue `
                    -HoldTagName $HoldTagName -SkipSshKeys:$SkipSshKeys
            }
        }
        catch {
            Write-RotationLog -Message "Discovery failed in subscription ${sub}: $($_.Exception.Message)" -Level Error
            $stats.Failed++
            continue
        }

        $stats.Candidates += @($candidates).Count
        Write-RotationLog -Message "$(@($candidates).Count) credential(s) to process" -Level Info

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
    Write-RotationLog -Message "Expiry pulled forward after access: $($stats.AccessMarked)" -Level Info
    Write-RotationLog -Message "Candidates: $($stats.Candidates) | rotated: $($stats.Rotated) | skipped: $($stats.Skipped) | failed: $($stats.Failed)" `
        -Level $(if ($stats.Failed -gt 0) { 'Warning' } else { 'Success' })

    return [pscustomobject]@{
        StartedAt    = $startTime.ToUniversalTime()
        Duration     = $duration
        Candidates   = $stats.Candidates
        Rotated      = $stats.Rotated
        Skipped      = $stats.Skipped
        Failed       = $stats.Failed
        AccessMarked = $stats.AccessMarked
        Records      = $records.ToArray()
    }
}
