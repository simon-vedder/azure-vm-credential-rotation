# Deploy with Bicep

`main.bicep` deploys the whole thing at subscription scope: a resource group, an Automation Account
with a system-assigned identity, the `AzureVMCredentialRotation` module imported from the PowerShell
Gallery, the runbook and its schedule, the roles the identity needs, and — unless you turn them off
— the audit trail and rotation after use.

For the Terraform path, see [`../infra`](../infra). The two are equivalent and share one contract:
the `CR_*` automation variables the runbook reads. [ADR 0007](../docs/decisions/0007-bicep-beside-terraform.md)
says why both exist.

## Before you start

You need an existing Key Vault with **RBAC authorisation** enabled, in the same subscription. The
deployment grants the identity Key Vault Secrets Officer on it; it does not create it, because the
vault that holds your credentials should outlive any one tool.

## The smallest useful deployment

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsimon-vedder%2Fazure-vm-credential-rotation%2Fmain%2Fdeploy%2Fazuredeploy.json)

The button opens the portal with the compiled template and asks for the parameters. From a shell:

```bash
az deployment sub create \
  --location switzerlandnorth \
  --template-file deploy/main.bicep \
  --parameters moduleVersion=0.1.0 \
               keyVaultName=kv-credentials \
               keyVaultResourceGroupName=rg-vault \
               targetResourceGroupNames='["rg-workloads"]'
```

That gives you expiry-driven rotation with the audit trail, **in dry-run mode**: every scheduled
run reports what it would replace and changes nothing. That is the default on purpose. Read one
run's output, then redeploy with `dryRun=false`.

Leave `targetResourceGroupNames` empty and the identity gets Virtual Machine Contributor across the
whole subscription instead. Think before you do: that role includes installing extensions, which is
code execution as SYSTEM or root on every VM in scope.

## Turning on rotation after use

```bash
az deployment sub create \
  ... \
  --parameters enableRotateOnAccess=true gracePeriodHours=8
```

A read of a credential pulls its expiry date forward by the grace period, so the next reconciliation
pass replaces it. `accessLookbackHours` defaults to twice the schedule interval, which is the safe
value: a window shorter than the gap between runs drops reads that land between two passes, and
nothing reports it.

## What you get

| | |
|---|---|
| Automation Account | system-assigned identity, `disableLocalAuth` |
| Runbook | `Invoke-CredentialRotation`, PowerShell 7.2 runtime |
| Schedule | every `scheduleIntervalHours`, default 6 |
| Module | `AzureVMCredentialRotation` from the Gallery, at `moduleVersion` |
| Variables | 15 `CR_*` settings the runbook reads at start-up |
| Workspace | `CredentialRotation_CL` custom table, ingestion endpoint and rule |
| Workbook | who read which credential, when it was replaced |
| Roles | Key Vault Secrets Officer, Virtual Machine Contributor, Automation Job Operator, Log Analytics Reader, Monitoring Metrics Publisher |

## Checking before you commit

`what-if` shows the whole plan without creating anything:

```bash
az deployment sub what-if \
  --location switzerlandnorth \
  --template-file deploy/main.bicep \
  --parameters moduleVersion=0.1.0 keyVaultName=kv-credentials keyVaultResourceGroupName=rg-vault
```

Role assignments come back as `Unsupported` there. That is expected: their names are derived from
the identity's principal ID, which does not exist until the Automation Account does.

## azuredeploy.json

Compiled from `main.bicep` and committed, so a deploy button has something to point at. CI fails if
the two drift apart. Rebuild it with:

```bash
az bicep build --file deploy/main.bicep --outfile deploy/azuredeploy.json
```
