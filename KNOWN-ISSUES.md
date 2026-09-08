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

## Platform

- *(observed)* Azure Automation schedules run at most hourly. That is the floor on how long a
  credential marked for rotation waits, and why the grace period and the interval are discussed
  together in the README rather than tuned separately.
- *(observed)* A password change does not end an established RDP session, but it does break
  reconnects, UAC elevation and anything that re-authenticates. The grace period exists for the
  person who just read the credential and is still using it.
