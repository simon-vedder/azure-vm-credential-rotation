# Known issues and sharp edges

Every entry says where it comes from: *(observed)* in a lab or a real run, *(Microsoft)* from
official documentation, *(to verify)* on the lab list. Nothing here is guessed.

## Behaviour

- *(observed)* **Key Vault looks secret names up case-insensitively, and Azure is inconsistent
  about the case of a resource group name.** A subscription-wide `Get-AzVM` returns it
  upper-cased; a targeted `Get-AzVM -ResourceGroupName` returns it as typed. With a `{rg}`
  template the same machine would therefore be written as `RG-PROD-web-01-pw` by the runbook
  and `rg-prod-web-01-pw` from a prompt. No second secret is created - a lookup finds the
  other casing, verified against a real vault - but the name changes shape depending on who
  wrote it, so `{rg}` is lower-cased before substitution. Names built from `{vm}` and `{user}`
  keep their original casing, because those values are consistent.
- *(observed)* **Two machines with the same name share one secret.** A VM name is unique in a
  resource group, not in a subscription, and the default template `{vm}-{user}-{kind}` uses
  neither the resource group nor the subscription. `web-01` in `rg-prod` and `web-01` in
  `rg-test` therefore resolve to the same secret: the first rotation writes it, the second
  finds it and, under `-OnlyIfDue`, leaves it alone - so the vault holds a credential that
  works on one of the two machines with nothing recording which. Found on 2026-09-08 while
  building the scale lab, which is why that template takes a name prefix per region. No
  lockout: both machines keep working credentials, but one of them is not the one in the
  vault. Where duplicate names are possible, key the name by resource group instead:
  `-SecretNameTemplate '{rg}-{vm}-{kind}'`. The `{rg}` placeholder exists for this and is
  refused if no resource group is supplied. Changing the template on an estate that is
  already rotating starts new secrets under the new names; the old ones stay until removed.

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

## What a rotation changes besides the credential

Measured on 2026-09-08 with `tests/manual/Test-HardeningDrift.ps1`, which photographs the
settings a baseline checks, rotates, and photographs them again.

- *(observed)* **On Linux the extension restores passwordless sudo.** VMAccess writes
  `/etc/sudoers.d/waagent` containing `<user> ALL = (ALL) NOPASSWD: ALL` for the OS-profile
  account. On a stock image cloud-init has already granted the same thing, so nothing changes.
  On a machine where somebody removed that grant deliberately - a standard hardening step - the
  next rotation puts it back, silently and every time. Verified by removing both
  `/etc/sudoers.d/waagent` and `/etc/sudoers.d/90-cloud-init-users`, rotating, and finding
  `waagent` recreated with `NOPASSWD: ALL`. This is the same class of problem as VMAccess
  recreating a deleted account, and more likely to be hit. If passwordless sudo is not
  acceptable for the account that holds the credential, keep the machine out of scope, or
  reassert the sudoers policy after rotation with configuration management.
- *(observed)* **On Windows, nothing moved at all.** The full local security policy, the audit
  policy, local group membership, the enabled accounts, the RDP setting and the password policy
  were identical before and after a rotation on the CIS Level 2 image. The password change goes
  through the account-management API and touches nothing else.
- *(observed)* On the STIG Ubuntu image the only other differences were the `chage` last-change
  date and the key count in `authorized_keys`, both of which are the rotation doing its job.

## Hardened images

Measured on 2026-09-08 against four hardened marketplace images: CIS Level 1 for Windows
Server 2022 (`cis-windows-server-2022-l1-gen2`) and Ubuntu 24.04
(`cis-ubuntulinux2404-l1-gen2`), CIS Level 2 for Windows Server 2022
(`cis-windows-server-2022-l2-gen2`), and the CIS STIG build of Ubuntu 24.04
(`cis-ubuntu2404-stig-gen2`, which is the strictest of the four and stands in for a Linux
Level 2, since none is published). The same checks as the plain images, and every path
passed on every image, including SSH login with the rotated key and the password against
the shadow hash.

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
- *(observed)* **A hardened guest can expire the password before the vault does.** The CIS
  STIG image for Ubuntu 24.04 sets a maximum password age of 60 days (`chage -l`), while
  `-ValidityDays` defaults to 90. The account's password then expires in the guest three
  weeks before anything schedules a rotation, and password logins start demanding a change.
  Measured on 2026-09-08. Set `-ValidityDays` (or `validityDays` in the deployment) below the
  shortest maximum age in the estate; the CIS Level 1 images use 365 on both platforms, the
  STIG image 60. Nothing warns about this: the tool sets the credential, it does not read the
  guest's aging policy.
- *(observed)* **CIS STIG for Ubuntu, and why the generated password satisfies it.** The STIG
  image enforces `minlen 15`, `difok 8`, `dictcheck`, `enforcing = 1` and one character from
  each of the four classes (`dcredit`/`ucredit`/`lcredit`/`ocredit` at -1). The generator
  draws one character from each class before filling the rest, which is what makes it pass by
  construction rather than by luck. Every rotation path was run against this image on
  2026-09-08 and passed, as did CIS Level 2 for Windows Server 2022.
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
