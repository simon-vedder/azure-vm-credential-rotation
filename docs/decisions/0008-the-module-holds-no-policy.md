# 0008 — The module rotates; the orchestrator decides who

**Status:** accepted · 2026-09-08 · changes the surface described in [0004](0004-powershell-module-with-build-step.md)

## Context

The module discovered its own work. `Get-RotationCandidate` called `Get-AzVM` across the
subscription, filtered by an enable tag, skipped machines carrying a hold tag, and
`Invoke-CredentialRotation` walked a list of subscriptions around it.

That reads sensibly until you put it next to the sibling tool, where the module's help says
plainly: *"The module never reads it from a tag — the caller states it."* There, discovery,
tags and ring order live in the runbook; the module takes a named machine and acts on it.

The difference is not cosmetic. With policy inside the module:

- Running it locally means either accepting the tag rules or reaching past the entry point
  to an internal function that takes a VM object.
- Anyone who wants different selection — a resource graph query, a CMDB, an approval
  workflow, a Logic App — has to work around the module rather than with it.
- The module needs Azure-wide read permission to do its own discovery, even when the caller
  already knows exactly which machine they mean.

## Decision

The module rotates the machines it is given. It does not search for them, does not read a
tag, and has no opinion about which machines belong in scope.

`Invoke-CredentialRotation` takes either `-VMName` (that one, now) or `-VM` (these, if they
are due). Selection, hold, the subscription walk and the schedule for the access scan all
move to the caller — which for the deployed form is the runbook wrapper.

## Why the hold tag went too

It was the closest call. A hold is the last thing standing between a rotation and a machine
somebody is working on, and moving it out means the module will happily rotate a held
machine if the orchestrator forgets to filter.

It still belongs outside, because a hold is a *statement about a machine* rather than a
fact about the credential. The module's own checks are all facts — is there a staged value,
does the machine have an admin username, is the secret readable. Mixing one policy flag into
that set would make the boundary a matter of taste rather than a rule, and a boundary you
have to argue about every time is not a boundary.

## Consequences

- Breaking, at 0.3.0. Nothing external is deployed against 0.2.0.
- The runbook wrapper grew from a configuration reader into a real orchestrator, and is now
  the place to read if you want to know which machines get touched.
- The 15 `CR_*` automation variables did not change, so Bicep, Terraform and the deployment
  contract test are untouched. `HoldTagName` became an ordinary wrapper parameter rather
  than a sixteenth variable, deliberately, to keep that true.
- Two tests assert the boundary through the PowerShell parser: no module file calls
  `Get-AzVM` without `-Name` or `-ResourceGroupName`, and no module file uses a tag
  variable. A third asserts the runbook does both, so the behaviour cannot pass the suite
  by simply disappearing.

## Revisit if

Someone finds a policy decision that genuinely cannot be expressed by the caller. So far the
only candidate was the hold tag, and it can.
