# Get-RotationCandidate

> Works out which credentials on the given machines need rotating.

The caller states the machines. This function never searches for them, never
reads a tag and has no opinion about which machines belong in scope - that is
the orchestrator's job, and keeping it there is what lets the same module run
from a workstation against one machine and from a runbook against a fleet.

What it does decide is whether a machine the caller already chose actually has
something to rotate. Rotation is triggered by one of five conditions:

  ResumePending - a previous run was interrupted after staging a value
  Missing       - no secret yet, or a secret with no expiry date
  Expiry        - the expiry date is within the threshold
  Access        - not detected here; access pulls the expiry date forward,
                  and this function then sees it as Expiry
  Manual        - -IgnoreExpiry was set, so a healthy credential is replaced
                  anyway

## Syntax

```powershell
Get-RotationCandidate [-VaultName] <string> [-VM] <Object[]> [[-ThresholdDays] <int>] [-IgnoreExpiry] [-SkipSshKeys] [<CommonParameters>]
```

## Parameters

| Name | Type | Required | Pipeline | Default | Description |
|---|---|---|---|---|---|
| `-VaultName` | String | yes | no |  |  |
| `-VM` | Object[] | yes | no |  | The machines to examine. Objects from Get-AzVM, fetched by the caller. |
| `-ThresholdDays` | Int32 | no | no | 14 |  |
| `-IgnoreExpiry` | SwitchParameter | no | no |  | Treat a healthy, unexpired credential as due anyway, reported as Manual. This is what somebody naming a single machine means: they asked for that machine, and a threshold quietly deciding to do nothing would be the wrong answer. A scheduled pass leaves it off and lets the expiry date decide. The last point is the design in one sentence: the expiry date is the only signal. Everything else writes to it. |
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
