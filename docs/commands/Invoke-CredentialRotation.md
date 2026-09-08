# Invoke-CredentialRotation

> Reconciles VM credentials against their Key Vault expiry dates.

Two ways to call it.

Name a machine with -VMName and it rotates that one, now, whatever its expiry
date says and whether or not it carries the enable tag. Naming a machine is a
stronger statement of intent than a tag, and this is the form to reach for from
a workstation.

Call it without -VMName and it makes one pass over the estate:

  1. ask Log Analytics which secrets a human read, and pull those expiry
     dates forward (optional, requires the observability module)
  2. find every credential that is missing, expiring or half-rotated
  3. rotate it
  4. write a record of what happened

There is no event subscription and no queue. The run is the retry: anything
that fails or is skipped - a stopped VM, a throttled call, an unhealthy guest
agent - is simply picked up next time. That is what makes the whole thing
small enough to reason about.

Latency is the trade. A credential read at 09:00 with a six-hourly schedule
and an eight-hour grace period is replaced some time before 23:00, not within
minutes. For credentials that would otherwise sit unchanged for months, that
is not a meaningful difference. If it is for you, see
docs/decisions/0002-reconciliation-loop-over-events.md, which describes what
an event-driven version would need.

## Syntax

```powershell
Invoke-CredentialRotation -VaultName <string> [-SubscriptionId <string[]>] [-ThresholdDays <int>] [-EnableTagName <string>] [-EnableTagValue <string>] [-ValidityDays <int>] [-HoldTagName <string>] [-SkipSshKeys] [-RemovePriorSshKeys] [-ResetSshConfiguration] [-WorkspaceId <string>] [-GracePeriodHours <int>] [-AccessLookbackHours <int>] [-ExcludeObjectId <string[]>] [-DataCollectionEndpoint <string>] [-DataCollectionRuleId <string>] [-StreamName <string>] [-TriggeredBy <string>] [-WhatIf] [-Confirm] [<CommonParameters>]

Invoke-CredentialRotation -VaultName <string> -VMName <string> [-ResourceGroupName <string>] [-IgnoreHold] [-SubscriptionId <string[]>] [-ValidityDays <int>] [-HoldTagName <string>] [-SkipSshKeys] [-RemovePriorSshKeys] [-ResetSshConfiguration] [-DataCollectionEndpoint <string>] [-DataCollectionRuleId <string>] [-StreamName <string>] [-TriggeredBy <string>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## Parameters

| Name | Type | Required | Pipeline | Default | Description |
|---|---|---|---|---|---|
| `-VaultName` | String | yes | no |  |  |
| `-VMName` | String | yes | no |  | Rotate this machine and nothing else. The enable tag is not required and the expiry threshold does not apply. The hold tag still does. |
| `-ResourceGroupName` | String | no | no |  | Narrows -VMName when the same name exists more than once in the subscription. Without it, an ambiguous name is an error rather than a guess. |
| `-IgnoreHold` | SwitchParameter | no | no |  | Rotate even a machine carrying the hold tag. Only available with -VMName: a scheduled run must never talk itself out of a hold. |
| `-SubscriptionId` | String[] | no | no |  | Subscriptions to process. Defaults to the current context only - deliberately narrow, so an unscoped run cannot reach further than intended. With -VMName only the first entry is used, because one machine lives in one subscription. |
| `-ThresholdDays` | Int32 | no | no | 14 | Estate only: a named machine is rotated whatever its expiry says, and was not found by tag in the first place. Offering these there would be offering a parameter that does nothing. |
| `-EnableTagName` | String | no | no | CredentialRotation |  |
| `-EnableTagValue` | String | no | no | enabled |  |
| `-ValidityDays` | Int32 | no | no | 90 |  |
| `-HoldTagName` | String | no | no | CredentialRotationHold |  |
| `-SkipSshKeys` | SwitchParameter | no | no |  |  |
| `-RemovePriorSshKeys` | SwitchParameter | no | no |  |  |
| `-ResetSshConfiguration` | SwitchParameter | no | no |  |  |
| `-WorkspaceId` | String | no | no |  | Access-triggered rotation. Without a workspace, only expiry drives rotation. Estate only: the scan is an estate-wide query whose only effect is to move expiry dates, and a named machine is rotated regardless of its expiry date. |
| `-GracePeriodHours` | Int32 | no | no | 8 |  |
| `-AccessLookbackHours` | Int32 | no | no | 24 |  |
| `-ExcludeObjectId` | String[] | no | no | @() |  |
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
Invoke-CredentialRotation -VaultName kv-creds -WhatIf
```

The estate pass: every VM carrying the enable tag whose credential is missing,
expiring or half-rotated. This is what the scheduled runbook calls.

## Output

- PSCustomObject summarising the run, with the individual records attached.

---

[All commands](README.md) | [Module README](../../README.md)

*Generated from the comment-based help by `tools/New-CommandReference.ps1`. Edit the help in the function, not this file.*
