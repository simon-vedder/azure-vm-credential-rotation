# 0009 — The module returns facts and takes findings

**Status:** accepted · 2026-09-08 · completes [0008](0008-the-module-holds-no-policy.md)

## Context

[0008](0008-the-module-holds-no-policy.md) took machine selection out of the module. Three
things of the same kind stayed behind, and each was a way for the module to reach past what it
was told and into infrastructure it did not deploy:

- `Register-CredentialAccess` ran a Log Analytics query to find out who had read a credential.
  Finding reads is discovery — the same activity as finding machines, aimed at a different table.
- `Invoke-CredentialRotation` posted its records to a data collection rule when given one. The
  table, the rule and the endpoint are all created by the deployment; the module knew their
  shape and their address.
- The secret naming convention was a private function nobody could reach. A vault with its own
  convention could not be used at all.

The cost showed up on the smallest use: a workstation rotating one machine had to install
`Az.OperationalInsights` for a query it would never run.

## Decision

The module's commands take facts and return facts.

- `Register-CredentialAccess` takes a secret name and a reader, and moves that secret's expiry.
  It accepts pipeline input by property name, so whatever produced the finding — the KQL in
  `queries/accessed-secrets.kql`, a SIEM export, a ticket — pipes straight in.
- `Invoke-CredentialRotation` returns its records. It has no parameter for where to send them.
- `-SecretNameTemplate` states the naming convention, with the previous shape as the default.

The runbook wrapper runs the query, pipes the reads into `Register-CredentialAccess`, calls
`Invoke-CredentialRotation`, and ships `.Records` to the table it deployed. `Az.OperationalInsights`
left the manifest.

## Why this is the same decision as 0008

The line is: **the module never learns anything on its own initiative.** Machines, reads and
destinations all arrive as arguments. That is what makes the module honest about its
dependencies — four Az modules, a vault, and whatever VM objects you hand it — and what lets
an orchestrator that is not this runbook use it without working around it. A Logic App that
learns about reads from a SIEM does not have to pretend to be a Log Analytics workspace.

## What did not move

- `New-RotationRecord` stays. It defines what a record *is* — the column contract with the
  custom table — which is knowledge about the module's own output, not about the destination.
- The informational tags on secrets stay. They are written to the module's own artefact so a
  person in the portal can read it; nothing decides on them.
- `-VMName` resolution stays. Resolving a name the caller gave is not discovery.

## Consequences

- Breaking, within the still-untagged 0.3.0.
- The 15 `CR_*` variables did not change. The wrapper reads the same settings; it now uses the
  workspace and ingestion ones itself instead of forwarding them.
- Three guards through the parser: no module file calls `Get-AzVM` without a name, uses a tag
  variable, or calls `Invoke-AzOperationalInsightsQuery` / `Invoke-RestMethod`. The runbook
  is asserted to do all of it, so nothing can pass by vanishing.
- Rotation after use from a workstation is two commands, not one: run the query, pipe it in.
  That is honest. It never worked without a workspace anyway.

## Revisit if

A module command turns out to need something it cannot be given as an argument. None has so far.
