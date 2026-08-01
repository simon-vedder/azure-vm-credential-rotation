# Changelog

## [0.1.0] — 2026-08-01

Initial release, verified end to end against a live Azure tenant. See the status
section in the README for what that covered and what it did not.

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

- Rotation engine as a PowerShell module (`src/CredentialRotation`), flattened into a
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
