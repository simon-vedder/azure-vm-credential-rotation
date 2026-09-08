# Deploy with Bicep

`main.bicep` deploys the whole thing at subscription scope: a resource group, an Automation Account
with a system-assigned identity, the `AzureVMCredentialRotation` module imported from the PowerShell
Gallery, the runbook and its schedule, the roles the identity needs, and — unless you turn them off
— the audit trail and rotation after use.

This is the path the project verifies live on every release. The Terraform modules under
[`../infra`](../infra) stay for teams that already run Terraform; they write the same `CR_*`
automation variables the runbook reads, and a test holds the two sets together, but they are
validated in CI rather than deployed live. [ADR 0007](../docs/decisions/0007-bicep-beside-terraform.md)
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
  --parameters moduleVersion=0.3.0 \
               keyVaultName=kv-credentials \
               keyVaultResourceGroupName=rg-vault \
               targetResourceGroupNames='["rg-workloads"]'
```

That gives you expiry-driven rotation with the audit trail, **in dry-run mode**: every scheduled
run reports what it would replace and changes nothing. That is the default on purpose. Read one
run's output, then redeploy with `dryRun=false`.

Name nothing - no resource groups, no subscriptions - and the identity gets Virtual Machine
Contributor across the whole subscription instead. Think before you do: that role includes
installing extensions, which is code execution as SYSTEM or root on every VM in scope.

## Machines in other subscriptions

The runbook walks every subscription it is told about, and the deployment assigns the role where
the machines are. Name resource groups elsewhere by resource ID, or whole subscriptions by ID:

```bash
az deployment sub create \
  ... \
  --parameters targetResourceGroupNames='["rg-workloads"]' \
               targetResourceGroupIds='["/subscriptions/<other-id>/resourceGroups/rg-dmz"]'
```

Every subscription mentioned in either list is walked, plus this one if any of its groups are
named. The deployer needs the right to assign roles in the other subscription - Owner or User
Access Administrator there - or the deployment fails on that module. The Key Vault stays in this
subscription; a vault is addressed by name, not by subscription, so the runbook reaches it from
anywhere in the tenant.

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
| Variables | 18 `CR_*` settings the runbook reads at start-up |
| Workspace | `CredentialRotation_CL` custom table, ingestion endpoint and rule |
| Workbook | who read which credential, when it was replaced |
| Roles | Key Vault Secrets Officer, Virtual Machine Contributor, Automation Job Operator, Log Analytics Reader, Monitoring Metrics Publisher |

## Checking before you commit

`what-if` shows the whole plan without creating anything:

```bash
az deployment sub what-if \
  --location switzerlandnorth \
  --template-file deploy/main.bicep \
  --parameters moduleVersion=0.3.0 keyVaultName=kv-credentials keyVaultResourceGroupName=rg-vault
```

Role assignments come back as `Unsupported` there. That is expected: their names are derived from
the identity's principal ID, which does not exist until the Automation Account does.

## azuredeploy.json

Compiled from `main.bicep` and committed, so a deploy button has something to point at. CI fails if
the two drift apart. Rebuild it with:

```bash
az bicep build --file deploy/main.bicep --outfile deploy/azuredeploy.json
```

## Lab

`lab.bicep` builds what the module needs to be verified against real guests: one Windows and one
Linux VM (password authentication left on, so both credential kinds get exercised), no public IP,
no inbound rule, and a Key Vault with RBAC authorisation that grants you Secrets Officer. Both
machines carry the `CredentialRotation=enabled` tag, so a `main.bicep` deployment pointed at the
lab resource group finds them.

```bash
az group create -n rg-crot-lab -l westeurope --tags Environment=lab Owner=simon CostCenter=lab Project=azure-vm-credential-rotation
az deployment group create -g rg-crot-lab -f deploy/lab.bicep \
  -p adminPassword="$(openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | head -c 18)Xy9!" \
     deployerObjectId="$(az ad signed-in-user show --query id -o tsv)"
```

The initial password is generated and forgotten on purpose: the first rotation replaces it, and
from then on the vault is the only place it lives. `tests/manual/Invoke-LabSmokeTest.ps1` runs the
module through every path against these two machines and checks each result on the guest through
Run Command.

`lab.bicep` also builds the variations the verification needs: `deployKeyVault=false` and
`deployWindowsVm=false` for a second lab in another subscription, and `windowsImage` /
`linuxImage` with their `windowsPlan` / `linuxPlan` for marketplace images such as the CIS
hardened ones (accept the terms first with `az vm image terms accept`). Note that the CIS
Windows images are SCSI-only and will not boot on the v6 sizes, which are NVMe.

## Scale lab

`lab-scale.bicep` builds a fleet of small Linux machines, so the per-machine cost of a pass can
be measured rather than guessed - `tests/manual/Measure-RotationThroughput.ps1` does the
measuring and prints what fits in Automation's three-hour job limit.

```bash
az group create -n rg-crot-scale -l westeurope
az deployment group create -g rg-crot-scale -f deploy/lab.bicep \
  -p adminPassword=... deployerObjectId=... deployWindowsVm=false deployLinuxVm=false   # vault only
az deployment group create -g rg-crot-scale -f deploy/lab-scale.bicep \
  -p adminPassword=... vmCount=7 namePrefix=vm-crot-w location=westeurope
```

The quota that bites here is **Total Regional Cores**, not the per-family one that is easy to
find: a region granted 14 cores holds seven 2-vCPU machines whatever the family limits say.
Spread a larger fleet over regions with a different `namePrefix` each - secret names are derived
from VM names, so two machines with the same name would share one secret in the vault.

Between sessions:

```bash
az vm deallocate -g rg-crot-lab --ids $(az vm list -g rg-crot-lab --query '[].id' -o tsv) --no-wait
```

When done — and purge the vault afterwards, or soft-delete keeps its name reserved:

```bash
az group delete -n rg-crot-lab --yes --no-wait
az keyvault purge --name <keyVaultName>
```
