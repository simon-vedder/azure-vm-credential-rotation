# Reference: what it reads, what it writes

Everything this tool decides from, and everything it leaves behind. If a value is not listed
here, the tool does not read it.

## Where the schedule lives

**On the secret, in Key Vault's own expiry attribute.** Not in a tag, not in a table, not in a
database of its own.

`Set-AzKeyVaultSecret -Expires` writes it when a credential is rotated. `Update-AzKeyVaultSecret
-Expires` moves it forward when somebody reads the secret. `Get-RotationCandidate` reads
`$secret.Secret.Expires` and compares it against the threshold, and that comparison is the whole
decision. See [ADR 0003](decisions/0003-expiry-date-as-single-signal.md) for why.

Two rules apply to the date:

- A read only ever brings it **forward**. If the secret already expires sooner than the grace
  period would put it, nothing changes.
- The staging secret `<name>-pending` expires after one day, so a rotation that dies between the
  vault and the guest cleans up after itself.

## Tags on the secret

Written by the tool, read by people. **None of them is an input to a decision.** The tool would
behave identically if every one of them were deleted.

| Tag | Written when | What it says |
|---|---|---|
| `VMName` | every rotation | the machine this credential belongs to |
| `AdminName` | every rotation | the local account the credential is for |
| `OSType` | every rotation | `Windows` or `Linux` |
| `CredentialType` | every rotation | `Password` or `SSHKey` |
| `LastRotated` | every rotation | date only, as a record. The expiry attribute is the schedule |
| `LastTrigger` | every rotation | why this rotation happened: `Expiry`, `Access`, `Missing`, `Manual` or `ResumePending` |
| `RotatedBy` | every rotation | always `azure-vm-credential-rotation`, so a foreign write is visible |
| `LastAccessedBy` | a read moved the expiry | the identity that read the secret |
| `LastAccessedAt` | a read moved the expiry | when it read it |
| `RotationReason` | a read moved the expiry | always `Access` |

On promotion the tag set is **replaced wholesale**, not merged. That clears `RotationReason` from
an earlier access-driven cycle, so a later scheduled rotation does not claim it was triggered by
a read.

The staging secret carries a smaller set while it exists: `State=pending`, `VMName`, `AdminName`
and `CreatedAt`.

## Tags on the virtual machine

Read by the runbook, never written by it. These are policy statements about a machine, which is
why they live on the machine and not on the secret.

| Tag | Default name | What it does |
|---|---|---|
| `CredentialRotation` | `CredentialRotation=enabled` | opts the machine in. Nothing without it is ever touched |
| `CredentialRotationHold` | `CredentialRotationHold=true` | takes the machine out of this run without untagging it |

Both names are parameters of the runbook, so an estate that already uses different tag keys can
say so instead of renaming its tags.

## What one run records

One row per attempt, in the custom Log Analytics table. It contains the secret **versions**
before and after, never credential material. The fields are the properties of the object
`Update-VMCredential` returns; see [architecture.md](architecture.md) for the write order that
makes a half-finished rotation safe.

## What it never reads

- VM tags other than the two above
- Secret tags, for any decision
- Anything in Azure Resource Graph, Azure Policy or an external store
- The previous run's outcome, except through the expiry dates it left behind
