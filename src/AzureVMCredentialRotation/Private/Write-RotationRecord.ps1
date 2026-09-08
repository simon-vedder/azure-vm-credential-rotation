function Write-RotationRecord {
    <#
    .SYNOPSIS
        Writes one structured rotation record to a Log Analytics custom table.

    .DESCRIPTION
        Uses the Logs Ingestion API (data collection endpoint plus data collection
        rule), not the HTTP Data Collector API. The latter retires on 14 September
        2026 and would be dead on arrival.

        The record never contains credential material. Secret versions are recorded
        as identifiers so an auditor can correlate a rotation with the Key Vault
        audit log without either system holding a value.

        Failure to write a record is logged but does not fail the rotation. The
        credential change already happened; losing the telemetry is the lesser
        problem, and the job output still carries the same information.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$Record,

        [Parameter(Mandatory)][string]$DataCollectionEndpoint,
        [Parameter(Mandatory)][string]$DataCollectionRuleId,
        [string]$StreamName = 'Custom-CredentialRotation_CL'
    )

    if (-not $PSCmdlet.ShouldProcess($StreamName, 'Write rotation record')) { return }

    try {
        $token = (Get-AzAccessToken -ResourceUrl 'https://monitor.azure.com' -ErrorAction Stop).Token
        $uri = '{0}/dataCollectionRules/{1}/streams/{2}?api-version=2023-01-01' -f
            $DataCollectionEndpoint.TrimEnd('/'), $DataCollectionRuleId, $StreamName

        $body = ConvertTo-Json -InputObject @($Record) -Depth 5 -Compress

        $null = Invoke-RestMethod -Uri $uri -Method Post -Body $body `
            -ContentType 'application/json' `
            -Headers @{ Authorization = "Bearer $token" } `
            -ErrorAction Stop

        Write-RotationLog -Message "Rotation record written for $($Record.SecretName)" -Level Info -Scope 'audit'
    }
    catch {
        Write-RotationLog -Message "Could not write rotation record for $($Record.SecretName): $($_.Exception.Message)" -Level Warning -Scope 'audit'
    }
}

function New-RotationRecord {
    <#
    .SYNOPSIS
        Builds the record shape expected by the CredentialRotation_CL custom table.

    .DESCRIPTION
        TimeGenerated is set explicitly so the record carries the time the rotation
        completed rather than the time the batch happened to flush.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$SecretName,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][ValidateSet('Windows', 'Linux')][string]$OSType,
        [Parameter(Mandatory)][ValidateSet('Password', 'SSHKey')][string]$CredentialType,
        [Parameter(Mandatory)][ValidateSet('Expiry', 'Access', 'Missing', 'Manual', 'ResumePending')][string]$TriggerReason,
        [Parameter(Mandatory)][ValidateSet('Rotated', 'Skipped', 'Failed', 'WhatIf')][string]$Result,

        [datetime]$StartedAt = (Get-Date).ToUniversalTime(),
        [string]$TriggeredBy,
        [string]$PreviousSecretVersion,
        [string]$NewSecretVersion,
        [string]$Detail
    )

    $now = (Get-Date).ToUniversalTime()

    return [pscustomobject]@{
        TimeGenerated         = $now.ToString('o')
        SecretName            = $SecretName
        VMName                = $VMName
        ResourceGroupName     = $ResourceGroupName
        SubscriptionId        = $SubscriptionId
        OSType                = $OSType
        CredentialType        = $CredentialType
        TriggerReason         = $TriggerReason
        TriggeredBy           = $TriggeredBy
        Result                = $Result
        StartedAt             = $StartedAt.ToString('o')
        DurationMs            = [int]($now - $StartedAt).TotalMilliseconds
        PreviousSecretVersion = $PreviousSecretVersion
        NewSecretVersion      = $NewSecretVersion
        Detail                = $Detail
    }
}
