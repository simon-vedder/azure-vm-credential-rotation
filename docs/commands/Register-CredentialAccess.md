# Register-CredentialAccess

> Brings the expiry date forward for secrets a human has read.

Rotation after use, without a second execution path.

A credential that someone has read is spent. It has been in a clipboard, a
terminal scrollback, an RDP client, possibly a screen share or a ticket. The
useful response is to replace it soon - but not instantly, because the person
who read it is usually still using it.

Rather than schedule a delayed job, this writes the deadline where the system
already looks: the secret's expiry date. Set it to now plus the grace period,
and the next scheduled run treats it as any other near-expiry secret. No
timer, no queue, no orchestrator, no second code path to test.

Changing an expiry date is an attribute update. It does not create a new
secret version and it does not read the value, so it neither disturbs
consumers nor pollutes the audit trail this function depends on.

## Syntax

```powershell
Register-CredentialAccess [-VaultName] <string> [-WorkspaceId] <string> [[-GracePeriodHours] <int>] [[-LookbackHours] <int>] [[-ExcludeObjectId] <string[]>] [[-HoldTagName] <string>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## Parameters

| Name | Type | Required | Pipeline | Default | Description |
|---|---|---|---|---|---|
| `-VaultName` | String | yes | no |  |  |
| `-WorkspaceId` | String | yes | no |  |  |
| `-GracePeriodHours` | Int32 | no | no | 8 | How long the reader keeps working credentials. Eight hours covers a working day. Note that a password change does not end an established RDP session, but it does break reconnects, UAC elevation and anything that re-authenticates. |
| `-LookbackHours` | Int32 | no | no | 24 |  |
| `-ExcludeObjectId` | String[] | no | no | @() |  |
| `-HoldTagName` | String | no | no | CredentialRotationHold |  |

Supports `-WhatIf` and `-Confirm`.

## Examples

### Example 1

```powershell

```

## Output

- PSCustomObject per secret whose expiry was moved.

---

[All commands](README.md) | [Module README](../../README.md)

*Generated from the comment-based help by `tools/New-CommandReference.ps1`. Edit the help in the function, not this file.*
