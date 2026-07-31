# Architecture

## The one idea

**The Key Vault expiry date is the only rotation signal.** Everything else writes to
it.

```
                      ┌──────────────────────────────────────┐
                      │  Key Vault                           │
   near expiry  ─────▶│    secret: exp = 2026-10-29          │
                      │    secret: exp = 2026-08-01 (moved)  │◀──── read by a human
                      └───────────────┬──────────────────────┘
                                      │
                        every N hours  │  "what is near expiry?"
                                      ▼
                      ┌──────────────────────────────────────┐
                      │  Automation runbook                  │
                      │    1. who read a secret? move exp     │
                      │    2. what is near exp? rotate it     │
                      │    3. write a record                  │
                      └───────┬──────────────────┬───────────┘
                              │                  │
                   VMAccess   │                  │  Logs Ingestion API
                              ▼                  ▼
                      ┌──────────────┐   ┌──────────────────────┐
                      │  the VM      │   │  Log Analytics       │
                      └──────────────┘   │   AZKVAuditLogs      │
                                         │   CredentialRotation │
                                         └──────────────────────┘
```

Rotation after use is not a second execution path. A read moves the expiry date
forward; the ordinary near-expiry logic does the rest. There is one code path to test,
one place where a credential is generated, one place where it is applied.

## Why a loop and not events

Key Vault publishes `SecretNearExpiry` to Event Grid, and Microsoft's own reference
architecture wires that to a function. It is a reasonable design for the problem it
was written for — rotating storage account keys — and a poor fit here.

An event fires **once**. The most common outcome in this domain is *skip, the VM is
powered off*, which is a successful handler invocation, so no retry is attempted and
the event is spent. Recovering from that needs a durable timer, a retry policy and
somewhere to keep state — an orchestrator. And the moment you add an orchestrator you
have three technologies to operate instead of one.

A reconciliation loop has no such problem, because **the schedule is the retry**.
Nothing is remembered between runs beyond what is already in Key Vault, so nothing can
be lost.

Full reasoning, including what would change the answer:
[ADR 0002](decisions/0002-reconciliation-loop-over-events.md).

## Components

| what | why it is that |
|---|---|
| Azure Automation | runs PowerShell with managed Az modules, on a schedule, with a managed identity, for free at this volume |
| Key Vault | holds the credentials *and* the schedule, in the form of expiry dates |
| Log Analytics | supplies who-read-what from the vault's own audit log, and receives rotation records |
| VMAccess extension | the only supported way to set a local credential on a running Azure VM |

No Function App, no Logic App, no Event Grid, no queue, no storage account.

## Timing

```
09:00   someone reads a credential
09:05   the read appears in Log Analytics
12:00   run: sees the read, sets exp = 20:00
18:00   run: exp is inside the threshold → rotate
```

Worst case between a read and its replacement is **grace period + schedule interval**.
The default 8 + 6 = 14 hours. Shorten the schedule interval before the grace period:
running more often is cheap, and cutting the grace period short interrupts the person
who is still working.

Two settings must stay in step, and the `rotate-on-access` module enforces it: the
access lookback window has to exceed the schedule interval, or a read that lands
between two runs is never seen. Overlapping windows are harmless — moving an expiry
date forward is idempotent, and a date that is already early enough is left alone.

## Write order

The failure that matters is a VM holding a password nobody knows. That happens when
the credential reaches the machine but not the vault.

```
1. write value ──▶ <name>-pending          value is now recoverable
2. apply to VM                             machine and vault both know it
3. write value ──▶ <name>                  callers see it
4. disable <name>-pending                  staging closed
```

A crash after 2 leaves an open staging secret. The next run finds it, re-applies the
same value (idempotent) and promotes it, rather than generating a third credential
nobody has.

The staging secret is disabled, not deleted: Key Vault soft-delete reserves a deleted
name until it is purged, so deleting it would break the next rotation.

## Independently deployable modules

The runbook resolves each setting as *parameter → automation variable → default*. Each
Terraform module writes its own `CR_*` variables:

```
core              CR_VaultName, CR_ThresholdDays, CR_ValidityDays, …
observability     CR_WorkspaceId, CR_DataCollectionEndpoint, CR_DataCollectionRuleId
rotate-on-access  CR_AccessRotationEnabled, CR_GracePeriodHours, CR_AccessLookbackHours
```

Deploy `core` alone and the runbook finds no workspace variable, so it runs plain
calendar rotation. Add `observability` and it starts writing audit records. Add
`rotate-on-access` and it starts querying for reads. Remove a module and the feature
switches off without touching the runbook.

## What is deliberately absent

- **On-demand rotation endpoint.** Starting the runbook by hand covers it, without a
  webhook whose URI has to live in Terraform state.
- **Per-VM locking.** A concurrency check stops overlapping *jobs*; within a job,
  rotation is sequential. The staging pattern makes a duplicate attempt safe rather
  than preventing it.
- **Alerting.** The workbook shows what happened. Alert rules are a local decision and
  a local naming convention; the data is there to build them on.
