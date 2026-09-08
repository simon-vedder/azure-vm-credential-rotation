# Get-RotationCandidate

> Finds the credentials that need rotating.

Opt-in, not opt-out. A VM is only considered when it carries the enable tag.

This is the difference between a tool and an incident. A discovery loop that
treats "no secret exists for this VM" as "rotate it" will, on its first run
in an established tenant, change the local administrator password of every
machine it can see - including the ones whose credentials live in a CMDB or a
password manager that nobody told it about.

Rotation is triggered by one of four conditions:

  ResumePending - a previous run was interrupted after staging a value
  Missing       - no secret yet, or a secret with no expiry date
  Expiry        - the expiry date is within the threshold
  Access        - not detected here; access pulls the expiry date forward,
                  and this function then sees it as Expiry

The last point is the design in one sentence: the expiry date is the only
signal. Everything else writes to it.

## Syntax

```powershell
Get-RotationCandidate [-VaultName] <string> [[-ThresholdDays] <int>] [[-EnableTagName] <string>] [[-EnableTagValue] <string>] [[-HoldTagName] <string>] [-SkipSshKeys] [<CommonParameters>]
```

## Parameters

| Name | Type | Required | Pipeline | Default | Description |
|---|---|---|---|---|---|
| `-VaultName` | String | yes | no |  |  |
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
