# Invoke-CredentialRotation

> Reconciles VM credentials against their Key Vault expiry dates.

One pass over the estate:

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
Invoke-CredentialRotation [-VaultName] <string> [[-SubscriptionId] <string[]>] [[-ThresholdDays] <int>] [[-ValidityDays] <int>] [[-EnableTagName] <string>] [[-EnableTagValue] <string>] [[-HoldTagName] <string>] [[-WorkspaceId] <string>] [[-GracePeriodHours] <int>] [[-AccessLookbackHours] <int>] [[-ExcludeObjectId] <string[]>] [[-DataCollectionEndpoint] <string>] [[-DataCollectionRuleId] <string>] [[-StreamName] <string>] [[-TriggeredBy] <string>] [-SkipSshKeys] [-RemovePriorSshKeys] [-ResetSshConfiguration] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## Parameters

| Name | Type | Required | Pipeline | Default | Description |
|---|---|---|---|---|---|
| `-VaultName` | String | yes | no |  |  |
| `-SubscriptionId` | String[] | no | no |  | Subscriptions to process. Defaults to the current context only - deliberately narrow, so an unscoped run cannot reach further than intended. |
| `-ThresholdDays` | Int32 | no | no | 14 |  |
| `-ValidityDays` | Int32 | no | no | 90 |  |
| `-EnableTagName` | String | no | no | CredentialRotation |  |
| `-EnableTagValue` | String | no | no | enabled |  |
| `-HoldTagName` | String | no | no | CredentialRotationHold |  |
| `-SkipSshKeys` | SwitchParameter | no | no |  |  |
| `-RemovePriorSshKeys` | SwitchParameter | no | no |  |  |
| `-ResetSshConfiguration` | SwitchParameter | no | no |  |  |
| `-WorkspaceId` | String | no | no |  | Access-triggered rotation. Without a workspace, only expiry drives rotation. |
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
Invoke-CredentialRotation -VaultName kv-creds -WhatIf
```

Reports what would be rotated without touching anything. Always the first run.

## Output

- PSCustomObject summarising the run, with the individual records attached.

---

[All commands](README.md) | [Module README](../../README.md)

*Generated from the comment-based help by `tools/New-CommandReference.ps1`. Edit the help in the function, not this file.*
