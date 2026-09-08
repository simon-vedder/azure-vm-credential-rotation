# 0007 — Bicep beside Terraform, not instead of it

**Status:** accepted · 2026-09-08

## Context

The Terraform modules work, are documented, and were tested against a live tenant. They are also
the wrong artefact for one specific job: a "Deploy to Azure" button, which is what turns a
repository into something a stranger will try. That button takes an ARM template and nothing else.

The obvious move — translate the Terraform to Bicep and delete the Terraform — throws away working,
tested infrastructure to gain one button.

## Decision

Both. `deploy/` holds the Bicep and the ARM template compiled from it; `infra/` keeps the Terraform
modules. The Bicep path is what the tool page and the deploy button point at. The Terraform path
stays for people who already run Terraform, which includes the author.

Neither is a translation of the other at the file level. They converge on one contract: **the
`CR_*` automation variables the runbook reads at start-up.** That contract is what
`tests/DeploymentContract.Tests.ps1` asserts, comparing the names Terraform writes, the names Bicep
writes and the names the runbook reads, in every direction.

## Why

**Two audiences, two habits.** Someone evaluating the tool wants a button. Someone adopting it into
a platform wants a module they can put in a pipeline with the rest of their estate. Making the first
group learn Terraform, or the second group wrap an ARM template, costs more than maintaining two
thin deployment surfaces over one runbook.

**The duplication is bounded.** Neither path contains logic. Between them they create an Automation
Account, a runbook, a schedule, some role assignments and a set of string variables. The logic is
in the module, tested once.

**The drift has a guard.** The failure mode worth fearing is not "the two files look different", it
is "one path configures the runbook and the other quietly does not". That is a set comparison, and
a test does it on every push.

## Consequences

- Two files change when a setting is added. The contract test fails loudly if only one does, which
  is the point.
- The Bicep path creates its own Log Analytics workspace or takes an existing one by resource ID
  **and** GUID; Terraform reads the GUID off the resource itself. ARM cannot safely reference a
  resource in another resource group that it did not create, so the Bicep asks for what it cannot
  look up.
- The Bicep path cannot enforce `accessLookbackHours > scheduleIntervalHours` the way the Terraform
  precondition does — ARM has no cross-parameter validation. Instead the default is computed as
  twice the interval, so the unsafe value has to be chosen deliberately rather than reached by
  accident.

## Revisit if

The two paths start disagreeing about anything but syntax, or one of them stops being used. Deleting
the Terraform is a one-commit change whenever it earns it.
