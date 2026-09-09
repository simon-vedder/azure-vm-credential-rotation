# Invoke-CredentialRotation

> Rotates the credentials that are due on the machines you give it.

The caller states the machines. This function does not search for them, does not
read a tag, and has no opinion about which machines belong in scope. That belongs
to whatever is orchestrating - a runbook, a pipeline, or you at a prompt - and
keeping it out of here is what lets the same code run against one machine from a
workstation and against a fleet on a schedule.

Every machine handed in is rotated. Add -OnlyIfDue and the expiry date gets a vote
instead, which is what a scheduled pass wants. Whether you passed one name or two
hundred objects has nothing to do with it.

Rotation after use is not handled here either. Register-CredentialAccess pulls the
expiry date of a credential somebody read forward; this function then sees it as
ordinary ageing. One signal, one code path - and the orchestrator decides how often
to look.

## Syntax

```powershell
Invoke-CredentialRotation -VaultName <string> -VMName <string> [-ResourceGroupName <string>] [-OnlyIfDue] [-ThresholdDays <int>] [-ValidityDays <int>] [-SkipSshKeys] [-RemovePriorSshKeys] [-ResetSshConfiguration] [-SecretNameTemplate <string>] [-TriggeredBy <string>] [-WhatIf] [-Confirm] [<CommonParameters>]

Invoke-CredentialRotation -VaultName <string> -VM <Object[]> [-OnlyIfDue] [-ThresholdDays <int>] [-ValidityDays <int>] [-SkipSshKeys] [-RemovePriorSshKeys] [-ResetSshConfiguration] [-SecretNameTemplate <string>] [-TriggeredBy <string>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## Requirements and notes

RequiredPermissions: Key Vault Secrets Officer on the vault, and Virtual Machine Contributor
on each machine or its resource group. Virtual Machine Contributor is the one to think about:
it includes installing extensions, which is code execution as SYSTEM or root on every machine
in scope, so assign it per resource group rather than per subscription.

## Parameters

| Name | Type | Required | Pipeline | Default | Description |
|---|---|---|---|---|---|
| `-VaultName` | String | yes | no |  | The Key Vault the credentials live in. The one thing this function must be told that it cannot work out from the machines themselves. |
| `-VMName` | String | yes | no |  | Rotate this machine. A convenience over -VM for the common case of one name; it behaves identically otherwise. |
| `-ResourceGroupName` | String | no | no |  | Narrows -VMName when the same name exists more than once in the subscription. Without it, an ambiguous name is an error rather than a guess. |
| `-VM` | Object[] | yes | no |  | Machines to process, as objects from Get-AzVM. What an orchestrator passes after it has selected them. |
| `-OnlyIfDue` | SwitchParameter | no | no |  | Rotate only what is missing, half-rotated or near expiry, instead of rotating everything handed in. How you name the machines says nothing about this - a scheduled pass sets it, a person at a prompt usually does not. |
| `-ThresholdDays` | Int32 | no | no | 14 | How close to expiry counts as due. Only consulted with -OnlyIfDue. |
| `-ValidityDays` | Int32 | no | no | 90 | How far ahead each new secret's expiry date is set. Since the expiry date is the only signal, this is the rotation interval: ninety days here means a credential comes back around in ninety days. |
| `-SkipSshKeys` | SwitchParameter | no | no |  | Rotates passwords only, leaving Linux SSH keys alone. Useful while onboarding an estate where the keys are managed by something else. |
| `-RemovePriorSshKeys` | SwitchParameter | no | no |  | Passed through to Update-VMCredential, and off by default for the reason given there: VMAccess can wipe every entry in authorized_keys, colleagues and agents included. |
| `-ResetSshConfiguration` | SwitchParameter | no | no |  | Passed through to Update-VMCredential, and off by default: VMAccess can restore sshd configuration to its default and undo hardening on a baselined host. |
| `-SecretNameTemplate` | String | no | no | {vm}-{user}-{kind} | How secret names are built from {vm}, {user}, {rg} and {kind}. Change it to fit a vault that already has a naming convention; keep it the same for the life of a secret. Use {rg} where two machines could share a name - a VM name is not unique in a subscription, and the default template would put both on one secret. |
| `-TriggeredBy` | String | no | no |  | Who or what asked for this run - a runbook job id, a person, a change ticket. Recorded on every record the run produces, and never interpreted. |

Supports `-WhatIf` and `-Confirm`.

## Examples

### Example 1

```powershell
Invoke-CredentialRotation -VaultName kv-creds -VMName jump-01 -WhatIf
```

Shows what would happen to one machine, from your own workstation, without
deploying anything. Always the first thing to run.

### Example 2

```powershell
Invoke-CredentialRotation -VaultName kv-creds -VMName jump-01
```

Rotates that machine now. The secret is created in the vault if it does not
exist yet, so this is also how a machine is onboarded by hand.

### Example 3

```powershell
$vms = Get-AzVM | Where-Object { $_.Tags.CredentialRotation -eq 'enabled' }
Invoke-CredentialRotation -VaultName kv-creds -VM $vms -OnlyIfDue
```

What an orchestrator does: select the machines however you like, hand them over,
and ask for only the ones that are due. The tag here is the caller's policy, not
the module's.

### Example 4

```powershell
Invoke-CredentialRotation -VaultName kv-creds -VM $vms
```

The same machines, all rotated, due or not. Naming machines and deciding whether
the expiry date gets a vote are two separate questions, so they are two separate
parameters.

## Output

- PSCustomObject summarising the run. Records holds one entry per credential touched,
in the shape CredentialRotation_CL expects, for whoever wants to ship them.

-WhatIf is supported and propagated, but the decision is made where the change is:
Update-VMCredential calls ShouldProcess per credential. Confirming once up here
instead would collapse a dry run into a single line and throw away the per-credential
WhatIf records, which are the reason anybody runs one.

---

[All commands](README.md) | [Module README](../../README.md)

*Generated from the comment-based help by `tools/New-CommandReference.ps1`. Edit the help in the function, not this file.*
