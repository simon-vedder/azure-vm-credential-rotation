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
| `-VaultName` | String | yes | no |  |  |
| `-VM` | Object | yes | no |  |  |
| `-CredentialType` | String | yes | no |  |  |
| `-ValidityDays` | Int32 | no | no | 90 |  |
| `-TriggerReason` | String | no | no | Expiry |  |
| `-TriggeredBy` | String | no | no |  |  |
| `-RemovePriorSshKeys` | SwitchParameter | no | no |  | Defaults to false, deliberately. The VMAccess extension can wipe every entry in authorized_keys, which takes out colleagues, configuration management and backup agents along with the key you meant to replace. Turn it on only if you are certain this tool owns every key on the machine. |
| `-ResetSshConfiguration` | SwitchParameter | no | no |  | Defaults to false, deliberately. VMAccess can restore sshd configuration to its default, which silently undoes hardening on a CIS-baselined host. |
| `-SecretNameTemplate` | String | no | no | {vm}-{user}-{kind} |  |

Supports `-WhatIf` and `-Confirm`.

## Examples

### Example 1

```powershell

```

## Output

- PSCustomObject describing the outcome.

---

[All commands](README.md) | [Module README](../../README.md)

*Generated from the comment-based help by `tools/New-CommandReference.ps1`. Edit the help in the function, not this file.*
