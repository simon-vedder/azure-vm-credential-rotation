<#
.SYNOPSIS
    Shows what a rotation does when the admin account was renamed inside the guest.

.DESCRIPTION
    The threat model says VMAccess recreates the account named in the Azure OS profile
    if it no longer exists on the machine. CIS Level 1 recommends renaming the built-in
    administrator, and people rename provisioning accounts for the same reason - so this
    is the case worth measuring rather than asserting.

    The probe renames the OS-profile account on the lab VM, runs one rotation by name,
    and reports the local accounts and their group memberships before and after. It then
    restores the machine: the recreated account is removed and the renamed one gets its
    name back, so the vault and the guest are in step again after one more rotation.

    Run it against the lab only. It changes local accounts.

.PARAMETER VaultName
    The lab Key Vault.

.PARAMETER ResourceGroupName
    The lab resource group.

.PARAMETER VMName
    The VM to probe. Its OS type decides the commands.

.PARAMETER AdminUsername
    The account named in the VM's OS profile.

.EXAMPLE
    ./tests/manual/Invoke-RenamedAccountProbe.ps1 -VaultName kv-crot-abc123 -ResourceGroupName rg-crot-lab -VMName vm-crot-win-01

.INPUTS
    None

.OUTPUTS
    PSCustomObject with Before, After and Restored account listings, plus the rotation record.

.NOTES
    Author:              Simon Vedder (simonvedder.com)
    Version:             1.0.0
    Created:             2026-09-08
    LastModified:        2026-09-08
    RequiredPermissions: Key Vault Secrets Officer on the vault, Virtual Machine Contributor on the lab resource group
    Prerequisites:       PowerShell 7.2, Az.Accounts, Az.Compute, Az.KeyVault, Az.Resources
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VaultName,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$VMName,
    [string]$AdminUsername = 'labadmin'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'AzureVMCredentialRotation') -Force

$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
$guestIsWindows = [string]$vm.StorageProfile.OsDisk.OsType -eq 'Windows'
$renamed = "$AdminUsername-x"

function Invoke-Guest {
    param([Parameter(Mandatory)][string]$Script)
    $commandId = if ($guestIsWindows) { 'RunPowerShellScript' } else { 'RunShellScript' }
    $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName -CommandId $commandId -ScriptString $Script
    (($result.Value | ForEach-Object { $_.Message }) -join "`n").Trim()
}

$listAccounts = if ($guestIsWindows) {
    @'
Get-LocalUser | Where-Object { $_.Name -like 'LABUSER*' } | ForEach-Object {
    $user = $_
    $groups = (Get-LocalGroup | Where-Object { (Get-LocalGroupMember $_ -ErrorAction SilentlyContinue).SID -contains $user.SID }).Name -join ','
    '{0} enabled={1} rid={2} groups={3}' -f $user.Name, $user.Enabled, $user.SID.Value.Split('-')[-1], $groups
}
'@ -replace 'LABUSER', $AdminUsername
}
else {
    @'
for u in $(getent passwd | cut -d: -f1 | grep '^LABUSER'); do
  echo "$u uid=$(id -u $u) home=$(getent passwd $u | cut -d: -f6) groups=$(id -Gn $u | tr ' ' ',') sudoers=$(grep -l "$u" /etc/sudoers.d/* 2>/dev/null | wc -l)"
done
'@ -replace 'LABUSER', $AdminUsername
}

$rename = if ($guestIsWindows) { "Rename-LocalUser -Name '$AdminUsername' -NewName '$renamed'; 'renamed'" }
else { "usermod -l $renamed $AdminUsername && echo renamed" }

Write-Host "`n### before" -ForegroundColor Cyan
$before = Invoke-Guest $listAccounts
Write-Host $before

Write-Host "`n### renaming $AdminUsername to $renamed in the guest" -ForegroundColor Cyan
Write-Host (Invoke-Guest $rename)

Write-Host "`n### rotating by name" -ForegroundColor Cyan
$rotation = Invoke-CredentialRotation -VaultName $VaultName -VMName $VMName -Confirm:$false

Write-Host "`n### after" -ForegroundColor Cyan
$after = Invoke-Guest $listAccounts
Write-Host $after

Write-Host "`n### restoring" -ForegroundColor Cyan
$restore = if ($guestIsWindows) {
    "if (Get-LocalUser -Name '$AdminUsername' -ErrorAction SilentlyContinue) { Remove-LocalUser -Name '$AdminUsername' }; Rename-LocalUser -Name '$renamed' -NewName '$AdminUsername'; 'restored'"
}
else {
    "if id $AdminUsername >/dev/null 2>&1; then userdel $AdminUsername; fi; usermod -l $AdminUsername $renamed && echo restored"
}
Write-Host (Invoke-Guest $restore)
# One more rotation so the vault matches the restored account again.
$null = Invoke-CredentialRotation -VaultName $VaultName -VMName $VMName -Confirm:$false
$restored = Invoke-Guest $listAccounts
Write-Host $restored

[pscustomobject]@{
    VMName   = $VMName
    OSType   = if ($guestIsWindows) { 'Windows' } else { 'Linux' }
    Before   = $before
    After    = $after
    Restored = $restored
    Rotation = $rotation.Records | Select-Object Result, TriggerReason, Detail
}
