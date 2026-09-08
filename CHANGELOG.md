# Changelog

## [0.4.1] — 2026-09-08

### Fixed

- `{rg}` is lower-cased before it goes into a secret name. A subscription-wide `Get-AzVM`
  returns the resource group upper-cased while a targeted one returns it as typed, so the
  runbook and a prompt produced differently-cased names for the same machine. Key Vault looks
  names up case-insensitively, so no second secret was ever created - verified against a real
  vault - but the name should not change shape depending on who wrote it.

## [Unreleased]

### Added

- `tests/manual/Test-HardeningDrift.ps1`, which answers a question the smoke tests do not:
  a rotation working on a hardened image is one thing, leaving it hardened is another. It
  photographs what a baseline measures, rotates, and diffs.

### Documented

- **VMAccess restores passwordless sudo on Linux.** It writes `/etc/sudoers.d/waagent` with
  `NOPASSWD: ALL` for the OS-profile account on every rotation. Stock images already grant
  that; a machine where it was removed on purpose gets it back. Verified by removing both
  sudoers files, rotating, and finding it recreated. In KNOWN-ISSUES, the threat model and
  the README, because it is the same class of surprise as the extension recreating a deleted
  account.

## [0.4.0] — 2026-09-08

### Added

- **`{rg}` in `-SecretNameTemplate`.** A VM name is unique in a resource group, not in a
  subscription, and the default template uses neither the group nor the subscription, so
  two machines called `web-01` resolved to one secret and the vault ended up holding a
  credential that works on one of them with nothing saying which. Found while building the
  scale lab. `-SecretNameTemplate '{rg}-{vm}-{kind}'` separates them; a template that uses
  `{rg}` without a resource group is refused rather than silently collapsed. The default is
  unchanged, so nothing moves under an existing estate. See KNOWN-ISSUES.
- **`CR_SecretNameTemplate`**, so the deployed path can use it. The runbook had no way to set
  a template at all, which would have left the fix above unavailable exactly where duplicate
  names are likely. Eighteen `CR_*` variables now, in Bicep, Terraform and the contract test.
  The access scan deliberately does not use it: the audit log reports the name that was read.

- `deploy/lab-scale.bicep` and `tests/manual/Measure-RotationThroughput.ps1`: a fleet of small
  Linux machines and a script that times the four phases a pass is made of, so the scale limit
  can be stated from measurement instead of estimated.
- **Machines in other subscriptions.** `deploy/main.bicep` takes `targetResourceGroupIds`
  (resource groups anywhere in the tenant, by resource ID) next to `targetResourceGroupNames`
  (this subscription, by name), and assigns Virtual Machine Contributor where each group
  lives. `targetSubscriptionIds` now grants the role at subscription scope on each listed
  subscription instead of only telling the runbook to walk it - which is what it did before,
  leaving the identity without a role there. The runbook walks every subscription mentioned
  in either list, plus this one if any of its groups are named.
- `deploy/lab.bicep` builds variations: a second lab in another subscription
  (`deployKeyVault=false`, `deployWindowsVm=false`, `nameSuffix`), and marketplace images
  with a plan, for CIS hardened guests.
- `tests/manual/Invoke-OrchestratorSmokeTest.ps1` gained a step that proves the second
  subscription is walked and its machine rotated. `tests/manual/Invoke-RenamedAccountProbe.ps1`
  measures what a rotation does when the OS-profile account was renamed inside the guest.

### Fixed

- **Redeploying with `dryRun=false` now takes effect.** Automation ignores a PUT on a job
  schedule whose runbook and schedule are already linked: the deployment reported success
  and the link kept `DryRun=True`. The setting moved into the automation variable
  `CR_DryRun`, which ARM updates reliably; the link itself carries no parameters. The
  runbook reads the variable when `-DryRun` is not passed explicitly.
- **The runbook pins its context to its own subscription.** With roles in a second
  subscription, `Connect-AzAccount -Identity` chose that one, the concurrent-job check
  looked for the automation account in the wrong place, and two jobs ran side by side. The
  new `CR_AutomationSubscriptionId` variable says where home is; older deployments without
  it are searched for.
- A deployment into an account that was deleted and recreated under the same names failed
  with `A jobSchedule with same id already exists`, because Automation keeps job-schedule
  ids beyond the account's life. The id is seeded with a per-deployment stamp.

### Changed

- The README's scale note names the real limit: sequential rotations against a three-hour
  job, not ARM throttling.
- Bicep is stated as the verified deployment path; Terraform stays, CI-validated, last
  deployed live with 0.1.0 (note in ADR 0007).

## [0.3.0] — 2026-09-08

**Breaking.** The module no longer selects machines. It rotates the machines it is given
and has no opinion about tags; every policy decision moved to the orchestrator that calls
it. That is what lets the same code run from a workstation against one named machine and
from a runbook against a fleet, without a mode switch — the same split the sibling tool
uses, where the module never reads a tag and the runbook owns discovery.

### Breaking

- **The module returns facts and takes findings; it neither looks for work nor ships
  results.** Three more things left it, for the same reason the tags did:
  - `Register-CredentialAccess` no longer queries Log Analytics. It takes `-SecretName`,
    `-AccessedBy` and `-AccessedAt` — pipeline-capable, so the audit-log query pipes straight
    in — and moves that one secret's expiry forward. Who read what is the orchestrator's
    finding; the KQL now lives in the runbook and in `queries/accessed-secrets.kql`.
  - `Invoke-CredentialRotation` no longer writes records to Log Analytics.
    `-DataCollectionEndpoint`, `-DataCollectionRuleId` and `-StreamName` are gone; the
    records it always returned in `.Records` are the whole interface, and the runbook
    ships them to the table it deployed.
  - `Az.OperationalInsights` is no longer a required module. A workstation rotating one
    machine never needed it.
- `Invoke-CredentialRotation` no longer discovers machines. It takes `-VMName` (one, by
  name) or `-VM` (machines the caller selected). The subscription loop, `-EnableTagName`,
  `-EnableTagValue` and `-HoldTagName` are gone.
- **Everything handed in is rotated.** Whether the expiry date gets a vote is `-OnlyIfDue`,
  a parameter of its own — not something inferred from whether you passed a name or a list.
  How you identify machines and what should happen to them are two questions, and the first
  answer was letting the shape of the input decide the second. `-ThresholdDays` is only
  consulted with `-OnlyIfDue`, and warns if you pass it without.
- `Invoke-CredentialRotation` no longer runs the access scan. Call
  `Register-CredentialAccess` first if you want rotation after use; it pulls the expiry
  dates forward and the rotation then sees ordinary ageing. One signal, one code path,
  and the orchestrator decides how often to look.
- `Get-RotationCandidate` requires `-VM` and lost the tag parameters. New `-OnlyIfDue`
  turns the expiry check on; without it every machine handed in is a candidate.
- `Register-CredentialAccess` lost `-HoldTagName`. A hold is a statement about a machine,
  not a fact about a credential.

### Added

- `-SecretNameTemplate` on `Invoke-CredentialRotation`, `Get-RotationCandidate` and
  `Update-VMCredential`, with `{vm}`, `{user}` and `{kind}` as placeholders and the shape
  this tool has always used as the default. The naming convention was the last policy
  decision hard-wired into the module; a vault with its own convention can now be used
  as it is. A template without `{vm}` or `{kind}` is refused, because credentials would
  collide on one secret.
- The runbook wrapper is now the orchestrator: tag discovery, hold filtering, the
  subscription walk and the access scan all live there, and it passes `-OnlyIfDue` so a
  six-hourly job replaces what is due rather than everything it can see. It also refetches
  each selected machine in full, because the list form of `Get-AzVM` has no `OSProfile`.
- A test asserting the scheduled pass asks for due credentials only, because the safe
  default moved out of the module and into the caller.
- A guard, through the parser, that no module file calls `Invoke-AzOperationalInsightsQuery`,
  `Invoke-RestMethod` or `Invoke-WebRequest` — and that the runbook does.
- Two tests that assert the layering itself, through the PowerShell parser rather than a
  regex: the module never calls `Get-AzVM` without `-Name` or `-ResourceGroupName`, and no
  module file uses a tag variable. A third checks the runbook does both, so the behaviour
  cannot pass by simply disappearing.

- `deploy/lab.bicep`: one Windows and one Linux VM with password authentication on, no
  public IP, and a Key Vault with RBAC, so every path the module has can be run against
  real guests. `tests/manual/Invoke-LabSmokeTest.ps1` does exactly that from a workstation
  and checks each rotation on the machine through Run Command;
  `tests/manual/Invoke-OrchestratorSmokeTest.ps1` drives the deployed runbook through dry
  run, live run, hold tag, audit-log detection and the custom table.

### Fixed

- The runbook's record writer accepts the token as either a string or a SecureString.
  Az.Accounts 5 returns the latter, and the same wrapper is meant to work at a prompt as
  well as in the sandbox's older module.
- `docs/operations.md` still described a per-secret hold tag. That went with
  `-HoldTagName` in this release; a hold is a statement about a machine.

### Unchanged

- The 15 `CR_*` automation variables, so Bicep, Terraform and the deployment contract test
  are untouched. `HoldTagName` became an ordinary wrapper parameter rather than a
  sixteenth variable, precisely to keep that contract still.

## [0.2.0] — 2026-09-08

### Added

- **Rotate one named machine, from your own workstation.**
  `Invoke-CredentialRotation -VaultName kv-creds -VMName jump-01` rotates that machine
  and nothing else. The enable tag is not required and the expiry threshold does not
  apply, because naming a machine is a stronger statement of intent than a tag — the
  same reasoning the sibling tool uses for `-Target`. The secret is created in the vault
  if it is not there yet, so this is also how a machine is onboarded by hand.

  Until now the only local route was `Update-VMCredential`, which takes a VM *object* and
  a credential type: an internal interface, not an entry point.

- `-IgnoreHold`, available only with `-VMName`. The hold tag means somebody is working on
  that machine, so it still applies when you name it; overriding is possible but has to be
  said out loud. A scheduled run cannot talk itself out of a hold at all.

- `Get-RotationCandidate -VM`, the same thing one level down, for callers that already
  hold VM objects.

### Changed

- `-ThresholdDays`, `-EnableTagName`, `-EnableTagValue`, `-WorkspaceId`, `-GracePeriodHours`,
  `-AccessLookbackHours` and `-ExcludeObjectId` are now on the estate parameter set only.
  They did nothing when a machine was named, and a parameter that silently does nothing is
  a small lie.

### Notes

- `Resolve-TargetVM` refuses an ambiguous name instead of taking the first match, and names
  the resource groups it found. It also re-fetches the machine by resource group, because
  the list form of `Get-AzVM` returns no `OSProfile` — which downstream would have reported
  as "specialised image" rather than "found".

## [0.1.0] — 2026-09-08

First published release, verified end to end against a live Azure tenant. See the status
section in the README for what that covered and what it did not.

### Deployment and distribution

- **Bicep, beside the Terraform rather than instead of it.** `deploy/` creates the same
  resources `infra/` does, with rotation-after-use as a feature flag rather than a stacked
  module, and a compiled `azuredeploy.json` so a deploy button has something to point at.
  Verified with `az deployment sub what-if` against ARM: 33 changes, nothing created.
- **The module is published to the PowerShell Gallery.** [ADR 0006](docs/decisions/0006-the-module-goes-to-the-gallery.md)
  supersedes the gallery rejection in [ADR 0004](docs/decisions/0004-powershell-module-with-build-step.md),
  whose premise — one consumer — no longer holds. The Bicep path imports the module by
  version; the Terraform path still publishes the flattened runbook and needs no Gallery.
- **The runbook wrapper works either way.** It imports the module only when its commands
  are not already defined, so the flattened artefact is unaffected.
- **A generated command reference** under `docs/commands`, built from the module's own help,
  with CI failing when the two drift apart.
- **A contract test** comparing the `CR_*` automation variables Terraform writes, Bicep
  writes and the runbook reads, in every direction. Nothing in the type system connects
  those three, and a mismatch there fails silently.

### Found by the live test

Everything below passed unit tests, PSScriptAnalyzer and `terraform validate` before
being deployed, and broke anyway. Recorded because each one is a trap for anyone
building something similar.

- **`for_each` over scope IDs** could not be planned when the caller creates the
  resource group in the same apply — the common case. Now `count`.
- **`file()` reaching outside the module** worked with a local relative `source` and
  would have broken for anyone consuming the module from a git URL, exactly as the
  README suggests. The runbook artefact now lives inside the core module.
- **Empty automation variables** are rejected by the provider. Filtering them with a
  comprehension made the map's keys unknown at plan time, so the optional entry is
  merged in instead.
- **`Write-Host` and `Write-Information` never appear in Azure Automation job
  streams.** Measured directly: of the five ways to log, only Output, Verbose and
  Warning arrive. Verbose is the only one that is both visible and safe inside a
  function that returns a value, and Automation drops it entirely unless the runbook
  has `logVerbose` on — hence that default.
- **Hashtables passed to `-ProtectedSettings`** serialise differently depending on the
  Az module version. Identical call and password: fine on Az.Accounts 5.5 locally,
  and inside the sandbox's 2.15 the extension received a nested object and failed with
  `crypt() argument 1 must be str, not dict`. Settings are now built as explicit JSON.
- **A public key does not fit in a Key Vault tag** (256 characters). On resume it is
  derived from the staged private key instead.
- **Disabled secrets cannot be read** — Key Vault answers with a 403 that reads like a
  permissions failure. Since the engine deliberately refuses to treat an unreadable
  secret as absent, one disabled staging secret took down discovery for an entire
  subscription. Staging secrets are now overwritten rather than disabled.
- **The `Automation Job Operator` role was missing**, so the concurrency check threw,
  was caught, and silently protected nothing.
- **Access-driven rotations were recorded as `Expiry`**, because access works by
  moving the expiry date. A tag now carries the real reason through, so the audit
  trail can distinguish "replaced because someone read it" from "replaced because it
  got old".

### Added

- Rotation engine as a PowerShell module (`src/AzureVMCredentialRotation`), flattened into a
  single runbook by `build/Build-Runbook.ps1`
- Calendar-driven rotation of Windows and Linux local passwords and Linux SSH keys
- Access-driven rotation: a human read pulls the secret's expiry date forward, and the
  ordinary near-expiry pass replaces it
- Three Terraform modules that stack — `core`, `observability`, `rotate-on-access`
- Log Analytics custom table via the Logs Ingestion API, plus a workbook correlating
  credential reads with rotations
- Pester tests and a CI pipeline covering analyzer, tests, build freshness and
  `terraform validate`

### Design notes

Carried over from a predecessor script, with the following changed deliberately:

- **Credentials are staged before they are applied**, so a failed vault write can no
  longer leave a machine holding a password nobody knows ([ADR 0005](docs/decisions/0005-stage-before-apply.md))
- **Missing secrets and unreadable secrets are distinguished.** A denied role
  assignment is no longer interpreted as "no secret here, rotate"
- **Discovery is opt-in by tag.** Previously every VM in every reachable subscription
  was a candidate, which on a first run in an established tenant would rotate
  everything it could see
- **`remove_prior_keys` and `reset_ssh` default to off**, so SSH rotation no longer
  wipes `authorized_keys` or resets `sshd_config` by default
- **SSH key generation rewritten** — the previous PEM mixed CRLF and LF line endings,
  and the public key was assembled by appending to an untyped array. Output is now
  verified against `ssh-keygen`
- **Password generation uses rejection sampling** instead of modulo over random bytes,
  and satisfies complexity by drawing from each class and shuffling rather than
  inserting known characters at fixed positions
- **The job fails when rotations fail.** Errors were previously caught and counted, so
  the job reported success and any alerting built on job status was blind
