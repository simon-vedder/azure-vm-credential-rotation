# Invoke-CredentialRotationRunbook.ps1

> Azure Automation entry point for VM credential rotation.

The orchestrator. It authenticates, resolves its configuration, guards against
overlapping runs, decides which machines are in scope, and hands them to the
AzureVMCredentialRotation module.

That split is the point. The module rotates the machines it is given and has no
opinion about tags; every policy decision - which machines are enabled, which are
on hold, which subscriptions to walk, how often to look for reads - lives here.
So the same module runs from a workstation against one named machine and from this
runbook against a fleet, without a mode switch.

Scope is opt-in by tag. A discovery loop that treated "no secret exists for this
VM" as "rotate it" would, on its first run in an established tenant, change the
local administrator password of every machine it can see.

It reaches Azure Automation two ways. The Bicep deployment imports the module from
the PowerShell Gallery and publishes this file as it stands; the Terraform
deployment publishes the flattened artefact from build/Build-Runbook.ps1, which
inlines the module ahead of this wrapper. The import below covers the first case
and stays out of the way in the second.

Configuration precedence is parameter, then Automation variable, then default.
That is what makes the optional parts independently deployable: observability sets
CR_WorkspaceId and the data collection variables, rotation-after-use sets
CR_AccessRotationEnabled. Deploy neither and the runbook falls back to plain
expiry-driven rotation.

## Syntax

```powershell
./Invoke-CredentialRotationRunbook.ps1 [[-VaultName] <string>] [[-SubscriptionId] <string>] [[-ThresholdDays] <int>] [[-ValidityDays] <int>] [[-EnableTagName] <string>] [[-EnableTagValue] <string>] [[-HoldTagName] <string>] [[-SkipSshKeys] <bool>] [[-RemovePriorSshKeys] <bool>] [[-ResetSshConfiguration] <bool>] [[-DryRun] <bool>] [<CommonParameters>]
```

## Requirements and notes

Requires the automation account's managed identity to hold:
  Key Vault Secrets Officer   on the vault
  Virtual Machine Contributor on the VM scopes
  Log Analytics Reader        on the workspace   (only for access-driven rotation)
  Monitoring Metrics Publisher on the DCR        (only for audit records)

## Parameters

| Name | Type | Required | Pipeline | Default | Description |
|---|---|---|---|---|---|
| `-VaultName` | String | no | no |  |  |
| `-SubscriptionId` | String | no | no |  |  |
| `-ThresholdDays` | Int32 | no | no | 0 |  |
| `-ValidityDays` | Int32 | no | no | 0 |  |
| `-EnableTagName` | String | no | no |  |  |
| `-EnableTagValue` | String | no | no |  |  |
| `-HoldTagName` | String | no | no | CredentialRotationHold | VM tag that takes a machine out of scope for this run without untagging it. Checked here rather than in the module, because it is a policy statement about a machine rather than a fact about the credential. |
| `-SkipSshKeys` | Boolean | no | no |  |  |
| `-RemovePriorSshKeys` | Boolean | no | no |  |  |
| `-ResetSshConfiguration` | Boolean | no | no |  |  |
| `-DryRun` | Boolean | no | no |  | Runs the whole pass under -WhatIf. Use this first, always. |

## Examples

### Example 1

```powershell

```

---

[All commands](README.md) | [Module README](../../README.md)

*Generated from the comment-based help by `tools/New-CommandReference.ps1`. Edit the help in the function, not this file.*
