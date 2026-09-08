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
timer, no queue, no second code path to test.

Who read what is the caller's finding, not this function's. It takes a secret
name and a reader and acts; the orchestrator gets those from the Key Vault
audit log in Log Analytics (queries/accessed-secrets.kql) and pipes them in.
That keeps the module free of any workspace dependency, and lets a different
orchestrator learn about reads however it likes.

Changing an expiry date is an attribute update. It does not create a new
secret version and it does not read the value, so it neither disturbs
consumers nor pollutes the audit trail this function depends on.

## Syntax

```powershell
Register-CredentialAccess [-VaultName] <string> [-SecretName] <string> [-AccessedBy] <string> [[-AccessedAt] <datetime>] [[-GracePeriodHours] <int>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## Parameters

| Name | Type | Required | Pipeline | Default | Description |
|---|---|---|---|---|---|
| `-VaultName` | String | yes | no |  | The vault holding the secret. Only its expiry date is touched; the value is never read, which is what keeps this function out of its own audit trail. |
| `-SecretName` | String | yes | yes |  | The secret that was read. Accepts pipeline input by property name, so the result of the audit-log query pipes straight in. |
| `-AccessedBy` | String | yes | yes |  | Who read it. Recorded on the secret so the audit trail can say. |
| `-AccessedAt` | DateTime | no | yes | (Get-Date).ToUniversalTime() | When. Defaults to now; the query supplies LastAccessedAt, which is accepted. |
| `-GracePeriodHours` | Int32 | no | no | 8 | How long the reader keeps working credentials. Eight hours covers a working day. Note that a password change does not end an established RDP session, but it does break reconnects, UAC elevation and anything that re-authenticates. |

Supports `-WhatIf` and `-Confirm`.

## Examples

### Example 1

```powershell
Register-CredentialAccess -VaultName kv -SecretName vm01-azureuser-pw -AccessedBy alice@contoso.com
```

One read, handled by hand. The expiry date moves to now plus the grace period
and the next scheduled run replaces the credential as ordinary ageing.

### Example 2

```powershell
$reads | Register-CredentialAccess -VaultName kv -GracePeriodHours 8 -WhatIf
```

Whatever produced $reads - the KQL in queries/, a SIEM export, a ticket - as
long as each object carries SecretName and AccessedBy.

## Output

- PSCustomObject per secret, saying whether its expiry was moved.

---

[All commands](README.md) | [Module README](../../README.md)

*Generated from the comment-based help by `tools/New-CommandReference.ps1`. Edit the help in the function, not this file.*
