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
