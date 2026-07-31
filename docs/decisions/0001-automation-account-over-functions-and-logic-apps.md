# 0001 — Azure Automation over Functions and Logic Apps

**Status:** accepted · 2026-07-31

## Context

The rotation logic is PowerShell that calls Az cmdlets. Three Azure runtimes could
host it: Automation runbooks, Functions, or Logic Apps as an orchestrator calling
either.

## Decision

Azure Automation, with the logic in a single runbook.

## Why

**Against PowerShell Functions.** The Az modules are large and the managed-dependency
mechanism for PowerShell Functions is slow and historically fragile. Cold starts run
to tens of seconds. Pinning module versions means baking them into the deployment,
which removes the main convenience the runtime offered. Automation manages Az modules
as a first-class concern, which is precisely the problem being avoided.

**Against Logic Apps.** Logic Apps were seriously considered as an orchestrator —
they have a native Event Grid trigger, `Delay until`, per-action retry policies and a
run history, all of which would have replaced hand-written scheduling. Two things ruled
them out:

1. Once the design settled on a reconciliation loop ([ADR 0002](0002-reconciliation-loop-over-events.md)),
   there was nothing left to orchestrate. Delay, retry and state were only needed
   because events created the need for them.
2. Logic Apps record action inputs and outputs in the run history. Keeping credentials
   out of that means the orchestrator can never see a value — so all the real work
   happens in a runbook anyway, and the Logic App becomes a wrapper around the thing
   that does the work.

Their cost is also real: Consumption workflows mean API connections and a workflow
definition that lives as JSON in Terraform rather than readable HCL; Standard has a
fixed monthly plan cost that is hard to justify for a few runs a day.

**For Automation.** One resource, PowerShell as a first-class runtime, managed
identity, a scheduler, and 500 free job minutes a month — comfortably more than this
uses. The audience for this repository already reads PowerShell and can open a runbook
and understand it, which is worth more here than architectural elegance.

## Consequences

- Runbook jobs are capped at three hours by Automation's fair-share limit. This is
  what makes an in-process `Start-Sleep` for the grace period impossible, and pushed
  the design towards writing the deadline into the expiry date instead. That turned
  out to be the better design regardless.
- No sub-minute latency. Accepted; see ADR 0002.
- The module has to be flattened into a single file, because Automation runs one
  script per job ([ADR 0004](0004-powershell-module-with-build-step.md)).

## Revisit if

Rotation needs to react within seconds, the fleet grows past what one sequential job
can process inside three hours, or the logic stops being PowerShell.
