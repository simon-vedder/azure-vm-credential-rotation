<#
.SYNOPSIS
    Measures what a rotation costs per machine, so the scale limit can be stated rather than guessed.

.DESCRIPTION
    Azure Automation unloads a runbook job after three hours and the rotation is sequential,
    so the size of an estate that fits in one pass is a division: three hours over the cost of
    a machine. This script measures that cost against a real fleet, in the four phases that
    make it up.

        discovery   one Get-AzVM list per subscription, then a full fetch per selected
                    machine - the list form has no OSProfile, so the orchestrator refetches
        candidates  Get-RotationCandidate: two Key Vault metadata reads per credential
        cold        a rotation of every credential, which is the first pass over a new estate
        steady      a -OnlyIfDue pass with nothing due, which is every pass after that

    The distinction that matters is the last two. A scheduled pass over a large estate spends
    almost all of its time in discovery and candidates; rotations are rare, because a 90-day
    validity means roughly one machine in ninety comes due each day. The wave that hurts is
    the first one, when every credential is missing at once.

    Numbers from a workstation are not numbers from the Automation sandbox: the sandbox has
    less CPU, which shows up in key generation, and it sits closer to the ARM endpoints. Run
    the same fleet through the deployed runbook to get the figure the three-hour limit applies
    to; this script prints the local one and says so.

    The cold phase rotates credentials on every machine it is given. Point it at a lab.

.PARAMETER VaultName
    Key Vault for the fleet's secrets.

.PARAMETER ResourceGroupName
    Resource group holding the fleet, as built by deploy/lab-scale.bicep.

.PARAMETER SkipCold
    Leave out the rotation phase and measure only the read paths. Use it to repeat the
    steady-state measurement without changing credentials.

.PARAMETER JobLimitHours
    The job limit to extrapolate against. Three hours is Azure Automation's fair-share limit
    for a PowerShell runbook.

.EXAMPLE
    ./tests/manual/Measure-RotationThroughput.ps1 -VaultName kv-crot-abc -ResourceGroupName rg-crot-scale

.EXAMPLE
    # Read paths only, on a fleet whose credentials are already in place.
    ./tests/manual/Measure-RotationThroughput.ps1 -VaultName kv-crot-abc -ResourceGroupName rg-crot-scale -SkipCold

.INPUTS
    None

.OUTPUTS
    PSCustomObject with one entry per phase (Seconds, PerMachine, PerCredential) and the
    extrapolated capacity of a single job.

.NOTES
    Author:              Simon Vedder (simonvedder.com)
    Version:             1.0.0
    Created:             2026-09-08
    LastModified:        2026-09-08
    RequiredPermissions: Key Vault Secrets Officer on the vault, Virtual Machine Contributor on the fleet's resource group
    Prerequisites:       PowerShell 7.2, Az.Accounts, Az.Compute, Az.KeyVault, Az.Resources
#>
# Read inside the phase script blocks, which the rule does not follow.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VaultName,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [switch]$SkipCold,
    [ValidateRange(1, 24)][int]$JobLimitHours = 3
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'AzureVMCredentialRotation') -Force

function Measure-Phase {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    Write-Host "`n### $Name" -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = & $Body
    $sw.Stop()
    Write-Host ("  {0:N1} s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
    [pscustomobject]@{ Name = $Name; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 2); Result = $result }
}

# --- discovery -------------------------------------------------------------------------------
# What the orchestrator does before the module sees anything: list the subscription, keep the
# tagged machines, then fetch each one in full because the list form has no OSProfile.
$discovery = Measure-Phase 'discovery' {
    $all = @(Get-AzVM -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
    $tagged = @($all | Where-Object { $_.Tags.Keys -contains 'CredentialRotation' })
    $full = foreach ($vm in $tagged) { Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -ErrorAction Stop }
    @($full)
}
$machines = @($discovery.Result)
if ($machines.Count -eq 0) { throw "No tagged machines in $ResourceGroupName." }
Write-Host "  $($machines.Count) machine(s)" -ForegroundColor DarkGray

# --- candidates ------------------------------------------------------------------------------
# Two Key Vault metadata reads per credential. This is the part that grows with the estate
# whether or not anything is due.
$candidates = Measure-Phase 'candidates (cold, everything missing)' {
    @(Get-RotationCandidate -VaultName $VaultName -VM $machines -OnlyIfDue -ThresholdDays 14 4>$null)
}
$credentialCount = @($candidates.Result).Count
Write-Host "  $credentialCount credential(s)" -ForegroundColor DarkGray

# --- cold wave -------------------------------------------------------------------------------
$cold = if ($SkipCold) {
    [pscustomobject]@{ Name = 'cold rotation'; Seconds = $null; Result = $null }
}
else {
    Measure-Phase 'cold rotation (every credential)' {
        Invoke-CredentialRotation -VaultName $VaultName -VM $machines -Confirm:$false 4>$null 3>$null
    }
}

# --- steady state ----------------------------------------------------------------------------
# The same pass once the credentials are in place and nothing is near expiry: discovery plus
# candidate evaluation, no rotations. This is what a six-hourly job costs almost every time.
$steady = Measure-Phase 'steady state (-OnlyIfDue, nothing due)' {
    Invoke-CredentialRotation -VaultName $VaultName -VM $machines -OnlyIfDue -ThresholdDays 14 -Confirm:$false 4>$null 3>$null
}
if ($steady.Result.Candidates -ne 0 -and -not $SkipCold) {
    Write-Warning "The steady-state pass found $($steady.Result.Candidates) candidate(s); it should find none right after a cold wave."
}

# --- the arithmetic --------------------------------------------------------------------------
$limitSeconds = $JobLimitHours * 3600
# A real pass pays for both: the orchestrator discovers, then the module evaluates. Dividing the
# job limit by the evaluation alone would flatter the result by roughly half.
$readPerMachine = ($discovery.Seconds + $candidates.Seconds) / $machines.Count
$steadyPerMachine = $steady.Seconds / $machines.Count
$passPerMachine = ($discovery.Seconds + $steady.Seconds) / $machines.Count
$rotatePerCredential = if ($cold.Seconds) { $cold.Seconds / $credentialCount } else { $null }

$report = [pscustomobject]@{
    Machines               = $machines.Count
    Credentials            = $credentialCount
    DiscoverySeconds       = $discovery.Seconds
    CandidateSeconds       = $candidates.Seconds
    ColdRotationSeconds    = $cold.Seconds
    SteadyStateSeconds     = $steady.Seconds
    ReadSecondsPerMachine  = [math]::Round($readPerMachine, 2)
    SteadySecondsPerMachine = [math]::Round($steadyPerMachine, 2)
    PassSecondsPerMachine  = [math]::Round($passPerMachine, 2)
    RotateSecondsPerCredential = if ($rotatePerCredential) { [math]::Round($rotatePerCredential, 1) } else { $null }
    MachinesPerJobSteady   = [math]::Floor($limitSeconds / $passPerMachine)
    CredentialsPerJobCold  = if ($rotatePerCredential) { [math]::Floor($limitSeconds / $rotatePerCredential) } else { $null }
    JobLimitHours          = $JobLimitHours
    MeasuredFrom           = 'workstation'
}

Write-Host "`n=== per machine ===" -ForegroundColor Cyan
$report | Format-List Machines, Credentials, ReadSecondsPerMachine, SteadySecondsPerMachine, PassSecondsPerMachine, RotateSecondsPerCredential
Write-Host "=== what fits in a $JobLimitHours-hour job ===" -ForegroundColor Cyan
Write-Host ("  reconciling, nothing due : {0} machines (discovery + evaluation)" -f $report.MachinesPerJobSteady)
if ($report.CredentialsPerJobCold) {
    Write-Host ("  rotating every credential: {0} credentials" -f $report.CredentialsPerJobCold)
}
Write-Host "  Measured from a workstation. Run the same fleet through the deployed runbook for the" -ForegroundColor DarkGray
Write-Host "  figure the job limit actually applies to." -ForegroundColor DarkGray

$report
