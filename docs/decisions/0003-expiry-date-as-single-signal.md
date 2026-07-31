# 0003 — The expiry date is the only rotation signal

**Status:** accepted · 2026-07-31

## Context

Two things should cause a credential to be replaced: it is getting old, and somebody
has used it. The obvious implementation gives each its own path — a schedule for the
first, an alert-to-webhook chain for the second — and ends up with two ways to rotate,
two sets of failure modes and two things to test.

## Decision

A detected read does not start a rotation. It **moves the secret's expiry date
forward** to now plus the grace period. The ordinary near-expiry logic then does the
work.

## Why

**One code path.** Rotation is generated, staged, applied and promoted in exactly one
place, no matter what prompted it. The trigger is recorded on the record for
reporting, and changes nothing about the mechanism.

**The state lives where it belongs.** "This credential should be replaced by 20:00" is
a property of the credential, not of a queue message or a workflow instance. It is
visible in the portal, it survives everything, and it needs no additional store.

**Idempotent by construction.** Running twice sets the same date twice. Overlapping
lookback windows are harmless, which is what allows the window to be generously wide
without any deduplication logic.

**It cheats the fair-share limit.** Automation kills a job after three hours, so an
in-process wait for an eight-hour grace period is impossible. Writing a date and
letting a later run act on it sidesteps the problem entirely — the waiting is done by
the calendar, not by a process.

**Attribute updates are cheap and quiet.** Changing an expiry date creates no new
secret version, so consumers are undisturbed, and it registers as `SecretPatch` rather
than `SecretGet` — so the tool's own writes cannot be mistaken for human reads by the
query that detects them.

## Consequences

- Rotation-after-use is not immediate. Total exposure is the grace period plus one
  schedule interval.
- The expiry date carries two meanings at once: natural lifetime, and "replace this
  soon". Anyone reading the vault sees a date that moved without an obvious cause. The
  `RotationReason` and `LastAccessedBy` tags exist to make that legible.
- Anyone with write access to secret attributes can schedule a rotation by editing a
  date — useful for on-demand rotation, and worth knowing.
- Key Vault does **not** enforce secret expiry: `get` on an expired secret still works,
  by design, for recovery. The date is a marker for this system, not an access control.
  Any README claiming otherwise would be wrong.

## Revisit if

Rotation needs to be immediate on access, or the dual meaning of the expiry date turns
out to confuse operators more than the extra code path would have.

The natural evolution is to stop storing long-lived credentials at all: generate one
on request, hand it over, expire it in hours. That design has no calendar rotation, and
this ADR is what would be replaced.
