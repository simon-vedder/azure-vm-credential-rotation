# Invoke-CredentialRotation

> Rotates the credentials that are due on the machines you give it.

The caller states the machines. This function does not search for them, does not
read a tag, and has no opinion about which machines belong in scope. That belongs
to whatever is orchestrating - a runbook, a pipeline, or you at a prompt - and
keeping it out of here is what lets the same code run against one machine from a
workstation and against a fleet on a schedule.

For each machine it works out what is due (missing, expiring or half-rotated),
rotates it, and writes a record of what happened.

Rotation after use is not handled here either. Register-CredentialAccess pulls the
expiry date of a credential somebody read forward; this function then sees it as
ordinary ageing. One signal, one code path - and the orchestrator decides how often
to look.

## Syntax

```powershell
Invoke-CredentialRotation -VaultName <string> -VMName <string> [-ResourceGroupName <string>] [-ValidityDays <int>] [-SkipSshKeys] [-RemovePriorSshKeys] [-ResetSshConfiguration] [-DataCollectionEndpoint <string>] [-DataCollectionRuleId <string>] [-StreamName <string>] [-TriggeredBy <string>] [-WhatIf] [-Confirm] [<CommonParameters>]

Invoke-CredentialRotation -VaultName <string> -VM <Object[]> [-ThresholdDays <int>] [-ValidityDays <int>] [-SkipSshKeys] [-RemovePriorSshKeys] [-ResetSshConfiguration] [-DataCollectionEndpoint <string>] [-DataCollectionRuleId <string>] [-StreamName <string>] [-TriggeredBy <string>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## Parameters

| Name | Type | Required | Pipeline | Default | Description |
|---|---|---|---|---|---|
| `-VaultName` | String | yes | no |  |  |
| `-VMName` | String | yes | no |  | Rotate this machine. The expiry threshold does not apply: you named it, so it is rotated. This is the form to reach for from a workstation. |
| `-ResourceGroupName` | String | no | no |  | Narrows -VMName when the same name exists more than once in the subscription. Without it, an ambiguous name is an error rather than a guess. |
| `-VM` | Object[] | yes | no |  | Machines to process, as objects from Get-AzVM. The expiry threshold applies, so only the ones that are actually due are touched. This is what an orchestrator passes after it has selected them. |
| `-ThresholdDays` | Int32 | no | no | 14 | Rotate a credential whose expiry is this close. Ignored with -VMName. |
| `-ValidityDays` | Int32 | no | no | 90 |  |
| `-SkipSshKeys` | SwitchParameter | no | no |  |  |
| `-RemovePriorSshKeys` | SwitchParameter | no | no |  |  |
| `-ResetSshConfiguration` | SwitchParameter | no | no |  |  |
| `-DataCollectionEndpoint` | String | no | no |  | Structured audit records. Without these, the job output is the only trail. |
| `-DataCollectionRuleId` | String | no | no |  |  |
| `-StreamName` | String | no | no | Custom-CredentialRotation_CL |  |
| `-TriggeredBy` | String | no | no |  |  |

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
Invoke-CredentialRotation -VaultName kv-creds -VM $vms
```

What an orchestrator does: select the machines however you like, then hand them
over. The tag here is the caller's policy, not the module's.

## Output

- PSCustomObject summarising the run, with the individual records attached.

-WhatIf is supported and propagated, but the decision is made where the change is:
Update-VMCredential calls ShouldProcess per credential. Confirming once up here
instead would collapse a dry run into a single line and throw away the per-credential
WhatIf records, which are the reason anybody runs one.

---

[All commands](README.md) | [Module README](../../README.md)

*Generated from the comment-based help by `tools/New-CommandReference.ps1`. Edit the help in the function, not this file.*
