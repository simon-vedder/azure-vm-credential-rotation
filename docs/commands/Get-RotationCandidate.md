# Get-RotationCandidate

> Finds the credentials that need rotating.

Opt-in, not opt-out. A VM is only considered when it carries the enable tag.

This is the difference between a tool and an incident. A discovery loop that
treats "no secret exists for this VM" as "rotate it" will, on its first run
in an established tenant, change the local administrator password of every
machine it can see - including the ones whose credentials live in a CMDB or a
password manager that nobody told it about.

Rotation is triggered by one of five conditions:

  ResumePending - a previous run was interrupted after staging a value
  Missing       - no secret yet, or a secret with no expiry date
  Expiry        - the expiry date is within the threshold
  Access        - not detected here; access pulls the expiry date forward,
                  and this function then sees it as Expiry
  Manual        - a VM was named explicitly through -VM, so it is rotated
                  whatever its expiry date says

## Syntax

```powershell
Get-RotationCandidate [-VaultName] <string> [[-VM] <Object[]>] [[-ThresholdDays] <int>] [[-EnableTagName] <string>] [[-EnableTagValue] <string>] [[-HoldTagName] <string>] [-IgnoreHold] [-SkipSshKeys] [<CommonParameters>]
```

## Parameters

| Name | Type | Required | Pipeline | Default | Description |
|---|---|---|---|---|---|
| `-VaultName` | String | yes | no |  |  |
| `-VM` | Object[] | no | no |  | Rotate these VMs instead of discovering tagged ones. Naming a machine is a stronger statement of intent than a tag, so the enable tag is not required and the expiry threshold does not apply - the reason becomes Manual. The hold tag still applies, because it means somebody is working on that machine. |
| `-IgnoreHold` | SwitchParameter | no | no |  | Rotate even a VM carrying the hold tag. Only meaningful with -VM: a scheduled run must never talk itself out of a hold. The last point is the design in one sentence: the expiry date is the only signal. Everything else writes to it. |
| `-ThresholdDays` | Int32 | no | no | 14 |  |
| `-EnableTagName` | String | no | no | CredentialRotation |  |
| `-EnableTagValue` | String | no | no | enabled |  |
| `-HoldTagName` | String | no | no | CredentialRotationHold |  |
| `-SkipSshKeys` | SwitchParameter | no | no |  | Linux VMs get an SSH key rotated unless this is set. |

## Examples

### Example 1

```powershell

```

## Output

- PSCustomObject with VM, CredentialType, Reason, SecretName, ExpiresOn.

---

[All commands](README.md) | [Module README](../../README.md)

*Generated from the comment-based help by `tools/New-CommandReference.ps1`. Edit the help in the function, not this file.*
