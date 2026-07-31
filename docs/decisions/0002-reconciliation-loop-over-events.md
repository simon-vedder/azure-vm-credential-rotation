# 0002 — A reconciliation loop, not Event Grid

**Status:** accepted · 2026-07-31

## Context

Key Vault publishes `SecretNearExpiry` to Event Grid 30 days before a secret expires,
and Microsoft's reference architecture for secret rotation subscribes a Function to it.
Reacting to that event instead of polling looks like the obvious modernisation.

It was investigated properly and rejected. This ADR records why, because "we scanned
instead of subscribing" looks like a shortcut and is not.

## Decision

A scheduled run reconciles the whole estate. No event subscription.

## Why

**The event fires once.** There is no second delivery. The most common outcome in this
domain is *skip, the VM is powered off* — which is a **successful** handler invocation
returning 200, so Event Grid's retry never engages. Forcing a retry means deliberately
returning 5xx from a healthy handler, and Event Grid's retry schedule spans about a day,
while a development VM can be off for two weeks.

**The threshold is fixed at 30 days.** Not configurable. A design built on it inherits
that number whether or not it suits the validity period.

**It fires only for new versions.** A secret whose expiry date is edited in place —
exactly what access-driven rotation does — is not a reliable trigger.

**Microsoft's reference architecture has no timer backstop.** That is defensible for
storage account keys, where the resource is always available. VMs are not always
available, and copying the pattern would produce silent rotation gaps.

**Fixing all of that requires an orchestrator**, and an orchestrator is a third
technology to deploy, secure and operate. Every problem it would solve — delayed
execution, retry, durable state — exists *only because* of the switch to events.

A loop has none of them. **The schedule is the retry.** Nothing is remembered between
runs beyond what is already in Key Vault, so nothing can be lost. A powered-off VM, a
throttled call, an unhealthy guest agent: all handled by doing nothing and running
again later.

## Consequences

- Worst case between a credential being read and replaced is the grace period plus one
  schedule interval, 14 hours by default, rather than minutes. For credentials that
  would otherwise sit for 90 days, that is not a meaningful difference.
- Every run enumerates tagged VMs and reads secret metadata. At a few hundred VMs this
  is fine; at several thousand, ARM throttling becomes the limit and the design needs
  revisiting.
- No infrastructure beyond the automation account: no Event Grid subscription, no
  Function App, no Logic App, no queue, no storage account.

## Revisit if

Rotation must happen within minutes of a credential being read, or the fleet grows past
what one sequential run can enumerate comfortably.

If it does, the event-driven version needs, at minimum: Event Grid to a **queue** rather
than directly to the handler — which buys back retry, dead-lettering and delayed
redelivery — plus a scheduled reconciliation pass anyway, to catch what the queue drops.
That is the honest cost, and it is why this was not the starting point.
