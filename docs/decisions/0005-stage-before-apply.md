# 0005 — Stage the credential before applying it

**Status:** accepted · 2026-07-31

## Context

The worst outcome for a rotation tool is a machine holding a credential nobody knows.
It has one cause: the credential reached the VM but not the vault.

The obvious orders both have a hole:

- **Vault first, then VM.** If the VM update fails, the vault advertises a credential
  the machine never accepted. Everyone who reads it is locked out.
- **VM first, then vault.** If the vault write fails — throttling, an expired role
  assignment, a firewall rule, a transient fault — the credential is gone. This is the
  unrecoverable one, and it is the order most examples use.

## Decision

Stage the value in a separate `<name>-pending` secret before touching the VM:

```
1. write value ──▶ <name>-pending  (State=pending)
2. apply to the VM
3. write value ──▶ <name>
4. disable <name>-pending          (State=consumed)
```

## Why

At no point does a credential exist only on the machine. A crash between 2 and 3 leaves
the value in `<name>-pending`; the next run finds it, re-applies the same value to the
VM — which is idempotent — and promotes it. A crash between 1 and 2 leaves a staged
value the VM never received, and the same resume path handles it.

Callers reading `<name>` only ever see a value the VM has accepted, because the
promotion is the last thing that happens.

**Why a separate secret rather than a new version of the same one.** A staged value
written as a new version becomes the *latest* version, which is what an unqualified
read returns — so anyone fetching the credential mid-rotation would get one the machine
does not have yet. Writing it disabled does not help: Key Vault returns an error for a
disabled latest version rather than falling back to the previous one.

**Why overwritten, and neither deleted nor disabled.** All three were tried against a
real vault:

- *deleted* — soft-delete reserves the name until it is purged, so the next rotation
  fails writing to it. Purging needs another permission and is irreversible.
- *disabled* — reads then fail with "Operation get is not allowed on a disabled
  secret", a 403 that looks exactly like a missing role assignment. Because this
  engine deliberately refuses to treat an unreadable secret as absent, one disabled
  staging secret aborted discovery for an entire subscription.
- *overwritten with a placeholder* — the value is gone, the metadata stays readable,
  the name stays usable. This one.

## Consequences

- Two secrets per credential in the vault. Outside an active rotation the staging one
  holds a placeholder and carries `State=consumed`.
- An interrupted rotation leaves a real credential readable in the staging secret until
  the next run closes it. It is covered by the same vault access controls, and this is
  the deliberate trade against losing it entirely.
- Anything enumerating the vault sees `-pending` entries. They are filtered out of
  access detection so the tool cannot trigger itself.
- Recovery reads the staged value, which is a `SecretGet` by the managed identity. That
  carries no UPN claim and so never registers as human access.

## Revisit if

Key Vault gains a way to write a non-latest version, or a two-credential model (like
the primary/secondary key pattern for storage accounts) becomes available for VM
credentials — a VM can only hold one password per account, so it does not today.
