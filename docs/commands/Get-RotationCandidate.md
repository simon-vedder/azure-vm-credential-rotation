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
  Manual        - nothing else applied, so the credential is replaced because
                  the caller asked for this machine

Access is the one worth reading twice, because it is the design in one sentence:
the expiry date is the only signal, and everything else writes to it.

## Syntax

```powershell
Get-RotationCandidate [-VaultName] <string> [-VM] <Object[]> [[-ThresholdDays] <int>] [[-SecretNameTemplate] <string>] [-OnlyIfDue] [-SkipSshKeys] [<CommonParameters>]
```

## Parameters

| Name | Type | Required | Pipeline | Default | Description |
|---|---|---|---|---|---|
| `-VaultName` | String | yes | no |  | The Key Vault holding the credentials. Only read here: this function decides what is due, it never writes. |
| `-VM` | Object[] | yes | no |  | The machines to examine. Objects from Get-AzVM, fetched by the caller. |
| `-OnlyIfDue` | SwitchParameter | no | no |  | Consult the expiry date instead of rotating regardless. Without it every machine handed in is a candidate, which is what asking for a machine means. A scheduled pass sets it, so it touches only what is missing, half-rotated or near expiry. |
| `-ThresholdDays` | Int32 | no | no | 14 | How close to expiry counts as due. Only consulted with -OnlyIfDue. |
| `-SkipSshKeys` | SwitchParameter | no | no |  | Leaves SSH keys out of the answer. Without it a Linux machine yields a key candidate as well as a password one. |
| `-SecretNameTemplate` | String | no | no | {vm}-{user}-{kind} | How secret names are built from {vm}, {user}, {rg} and {kind}. Must match what was used when the secrets were written, or nothing will be found. |

## Examples

### Example 1

```powershell
Get-RotationCandidate -VaultName kv-creds -VM (Get-AzVM -ResourceGroupName rg-dmz)
```

Every credential on every machine in that resource group, because asking for a
machine is itself the reason to rotate it. Reason comes back as Manual.

### Example 2

```powershell
Get-RotationCandidate -VaultName kv-creds -VM $vms -OnlyIfDue -ThresholdDays 14
```

What a scheduled pass asks: only what is missing, half-rotated or within
fourteen days of expiry. Reason distinguishes Missing, Expiry and ResumePending.

### Example 3

```powershell
Get-RotationCandidate -VaultName kv-creds -VM $vms -OnlyIfDue |
    Format-Table VM, CredentialType, Reason, ExpiresOn
```

Dry inspection before a first run over an estate. Nothing is changed by asking,
so this is the cheapest way to see how much work the next rotation would be.

## Output

- PSCustomObject with VM, CredentialType, Reason, SecretName, ExpiresOn.

---

[All commands](README.md) | [Module README](../../README.md)

*Generated from the comment-based help by `tools/New-CommandReference.ps1`. Edit the help in the function, not this file.*
