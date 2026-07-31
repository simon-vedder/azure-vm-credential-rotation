# Changelog

## [0.1.0] — 2026-07-31

Initial release. Not yet deployed against a live tenant end to end; see the status
section in the README for what remains unverified.

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
