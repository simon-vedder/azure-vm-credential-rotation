<#
.SYNOPSIS
    Azure Automation entry point for VM credential rotation.

.DESCRIPTION
    The orchestrator. It authenticates, resolves its configuration, guards against
    overlapping runs, decides which machines are in scope, and hands them to the
    AzureVMCredentialRotation module.

    That split is the point. The module rotates the machines it is given and has no
    opinion about tags; every policy decision - which machines are enabled, which are
    on hold, which subscriptions to walk, how often to look for reads - lives here.
    So the same module runs from a workstation against one named machine and from this
    runbook against a fleet, without a mode switch.

    Scope is opt-in by tag. A discovery loop that treated "no secret exists for this
    VM" as "rotate it" would, on its first run in an established tenant, change the
    local administrator password of every machine it can see.

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

.PARAMETER HoldTagName
    VM tag that takes a machine out of scope for this run without untagging it. Checked
    here rather than in the module, because it is a policy statement about a machine
    rather than a fact about the credential.

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

    # Not an automation variable on purpose: adding one would change the deployment
    # contract that Bicep, Terraform and the contract test all agree on, for a name
    # nobody has ever needed to override.
    [string]$HoldTagName = 'CredentialRotationHold',

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
# the AzureVMCredentialRotation module from the Gallery and publishes this wrapper as it stands, so the
# module has to be imported here. The Terraform deployment publishes the flattened artefact from
# build/Build-Runbook.ps1, which inlines every function ahead of this line - there the commands are
# already defined and importing would pull a second, possibly older copy over them.
if (-not (Get-Command -Name 'Invoke-CredentialRotation' -ErrorAction SilentlyContinue)) {
    Import-Module -Name 'AzureVMCredentialRotation' -ErrorAction Stop
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
# orchestrate
#
# This is the layer that decides which machines are in scope. The module does not:
# it rotates the machines it is given and has no opinion about tags. Keeping the
# policy here is what lets the same module run from a workstation against one machine
# and from this runbook against a fleet.
# ---------------------------------------------------------------------------

function Test-TagValue {
    # Azure tag keys are case-insensitive, and a tag typed in the portal as
    # "credentialrotation" must count. Hashtable lookup is not, so match on the key.
    param($Tags, [string]$Name, [string]$Value)
    if (-not $Tags) { return $false }
    $key = $Tags.Keys | Where-Object { $_ -ieq $Name } | Select-Object -First 1
    if (-not $key) { return $false }
    return ([string]$Tags[$key]) -eq $Value
}

$targetSubscriptions = if ($subscriptions) { $subscriptions } else { @((Get-AzContext).Subscription.Id) }

$totals = [ordered]@{ Candidates = 0; Rotated = 0; Skipped = 0; Failed = 0; AccessMarked = 0 }

# Rotation after use, once for the whole run: it moves expiry dates in the vault, and
# the per-subscription passes below then see those credentials as ordinary ageing.
if ($workspaceId) {
    try {
        $accessParams = @{
            VaultName        = $config.VaultName
            WorkspaceId      = $workspaceId
            GracePeriodHours = $optional['GracePeriodHours']
            LookbackHours    = $optional['AccessLookbackHours']
        }
        if ($optional.ContainsKey('ExcludeObjectId')) { $accessParams['ExcludeObjectId'] = $optional['ExcludeObjectId'] }

        $marked = Register-CredentialAccess @accessParams -WhatIf:$DryRun -Confirm:$false
        $totals.AccessMarked = @($marked).Count
    }
    catch {
        # A workspace problem must not stop expiry-driven rotation.
        Write-Warning "Access scan failed, continuing with expiry-driven rotation only: $($_.Exception.Message)"
        $totals.Failed++
    }
}

foreach ($sub in $targetSubscriptions) {
    Write-Verbose "--- Subscription $sub ---" -Verbose

    try {
        $null = Set-AzContext -SubscriptionId $sub -ErrorAction Stop
    }
    catch {
        Write-Warning "Cannot switch to subscription ${sub}: $($_.Exception.Message)"
        $totals.Failed++
        continue
    }

    try {
        # Opt-in, not opt-out. A discovery loop that treated "no secret exists for this
        # VM" as "rotate it" would, on its first run in an established tenant, change the
        # local administrator password of every machine it can see - including the ones
        # whose credentials live in a CMDB nobody told it about.
        $all = @(Get-AzVM -ErrorAction Stop)
        $enabled = @($all | Where-Object { Test-TagValue -Tags $_.Tags -Name $config.EnableTagName -Value $config.EnableTagValue })
        $held = @($enabled | Where-Object { Test-TagValue -Tags $_.Tags -Name $HoldTagName -Value 'true' })
        $machines = @($enabled | Where-Object { $_ -notin $held })
    }
    catch {
        Write-Warning "Discovery failed in subscription ${sub}: $($_.Exception.Message)"
        $totals.Failed++
        continue
    }

    Write-Verbose "$($enabled.Count) VM(s) tagged $($config.EnableTagName)=$($config.EnableTagValue), $($held.Count) on hold via $HoldTagName" -Verbose
    foreach ($vm in $held) { Write-Verbose "[$($vm.Name)] on hold, skipping" -Verbose }

    if ($machines.Count -eq 0) { continue }

    # The list form of Get-AzVM has no OSProfile, and the rotation needs the admin
    # username off it. Fetch each selected machine in full before handing it over.
    $full = foreach ($vm in $machines) {
        try { Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -ErrorAction Stop }
        catch {
            Write-Warning "Could not read $($vm.Name) in full: $($_.Exception.Message)"
            $totals.Failed++
        }
    }
    $full = @($full)
    if ($full.Count -eq 0) { continue }

    $params = @{
        VaultName             = $config.VaultName
        VM                    = $full
        # A scheduled pass replaces what is due, not everything it can see. The module
        # rotates whatever it is handed unless told otherwise, so this switch is what
        # keeps a six-hourly job from re-rolling every credential in the estate.
        OnlyIfDue             = $true
        ThresholdDays         = $config.ThresholdDays
        ValidityDays          = $config.ValidityDays
        SkipSshKeys           = $config.SkipSshKeys
        RemovePriorSshKeys    = $config.RemovePriorSshKeys
        ResetSshConfiguration = $config.ResetSshConfiguration
        TriggeredBy           = 'automation'
    }
    if ($optional.ContainsKey('DataCollectionEndpoint')) {
        $params['DataCollectionEndpoint'] = $optional['DataCollectionEndpoint']
        $params['DataCollectionRuleId'] = $optional['DataCollectionRuleId']
        $params['StreamName'] = $optional['StreamName']
    }

    $result = Invoke-CredentialRotation @params -WhatIf:$DryRun -Confirm:$false

    $totals.Candidates += $result.Candidates
    $totals.Rotated += $result.Rotated
    $totals.Skipped += $result.Skipped
    $totals.Failed += $result.Failed
}

$summary = [pscustomobject]$totals

if ($DryRun) {
    Write-Warning 'DRY RUN - nothing was changed'
}

# The headline numbers go to the output stream, not the verbose one, so they survive
# even if someone deploys with verbose logging turned off.
Write-Output ("Rotation summary: candidates={0} rotated={1} skipped={2} failed={3} accessMarked={4}" -f `
    $summary.Candidates, $summary.Rotated, $summary.Skipped, $summary.Failed, $summary.AccessMarked)

# A runbook that swallows its errors reports Completed, and every alert built on job
# status is then blind. Throw so the job status reflects reality.
if ($summary.Failed -gt 0) {
    throw "Credential rotation finished with $($summary.Failed) failure(s). See the job output for detail."
}
