<#
.SYNOPSIS
    Drives the deployed runbook against the lab and checks what it did.

.DESCRIPTION
    Runs after deploy/main.bicep has been pointed at the lab resource group. Starts the
    Invoke-CredentialRotation runbook with explicit parameters, waits for each job, reads
    its streams, and checks the outcome in the vault, on the guest and - for the audit
    trail - in the workspace.

    What it proves, in order: a dry run reports and changes nothing; a live run rotates
    only what is due; the hold tag takes a machine out of scope; rotation records land
    in CredentialRotation_CL; a human read of a secret, seen in the Key Vault audit log,
    pulls the expiry forward and the same run replaces the credential; two overlapping
    jobs do not fight.

    The audit-log and custom-table steps wait for Log Analytics ingestion, which takes
    minutes. Budget half an hour for the whole thing.

.PARAMETER AutomationAccountName
    The automation account main.bicep created.

.PARAMETER AutomationResourceGroupName
    Its resource group.

.PARAMETER VaultName
    The lab Key Vault.

.PARAMETER LabResourceGroupName
    The resource group with the two lab VMs.

.PARAMETER Step
    Names of steps to run. Default is all of them, in order.

.PARAMETER Since
    Lower bound for the workspace queries. Defaults to the moment the script started,
    which is right for a full run; when repeating the custom-table step on its own, pass
    the start of the run whose records you are looking for.

.EXAMPLE
    ./tests/manual/Invoke-OrchestratorSmokeTest.ps1 -AutomationAccountName aa-credential-rotation -AutomationResourceGroupName rg-credential-rotation -VaultName kv-crot-abc123 -LabResourceGroupName rg-crot-lab

.EXAMPLE
    ./tests/manual/Invoke-OrchestratorSmokeTest.ps1 ... -Step records-land-in-the-custom-table -Since '2026-09-08T10:37:00Z'

.INPUTS
    None

.OUTPUTS
    One PSCustomObject per step: Step, Result (PASS/FAIL), Detail, Seconds.

.NOTES
    Author:              Simon Vedder (simonvedder.com)
    Version:             1.0.0
    Created:             2026-09-08
    LastModified:        2026-09-08
    RequiredPermissions: Automation Contributor on the account, Key Vault Secrets Officer on the vault, Virtual Machine Contributor on the lab resource group, Log Analytics Reader on the workspace
    Prerequisites:       PowerShell 7.2, Az.Accounts, Az.Automation, Az.Compute, Az.KeyVault, Az.OperationalInsights, Az.Resources
#>
# The parameters are read inside the step script blocks and helper functions, which the rule
# does not follow.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AutomationAccountName,
    [Parameter(Mandatory)][string]$AutomationResourceGroupName,
    [Parameter(Mandatory)][string]$VaultName,
    [Parameter(Mandatory)][string]$LabResourceGroupName,
    [string]$WindowsVMName = 'vm-crot-win-01',
    [string]$LinuxVMName = 'vm-crot-lnx-01',
    [string]$AdminUsername = 'labadmin',
    [string]$RunbookName = 'Invoke-CredentialRotation',
    [string]$HoldTagName = 'CredentialRotationHold',
    [string[]]$Step,
    [datetime]$Since
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'AzureVMCredentialRotation') -Force

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

function Invoke-RunbookJob {
    # Starts the runbook, waits for it to finish, and returns status plus every stream
    # line so the steps can assert on what the job said.
    param([hashtable]$Parameters = @{}, [int]$TimeoutMinutes = 20)

    $job = Start-AzAutomationRunbook -ResourceGroupName $AutomationResourceGroupName `
        -AutomationAccountName $AutomationAccountName -Name $RunbookName -Parameters $Parameters -ErrorAction Stop
    Write-Host "  job $($job.JobId) started" -ForegroundColor DarkGray

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds 15
        $current = Get-AzAutomationJob -ResourceGroupName $AutomationResourceGroupName `
            -AutomationAccountName $AutomationAccountName -Id $job.JobId -ErrorAction Stop
    } while ($current.Status -notin @('Completed', 'Failed', 'Stopped', 'Suspended') -and (Get-Date) -lt $deadline)

    if ($current.Status -notin @('Completed', 'Failed', 'Stopped', 'Suspended')) {
        throw "Job $($job.JobId) still $($current.Status) after $TimeoutMinutes minutes"
    }

    $streams = Get-AzAutomationJobOutput -ResourceGroupName $AutomationResourceGroupName `
        -AutomationAccountName $AutomationAccountName -Id $job.JobId -Stream Any -ErrorAction Stop
    $lines = @($streams | ForEach-Object { "[$($_.Type)] $($_.Summary)" })

    [pscustomobject]@{
        JobId     = $job.JobId
        Status    = $current.Status
        Exception = $current.Exception
        Lines     = $lines
        Text      = $lines -join "`n"
    }
}

function Get-Summary {
    param([Parameter(Mandatory)]$Job)
    $line = $Job.Lines | Where-Object { $_ -match 'Rotation summary: candidates=(\d+) rotated=(\d+) skipped=(\d+) failed=(\d+) accessMarked=(\d+)' } | Select-Object -First 1
    if (-not $line) { throw "No summary line in job $($Job.JobId). Streams:`n$($Job.Text)" }
    $null = $line -match 'candidates=(\d+) rotated=(\d+) skipped=(\d+) failed=(\d+) accessMarked=(\d+)'
    [pscustomobject]@{ Candidates = [int]$Matches[1]; Rotated = [int]$Matches[2]; Skipped = [int]$Matches[3]; Failed = [int]$Matches[4]; AccessMarked = [int]$Matches[5] }
}

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Because)
    if (-not $Condition) { throw $Because }
}

function ConvertTo-Base64 {
    param([Parameter(Mandatory)][string]$Text)
    [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function Test-WindowsPassword {
    param([Parameter(Mandatory)][string]$Password)
    $script = @"
Add-Type -AssemblyName System.DirectoryServices.AccountManagement
`$pw = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$(ConvertTo-Base64 $Password)'))
`$ctx = [System.DirectoryServices.AccountManagement.PrincipalContext]::new('Machine')
if (`$ctx.ValidateCredentials('$AdminUsername', `$pw)) { 'CRED_OK' } else { 'CRED_BAD' }
"@
    $result = Invoke-AzVMRunCommand -ResourceGroupName $LabResourceGroupName -VMName $WindowsVMName `
        -CommandId 'RunPowerShellScript' -ScriptString $script -ErrorAction Stop
    $text = ($result.Value | ForEach-Object { $_.Message }) -join "`n"
    if ($text -notmatch 'CRED_OK') { throw "Windows password check did not pass: $($text.Trim())" }
}

function Test-LinuxPassword {
    param([Parameter(Mandatory)][string]$Password)
    $script = @"
PW=`$(echo '$(ConvertTo-Base64 $Password)' | base64 -d)
python3 - "`$PW" <<'PY' 2>/dev/null
import sys, crypt, spwd
h = spwd.getspnam('$AdminUsername').sp_pwdp
print('PW_OK' if crypt.crypt(sys.argv[1], h) == h else 'PW_BAD')
PY
"@
    $result = Invoke-AzVMRunCommand -ResourceGroupName $LabResourceGroupName -VMName $LinuxVMName `
        -CommandId 'RunShellScript' -ScriptString $script -ErrorAction Stop
    $text = ($result.Value | ForEach-Object { $_.Message }) -join "`n"
    if ($text -notmatch 'PW_OK') { throw "Linux password check did not pass: $($text.Trim())" }
}

function Get-SecretPlain { param([Parameter(Mandatory)][string]$Name); Get-AzKeyVaultSecret -VaultName $VaultName -Name $Name -AsPlainText -ErrorAction Stop }
function Get-SecretMeta { param([Parameter(Mandatory)][string]$Name); Get-AzKeyVaultSecret -VaultName $VaultName -Name $Name -ErrorAction Stop }

function Set-Due {
    # The same thing the runbook's access scan does, done by hand: pull the expiry to now.
    param([Parameter(Mandatory)][string]$SecretName)
    $out = [pscustomobject]@{ SecretName = $SecretName; AccessedBy = 'orchestrator-smoke@example.test' } |
        Register-CredentialAccess -VaultName $VaultName -GracePeriodHours 0 -Confirm:$false
    Assert-True ([bool]$out.Applied) "could not make $SecretName due"
}

function Get-WorkspaceId {
    $var = Get-AzAutomationVariable -ResourceGroupName $AutomationResourceGroupName -AutomationAccountName $AutomationAccountName -Name 'CR_WorkspaceId' -ErrorAction Stop
    [string]$var.Value
}

function Wait-Query {
    # Log Analytics ingestion is minutes, not seconds, and not ordered: a record written
    # later can show up before one written earlier. So a step that expects several rows
    # says what "enough" means through -Until, rather than taking the first row that lands.
    param(
        [Parameter(Mandatory)][string]$Query,
        [scriptblock]$Until = { param($rows) $rows.Count -gt 0 },
        [int]$TimeoutMinutes = 25
    )
    $workspace = Get-WorkspaceId
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        try {
            $rows = @((Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace -Query $Query -ErrorAction Stop).Results)
        }
        catch {
            # A table that has not received its first row yet answers with an error, not zero rows.
            Write-Host "  query not ready yet: $($_.Exception.Message.Split("`n")[0])" -ForegroundColor DarkGray
            $rows = @()
        }
        if (& $Until $rows) { return $rows }
        Write-Host "  waiting for ingestion ($([int]($deadline - (Get-Date)).TotalMinutes) min left)" -ForegroundColor DarkGray
        Start-Sleep -Seconds 60
    } while ((Get-Date) -lt $deadline)
    throw "Query returned nothing within $TimeoutMinutes minutes: $Query"
}

# ---------------------------------------------------------------------------
# the steps
# ---------------------------------------------------------------------------

$winPw = "$WindowsVMName-$AdminUsername-pw"
$lnxPw = "$LinuxVMName-$AdminUsername-pw"
$script:runStartedAt = if ($PSBoundParameters.ContainsKey('Since')) { $Since.ToUniversalTime() } else { (Get-Date).ToUniversalTime() }

$steps = [ordered]@{}

$steps['dry-run-reports-and-changes-nothing'] = {
    Set-Due $winPw
    $before = (Get-SecretMeta $winPw).Version
    $job = Invoke-RunbookJob -Parameters @{ DryRun = $true }
    Assert-True ($job.Status -eq 'Completed') "job $($job.JobId) ended $($job.Status): $($job.Exception)"
    Assert-True ($job.Text -match "2 VM\(s\) tagged CredentialRotation=enabled") "discovery line missing:`n$($job.Text)"
    Assert-True ($job.Text -match "Would rotate Password for $WindowsVMName \[Access\]") "WhatIf line missing:`n$($job.Text)"
    Assert-True ($job.Text -match 'DRY RUN - nothing was changed') 'dry-run warning missing'
    $s = Get-Summary $job
    Assert-True ($s.Candidates -eq 1 -and $s.Rotated -eq 0 -and $s.Failed -eq 0) "summary: $($s | ConvertTo-Json -Compress)"
    Assert-True ((Get-SecretMeta $winPw).Version -eq $before) 'dry run must not create a new secret version'
    "job $($job.JobId): found both tagged VMs, 1 due, would rotate, changed nothing"
}

$steps['live-run-rotates-only-what-is-due'] = {
    $before = (Get-SecretMeta $winPw).Version
    $lnxBefore = (Get-SecretMeta $lnxPw).Version
    $job = Invoke-RunbookJob -Parameters @{ DryRun = $false }
    Assert-True ($job.Status -eq 'Completed') "job $($job.JobId) ended $($job.Status): $($job.Exception)"
    $s = Get-Summary $job
    Assert-True ($s.Candidates -eq 1 -and $s.Rotated -eq 1 -and $s.Failed -eq 0) "summary: $($s | ConvertTo-Json -Compress)`n$($job.Text)"
    $after = Get-SecretMeta $winPw
    Assert-True ($after.Version -ne $before) 'expected a new secret version'
    Assert-True ($after.Tags.LastTrigger -eq 'Access' -and -not $after.Tags.ContainsKey('RotationReason')) "tags: $($after.Tags | ConvertTo-Json -Compress)"
    Assert-True ((Get-SecretMeta $lnxPw).Version -eq $lnxBefore) 'the Linux secret was not due and must be untouched'
    Test-WindowsPassword -Password (Get-SecretPlain $winPw)
    "job $($job.JobId): rotated the one due credential (reason Access), left the other machine alone, guest accepts the password"
}

$steps['hold-tag-takes-machine-out-of-scope'] = {
    $vm = Get-AzVM -ResourceGroupName $LabResourceGroupName -Name $LinuxVMName
    $null = Update-AzTag -ResourceId $vm.Id -Tag @{ $HoldTagName = 'true' } -Operation Merge -ErrorAction Stop
    try {
        Set-Due $lnxPw
        $before = (Get-SecretMeta $lnxPw).Version
        $job = Invoke-RunbookJob -Parameters @{ DryRun = $false }
        Assert-True ($job.Status -eq 'Completed') "job $($job.JobId) ended $($job.Status): $($job.Exception)"
        Assert-True ($job.Text -match "\[$LinuxVMName\] on hold, skipping") "hold line missing:`n$($job.Text)"
        $s = Get-Summary $job
        Assert-True ($s.Candidates -eq 0 -and $s.Rotated -eq 0) "summary with hold: $($s | ConvertTo-Json -Compress)"
        Assert-True ((Get-SecretMeta $lnxPw).Version -eq $before) 'held machine must not be rotated'
    }
    finally {
        $null = Update-AzTag -ResourceId $vm.Id -Tag @{ $HoldTagName = 'true' } -Operation Delete -ErrorAction Stop
    }
    $job2 = Invoke-RunbookJob -Parameters @{ DryRun = $false }
    $s2 = Get-Summary $job2
    Assert-True ($job2.Status -eq 'Completed' -and $s2.Rotated -eq 1 -and $s2.Failed -eq 0) "after removing the hold: $($s2 | ConvertTo-Json -Compress)`n$($job2.Text)"
    Test-LinuxPassword -Password (Get-SecretPlain $lnxPw)
    "job $($job.JobId): held machine skipped with its credential due; job $($job2.JobId): rotated once the tag came off, guest accepts the password"
}

$steps['records-land-in-the-custom-table'] = {
    $since = $script:runStartedAt.ToString('o')
    $rows = Wait-Query -Query "CredentialRotation_CL | where TimeGenerated > datetime('$since') | where Result == 'Rotated' | project VMName, CredentialType, TriggerReason, TriggeredBy, NewSecretVersion | order by VMName asc" `
        -Until { param($rows) $names = @($rows | ForEach-Object { $_.VMName }); $WindowsVMName -in $names -and $LinuxVMName -in $names }
    $vms = @($rows | ForEach-Object { $_.VMName } | Sort-Object -Unique)
    Assert-True ($WindowsVMName -in $vms -and $LinuxVMName -in $vms) "rows found for: $($vms -join ', ')"
    Assert-True (@($rows | Where-Object { $_.TriggeredBy -ne 'automation' }).Count -eq 0) 'every record from the runbook should say TriggeredBy=automation'
    "$($rows.Count) rotation record(s) in CredentialRotation_CL for both machines, TriggeredBy=automation"
}

$steps['human-read-is-detected-and-rotated'] = {
    # A read with a upn claim, exactly what a person at a prompt produces.
    $before = Get-SecretMeta $winPw
    $null = Get-SecretPlain $winPw
    $readAt = (Get-Date).ToUniversalTime()
    $rows = Wait-Query -Query "AZKVAuditLogs | where TimeGenerated > datetime('$($readAt.AddMinutes(-2).ToString('o'))') | where OperationName == 'SecretGet' and ResultType == 'Success' | extend Upn = tostring(Identity.claim.upn) | where isnotempty(Upn) | extend SecretName = tostring(split(tostring(parse_url(RequestUri).Path), '/')[2]) | where SecretName == '$winPw' | project TimeGenerated, Upn, SecretName"
    Assert-True ($rows.Count -ge 1) 'the read should be in AZKVAuditLogs'

    $job = Invoke-RunbookJob -Parameters @{ DryRun = $false }
    Assert-True ($job.Status -eq 'Completed') "job $($job.JobId) ended $($job.Status): $($job.Exception)"
    $s = Get-Summary $job
    Assert-True ($s.AccessMarked -ge 1) "the runbook should have marked the read secret; summary: $($s | ConvertTo-Json -Compress)`n$($job.Text)"
    Assert-True ($s.Rotated -ge 1 -and $s.Failed -eq 0) "the marked secret should rotate in the same run; summary: $($s | ConvertTo-Json -Compress)"
    $after = Get-SecretMeta $winPw
    Assert-True ($after.Version -ne $before.Version -and $after.Tags.LastTrigger -eq 'Access') "after: version changed=$($after.Version -ne $before.Version) tags=$($after.Tags | ConvertTo-Json -Compress)"
    Test-WindowsPassword -Password (Get-SecretPlain $winPw)
    "job $($job.JobId): read by $($rows[0].Upn) seen in the audit log, expiry pulled forward, credential replaced in the same run, guest accepts it"
}

$steps['overlapping-jobs-do-not-fight'] = {
    $first = Start-AzAutomationRunbook -ResourceGroupName $AutomationResourceGroupName -AutomationAccountName $AutomationAccountName -Name $RunbookName -Parameters @{ DryRun = $true } -ErrorAction Stop
    $second = Invoke-RunbookJob -Parameters @{ DryRun = $true }
    $deadline = (Get-Date).AddMinutes(15)
    do {
        Start-Sleep -Seconds 15
        $f = Get-AzAutomationJob -ResourceGroupName $AutomationResourceGroupName -AutomationAccountName $AutomationAccountName -Id $first.JobId
    } while ($f.Status -notin @('Completed', 'Failed', 'Stopped', 'Suspended') -and (Get-Date) -lt $deadline)
    $firstText = (Get-AzAutomationJobOutput -ResourceGroupName $AutomationResourceGroupName -AutomationAccountName $AutomationAccountName -Id $first.JobId -Stream Any | ForEach-Object { $_.Summary }) -join "`n"
    $both = $firstText + "`n" + $second.Text
    $bailed = ([regex]::Matches($both, 'Another rotation job is already running')).Count
    $summaries = ([regex]::Matches($both, 'Rotation summary:')).Count
    Assert-True ($bailed -eq 1 -and $summaries -eq 1) "expected exactly one job to yield and one to run; yielded=$bailed ran=$summaries`n--- first ---`n$firstText`n--- second ---`n$($second.Text)"
    "two jobs started together: one yielded to the other, one ran"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

$selected = if ($Step) { $steps.Keys | Where-Object { $_ -in $Step } } else { $steps.Keys }
$results = foreach ($name in $selected) {
    Write-Host "`n### $name" -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $detail = & $steps[$name]
        [pscustomobject]@{ Step = $name; Result = 'PASS'; Detail = [string]$detail; Seconds = [int]$sw.Elapsed.TotalSeconds }
    }
    catch {
        [pscustomobject]@{ Step = $name; Result = 'FAIL'; Detail = $_.Exception.Message; Seconds = [int]$sw.Elapsed.TotalSeconds }
    }
}

$results | Format-Table -AutoSize -Wrap Step, Result, Seconds, Detail
$results
