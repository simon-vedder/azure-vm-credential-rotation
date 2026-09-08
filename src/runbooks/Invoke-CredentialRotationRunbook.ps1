<#
.SYNOPSIS
    Azure Automation entry point for VM credential rotation.

.DESCRIPTION
    Thin wrapper. It authenticates, resolves configuration, guards against
    overlapping runs and calls Invoke-CredentialRotation. All logic lives in the
    CredentialRotation module under src/.

    It reaches Azure Automation two ways. The Bicep deployment imports the module from
    the PowerShell Gallery and publishes this file as it stands; the Terraform
    deployment publishes the flattened artefact from build/Build-Runbook.ps1, which
    inlines the module ahead of this wrapper. The import below covers the first case
    and stays out of the way in the second.

    Configuration precedence is parameter, then Automation variable, then default.
    That is what makes the optional parts independently deployable: observability sets
    CR_WorkspaceId and the data collection variables, rotation-after-use sets
    CR_AccessRotationEnabled. Deploy neither and the runbook falls back to plain
    expiry-driven rotation.

.PARAMETER DryRun
    Runs the whole pass under -WhatIf. Use this first, always.

.NOTES
    Requires the automation account's managed identity to hold:
      Key Vault Secrets Officer   on the vault
      Virtual Machine Contributor on the VM scopes
      Log Analytics Reader        on the workspace   (only for access-driven rotation)
      Monitoring Metrics Publisher on the DCR        (only for audit records)
#>
[CmdletBinding()]
param(
    [string]$VaultName,
    [string]$SubscriptionId,

    [int]$ThresholdDays = 0,
    [int]$ValidityDays = 0,

    [string]$EnableTagName,
    [string]$EnableTagValue,

    [bool]$SkipSshKeys = $false,
    [bool]$RemovePriorSshKeys = $false,
    [bool]$ResetSshConfiguration = $false,

    [bool]$DryRun = $false
)

$ErrorActionPreference = 'Stop'

# Importing the Az modules emits several hundred verbose lines per job, which buries
# everything useful. Silencing the preference keeps them out; Write-RotationLog passes
# -Verbose explicitly so its own lines still come through.
$VerbosePreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# configuration helpers
# ---------------------------------------------------------------------------

function Get-RunbookSetting {
    param(
        [Parameter(Mandatory)][string]$Name,
        $Value,
        $Default
    )

    $isSet = $null -ne $Value -and
             -not ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) -and
             -not ($Value -is [int] -and $Value -eq 0)

    if ($isSet) { return $Value }

    try {
        $fromVariable = Get-AutomationVariable -Name "CR_$Name" -ErrorAction Stop
        if ($null -ne $fromVariable -and -not ([string]::IsNullOrWhiteSpace([string]$fromVariable))) {
            return $fromVariable
        }
    }
    catch {
        # Variable not present. Expected whenever an optional module is not deployed,
        # so this is a normal path rather than an error.
        Write-Verbose "Automation variable CR_$Name not set, using the default."
    }

    return $Default
}

# ---------------------------------------------------------------------------
# authenticate
# ---------------------------------------------------------------------------

# Keeps contexts from leaking between concurrent jobs in the same sandbox.
$null = Disable-AzContextAutosave -Scope Process

# Two ways this file reaches Automation, and it has to work for both. The Bicep deployment imports
# the CredentialRotation module from the Gallery and publishes this wrapper as it stands, so the
# module has to be imported here. The Terraform deployment publishes the flattened artefact from
# build/Build-Runbook.ps1, which inlines every function ahead of this line - there the commands are
# already defined and importing would pull a second, possibly older copy over them.
if (-not (Get-Command -Name 'Invoke-CredentialRotation' -ErrorAction SilentlyContinue)) {
    Import-Module -Name 'CredentialRotation' -ErrorAction Stop
}

Write-Verbose "$((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) [Info] Connecting with the managed identity" -Verbose
$null = Connect-AzAccount -Identity -ErrorAction Stop

# ---------------------------------------------------------------------------
# resolve configuration
# ---------------------------------------------------------------------------

$config = @{
    VaultName             = Get-RunbookSetting -Name 'VaultName' -Value $VaultName
    ThresholdDays         = [int](Get-RunbookSetting -Name 'ThresholdDays' -Value $ThresholdDays -Default 14)
    ValidityDays          = [int](Get-RunbookSetting -Name 'ValidityDays' -Value $ValidityDays -Default 90)
    EnableTagName         = Get-RunbookSetting -Name 'EnableTagName' -Value $EnableTagName -Default 'CredentialRotation'
    EnableTagValue        = Get-RunbookSetting -Name 'EnableTagValue' -Value $EnableTagValue -Default 'enabled'
    SkipSshKeys           = $SkipSshKeys
    RemovePriorSshKeys    = $RemovePriorSshKeys
    ResetSshConfiguration = $ResetSshConfiguration
}

if ([string]::IsNullOrWhiteSpace($config.VaultName)) {
    throw 'No vault name. Pass -VaultName or set the automation variable CR_VaultName.'
}

$subscriptions = if ($SubscriptionId) {
    $SubscriptionId -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}
else {
    $fromVariable = Get-RunbookSetting -Name 'SubscriptionId' -Default ''
    if ($fromVariable) { $fromVariable -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { $null }
}

# Optional: access-driven rotation, present only when the modules are deployed.
$workspaceId = Get-RunbookSetting -Name 'WorkspaceId' -Default ''
$accessEnabled = [bool]::TryParse([string](Get-RunbookSetting -Name 'AccessRotationEnabled' -Default 'false'), [ref]$null) -and
                 ([string](Get-RunbookSetting -Name 'AccessRotationEnabled' -Default 'false')) -eq 'true'

if (-not $accessEnabled) { $workspaceId = '' }

$optional = @{}
if ($workspaceId) {
    $optional['WorkspaceId'] = $workspaceId
    $optional['GracePeriodHours'] = [int](Get-RunbookSetting -Name 'GracePeriodHours' -Default 8)
    $optional['AccessLookbackHours'] = [int](Get-RunbookSetting -Name 'AccessLookbackHours' -Default 24)

    $exclude = [string](Get-RunbookSetting -Name 'ExcludeObjectId' -Default '')
    if ($exclude) {
        $optional['ExcludeObjectId'] = $exclude -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
}

$dce = Get-RunbookSetting -Name 'DataCollectionEndpoint' -Default ''
$dcr = Get-RunbookSetting -Name 'DataCollectionRuleId' -Default ''
if ($dce -and $dcr) {
    $optional['DataCollectionEndpoint'] = $dce
    $optional['DataCollectionRuleId'] = $dcr
    $optional['StreamName'] = Get-RunbookSetting -Name 'StreamName' -Default 'Custom-CredentialRotation_CL'
}

# ---------------------------------------------------------------------------
# guard against overlapping runs
# ---------------------------------------------------------------------------

$accountName = Get-RunbookSetting -Name 'AutomationAccountName' -Default ''
$accountRg = Get-RunbookSetting -Name 'AutomationResourceGroup' -Default ''

if ($accountName -and $accountRg -and $PSPrivateMetadata.JobId) {
    try {
        $thisJobId = $PSPrivateMetadata.JobId.Guid
        $running = Get-AzAutomationJob -ResourceGroupName $accountRg -AutomationAccountName $accountName `
            -RunbookName 'Invoke-CredentialRotation' -ErrorAction Stop |
            Where-Object { $_.Status -in @('Running', 'Starting', 'Activating') -and $_.JobId -ne $thisJobId }

        if ($running) {
            Write-Warning "Another rotation job is already running ($($running[0].JobId)). Exiting so the two cannot fight over the same VM."
            return
        }
    }
    catch {
        Write-Warning "Could not check for concurrent jobs, continuing: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

$params = @{
    VaultName             = $config.VaultName
    ThresholdDays         = $config.ThresholdDays
    ValidityDays          = $config.ValidityDays
    EnableTagName         = $config.EnableTagName
    EnableTagValue        = $config.EnableTagValue
    SkipSshKeys           = $config.SkipSshKeys
    RemovePriorSshKeys    = $config.RemovePriorSshKeys
    ResetSshConfiguration = $config.ResetSshConfiguration
    TriggeredBy           = 'automation'
}
if ($subscriptions) { $params['SubscriptionId'] = $subscriptions }
foreach ($key in $optional.Keys) { $params[$key] = $optional[$key] }

$summary = Invoke-CredentialRotation @params -WhatIf:$DryRun -Confirm:$false

if ($DryRun) {
    Write-Warning 'DRY RUN - nothing was changed'
}

# The headline numbers go to the output stream, not the verbose one, so they survive
# even if someone deploys with verbose logging turned off.
Write-Output ("Rotation summary: candidates={0} rotated={1} skipped={2} failed={3} accessMarked={4} duration={5}" -f `
    $summary.Candidates, $summary.Rotated, $summary.Skipped, $summary.Failed, $summary.AccessMarked, $summary.Duration.ToString('hh\:mm\:ss'))

# A runbook that swallows its errors reports Completed, and every alert built on job
# status is then blind. Throw so the job status reflects reality.
if ($summary.Failed -gt 0) {
    throw "Credential rotation finished with $($summary.Failed) failure(s). See the job output for detail."
}
