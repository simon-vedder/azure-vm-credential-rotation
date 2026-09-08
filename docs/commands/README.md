# CredentialRotation command reference

Credential lifecycle for Azure VMs that cannot use Windows LAPS or Entra login. Rotates local admin passwords and SSH keys, driven by Key Vault expiry dates.

## Requirements

| | |
|---|---|
| Module version | 0.1.0 |
| PowerShell | 7.2+ (Core) |
| Required modules | `Az.Accounts`, `Az.Compute`, `Az.KeyVault`, `Az.OperationalInsights`, `Az.Resources` |
| Getting it | `Install-Module CredentialRotation`, or let the deployment pull it at the pinned version |

Per-command permissions are on each page under **Requirements and notes**.

## The runbook

What Azure Automation runs on the schedule.

| Script | What it does |
|---|---|
| [Invoke-CredentialRotationRunbook.ps1](Invoke-CredentialRotationRunbook.md) | Azure Automation entry point for VM credential rotation. |

## Module commands

The commands the runbook calls, and the same ones you can run locally after Install-Module.

| Command | What it does |
|---|---|
| [Get-RotationCandidate](Get-RotationCandidate.md) | Finds the credentials that need rotating. |
| [Invoke-CredentialRotation](Invoke-CredentialRotation.md) | Reconciles VM credentials against their Key Vault expiry dates. |
| [Register-CredentialAccess](Register-CredentialAccess.md) | Brings the expiry date forward for secrets a human has read. |
| [Update-VMCredential](Update-VMCredential.md) | Rotates one credential on one VM and stores it in Key Vault. |

---

*Generated from the comment-based help by `tools/New-CommandReference.ps1`. Edit the help in the function, not these files.*
