# 0004 — A PowerShell module, flattened at build time

**Status:** accepted · 2026-07-31 · the gallery rejection below is superseded by [0006](0006-the-module-goes-to-the-gallery.md)

## Context

Azure Automation executes one script per job. It cannot `Import-Module` something that
is not published to a gallery or uploaded as a module asset. The path of least
resistance is therefore a single large `.ps1` — which is how the predecessor of this
project was written, and it made the logic effectively untestable.

## Decision

The source is a proper module, one function per file, under `src/AzureVMCredentialRotation`.
`build/Build-Runbook.ps1` concatenates it with the runbook wrapper into a single file
in `infra/modules/core/runbook/`, which is **committed** so deployment needs no build step. CI fails if the
artefact and the sources drift apart.

## Why

**Testable.** Pester imports the module and tests functions in isolation. Password
generation, SSH key encoding and secret-name resolution are pure and get real
assertions rather than a hopeful manual run.

**Runnable locally.** `Import-Module ./src/AzureVMCredentialRotation` then
`Invoke-CredentialRotation -WhatIf` against one VM. Nobody deploys a scheduled job that
changes administrator passwords without trying it by hand first, and making that
possible is the difference between a tool people adopt and one they read.

**Deployable without tooling.** The committed artefact means `terraform apply` works on
a machine with no PowerShell at all.

Rejected alternatives: publishing to the PowerShell Gallery (a release process for a
project with one consumer), and uploading a module asset from a storage account (a
storage account and a versioned zip to keep in sync, for the same result).

## Consequences

- `infra/modules/core/runbook/` must be rebuilt and committed whenever `src/` changes. CI enforces this
  rather than trusting discipline.
- The generated file is 60 KB and not meant to be read; the header says so.
- The build parses the wrapper with the PowerShell language parser to split its
  `param()` block out, because a param block must be the first statement in a script
  and cannot follow the function definitions. The build also re-parses its own output
  and fails on a syntax error — which caught a real bug (`"$Var:"` parsed as a scope
  qualifier) on the first run.

## Revisit if

The module grows enough consumers to justify a gallery release, or Automation gains a
way to reference module source directly.
