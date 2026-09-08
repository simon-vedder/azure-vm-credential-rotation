<#
.SYNOPSIS
    Runs the module against the lab VMs and checks every result on the guest.

.DESCRIPTION
    Exercises Invoke-CredentialRotation and Register-CredentialAccess from a workstation
    against the two machines deploy/lab.bicep creates, and verifies each rotation where it
    matters: on the machine. Windows passwords are validated with the local account
    principal on the VM, Linux passwords against the shadow hash, and SSH keys by logging
    in to the VM from itself. Every check runs through Run Command, so the lab needs no
    public IP.

    The steps build on each other and run in order. Pass -Step to run a subset; the
    earlier ones leave the vault in a state the later ones assume, so a subset may need
    a full run first.

    This changes credentials on real machines. Point it only at the lab.

.PARAMETER VaultName
    The lab Key Vault. deploy/lab.bicep prints it as an output.

.PARAMETER ResourceGroupName
    The lab resource group.

.PARAMETER Step
    Names of steps to run. Default is all of them, in order.

.PARAMETER SkipPowerCycle
    Leaves out the step that stops a VM to prove a stopped machine is skipped, which
    takes several minutes.

.EXAMPLE
    ./tests/manual/Invoke-LabSmokeTest.ps1 -VaultName kv-crot-abc123 -ResourceGroupName rg-crot-lab

.EXAMPLE
    ./tests/manual/Invoke-LabSmokeTest.ps1 -VaultName kv-crot-abc123 -ResourceGroupName rg-crot-lab -Step 'resume-pending'

.INPUTS
    None

.OUTPUTS
    One PSCustomObject per step: Step, Result (PASS/FAIL), Detail, Seconds.

.NOTES
    Author:              Simon Vedder (simonvedder.com)
    Version:             1.0.0
    Created:             2026-09-08
    LastModified:        2026-09-08
    RequiredPermissions: Key Vault Secrets Officer on the vault, Virtual Machine Contributor on the lab resource group
    Prerequisites:       PowerShell 7.2, Az.Accounts, Az.Compute, Az.KeyVault, Az.Resources; an Azure context on the lab subscription
#>
# The parameters are read inside the step script blocks and helper functions, which the rule
# does not follow.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VaultName,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [string]$WindowsVMName = 'vm-crot-win-01',
    [string]$LinuxVMName = 'vm-crot-lnx-01',
    [string]$AdminUsername = 'labadmin',
    [string[]]$Step,
    [switch]$SkipPowerCycle
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'AzureVMCredentialRotation') -Force

# ---------------------------------------------------------------------------
# guest-side checks
# ---------------------------------------------------------------------------

function ConvertTo-Base64 {
    param([Parameter(Mandatory)][string]$Text)
    [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function Test-WindowsPassword {
    # ValidateCredentials against the machine context is a real logon check without
    # opening a session; it exercises the same path RDP would.
    param([Parameter(Mandatory)][string]$Password)

    $script = @"
Add-Type -AssemblyName System.DirectoryServices.AccountManagement
`$pw = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$(ConvertTo-Base64 $Password)'))
`$ctx = [System.DirectoryServices.AccountManagement.PrincipalContext]::new('Machine')
if (`$ctx.ValidateCredentials('$AdminUsername', `$pw)) { 'CRED_OK' } else { 'CRED_BAD' }
"@
    $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $WindowsVMName `
        -CommandId 'RunPowerShellScript' -ScriptString $script -ErrorAction Stop
    $text = ($result.Value | ForEach-Object { $_.Message }) -join "`n"
    if ($text -notmatch 'CRED_OK') { throw "Windows password check did not pass: $($text.Trim())" }
}

function Test-LinuxCredential {
    # Password: compare against the shadow hash through libcrypt, which handles yescrypt.
    # SSH key: the honest test is a login, so the VM logs in to itself over loopback with
    # the private key from the vault.
    param([string]$Password, [string]$PrivateKeyPem)

    $lines = @('set -e')
    if ($Password) {
        $lines += "PW=`$(echo '$(ConvertTo-Base64 $Password)' | base64 -d)"
        $lines += @'
python3 - "$PW" <<'PY' 2>/dev/null
import sys, crypt, spwd
h = spwd.getspnam('LABUSER').sp_pwdp
print('PW_OK' if crypt.crypt(sys.argv[1], h) == h else 'PW_BAD')
PY
'@ -replace 'LABUSER', $AdminUsername
    }
    if ($PrivateKeyPem) {
        $lines += "KEY=`$(mktemp); echo '$(ConvertTo-Base64 $PrivateKeyPem)' | base64 -d > `$KEY; chmod 600 `$KEY"
        $lines += "ssh -i `$KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 $AdminUsername@127.0.0.1 'echo SSH_OK' 2>&1 || echo SSH_BAD"
        $lines += 'rm -f $KEY'
    }

    $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $LinuxVMName `
        -CommandId 'RunShellScript' -ScriptString ($lines -join "`n") -ErrorAction Stop
    $text = ($result.Value | ForEach-Object { $_.Message }) -join "`n"
    if ($Password -and $text -notmatch 'PW_OK') { throw "Linux password check did not pass: $($text.Trim())" }
    if ($PrivateKeyPem -and $text -notmatch 'SSH_OK') { throw "SSH key login did not pass: $($text.Trim())" }
}

function Get-SecretPlain {
    param([Parameter(Mandatory)][string]$Name)
    Get-AzKeyVaultSecret -VaultName $VaultName -Name $Name -AsPlainText -ErrorAction Stop
}

function Get-SecretMeta {
    param([Parameter(Mandatory)][string]$Name)
    Get-AzKeyVaultSecret -VaultName $VaultName -Name $Name -ErrorAction Stop
}

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Because)
    if (-not $Condition) { throw $Because }
}

# ---------------------------------------------------------------------------
# the steps
# ---------------------------------------------------------------------------

$winPw = "$WindowsVMName-$AdminUsername-pw"
$lnxPw = "$LinuxVMName-$AdminUsername-pw"
$lnxPriv = "$LinuxVMName-$AdminUsername-ssh-priv"
$lnxPub = "$LinuxVMName-$AdminUsername-ssh-pub"

$steps = [ordered]@{}

$steps['whatif-named-windows'] = {
    $r = Invoke-CredentialRotation -VaultName $VaultName -VMName $WindowsVMName -WhatIf
    Assert-True ($r.Candidates -eq 1) "expected 1 candidate, got $($r.Candidates)"
    Assert-True ($r.Records[0].Result -eq 'WhatIf') "expected WhatIf, got $($r.Records[0].Result)"
    Assert-True ($r.Records[0].TriggerReason -eq 'Missing') "expected Missing, got $($r.Records[0].TriggerReason)"
    Assert-True ($null -eq (Get-AzKeyVaultSecret -VaultName $VaultName -Name $winPw)) 'WhatIf must not create the secret'
    "candidate=$($r.Candidates) result=WhatIf reason=Missing, vault untouched"
}

$steps['rotate-windows-named'] = {
    $r = Invoke-CredentialRotation -VaultName $VaultName -VMName $WindowsVMName -Confirm:$false
    Assert-True ($r.Rotated -eq 1 -and $r.Failed -eq 0) "expected 1 rotated, got rotated=$($r.Rotated) failed=$($r.Failed)"
    $rec = $r.Records[0]
    Assert-True ($rec.TriggerReason -eq 'Missing' -and $rec.OSType -eq 'Windows' -and $rec.CredentialType -eq 'Password') "record: $($rec | ConvertTo-Json -Compress)"
    $meta = Get-SecretMeta $winPw
    $days = ($meta.Expires.ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalDays
    Assert-True ($days -gt 89.9 -and $days -lt 90.1) "expiry should be 90 days out, is $([math]::Round($days, 2))"
    Assert-True ($meta.Tags.LastTrigger -eq 'Missing' -and $meta.Tags.RotatedBy -eq 'azure-vm-credential-rotation') "tags: $($meta.Tags | ConvertTo-Json -Compress)"
    $pending = Get-SecretMeta "$winPw-pending"
    Assert-True ($pending.Tags.State -eq 'consumed') "staging secret should be consumed, is $($pending.Tags.State)"
    Test-WindowsPassword -Password (Get-SecretPlain $winPw)
    "rotated, reason=Missing, expires in $([math]::Round($days, 1)) d, staging consumed, guest accepts the password"
}

$steps['rotate-linux-named'] = {
    $r = Invoke-CredentialRotation -VaultName $VaultName -VMName $LinuxVMName -Confirm:$false
    Assert-True ($r.Rotated -eq 2 -and $r.Failed -eq 0) "expected 2 rotated, got rotated=$($r.Rotated) failed=$($r.Failed)"
    $types = @($r.Records | ForEach-Object { $_.CredentialType } | Sort-Object)
    Assert-True (($types -join ',') -eq 'Password,SSHKey') "credential types: $($types -join ',')"
    Assert-True (@($r.Records | Where-Object { $_.TriggerReason -ne 'Missing' }).Count -eq 0) 'every reason should be Missing'
    $pub = Get-SecretPlain $lnxPub
    Assert-True ($pub -like 'ssh-rsa *') 'public key secret should be an ssh-rsa line'
    Test-LinuxCredential -Password (Get-SecretPlain $lnxPw) -PrivateKeyPem (Get-SecretPlain $lnxPriv)
    'password + SSH key rotated, both reason=Missing, guest accepts the password and the key logs in'
}

$steps['rotate-linux-again-is-manual'] = {
    $before = @((Get-SecretMeta $lnxPw).Version, (Get-SecretMeta $lnxPriv).Version)
    $r = Invoke-CredentialRotation -VaultName $VaultName -VMName $LinuxVMName -Confirm:$false
    Assert-True ($r.Rotated -eq 2) "expected 2 rotated, got $($r.Rotated)"
    Assert-True (@($r.Records | Where-Object { $_.TriggerReason -ne 'Manual' }).Count -eq 0) "reasons: $(($r.Records | ForEach-Object { $_.TriggerReason }) -join ',')"
    foreach ($rec in $r.Records) {
        Assert-True ($rec.PreviousSecretVersion -in $before -and $rec.NewSecretVersion -notin $before) "versions did not advance: $($rec | ConvertTo-Json -Compress)"
    }
    Test-LinuxCredential -Password (Get-SecretPlain $lnxPw) -PrivateKeyPem (Get-SecretPlain $lnxPriv)
    'second run by name rotates again with reason=Manual, versions advanced, guest accepts the new values'
}

$steps['only-if-due-leaves-fresh-alone'] = {
    $vms = @((Get-AzVM -ResourceGroupName $ResourceGroupName -Name $WindowsVMName), (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $LinuxVMName))
    $r = Invoke-CredentialRotation -VaultName $VaultName -VM $vms -OnlyIfDue -Confirm:$false
    Assert-True ($r.Candidates -eq 0) "expected 0 candidates, got $($r.Candidates)"
    'two machines handed in with -OnlyIfDue, 0 candidates because everything expires in 90 days'
}

$steps['only-if-due-with-threshold'] = {
    $vms = @((Get-AzVM -ResourceGroupName $ResourceGroupName -Name $WindowsVMName), (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $LinuxVMName))
    $r = Invoke-CredentialRotation -VaultName $VaultName -VM $vms -OnlyIfDue -ThresholdDays 100 -Confirm:$false
    Assert-True ($r.Candidates -eq 3 -and $r.Rotated -eq 3) "expected 3/3, got candidates=$($r.Candidates) rotated=$($r.Rotated)"
    Assert-True (@($r.Records | Where-Object { $_.TriggerReason -ne 'Expiry' }).Count -eq 0) "reasons: $(($r.Records | ForEach-Object { $_.TriggerReason }) -join ',')"
    Test-WindowsPassword -Password (Get-SecretPlain $winPw)
    '-ThresholdDays 100 makes all three credentials due, all rotated with reason=Expiry'
}

$steps['threshold-without-due-warns'] = {
    $r = Invoke-CredentialRotation -VaultName $VaultName -VMName $WindowsVMName -ThresholdDays 5 -WhatIf -WarningVariable w -WarningAction SilentlyContinue
    Assert-True (@($w | Where-Object { $_ -like '*-ThresholdDays was given without -OnlyIfDue*' }).Count -eq 1) "warnings: $($w -join ' | ')"
    Assert-True ($r.Candidates -eq 1) 'the machine is still a candidate'
    'passing -ThresholdDays without -OnlyIfDue warns and rotates anyway'
}

$steps['access-pulls-expiry-then-due'] = {
    $finding = [pscustomobject]@{ SecretName = $winPw; AccessedBy = 'smoke@example.test'; LastAccessedAt = (Get-Date).ToUniversalTime().AddMinutes(-30) }
    $out = $finding | Register-CredentialAccess -VaultName $VaultName -GracePeriodHours 0 -Confirm:$false
    Assert-True ($out.Applied) 'expiry should have been moved'
    $meta = Get-SecretMeta $winPw
    Assert-True ($meta.Tags.RotationReason -eq 'Access' -and $meta.Tags.LastAccessedBy -eq 'smoke@example.test') "tags after access: $($meta.Tags | ConvertTo-Json -Compress)"
    Assert-True ($meta.Expires.ToUniversalTime() -lt (Get-Date).ToUniversalTime().AddMinutes(5)) 'expiry should be now'

    $r = Invoke-CredentialRotation -VaultName $VaultName -VMName $WindowsVMName -OnlyIfDue -Confirm:$false
    Assert-True ($r.Rotated -eq 1 -and $r.Records[0].TriggerReason -eq 'Access') "expected Access rotation, got rotated=$($r.Rotated) reason=$($r.Records[0].TriggerReason)"
    $after = Get-SecretMeta $winPw
    Assert-True ($after.Tags.LastTrigger -eq 'Access' -and -not $after.Tags.ContainsKey('RotationReason')) "tags after rotation: $($after.Tags | ConvertTo-Json -Compress)"
    Test-WindowsPassword -Password (Get-SecretPlain $winPw)
    'pipeline finding moved the expiry to now; -OnlyIfDue then rotated with reason=Access and cleared the marker'
}

$steps['skip-ssh-keys'] = {
    $r = Invoke-CredentialRotation -VaultName $VaultName -VMName $LinuxVMName -SkipSshKeys -Confirm:$false
    Assert-True ($r.Candidates -eq 1 -and $r.Records[0].CredentialType -eq 'Password') "expected password only, got $(($r.Records | ForEach-Object { $_.CredentialType }) -join ',')"
    Test-LinuxCredential -Password (Get-SecretPlain $lnxPw) -PrivateKeyPem (Get-SecretPlain $lnxPriv)
    '-SkipSshKeys rotates the password only; the previous key still logs in'
}

$steps['secret-name-template'] = {
    $r = Invoke-CredentialRotation -VaultName $VaultName -VMName $WindowsVMName -SecretNameTemplate 'lab-{vm}-{kind}' -Confirm:$false
    Assert-True ($r.Rotated -eq 1 -and $r.Records[0].SecretName -eq "lab-$WindowsVMName-pw" -and $r.Records[0].TriggerReason -eq 'Missing') "record: $($r.Records[0] | ConvertTo-Json -Compress)"
    Test-WindowsPassword -Password (Get-SecretPlain "lab-$WindowsVMName-pw")
    $threw = $null
    try { Invoke-CredentialRotation -VaultName $VaultName -VMName $WindowsVMName -SecretNameTemplate '{user}-{kind}' -WhatIf } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -like '*must contain {vm}*') "template without {vm} should be refused, got: $threw"
    "custom template wrote lab-$WindowsVMName-pw as a new secret; a template without {vm} is refused"
}

$steps['resume-pending'] = {
    # Simulate a run that died between staging and applying: a staged value the VM has
    # never seen. The next run must apply exactly that value and promote it.
    $staged = 'Staged' + (-join ((65..90) + (97..122) + (50..57) | Get-Random -Count 16 | ForEach-Object { [char]$_ })) + '!x'
    $null = Set-AzKeyVaultSecret -VaultName $VaultName -Name "$winPw-pending" `
        -SecretValue (ConvertTo-SecureString $staged -AsPlainText -Force) `
        -Expires (Get-Date).ToUniversalTime().AddDays(1) `
        -Tag @{ State = 'pending'; VMName = $WindowsVMName; AdminName = $AdminUsername; CreatedAt = (Get-Date).ToUniversalTime().ToString('o') }
    $r = Invoke-CredentialRotation -VaultName $VaultName -VMName $WindowsVMName -Confirm:$false
    Assert-True ($r.Rotated -eq 1 -and $r.Records[0].TriggerReason -eq 'ResumePending') "expected ResumePending, got rotated=$($r.Rotated) reason=$($r.Records[0].TriggerReason)"
    Assert-True ((Get-SecretPlain $winPw) -eq $staged) 'the live secret must hold the staged value, not a fresh one'
    Assert-True ((Get-SecretMeta "$winPw-pending").Tags.State -eq 'consumed') 'staging secret should be consumed'
    Test-WindowsPassword -Password $staged
    'an open staging secret is resumed: same value applied to the guest, promoted, staging closed'
}

$steps['resume-expired-pending'] = {
    # The KNOWN-ISSUES entry: a machine off for longer than the one-day staging expiry.
    $staged = 'Expired' + (-join ((65..90) + (97..122) + (50..57) | Get-Random -Count 16 | ForEach-Object { [char]$_ })) + '!x'
    $null = Set-AzKeyVaultSecret -VaultName $VaultName -Name "$winPw-pending" `
        -SecretValue (ConvertTo-SecureString $staged -AsPlainText -Force) `
        -Expires (Get-Date).ToUniversalTime().AddDays(-2) `
        -Tag @{ State = 'pending'; VMName = $WindowsVMName; AdminName = $AdminUsername; CreatedAt = (Get-Date).ToUniversalTime().AddDays(-2).ToString('o') }
    $r = Invoke-CredentialRotation -VaultName $VaultName -VMName $WindowsVMName -Confirm:$false
    Assert-True ($r.Rotated -eq 1 -and $r.Records[0].TriggerReason -eq 'ResumePending') "expected ResumePending, got rotated=$($r.Rotated) failed=$($r.Failed) reason=$($r.Records[0].TriggerReason) detail=$($r.Records[0].Detail)"
    Assert-True ((Get-SecretPlain $winPw) -eq $staged) 'the live secret must hold the staged value'
    Test-WindowsPassword -Password $staged
    'a staging secret expired two days ago is still read and resumed'
}

$steps['unknown-vm-name-throws'] = {
    $threw = $null
    try { Invoke-CredentialRotation -VaultName $VaultName -VMName 'vm-does-not-exist' -WhatIf } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -like '*No VM named*') "expected a clear error, got: $threw"
    'an unknown name fails before anything is touched'
}

$steps['stopped-vm-is-skipped'] = {
    if ($SkipPowerCycle) { return 'skipped on request' }
    $null = Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $LinuxVMName -Force -ErrorAction Stop
    try {
        $r = Invoke-CredentialRotation -VaultName $VaultName -VMName $LinuxVMName -Confirm:$false
        Assert-True ($r.Skipped -eq 2 -and $r.Rotated -eq 0 -and $r.Failed -eq 0) "expected 2 skipped, got rotated=$($r.Rotated) skipped=$($r.Skipped) failed=$($r.Failed)"
        Assert-True (@($r.Records | Where-Object { $_.Detail -ne 'VM not running' }).Count -eq 0) "details: $(($r.Records | ForEach-Object { $_.Detail }) -join ',')"
        Assert-True ((Get-SecretMeta "$lnxPw-pending").Tags.State -eq 'consumed') 'nothing may be staged for a stopped machine'
    }
    finally {
        $null = Start-AzVM -ResourceGroupName $ResourceGroupName -Name $LinuxVMName -ErrorAction Stop
    }
    'a deallocated machine yields Skipped / VM not running for both credentials, nothing staged, VM started again'
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

# pwsh -File hands a comma-separated value over as one string, so split it here.
$wanted = @($Step | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$selected = if ($wanted) { $steps.Keys | Where-Object { $_ -in $wanted } } else { $steps.Keys }
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
