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
./Invoke-CredentialRotationRunbook.ps1 [[-VaultName] <string>] [[-SubscriptionId] <string>] [[-ThresholdDays] <int>] [[-ValidityDays] <int>] [[-EnableTagName] <string>] [[-EnableTagValue] <string>] [[-SecretNameTemplate] <string>] [[-HoldTagName] <string>] [[-SkipSshKeys] <bool>] [[-RemovePriorSshKeys] <bool>] [[-ResetSshConfiguration] <bool>] [[-DryRun] <bool>] [<CommonParameters>]
```

## Requirements and notes

RequiredPermissions: the automation account's system-assigned identity needs Key Vault Secrets
Officer on the vault, Virtual Machine Contributor on the VM scopes, and Automation Job Operator
on the automation account itself. Access-driven rotation adds Log Analytics Reader on the
workspace; the audit trail adds Monitoring Metrics Publisher on the data collection rule. The
deployment assigns all of them, so running it needs the right to create role assignments in
every scope you name.

## Parameters

| Name | Type | Required | Pipeline | Default | Description |
|---|---|---|---|---|---|
| `-VaultName` | String | no | no |  | The Key Vault holding the credentials. Normally left unset so the job takes it from the automation variable CR_VaultName that the deployment writes; pass it to point one manual run at a different vault. |
| `-SubscriptionId` | String | no | no |  | The subscriptions to walk, comma-separated. Unset means the automation variable CR_SubscriptionId, and unset there means the subscription the automation account itself lives in. Naming subscriptions is what makes a cross-subscription estate work: the identity's role assignments still have to reach them. |
| `-ThresholdDays` | Int32 | no | no | 0 | How close to expiry counts as due, defaulting to fourteen through CR_ThresholdDays. Read together with the schedule: a machine is only seen when a job runs, so the threshold has to be comfortably wider than the interval between runs. |
| `-ValidityDays` | Int32 | no | no | 0 | How far ahead a new secret's expiry date is set, defaulting to ninety through CR_ValidityDays. Since the expiry date is the only signal, this is the rotation interval. A STIG-hardened Linux image enforces a shorter maximum password age, so match it there rather than letting the guest and the vault disagree. |
| `-EnableTagName` | String | no | no |  | The VM tag that opts a machine in, defaulting to CredentialRotation through CR_EnableTagName. This is the orchestrator's vocabulary and nothing else reads it - the module is handed machines, never a tag name. |
| `-EnableTagValue` | String | no | no |  | The value that tag must carry, defaulting to enabled through CR_EnableTagValue. A machine tagged with anything else is out of scope, which is how a fleet is onboarded in batches rather than all at once. |
| `-SecretNameTemplate` | String | no | no |  | How secret names are built, from {vm}, {user}, {rg} and {kind}. Defaults to the shape this tool has always used. Set it where two machines could share a name, or where the vault already has a convention; it has to stay the same for the life of a secret. |
| `-HoldTagName` | String | no | no | CredentialRotationHold | VM tag that takes a machine out of scope for this run without untagging it. Checked here rather than in the module, because it is a policy statement about a machine rather than a fact about the credential. |
| `-SkipSshKeys` | Boolean | no | no |  | Rotates passwords only and leaves Linux SSH keys alone. Set it through CR_SkipSshKeys where the keys belong to configuration management. |
| `-RemovePriorSshKeys` | Boolean | no | no |  | Off by default, and worth leaving off: the VMAccess extension can wipe every entry in authorized_keys, which takes out colleagues, configuration management and backup agents along with the key being replaced. |
| `-ResetSshConfiguration` | Boolean | no | no |  | Off by default: VMAccess can restore sshd configuration to its default, silently undoing hardening on a CIS-baselined host. |
| `-DryRun` | Boolean | no | no |  | Runs the whole pass under -WhatIf. Use this first, always. Passed explicitly for a manual run; the scheduled job leaves it to the automation variable CR_DryRun, which is what the deployment's dryRun setting writes. It lives in a variable rather than in the job schedule's parameters because Automation ignores a PUT on a schedule link that already exists - a redeployment with dryRun=false would report success and change nothing. |

## Examples

### Example 1

```powershell
Start-AzAutomationRunbook -AutomationAccountName aa-credrotation -ResourceGroupName rg-credrotation -Name Invoke-CredentialRotationRunbook -Parameters @{ DryRun = $true }
```

The first run after a deployment. Reports what it would replace across every tagged
machine and changes nothing. Read one of these before turning the schedule loose.

### Example 2

```powershell
Set-AzAutomationVariable -AutomationAccountName aa-credrotation -ResourceGroupName rg-credrotation -Name CR_DryRun -Value 'false' -Encrypted $false
```

How the scheduled job leaves dry-run mode. The schedule carries no parameters on
purpose: Automation ignores a PUT on a job schedule that already exists, so a
redeployment with dryRun=false would report success and change nothing.

### Example 3

```powershell
,<sub-b>'; DryRun = $true }
```

A cross-subscription pass, forced for one run. Both subscriptions have to be within
reach of the managed identity's role assignments; naming one it cannot see produces a
permission error rather than an empty result.

---

[All commands](README.md) | [Module README](../../README.md)

*Generated from the comment-based help by `tools/New-CommandReference.ps1`. Edit the help in the function, not this file.*
