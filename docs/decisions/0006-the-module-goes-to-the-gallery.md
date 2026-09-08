# 0006 — The module goes to the PowerShell Gallery

**Status:** accepted · 2026-09-08 · supersedes the gallery rejection in [0004](0004-powershell-module-with-build-step.md)

## Context

[0004](0004-powershell-module-with-build-step.md) rejected publishing to the PowerShell Gallery,
and gave a reason rather than a preference: *"a release process for a project with one consumer"*.
At the time that was exactly right. The module had one consumer, the flattened runbook was free,
and a versioned package on a public feed would have been ceremony around a file only one deployment
ever read.

The premise has changed. This is going out as a tool other people deploy, alongside
AzureInPlaceUpgrade, which already works this way. With more than one consumer, the flattened
artefact stops being free:

- The runbook is 60 KB of generated PowerShell in the repository. Anybody deploying it has to trust
  a blob they will not read, and has no version to point at when something misbehaves.
- ARM cannot publish inline runbook content the way Terraform can. A Bicep deployment must fetch
  the script from a URL, so the artefact has to be reachable and pinned anyway — at which point it
  is a distribution channel with none of a package feed's guarantees.
- "Which version is deployed?" has no answer today. A Gallery version and the `contentLink`
  version give Automation something to re-import against, which is how a fix actually reaches an
  existing deployment.

## Decision

`CredentialRotation` is published to the PowerShell Gallery. The Bicep deployment imports it into
the Automation Account by version, and publishes the thin runbook wrapper from a pinned raw URL.

The wrapper imports the module only when its commands are not already defined, so the flattened
artefact keeps working unchanged.

## Why not just keep flattening

It still works, and the Terraform path still does exactly that — see
[0007](0007-bicep-beside-terraform.md). What the Gallery adds is a version number that survives
outside this repository: something to pin in a template, to compare against a running deployment,
and to bump when a fix ships. A concatenated file has no such handle.

## Consequences

- A release process: a tag, a workflow, an API key held as a GitHub secret. Nobody publishes by
  hand from a laptop.
- The module's public surface is now a promise to strangers. Renaming an exported command is a
  breaking change, not a refactor.
- Two ways to get the same logic into Automation, which is a real cost. The runbook wrapper is the
  single place that has to work for both, and it is a dozen lines.
- The Gallery cannot delete a version, only unlist it. A bad release is permanent and gets fixed
  by publishing a better one.

## Revisit if

The tool stops being distributed and goes back to one consumer, or Automation gains a way to
reference module source directly.
