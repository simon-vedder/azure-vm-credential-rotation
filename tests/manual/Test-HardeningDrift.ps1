<#
.SYNOPSIS
    Checks whether a rotation moves anything a hardening baseline measures.

.DESCRIPTION
    "It works on a hardened image" and "it leaves the image hardened" are two different
    claims. The smoke test covers the first. This covers the second: it photographs the
    settings a CIS or STIG baseline actually checks, rotates a credential, photographs them
    again, and reports the difference.

    This is a drift check against the settings a credential change could plausibly touch, not
    a benchmark assessment. What it captures:

        Linux     sshd's effective configuration, PAM and pwquality, password aging on the
                  account, sudoers, the account list, permissions on the home and key files,
                  and the number of keys in authorized_keys
        Windows   the full local security policy (secedit), the audit policy, local group
                  membership, the enabled accounts, and the RDP setting

    The one difference expected on Linux is in `chage`: rotating a password sets the last
    change date, and with `-RemovePriorSshKeys` off the key count grows. Anything else is
    worth reading closely, which is why the whole diff is printed rather than a verdict.

    Run it against a lab. It rotates credentials.

.PARAMETER VaultName
    The lab Key Vault.

.PARAMETER ResourceGroupName
    The lab resource group.

.PARAMETER VMName
    The machine to check. Its OS decides which snapshot is taken.

.PARAMETER AdminUsername
    The account named in the VM's OS profile.

.EXAMPLE
    ./tests/manual/Test-HardeningDrift.ps1 -VaultName kv-crot-abc -ResourceGroupName rg-crot-drift -VMName vm-crot-lnx-d1

.INPUTS
    None

.OUTPUTS
    PSCustomObject with the two snapshots, the diff lines, and the rotation record.

.NOTES
    Author:              Simon Vedder (simonvedder.com)
    Version:             1.0.0
    Created:             2026-09-08
    LastModified:        2026-09-08
    RequiredPermissions: Key Vault Secrets Officer on the vault, Virtual Machine Contributor on the resource group
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
$scriptDir = [System.IO.Path]::GetTempPath()

$linuxSnapshot = @'
echo "== sshd"
mkdir -p /run/sshd
# Long values (algorithm lists) are folded to a digest: Run Command wraps them, and a wrap
# point that moves between two captures looks exactly like a changed setting.
/usr/sbin/sshd -T 2>/dev/null | sort | awk '{ if (length($0) > 100) { cmd = "printf %s \"" $0 "\" | sha256sum | cut -c1-12"; cmd | getline h; close(cmd); split($0, f, " "); print f[1] " <digest " h ">" } else print }'
echo "== pwquality"
grep -Ev '^\s*#|^\s*$' /etc/security/pwquality.conf 2>/dev/null | sort
echo "== pam common-password"
grep -Ev '^\s*#|^\s*$' /etc/pam.d/common-password 2>/dev/null
echo "== login.defs aging"
grep -E '^\s*(PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE|ENCRYPT_METHOD)' /etc/login.defs
echo "== chage"
chage -l LABUSER | grep -Ei 'minimum|maximum|warning|inactive|expires'
echo "== sudoers"
ls /etc/sudoers.d | sort
echo "== accounts"
getent passwd | cut -d: -f1,3 | sort
echo "== perms"
stat -c '%n %a %U:%G' /home/LABUSER /home/LABUSER/.ssh /home/LABUSER/.ssh/authorized_keys 2>/dev/null
echo "== authorized_keys count"
grep -c . /home/LABUSER/.ssh/authorized_keys 2>/dev/null || echo 0
echo "== mounts"
findmnt -no TARGET,OPTIONS /tmp /var/tmp /home 2>/dev/null | sort
'@ -replace 'LABUSER', $AdminUsername

$windowsSnapshot = @'
'== security policy'
secedit /export /cfg C:\Windows\Temp\drift.cfg /quiet | Out-Null
Get-Content C:\Windows\Temp\drift.cfg | Where-Object { $_ -match '=' -and $_ -notmatch 'Revision|Unicode|signature' } | Sort-Object
Remove-Item C:\Windows\Temp\drift.cfg -Force -ErrorAction SilentlyContinue
'== audit policy'
auditpol /get /category:* | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() } | Sort-Object
'== local administrators'
(Get-LocalGroupMember -Group Administrators | ForEach-Object { $_.SID.Value }) | Sort-Object
'== enabled accounts'
(Get-LocalUser | Where-Object Enabled | ForEach-Object { '{0} rid={1}' -f $_.Name, $_.SID.Value.Split('-')[-1] }) | Sort-Object
'== rdp'
'fDenyTSConnections=' + (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server').fDenyTSConnections
'== password policy'
net accounts | Where-Object { $_ -match ':' } | ForEach-Object { $_.Trim() }
'@

function Get-Snapshot {
    param([Parameter(Mandatory)][string]$Label)
    $path = Join-Path $scriptDir "drift-$Label.txt"
    if ($guestIsWindows) {
        Set-Content -Path $path -Value $windowsSnapshot -Encoding utf8
        $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName -CommandId 'RunPowerShellScript' -ScriptPath $path
    }
    else {
        Set-Content -Path $path -Value $linuxSnapshot -Encoding utf8
        $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName -CommandId 'RunShellScript' -ScriptPath $path
    }
    Remove-Item $path -Force -ErrorAction SilentlyContinue
    $text = ($result.Value | ForEach-Object { $_.Message }) -join "`n"
    # Run Command wraps the output; keep the payload only.
    ($text -split "`n" | Where-Object { $_ -notmatch '^(Enable succeeded|\[stdout\]|\[stderr\])\s*$' }) -join "`n"
}

Write-Host "`n### snapshot before" -ForegroundColor Cyan
$before = Get-Snapshot -Label 'before'
Write-Host "  $((($before -split "`n") | Measure-Object).Count) line(s)" -ForegroundColor DarkGray

Write-Host "`n### rotating" -ForegroundColor Cyan
$rotation = Invoke-CredentialRotation -VaultName $VaultName -VMName $VMName -ResourceGroupName $ResourceGroupName -Confirm:$false 4>$null 3>$null
Write-Host "  rotated=$($rotation.Rotated) failed=$($rotation.Failed)" -ForegroundColor DarkGray

Write-Host "`n### snapshot after" -ForegroundColor Cyan
$after = Get-Snapshot -Label 'after'

$diff = Compare-Object -ReferenceObject ($before -split "`n") -DifferenceObject ($after -split "`n") |
    Where-Object { $_.InputObject.Trim() } |
    ForEach-Object { '{0} {1}' -f $_.SideIndicator, $_.InputObject.Trim() }

Write-Host "`n=== drift ===" -ForegroundColor Cyan
if ($diff) { $diff | ForEach-Object { Write-Host "  $_" } }
else { Write-Host '  none' -ForegroundColor Green }

[pscustomobject]@{
    VMName    = $VMName
    OSType    = if ($guestIsWindows) { 'Windows' } else { 'Linux' }
    Rotated   = $rotation.Rotated
    Failed    = $rotation.Failed
    DiffLines = @($diff)
    Before    = $before
    After     = $after
}
