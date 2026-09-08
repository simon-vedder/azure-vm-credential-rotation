# Known issues and sharp edges

Every entry says where it comes from: *(observed)* in a lab or a real run, *(Microsoft)* from
official documentation, *(to verify)* on the lab list. Nothing here is guessed.

## Behaviour

- *(observed)* The staging secret `<name>-pending` is written with a one-day expiry, so a
  machine that stays off for longer than that has an **expired** staging secret waiting when
  the next run tries to resume. Verified against a real vault on 2026-09-08: a staging secret
  whose expiry lay two days in the past was read, applied to the guest and promoted
  (`tests/manual/Invoke-LabSmokeTest.ps1`, step `resume-expired-pending`). That matches
  [About Azure Key Vault secrets](https://learn.microsoft.com/en-us/azure/key-vault/secrets/about-secrets),
  which says `get` works on an expired secret and names recovery as the reason. The same page
  also says operations outside the `nbf`/`exp` window are disallowed "except in particular
  situations", and [Azure/AzureKeyVault#19](https://github.com/Azure/AzureKeyVault/issues/19)
  reports the error `Operation get is not allowed on an expired secret` in the wild.
  `Get-RotationSecret` treats that message as an error rather than as "absent", so if it ever
  appears the run stops loudly instead of rotating over a staged value.
- *(observed)* The `State` tag on the staging secret is the resume flag. Remove it by hand and
  the next run does not resume; it rotates fresh. The machine and the vault end up in step
  again, one rotation later, and the staged value is left behind as an orphan. No lockout — see
  [ADR 0005](docs/decisions/0005-stage-before-apply.md) for the write order that guarantees it.
- *(Microsoft)* Key Vault caps a tag value at 256 characters, which is why the SSH public key is
  stored as its own secret rather than as a tag on the private one.

## The account was renamed inside the guest

Measured on 2026-09-08 with `tests/manual/Invoke-RenamedAccountProbe.ps1`: the OS-profile
account was renamed on the machine, one rotation by name was run, and the local accounts were
listed before and after. The two platforms behave differently, and neither locks anyone out.

- *(observed)* **Windows: a second administrator appears.** VMAccess does not find the
  OS-profile name, creates it as a new local account (RID 1000, member of Administrators) and
  sets the new password on *that*. The renamed original (RID 500) keeps its old password,
  which is still the previous version of the secret in the vault. The rotation reports
  `Rotated`, so nothing in the job output says two administrators now exist. If you rename
  provisioning accounts, either rename them in the Azure OS profile as well or keep the VM
  out of scope.
- *(observed)* **Linux: the rotation fails, loudly.** VMAccess tries to create the missing
  user, `useradd` refuses because the renamed account still owns the uid and the home
  directory, and the extension reports `Failed to create user account: <name> (0x07)`. The
  rotation is recorded as `Failed`, the staged value stays in the `-pending` secret, the
  renamed account and its password are untouched. The next run retries; rename the account
  back, or update the OS profile, and it resumes from the staged value.

## Hardened images

Measured on 2026-09-08 against the CIS Level 1 marketplace images for Windows Server 2022
(`cis-windows-server-2022-l1-gen2`) and Ubuntu 24.04 (`cis-ubuntulinux2404-l1-gen2`), with the
same checks as the plain images: every Windows path passed (7 of 7), every Linux path passed
(4 of 4), including SSH login with the rotated key and the password against the shadow hash.

- *(observed)* **Windows, CIS L1.** Minimum password age is one day, minimum length 14, history
  24, lockout after five attempts. None of it got in the way: VMAccess sets the password
  through the account-management API, which is exempt from the minimum age, and the generated
  24-character password satisfies length and complexity. Note that on Windows, Azure
  provisioning renames the built-in Administrator (RID 500) to the OS-profile name, so the
  CIS recommendation to rename that account is met by the platform - and the account the
  module rotates *is* RID 500.
- *(observed)* **Ubuntu, CIS L1.** `/tmp` is mounted `noexec`; the VMAccess extension does not
  care. `pwquality` enforces `minlen 14`, `minclass 4`, `maxrepeat 3`, `maxsequence 3` and
  `dictcheck`, with `enforce_for_root`, and the generated password passed every time. A
  random 24-character password can, rarely, contain three identical characters in a row or
  a four-character sequence; if `chpasswd` then refuses it, the rotation is reported as
  `Failed` and the next run tries again with a fresh value - nothing is left half-done,
  because the machine is only touched after the value is staged.
- *(observed)* **Password authentication in sshd.** The image ships
  `60-cloudimg-settings.conf` with `PasswordAuthentication no`, but cloud-init writes the OS
  profile's setting to `50-cloud-init.conf`, which sshd reads first, so the effective value
  follows the Azure OS profile - the same switch the module consults. `PermitRootLogin no`
  and `MaxAuthTries 4` do not affect VMAccess, which works through the agent, not SSH.
- *(observed)* SSH keys accumulate in `authorized_keys` across rotations unless
  `-RemovePriorSshKeys` is set: two rotations, two keys. That is the documented default, and
  the reason for it is on the parameter.

## Platform

- *(observed)* Azure Automation keeps job-schedule ids after the automation account is
  deleted. A job schedule named `guid(automationAccount.id, …)` therefore collides when the
  same resource group and account names are deployed again: `A jobSchedule with same id
  already exists`, on an account that has no job schedules at all. Seen on 2026-09-08 when the
  lab was rebuilt after a delete. `deploy/modules/automation.bicep` seeds the id with a
  per-deployment stamp instead.
- *(observed)* With roles in more than one subscription, `Connect-AzAccount -Identity` picks
  the first subscription it sees as the context, not the automation account's own. Measured
  on 2026-09-08 with a machine in a second subscription: the job started in that one, the
  concurrent-job check looked for the account there, failed with a warning, and two jobs ran
  side by side. The runbook now pins its context to `CR_AutomationSubscriptionId` right after
  connecting, and falls back to searching for the account when the variable is absent.
- *(observed)* Automation ignores a PUT on a job schedule whose runbook and schedule are
  already linked. ARM reports `Created`, no second link appears, and **the existing link keeps
  its parameters** - measured on 2026-09-08 by re-deploying the link with `dryrun=False` and
  reading `DryRun=True` back. That is why the deployment carries no parameters on the link and
  reads `dryRun` from the `CR_DryRun` variable: a redeployment with `dryRun=false` would
  otherwise have reported success and changed nothing.
- *(observed)* Azure Automation schedules run at most hourly. That is the floor on how long a
  credential marked for rotation waits, and why the grace period and the interval are discussed
  together in the README rather than tuned separately.
- *(observed)* A password change does not end an established RDP session, but it does break
  reconnects, UAC elevation and anything that re-authenticates. The grace period exists for the
  person who just read the credential and is still using it.
