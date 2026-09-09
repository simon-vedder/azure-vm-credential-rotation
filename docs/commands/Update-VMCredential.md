# Update-VMCredential

> Rotates one credential on one VM and stores it in Key Vault.

Write order is the point of this function.

The naive order is: change the VM, then store the new value. If the Key Vault
write then fails - throttling, a role assignment that expired, a firewall
rule - the machine has a password nobody knows. That is unrecoverable without
a serial console or a disk swap.

This function stages the value first, in a separate secret named
"<name>-pending":

    1. write the new value to <name>-pending, tagged State=pending
    2. apply it to the VM through the VMAccess extension
    3. write it to <name> with the real expiry
    4. overwrite <name>-pending with a placeholder, tagged State=consumed

Any crash leaves the value recoverable. If the run dies between 2 and 3, the
next run finds an open pending secret, reapplies the same value to the VM
(idempotent) and promotes it. Callers see <name> only ever holding a value
the VM has actually accepted.

The staging secret is overwritten rather than deleted or disabled - see
Close-PendingCredential for why both of those fail against a real vault.

## Syntax

```powershell
Update-VMCredential [-VaultName] <string> [-VM] <Object> [-CredentialType] <string> [[-ValidityDays] <int>] [[-TriggerReason] <string>] [[-TriggeredBy] <string>] [[-SecretNameTemplate] <string>] [-RemovePriorSshKeys] [-ResetSshConfiguration] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## Parameters

| Name | Type | Required | Pipeline | Default | Description |
|---|---|---|---|---|---|
| `-VaultName` | String | yes | no |  | The Key Vault the new value is written to. Written before the machine is touched, which is the whole point of the order above. |
| `-VM` | Object | yes | no |  | The machine to change, as an object from Get-AzVM. One machine, not a list: the fan-out belongs to Invoke-CredentialRotation. |
| `-CredentialType` | String | yes | no |  | Password for the local administrator account, or SSHKey for a new key pair on a Linux machine. One credential per call, so a machine with both is two calls. |
| `-ValidityDays` | Int32 | no | no | 90 | How far ahead the new secret's expiry date is set. That date is the only thing that brings the credential back for rotation, so it is the rotation interval in everything but name. Note that a STIG-hardened Linux image enforces a shorter maximum password age than the ninety-day default. |
| `-TriggerReason` | String | no | no | Expiry | Why this rotation is happening, recorded on the run. Get-RotationCandidate works it out; pass it through rather than inventing one, or the audit trail stops matching what actually drove the change. |
| `-TriggeredBy` | String | no | no |  | Who or what asked for it - a runbook job id, a person, a change ticket. Free text, recorded verbatim, never interpreted. |
| `-RemovePriorSshKeys` | SwitchParameter | no | no |  | Defaults to false, deliberately. The VMAccess extension can wipe every entry in authorized_keys, which takes out colleagues, configuration management and backup agents along with the key you meant to replace. Turn it on only if you are certain this tool owns every key on the machine. |
| `-ResetSshConfiguration` | SwitchParameter | no | no |  | Defaults to false, deliberately. VMAccess can restore sshd configuration to its default, which silently undoes hardening on a CIS-baselined host. |
| `-SecretNameTemplate` | String | no | no | {vm}-{user}-{kind} | How the secret name is built from {vm}, {user}, {rg} and {kind}. Must match what was used when the secret was written, or this call stages a new secret beside the real one instead of replacing it. |

Supports `-WhatIf` and `-Confirm`.

## Examples

### Example 1

```powershell
$vm = Get-AzVM -ResourceGroupName rg-dmz -Name jump-01
Update-VMCredential -VaultName kv-creds -VM $vm -CredentialType Password -WhatIf
```

What one rotation would do, without doing it. ShouldProcess is asked per
credential, so a dry run over a fleet still reports every machine separately.

### Example 2

```powershell
$vm = Get-AzVM -ResourceGroupName rg-dmz -Name jump-01
Update-VMCredential -VaultName kv-creds -VM $vm -CredentialType Password -Confirm:$false
```

Replaces the local administrator password now and stores it with the default
ninety-day expiry. ConfirmImpact is High, so without -Confirm:$false this prompts.

### Example 3

```powershell
Update-VMCredential -VaultName kv-creds -VM $linuxVm -CredentialType SSHKey -TriggerReason Access -TriggeredBy 'runbook:8f2c' -Confirm:$false
```

A key replaced because somebody read the old one. The reason and the caller are
recorded on the run; they change nothing about how the rotation is performed.

## Output

- PSCustomObject describing the outcome.

---

[All commands](README.md) | [Module README](../../README.md)

*Generated from the comment-based help by `tools/New-CommandReference.ps1`. Edit the help in the function, not this file.*
